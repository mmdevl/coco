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
    python3 python3-pip python3-virtualenv \
    python3.14 python3.14-pip \
    openldap-clients \
    bash-completion sudo shadow-utils tzdata \
    zsh ripgrep fd-find fzf opentmux kitty-terminfo \
    socat \
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
 && (curl -fsSL https://antigravity.google/cli/install.sh | bash || true) \
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
     if [[ -n "$grp" ]]; then [[ "$grp" = coco ]] || groupmod -n coco "$grp"; else groupadd -g "${GID}" coco; fi) \
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

# --- shell / vim defaults ---
COPY container/bashrc.coco /etc/profile.d/coco-bashrc.sh
COPY container/vimrc /etc/vimrc.local
COPY container/zshrc.local /etc/zshrc.local
RUN chmod 0644 \
 /etc/zshrc.local /etc/profile.d/coco-bashrc.sh /etc/vimrc.local \
 && echo 'source /etc/vimrc.local' >> /etc/vimrc \
 && echo 'source /etc/zshrc.local' >> /etc/zshrc 

# --- entrypoint ---
COPY container/entrypoint.sh /usr/local/bin/coco-entrypoint.sh
RUN chmod 0755 /usr/local/bin/coco-entrypoint.sh

LABEL coco.hash=""
LABEL coco.version=""

USER coco
WORKDIR ${HOME}
ENTRYPOINT ["/usr/local/bin/coco-entrypoint.sh"]
CMD ["/bin/bash", "-l"]
