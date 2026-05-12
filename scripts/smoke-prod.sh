#!/usr/bin/env bash
# scripts/smoke-prod.sh — Tier 3 (prod post-deploy + scheduled drift) smoke
# harness. READ-ONLY against the live prod ACI. No file uploads, no Telegram
# message sends, no ACP spawns, no mutating CLI commands.
#
# Probes (matrix numbers from docs/wip/smoke-test-harness/design.md):
#   #1  Container alive            — az container show currentState.state
#   #2  Liveness  (/healthz on direct ACI FQDN port 18789)
#   #3  Readiness (/readyz   on direct ACI FQDN port 18789)
#   #4  Config validate --json   (openclaw config validate --json)
#   #5  Doctor --non-interactive (openclaw doctor --non-interactive)
#   #6  Plugin brave loaded      (openclaw plugins inspect brave --json)
#   #7  Plugin memory-lancedb    (openclaw plugins inspect memory-lancedb --json)
#   #8  Telegram channel up      (openclaw health --json — see note)
#   #9  LLM primary chat         (openclaw infer model run … gemma-4-31b-it)
#   #14 Telegram allowlist + groups + topics counts cross-checked against
#       the running in-container config (gateway-reported counts don't exist
#       in 2026.5.6 — see discoveries/2026-05-07-openclaw-smoke-tooling-inventory.md)
#   #16 Cloudflare tunnel /healthz  (skip if CF_TUNNEL_HOST unset)
#
# Skipped on prod (mutating / chatty / out-of-scope for read-only Tier 3):
#   #10 (LLM fallbacks), #11 (brave web search), #12 (memory recall),
#   #13 (file upload), #17 (ACP spawn).
#
# Note on probe #8: the design spec says use `openclaw status --deep --json`,
# but on 2026.5.6 that command emits a malformed JSON token (missing quote in
# one of the session-key entries) which jq/python both reject. `openclaw
# health --json` returns the same `.channels.telegram` shape (connected,
# tokenStatus, running) and parses cleanly, so we use it instead. If a
# future OpenClaw version fixes the bug, switching back is one line.
#
# Time budget: ≤ 60s. Most probes are sub-second; #5 (doctor) and #9 (LLM)
# dominate. Each is wrapped in with_timeout.
#
# Exit code: 0 if all hard-fail probes pass; non-zero on any hard-fail.
#
# Usage:
#   scripts/smoke-prod.sh            # prints TAP + JSON summary
#
# Reads from scripts/env.sh: SUBSCRIPTION, RG, CONTAINER, DNS_LABEL, LOCATION
# (required); CF_TUNNEL_HOST (optional — probe #16 skips if unset).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

if [ ! -f "$HERE/env.sh" ]; then
  echo "smoke-prod: $HERE/env.sh missing — copy scripts/env.sh.example to scripts/env.sh and fill in." >&2
  exit 2
fi
# shellcheck source=/dev/null
source "$HERE/env.sh"

# shellcheck source=lib/smoke.sh
source "$HERE/lib/smoke.sh"

# Required env vars from env.sh.
: "${SUBSCRIPTION:?smoke-prod: SUBSCRIPTION not set in scripts/env.sh}"
: "${RG:?smoke-prod: RG not set in scripts/env.sh}"
: "${CONTAINER:?smoke-prod: CONTAINER not set in scripts/env.sh}"
: "${DNS_LABEL:?smoke-prod: DNS_LABEL not set in scripts/env.sh}"
: "${LOCATION:?smoke-prod: LOCATION not set in scripts/env.sh}"

FQDN="${DNS_LABEL}.${LOCATION}.azurecontainer.io"

# -----------------------------------------------------------------------------
# Helpers specific to Tier 3
# -----------------------------------------------------------------------------

# Run an openclaw subcommand inside the live ACI container. All output (stdout
# + stderr) is captured, ANSI-stripped, and CRLFs removed so the result is
# safe to pipe into jq. Wrapped in a generous timeout so a hung exec doesn't
# blow the 60s tier budget. Bumped to 60s for `doctor` which can take >30s
# round-trip from GH-hosted runners (slower path than a developer Mac).
in_container() {
  with_timeout "${SMOKE_EXEC_TIMEOUT:-60}" az container exec \
    --resource-group "$RG" \
    --subscription "$SUBSCRIPTION" \
    --name "$CONTAINER" \
    --exec-command "gosu node openclaw $*" 2>&1 \
    | _smoke_strip_ansi
}

