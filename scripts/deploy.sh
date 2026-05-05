#!/usr/bin/env bash
# scripts/deploy.sh — render config, validate env, deploy OpenClaw to ACI.
#
# Steps:
#   1. Source scripts/env.sh
#   2. Validate required env vars (loop; reports all missing at once)
#   3. envsubst over config/config.template.json -> jq . validation
#   4. Inject GATEWAY_TOKEN if pinned
#   5. Fetch ACR credentials and storage account key
#   6. az container delete (existing) + az container create
#   7. Wait for Running, fetch token, print summary
#
# Flags:
#   --dry-run       Stop before az container create; print what would run.
# Env:
#   DEPLOY_DRY_RUN=1   Same as --dry-run.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done
[ "${DEPLOY_DRY_RUN:-0}" = "1" ] && DRY_RUN=1

# --- 1. Validate required env vars (single pass, batched error) ---
required=(
  SUBSCRIPTION RG LOCATION
  ACR_NAME WRAPPER_REV CONTAINER DNS_LABEL
  STORAGE_ACCOUNT WORKSPACE_SHARE WORKSPACE_MOUNT
  AZURE_OPENAI_API_KEY AOAI_BASE_URL AOAI_RESOURCE_NAME
  TELEGRAM_BOT_TOKEN TELEGRAM_OWNER_ID
  BRAVE_SEARCH_API
)
missing=()
for v in "${required[@]}"; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: missing required env vars: ${missing[*]}" >&2
  echo "Edit scripts/env.sh and re-run." >&2
  exit 1
fi

# --- 2. Resolve image tag from .last-build ---
LAST_BUILD_FILE="$REPO_ROOT/.last-build"
[ -f "$LAST_BUILD_FILE" ] || { echo "ERROR: $LAST_BUILD_FILE missing — run scripts/build-image.sh first" >&2; exit 1; }
CUSTOM_TAG="$(cat "$LAST_BUILD_FILE")"
IMAGE="${ACR_NAME}.azurecr.io/openclaw:${CUSTOM_TAG}"

# --- 3. Render config from template via envsubst + jq validation ---
TEMPLATE="$REPO_ROOT/config/config.template.json"
[ -f "$TEMPLATE" ] || { echo "ERROR: $TEMPLATE missing" >&2; exit 1; }

RENDERED="$(mktemp -t openclaw-config.XXXXXX.json)"
trap 'rm -f "$RENDERED"' EXIT

# Export every required var so envsubst sees them. Optional vars are
# exported by env.sh already (or empty); envsubst leaves unset vars literal.
export SUBSCRIPTION RG LOCATION ACR_NAME WRAPPER_REV CONTAINER DNS_LABEL \
  STORAGE_ACCOUNT WORKSPACE_SHARE WORKSPACE_MOUNT \
  AZURE_OPENAI_API_KEY AOAI_BASE_URL AOAI_RESOURCE_NAME \
  NVIDIA_API_KEY GEMINI_API_KEY \
  TELEGRAM_BOT_TOKEN TELEGRAM_OWNER_ID BRAVE_SEARCH_API \
  CF_TUNNEL_TOKEN GATEWAY_TOKEN \
  PHONE_CONTROL_TENANT_ID PHONE_CONTROL_CLIENT_ID PHONE_CONTROL_CLIENT_SECRET

envsubst < "$TEMPLATE" > "$RENDERED"

if ! jq . "$RENDERED" >/dev/null 2>&1; then
  echo "ERROR: rendered config is not valid JSON. Check $TEMPLATE for unescaped" >&2
  echo "       characters or unsubstituted \${VAR} placeholders." >&2
  echo "Rendered file kept at: $RENDERED" >&2
  trap - EXIT
  exit 1
fi
echo "==> Config rendered: $RENDERED"

# Detect any \${VAR} placeholders that survived (i.e. their env var was empty)
remaining=$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$RENDERED" | sort -u || true)
if [ -n "$remaining" ]; then
  echo "WARN: rendered config still contains unsubstituted placeholders:" >&2
  echo "$remaining" >&2
fi

# --- 4. Optional GATEWAY_TOKEN pin ---
if [ -n "${GATEWAY_TOKEN:-}" ]; then
  echo "==> Pinning gateway token from env.sh"
  EFFECTIVE_CONFIG="$(jq --arg t "$GATEWAY_TOKEN" '.gateway.auth.token = $t' "$RENDERED")"
else
  echo "==> GATEWAY_TOKEN not set — OpenClaw will auto-generate a fresh token (rotates on every redeploy)"
  EFFECTIVE_CONFIG="$(cat "$RENDERED")"
