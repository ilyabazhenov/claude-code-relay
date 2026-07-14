#!/usr/bin/env bash
# Relay status line — forwards Claude's 5h / 7d usage to the local Relay daemon and
# prints a compact readout. Fail-open: prints an empty line on any problem.
#
# NOTE: This is a reference copy. The authoritative template lives in
# Sources/Relay/Hooks/HookScripts.swift and is what the installer actually writes
# into ~/.claude/relay/statusline.sh (with @@PORT@@ / @@SECRET@@ substituted).
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
