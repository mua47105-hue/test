#!/bin/bash
set -euo pipefail

umask 0077

# ════════════════════════════════════════════════════════════════
# HuggingMes — Hermes Gateway for HF Spaces
# ════════════════════════════════════════════════════════════════

# ── Startup Banner ──
APP_DIR="${HUGGINGMES_APP_DIR:-/opt/huggingmes}"
HERMES_HOME="${HERMES_HOME:-/opt/data}"
PUBLIC_PORT="${PORT:-7861}"
GATEWAY_API_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
SYNC_INTERVAL="${SYNC_INTERVAL:-600}"
BACKUP_DATASET="${BACKUP_DATASET_NAME:-huggingmes-backup}"
STARTUP_FILE="$HERMES_HOME/workspace/startup.sh"

export HERMES_HOME
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export API_SERVER_PORT="$GATEWAY_API_PORT"
export GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:${GATEWAY_API_PORT}}"

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║        🪽 HuggingMes Hermes Gateway      ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

if [ -z "${API_SERVER_KEY:-}" ]; then
  if [ -n "${GATEWAY_TOKEN:-}" ]; then
    export API_SERVER_KEY="$GATEWAY_TOKEN"
  else
    API_SERVER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
    export API_SERVER_KEY
    echo "GATEWAY_TOKEN not set - generated an ephemeral API token for this boot."
  fi
fi

# The api_server platform refuses to start with a key shorter than 16
# chars (gateway/config.py has_usable_secret guard) — a short
# GATEWAY_TOKEN secret would leave port 8642 closed and trip the
# readiness loop. Enforce a strong key for this boot.
if [ "${#API_SERVER_KEY}" -lt 16 ]; then
  echo "WARNING: API_SERVER_KEY/GATEWAY_TOKEN is only ${#API_SERVER_KEY} chars; api_server needs at least 16. Generating a strong key for this boot (set a GATEWAY_TOKEN of 16+ chars to make it stable)."
  API_SERVER_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
  export API_SERVER_KEY
fi

# ── Publish API-server env into HERMES_HOME/.env (force) ──
# The gateway loads $HERMES_HOME/.env with override=True
# (hermes_cli/env_loader.py), so a stale API_SERVER_KEY left in this
# PERSISTENT file (it survives deploys/restarts on HF Spaces) silently
# beats the process env and leaves the api_server platform unbound → port
# 8642 never opens → the readiness loop below times out → container exits
# 1 → HF restart loop. Always rewrite the API-server keys (and drop the
# deprecated TERMINAL_CWD line) so the file can never poison a boot.
python3 - "$HERMES_HOME/.env" <<'PY'
import os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
drop = re.compile(r"^(API_SERVER_KEY|API_SERVER_ENABLED|API_SERVER_HOST|API_SERVER_PORT|TERMINAL_CWD)=")
lines = [ln for ln in text.splitlines() if not drop.match(ln)]
lines.append(f"API_SERVER_KEY={os.environ['API_SERVER_KEY']}")
lines.append(f"API_SERVER_ENABLED={os.environ.get('API_SERVER_ENABLED', 'true')}")
lines.append(f"API_SERVER_HOST={os.environ.get('API_SERVER_HOST', '127.0.0.1')}")
lines.append(f"API_SERVER_PORT={os.environ.get('API_SERVER_PORT', '8642')}")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

# Best-effort: mirror the same keys into s6's container_environment so any
# future s6-spawned process (named-profile slots, dashboard launchers)
# inherits them too. start.sh may lack the privileges to write there
# (root-owned tmpfs); the .env force-write above is the authoritative fix.
if [ -d /run/s6/container_environment ]; then
  for _k in API_SERVER_KEY API_SERVER_ENABLED API_SERVER_HOST API_SERVER_PORT; do
    _v="$(printenv "$_k" 2>/dev/null || true)"
    [ -n "$_v" ] || continue
    (umask 077; printf '%s' "$_v" > "/run/s6/container_environment/$_k") 2>/dev/null || true
  done
fi

# Keep any `hermes gateway run` invocation (dashboard restart button,
# terminal commands) in-process instead of handing it to s6-supervise,
# which would drop the env start.sh exported.
export HERMES_GATEWAY_NO_SUPERVISE=1

# ── Setup directories ──
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home,plugins}

# Expose hermes CLI in ~/.local/bin so login shells (terminal backend) find it.
# Base image PATH includes /opt/data/.local/bin but hermes lives in the venv.
mkdir -p "$HERMES_HOME/.local/bin"
ln -sfn /opt/hermes/.venv/bin/hermes "$HERMES_HOME/.local/bin/hermes"

# Redirect Hermes plugin dir into volume so plugins survive container restarts
if [ ! -L "${HOME}/.hermes/plugins" ]; then
  mkdir -p "${HOME}/.hermes"
  rm -rf "${HOME}/.hermes/plugins"
  ln -sfn "$HERMES_HOME/plugins" "${HOME}/.hermes/plugins"
fi

# ── Restore workspace/state from HF Dataset ──
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Restoring Hermes state from HF Dataset..."
  python3 "$APP_DIR/hermes-sync.py" restore || true
else
  echo "HF_TOKEN not set - dataset persistence is disabled."
fi

MODEL_INPUT="${HERMES_MODEL:-${LLM_MODEL:-}}"
MODEL_FOR_CONFIG="$MODEL_INPUT"
PROVIDER_FOR_CONFIG="${HERMES_INFERENCE_PROVIDER:-auto}"
LLM_API_KEY="${LLM_API_KEY:-}"

