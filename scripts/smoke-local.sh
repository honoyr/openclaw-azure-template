#!/usr/bin/env bash
# scripts/smoke-local.sh — Tier 1 (local Docker) smoke harness.
#
# Spins up the just-built (or user-pinned) wrapper image with a synthetic
# Tier-1-only config, runs probes #1, #2, #3, #4, #5, #6, #7, optionally #9
# and #13, and prints a TAP-ish report + JSON summary.
#
# See:
#   docs/wip/smoke-test-harness/design.md  (probe matrix)
#   docs/wip/smoke-test-harness/implementation.md  (probe-by-probe spec)
#   docs/discoveries/2026-05-07-openclaw-smoke-tooling-inventory.md  (actual
#     JSON shapes; this script asserts against the real ones, not the
#     inferred ones in design.md)
#
# Env knobs:
#   SMOKE_HAVE_LLM_KEYS=1   Enable LLM-dependent probes (#9, #13).
#   OPENCLAW_LOCAL_IMAGE_TAG  Override which image to run. Default: read
#                             from .last-build (matches prod deploy tag).
#   SMOKE_PORT             Local host port to publish (default 18789).
#   SMOKE_BOOT_TIMEOUT     Seconds to wait for /healthz (default 90).
#
# Secrets (passed into the container as env vars; see
# test/smoke/fixtures/synthetic-config.json for the ${SMOKE_*} refs):
#   SMOKE_GEMINI_API_KEY, SMOKE_AZURE_OPENAI_API_KEY, SMOKE_NVIDIA_API_KEY,
#   SMOKE_BRAVE_SEARCH_API, SMOKE_AZURE_STORAGE_ACCOUNT,
#   SMOKE_AZURE_STORAGE_KEY.
# If unset, scripts/env.sh values (GEMINI_API_KEY etc.) are reused as a
# convenience for local devs. The synthetic config does NOT carry the prod
# telegram bot token (telegram is disabled in T1).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=/dev/null
[ -f "$HERE/env.sh" ] && source "$HERE/env.sh" || true

# shellcheck source=lib/smoke.sh
source "$HERE/lib/smoke.sh"

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

SMOKE_PORT="${SMOKE_PORT:-18789}"
SMOKE_BOOT_TIMEOUT="${SMOKE_BOOT_TIMEOUT:-90}"
SMOKE_HAVE_LLM_KEYS="${SMOKE_HAVE_LLM_KEYS:-0}"
LATENCY_FILE="$REPO_ROOT/test/smoke/.last-latency.json"

# Resolve image tag.
if [ -n "${OPENCLAW_LOCAL_IMAGE_TAG:-}" ]; then
  IMAGE_TAG="$OPENCLAW_LOCAL_IMAGE_TAG"
elif [ -f "$REPO_ROOT/.last-build" ]; then
  IMAGE_TAG="${ACR_NAME}.azurecr.io/openclaw:$(cat "$REPO_ROOT/.last-build")"
else
  echo "smoke-local: no .last-build and no OPENCLAW_LOCAL_IMAGE_TAG set." >&2
  echo "Run scripts/build-image.sh first, or set OPENCLAW_LOCAL_IMAGE_TAG." >&2
  exit 2
fi

# Map prod env-var names to the SMOKE_-prefixed names the synthetic config
# references. Empty strings are fine — probes that need a key will SKIP.
: "${SMOKE_GEMINI_API_KEY:=${GEMINI_API_KEY:-}}"
: "${SMOKE_AZURE_OPENAI_API_KEY:=${AZURE_OPENAI_API_KEY:-}}"
: "${SMOKE_NVIDIA_API_KEY:=${NVIDIA_API_KEY:-}}"
: "${SMOKE_BRAVE_SEARCH_API:=${BRAVE_SEARCH_API:-dummy}}"
: "${SMOKE_AZURE_STORAGE_ACCOUNT:=${AZURE_STORAGE_ACCOUNT:-dummy}}"
: "${SMOKE_AZURE_STORAGE_KEY:=${AZURE_STORAGE_KEY:-dummy}}"

