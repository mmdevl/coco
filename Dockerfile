FROM almalinux:10

ARG UID=1000
ARG GID=1000
ARG TZ=UTC

# --- base packages ---
# AlmaLinux 10 (RHEL 10) dropped dnf modularity for its own AppStream
# packages ("No matching Modules to list") -- nodejs is now a single plain
# package (currently 22.x), no `dnf module enable` needed or available.
#
# python3.14: installed alongside the system python3 (3.12), not in place
# of it. /usr/bin/python3 is RPM-owned and dnf's own shebang is
# `#!/usr/bin/python3` -- repointing that symlink would run dnf under an
# interpreter its compiled C-extension modules (python3-libdnf5 etc.)
# aren't built against, breaking dnf itself. python3.14 gets made the
# *user-facing* default instead, via /usr/local/bin symlinks that win on
# PATH ahead of /usr/bin without touching the system binary (see below).
RUN dnf install -y epel-release \
 && dnf config-manager --set-enabled crb \
 && dnf install -y --allowerasing \
    git vim less curl wget jq rsync unzip zip tar make gcc which \
    screen htop strace lsof procps-ng \
    mariadb sqlite \
    libatomic \
    python3 python3-pip python3-virtualenv \
    python3.14 python3.14-pip \
    openldap-clients \
    bash-completion sudo shadow-utils tzdata socat \
 && dnf clean all \
 && ln -sf /usr/bin/python3.14 /usr/local/bin/python3 \
 && ln -sf /usr/bin/python3.14 /usr/local/bin/python \
 && ln -sf /usr/bin/pip3.14 /usr/local/bin/pip3 \
 && ln -sf /usr/bin/pip3.14 /usr/local/bin/pip

ENV TZ=${TZ}

# --- PHP 8.5 (Remi) --- (AlmaLinux 10's own AppStream PHP is 8.3; Remi
# still publishes its own module stream even though RHEL 10 dropped
# modularity for its own packages, so `dnf module enable` still works here).
# must come before composer below, which invokes `php`.
RUN dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm \
 && dnf module enable -y php:remi-8.5 \
 && dnf install -y --allowerasing \
    php-cli php-ldap php-mysqlnd php-pecl-xdebug php-xml php-mbstring \
 && dnf clean all

# --- composer ---
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# --- phpunit --- (pinned to major 12, the current stable line -- requires
# PHP >=8.3, verified running clean under Remi's PHP 8.5 above)
RUN curl -sSL https://phar.phpunit.de/phpunit-12.phar -o /usr/local/bin/phpunit \
 && chmod +x /usr/local/bin/phpunit

# --- node (needed by most coding agent CLIs) ---
RUN dnf install -y nodejs \
 && dnf clean all

# --- bun (needed by the claude-mem plugin's hook worker) ---
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash \
 && chmod +x /usr/local/bin/bun