if [ -n "$MODEL_INPUT" ]; then
  MODEL_PREFIX="${MODEL_INPUT%%/*}"
else
  MODEL_PREFIX=""
fi

case "$MODEL_PREFIX" in
  openrouter)
    [ -n "$LLM_API_KEY" ] && export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="openrouter"
    MODEL_FOR_CONFIG="${MODEL_INPUT#openrouter/}"
    ;;
  huggingface|hf)
    [ -n "$LLM_API_KEY" ] && export HF_TOKEN="${HF_TOKEN:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="huggingface"
    MODEL_FOR_CONFIG="${MODEL_INPUT#huggingface/}"
    ;;
  vercel-ai-gateway|ai-gateway)
    [ -n "$LLM_API_KEY" ] && export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-$LLM_API_KEY}"
    [ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="ai-gateway"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
    ;;
  anthropic)
    [ -n "$LLM_API_KEY" ] && export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$LLM_API_KEY}"
    ;;
  openai|openai-codex)
    [ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
    ;;
  google|gemini)
    [ -n "$LLM_API_KEY" ] && export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}" GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
    PROVIDER_FOR_CONFIG="gemini"
    MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"   # strip "google/" or "gemini/" prefix — Hermes gemini provider needs bare model name
    ;;
  deepseek)
    [ -n "$LLM_API_KEY" ] && export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding|moonshot)
    [ -n "$LLM_API_KEY" ] && export KIMI_API_KEY="${KIMI_API_KEY:-$LLM_API_KEY}"
    ;;
  kimi-coding-cn|moonshot-cn|kimi-cn)
    [ -n "$LLM_API_KEY" ] && export KIMI_CN_API_KEY="${KIMI_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_API_KEY="${MINIMAX_API_KEY:-$LLM_API_KEY}"
    ;;
  minimax-cn)
    [ -n "$LLM_API_KEY" ] && export MINIMAX_CN_API_KEY="${MINIMAX_CN_API_KEY:-$LLM_API_KEY}"
    ;;
  xiaomi)
    [ -n "$LLM_API_KEY" ] && export XIAOMI_API_KEY="${XIAOMI_API_KEY:-$LLM_API_KEY}"
    ;;
  zai|z-ai|z.ai|glm)
    [ -n "$LLM_API_KEY" ] && export GLM_API_KEY="${GLM_API_KEY:-$LLM_API_KEY}"
    ;;
  arcee|arcee-ai|arceeai)
    [ -n "$LLM_API_KEY" ] && export ARCEEAI_API_KEY="${ARCEEAI_API_KEY:-$LLM_API_KEY}"
    ;;
  gmi|gmi-cloud|gmicloud)
    [ -n "$LLM_API_KEY" ] && export GMI_API_KEY="${GMI_API_KEY:-$LLM_API_KEY}"
    ;;
  alibaba)
    [ -n "$LLM_API_KEY" ] && export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
    ;;
  alibaba-coding-plan|alibaba_coding)
    [ -n "$LLM_API_KEY" ] && export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
    ;;
  tencent-tokenhub|tencent|tokenhub|tencentmaas)
    [ -n "$LLM_API_KEY" ] && export TOKENHUB_API_KEY="${TOKENHUB_API_KEY:-$LLM_API_KEY}"
    ;;
  nvidia)
    [ -n "$LLM_API_KEY" ] && export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$LLM_API_KEY}"
    ;;
  xai|grok)
    [ -n "$LLM_API_KEY" ] && export XAI_API_KEY="${XAI_API_KEY:-$LLM_API_KEY}"
    ;;
  kilocode)
    [ -n "$LLM_API_KEY" ] && export KILOCODE_API_KEY="${KILOCODE_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-zen)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-$LLM_API_KEY}"
    ;;
  opencode-go)
    [ -n "$LLM_API_KEY" ] && export OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY:-$LLM_API_KEY}"
    ;;
esac