# Encode synthetic config to base64 for OPENCLAW_CONFIG_B64.
CONFIG_FILE="$REPO_ROOT/test/smoke/fixtures/synthetic-config.json"
[ -f "$CONFIG_FILE" ] || { echo "Missing $CONFIG_FILE" >&2; exit 2; }
CONFIG_B64="$(base64 < "$CONFIG_FILE" | tr -d '\n')"

# -----------------------------------------------------------------------------
# Container lifecycle
# -----------------------------------------------------------------------------

LOCAL_CID=""

cleanup() {
  if [ -n "$LOCAL_CID" ]; then
    docker rm -f "$LOCAL_CID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# Helpers specific to Tier 1
# -----------------------------------------------------------------------------

# Run an openclaw subcommand inside the container. Capture stdout cleanly.
in_container() {
  docker exec "$LOCAL_CID" gosu node openclaw "$@"
}

# -----------------------------------------------------------------------------
# Boot
# -----------------------------------------------------------------------------

echo "==> smoke-local Tier 1 — image=${IMAGE_TAG} port=${SMOKE_PORT}"
init_smoke "1"

T_BOOT_START=$(date +%s)

# Pull image if not present locally (no-op if already pulled). Best-effort —
# az acr build leaves it in ACR; user may need `az acr login` separately.
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || {
  echo "==> docker pull $IMAGE_TAG"
  docker pull "$IMAGE_TAG" >/dev/null 2>&1 || {
    echo "smoke-local: failed to pull $IMAGE_TAG. Run 'az acr login --name ${ACR_NAME}' first." >&2
    exit 2
  }
}

LOCAL_CID="$(
  docker run -d --rm \
    -p "${SMOKE_PORT}:18789" \
    -e OPENCLAW_CONFIG_B64="$CONFIG_B64" \
    -e GATEWAY_TOKEN="smoke-local-token" \
    -e GEMINI_API_KEY="$SMOKE_GEMINI_API_KEY" \
    -e AZURE_OPENAI_API_KEY="$SMOKE_AZURE_OPENAI_API_KEY" \
    -e NVIDIA_API_KEY="$SMOKE_NVIDIA_API_KEY" \
    -e BRAVE_SEARCH_API="$SMOKE_BRAVE_SEARCH_API" \
    -e AZURE_STORAGE_ACCOUNT="$SMOKE_AZURE_STORAGE_ACCOUNT" \
    -e AZURE_STORAGE_KEY="$SMOKE_AZURE_STORAGE_KEY" \
    -e SMOKE_AZURE_OPENAI_API_KEY="$SMOKE_AZURE_OPENAI_API_KEY" \
    -e SMOKE_BRAVE_SEARCH_API="$SMOKE_BRAVE_SEARCH_API" \
    "$IMAGE_TAG"
)"
echo "# container=${LOCAL_CID}"

# -----------------------------------------------------------------------------
# Probe 1 — Container alive
# -----------------------------------------------------------------------------

probe1() {
  local state
  state="$(docker inspect --format='{{.State.Status}}' "$LOCAL_CID" 2>/dev/null || echo "missing")"
  if [ "$state" = "running" ]; then
    log_ok 1 "container alive"
  else
    log_fail 1 "container alive" "docker state=${state}"
  fi
}
probe1

# -----------------------------------------------------------------------------
# Probe 2 — Liveness /healthz (with retry during boot)
# -----------------------------------------------------------------------------

