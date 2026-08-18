# Contributing

Thanks for improving HuggingMes.

## Local Checks

Run these before submitting changes:

```bash
bash -n start.sh
node --check health-server.js
python3 -m py_compile hermes-sync.py
```

If Docker is available:

```bash
docker compose up --build
```

## Notes

- Keep the wrapper thin; prefer the official `nousresearch/hermes-agent` image for Hermes itself.
- Avoid committing secrets or generated `/opt/data` state.
- Preserve Hugging Face Space metadata in `README.md`.
