#!/bin/bash
set -e

XDEBUG_INI="/etc/php.d/15-xdebug.ini"
if [ -f "$XDEBUG_INI" ]; then
  if [ "${XDEBUG_ENABLE:-0}" = "1" ]; then
    MODE="develop,debug"
  else
    MODE="off"
  fi
  if sudo grep -q '^\s*xdebug\.mode\s*=' "$XDEBUG_INI"; then
    sudo sed -i "s/^\s*xdebug\.mode\s*=.*/xdebug.mode=$MODE/" "$XDEBUG_INI"
  else
    echo "xdebug.mode=$MODE" | sudo tee -a "$XDEBUG_INI" >/dev/null
  fi
fi

# $HOME now points at the host's own home path (see bin/coco), so that
# agent configs cached with absolute host paths (e.g. claude's plugin
# marketplace install locations) still resolve in-container. docker
# auto-creates bind-mount parent dirs but doesn't guarantee ownership, so
# make sure coco actually owns its home before anything writes into it.
# Recursion is required, not just the top-level dir: bind-mount parents
# created by the runtime (~/.config and ~/.local/share for opencode's
# mounts) and the image's root-built ~/.local (claude install, see
# Dockerfile) are root-owned, so without it agents hit EACCES creating
# dirs under them. But never recurse into the bind mounts themselves (the
# project dir, ~/.claude, caches, ...): they are host-owned, and chown
# there is at best a slow no-op and on docker/macOS a wall of "Permission
# denied" that aborts the entrypoint. -xdev stops the descent at the mount
# boundary; the mountpoint prune skips the mount root itself.
sudo mkdir -p "$HOME"
sudo find "$HOME" -xdev -type d -exec mountpoint -q {} \; -prune -o -exec chown -h coco:coco {} +

# ~/.claude is bind-mounted as a directory; ~/.claude.json lives inside it
# (as claude.json) and is symlinked here, so claude's atomic config writes
# (temp file + rename) stay on one filesystem instead of hitting EXDEV
# against a directly-bind-mounted single file.
if [ -d "$HOME/.claude" ]; then
  ln -sf .claude/claude.json "$HOME/.claude.json"
fi

# hermes (baked into the image, see Dockerfile): its committed dependency
# environment is recorded per checkout under
# $HOME/.hermes/installs/<sha256(checkout path)> -- and $HOME/.hermes is
# hermes's host bind mount, so on a host where hermes is newly selected
# the record is missing and hermes has no venv until it provisions once.
# Do that one-time provisioning here instead of letting the user's first
# `hermes` invocation build it: the probe is a cheap read of PM's record
# via the store's managed python (no network), and the repair is
# near-offline -- the uv package cache ships seeded beside the store and
# pm merges it into its own cache on first use. Best effort: if it can't
# finish now (no network), hermes self-provisions on first use anyway.
if [ -x "$HOME/.local/bin/hermes" ]; then
  _hrt="${HERMES_RUNTIME_DIR:-$HOME/.local/share/hermes/tools}"
  _hrepo="$HOME/.local/share/hermes/hermes-agent"
  _hpy="$(ls -d "${_hrt}"/python-*/bin/python3 2>/dev/null | head -n 1)"
  if [ -n "${_hpy}" ] && [ -f "${_hrepo}/uv.lock" ] \
      && ! "${_hpy}" -I -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from pm.environments import committed_venv
sys.exit(0 if committed_venv(Path(sys.argv[1])) is not None else 1)
' "${_hrepo}" >/dev/null 2>&1
  then
    if "$HOME/.local/bin/hermes" pm repair >/dev/null 2>&1; then
      echo "hermes: dependency environment provisioned (first run on this host)"
    else
      echo "hermes: first-run provisioning deferred; it will finish on first use" >&2
    fi
  fi
fi

if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  git config --global user.email "$GIT_AUTHOR_EMAIL"
fi

# host loopback ports as localhost:<port>. pasta does this natively for
# rootless podman; docker and rootful podman only hand out the host alias
# (bridge gateway, see bin/coco), so bridge each port over socat instead.
# bind=127.0.0.1 keeps the listeners container-local. stderr dropped: a
# per-connection "Connection refused" (host service down) would scribble
# over the agent's TUI.
if [ -n "${COCO_HOST_ALIAS:-}" ]; then
  for p in ${COCO_HOST_PORTS//,/ }; do
    for port in $(seq "${p%-*}" "${p#*-}"); do
      socat TCP-LISTEN:"$port",bind=127.0.0.1,fork,reuseaddr TCP:"$COCO_HOST_ALIAS:$port" 2>/dev/null &
    done
  done
fi

exec "$@"
