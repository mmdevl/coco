# 🥥 coco — facts

## What
- Docker dev container, mounts `pwd` at same absolute path in-container
- Base: AlmaLinux 10
- Agents installed: Claude Code, Codex, Copilot, Cursor, Gemini, Qwen Code, OpenCode

## Install
```
git clone https://github.com/mmdevl/coco.git ~/coco
~/coco/bin/coco --install
```

## Run
```
cd project
coco
```
- builds image (cached), starts container, drops into shell
- running in `$HOME` warns first (would mount whole home)

## Flags
- `--install` — add to PATH
- `--rebuild` — force image rebuild
- `--config` — re-pick agents for this project
- `--cleanup` — remove old/dangling coco images
- `--check-update` — check now, skip 24h cache
- `--no-update-check` — skip check this run
- `-V` — version
- `-h` — help

## Env vars
- `UID`, `GID`, `TZ`
- `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` (optional)
- `XDEBUG_ENABLE` (optional)
- `COCO_NO_UPDATE_CHECK=1` — same as `--no-update-check`
- `COCO_UPDATE_REMOTE=<name>` — remote to check (default `origin`)
- `COCO_HOST_PORTS=<ports>` — host loopback ports reachable as `localhost:<port>` in-container; comma-separated ports/ranges (default `11434`, empty disables)

## Mount path — why
- project mounted at same absolute host path → tool caches (claude-mem, `.git` worktrees, LSP) stay valid both sides
- host paths unique → agent trust-lists don't confuse different projects
- container name still gets 6-char hash of full path (Docker needs unique names, limited chars)
- podman on an SELinux host (Fedora, RHEL): every bind mount gets `:Z` so the container may read/write it; relabels the project dir and agent config dirs with a private container label. Skipped for docker and non-SELinux hosts

## Host services (ollama)
- `localhost:11434` in-container reaches the host's `localhost:11434` (ollama's default), so agents configured for a local ollama just work
- rootless podman with pasta (auto-detected: the binary `podman info` reports, else `pasta` on PATH): pasta forwards the port container-loopback → host-loopback (`--network=pasta:-T,11434`); ollama can stay bound to `127.0.0.1` on the host. `pasta` is a network *mode*, it never shows up in `podman network ls` (that only lists bridges like the default `podman`)
- docker / rootful podman: container gets the host alias (`host.docker.internal` / `host.containers.internal`) and the entrypoint bridges each port `localhost:<port>` → alias with `socat`, so in-container `localhost:<port>` works here too
  - Docker Desktop (macOS, Windows): the alias reaches the host's loopback; ollama can stay on `127.0.0.1`, nothing to configure
  - Linux docker / rootful podman: the alias is the bridge gateway, which never reaches host `127.0.0.1`. Bind ollama to the bridge IP, narrowest first: `OLLAMA_HOST=172.17.0.1:11434` (docker0 only, invisible to the LAN); `OLLAMA_HOST=0.0.0.0` works too but exposes ollama to every interface — firewall it. `ip -4 addr show docker0` (podman: `podman0`) prints the bridge IP
  - rootless docker: rootlesskit blocks host loopback by default; `DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false` in the daemon's environment lifts that for every container, not per-run — binding ollama to the bridge IP as above is the safer route
- other ports: `COCO_HOST_PORTS=11434,8000-8010`; `COCO_HOST_PORTS=` turns it off

## Coding agents
- first run: interactive checklist picks agents (0+), saved to `.coco/config` as `AGENTS=claude,codex,...`
- non-tty: falls back to numbered prompt
- all agent CLIs installed regardless; selection only controls which host config dirs get mounted
- config paths: `~/.claude`, `~/.codex`, `~/.config/gh-copilot`, `~/.cursor`, `~/.gemini`, `~/.qwen`, `~/.config/opencode` + `~/.local/share/opencode` (opencode keeps auth/sessions in the XDG data dir, config in the XDG config dir)
- `~/.claude.json` NOT bind-mounted directly (breaks atomic writes); host symlinks it into `~/.claude/claude.json`, container entrypoint recreates matching symlink each start
- re-run picker: `coco --config`

## Persistent data
```
global (~/...):     .claude .codex .config/gh-copilot .cursor .gemini .qwen .config/opencode .local/share/opencode
project (pwd/.coco/...): cache/pip cache/npm cache/composer bash_history vim
```
- `.coco/` also holds `config`
- first run prompts to add `.coco` to `.gitignore`

## Build/rebuild
- version lives in `VERSION` file (semver, manual bump)
- images tagged `coco:latest` + `coco:<VERSION>`
- hash of Dockerfile + build context + UID/GID/TZ/HOME + VERSION → stored as `coco.hash` label
- rebuilds only if hash changed; `--rebuild` forces it
- missing `coco:<VERSION>` tag but matching hash → re-tags for free, no rebuild
- Podman build fails with `disk quota exceeded` writing to `/tmp/container_images_storage…`: podman stages layer blobs in `$TMPDIR`, and a small tmpfs `/tmp` overflows on the coding-agent layer. Build with `TMPDIR=/var/tmp coco --rebuild` (only the build needs it; `containers.conf` `image_copy_tmp_dir` is ignored when `TMPDIR` is set)

## Update check
- runs on startup, before agent selection
- compares local `VERSION` vs highest `vX.Y.Z` git tag on remote
- cached 24h in `${XDG_CACHE_HOME:-~/.cache}/coco/update-check`
- silently skips if: no `VERSION`, not a git checkout, no matching remote, non-interactive, remote unreachable (backs off 1h), no tags yet
- on update found: prompts → `git pull --ff-only` → re-execs coco
- refuses on dirty worktree / detached HEAD

## Cleanup
- `coco --cleanup` removes: dangling `<none>` images (matched via `coco.hash` label), old `coco:<version>` tags
- never touches current `latest`/`<VERSION>`, never touches non-coco images, never force-removes in-use images
- confirms before removing

## Release
```
echo "0.2.0" > VERSION
bin/release            # commit VERSION, tag, push
bin/release --dry-run
bin/release --force    # skip semver-newer guard
```
- no-op if tag already exists
- refuses on detached HEAD or non-newer semver

## Shell / Vim
- bash: git completion, colored prompt, shows branch
- vim: syntax highlight, line numbers, incremental search

## Safety
- each coding agent's own first-run trust prompt still applies (e.g. Claude Code "Yes, I trust this folder")
- per-project mount path makes this fire correctly per project

## License
MIT — see [LICENSE](LICENSE)
