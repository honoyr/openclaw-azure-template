#!/usr/bin/env bash
# scripts/lib/smoke.sh — sourceable helpers for the smoke-test harness.
#
# Tier scripts (smoke-local.sh, smoke-staging.sh, smoke-prod.sh) source this
# file, then call init_smoke, then the probe helpers, and finally tier_summary.
#
# Output is TAP-ish: `ok N — name` / `not ok N — name (why)`.
# A one-line JSON summary is also emitted (emit_json_summary) for CI.
#
# Convention: probe ids are the matrix numbers from
# docs/wip/smoke-test-harness/design.md "Smoke surfaces matrix".
#
# Reference: docs/discoveries/2026-05-07-openclaw-smoke-tooling-inventory.md
# for the exact JSON shapes / commands the assertions below depend on.

# Don't enable -u here: this file is sourced; callers vary.

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------

# These are populated by init_smoke and mutated by log_ok / log_fail / etc.
SMOKE_PASSED=0
SMOKE_FAILED=0
SMOKE_SKIPPED=0
SMOKE_WARN=0
SMOKE_TIER=""
# Use plain arrays — bash 3-safe (macOS default).
FAIL_REASONS=()
SKIP_REASONS=()
WARN_REASONS=()
LAST_PROBE_NUM=0

init_smoke() {
  SMOKE_TIER="${1:-?}"
  SMOKE_PASSED=0
  SMOKE_FAILED=0
  SMOKE_SKIPPED=0
  SMOKE_WARN=0
  FAIL_REASONS=()
  SKIP_REASONS=()
  WARN_REASONS=()
  LAST_PROBE_NUM=0
  echo "TAP version 13"
  echo "# tier=${SMOKE_TIER}"
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

log_ok() {
  local n="$1" name="$2"
  echo "ok ${n} — ${name}"
  SMOKE_PASSED=$((SMOKE_PASSED + 1))
  [ "$n" -gt "$LAST_PROBE_NUM" ] && LAST_PROBE_NUM="$n"
}

log_fail() {
  local n="$1" name="$2" why="${3:-}"
  echo "not ok ${n} — ${name}${why:+ (${why})}"
  SMOKE_FAILED=$((SMOKE_FAILED + 1))
  FAIL_REASONS+=("#${n} ${name}: ${why}")
  [ "$n" -gt "$LAST_PROBE_NUM" ] && LAST_PROBE_NUM="$n"
}

log_skip() {
  local n="$1" name="$2" why="${3:-}"
  echo "ok ${n} — ${name} # SKIP ${why}"
  SMOKE_SKIPPED=$((SMOKE_SKIPPED + 1))
  SKIP_REASONS+=("#${n} ${name}: ${why}")
  [ "$n" -gt "$LAST_PROBE_NUM" ] && LAST_PROBE_NUM="$n"
}

log_warn() {
  # Warn-only probe failed: count separately, do NOT increment SMOKE_FAILED.
  local n="$1" name="$2" why="${3:-}"
  echo "ok ${n} — ${name} # WARN ${why}"
  SMOKE_WARN=$((SMOKE_WARN + 1))
  WARN_REASONS+=("#${n} ${name}: ${why}")
  [ "$n" -gt "$LAST_PROBE_NUM" ] && LAST_PROBE_NUM="$n"
}

# -----------------------------------------------------------------------------
# Timeout helper (linux: timeout, macos: gtimeout from coreutils)
# -----------------------------------------------------------------------------

_smoke_timeout_bin=""
_smoke_pick_timeout() {
  if [ -n "$_smoke_timeout_bin" ]; then return 0; fi
  if command -v gtimeout >/dev/null 2>&1; then
    _smoke_timeout_bin="gtimeout"
  elif command -v timeout >/dev/null 2>&1; then
    _smoke_timeout_bin="timeout"
  else
    _smoke_timeout_bin="-"
  fi
}

with_timeout() {
  # Usage: with_timeout <seconds> <cmd> [args...]
  local secs="$1"; shift
  _smoke_pick_timeout
  if [ "$_smoke_timeout_bin" = "-" ]; then
    # No timeout binary; run without (mac without coreutils). Caller may
    # see it hang — document in test/smoke/README.md.
    "$@"
    return $?
  fi
  "$_smoke_timeout_bin" "$secs" "$@"
}

# -----------------------------------------------------------------------------
# Assertion primitives
# -----------------------------------------------------------------------------

_smoke_strip_ansi() {
  # az container exec output carries ANSI color escapes + CRLF; jq chokes.
  sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/\r//g'
}

# Returns 0 if HTTP GET <url> returns 200.
# Optionally takes a bearer token (-H "Authorization: Bearer <token>").
assert_http_200() {
  local url="$1"
  local bearer="${2:-}"
  if [ -n "$bearer" ]; then
    curl -fsS -o /dev/null -H "Authorization: Bearer ${bearer}" "$url"
  else
    curl -fsS -o /dev/null "$url"
  fi
}

# Returns 0 if HTTP GET <url> returns 200 AND `jq -e <expr>` is truthy.
assert_http_json() {
  local url="$1" expr="$2" bearer="${3:-}"
  local body
  if [ -n "$bearer" ]; then
    body="$(curl -fsS -H "Authorization: Bearer ${bearer}" "$url")" || return 1
  else
    body="$(curl -fsS "$url")" || return 1
  fi
  printf '%s' "$body" | jq -e "$expr" >/dev/null
}

# Returns 0 if cmd exits 0. Stdout/stderr are passed through.
assert_cli_exit_0() {
  "$@"
}

# Boolean check on a JSON blob already in $1 (string).
# Usage: assert_jq "$json" '.valid == true'
assert_jq() {
  local json="$1" expr="$2"
  printf '%s' "$json" | _smoke_strip_ansi | jq -e "$expr" >/dev/null
}

# Retry an assertion every 1s up to N times. Used for boot-time readiness.
# Usage: retry_assert <tries> <fn> [args...]
retry_assert() {
  local tries="$1"; shift
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

tier_summary() {
  local total=$((SMOKE_PASSED + SMOKE_FAILED + SMOKE_SKIPPED + SMOKE_WARN))
  echo "1..${LAST_PROBE_NUM}"
  echo "# tier=${SMOKE_TIER} total=${total} passed=${SMOKE_PASSED} failed=${SMOKE_FAILED} warned=${SMOKE_WARN} skipped=${SMOKE_SKIPPED}"
  if [ "$SMOKE_FAILED" -gt 0 ]; then
    echo "# failures:"
    local r
    for r in "${FAIL_REASONS[@]}"; do
      echo "#   ${r}"
    done
  fi
  if [ "$SMOKE_WARN" -gt 0 ]; then
    echo "# warnings:"
    local r
    for r in "${WARN_REASONS[@]}"; do
      echo "#   ${r}"
    done
  fi
  if [ "$SMOKE_SKIPPED" -gt 0 ]; then
    echo "# skipped:"
    local r
    for r in "${SKIP_REASONS[@]}"; do
      echo "#   ${r}"
    done
  fi
}

emit_json_summary() {
  # Single line, machine-parseable.
  local fails="[]" warns="[]" skips="[]"
  if [ "${#FAIL_REASONS[@]}" -gt 0 ]; then
    fails="$(printf '%s\n' "${FAIL_REASONS[@]}" | jq -R . | jq -sc .)"
  fi
  if [ "${#WARN_REASONS[@]}" -gt 0 ]; then
    warns="$(printf '%s\n' "${WARN_REASONS[@]}" | jq -R . | jq -sc .)"
  fi
  if [ "${#SKIP_REASONS[@]}" -gt 0 ]; then
    skips="$(printf '%s\n' "${SKIP_REASONS[@]}" | jq -R . | jq -sc .)"
  fi
  printf '{"tier":"%s","passed":%d,"failed":%d,"warned":%d,"skipped":%d,"failures":%s,"warnings":%s,"skipped_reasons":%s}\n' \
    "$SMOKE_TIER" "$SMOKE_PASSED" "$SMOKE_FAILED" "$SMOKE_WARN" "$SMOKE_SKIPPED" \
    "$fails" "$warns" "$skips"
}

# Tier-script exit code helper: non-zero iff any critical (hard-fail) probe failed.
smoke_exit_code() {
  if [ "$SMOKE_FAILED" -gt 0 ]; then
    return 1
  fi
  return 0
}
