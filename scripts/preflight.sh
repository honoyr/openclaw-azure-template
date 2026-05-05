#!/usr/bin/env bash
# scripts/preflight.sh — sanity checks before deploy.sh
#
# Verifies required CLIs are on PATH, Azure CLI is logged in, the configured
# subscription is accessible, and the resource group exists. Exits 0 on
# success; non-zero with a hint on failure.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"

fail() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
ok()   { echo "OK:    $*"; }

# --- 1. Required CLIs ---
missing_cli=()
for cmd in az gh jq envsubst node python3; do
  command -v "$cmd" >/dev/null 2>&1 || missing_cli+=("$cmd")
done
if [ ${#missing_cli[@]} -gt 0 ]; then
  echo "ERROR: missing required CLIs: ${missing_cli[*]}" >&2
  echo "Install with (macOS, Homebrew):" >&2
  for cmd in "${missing_cli[@]}"; do
    case "$cmd" in
      az)        echo "  brew install azure-cli" >&2 ;;
      gh)        echo "  brew install gh" >&2 ;;
      jq)        echo "  brew install jq" >&2 ;;
      envsubst)  echo "  brew install gettext && brew link --force gettext" >&2 ;;
      node)      echo "  brew install node" >&2 ;;
      python3)   echo "  brew install python@3" >&2 ;;
    esac
  done
  exit 1
fi
ok "all required CLIs present"

# --- 2. Azure CLI logged in ---
if ! az account show >/dev/null 2>&1; then
  fail "az not logged in. Run: az login"
fi
ok "az logged in as: $(az account show --query user.name -o tsv)"

# --- 3. Subscription matches ---
[ -n "${SUBSCRIPTION:-}" ] || fail "SUBSCRIPTION is empty in scripts/env.sh"
current_sub="$(az account show --query id -o tsv)"
if [ "$current_sub" != "$SUBSCRIPTION" ]; then
  warn "active subscription ($current_sub) != configured ($SUBSCRIPTION)"
  warn "fixing with: az account set --subscription $SUBSCRIPTION"
  az account set --subscription "$SUBSCRIPTION"
fi
ok "subscription: $SUBSCRIPTION"

# --- 4. Resource group exists ---
[ -n "${RG:-}" ] || fail "RG is empty in scripts/env.sh"
if ! az group show --name "$RG" >/dev/null 2>&1; then
  warn "resource group '$RG' does not exist"
  echo "Create it with:" >&2
  echo "  az group create --name $RG --location ${LOCATION:-eastus}" >&2
  exit 1
fi
ok "resource group: $RG (in $(az group show --name "$RG" --query location -o tsv))"

echo
echo "Preflight passed. Run scripts/deploy.sh next."
