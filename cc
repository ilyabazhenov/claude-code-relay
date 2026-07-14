#!/usr/bin/env bash
#
# cc — launch Claude Code inside a named tmux session so Relay's hooks always see a
# TMUX_PANE (which Relay needs to inject replies back into the session).
#
# - Already inside tmux? Just run `claude` as-is.
# - Not in tmux? Start a fresh named tmux session running `claude`.
# - tmux missing? Explain how to fix it.

set -euo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "cc: 'claude' (Claude Code) was not found in PATH." >&2
  echo "    Install Claude Code first: https://code.claude.com" >&2
  exit 127
fi

# Inside tmux already: TMUX_PANE is set for us, so hooks work — just run claude.
if [[ -n "${TMUX:-}" ]]; then
  exec claude "$@"
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "cc: tmux is not installed, so Relay can't inject replies into this session." >&2
  echo "    Install it with:  brew install tmux" >&2
  echo "    (or run 'claude' directly to work without Relay reply-injection)." >&2
  exit 127
fi

# Build a safely-quoted command string for tmux.
CMD="claude"
for arg in "$@"; do
  CMD+=" $(printf '%q' "$arg")"
done

# Unique, filesystem-safe session name derived from the current directory.
BASE="$(basename "$PWD" | tr -cd '[:alnum:]-_')"
SESSION="cc-${BASE:-session}-$$"

exec tmux new-session -s "$SESSION" "$CMD"