if [ -n "${CUSTOM_BASE_URL:-}" ]; then
  PROVIDER_FOR_CONFIG="${CUSTOM_PROVIDER:-custom}"
  [ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
fi

export MODEL_FOR_CONFIG PROVIDER_FOR_CONFIG
export CUSTOM_BASE_URL="${CUSTOM_BASE_URL:-}"
export CUSTOM_API_KEY="${CUSTOM_API_KEY:-${LLM_API_KEY:-}}"
export CUSTOM_MODEL_CONTEXT_LENGTH="${CUSTOM_MODEL_CONTEXT_LENGTH:-131072}"
export CUSTOM_MODEL_MAX_TOKENS="${CUSTOM_MODEL_MAX_TOKENS:-8192}"

# ── Pool key promotion ──
# Mirror first key from comma-separated pool vars into the singular env var.
# Hermes providers read singular vars; this lets users supply pool keys like
# ANTHROPIC_API_KEYS=key1,key2 and have them picked up automatically.
promote_first_pool_key() {
  local singular_var="$1"
  local pool_var="$2"
  local singular_val="${!singular_var:-}"
  local pool_val="${!pool_var:-}"
  [ -n "$singular_val" ] && return 0
  [ -n "$pool_val" ] || return 0
  local first
  first=$(printf '%s' "$pool_val" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF{print; exit}')
  [ -n "$first" ] || return 0
  export "${singular_var}=$first"
}

promote_first_pool_key "OPENROUTER_API_KEY"   "OPENROUTER_API_KEYS"
promote_first_pool_key "ANTHROPIC_API_KEY"    "ANTHROPIC_API_KEYS"
promote_first_pool_key "OPENAI_API_KEY"       "OPENAI_API_KEYS"
promote_first_pool_key "GOOGLE_API_KEY"       "GOOGLE_API_KEYS"
promote_first_pool_key "GEMINI_API_KEY"       "GEMINI_API_KEYS"
promote_first_pool_key "DEEPSEEK_API_KEY"     "DEEPSEEK_API_KEYS"
promote_first_pool_key "KIMI_API_KEY"         "KIMI_API_KEYS"
promote_first_pool_key "MINIMAX_API_KEY"      "MINIMAX_API_KEYS"
promote_first_pool_key "NVIDIA_API_KEY"       "NVIDIA_API_KEYS"
promote_first_pool_key "XAI_API_KEY"          "XAI_API_KEYS"
promote_first_pool_key "KILOCODE_API_KEY"     "KILOCODE_API_KEYS"
promote_first_pool_key "GLM_API_KEY"          "GLM_API_KEYS"
promote_first_pool_key "ARCEEAI_API_KEY"      "ARCEEAI_API_KEYS"
promote_first_pool_key "DASHSCOPE_API_KEY"    "DASHSCOPE_API_KEYS"
promote_first_pool_key "GMI_API_KEY"          "GMI_API_KEYS"
promote_first_pool_key "TOKENHUB_API_KEY"     "TOKENHUB_API_KEYS"

# ── Build config ──
python3 - <<'PY'
import os
from pathlib import Path

import yaml

home = Path(os.environ["HERMES_HOME"])
path = home / "config.yaml"
try:
    config = yaml.safe_load(path.read_text(encoding="utf-8", errors="replace")) or {}
    if not isinstance(config, dict):
        config = {}
except Exception:
    # An old/corrupt config.yaml must never crash config-gen (which would
    # kill start.sh under set -e). Fall back to a fresh config.
    config = {}

model_name = os.environ.get("MODEL_FOR_CONFIG", "").strip()
provider_name = os.environ.get("PROVIDER_FOR_CONFIG", "").strip()

# Defensive: coerce model/platforms to dicts before merging.
if not isinstance(config.get("model"), dict):
    config["model"] = {}
if not isinstance(config.get("platforms"), dict):
    config["platforms"] = {}

model = config["model"]
if model_name:
    model["default"] = model_name                          # always from env — deploy-time setting
    if provider_name and provider_name != "auto":
        model["provider"] = provider_name                  # explicit provider (openrouter, huggingface, custom…)
    else:
        model.pop("provider", None)                        # let Hermes infer from model-name prefix
else:
    # No model configured via env (HF secrets unset) — inject the Zen
    # fallback so the gateway always has a usable model route and the
    # api_server platform can serve requests out of the box. Values match
    # config.zen.example.yaml + the OpenCode Zen integration reference.
    # Env wins whenever the operator later sets LLM_MODEL/HERMES_MODEL.
    zen_url = "https://opencode.ai/zen/v1"
    zen_ua = "opencode/1.18.18 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14"
    zen_models = {
        # Explicit context_length for EVERY model: the resolver's step 0c
        # (custom_providers[i].models.<model>.context_length) short-circuits
        # before any endpoint probing, so a /model switch never burns the
        # Zen rate-limit budget. Windows per the operator (2026-08-18); the
        # Zen catalog now has 7 free models (nemotron-3.5-lightning-free added).
        "deepseek-v4-flash-free": 200000,
        "mimo-v2.5-free": 200000,
        "hy3-free": 190000,
        "laguna-s-2.1-free": 256000,
        "nemotron-3.5-lightning-free": 262144,
        "nemotron-3-ultra-free": 128000,
        "big-pickle": 128000,
    }
    # Reasoning-effort support, per the OpenCode UI (operator-verified) and
    # confirmed against the live endpoint: deepseek exposes default/low/high/
    # max; hy3 and laguna expose default/medium/high (NO "max"); mimo and the
    # nemotron models expose no effort levels. Map each reasoning model to its
    # MAXIMUM supported level so Hermes never sends a level Zen rejects
    # (hy3/laguna reject "max"; everyone rejects "ultra").
    zen_effort = {
        "deepseek-v4-flash-free": "max",
        "hy3-free": "high",
        "laguna-s-2.1-free": "high",
    }
    zen_vision = {"mimo-v2.5-free"}
    model["default"] = "deepseek-v4-flash-free"
    model["provider"] = "custom"
    model["base_url"] = zen_url
    model["api_key"] = "placeholder"          # Zen needs no auth; non-empty satisfies Hermes
    model["context_length"] = zen_models["deepseek-v4-flash-free"]
    model["max_tokens"] = 8192
    model["discover_models"] = False
    # Top-level headers the AUXILIARY client merges onto its own requests
    # (agent/auxiliary_client._apply_user_default_headers reads
    # model.default_headers / model.extra_headers). Without these, vision /
    # compression / web-extract calls to Zen would send the default
    # Bearer + OpenAI User-Agent and get 401/429 from Zen.
    model["extra_headers"] = {
        "Authorization": "",
        "User-Agent": zen_ua,
    }

    # Newer keyed schema — this is where the HTTP client lifts the headers
    # (runtime_provider._lift_extra_headers).
    providers = config.setdefault("providers", {})
    if not isinstance(providers, dict):
        providers = {}
        config["providers"] = providers
    custom_prov = providers.setdefault("custom", {})
    if not isinstance(custom_prov, dict):
        custom_prov = {}
        providers["custom"] = custom_prov
    custom_prov["base_url"] = zen_url
    custom_prov["api_key"] = "placeholder"
    custom_prov["default_model"] = "deepseek-v4-flash-free"
    custom_prov["extra_headers"] = {
        "Authorization": "",      # empty → strip the Bearer header Zen rejects (401)
        "User-Agent": zen_ua,     # official OpenCode client identity (Tier-1 models)
    }

    # Legacy list format the per-model context resolver reads directly
    # (agent/model_metadata.py step 0c via get_custom_provider_context_length).
    config["custom_providers"] = [{
        "name": "opencode-zen-free",
        "base_url": zen_url,
        "api_key": "placeholder",
        "api_mode": "chat_completions",
        "model": "deepseek-v4-flash-free",
        "discover_models": False,
        "models": {m: {"context_length": ctx} for m, ctx in zen_models.items()},
        "extra_headers": {
            "Authorization": "",
            "User-Agent": zen_ua,
        },
    }]

    # Per-model capability + context overrides. Zen model ids are unknown to
    # models.dev, which defaults unknown models to tools-on / vision-off /
    # reasoning-off — so agent.reasoning_effort would be a no-op (models run
    # at Zen's default effort) and images would never attach to mimo.
    mo = config.setdefault("model_overrides", {})
    if not isinstance(mo, dict):
        mo = {}
        config["model_overrides"] = mo
    mo_custom = mo.setdefault("custom", {})
    if not isinstance(mo_custom, dict):
        mo_custom = {}
        mo["custom"] = mo_custom
    for _m, _ctx in zen_models.items():
        _e = mo_custom.setdefault(_m, {})
        if not isinstance(_e, dict):
            _e = {}
            mo_custom[_m] = _e
        _e["context_window"] = _ctx
        _e.setdefault("supports_tools", True)
        _e["supports_reasoning"] = _m in zen_effort
        _e["supports_vision"] = _m in zen_vision

    # Reasoning effort: a safe global default ("high") plus explicit per-model
    # levels so deepseek gets "max" while hy3/laguna stay at their ceiling of
    # "high". Global default overridable via HERMES_REASONING_EFFORT.
    _agent_cfg = config.setdefault("agent", {})
    if not isinstance(_agent_cfg, dict):
        _agent_cfg = {}
        config["agent"] = _agent_cfg
    _agent_cfg["reasoning_effort"] = os.environ.get("HERMES_REASONING_EFFORT", "high").strip() or "high"
    _ro = _agent_cfg.setdefault("reasoning_overrides", {})
    if not isinstance(_ro, dict):
        _ro = {}
        _agent_cfg["reasoning_overrides"] = _ro
    for _m, _eff in zen_effort.items():
        _ro.setdefault(_m, _eff)

    # Auxiliary LLM routes (vision, compression, web-extract) — the background
    # side-jobs Hermes offloads from the main model. Point them at Zen so
    # "no auxiliary LLM provider configured" goes away and vision can use the
    # multimodal mimo-v2.5-free. setdefault: an operator's explicit config wins.
    aux = config.setdefault("auxiliary", {})
    if not isinstance(aux, dict):
        aux = {}
        config["auxiliary"] = aux
    aux_routes = {
        "vision": "mimo-v2.5-free",       # multimodal model on Zen (image input)
        "compression": "deepseek-v4-flash-free",  # fast/cheap summarisation
        "web_extract": "deepseek-v4-flash-free",  # page summarisation
    }
    for _task, _aux_model in aux_routes.items():
        _task_cfg = aux.setdefault(_task, {})
        if not isinstance(_task_cfg, dict):
            _task_cfg = {}
            aux[_task] = _task_cfg
        _task_cfg.setdefault("provider", "custom")
        _task_cfg.setdefault("base_url", zen_url)
        _task_cfg.setdefault("api_key", "placeholder")
        _task_cfg.setdefault("model", _aux_model)

    print("No LLM_MODEL/HERMES_MODEL set; injected the Zen fallback catalog (6 models, deepseek-v4-flash-free default).")

custom_base = os.environ.get("CUSTOM_BASE_URL", "").strip()
if custom_base and model_name:
    model.setdefault("base_url", custom_base.rstrip("/"))
    if os.environ.get("CUSTOM_API_KEY"):
        model.setdefault("api_key", os.environ["CUSTOM_API_KEY"])
    try:
        model.setdefault("context_length", int(os.environ.get("CUSTOM_MODEL_CONTEXT_LENGTH", "131072")))
        model.setdefault("max_tokens", int(os.environ.get("CUSTOM_MODEL_MAX_TOKENS", "8192")))
    except ValueError:
        pass

config.setdefault("terminal", {}).setdefault("cwd", os.environ.get("MESSAGING_CWD", str(home / "workspace")))
# Explicit kanban concurrency cap: the base image derives a default from
# the SHARED host's /proc/meminfo and warns "system memory pressure is
# critical" every tick when that host is loaded (HF sandbox hosts are),
# which reads like a crash cause in the runtime logs. An explicit value
# makes dispatch deterministic and silences the warnings.
try:
    config.setdefault("kanban", {}).setdefault(
        "max_in_progress", int(os.environ.get("HERMES_KANBAN_MAX_IN_PROGRESS", "4"))
    )
except ValueError:
    pass
config.setdefault("compression", {}).setdefault("enabled", True)
config.setdefault("display", {}).setdefault("background_process_notifications", os.environ.get("HERMES_BACKGROUND_NOTIFICATIONS", "result"))
config.setdefault("security", {}).setdefault("redact_secrets", True)

# Deeper subagent nesting: Hermes defaults max_spawn_depth=1 (flat only).
# 2 lets an orchestrator spawn leaf subagents — the "can't spawn chains of
# subagents deeper than one level" limitation. Respect HERMES_MAX_SPAWN_DEPTH.
try:
    config.setdefault("delegation", {}).setdefault(
        "max_spawn_depth", int(os.environ.get("HERMES_MAX_SPAWN_DEPTH", "2"))
    )
except ValueError:
    pass

# Web search: ddgs (DuckDuckGo) is the keyless/free backend, installed at
# build time. Only set when the operator hasn't chosen a key-based backend.
_web_cfg = config.setdefault("web", {})
if not isinstance(_web_cfg, dict):
    _web_cfg = {}
    config["web"] = _web_cfg
if not str(_web_cfg.get("search_backend", "")).strip():
    _web_cfg["search_backend"] = "ddgs"

# Browser: force the built-in (agent-browser + local Chromium) tools rather
# than the browser-use/uvx auto path, which downloads a heavy stack at
# runtime and is fragile in a root container. Deterministic on HF.
_browser_cfg = config.setdefault("browser", {})
if not isinstance(_browser_cfg, dict):
    _browser_cfg = {}
    config["browser"] = _browser_cfg
if not str(_browser_cfg.get("backend", "")).strip():
    _browser_cfg["backend"] = "off"

platforms = config["platforms"]

# Force api_server enabled: it is the 8642 readiness port start.sh's boot
# loop waits for. A stale `platforms.api_server.enabled: false` in an old
# config.yaml sets the loader's _enabled_explicit marker, which keeps the
# platform disabled even with a valid API_SERVER_KEY (gateway/config.py).
# Overwrite the block so the port always opens.
api_server = platforms.setdefault("api_server", {})
if not isinstance(api_server, dict):
    api_server = {}
    platforms["api_server"] = api_server
api_server["enabled"] = True
api_extra = api_server.setdefault("extra", {})
if not isinstance(api_extra, dict):
    api_extra = {}
    api_server["extra"] = api_extra
api_extra["key"] = os.environ["API_SERVER_KEY"]
api_extra["host"] = os.environ.get("API_SERVER_HOST", "127.0.0.1")
try:
    api_extra["port"] = int(os.environ.get("API_SERVER_PORT", "8642"))
except ValueError:
    pass

if os.environ.get("DISCORD_BOT_TOKEN"):
    discord = platforms.setdefault("discord", {})
    discord.setdefault("enabled", True)
    if os.environ.get("DISCORD_ALLOWED_USERS"):
        discord.setdefault("allowed_users", [
            item.strip()
            for item in os.environ["DISCORD_ALLOWED_USERS"].split(",")
            if item.strip()
        ])

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
path.chmod(0o600)
PY

# ── Startup Summary ──
HERMES_RUNTIME_VERSION="$(/opt/hermes/.venv/bin/hermes --version 2>/dev/null | awk '{print $NF; exit}' || true)"
echo ""
if [ -n "${HERMES_RUNTIME_VERSION:-}" ]; then
  echo "Version   : ${HERMES_RUNTIME_VERSION}"
fi
echo "Model     : ${MODEL_FOR_CONFIG:-unset}"
echo "Provider  : ${PROVIDER_FOR_CONFIG:-unset}"
if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
  echo "Discord   : configured"
else
  echo "Discord   : not configured"
fi
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Backup    : ${BACKUP_DATASET} (every ${SYNC_INTERVAL:-600}s)"
else
  echo "Backup    : disabled"
fi
echo "Routes    : /app/ (Hermes UI), /health (readiness)"
echo "Dashboard : http://127.0.0.1:${DASHBOARD_PORT}"
echo "Gateway   : http://127.0.0.1:${GATEWAY_API_PORT}"
echo ""

# ── Trap SIGTERM for graceful shutdown ──
SYNC_LOOP_PID=""
DASHBOARD_PID=""
graceful_shutdown() {
  echo "Shutting down HuggingMes..."
  if [ -n "${HF_TOKEN:-}" ]; then
    python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: shutdown sync failed."
  fi
  kill $(jobs -p) 2>/dev/null || true
  exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── Shell capture wrappers ──
# Written to ~/.bashrc so terminal installs are recorded in workspace/startup.sh
# and replayed on next boot — packages survive Space restarts.
if [ ! -f "$STARTUP_FILE" ]; then
  touch "$STARTUP_FILE"
  chmod +x "$STARTUP_FILE"
  echo "Created workspace/startup.sh"
fi
cat > "$HOME/.bashrc" << 'BASHRC'
export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
if [ -z "${PS1:-}" ] || [ "$PS1" = "$ " ]; then
  export PS1="\u@\h:\w\$ "
fi

HERMES_HOME="${HERMES_HOME:-/opt/data}"
STARTUP_FILE="$HERMES_HOME/workspace/startup.sh"

_hm_append() {
  [ "${HUGGINGMES_CAPTURE_DISABLE:-0}" = "1" ] && return 0
  local line="$*"
  mkdir -p "$(dirname "$STARTUP_FILE")"
  touch "$STARTUP_FILE"
  chmod +x "$STARTUP_FILE" 2>/dev/null || true
  grep -qxF "$line" "$STARTUP_FILE" 2>/dev/null || echo "$line" >> "$STARTUP_FILE"
}
_hm_quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    quoted+=("$arg")
  done
  printf '%s' "${quoted[*]}"
}
_hm_append_cmd() {
  local cmd="$1"
  shift
  local args
  args=$(_hm_quote_args "$@")
  if [ -n "$args" ]; then
    _hm_append "$cmd $args"
  else
    _hm_append "$cmd"
  fi
}
_hm_args_without_flags() {
  local out=()
  for arg in "$@"; do
    case "$arg" in
      ''|-|--*|-*) ;;
      *) out+=("$arg") ;;
    esac
  done
  printf '%s\n' "${out[@]}"
}
_hm_has_install_targets() {
  local item
  while IFS= read -r item; do
    [ -n "$item" ] && return 0
  done <<EOF
$(_hm_args_without_flags "$@")
EOF
  return 1
}
_hm_has_arg() {
  local needle="$1"
  shift
  for arg in "$@"; do
    [ "$arg" = "$needle" ] && return 0
  done
  return 1
}
_hm_can_sudo_apt() {
  command -v sudo >/dev/null 2>&1 && sudo -n apt-get --version >/dev/null 2>&1
}
_hm_apt_install() {
  if [ "$(id -u)" -eq 0 ]; then
    command apt-get update && command apt-get install -y "$@"
  elif _hm_can_sudo_apt; then
    sudo apt-get update && sudo apt-get install -y "$@"
  else
    echo "Error: apt install needs root." >&2
    return 1
  fi
}
apt-get() {
  case "${1:-}" in
    install)
      shift
      _hm_apt_install "$@"
      local rc=$?
      if [ $rc -eq 0 ]; then
        _hm_has_install_targets "$@" && _hm_append_cmd "sudo apt-get update && sudo apt-get install -y" "$@"
      fi
      return $rc
      ;;
    update)
      if [ "$(id -u)" -eq 0 ]; then command apt-get "$@"
      elif _hm_can_sudo_apt; then sudo apt-get "$@"
      else command apt-get "$@"; fi
      return $?
      ;;
    *) command apt-get "$@"; return $? ;;
  esac
}
apt() {
  case "${1:-}" in
    install)
      shift
      _hm_apt_install "$@"
      local rc=$?
      if [ $rc -eq 0 ]; then
        _hm_has_install_targets "$@" && _hm_append_cmd "sudo apt-get update && sudo apt-get install -y" "$@"
      fi
      return $rc
      ;;
    update)
      if [ "$(id -u)" -eq 0 ]; then command apt "$@"
      elif _hm_can_sudo_apt; then sudo apt "$@"
      else command apt "$@"; fi
      return $?
      ;;
    *) command apt "$@"; return $? ;;
  esac
}
pip() {
  command pip "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:2}" && ! _hm_has_arg --requirement "${@:2}" \
      && _hm_has_install_targets "${@:2}"; then
    _hm_append_cmd "pip install" "${@:2}"
  fi
  return $rc
}
pip3() {
  command pip3 "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:2}" && ! _hm_has_arg --requirement "${@:2}" \
      && _hm_has_install_targets "${@:2}"; then
    _hm_append_cmd "pip install" "${@:2}"
  fi
  return $rc
}
uv() {
  command uv "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "pip" ] && [ "${2:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:3}" && ! _hm_has_arg --requirements "${@:3}" \
      && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "uv pip install" "${@:3}"
  fi
  return $rc
}
npm() {
  command npm "$@"
  local rc=$?
  if [ $rc -eq 0 ] && { [ "${1:-}" = "install" ] || [ "${1:-}" = "i" ]; } && { [ "${2:-}" = "-g" ] || [ "${2:-}" = "--global" ]; } && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "npm install -g" "${@:3}"
  fi
  return $rc
}
hermes() {
  command hermes "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "plugins" ] && [ "${2:-}" = "install" ] && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "hermes plugins install" "${@:3}"
  fi
  return $rc
}
BASHRC
cat > "$HOME/.profile" << 'PROFILE'
[ -n "${BASH_VERSION:-}" ] && [ -f ~/.bashrc ] && . ~/.bashrc
PROFILE
echo "Shell capture wrappers ready."