# Read the deployed config file directly from inside the container.
# Used by probe #14 since 2026.5.6 has no `openclaw config show --json`
# subcommand and gateway status doesn't expose telegram counts.
#
# Note: `az container exec` has a transport flake that occasionally drops a
# single character on multi-KB outputs (observed ~1 in 4 reads of the ~10KB
# config). We retry up to 3 times until the output parses as JSON; this is
# read-only and idempotent, so retry is safe.
in_container_cat_config() {
  local i out
  for i in 1 2 3; do
    out="$(with_timeout 30 az container exec \
      --resource-group "$RG" \
      --subscription "$SUBSCRIPTION" \
      --name "$CONTAINER" \
      --exec-command "gosu node cat /home/node/.openclaw/openclaw.json" 2>&1 \
      | _smoke_strip_ansi)"
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
  done
  # Last attempt's output, even if not parseable — caller will diagnose.
  printf '%s' "$out"
  return 0
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------

init_smoke "3"

IMAGE_TAG="$(az container show \
  --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
  --query "containers[0].image" -o tsv 2>/dev/null || echo "<unknown>")"

echo "# fqdn=${FQDN}"
echo "# container=${CONTAINER}"
echo "# image=${IMAGE_TAG}"
[ -n "${CF_TUNNEL_HOST:-}" ] && echo "# cf_tunnel_host=${CF_TUNNEL_HOST}" || echo "# cf_tunnel_host=<unset, probe #16 will skip>"

# Cache for the health blob — used by probes #8 and #14 so we only call
# `openclaw health --json` once.
HEALTH_JSON=""

# -----------------------------------------------------------------------------
# Probe 1 — Container alive
# -----------------------------------------------------------------------------

probe1() {
  local state
  state="$(az container show \
    --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
    --query "containers[0].instanceView.currentState.state" -o tsv 2>/dev/null || echo "")"
  if [ "$state" = "Running" ]; then
    log_ok 1 "container alive"
  else
    log_fail 1 "container alive" "az currentState.state=${state:-<empty>}"
  fi
}
probe1

# -----------------------------------------------------------------------------
# Probe 2 — Liveness /healthz (direct ACI FQDN)
# -----------------------------------------------------------------------------

probe2() {
  local url="http://${FQDN}:18789/healthz"
  local body
  if ! body="$(curl -fsS --max-time 10 "$url" 2>/dev/null)"; then
    log_fail 2 "liveness /healthz" "curl failed (${url})"
    return
  fi
  if printf '%s' "$body" | grep -qE 'live|ok'; then
    log_ok 2 "liveness /healthz"
  else
    local sample
    sample="$(printf '%s' "$body" | tr -d '\n' | head -c 120)"
    log_fail 2 "liveness /healthz" "body did not match live|ok (got: ${sample})"
  fi
}
probe2

# -----------------------------------------------------------------------------
# Probe 3 — Readiness /readyz (direct ACI FQDN)
# -----------------------------------------------------------------------------

probe3() {
  local url="http://${FQDN}:18789/readyz"
  if curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    log_ok 3 "readiness /readyz"
  else
    log_fail 3 "readiness /readyz" "curl !=200 (${url})"
  fi
}
probe3

# -----------------------------------------------------------------------------
# Probe 4 — Config validate --json
# -----------------------------------------------------------------------------

probe4() {
  local out rc=0
  out="$(in_container config validate --json)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 4 "config validate" "exit=${rc}"
    return
  fi
  if assert_jq "$out" '.valid == true'; then
    log_ok 4 "config validate"
  else
    local sample
    sample="$(printf '%s' "$out" | head -c 200 | tr -d '\n')"
    log_fail 4 "config validate" ".valid != true (sample: ${sample})"
  fi
}
probe4

# -----------------------------------------------------------------------------
# Probe 5 — Doctor --non-interactive
# -----------------------------------------------------------------------------