probe2() {
  local url="http://127.0.0.1:${SMOKE_PORT}/healthz"
  local body
  local i=0
  local tries="$SMOKE_BOOT_TIMEOUT"
  while [ "$i" -lt "$tries" ]; do
    if body="$(curl -fsS "$url" 2>/dev/null)"; then
      if printf '%s' "$body" | grep -qE 'live|ok'; then
        log_ok 2 "liveness /healthz"
        return 0
      fi
    fi
    i=$((i + 1))
    sleep 1
  done
  log_fail 2 "liveness /healthz" "no 200+match within ${tries}s"
  return 1
}
probe2 || true

# -----------------------------------------------------------------------------
# Probe 3 — Readiness /readyz (also retried)
# -----------------------------------------------------------------------------

probe3() {
  local url="http://127.0.0.1:${SMOKE_PORT}/readyz"
  local i=0 tries=30
  while [ "$i" -lt "$tries" ]; do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      log_ok 3 "readiness /readyz"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  log_fail 3 "readiness /readyz" "no 200 within ${tries}s"
  return 1
}
probe3 || true

# -----------------------------------------------------------------------------
# Probe 4 — Config validate --json
# -----------------------------------------------------------------------------

probe4() {
  local out rc
  out="$(in_container config validate --json 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 4 "config validate" "exit=${rc}"
    return
  fi
  if assert_jq "$out" '.valid == true'; then
    log_ok 4 "config validate"
  else
    local sample
    sample="$(printf '%s' "$out" | _smoke_strip_ansi | head -c 200)"
    log_fail 4 "config validate" ".valid != true (sample: ${sample})"
  fi
}
probe4

# -----------------------------------------------------------------------------
# Probe 5 — Doctor --non-interactive
# -----------------------------------------------------------------------------

probe5() {
  local out err rc
  err="$(mktemp -t smoke-doctor.XXXXXX 2>/dev/null || mktemp)"
  out="$(in_container doctor --non-interactive 2>"$err")" || rc=$?
  rc="${rc:-0}"
  local err_lines
  err_lines="$(grep -E '^ERROR' "$err" 2>/dev/null || true)"
  rm -f "$err"
  if [ "$rc" -ne 0 ]; then
    log_fail 5 "doctor --non-interactive" "exit=${rc}"
    return
  fi
  if [ -n "$err_lines" ]; then
    log_fail 5 "doctor --non-interactive" "stderr has ERROR: $(printf '%s' "$err_lines" | head -1)"
    return
  fi
  log_ok 5 "doctor --non-interactive"
}
probe5

# -----------------------------------------------------------------------------
# Probes 6 & 7 — plugins inspect brave / memory-lancedb
# -----------------------------------------------------------------------------

probe_plugin() {
  local n="$1" id="$2"
  local out rc
  out="$(in_container plugins inspect "$id" --json 2>&1)" || rc=$?
  rc="${rc:-0}"
  if [ "$rc" -ne 0 ]; then
    log_fail "$n" "plugin ${id} loaded" "exit=${rc}"
    return
  fi
  # Per discoveries 2026-05-07: descriptor is under .plugin
  if assert_jq "$out" '.plugin.enabled == true and .plugin.status == "loaded"'; then
    log_ok "$n" "plugin ${id} loaded"
  else
    local why
    why="$(printf '%s' "$out" | _smoke_strip_ansi | jq -r '"enabled=\(.plugin.enabled) status=\(.plugin.status)"' 2>/dev/null || echo "no .plugin")"
    log_fail "$n" "plugin ${id} loaded" "${why}"
  fi
}
probe_plugin 6 "brave"
probe_plugin 7 "memory-lancedb"

# -----------------------------------------------------------------------------
# Probe 9 — LLM primary chat (gated)
# -----------------------------------------------------------------------------

T_LLM_START=""
T_LLM_END=""

