#!/usr/bin/env bash
# Relay lifecycle hook — forwards SessionStart/SessionEnd/Stop/Notification to the
# local Relay daemon. Fail-open: never blocks Claude Code.
#
# NOTE: This is a reference copy. The authoritative template lives in
# Sources/Relay/Hooks/HookScripts.swift and is what the installer actually writes
# into ~/.claude/relay/event.sh (with @@PORT@@ / @@SECRET@@ substituted).
set -u

PORT="@@PORT@@"
SECRET="@@SECRET@@"

INPUT="$(cat)"

# Build the daemon payload with python3 (no jq dependency). TMUX_PANE comes from the
# environment the hook inherits inside tmux.
PAYLOAD="$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
out = {
    "event": data.get("hook_event_name", ""),
    "session_id": data.get("session_id", ""),
    "cwd": data.get("cwd", ""),
    "tmux_pane": os.environ.get("TMUX_PANE", ""),
    "transcript_path": data.get("transcript_path", ""),
    "last_assistant_message": data.get("last_assistant_message", ""),
    "message": data.get("message", ""),
    "source": data.get("source", ""),
    "reason": data.get("reason", ""),
    "prompt": data.get("prompt", ""),
}
sys.stdout.write(json.dumps(out))
' 2>/dev/null)"

printf '%s' "$PAYLOAD" | curl -s --max-time 3 \
  -X POST "http://127.0.0.1:${PORT}/event" \
  -H "X-Relay-Secret: ${SECRET}" \
  -H "Content-Type: application/json" \
  --data-binary @- >/dev/null 2>&1 || true

exit 0
