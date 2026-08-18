# Security

HuggingMes runs a full agent gateway with tool access. Treat the Space and its secrets like a server.

## Required Hardening

- Set `GATEWAY_TOKEN`; `/v1/*` routes require `Authorization: Bearer <GATEWAY_TOKEN>`.
- Set `TELEGRAM_ALLOWED_USERS` to numeric Telegram user IDs.
- Keep your HF Dataset backup private.
- Do not enable `SYNC_INCLUDE_ENV=true` unless you intentionally want `/opt/data/.env` backed up.

## Reporting

Open a private issue or contact the maintainer directly with reproduction steps and affected configuration.