# ── Optional package installs from HF Variables/Secrets ──
HM_STARTUP_FAILURES=0

if [ -n "${HUGGINGMES_APT_PACKAGES:-}" ]; then
  echo "Installing apt packages from HUGGINGMES_APT_PACKAGES..."
  read -r -a HM_APT_PACKAGES <<< "$HUGGINGMES_APT_PACKAGES"
  if command -v sudo >/dev/null 2>&1; then
    if sudo apt-get update && sudo apt-get install -y "${HM_APT_PACKAGES[@]}"; then
      echo "HUGGINGMES_APT_PACKAGES install complete."
    else
      HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
      echo "ERROR: HUGGINGMES_APT_PACKAGES install failed: ${HUGGINGMES_APT_PACKAGES}" >&2
    fi
  elif [ "$(id -u)" -eq 0 ]; then
    if apt-get update && apt-get install -y "${HM_APT_PACKAGES[@]}"; then
      echo "HUGGINGMES_APT_PACKAGES install complete."
    else
      HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
      echo "ERROR: HUGGINGMES_APT_PACKAGES install failed: ${HUGGINGMES_APT_PACKAGES}" >&2
    fi
  else
    HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
    echo "ERROR: root/sudo unavailable; HUGGINGMES_APT_PACKAGES skipped" >&2
  fi
