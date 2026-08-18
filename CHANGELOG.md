# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.6] - 2026-08-18

### Added / Fixed — capability un-blocking

- **Auxiliary LLM routes wired to Zen** (fixes Hermes's "no auxiliary LLM
  provider configured" + "cannot read images"). config-gen now writes
  `auxiliary.vision` → `mimo-v2.5-free` (the multimodal model), and
  `auxiliary.compression` / `auxiliary.web_extract` → `deepseek-v4-flash-free`,
  each as `provider: custom` + Zen `base_url` + `placeholder` key.
- **Top-level `model.extra_headers`** (empty `Authorization` + OpenCode
  `User-Agent`) so auxiliary calls merge the same Zen headers the main
  client uses — otherwise vision/compression would send a default Bearer +
  OpenAI UA and get 401/429 from Zen (verified via
  `resolve_vision_provider_client`: base_url Zen, model mimo, headers correct).
- **Web search re-enabled for free**: `ddgs` (DuckDuckGo, keyless) installed
  at build time and `web.search_backend: ddgs` set when no key-based backend
  is configured. Live search verified in-container.
- **Deeper subagent nesting**: `delegation.max_spawn_depth` raised 1→2
  (overridable via `HERMES_MAX_SPAWN_DEPTH`), un-blocking orchestrator→leaf
  chains.
- **Browser determinism**: `browser.backend` forced to built-in (agent-browser)
  tools instead of the browser-use/uvx auto path, plus `AGENT_BROWSER_ARGS`
  (`--no-sandbox,--disable-dev-shm-usage`) and `AGENT_BROWSER_EXECUTABLE_PATH`
  (`/usr/bin/chromium`) so local Chromium starts reliably in the root
  container with the 64MB `/dev/shm`.

## [2.0.5-hardened] - 2026-08-18

### Added / Fixed

- **Full OpenCode Zen model catalog.** When no model secrets are set,
  config-gen now writes the complete Zen integration, not just the default
  model: a `custom_providers` list (the legacy format the context resolver
  reads at step 0c) with explicit per-model `context_length` for all six
  free models (`deepseek-v4-flash-free` 256000, `nemotron-3-ultra-free`/
  `mimo-v2.5-free`/`big-pickle` 128000, `hy3-free`/`laguna-s-2.1-free`
  64000), plus `discover_models: false`, `api_mode: chat_completions`, and
  the `extra_headers` (empty `Authorization` + OpenCode `User-Agent`) in
  both the `providers.custom` (keyed) and `custom_providers` (list) blocks.
  Every model has an explicit context window, so a `/model` switch never
  falls through to endpoint probing.
- **`MALLOC_ARENA_MAX=2`** in the image ENV to reduce glibc malloc-arena
  fragmentation in the multi-threaded gateway (lowers steady-state RSS).
- **Bytecode cache cleared at build time** after the source patches so the
  patched `model_metadata.py` is guaranteed to recompile on first import.
- **`/status` now reports memory** (`memory` object: cgroup limit/usage,
  host MemTotal/MemAvailable, and top processes by RSS) for diagnosing the
  HF out-of-memory banner.

Verified locally: probe-suppression trap test passes (0 HTTP requests),
`hermes -z` PONG test succeeds for `deepseek-v4-flash-free` and
`nemotron-3-ultra-free`.

## [2.0.4-hardened] - 2026-08-18

### Fixed

- **api_server now always binds 8642 even on a stale volume.** Two new
  blockers surfaced on the live Space after 2.0.3 (root-caused from the
  runtime logs + base-image source):
  - An old `config.yaml` (the Space volume predates config version 12)
    can carry `platforms.api_server.enabled: false`, which sets the
    loader's `_enabled_explicit` marker and keeps the platform disabled
    even with a valid `API_SERVER_KEY` (gateway/config.py). `start.sh`
    config-gen now force-overwrites the api_server block (`enabled:
    true` + key/host/port in `extra`) instead of setdefault-merge, and
    defensively coerces `model`/`platforms` to dicts so an old or
    corrupt YAML can never crash config-gen under `set -e`.
  - A short `GATEWAY_TOKEN` (< 16 chars) fails the api_server platform's
    `has_usable_secret` guard, leaving 8642 closed. `start.sh` now
    enforces a strong key for the boot (warns to fix GATEWAY_TOKEN), and
    the health-server accepts either `API_SERVER_KEY` or `GATEWAY_TOKEN`
    for dashboard/API auth so the user's login keeps working.
- **Zen fallback model injected when no model secrets are set.** The
  Space had no `LLM_MODEL`/`CUSTOM_BASE_URL` secrets, so the gateway had
  no model route. When env is unset, config-gen now writes the Zen
  fallback (`deepseek-v4-flash-free` via `https://opencode.ai/zen/v1`,
  placeholder key, explicit `context_length: 131072`,
  `discover_models: false`, `extra_headers` per `config.zen.example.yaml`)
  so the gateway serves out of the box; env still wins when set later.
- **Dashboard restored for `/app/`.** `start_dashboard_once` is re-enabled
  (loopback bind on 9119 via `hermes dashboard --host 127.0.0.1 --no-open`)
  so the health-server's `/app/` route has a backend — the base image's
  s6 dashboard service stays down (HERMES_DASHBOARD unset), so there is no
  port conflict. Previously `/app/` returned `forward_error connect
  ECONNREFUSED 127.0.0.1:9119`.

Verified locally against a poisoned volume (ancient `config.yaml` with
`api_server.enabled: false`, empty `API_SERVER_KEY` in `.env`,
`gateway_state.json=running`, short GATEWAY_TOKEN, no model env): boots
healthy, `/health` → `gateway:true`, 8642 bound, `/app/` serves the Hermes
SPA (200 with token, 302 without), and a restart cycle stays healthy.

## [2.0.3-hardened] - 2026-08-18

### Fixed

- **Root cause of the persistent 90-120 s death loop (finally):** the base
  image's container-boot reconciler (`02-reconcile-profiles` →
  `container_boot.reconcile_profile_gateways`) auto-starts an
  s6-supervised `gateway-default` slot on every boot whenever
  `$HERMES_HOME/gateway_state.json` says `running` — and the running
  gateway persists exactly that while it serves, so every boot after the
  first re-created the race. The s6-spawned gateway only sees
  `/run/s6/container_environment` (never start.sh's runtime exports, and
  `API_SERVER_KEY` is not an HF secret), so it never opened the 8642
  api_server port (log signature: `No messaging platforms enabled`, no
  `API server listening` line), and it raced the direct launch — the
  double-run guard made start.sh's gateway bow out, the readiness loop
  timed out, and the container exited 1. Fixes:
  - New `scripts/99-huggingmes-gateway-owner` cont-init script runs after
    the base reconciler and downs the `gateway-default` slot plus pins
    `desired_state: stopped` in `gateway_state.json` — the reconciler
    honours `desired_state` verbatim, so the slot registers DOWN on every
    subsequent boot and the env-starved s6 gateway never starts.
    Mirrors `GATEWAY_TOKEN` into s6's `container_environment` when set.
  - `start.sh` re-asserts the slot-down + state pin defensively at boot
    (covers images built without the cont-init script), exports
    `HERMES_GATEWAY_NO_SUPERVISE=1`, and force-rewrites
    `API_SERVER_KEY`/`API_SERVER_ENABLED`/`API_SERVER_HOST`/
    `API_SERVER_PORT` in `$HERMES_HOME/.env` instead of append-if-missing:
    the gateway loads that persistent file with `override=True`, so a
    stale/empty `API_SERVER_KEY=` left in the volume from an older deploy
    silently beat the process env and disabled api_server (a second,
    independent way to reproduce the same death loop). The deprecated
    `TERMINAL_CWD` line is dropped from `.env` as well.
  - `Dockerfile` sets `HERMES_GATEWAY_NO_SUPERVISE=1` in the image ENV and
    ships the cont-init script.
