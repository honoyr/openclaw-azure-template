#!/usr/bin/env bash
# Resolve the latest stable upstream OpenClaw release from GitHub, conditionally
# import it into ACR, and print the resolved upstream tag on stdout.
#
# Usage:
#   scripts/pull-latest.sh                  # use cached resolution if image exists in ACR
#   FORCE=1 scripts/pull-latest.sh          # force re-resolve + re-import
#
# Output:
#   Logs to stderr; the final stdout line is the resolved upstream tag (e.g. "2026.4.27").
#
# State files (gitignored):
#   .upstream-version   Last resolved upstream tag (cache).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/env.sh"

: "${ACR_NAME:?ACR_NAME not set}"
: "${SUBSCRIPTION:?SUBSCRIPTION not set}"

CACHE_FILE="$REPO_ROOT/.upstream-version"
GH_API="https://api.github.com/repos/openclaw/openclaw/releases/latest"

log() { echo "[pull-latest] $*" >&2; }

log "resolving latest stable OpenClaw release..."
upstream_tag="$(curl -fsSL "$GH_API" | jq -r .tag_name | sed 's/^v//')"
[[ -n "$upstream_tag" && "$upstream_tag" != "null" ]] || {
  log "ERROR: failed to resolve tag from $GH_API"
  exit 1
}
log "upstream=$upstream_tag"

cached=""
[[ -f "$CACHE_FILE" ]] && cached="$(cat "$CACHE_FILE")"

if [[ "${FORCE:-0}" != "1" ]]; then
  log "checking ACR for openclaw:$upstream_tag..."
  acr_has_tag="$(az acr repository show-tags \
    --name "$ACR_NAME" \
    --repository openclaw \
    --subscription "$SUBSCRIPTION" \
    --output tsv 2>/dev/null | grep -Fx "$upstream_tag" || true)"

  if [[ "$cached" == "$upstream_tag" && -n "$acr_has_tag" ]]; then
    log "cache hit + ACR has openclaw:$upstream_tag — skipping import"
    echo "$upstream_tag"
    exit 0
  fi
fi

log "importing ghcr.io/openclaw/openclaw:${upstream_tag}-slim -> ${ACR_NAME}.azurecr.io/openclaw:${upstream_tag}"
az acr import \
  --name "$ACR_NAME" \
  --subscription "$SUBSCRIPTION" \
  --source "ghcr.io/openclaw/openclaw:${upstream_tag}-slim" \
  --image "openclaw:${upstream_tag}" \
  --force >&2

echo "$upstream_tag" > "$CACHE_FILE"
log "import complete; cache updated"

echo "$upstream_tag"