fi

if [ -n "${HUGGINGMES_PIP_PACKAGES:-}" ]; then
  echo "Installing Python packages from HUGGINGMES_PIP_PACKAGES..."
  read -r -a HM_PIP_PACKAGES <<< "$HUGGINGMES_PIP_PACKAGES"
  if /opt/hermes/.venv/bin/pip install "${HM_PIP_PACKAGES[@]}"; then
    echo "HUGGINGMES_PIP_PACKAGES install complete."
  else
    HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
    echo "ERROR: HUGGINGMES_PIP_PACKAGES install failed: ${HUGGINGMES_PIP_PACKAGES}" >&2
  fi
fi

if [ -n "${HUGGINGMES_NPM_PACKAGES:-}" ]; then
  echo "Installing npm packages from HUGGINGMES_NPM_PACKAGES..."
  read -r -a HM_NPM_PACKAGES <<< "$HUGGINGMES_NPM_PACKAGES"
  if npm install -g "${HM_NPM_PACKAGES[@]}"; then
    echo "HUGGINGMES_NPM_PACKAGES install complete."
  else
    HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
    echo "ERROR: HUGGINGMES_NPM_PACKAGES install failed: ${HUGGINGMES_NPM_PACKAGES}" >&2
  fi
fi

# ── Arbitrary startup script (HUGGINGMES_RUN) ──
# Supports plain bash or base64-encoded scripts (prefix with base64: or b64:).
# Example: HUGGINGMES_RUN="pip install pandas && npm install -g typescript"
# Example: HUGGINGMES_RUN="base64:$(base64 -w0 setup.sh)"
hm_run_startup_auto() {
  local payload="$1"
  [ -n "$payload" ] || return 0
  local script_file
  script_file=$(mktemp "/tmp/huggingmes-startup.XXXXXX.sh")
  {
    echo 'export HUGGINGMES_CAPTURE_DISABLE=1'
    echo '[ -f ~/.bashrc ] && . ~/.bashrc'
    if [[ "$payload" == base64:* ]] || [[ "$payload" == b64:* ]]; then
      printf '%s' "${payload#*:}" | base64 -d
    else
      printf '%s\n' "$payload"
    fi
  } > "$script_file"
  chmod 700 "$script_file"
  echo "[startup:HUGGINGMES_RUN] running script"
  set +e
  bash "$script_file"
  local rc=$?
  set -e
  rm -f "$script_file"
  if [ $rc -eq 0 ]; then
    echo "[startup:HUGGINGMES_RUN] ok"
  else
    HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
    echo "ERROR: HUGGINGMES_RUN script failed (exit ${rc})" >&2
  fi
}

