#!/usr/bin/env bash
# Build the OpenClaw wrapper image.
#
# 1. Resolve latest stable upstream OpenClaw release (via pull-latest.sh).
# 2. az acr build the wrapper Dockerfile FROM that upstream tag.
# 3. Tag the result as openclaw:custom-<upstream>-<WRAPPER_REV>.
# 4. Record the resulting custom tag in .last-build so deploy.sh can pick it up.
#
# Bump WRAPPER_REV in scripts/env.sh whenever you change docker/Dockerfile or
# docker/openclaw-init.sh. Don't bump it for upstream-only changes.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/env.sh"

: "${ACR_NAME:?ACR_NAME not set}"
: "${SUBSCRIPTION:?SUBSCRIPTION not set}"
: "${WRAPPER_REV:?WRAPPER_REV not set in env.sh (e.g. 1)}"

DOCKER_DIR="$REPO_ROOT/docker"
LAST_BUILD_FILE="$REPO_ROOT/.last-build"

# 1. Resolve + import latest upstream
upstream_tag="$("$HERE/pull-latest.sh" | tail -1)"
[[ -n "$upstream_tag" ]] || { echo "[build] ERROR: pull-latest.sh returned empty tag" >&2; exit 1; }

custom_tag="custom-${upstream_tag}-${WRAPPER_REV}"
base_image="${ACR_NAME}.azurecr.io/openclaw:${upstream_tag}"
target_image="${ACR_NAME}.azurecr.io/openclaw:${custom_tag}"
build_date="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

echo "==> Building $target_image"
echo "    FROM:       $base_image"
echo "    BUILD_DATE: $build_date  (busts npm install layer cache so openclaw@latest is re-resolved)"

az acr build \
  --registry "$ACR_NAME" \
  --subscription "$SUBSCRIPTION" \
  --image "openclaw:${custom_tag}" \
  --build-arg "BASE_IMAGE=${base_image}" \
  --build-arg "BUILD_DATE=${build_date}" \
  --file "$DOCKER_DIR/Dockerfile" \
  "$DOCKER_DIR"

echo "$custom_tag" > "$LAST_BUILD_FILE"

echo
echo "==> Built. Tag: $custom_tag"
echo "    Run: scripts/deploy.sh"
