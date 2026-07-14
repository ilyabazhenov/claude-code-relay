# Relay

A menu-bar **dispatcher for Claude Code sessions** on macOS. Answer Claude's
approval prompts and text questions — approve/deny a risky command, type a reply —
straight from a native notification or the menu-bar icon, **without switching back to
the terminal**.

> Status: M0–M4 implemented. Skeleton, session tracking, blocking approvals, tmux
> reply injection, and polish (quick replies, settings, focus, `.dmg`).

---

## How it works

```
Claude Code (running inside tmux)
   │  hooks: PreToolUse / Stop / Notification / SessionStart / SessionEnd
   ▼
hook scripts (bash + curl + python3)  ──POST──►  Relay daemon (in the .app, 127.0.0.1)
                                                     │
                                    ┌────────────────┼──────────────────┐
                                    ▼                ▼                  ▼
                             Menu-bar UI       Native notifications   tmux send-keys
                             (session list,    (Approve/Deny +        (inject the reply
                              cards, replies)   text field)            into the pane)
```

- The daemon is a small HTTP server **bound to `127.0.0.1` only** (loopback), on a
  free port chosen at first launch and saved to `~/.claude/relay/config.json`.
- Every hook request carries a **shared secret** (`X-Relay-Secret`) that Relay
  generates and bakes into the installed hook scripts. Requests without it are
  rejected `401`. This keeps other local processes from driving Relay.
- Injecting text replies uses `tmux send-keys`, so Claude Code must run inside tmux
  (use the bundled [`cc`](cc) wrapper).

### Per-session state machine

```
working ──Stop──────────▶ waiting_text
working ──PreToolUse────▶ waiting_approval
waiting_* ──answer────▶ working
any ──SessionEnd───────▶ ended
```

Text is only ever injected while a session is in a `waiting_*` state — never while
it is `working` (that would corrupt the running session).

---

## Requirements

- macOS 14+ (Sonoma or newer), Xcode command-line tools / Swift 6.
- **tmux** — needed for reply injection (M3) and by the `cc` wrapper.
  `brew install tmux`
- Claude Code, with permission granted to Relay to post **Notifications** (M2/M3).
- Hook scripts rely only on `bash`, `curl`, `python3` — all present on a clean macOS.

---

## Build & run

```bash
./scripts/build_app.sh debug     # or: release
open build/Relay.app             # menu-bar icon appears (no Dock icon)
```

Install the Claude Code hooks (either the **Install hooks** button in the menu, or
headless):

```bash
build/Relay.app/Contents/MacOS/Relay --install-hooks
# later:
build/Relay.app/Contents/MacOS/Relay --uninstall-hooks
```

Then run Claude Code through the wrapper so hooks always see a tmux pane:

```bash
./cc            # == tmux + claude
```

The first time a notification fires, macOS asks you to allow notifications for Relay
— approve it, or approvals/replies can only be answered from the menu.

---

## Features

- **Menu-bar session list** — every Claude Code session by project name, colored by
  state (blue working / orange waiting-for-reply / red waiting-for-approval / gray
  ended), waiting ones on top.
- **Approvals** — dangerous commands (configurable rules) raise a native
  Approve/Deny notification and an inline card; safe commands auto-allow (toggle in
  Settings).
- **Text replies** — when Claude stops with a question, answer from the notification's
  text field, a **quick-reply** button (`yes` / `continue` / `option 2`, configurable),
  or the menu — injected into the session via `tmux send-keys`. A double-answer lock
  dismisses the card after the first reply.
- **Focus** — click a session to bring its terminal (and tmux pane) to the front.
- **Settings** window — launch at login, port, danger rules, quick replies, approval
  behavior, and notification toggles.
- **Launch at login** — a General toggle registers Relay as a login item via
  `SMAppService` (macOS 13+), so it starts automatically when you log in. macOS may ask
  you to confirm it under System Settings ▸ General ▸ Login Items the first time.

---

## Packaging & distribution

Build a `.dmg`:

```bash
scripts/make_dmg.sh                # ad-hoc signed; build/Relay.dmg
```

The app is **ad-hoc signed, not notarized**. That's fine on the machine that built
it, but Gatekeeper rejects an ad-hoc app once it carries the download-quarantine flag
— on another Mac a double-click shows *"Relay is damaged and can't be opened"*, and
right-click → Open usually won't clear it either. Two ways to hand it to colleagues:

### A) Share the `.dmg` (no Apple Developer account)

The dmg ships an **`Install.command`** alongside `Relay.app`. Tell colleagues:

> Open `Relay.dmg`, double-click **Install.command**, and click **Open** when macOS
> asks. It copies Relay to `/Applications`, strips the quarantine flag, and launches
> it.

Prefer the terminal? The equivalent one-liner after dragging Relay to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/Relay.app && open /Applications/Relay.app
```

On first launch macOS asks to allow **Notifications** — approve it, or approvals and
replies can only be answered from the menu-bar icon.

### B) Notarize for a one-click open (needs a Developer ID)

```bash
# 1) sign with your Developer ID and package
CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/make_dmg.sh

# 2) notarize the dmg (requires an App Store Connect API key / stored credentials)
xcrun notarytool submit build/Relay.dmg --keychain-profile "AC_NOTARY" --wait