probe9() {
  if [ "$SMOKE_HAVE_LLM_KEYS" != "1" ]; then
    log_skip 9 "LLM primary chat" "SMOKE_HAVE_LLM_KEYS!=1"
    return
  fi
  if [ -z "$SMOKE_GEMINI_API_KEY" ]; then
    log_skip 9 "LLM primary chat" "GEMINI_API_KEY not set"
    return
  fi
  local ts pong_token out rc
  ts="$(date +%s)"
  pong_token="PONG-${ts}"
  T_LLM_START="$(date +%s)"
  out="$(with_timeout 30 docker exec "$LOCAL_CID" gosu node openclaw \
    infer model run --json \
    --model google/gemma-4-31b-it \
    --prompt "Reply with exactly the literal token ${pong_token} and nothing else." 2>&1)" || rc=$?
  rc="${rc:-0}"
  T_LLM_END="$(date +%s)"
  if [ "$rc" -ne 0 ]; then
    log_fail 9 "LLM primary chat" "exit=${rc}"
    return
  fi
  # Two checks: response contains PONG-, and the model id starts with the right prefix.
  local clean
  clean="$(printf '%s' "$out" | _smoke_strip_ansi)"
  if ! printf '%s' "$clean" | grep -q 'PONG-'; then
    local sample
    sample="$(printf '%s' "$clean" | tr -d '\n' | head -c 200)"
    log_fail 9 "LLM primary chat" "no PONG- in response (sample: ${sample})"
    return
  fi
  # Model id assertion is best-effort — the JSON shape varies. Try common keys.
  if printf '%s' "$clean" | jq -e 'try (.model // .modelId // .resolvedModel // .response.model // .meta.model // empty) | tostring | startswith("google/gemma-4-31b") or contains("gemma-4-31b")' >/dev/null 2>&1; then
    log_ok 9 "LLM primary chat"
  else
    # Loose match: just substring-check the raw output for the model id.
    if printf '%s' "$clean" | grep -q 'gemma-4-31b'; then
      log_ok 9 "LLM primary chat"
    else
      log_fail 9 "LLM primary chat" "model id not in response (got PONG but no gemma-4-31b)"
    fi
  fi
}
probe9

# -----------------------------------------------------------------------------
# Probe 13 — File handling sentinel — DEFERRED in T1
# -----------------------------------------------------------------------------

probe13() {
  if [ "$SMOKE_HAVE_LLM_KEYS" != "1" ]; then
    log_skip 13 "file upload sentinel" "SMOKE_HAVE_LLM_KEYS!=1"
    return
  fi
  # TODO: wire when the upload endpoint is identified.
  # See docs/discoveries/2026-05-07-openclaw-smoke-tooling-inventory.md
  # "File-upload endpoint shape — deferred". Tier 1 keeps the fixture in
  # place so a future tools.invoke client can pick this up without
  # re-shuffling test/smoke/fixtures/.
  log_skip 13 "file upload sentinel" "deferred (no T1 upload endpoint identified — see 2026-05-07-openclaw-smoke-tooling-inventory.md)"
}
probe13

# -----------------------------------------------------------------------------
# Probe 18 — First-response latency budget (warn-only)
# -----------------------------------------------------------------------------

probe18() {
  if [ -z "$T_LLM_START" ] || [ -z "$T_LLM_END" ]; then
    log_skip 18 "first-response latency" "probe #9 did not run"
    return
  fi
  local cold_to_first=$((T_LLM_END - T_BOOT_START))
  local llm_only=$((T_LLM_END - T_LLM_START))
  mkdir -p "$(dirname "$LATENCY_FILE")"
  printf '{"image":"%s","cold_to_first_response_seconds":%d,"llm_only_seconds":%d,"recorded_at":"%s"}\n' \
    "$IMAGE_TAG" "$cold_to_first" "$llm_only" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LATENCY_FILE"
  if [ "$cold_to_first" -le 30 ]; then
    log_ok 18 "first-response latency (${cold_to_first}s, budget 30s)"
  else
    log_warn 18 "first-response latency" "${cold_to_first}s > 30s budget"
  fi
}
probe18

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

tier_summary
emit_json_summary
smoke_exit_code
