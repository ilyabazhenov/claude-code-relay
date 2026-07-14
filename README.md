# Relay

![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)
[![Latest release](https://img.shields.io/github/v/release/ilyabazhenov/claude-code-relay?sort=semver)](https://github.com/ilyabazhenov/claude-code-relay/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A menu-bar **dispatcher for Claude Code sessions** on macOS. Answer Claude's
approval prompts and text questions — approve/deny a risky command, type a reply —
straight from a native notification or the menu-bar icon, **without switching back to
the terminal**.

## Demo

<!--
  Drop a short screen recording (≈10s: notification → Approve/Deny → typed reply
  injected into the pane) at docs/demo.gif and uncomment the line below.
  Capture tips: docs/README.md
-->
<!-- ![Relay in action](docs/demo.gif) -->

> 📹 _Demo GIF coming soon — approve a command and answer Claude straight from the
> notification, without touching the terminal._

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

Relay's users already live in a terminal (they run Claude Code via `./cc`), so the
install is a one-liner rather than a bundled clicker. Tell colleagues:

> Open `Relay.dmg`, drag **Relay** onto **Applications**, then run this once to clear
> the download quarantine and launch it:

```bash
xattr -dr com.apple.quarantine /Applications/Relay.app && open /Applications/Relay.app
```

Without the `xattr` step, Gatekeeper blocks the ad-hoc app on another Mac with *"Relay
is damaged and can't be opened"* (and right-click → Open usually won't clear it either).

On first launch macOS asks to allow **Notifications** — approve it, or approvals and
replies can only be answered from the menu-bar icon.

Only the *first* install needs this — Sparkle updates strip quarantine themselves (see
[Auto-update](#auto-update-sparkle)).

### B) Notarize for a one-click open (needs a Developer ID)

```bash
# 1) sign with your Developer ID and package
CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/make_dmg.sh

# 2) notarize the dmg (requires an App Store Connect API key / stored credentials)
xcrun notarytool submit build/Relay.dmg --keychain-profile "AC_NOTARY" --wait

# 3) staple the ticket
xcrun stapler staple build/Relay.dmg
```

A notarized dmg opens with a normal double-click on any Mac — no `xattr`, no
quarantine dance.

---

## Auto-update (Sparkle)

Relay updates itself with [Sparkle](https://sparkle-project.org). It checks a signed
appcast once a day in the background and shows the standard *"a new version is
available"* alert — **notify, not silent**: nothing installs until you click **Install**
(`SUAutomaticallyUpdate` is `false`). There's also **Check for Updates…** in the menu and
an **Updates** section in Settings (auto-check toggle, current version, last checked).

Because Relay is ad-hoc signed (not notarized), the update's **EdDSA signature is the
sole integrity anchor** — Sparkle verifies it against `SUPublicEDKey` in `Info.plist`
before installing, and strips quarantine itself. (First install on a *new* machine still
uses the dmg + one-time `xattr` step above; auto-update only helps already-installed
users.)

**Configuration** lives in `Resources/Info.plist`: `SUFeedURL` (the appcast URL),
`SUPublicEDKey`, `SUScheduledCheckInterval`, `SUEnableAutomaticChecks`,
`SUAutomaticallyUpdate`. The framework is embedded into the hand-assembled bundle by
`scripts/build_app.sh` (copied into `Contents/Frameworks`, ad-hoc signed inside-out).

### Versioning

`./VERSION` holds the marketing version (`CFBundleShortVersionString`).
`CFBundleVersion` — the monotonic number Sparkle compares releases by — is derived from
the git commit count at build time, so **committing is what advances the build number**.

### Cutting a release

One-time: an EdDSA key pair must exist in your login keychain (check with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys -p`; its public half must match
`SUPublicEDKey`). Then:

```bash
# 1) bump ./VERSION and commit (advances CFBundleVersion)
# 2) build + zip + EdDSA-sign + regenerate appcast.xml (publishes nothing):
scripts/release.sh
# 3) follow the printed steps: create the GitHub release with the .zip asset,
#    then commit appcast.xml so SUFeedURL serves it.
```

> **arm64 only.** The SwiftPM build produces an Apple-Silicon binary, so `generate_appcast`
> marks updates `arm64`. Intel Macs won't be offered them. Build a universal binary first
> if you need Intel coverage.

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

Found a security issue? Please **don't** open a public issue — see [SECURITY.md](SECURITY.md)
for how to report it privately.

---

## Contributing

Bug reports, ideas, and PRs are welcome. Before opening a PR please run:

```bash
swift build
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, coding conventions, and how to
exercise the hooks without a long real session.

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
| `scripts/build_app.sh`            | Build + assemble the `.app` (embeds/signs Sparkle) |
| `scripts/make_dmg.sh`             | Build release + package `Relay.dmg`               |
| `scripts/release.sh`              | Zip + EdDSA-sign + regenerate `appcast.xml`       |
| `VERSION` / `appcast.xml`         | Marketing version / Sparkle update feed           |
| `Sources/Relay/Support/UpdateController.swift` | Sparkle updater wrapper              |
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
