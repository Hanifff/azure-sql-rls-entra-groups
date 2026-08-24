#!/bin/bash
# ============================================================================
# destroy.sh - remove everything deploy.sh created, including the Entra groups.
#
#   ./destroy.sh           # asks for confirmation
#   ./destroy.sh --yes     # no prompt, for scripted teardown
#   ./destroy.sh --wait    # block until the resource group is really gone
#
# The Entra groups live in the directory rather than the resource group, so
# deleting the group alone would leave them behind. This removes both.
#
# Idempotent: running it when nothing exists is a no-op.
# ============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ASSUME_YES=false; WAIT_FOR_DELETE=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=true ;;
        --wait)   WAIT_FOR_DELETE=true ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }

az account set --subscription "$SUBSCRIPTION_ID"

RG_EXISTS=$(az group exists -n "$RESOURCE_GROUP")

echo "Subscription : $SUBSCRIPTION_ID"
echo "Tenant       : $TENANT_ID"

step "What will be removed"
if [ "$RG_EXISTS" = "true" ]; then
    az resource list -g "$RESOURCE_GROUP" --query "[].{name:name, type:type}" -o table 2>/dev/null || true
else
    echo "  resource group $RESOURCE_GROUP: not present"
fi

echo "  Entra groups:"
FOUND_GROUPS=()
for NAME in "${DEMO_GROUPS[@]}"; do
    GID=$(az ad group list --display-name "$NAME" --query "[0].id" -o tsv 2>/dev/null || true)
    if [ -n "$GID" ]; then
        echo "    $NAME ($GID)"
        FOUND_GROUPS+=("$GID")
    fi
done
[ ${#FOUND_GROUPS[@]} -eq 0 ] && echo "    none present"

if [ "$RG_EXISTS" != "true" ] && [ ${#FOUND_GROUPS[@]} -eq 0 ]; then
    echo -e "\n${GREEN}Nothing to do.${NC}"
    exit 0
fi

if [ "$ASSUME_YES" = false ]; then
    echo
    echo -e "${RED}This permanently deletes the resources listed above.${NC}"
    read -r -p "Type the resource group name to confirm ($RESOURCE_GROUP): " CONFIRM
    if [ "$CONFIRM" != "$RESOURCE_GROUP" ]; then
        echo "Confirmation did not match. Nothing was deleted."
        exit 1
    fi
fi

if [ "$RG_EXISTS" = "true" ]; then
    step "Deleting resource group $RESOURCE_GROUP"
    az group delete -n "$RESOURCE_GROUP" --yes --no-wait
    ok "deletion started"
fi

if [ ${#FOUND_GROUPS[@]} -gt 0 ]; then
    step "Deleting Entra groups"
    for GID in "${FOUND_GROUPS[@]}"; do
        az ad group delete --group "$GID" 2>/dev/null && ok "deleted $GID" || warn "could not delete $GID"
    done
fi

if [ "$WAIT_FOR_DELETE" = true ] && [ "$RG_EXISTS" = "true" ]; then
    step "Waiting for the resource group to disappear"
    az group wait --deleted -n "$RESOURCE_GROUP" --timeout 1800 >/dev/null 2>&1 || true
    ok "gone"
fi

echo -e "\n${GREEN}Teardown complete.${NC} Rebuild with ./deploy.sh"
