# Contributing to Relay

Thanks for taking the time to contribute! Relay is a native macOS menu-bar app written
in Swift (SwiftPM), so contributing needs a Mac.

## Prerequisites

- macOS 14+ (Sonoma or newer)
- Swift 6 toolchain (Xcode command-line tools)
- `tmux` (`brew install tmux`) — required to exercise reply injection

## Build & test

```bash
swift build            # compile the package
swift test             # run the test suite
```

To build and run the actual app bundle:

```bash
./scripts/build_app.sh debug     # or: release
open build/Relay.app
```

Please make sure `swift build` and `swift test` both pass before opening a PR.

## Exercising the hooks without a long real session

You don't need to run a full Claude Code session to test lifecycle behavior — drive the
installed hooks directly with the fixtures:

```bash
build/Relay.app/Contents/MacOS/Relay --install-hooks
fixtures/emit.sh session_start_alpha.json %1
fixtures/emit.sh stop_alpha.json          %1
```

See [`fixtures/`](fixtures/) for the full set of sample payloads and the README's
"Testing without a long real session" section for inspecting the registry.

## Coding conventions

- Match the style of the surrounding code — naming, spacing, and comment density.
- Keep changes focused; unrelated cleanups belong in their own PR.
- The daemon is loopback-only and auth-gated — don't loosen the security model
  (`127.0.0.1` bind, `X-Relay-Secret`, fail-open hooks) without discussing it first.
- New behavior that can be unit-tested should come with a test under
  `Tests/RelayTests/`.

## Pull requests

1. Fork and create a topic branch off `main`.
2. Make your change with a clear commit history.
3. Run `swift build && swift test`.
4. Open a PR describing **what** changed and **why**. Link any related issue.
5. Screenshots or a short clip are very welcome for UI changes.

## Reporting bugs & requesting features

Use the issue templates — pick **Bug report** or **Feature request** when you open a new
issue. For security problems, follow [SECURITY.md](SECURITY.md) instead of filing a
public issue.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