if [ -n "${HUGGINGMES_RUN:-}" ]; then
  hm_run_startup_auto "$HUGGINGMES_RUN"
fi

# ── Ensure hermes Python files are writable ──
# hermes v0.17+ self-patches its own .py files inside workspace/startup.sh.
# The files ship read-only in the Docker image; make them writable now so the
# patcher can succeed. Must run after the HF Dataset restore (which runs above)
# in case the restore ever touches /opt/hermes paths via symlinks.
# First make directories traversable — find silently skips dirs without the
# execute bit (errors eaten by 2>/dev/null), so .py files inside them are never
# reached and remain read-only.
# Use a+w (not u+w): these files are owned by root from the Docker build, but
# HF Spaces runs the container as an arbitrary non-root UID at runtime — u+w
# only grants write to the owner (root), which the runtime UID isn't.
find /opt/hermes -type d -exec chmod a+rwx {} + 2>/dev/null || true
find /opt/hermes -name "*.py" -exec chmod a+w {} + 2>/dev/null || true

# ── Run workspace startup script ──
# Replays install commands recorded by the shell wrappers from previous sessions.
if [ -s "$STARTUP_FILE" ]; then
  echo "Running workspace/startup.sh..."
  set +e
  HUGGINGMES_CAPTURE_DISABLE=1 bash -l "$STARTUP_FILE"
  set -e
  echo "Workspace startup script complete."