fi
CONFIG_B64="$(echo "$EFFECTIVE_CONFIG" | base64 | tr -d '\n')"

# --- 5. Dry-run exit point ---
if [ "$DRY_RUN" = "1" ]; then
  echo
  echo "==> [DRY RUN] would deploy:"
  echo "    image:     $IMAGE"
  echo "    container: $CONTAINER (in $RG, $LOCATION)"
  echo "    storage:   $STORAGE_ACCOUNT / $WORKSPACE_SHARE -> $WORKSPACE_MOUNT"
  echo "    cpu/mem:   ${CPU:-2} / ${MEMORY:-4} GB"
  echo "    config:    $RENDERED ($(wc -c < "$RENDERED") bytes)"
  echo
  echo "[DRY RUN] no Azure resources created."
  trap - EXIT
  exit 0
fi

# --- 6. Real deploy ---
echo "==> Ensuring ACR admin user is enabled"
az acr update --name "$ACR_NAME" --admin-enabled true >/dev/null

ACR_USER="$(az acr credential show --name "$ACR_NAME" --query username -o tsv)"
ACR_PASS="$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)"

AZURE_STORAGE_KEY="$(az storage account keys list \
  --resource-group "$RG" --account-name "$STORAGE_ACCOUNT" \
  --query "[0].value" -o tsv)"
[ -n "$AZURE_STORAGE_KEY" ] || { echo "ERROR: could not fetch storage key for $STORAGE_ACCOUNT" >&2; exit 1; }

echo "==> Deleting existing container (if any)"
az container delete --resource-group "$RG" --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" --yes 2>/dev/null || true

echo "==> Creating container ($IMAGE)"
az container create \
  --resource-group "$RG" \
  --subscription "$SUBSCRIPTION" \
  --name "$CONTAINER" \
  --location "$LOCATION" \
  --image "$IMAGE" \
  --registry-login-server "${ACR_NAME}.azurecr.io" \
  --registry-username "$ACR_USER" \
  --registry-password "$ACR_PASS" \
  --os-type Linux \
  --cpu "${CPU:-2}" \
  --memory "${MEMORY:-4}" \
  --ip-address Public \
  --ports 18789 \
  --dns-name-label "$DNS_LABEL" \
  --azure-file-volume-account-name "$STORAGE_ACCOUNT" \
  --azure-file-volume-account-key "$AZURE_STORAGE_KEY" \
  --azure-file-volume-share-name "$WORKSPACE_SHARE" \
  --azure-file-volume-mount-path "$WORKSPACE_MOUNT" \
  --secure-environment-variables \
    AZURE_OPENAI_API_KEY="$AZURE_OPENAI_API_KEY" \
    TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
    AZURE_STORAGE_ACCOUNT="$STORAGE_ACCOUNT" \
    AZURE_STORAGE_KEY="$AZURE_STORAGE_KEY" \
    AZURE_STORAGE_ACCOUNT_NAME="$STORAGE_ACCOUNT" \
    AZURE_STORAGE_ACCOUNT_KEY="$AZURE_STORAGE_KEY" \
    BRAVE_SEARCH_API="$BRAVE_SEARCH_API" \
    CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}" \
    GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
    NVIDIA_API_KEY="${NVIDIA_API_KEY:-}" \
    OPENCLAW_CONFIG_B64="$CONFIG_B64" \
  >/dev/null

echo "==> Waiting for container to reach Running state"
until [ "$(az container show --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" --query "containers[0].instanceView.currentState.state" -o tsv 2>/dev/null)" = "Running" ]; do
  sleep 10
  echo -n "."
done
echo

echo "==> Waiting for OpenClaw gateway to be ready (~60s on first boot)"
until az container logs --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" 2>&1 | grep -q "gateway.*ready"; do
  sleep 5
  echo -n "."
done
echo

echo "==> Done"
az container show --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" --query "{ip:ipAddress.ip, fqdn:ipAddress.fqdn}" -o table

echo
echo "Access the UI from any browser: http://<fqdn>:18789/"
echo
echo "==> Fetching Gateway Token"
TOKEN="$(az container exec --resource-group "$RG" --subscription "$SUBSCRIPTION" --name "$CONTAINER" \
  --exec-command "gosu node node -e console.log(JSON.parse(require(String.fromCharCode(102,115)).readFileSync('/home/node/.openclaw/openclaw.json')).gateway.auth.token)" 2>&1 \
  | tr -d '\r' | grep -E '^[a-f0-9]{32,}$' | head -n1 || true)"
if [ -n "$TOKEN" ]; then
  echo "Gateway Token: $TOKEN"
else
  echo "WARN: could not extract Gateway Token; fetch manually with az container exec."
fi
