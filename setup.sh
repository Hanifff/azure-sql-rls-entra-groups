#!/bin/bash
# ============================================================================
# setup.sh - interactive first-run setup.
#
# Asks for the few things that are specific to your directory and subscription,
# checks they are valid, and writes infra/.env for deploy.sh to pick up.
#
#   ./setup.sh            # ask for everything
#   ./setup.sh --show     # print current settings and exit
#   ./setup.sh --reset    # forget saved settings
#
# Nothing written here is secret. infra/.env is gitignored regardless.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE="./infra/.env"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

case "${1:-}" in
    --show)
        [ -f "$ENV_FILE" ] && cat "$ENV_FILE" || echo "No settings yet. Run ./setup.sh"
        exit 0 ;;
    --reset)
        rm -f "$ENV_FILE"; echo "Settings cleared."; exit 0 ;;
    -h|--help)
        sed -n '2,13p' "$0"; exit 0 ;;
esac

command -v az >/dev/null     || die "az CLI not found. See https://aka.ms/azcli"
command -v dotnet >/dev/null || die "dotnet SDK not found. See https://dotnet.microsoft.com/download"
command -v zip >/dev/null    || die "zip not found. Install it with your package manager."

az account show >/dev/null 2>&1 || die "Not signed in. Run: az login"

# Anything already in .env becomes the default answer, so re-running is cheap.
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

ask() {
    local prompt="$1" default="${2:-}" answer
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer
        echo "$answer"
    fi
}

echo "============================================================"
echo " Azure SQL row-level security demo: setup"
echo "============================================================"
echo
echo "This asks for a handful of values, checks them, and saves them to"
echo "infra/.env. Press Enter to accept a default in brackets."

# --- subscription -----------------------------------------------------------
step "Subscription"
az account list --query "[].{name:name, id:id, default:isDefault}" -o table | head -20
CURRENT_SUB=$(az account show --query id -o tsv)
SUBSCRIPTION_ID=$(ask "Subscription ID to deploy into" "${SUBSCRIPTION_ID:-$CURRENT_SUB}")

az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null \
    || die "Cannot select subscription $SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)
SIGNED_IN=$(az account show --query user.name -o tsv)
ok "$(az account show --query name -o tsv)"
ok "tenant $TENANT_ID, signed in as $SIGNED_IN"

# --- region -----------------------------------------------------------------
step "Region"
echo "  Some regions periodically refuse new Azure SQL servers. If the deploy"
echo "  fails with RegionDoesNotAllowProvisioning, run this again and pick"
echo "  another one."
LOCATION=$(ask "Azure region" "${LOCATION:-swedencentral}")
az account list-locations --query "[?name=='$LOCATION'].name" -o tsv | grep -q . \
    || die "Unknown region: $LOCATION"
ok "$LOCATION"

# --- naming -----------------------------------------------------------------
step "Naming"
echo "  Resources are named <abbreviation>-<component>-<environment>-<region>-<instance>,"
echo "  for example rg-rls-demo-${LOCATION}-001."
COMPONENT=$(ask "Component" "${COMPONENT:-rls}")
ENVIRONMENT=$(ask "Environment" "${ENVIRONMENT:-demo}")
ok "resource group will be rg-${COMPONENT}-${ENVIRONMENT}-${LOCATION}-001"

# --- demo users -------------------------------------------------------------
step "Demo users"
cat <<'TEXT'
  Whoever runs the deploy becomes the Entra admin of the SQL server, and an
  Entra admin connects as dbo, which bypasses row-level security by design.
  So you cannot demonstrate filtering with your own account.

  Name two ordinary users in your directory. They do not need any permissions
  and they do not need to be members of anything; the deploy adds them to the
  groups it creates.

    read-write user  gets read and write on project 1
    read-only  user  gets read on project 2, and no write anywhere

  Leave both empty to skip. Everything still deploys and the SQL tests still
  pass, you just cannot show filtering over HTTP.
TEXT
echo

verify_user() {
    local upn="$1"
    [ -z "$upn" ] && return 0
    if az ad user show --id "$upn" --query id -o tsv >/dev/null 2>&1; then
        ok "found $upn"; return 0
    fi
    warn "not found in this directory: $upn"; return 1
}

DEMO_USER_READWRITE=$(ask "Read-write user UPN (blank to skip)" "${DEMO_USER_READWRITE:-}")
verify_user "$DEMO_USER_READWRITE" || warn "the deploy will skip this user"

DEMO_USER_READONLY=$(ask "Read-only user UPN (blank to skip)" "${DEMO_USER_READONLY:-}")
verify_user "$DEMO_USER_READONLY" || warn "the deploy will skip this user"

# --- permission check -------------------------------------------------------
step "Checking directory permissions"
PROBE="rls-setup-probe-$RANDOM"
if PROBE_ID=$(az ad group create --display-name "$PROBE" --mail-nickname "$PROBE" \
                --query id -o tsv 2>/dev/null) && [ -n "$PROBE_ID" ]; then
    az ad group delete --group "$PROBE_ID" 2>/dev/null
    ok "you can create security groups"
else
    warn "you cannot create security groups in this directory"
    warn "the deploy still works, but on synthetic group IDs only, so the"
    warn "end-to-end identity demo will have nothing real to resolve"
fi

# --- scale ------------------------------------------------------------------
step "Demo data size"
echo "  Defaults give 100,000 rows across 2,000 projects, which is enough to"
echo "  make the benchmark meaningful. Lower them if you want a faster deploy."
PROJECT_COUNT=$(ask "Number of projects" "${PROJECT_COUNT:-2000}")
DOCUMENT_COUNT=$(ask "Number of documents" "${DOCUMENT_COUNT:-100000}")

# --- write ------------------------------------------------------------------
mkdir -p ./infra
cat > "$ENV_FILE" <<EOF
# Written by setup.sh. Safe to edit by hand, safe to delete.
# Not committed: .gitignore excludes it.
SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
LOCATION="$LOCATION"
COMPONENT="$COMPONENT"
ENVIRONMENT="$ENVIRONMENT"
DEMO_USER_READWRITE="$DEMO_USER_READWRITE"
DEMO_USER_READONLY="$DEMO_USER_READONLY"
PROJECT_COUNT="$PROJECT_COUNT"
DOCUMENT_COUNT="$DOCUMENT_COUNT"
EOF

step "Saved to $ENV_FILE"
cat "$ENV_FILE" | grep -v '^#'

cat <<TEXT

============================================================
 Next
============================================================

  cd infra
  ./deploy.sh --sql-only     database only, a couple of minutes
  ./deploy.sh                everything, including APIM

APIM takes 30 to 45 minutes to provision and is the expensive part. Start with
--sql-only: the row-level security, the tests and the benchmark all work
without it.

When you are done:

  ./destroy.sh               removes everything, including the Entra groups

TEXT