probe5() {
  # az container exec interleaves stdout+stderr; we run via in_container which
  # captures both. We treat any line beginning with "ERROR" (case-insensitive
  # "^ERROR") as a hard fail. Cosmetic advisories on prod (legacy
  # messages.tts.enabled, gateway.mode unset, missing commands.ownerAllowFrom)
  # do not start with "ERROR" — see
  # docs/discoveries/2026-05-07-openclaw-smoke-tooling-inventory.md.
  local out rc=0
  out="$(in_container doctor --non-interactive)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 5 "doctor --non-interactive" "exit=${rc}"
    return
  fi
  local err_lines
  err_lines="$(printf '%s\n' "$out" | grep -E '^ERROR' || true)"
  if [ -n "$err_lines" ]; then
    log_fail 5 "doctor --non-interactive" "stderr/stdout has ERROR: $(printf '%s' "$err_lines" | head -1 | head -c 160)"
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
  local out rc=0
  out="$(in_container plugins inspect "$id" --json)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail "$n" "plugin ${id} loaded" "exit=${rc}"
    return
  fi
  if assert_jq "$out" '.plugin.enabled == true and .plugin.status == "loaded"'; then
    log_ok "$n" "plugin ${id} loaded"
  else
    local why
    why="$(printf '%s' "$out" | jq -r '"enabled=\(.plugin.enabled) status=\(.plugin.status)"' 2>/dev/null || echo "no .plugin")"
    log_fail "$n" "plugin ${id} loaded" "${why}"
  fi
}
probe_plugin 6 "brave"
probe_plugin 7 "memory-lancedb"

# -----------------------------------------------------------------------------
# Probe 8 — Telegram channel connected (cached blob, also feeds #14)
# -----------------------------------------------------------------------------

probe8() {
  local rc=0
  HEALTH_JSON="$(in_container health --json)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 8 "telegram channel connected" "openclaw health --json exit=${rc}"
    return
  fi
  if assert_jq "$HEALTH_JSON" '.channels.telegram.connected == true'; then
    log_ok 8 "telegram channel connected"
  else
    local why
    why="$(printf '%s' "$HEALTH_JSON" | jq -r '"connected=\(.channels.telegram.connected) tokenStatus=\(.channels.telegram.tokenStatus) running=\(.channels.telegram.running)"' 2>/dev/null || echo "no .channels.telegram")"
    log_fail 8 "telegram channel connected" "${why}"
  fi
}
probe8

# -----------------------------------------------------------------------------
# Probe 9 — LLM primary chat (read-only; throwaway sentinel token)
# -----------------------------------------------------------------------------
#
# `openclaw infer model run` is stateless on 2026.5.6 — it doesn't take a
# session id (verified against `infer model run --help` in the inventory
# doc), so we don't pass one. The PONG-PROD-<ts> sentinel makes it obvious
# in any provider-side log this is a smoke probe.

probe9() {
  local ts pong rc=0 out cfg_json primary
  ts="$(date +%s)"
  pong="PONG-PROD-${ts}"
  # Resolve the configured primary chat model from the deployed config so this
  # probe stays correct across model swaps (gemma → openai/gpt-5.5 → …).
  cfg_json="$(in_container_cat_config 2>/dev/null || true)"
  primary="$(printf '%s' "$cfg_json" | jq -r '.agents.defaults.model.primary // empty' 2>/dev/null || true)"
  if [ -z "$primary" ]; then
    log_fail 9 "LLM primary chat" "could not resolve agents.defaults.model.primary from in-container config"
    return
  fi
  # Match anything before the slash for the model-id grep (provider-stripped name).
  local model_id="${primary#*/}"
  out="$(with_timeout 30 az container exec \
    --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
    --exec-command "gosu node openclaw infer model run --json --model ${primary} --prompt 'Reply with literally ${pong} and nothing else.'" \
    2>&1 | _smoke_strip_ansi)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 9 "LLM primary chat (${primary})" "exit=${rc}"
    return
  fi
  if ! printf '%s' "$out" | grep -q 'PONG-PROD-'; then
    local sample
    sample="$(printf '%s' "$out" | tr -d '\n' | head -c 200)"
    log_fail 9 "LLM primary chat (${primary})" "no PONG-PROD- in response (sample: ${sample})"
    return
  fi
  if printf '%s' "$out" | grep -qF "$model_id"; then
    log_ok 9 "LLM primary chat (${primary})"
  else
    log_fail 9 "LLM primary chat (${primary})" "got PONG- but no ${model_id} in response (model misroute?)"
  fi
}
probe9

