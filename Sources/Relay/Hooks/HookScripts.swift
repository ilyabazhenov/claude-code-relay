import Foundation

/// Canonical text of the hook scripts Relay installs into `~/.claude/relay/`.
///
/// These are the single source of truth (the repo's `hooks/` folder holds reference
/// copies). Only `bash`, `curl`, and `python3` are used — nothing that isn't on a
/// clean macOS. `@@PORT@@` and `@@SECRET@@` are substituted at install time.
enum HookScripts {
    static let portPlaceholder = "@@PORT@@"
    static let secretPlaceholder = "@@SECRET@@"

    /// Handles the lifecycle events SessionStart / SessionEnd / Stop / Notification.
    /// Reads Claude Code's hook JSON on stdin, augments it with `TMUX_PANE`, and
    /// POSTs a normalized payload to the daemon. Always fail-open (exit 0).
    static let eventScript = #"""
#!/usr/bin/env bash
# Relay lifecycle hook — forwards SessionStart/SessionEnd/Stop/Notification to the
# local Relay daemon. Fail-open: never blocks Claude Code.
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
"""#

    /// PreToolUse approval hook. Asks the daemon whether a tool call may run, blocking
    /// until the user decides (or the daemon times out). Fail-open: on any error,
    /// empty response, or timeout, it prints nothing and exits 0, so Claude Code's
    /// normal permission flow applies and Relay can never brick a session.
    static let preToolUseScript = #"""
#!/usr/bin/env bash
# Relay PreToolUse hook — routes tool calls through the Relay daemon for approval.
# Fail-open: prints nothing and exits 0 on any error/timeout.
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
    # Non-Bash tool: fall back to a compact JSON summary of the input.
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

# --max-time must be greater than the daemon's internal wait, so the daemon decides
# the timeout (returning an empty body) rather than curl aborting mid-decision.
RESP="$(printf '%s' "$REQ" | curl -s --max-time 300 \
  -X POST "http://127.0.0.1:${PORT}/approve" \
  -H "X-Relay-Secret: ${SECRET}" \
  -H "Content-Type: application/json" \
  --data-binary @- 2>/dev/null)"

# Non-empty response = a decision to emit; empty = passthrough (fail-open).
if [ -n "$RESP" ]; then
  printf '%s' "$RESP"
fi
exit 0
"""#

    /// Status-line script. Claude Code pipes the status-line JSON (which includes
    /// `rate_limits.five_hour` / `.seven_day` for Claude.ai Pro/Max) to this on stdin
    /// each time it refreshes. We forward the usage figures to the daemon and print a
    /// compact readout for the terminal status line. Fail-open: never errors the line.
    static let statuslineScript = #"""
#!/usr/bin/env bash
# Relay status line — forwards Claude's 5h / 7d usage to the local Relay daemon and
# prints a compact readout. Fail-open: prints an empty line on any problem.
set -u

PORT="@@PORT@@"
SECRET="@@SECRET@@"

INPUT="$(cat)"

# Extract usage with python3 (no jq dependency). Emits two lines:
#   line 1: JSON payload for the daemon, or "-" when no rate_limits are present
#   line 2: compact display string for the terminal, or empty
OUT="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
rl = d.get("rate_limits") or {}
fh = rl.get("five_hour") or {}
sd = rl.get("seven_day") or {}
def num(x):
    return x if isinstance(x, (int, float)) else None
fhp, sdp = num(fh.get("used_percentage")), num(sd.get("used_percentage"))
payload = {}
if fhp is not None:
    payload["five_hour_percent"] = fhp
    if num(fh.get("resets_at")) is not None: payload["five_hour_reset_epoch"] = fh["resets_at"]
if sdp is not None:
    payload["seven_day_percent"] = sdp
    if num(sd.get("resets_at")) is not None: payload["seven_day_reset_epoch"] = sd["resets_at"]
parts = []
if fhp is not None: parts.append("5h %d%%" % round(fhp))
if sdp is not None: parts.append("7d %d%%" % round(sdp))
disp = ("» " + " · ".join(parts)) if parts else ""
sys.stdout.write((json.dumps(payload) if payload else "-") + "\n" + disp)
' 2>/dev/null)"

PAYLOAD="$(printf '%s\n' "$OUT" | sed -n '1p')"
DISPLAY="$(printf '%s\n' "$OUT" | sed -n '2p')"

if [ -n "$PAYLOAD" ] && [ "$PAYLOAD" != "-" ]; then
  printf '%s' "$PAYLOAD" | curl -s --max-time 2 \
    -X POST "http://127.0.0.1:${PORT}/usage" \
    -H "X-Relay-Secret: ${SECRET}" \
    -H "Content-Type: application/json" \
    --data-binary @- >/dev/null 2>&1 || true
fi

printf '%s' "$DISPLAY"
exit 0
"""#

    /// Renders a script with the live port and secret baked in.
    static func render(_ template: String, port: Int, secret: String) -> String {
        template
            .replacingOccurrences(of: portPlaceholder, with: String(port))
            .replacingOccurrences(of: secretPlaceholder, with: secret)
    }
}