# --- uv/uvx (needed by the claude-mem plugin's vector search) ---
RUN curl -fsSL https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# --- coding agent CLIs (installed regardless of per-project selection) ---
# unpinned -- always installs whatever's currently latest. Docker still
# caches this layer as long as the Dockerfile text and COCO_AGENTS_CACHE_BUST
# are unchanged, so a plain rebuild does NOT pick up new agent releases;
# `coco --rebuild` busts it explicitly (see bin/coco) to force a refresh.
# opencode: @opencode/cli is the v2 package (v1 shipped as opencode-ai).
ARG COCO_AGENTS_CACHE_BUST=0
RUN echo "cache-bust: ${COCO_AGENTS_CACHE_BUST}" \
 && npm install -g @anthropic-ai/claude-code \
 && npm install -g @openai/codex \
 && npm install -g @google/gemini-cli \
 && npm install -g @qwen-code/qwen-code \
 && npm install -g @opencode/cli \
 && (curl -fsSL https://cursor.com/install | bash || true)

# GitHub CLI + Copilot extension
RUN dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
 && dnf install -y gh \
 && dnf clean all

# --- coco user, configurable UID/GID ---
ARG HOME=/home/coco
# home dir is set to the host's own $HOME (see bin/coco / ARG HOME above),
# not /home/coco: at runtime the container is run with -e HOME=<host $HOME>
# so that agent configs cached with absolute host paths (e.g. claude's
# plugin marketplace install locations) stay valid. building the coco
# native binary (below) under that same path keeps `claude install` from
# needing to run again at every container start.
#
# -M (no skel copy), not -m: /etc/skel's ~/.bash_profile -> ~/.bashrc ->
# /etc/bashrc chain would run after /etc/profile.d/coco-bashrc.sh on
# login shells and clobber its PS1 with the stock [user@host dir]$ one.
#
# no chown to ${UID} and no `USER coco` anywhere at build time: under
# rootless podman the build runs in a user namespace that maps only the
# host user's own UID plus its /etc/subuid range (65536 ids by default),
# so a large UID (e.g. 577997 on LDAP/NFS sites) is unmapped there and
# chown/setuid to it fail with EINVAL. useradd itself copes (only warns).
# ownership is fixed up at container start instead (entrypoint.sh), where
# --userns=keep-id makes the UID resolvable.
# host GID may collide with a stock group (macOS staff=20 is almalinux's
# games): rename it rather than skip, so `id` reads coco, not games.
RUN (grp="$(getent group "${GID}" | cut -d: -f1)"; \
     if [ -n "$grp" ]; then [ "$grp" = coco ] || groupmod -n coco "$grp"; else groupadd -g "${GID}" coco; fi) \
 && (getent passwd "${UID}" >/dev/null || useradd -u "${UID}" -g "${GID}" -M -s /bin/bash -d "${HOME}" coco) \
 && mkdir -p "${HOME}" \
 && echo "coco ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coco \
 && chmod 0440 /etc/sudoers.d/coco

# note: this gh CLI version ships `gh copilot` as a built-in command already,
# no separate extension install needed.

# claude-code manages its own native binary under ~/.local/bin, separate from
# the npm-installed shim above; bake it into the image now so fresh --rm
# containers don't hit "missing or broken, run claude install to repair".
# runs as root (see the UID note above); entrypoint.sh chowns ~/.local to
# coco at start. as root the installer also succeeds at removing the npm
# shim (/usr/local/bin/claude), so ~/.local/bin must be on PATH -- nothing
# else puts it there (no skel .bash_profile, see -M above).
RUN HOME="${HOME}" claude install
ENV PATH="${HOME}/.local/bin:${PATH}"

# --- hermes (Nous Research) ---
# pip/PyPI is not a supported install path upstream (setup.py refuses to
# build wheels outside Nix, and no prebuilt assets are published), so bake
# the official source install instead -- exactly what a host user gets from
# install.sh: clone -> `hermes pm install` (pinned uv, managed Python,
# hash-verified venv, build toolchain) -> command publication + TUI build.
# Layout constraints:
#  - checkout and the PM dependency store must NOT live under ~/.hermes:
#    that dir is bind-mounted from the host as hermes's user state
#    (config.yaml, .env, logs, sessions, skills, profiles), and the host
#    mount would shadow anything baked in there. both default locations
#    sit under $HERMES_HOME (hermes-agent/, tools/), so redirect the
#    checkout under .local/share/hermes and pin the store root via
#    HERMES_RUNTIME_DIR (the supported knob). the launcher pins its store
#    interpreter by absolute path, and entrypoint.sh chowns this tree at
#    start (it's under $HOME, not a bind mount), so it stays writable for
#    `hermes update` / `hermes pm install`.
#  - the store root must also survive as an image ENV: hermes's source
#    install stamp carries no runtimeDir, so at runtime every store lookup
#    (the launcher pins its own Python, but pm tool syncs, venv validation,
#    `hermes pm install ...`) resolves the store from HERMES_RUNTIME_DIR --
#    defaulting to <home>/tools, i.e. the mounted host dir. same trick the
#    vendor's own container ships (ENV HERMES_RUNTIME_DIR=/opt/hermes/tools).
# --skip-browser/--skip-computer-use: coco is a CLI/TUI box and those are
# heavy; both opt back in with `hermes pm install chromium` / `cua-driver`.
# unpinned, like the agents above: fresh stable at build time, and
# `coco --rebuild` (cache-bust below) refreshes the release.
# Network: pm's artifact downloader has no read timeout and stalls
# indefinitely from some networks on Cloudflare-backed peers (npmjs and
# friends; the same curl succeeds in seconds). So the hash-verified
# artifact downloads are never left to it: resolve the release, clone it,
# then pre-seed the store's fetch cache (fetch-<sha256>/<name>) from the
# checkout's pm/lock.json -- curl + sha256 verify. pm's downloader skips
# the network entirely when the seeded dest already matches. The seeded
# fetch dirs are removed again after the install (the unpacked store dirs
# are what's used at runtime).
# First run of the box: hermes's committed dependency env is recorded
# under $HERMES_HOME/installs/<sha256(checkout path)> -- i.e. in the host
# bind mount, so a fresh host starts without it. entrypoint.sh provisions
# it once (see entrypoint.sh); to keep that step near-offline, the uv
# package cache is seeded next to the store at <store>/../uv-cache, which
# pm merges into its machine cache on first use. For the same reason the
# `hermes --version` smoke test runs before ~/.hermes is wiped -- after
# the wipe the record is gone and hermes would demand `pm repair`.
RUN echo "cache-bust: ${COCO_AGENTS_CACHE_BUST}" \
  && curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh \
  && HTOOLS="${HOME}/.local/share/hermes/tools" \
  && HREPO="${HOME}/.local/share/hermes/hermes-agent" \
  && mkdir -p "${HTOOLS}" \
  && TAG="$(curl -fsSL --connect-timeout 5 --max-time 20 \
       -H 'Accept: application/vnd.github+json' \
       https://api.github.com/repos/NousResearch/hermes-agent/releases/latest 2>/dev/null \
       | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" \
  && { printf '%s' "${TAG}" | grep -Eq '^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
      || TAG="$(git ls-remote --tags --refs \
           https://github.com/NousResearch/hermes-agent.git 'refs/tags/v*' \
           | sed 's#.*refs/tags/##' \
           | grep -E '^v(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
           | sort -V | tail -n 1)"; } \
  && test -n "${TAG}" \
  && git clone --branch "${TAG}" \
       https://github.com/NousResearch/hermes-agent.git "${HREPO}" \
  && (cd "${HREPO}" \
      && jq -r ' \
         ["uv","bws","ffmpeg","gh","just","node","npm","pnpm","python","ripgrep"] as $want \
         | .packages | with_entries(select(.key as $k | ($want | index($k)) != null)) \
         | .[] | .artifacts | to_entries \
         | map(select(.key == "linux-x64" or .key == "any")) \
         | map(.value) \
         | map(if type == "array" then .[] else . end) \
         | map(select(has("url") and has("sha256"))) \
         | unique_by([.url, .sha256]) \
         | .[] | [.url, .sha256] | @tsv \
       ' pm/lock.json > /tmp/hermes-seeds.tsv) \
  && test -s /tmp/hermes-seeds.tsv \
  && while IFS="$(printf '\t')" read -r url sha; do \
       name="${url##*/}"; \
       dest="${HTOOLS}/fetch-${sha}/${name}"; \
       if [ -f "${dest}" ] && [ "$(sha256sum "${dest}" | cut -d' ' -f1)" = "${sha}" ]; then \
         continue; \
       fi; \
       curl -fSL --retry 3 --max-time 900 -o /tmp/hermes-seed.tmp "${url}" \
           || { echo "hermes: seed download failed: ${url}" >&2; exit 1; }; \
       act="$(sha256sum /tmp/hermes-seed.tmp | cut -d' ' -f1)"; \
       if [ "${act}" != "${sha}" ]; then \
         echo "hermes: seed sha256 mismatch for ${url}" >&2; exit 1; \
       fi; \
       mkdir -p "$(dirname "${dest}")" && mv /tmp/hermes-seed.tmp "${dest}"; \
     done < /tmp/hermes-seeds.tsv \
  && rm -f /tmp/hermes-seeds.tsv \
  && HOME="${HOME}" \
     HERMES_RUNTIME_DIR="${HTOOLS}" \
     NODE_OPTIONS=--dns-result-order=ipv4first \
     bash /tmp/hermes-install.sh --non-interactive \
          --skip-browser --skip-computer-use \
          --dir "${HREPO}" \
  && HERMES_RUNTIME_DIR="${HTOOLS}" "${HOME}/.local/bin/hermes" --version \
  && find "${HTOOLS}" -maxdepth 1 -type d -name 'fetch-*' -exec rm -rf {} + \
  && if [ -d "${HOME}/.hermes/cache/uv" ]; then \
       cp -a "${HOME}/.hermes/cache/uv" "${HOME}/.local/share/hermes/uv-cache"; \
     fi \
  && rm -rf "${HOME}/.hermes" "${HOME}/.cache/uv" \
  && rm -f /tmp/hermes-install.sh \
  && test -x "${HOME}/.local/bin/hermes" \
  && test -d "${HOME}/.local/share/hermes/uv-cache"
ENV HERMES_RUNTIME_DIR=${HOME}/.local/share/hermes/tools

# --- shell / vim defaults ---
COPY container/bashrc.coco /etc/profile.d/coco-bashrc.sh
COPY container/vimrc /etc/vimrc.local
RUN chmod 0644 /etc/profile.d/coco-bashrc.sh /etc/vimrc.local \
 && echo 'source /etc/vimrc.local' >> /etc/vimrc

# --- entrypoint ---
COPY container/entrypoint.sh /usr/local/bin/coco-entrypoint.sh
RUN chmod 0755 /usr/local/bin/coco-entrypoint.sh

LABEL coco.hash=""
LABEL coco.version=""

USER coco
WORKDIR ${HOME}
ENTRYPOINT ["/usr/local/bin/coco-entrypoint.sh"]
CMD ["/bin/bash", "-l"]