- `kanban.max_in_progress` is now written to config.yaml (default 4,
  `HERMES_KANBAN_MAX_IN_PROGRESS` overrides). The base image derives a
  default from the SHARED host's `/proc/meminfo` and logged `system memory
  pressure is critical` every tick on loaded HF hosts, which read like a
  crash cause in the runtime logs; an explicit value makes dispatch
  deterministic and silences the warnings.

Verified end-to-end locally: poisoned `.env` + `gateway_state.json=running`
volume boots healthy (`/health` → `gateway:true`), survives past the old
120 s death window, and a `docker restart` reconciles to
`prior_state=stopped action=registered` with the gateway still healthy.

## [2.0.2-hardened] - 2026-08-18

### Fixed

- Gateway is now launched via its runtime module directly (`python3 -m
  gateway.run` with the venv interpreter), bypassing the `hermes` CLI layer.
  The container image intercepts `hermes gateway run` and hands the gateway
  to s6-supervise, which drops start.sh's exported env — so the api_server
  platform never opened the 8642 readiness port and the startup wait loop
  exited 1 about two minutes after boot. The direct module launch keeps the
  gateway a plain foreground child of start.sh (inherits `API_SERVER_KEY`;
  the restart loop still supervises it).
- `API_SERVER_KEY` is also published into `HERMES_HOME/.env` (idempotent,
  mode 600) so any gateway process — including an s6-spawned one — can find
  it.
- Dashboard auto-start disabled (`start_dashboard_once` commented out) to
  save roughly 1 GB of RAM and avoid the 9119 port conflict with the base
  image's own s6 dashboard service. Discord/API remain the access paths.
- Gateway restart cap default raised to 3 (`GATEWAY_MAX_RESTARTS=3`,
  overridable) so a genuine crash loop cannot churn forever in-container.
- `PLAYWRIGHT_CHROMIUM_ARGS="--disable-dev-shm-usage --no-sandbox
  --disable-gpu"` added to the image ENV so headless Chromium uses disk
  instead of the 64 MB `/dev/shm` and cannot crash the gateway on browse
  actions.

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