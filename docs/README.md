# Docs & media assets

This folder holds images used by the top-level `README.md`.

## Schematic mockups (SVG)

- `mockup-panel.svg` — the menu-bar panel: usage dashboard (5-hour / weekly / peak
  cards, projection strip, peaks chart) and the state-colored session list.
- `mockup-notifications.svg` — the native approval (Approve/Deny) and reply
  (text field + quick-replies) notifications.

These are hand-drawn schematics kept in sync with the SwiftUI views under
`Sources/Relay/MenuUI/`. They use the same state colors as the app (blue working /
orange waiting-for-reply / red waiting-for-approval / gray ended). Editing: they're
plain SVG — open in any editor; preview by serving the folder
(`python3 -m http.server` from `docs/`) since browsers block `file://` SVG.

## `demo.gif` — the README demo

The README has a **Demo** section with a commented-out `![Relay in action](docs/demo.gif)`.
Record a short clip, drop it here as `demo.gif`, and uncomment that line.

### What to capture (~10 seconds)

1. A Claude Code session hits a dangerous command → Relay's **Approve/Deny** notification.
2. Click **Approve** (or **Deny**) from the notification — no terminal in sight.
3. Claude stops with a question → type a reply in the notification's text field.
4. Cut to the terminal showing the reply injected into the pane.

Keep the menu-bar icon visible if you can — it colors by session state.

### How to record

- **QuickTime Player** ▸ File ▸ New Screen Recording → record a region → trim.
- Convert to GIF (keeps the file small and auto-plays on GitHub):

  ```bash
  # with ffmpeg + gifski (brew install ffmpeg gifski)
  ffmpeg -i demo.mov -vf "fps=15,scale=900:-1:flags=lanczos" -f yuv4mpegpipe - \
    | gifski -o demo.gif -
  ```

- Aim for **≤ 5 MB** and a width around **900px** so it renders crisply in the README.

A static `screenshot.png` of the menu-bar panel is a good fallback if a GIF is too heavy.
