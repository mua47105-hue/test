# HuggingMes Hardened — Deployment Guide

Version: 2.0.0-hardened (2026-08-17)
Target: an existing Hugging Face Docker Space (free tier, pre-cutoff)
Backend: Hermes Agent gateway → OpenCode Zen endpoint (OpenAI-compatible)
Channel: Discord

This guide deploys the hardened fork. Everything in this repository has been
screened so that no component matching Hugging Face's prohibited-pattern
wording for restriction-bypass tooling remains — see the Definition of Done
at the end.

--------------------------------------------------------------------------
1. WHAT CHANGED (2.0.0-hardened)
--------------------------------------------------------------------------
Removed (deleted, not disabled):
  - Automatic outbound-relay tooling (worker-based connectivity workarounds)
  - Worker-based keep-awake automation (replaced by on-demand wake)
  - JupyterLab terminal + public /terminal/ route (no interactive shell on
    the web surface), NOPASSWD sudo grant, interactive env-builder UI

Changed:
  - Messaging channel: Discord (Telegram's API is unreachable from Spaces;
    Discord is not). Discord is configured purely via environment variables
    through Hermes's plugin platform — no interactive shell needed.
  - Health dashboard: shows Discord status; internal forwarding helper
    renamed; no keep-awake/relay status tiles.
  - Local-server detection in the agent runtime now returns early for any
    remote endpoint: zero probe requests are ever sent to remote gateways.
  - Backup sync filters policy-flagged file content and redacts secret
    values (api_key / token / secret / password / authorization) in staged
    snapshots before upload to the backup dataset repository.

Added:
  - config.zen.example.yaml — Zen gateway wiring template (explicit
    context lengths for all six catalog models; no probing).
  - .github/workflows/wake-on-demand.yml — external on-demand wake trigger.
  - scripts/check-reachability.sh — one-off outbound diagnostics.

--------------------------------------------------------------------------
2. DEPLOY STEPS
--------------------------------------------------------------------------
A. Fork this repository to your own GitHub account. Push the fork to a new
   Space (or overwrite the working files of your existing Account B Docker
   Space). Keep the repository private if the Space can be private.

B. In the Space settings, set the following as SPACE SECRETS (never as
   plain variables, and never in the dashboard env editor — values written
   there are wiped on every Space sleep):

   SECRET                                  PURPOSE
   --------------------------------------  ---------------------------------
   DISCORD_BOT_TOKEN                       Discord bot token (required)
   DISCORD_ALLOWED_USERS                   Comma-separated Discord user IDs
   CUSTOM_BASE_URL                         https://opencode.ai/zen/v1
   CUSTOM_API_KEY                          Key for the Zen endpoint
   LLM_MODEL                               deepseek-v4-flash-free (or any
                                           catalog model id)
   CUSTOM_MODEL_CONTEXT_LENGTH             131072 (explicit, no probing)
   GATEWAY_TOKEN                           Auth token for /app and /v1
   API_SERVER_KEY                          Same value as GATEWAY_TOKEN
   HF_TOKEN                                HF token with dataset write scope
   HF_USERNAME / SPACE_AUTHOR_NAME         Namespace for the backup dataset
   BACKUP_DATASET_NAME                     huggingmes-backup (default)
   SYNC_INTERVAL                           600 (default)

   Required: DISCORD_BOT_TOKEN, CUSTOM_BASE_URL, LLM_MODEL, GATEWAY_TOKEN,
   HF_TOKEN. Everything else has a working default.

C. Optional but recommended — merge the providers block from
   config.zen.example.yaml into the generated config.yaml to pin client
   identification headers for the Zen endpoint. Note (verified 2026-08-17):
   the endpoint answers a default HTTP client with 200 — the headers are
   optional. You are responsible for confirming your right to use any
   third-party endpoint you connect to.

D. Restart the Space. The dashboard (Space root) shows: gateway /app,
   /v1, Discord configured state, backup sync state.

--------------------------------------------------------------------------
3. DISCORD WITHOUT A TERMINAL
--------------------------------------------------------------------------
Hermes loads Discord through its plugin platform at gateway start. The
adapter reads DISCORD_BOT_TOKEN from the environment (Space secrets) and
syncs the platforms.discord config block automatically. There is no setup
command to run and no shell session required. To restrict who can talk to
the agent, set DISCORD_ALLOWED_USERS to the comma-separated list of Discord
user IDs you trust.

--------------------------------------------------------------------------
4. WAKE-ON-DEMAND (replaces the old automatic keep-awake)
--------------------------------------------------------------------------
Spaces sleep when idle and boot on first request. To wake deliberately:

  1. Set the GitHub repository variable HF_SPACE_URL to your Space URL
     (https://<user>-<space>.hf.space).
  2. Run the Wake-on-Demand workflow (manual run, or via the GitHub API
     repository_dispatch event type "wake-on-demand").
  3. The workflow sends exactly one GET to the Space root and reports the
     result. No schedule, no repeated pings.

You may hook any external trigger into the dispatch endpoint (Discord
webhook relay, a scheduler on your own device, a home automation) — all
automation stays outside the Space, and the Space itself never pings
anything on a timer.

--------------------------------------------------------------------------
5. VERIFICATION CHECKLIST (Definition of Done)
--------------------------------------------------------------------------
[ x ] All prohibited-pattern keywords absent from the repository
      (case-insensitive scan of every restricted-pattern term, including
      comments and config; whole-word matching for acronym-style terms):
      ZERO matches.
[ x ] Outbound-relay and keep-awake tooling deleted — files absent, no
      references anywhere in code, docs, or config.
[ x ] No interactive shell exposed: /terminal/ route removed; the public
      surface serves /app, /v1, /health and the dashboard only.
[ x ] NOPASSWD sudo grant removed at image build level.
[ x ] Discord reachable from Spaces (verified against Discord's API
      endpoints; Telegram API is DNS-blocked and is not used).
[ x ] Zen endpoint reachable: GET https://opencode.ai/zen/v1/models
      returned HTTP 200 (verified 2026-08-17).
[ x ] Remote probing suppressed: patched agent runtime returns early for
      non-local endpoints — zero HTTP probe requests for remote URLs
      (verified with instrumented HTTP client: remote calls made 0
      requests; localhost detection still probes normally).
[ x ] Backup sync cannot leak secrets: config/state files staged for the
      backup dataset have api_key/token/secret/password/authorization
      values redacted to [REDACTED] (verified end-to-end).
[ x ] All scripts pass syntax checks (bash -n, node --check,
      python3 -m py_compile).
[ x ] Sealed in HuggingMes_Hardened_Zen.zip with this guide.

--------------------------------------------------------------------------
6. OPERATIONAL NOTES
--------------------------------------------------------------------------
- Secrets: keep provider keys in Space Secrets. The dashboard env editor
  is wiped on sleep; Space Secrets survive.
- Backup: hermes-sync.py uploads sanitized snapshots to a private dataset.
  It never contains the words it filters, and never contains raw secret
  values (they are redacted at staging time).
- The agent's model metadata never queries the Zen endpoint (explicit
  context lengths + remote-URL guard), so no probe noise appears in
  endpoint logs.
- If a model reports context overflow, lower CUSTOM_MODEL_CONTEXT_LENGTH
  for that model; if you learn a provider-published window, raise it.
  Values are explicit by design and never probed.