fi

if [ "$HM_STARTUP_FAILURES" -gt 0 ]; then
  echo "Warning: ${HM_STARTUP_FAILURES} startup step(s) failed. Check logs above." >&2
fi

# ── Start background services ──
node "$APP_DIR/health-server.js" &
HEALTH_PID=$!

if [ -n "${WEBHOOK_URL:-}" ]; then
  python3 - <<'PY' >/dev/null 2>&1 &
import json, os, urllib.request
body = json.dumps({
    "event": "restart",
    "status": "success",
    "message": "HuggingMes Hermes gateway has started.",
    "model": os.environ.get("MODEL_FOR_CONFIG", ""),
}).encode()
req = urllib.request.Request(os.environ["WEBHOOK_URL"], data=body, method="POST", headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
PY
fi

# ── Launch dashboard once (restarts if it dies) ──
start_dashboard_once() {
  if [ -n "${DASHBOARD_PID:-}" ] && kill -0 "$DASHBOARD_PID" 2>/dev/null; then
    return 0
  fi
  echo "Launching Hermes dashboard on 127.0.0.1:${DASHBOARD_PORT}..."
  # Loopback bind: the dashboard's auth gate only engages on non-loopback
  # binds, and the health-server already gates /app/ with GATEWAY_TOKEN.
  (hermes dashboard --host 127.0.0.1 --port "$DASHBOARD_PORT" --no-open 2>&1 | tee -a "$HERMES_HOME/logs/dashboard.log") &
  DASHBOARD_PID=$!
}

# ── Start sync loop once — survives gateway restarts ──
start_background_sync_once() {
  [ -n "${HF_TOKEN:-}" ] || return 0
  if [ -n "${SYNC_LOOP_PID:-}" ] && kill -0 "$SYNC_LOOP_PID" 2>/dev/null; then
    return 0
  fi
  python3 -u "$APP_DIR/hermes-sync.py" loop &
  SYNC_LOOP_PID=$!
}

# Serve the Hermes dashboard on loopback 9119 so the health-server's
# /app/ route has a backend (the base image's s6 dashboard service stays
# down — HERMES_DASHBOARD is unset — so there is no port conflict).
start_dashboard_once

# ── Reclaim gateway ownership from the base image's s6 lifecycle ──
# 02-reconcile-profiles auto-starts an s6-supervised gateway-default slot
# whenever /opt/data/gateway_state.json says "running" (the running
# gateway persists that while it serves). That s6-spawned gateway only
# sees container_environment — never the API_SERVER_KEY start.sh
# generates — so it never opens 8642, and it races the direct launch
# below (the double-run guard makes ours bow out → restart cap →
# container exit 1 → HF restart loop). Down the slot (kills any s6
# gateway) and pin the persisted intent to stopped so the next boot
# registers the slot down as well. The image's own cont-init script
# (99-huggingmes-gateway-owner) does this earlier in the boot; this
# re-asserts it defensively.
SLOT=/run/service/gateway-default
if [ -d "$SLOT" ] && [ ! -f "$SLOT/down" ]; then
  echo "Downing base-image s6 gateway slot (start.sh owns the gateway)..."
  /command/s6-svc -d "$SLOT" 2>/dev/null || true
  for _i in $(seq 1 15); do
    pgrep -f 'gateway\.run' >/dev/null 2>&1 || break
    sleep 1
  done
fi
if [ -f "$HERMES_HOME/gateway_state.json" ]; then
  printf '{"gateway_state":"stopped","desired_state":"stopped","timestamp":%s}\n' "$(date +%s)" > "$HERMES_HOME/gateway_state.json"
  echo "Pinned gateway_state.json to stopped (no s6 gateway auto-start next boot)."
fi
unset SLOT

# ── Gateway restart loop ──
GATEWAY_RESTART_DELAY="${GATEWAY_RESTART_DELAY:-5}"
GATEWAY_MAX_RESTARTS="${GATEWAY_MAX_RESTARTS:-3}"
GATEWAY_RESTART_COUNT=0
GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-120}"

