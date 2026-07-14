# Security Policy

Relay runs a local HTTP daemon, holds a shared secret, and can inject keystrokes into
your terminal via `tmux send-keys`. Security reports are taken seriously.

## Supported versions

Relay is pre-1.0 and ships from `main`. Only the **latest release** is supported —
please reproduce issues on it before reporting.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Instead, report privately via GitHub's
[**Report a vulnerability**](https://github.com/ilyabazhenov/claude-code-relay/security/advisories/new)
form (Security ▸ Advisories). If you can't use that, open a minimal public issue that
says only "security report, please provide a private contact" — without details — and
we'll follow up.

Please include:

- affected version (menu ▸ Settings ▸ Updates, or `VERSION`)
- macOS version
- a description of the issue and its impact
- steps to reproduce, ideally with a minimal payload against a local daemon
- any suggested fix

You can expect an initial acknowledgement within a few days. We'll keep you posted on
remediation and credit you in the release notes unless you prefer otherwise.

## Scope & threat model

Relay's design assumes a **single-user, trusted local machine**. Relevant safeguards:

- The daemon binds `127.0.0.1` only — nothing off-machine can reach it.
- Every endpoint except `GET /health` requires the `X-Relay-Secret` header. The secret
  is 32 random bytes generated on first launch, stored in `~/.claude/relay/config.json`
  and baked into the installed hook scripts.
- Hooks are **fail-open**: if the daemon is unreachable or an approval times out, they
  exit non-blocking so Claude Code proceeds as if Relay weren't installed.

Reports especially of interest:

- ways for another **local** process (without the secret) to drive Relay, read the
  secret, or trigger a reply/approval injection;
- the secret leaking into logs, process listings, or world-readable files;
- an approval flow that could be tricked into auto-allowing a dangerous command;
- text injection into a session that is not in a `waiting_*` state.

Out of scope: attacks that require an already-compromised local account with the same
privileges as the user running Relay (they already have your terminal and files).