# 3) staple the ticket
xcrun stapler staple build/Relay.dmg
```

A notarized dmg opens with a normal double-click on any Mac — no `Install.command`,
no quarantine dance.

---

## Claude Code hook integration (verified schema)

> The hook mechanics and JSON schemas evolve. This section records the schema Relay
> currently builds on (verified against the official Hooks docs). If the docs and
> this disagree, trust the docs and adjust `Sources/Relay/Hooks/HookScripts.swift`
> and `HooksInstaller.swift`.

**Config** is merged into `~/.claude/settings.json` under `hooks`, grouped by event
and (for tool events) `matcher`. Relay never clobbers existing user hooks — it takes
a timestamped backup (`settings.json.relay-backup-…`) and inserts/updates only its
own entries (identified by the `~/.claude/relay/` script path). Uninstall removes
exactly those.

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "~/.claude/relay/event.sh", "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/relay/pretooluse.sh", "timeout": 300 } ] }
    ]
  }
}
```

**Hook stdin** (JSON) — common fields: `session_id`, `transcript_path`, `cwd`,
`permission_mode`, `hook_event_name`. Per-event extras Relay uses:

| Event          | Extra fields Relay reads                         |
| -------------- | ------------------------------------------------ |
| `SessionStart` | `source`                                         |
| `SessionEnd`   | `reason`                                         |
| `Stop`         | `last_assistant_message` (the full reply text)   |
| `Notification` | `message`                                        |
| `PreToolUse`   | `tool_name`, `tool_input` (e.g. `.command`)      |

Inside tmux the hook process inherits `TMUX_PANE` — Relay forwards it so replies can
be routed back to the exact pane.

**PreToolUse control output** (M2) — the hook prints on stdout:

```json
{ "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow" | "deny" | "ask",
    "permissionDecisionReason": "…"
} }
```

Exit-code semantics Relay relies on: `0` = stdout JSON is applied; `2` = hard block
(stderr shown to Claude); **any other code = non-blocking** — this is Relay's
**fail-open** path if the daemon is unreachable or times out, so Relay can never
brick Claude Code.

---

## Security model

- **Loopback only.** The server binds `127.0.0.1`; nothing off-machine can reach it.
- **Shared secret.** 32 random bytes generated on first launch, stored in
  `~/.claude/relay/config.json` and baked into the hook scripts. Every request but
  `/health` must present it.
- **Fail-open.** If the daemon is down or an approval times out, hooks exit
  non-blocking so Claude Code proceeds as if Relay weren't installed. These cases are
  logged to `~/.claude/relay/relay.log`.

---

## Testing without a long real session

Use the fixtures to drive the installed hooks directly:

```bash
build/Relay.app/Contents/MacOS/Relay --install-hooks
fixtures/emit.sh session_start_alpha.json %1
fixtures/emit.sh session_start_beta.json  %2
fixtures/emit.sh stop_alpha.json          %1
# inspect the registry:
PORT=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/relay/config.json')))['port'])")
SECRET=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude/relay/config.json')))['secret'])")
curl -s -H "X-Relay-Secret: $SECRET" http://127.0.0.1:$PORT/sessions | python3 -m json.tool
```

See [`fixtures/`](fixtures/) for the full set of sample payloads.

---

## Project layout

| Path                              | What                                              |
| --------------------------------- | ------------------------------------------------- |
| `Sources/Relay/Server/`           | Loopback HTTP server + daemon/router              |
| `Sources/Relay/SessionStore/`     | Session model, registry, hook-event parsing       |
| `Sources/Relay/Approvals/`        | Danger rules, blocking approval coordinator, auth |
| `Sources/Relay/Notifications/`    | Native notifications + actions                    |
| `Sources/Relay/Tmux/`             | `tmux send-keys` injection, transcript, focus     |
| `Sources/Relay/Hooks/`            | Hook-script templates + settings.json installer   |
| `Sources/Relay/MenuUI/`           | `MenuBarExtra` UI + Settings window               |
| `hooks/`                          | Reference copies of the installed hook scripts    |
| `fixtures/`                       | Sample hook payloads + `emit.sh` emulator         |
| `scripts/build_app.sh`            | Build + assemble the `.app` bundle                |
| `scripts/make_dmg.sh`             | Build release + package `Relay.dmg`               |
| `cc`                              | Wrapper: run Claude Code inside tmux              |

### HTTP endpoints (all but `/health` require `X-Relay-Secret`)

| Endpoint          | Purpose                                                        |
| ----------------- | ------------------------------------------------------------- |
| `GET /health`     | Liveness probe → `ok`                                          |
| `POST /event`     | Lifecycle events (SessionStart/End, Stop, Notification)       |
| `POST /approve`   | Blocking PreToolUse approval; returns the hook decision JSON  |
| `POST /reply`     | Inject a text reply into a waiting session                    |
| `GET /sessions`   | Debug: session registry snapshot                              |
| `GET /pending`    | Debug: pending approvals                                      |
| `POST /resolve`   | Debug: resolve an approval (simulates a button press)         |
| `POST /usage`     | Usage update from the status-line script (5h / weekly percent + reset) |
| `GET /usage`      | Debug: latest 5h / weekly usage snapshot                      |
| `GET /usage/history` | Debug: accumulated usage series + completed windows        |