while true; do
  # Monitor health-server — restart if it died unexpectedly
  if [ -n "${HEALTH_PID:-}" ] && ! kill -0 "$HEALTH_PID" 2>/dev/null; then
    echo "Warning: health-server exited (PID $HEALTH_PID dead); restarting..."
    node "$APP_DIR/health-server.js" &
    HEALTH_PID=$!
    echo "Health server restarted (PID: $HEALTH_PID)"
  fi

  # Monitor Hermes dashboard — restart if it died unexpectedly
  if [ -n "${DASHBOARD_PID:-}" ] && ! kill -0 "$DASHBOARD_PID" 2>/dev/null; then
    echo "Warning: Hermes dashboard exited; restarting..."
    start_dashboard_once
  fi

  echo "Launching Hermes gateway..."
  # Launch the gateway via its runtime module directly (python3 -m
  # gateway.run), bypassing the `hermes` CLI: in this container image the CLI
  # intercepts `gateway run` and hands the gateway to s6-supervise, which
  # drops start.sh's exported env — so API_SERVER_KEY never reaches the
  # api_server platform and the 8642 readiness port never opens. Running the
  # module directly keeps the gateway a plain foreground child of start.sh
  # (it inherits API_SERVER_KEY; the restart loop below supervises it).
  GATEWAY_PY="$(head -1 "$(command -v hermes)" | sed 's/^#!//')"
  (cd /opt/hermes && "$GATEWAY_PY" -m gateway.run 2>&1 | tee -a "$HERMES_HOME/logs/gateway.log") &
  GATEWAY_PID=$!

  ready=false
  for ((i=0; i<GATEWAY_READY_TIMEOUT; i++)); do
    if (echo > "/dev/tcp/127.0.0.1/${GATEWAY_API_PORT}") 2>/dev/null; then
      ready=true
      break
    fi
    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [ "$ready" != "true" ]; then
    echo ""
    echo "Hermes gateway failed to expose the API health port. Last 40 log lines:"
    echo "----------------------------------------"
    tail -40 "$HERMES_HOME/logs/gateway.log" || true
    exit 1
  fi

  # Start sync loop (only once — shared across all gateway restarts)
  start_background_sync_once

  set +e
  wait "$GATEWAY_PID"
  GATEWAY_EXIT_CODE=$?
  set -e

  # Sync state before restart
  if [ -n "${HF_TOKEN:-}" ]; then
    echo "Gateway exited — syncing state before restart..."
    python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: sync failed."
  fi

  GATEWAY_RESTART_COUNT=$((GATEWAY_RESTART_COUNT + 1))
  if [ "$GATEWAY_MAX_RESTARTS" != "0" ] && [ "$GATEWAY_RESTART_COUNT" -ge "$GATEWAY_MAX_RESTARTS" ]; then
    echo "Gateway exited (code ${GATEWAY_EXIT_CODE}); restart limit (${GATEWAY_MAX_RESTARTS}) reached."
    exit "$GATEWAY_EXIT_CODE"
  fi

  echo "Gateway exited (code ${GATEWAY_EXIT_CODE}); restarting in ${GATEWAY_RESTART_DELAY}s..."
  sleep "$GATEWAY_RESTART_DELAY"
done
