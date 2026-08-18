#!/usr/bin/env bash
# ============================================================================
# check-reachability.sh — verify the outbound endpoints this Space depends on
# ----------------------------------------------------------------------------
# Run INSIDE the Space (one-off diagnostics). Prints a pass/fail table for
# the external endpoints the gateway talks to. Purely informational: it never
# blocks startup and never runs on a schedule.
#
# Usage:  bash scripts/check-reachability.sh
# ============================================================================
set -u

ENDPOINTS=(
  "https://opencode.ai/zen/v1/models|Zen model gateway"
  "https://discord.com/api/v10/gateway|Discord gateway"
  "https://huggingface.co/api/2/whoami-v2|Hugging Face API"
)

check() {
  local url="$1" label="$2" code
  code="$(curl -sS -m 12 -L -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
  if [ -n "$code" ]; then
    printf "  %-28s %s\n" "$label" "$code"
  else
    printf "  %-28s unreachable\n" "$label"
  fi
}

printf "Outbound reachability check (%s)\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for entry in "${ENDPOINTS[@]}"; do
  check "${entry%%|*}" "${entry##*|}"
done
printf "Done. 4xx/5xx codes can still mean 'reachable but auth-gated'.\n"