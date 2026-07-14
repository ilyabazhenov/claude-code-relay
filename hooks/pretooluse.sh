#!/usr/bin/env bash
# Relay PreToolUse hook — routes tool calls through the Relay daemon for approval.
# Fail-open: prints nothing and exits 0 on any error/timeout.
#
# NOTE: Reference copy. The authoritative template lives in
# Sources/Relay/Hooks/HookScripts.swift and is what the installer writes into
# ~/.claude/relay/pretooluse.sh (with @@PORT@@ / @@SECRET@@ substituted).
set -u

PORT="@@PORT@@"
SECRET="@@SECRET@@"

INPUT="$(cat)"

REQ="$(printf '%s' "$INPUT" | python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
ti = data.get("tool_input") or {}
cmd = ti.get("command")
if cmd is None:
    try:
        cmd = json.dumps(ti)
    except Exception:
        cmd = ""
out = {
    "session_id": data.get("session_id", ""),
    "cwd": data.get("cwd", ""),
    "tmux_pane": os.environ.get("TMUX_PANE", ""),
    "tool_name": data.get("tool_name", ""),
    "command": cmd or "",
}
sys.stdout.write(json.dumps(out))
' 2>/dev/null)"

# --max-time must exceed the daemon's internal wait, so the daemon decides the
# timeout (empty body) rather than curl aborting mid-decision.
RESP="$(printf '%s' "$REQ" | curl -s --max-time 300 \
  -X POST "http://127.0.0.1:${PORT}/approve" \
  -H "X-Relay-Secret: ${SECRET}" \
  -H "Content-Type: application/json" \
  --data-binary @- 2>/dev/null)"

if [ -n "$RESP" ]; then
  printf '%s' "$RESP"
fi
exit 0
