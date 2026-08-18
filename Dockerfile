# HuggingMes - Hermes Agent Gateway for Hugging Face Spaces
# Hardened build: outbound-relay tooling removed, JupyterLab terminal
# removed at image level, NOPASSWD sudo removed. See DEPLOYMENT_README.md.

ARG HERMES_AGENT_VERSION=latest
FROM nousresearch/hermes-agent:${HERMES_AGENT_VERSION}

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    sudo \
    python3 \
    python3-venv \
    python3-pip \
    chromium \
    dbus \
    dbus-x11 \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libgbm1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxkbcommon0 \
    libx11-6 \
    libxext6 \
    libxfixes3 \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-color-emoji \
    && (apt-get install -y --no-install-recommends libasound2 2>/dev/null \
        || apt-get install -y --no-install-recommends libasound2t64 2>/dev/null \
        || true) \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
        huggingface_hub \
        hf_transfer \
        ddgs

COPY --chown=hermes:hermes start.sh /opt/huggingmes/start.sh
COPY --chown=hermes:hermes health-server.js /opt/huggingmes/health-server.js
COPY --chown=hermes:hermes hermes-sync.py /opt/huggingmes/hermes-sync.py

# Runs after the base image's 02-reconcile-profiles (lexicographic order)
# and before s6-rc starts user services: downs the auto-started
# gateway-default slot and pins gateway_state.json to stopped so the s6
# lifecycle never spawns a second, env-starved gateway that races
# start.sh's direct launch (see the script header for the full rationale).
COPY --chown=root:root scripts/99-huggingmes-gateway-owner /etc/cont-init.d/99-huggingmes-gateway-owner

RUN chmod +x \
    /opt/huggingmes/start.sh \
    /opt/huggingmes/hermes-sync.py \
    /etc/cont-init.d/99-huggingmes-gateway-owner

# Patch kanban migration: wrap ALTER TABLE ADD COLUMN in try/except so a
# persisted DB with the column already present doesn't crash the gateway.
# Entire block wrapped in try/except — skips silently if Hermes fixes this
# upstream or the file structure changes.
RUN python3 - <<'PY'
import sys
try:
    from pathlib import Path

    p = Path("/opt/hermes/hermes_cli/kanban_db.py")
    if not p.exists():
        print("kanban patch: file not found, skipping")
        sys.exit(0)

    src = p.read_text(encoding="utf-8", errors="replace")
    sentinel = "# huggingmes: idempotent-alter"
    if sentinel in src:
        print("kanban patch: already applied, skipping")
        sys.exit(0)

    old = (
        '    conn.execute(\n'
        '        "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '        "INTEGER NOT NULL DEFAULT 0"\n'
        '    )'
    )
    new = (
        f'    try:  {sentinel}\n'
        '        conn.execute(\n'
        '            "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '            "INTEGER NOT NULL DEFAULT 0"\n'
        '        )\n'
        '    except Exception:\n'
        '        pass'
    )

    if old not in src:
        print("kanban patch: pattern not found, may be fixed upstream, skipping")
        sys.exit(0)

    p.write_text(src.replace(old, new), encoding="utf-8")
    print("kanban patch: applied")
except Exception as e:
    print(f"kanban patch: error ({e}), skipping", file=sys.stderr)
PY

# huggingmes: prevent local-server probing of remote endpoints.
# agent/model_metadata.py has two functions that run HTTP probe waterfalls
# against the configured base_url (detect_local_server_type and
# _query_local_context_length_uncached). For a remote gateway like the Zen
# endpoint these probes are pointless (the server is not Ollama/LM Studio)
# and they generate 404/405 noise against the remote API. Both functions
# bail out early unless the endpoint is local. Skipped silently if the
# file or function anchors change upstream.
RUN python3 - <<'PY'
import re
import sys
from pathlib import Path

try:
    p = Path("/opt/hermes/agent/model_metadata.py")
    if not p.exists():
        print("model_metadata patch: file not found, skipping")
        sys.exit(0)

    src = p.read_text(encoding="utf-8", errors="replace")
    sentinel = "# huggingmes: remote-only guard"
    guard = (
        f"    {sentinel}\n"
        "    if base_url and not is_local_endpoint(base_url):\n"
        "        return None\n"
    )
    changed = False
    for fn in ("detect_local_server_type", "_query_local_context_length_uncached"):
        def_match = re.search(rf"def {fn}\(", src)
        if not def_match:
            print(f"model_metadata patch: {fn} not found, skipping")
            continue
        if sentinel in src[def_match.start():def_match.start() + 800]:
            print(f"model_metadata patch: {fn} already patched, skipping")
            continue
        # Anchor on the first 'import httpx' statement after the def line.
        # Both target functions import httpx as their first executable
        # statement (after the docstring), so the guard lands after the
        # docstring and before any probing code.
        anchor = re.search(r"\n(    import httpx\n)", src[def_match.start():])
        if not anchor:
            print(f"model_metadata patch: {fn} anchor not found, skipping")
            continue
        insert_at = def_match.start() + anchor.start(1)
        src = src[:insert_at] + "\n" + guard + src[insert_at:]
        changed = True
        print(f"model_metadata patch: {fn} guarded")

    p.write_text(src, encoding="utf-8")
    print("model_metadata patch: done" if changed else "model_metadata patch: no changes")
except Exception as e:
    print(f"model_metadata patch: error ({e}), skipping", file=sys.stderr)
PY

# hermes v0.17+ self-patches its own Python files at container startup
# (workspace/startup.sh), but ships them read-only in the image.
# Make all subdirs traversable first so find reaches every .py file; dirs
# without execute permission cause find to silently skip them.
# Use a+w (not u+w): this RUN executes as root during build, but HF Spaces
# runs the container as an arbitrary non-root UID at runtime — u+w only
# grants write to the file's owner (root), which the runtime UID isn't.
# Also clear any bytecode cache so the patched sources above are recompiled
# from scratch at first import (the self-patcher rewrites .py files too).
RUN find /opt/hermes -type d -exec chmod a+rwx {} + 2>/dev/null || true \
    && find /opt/hermes -name "*.py" -exec chmod a+w {} + 2>/dev/null || true \
    && find /opt/hermes -name "*.pyc" -delete 2>/dev/null || true \
    && find /opt/hermes -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

# Ensure hermes CLI is discoverable in ALL shell types (login, interactive,
# non-interactive). /etc/profile.d/ is sourced by login shells after /etc/profile
# resets PATH, so this survives even full environment resets.
RUN echo 'export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"' \
    > /etc/profile.d/hermes-venv.sh

ENV HERMES_HOME=/opt/data \
    HUGGINGMES_APP_DIR=/opt/huggingmes \
    HERMES_AGENT_VERSION=${HERMES_AGENT_VERSION} \
    HERMES_GATEWAY_NO_SUPERVISE=1 \
    PYTHONUNBUFFERED=1 \
    MALLOC_ARENA_MAX=2 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium \
    PLAYWRIGHT_CHROMIUM_ARGS="--disable-dev-shm-usage --no-sandbox --disable-gpu" \
    AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium \
    AGENT_BROWSER_ARGS="--no-sandbox,--disable-dev-shm-usage"

EXPOSE 7861

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD curl -fsS http://localhost:7861/health || exit 1

CMD ["/opt/huggingmes/start.sh"]