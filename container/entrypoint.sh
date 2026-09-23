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
sudo mkdir -p "$HOME"
sudo chown -R coco:coco "$HOME"

# ~/.claude is bind-mounted as a directory; ~/.claude.json lives inside it
# (as claude.json) and is symlinked here, so claude's atomic config writes
# (temp file + rename) stay on one filesystem instead of hitting EXDEV
# against a directly-bind-mounted single file.
if [ -d "$HOME/.claude" ]; then
  ln -sf .claude/claude.json "$HOME/.claude.json"
fi

if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  git config --global user.email "$GIT_AUTHOR_EMAIL"
fi

exec "$@"