# -----------------------------------------------------------------------------
# Skip marker for #10–#13 (mutating / chatty / out of scope for read-only T3)
# -----------------------------------------------------------------------------

echo "# SKIP tier-3 mutating probes (#10 #11 #12 #13)"

# -----------------------------------------------------------------------------
# Probe 14 — Telegram channel health + config-count cross-check
# -----------------------------------------------------------------------------
#
# Two assertions:
#   a. From the cached health blob (#8): connected==true, tokenStatus=="available",
#      running==true. (`status --deep --json` would have been the spec'd
#      source, but it emits malformed JSON on 2026.5.6 — see file header.)
#   b. The deployed in-container config has at least one entry in
#      channels.telegram.allowFrom and channels.telegram.groups, and at
#      least one mapped topic across all groups. Note: gateway-reported
#      counts do not exist in 2026.5.6 (status --deep does not include
#      `allowFromCount`/`groupsCount` keys — see inventory doc), so this
#      probe asserts the config has the *shape* a healthy prod expects;
#      a future version that exposes counts can be tightened here.

probe14() {
  if [ -z "$HEALTH_JSON" ]; then
    log_fail 14 "telegram channel health + counts" "no cached health blob (probe #8 did not run)"
    return
  fi
  if ! assert_jq "$HEALTH_JSON" '.channels.telegram.connected == true and .channels.telegram.tokenStatus == "available" and .channels.telegram.running == true'; then
    local why
    why="$(printf '%s' "$HEALTH_JSON" | jq -c '.channels.telegram | {connected, tokenStatus, running}' 2>/dev/null || echo "no .channels.telegram")"
    log_fail 14 "telegram channel health + counts" "health: ${why}"
    return
  fi

  local cfg_json rc=0
  cfg_json="$(in_container_cat_config)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 14 "telegram channel health + counts" "could not read in-container config (exit=${rc})"
    return
  fi
  # Validate JSON parses before counting (catches drift if the config write
  # path ever stops being well-formed JSON).
  if ! printf '%s' "$cfg_json" | jq -e . >/dev/null 2>&1; then
    log_fail 14 "telegram channel health + counts" "in-container openclaw.json is not valid JSON"
    return
  fi
  local counts allow groups topics
  counts="$(printf '%s' "$cfg_json" | jq -c '
    .channels.telegram as $t |
    {
      allow:  (($t.allowFrom // []) | length),
      groups: (($t.groups    // {}) | length),
      topics: ([ ($t.groups // {}) | to_entries[] | .value.topics // {} | keys ] | flatten | length)
    }')"
  allow="$(printf '%s' "$counts" | jq -r '.allow')"
  groups="$(printf '%s' "$counts" | jq -r '.groups')"
  topics="$(printf '%s' "$counts" | jq -r '.topics')"
  if [ "${allow:-0}" -ge 1 ] && [ "${groups:-0}" -ge 1 ] && [ "${topics:-0}" -ge 1 ]; then
    log_ok 14 "telegram channel health + counts (allow=${allow} groups=${groups} topics=${topics})"
  else
    log_fail 14 "telegram channel health + counts" "config counts allow=${allow} groups=${groups} topics=${topics}; expected all>=1"
  fi
}
probe14

# -----------------------------------------------------------------------------
# Probe 16 — Cloudflare tunnel /healthz
# -----------------------------------------------------------------------------

probe16() {
  if [ -z "${CF_TUNNEL_HOST:-}" ]; then
    log_skip 16 "cloudflare tunnel /healthz" "CF_TUNNEL_HOST unset"
    return
  fi
  local url="https://${CF_TUNNEL_HOST}/healthz"
  local body
  if ! body="$(curl -fsS --max-time 10 "$url" 2>/dev/null)"; then
    log_fail 16 "cloudflare tunnel /healthz" "curl failed (${url})"
    return
  fi
  if printf '%s' "$body" | grep -qE 'live|ok'; then
    log_ok 16 "cloudflare tunnel /healthz"
  else
    local sample
    sample="$(printf '%s' "$body" | tr -d '\n' | head -c 120)"
    log_fail 16 "cloudflare tunnel /healthz" "body did not match live|ok (got: ${sample})"
  fi
}
probe16

# -----------------------------------------------------------------------------
# Probe 17: photo-inbox cron job is registered (warn-only)
# -----------------------------------------------------------------------------

probe17() {
  local rc=0 out
  out="$(in_container cron list --json 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn 17 "photo-inbox cron registered" "openclaw cron list exit=${rc}"
    return
  fi
  # Extract the JSON object (CLI emits a banner first).
  local job_json
  job_json="$(printf '%s' "$out" | python3 -c '
import sys, json, re
t = sys.stdin.read()
m = re.search(r"\{[\s\S]*\}", t)
if not m:
    sys.exit(2)
try:
    j = json.loads(m.group())
except Exception:
    sys.exit(3)
for x in j.get("jobs", []):
    if x.get("name") == "photo-inbox-extract":
        print(json.dumps(x))
        sys.exit(0)
sys.exit(4)
' 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$job_json" ]; then
    log_warn 17 "photo-inbox cron registered" "job 'photo-inbox-extract' not found (rc=${rc})"
    return
  fi
  local enabled next_run_ms now_ms diff_h
  enabled="$(printf '%s' "$job_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("enabled",False))' 2>/dev/null || echo "False")"
  next_run_ms="$(printf '%s' "$job_json" | python3 -c '
import sys, json
j = json.load(sys.stdin)
print(j.get("state", {}).get("nextRunAtMs") or j.get("nextRunAtMs") or 0)
' 2>/dev/null || echo "0")"
  if [ "$enabled" != "True" ]; then
    log_warn 17 "photo-inbox cron registered" "enabled=${enabled}"
    return
  fi
  now_ms=$(($(date +%s) * 1000))
  diff_h=$(( (next_run_ms - now_ms) / 3600000 ))
  if [ "$next_run_ms" -le 0 ] || [ "$diff_h" -gt 25 ] || [ "$diff_h" -lt -1 ]; then
    log_warn 17 "photo-inbox cron registered" "next_run unhealthy (Δ=${diff_h}h, ms=${next_run_ms})"
    return
  fi
  log_ok 17 "photo-inbox cron registered (next_run in ${diff_h}h)"
}
probe17

# -----------------------------------------------------------------------------
# Probe 19 — container-log forbidden patterns
# -----------------------------------------------------------------------------
#
# Hard-fails on any post-boot log line matching a known regression signature
# we have hit in production. Each pattern below was a real outage diagnosed
# in this deployment's history; codifying them here catches recurrence
# without waiting for a user complaint.
#
# Patterns (with citation to the incident that motivated them):
#   • "Requested agent harness .* is not registered"
#       — codex/openai harness not loaded (e.g. missing plugins.entries.codex
#         on a build that doesn't auto-enable it). Manifests as Telegram
#         showing typing-indicator with no reply.
#   • "insecure permissions 7\d\d"
#       — Azure Files SMB mount perms (always 0777 on ACI) blocking the
#         agent secret-dir check. Fixed by local-fs materialization in
#         openclaw-init.sh; this probe catches regressions if the init
#         script ever stops materializing.
#   • "startup model warmup failed"
#       — primary model unreachable at boot (auth profile missing, Azure
#         Foundry deployment removed, etc.). Boot succeeds but every turn
#         fails over to fallbacks or fails outright.
#   • "Failed to load model catalog"
#       — agent model catalog can't load (perms, missing models.json, JSON
#         parse error). Causes "agent harness not registered" downstream.
#   • "surface_error.*reason=format"
#       — provider returned a non-200 the LLM lane could not reshape.
#         Real cases: Foundry "API version not supported" 400 on audio
#         attachments; Foundry 404 when openai/* namespace is hijacked.
#   • "provider rejected the request schema or tool payload"
#       — user-visible companion of the above. We've seen Telegram surface
#         this verbatim when fallback chains exhausted.
#   • "Embedded agent failed before reply"
#       — generic "turn died before producing content"; correlates 1:1 with
#         the harness-not-registered error in this deployment.
#
# Scan window: last 200 log lines. Recent enough to not flag long-resolved
# transient errors from before a redeploy, large enough to catch any error
# from the typical 30–60s boot + first warmup window. Boot-only errors
# (pre-"gateway ready") are filtered out so a transient cloudflared origin
# refused while the gateway is starting doesn't cause a false positive.

probe19() {
  local logs rc=0
  logs="$(with_timeout 20 az container logs \
    --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
    2>&1 | tail -200)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_fail 19 "no forbidden log patterns" "az container logs exit=${rc}"
    return
  fi
  # Only consider lines from after the most recent "gateway ready" — any
  # error before that is a startup-phase transient (e.g. cloudflared origin
  # refused while gateway is binding). If "gateway ready" hasn't been hit
  # yet, scan everything (fail-loud).
  local post_ready
  post_ready="$(printf '%s\n' "$logs" | awk '
    /gateway.*ready/ { found=1; out="" }
    found { out = out $0 "\n" }
    END { printf "%s", out }
  ')"
  [ -z "$post_ready" ] && post_ready="$logs"

  # Each entry is "regex|short-name". Pipe-delim because regexes contain
  # spaces and we keep this readable.
  local patterns=(
    'Requested agent harness .* is not registered|harness-not-registered'
    'insecure permissions 7[0-9][0-9]|insecure-perms-777'
    'startup model warmup failed|model-warmup-failed'
    'Failed to load model catalog|model-catalog-load-failed'
    'surface_error.*reason=format|provider-reject-format'
    'provider rejected the request schema or tool payload|provider-reject-user-visible'
    'Embedded agent failed before reply|embedded-agent-failed'
  )
  local hits=()
  local p re short match
  for p in "${patterns[@]}"; do
    re="${p%%|*}"
    short="${p##*|}"
    if match="$(printf '%s' "$post_ready" | grep -E "$re" | head -1)"; then
      if [ -n "$match" ]; then
        hits+=("${short}: $(printf '%s' "$match" | tr -d '\r' | head -c 140)")
      fi
    fi
  done
  if [ "${#hits[@]}" -eq 0 ]; then
    log_ok 19 "no forbidden log patterns (last 200 lines, post-ready)"
  else
    local detail
    detail="$(printf '%s; ' "${hits[@]}")"
    log_fail 19 "no forbidden log patterns" "${detail}"
  fi
}
probe19

# -----------------------------------------------------------------------------
# Probe 20 — agent harness for primary model is registered
# -----------------------------------------------------------------------------
#
# Read-only positive check that pairs with #19. We synthesize a stateless
# infer call against the configured primary and inspect the error path:
# if it returns "Requested agent harness ... is not registered.", the
# harness for whatever runtime that model resolves to (codex for openai/*,
# native for everything else) is missing — exactly the regression that
# silently broke Telegram in May 2026.
#
# This complements #9 (which also exercises the primary) by failing fast
# even when #9 passes for unrelated reasons (e.g. a fallback returning
# the sentinel). #9 cares about producing PONG-; #20 cares about the
# harness binding and runs first.

probe20() {
  local cfg_json primary out rc=0
  cfg_json="$(in_container_cat_config 2>/dev/null || true)"
  primary="$(printf '%s' "$cfg_json" | jq -r '.agents.defaults.model.primary // empty' 2>/dev/null || true)"
  if [ -z "$primary" ]; then
    log_fail 20 "agent harness for primary registered" "could not resolve primary model"
    return
  fi
  out="$(with_timeout 25 az container exec \
    --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
    --exec-command "gosu node openclaw infer model run --json --model ${primary} --prompt 'ping'" \
    2>&1 | _smoke_strip_ansi)" || rc=$?
  if printf '%s' "$out" | grep -qE 'Requested agent harness .* is not registered'; then
    local h
    h="$(printf '%s' "$out" | grep -oE 'Requested agent harness "[^"]+" is not registered' | head -1)"
    log_fail 20 "agent harness for primary registered (${primary})" "${h:-harness missing}"
    return
  fi
  log_ok 20 "agent harness for primary registered (${primary})"
}
probe20

# -----------------------------------------------------------------------------
# Skip marker for #18 (ACP spawn — mutating)
# -----------------------------------------------------------------------------

echo "# SKIP tier-3 mutating probe (#18)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

tier_summary
emit_json_summary
smoke_exit_code
