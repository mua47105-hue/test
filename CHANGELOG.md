# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1-hardened] - 2026-08-17

### Fixed

- Container gateway launch now sets `HERMES_GATEWAY_NO_SUPERVISE=1` so
  `hermes gateway run` stays a foreground child of start.sh instead of being
  handed off to s6 supervision. The s6 handoff orphaned the gateway from
  start.sh's exported `API_SERVER_KEY`, so the api_server platform never
  opened the 8642 health port and the startup readiness loop timed out
  (orderly exit 1 about 110 s after boot). The existing restart loop in
  start.sh continues to supervise the gateway.

## [2.0.0-hardened] - 2026-08-17

This release is a hardening pass for deployment on Hugging Face Spaces.
It removes all components that carry account-suspension risk and replaces
them with platform-native, policy-compliant alternatives.

### Removed

- Outbound-relay tooling (automatic worker-based connectivity workarounds) — deleted, not just disabled.
- Worker-based keep-awake automation. Replaced by an on-demand wake trigger (see README "Wake-on-Demand").
- JupyterLab terminal and its `/terminal/` route; the public web surface now exposes no interactive shell.
- NOPASSWD sudo grant for the container user.
- Interactive env-builder dashboard UI (`/env-builder`).
- The env-builder HTML/JS assets.

### Changed

- Discord replaces Telegram as the messaging platform (the Telegram API is unreachable from Spaces; Discord is not).
- The dashboard now shows Discord status instead of Telegram/keep-awake status.
- The health server forwards `/app` and `/v1/*` to local services; internal forwarding helper renamed for clarity.
- The local-server detection routines in the agent runtime now skip remote endpoints entirely, eliminating pointless probe requests against remote model gateways.
- Backup sync (`hermes-sync.py`) now filters keyword-flagged files and redacts secret-bearing values before staging snapshots for upload.
- `README.md`, `.env.example`, and `CONTRIBUTING.md` rewritten to reflect the hardened surface.

### Added

- Custom OpenAI-compatible endpoint section (`CUSTOM_BASE_URL` / `CUSTOM_API_KEY` / context-length env).
- Wake-on-demand workflow documented in the README, with an optional Discord→GitHub relay trigger.

## [1.x] - earlier releases

Earlier releases shipped the original feature set (Hermes agent gateway,
dashboard, dataset backup, startup scripts, provider mapping). Before the
2.0.0-hardened release, the project included experimental automatic
connectivity workarounds and a terminal UI that were removed in this
release for platform-compliance reasons. Feature history for those
components is intentionally not preserved in this changelog.