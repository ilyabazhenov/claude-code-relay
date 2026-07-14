#!/usr/bin/env bash
#
# emit.sh — emulate a Claude Code hook firing, by piping a fixture JSON into the
# installed Relay hook script. Lets you exercise Relay without a long real session.
#
# Usage:
#   fixtures/emit.sh <fixture.json> [TMUX_PANE]
#
# Examples:
#   fixtures/emit.sh session_start_alpha.json
#   fixtures/emit.sh pretooluse_dangerous.json %3
#
# The event is routed to the right installed script based on hook_event_name:
#   PreToolUse -> ~/.claude/relay/pretooluse.sh   (blocking; prints the decision JSON)
#   others     -> ~/.claude/relay/event.sh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: fixtures/emit.sh <fixture.json> [TMUX_PANE]" >&2
  exit 2
fi

FIXTURE="$1"
PANE="${2:-%1}"
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "$FIXTURE" = /* ]] || FIXTURE="$DIR/$FIXTURE"

if [[ ! -f "$FIXTURE" ]]; then
  echo "emit.sh: fixture not found: $FIXTURE" >&2
  exit 1
fi

EVENT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hook_event_name",""))' "$FIXTURE")"

case "$EVENT" in
  PreToolUse) SCRIPT="$HOME/.claude/relay/pretooluse.sh" ;;
  *)          SCRIPT="$HOME/.claude/relay/event.sh" ;;
esac

if [[ ! -x "$SCRIPT" ]]; then
  echo "emit.sh: hook script not installed/executable: $SCRIPT" >&2
  echo "         Run 'Install hooks' in the menu, or: build/Relay.app/Contents/MacOS/Relay --install-hooks" >&2
  exit 1
fi

echo "==> $EVENT  ->  $SCRIPT   (TMUX_PANE=$PANE)"
TMUX_PANE="$PANE" "$SCRIPT" < "$FIXTURE"
STATUS=$?
echo
echo "[hook exit status: $STATUS]"
