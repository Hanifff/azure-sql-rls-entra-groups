#!/bin/bash
# ============================================================================
# deploy.sh - build the whole demo from an empty subscription.
#
#   ./deploy.sh                # everything
#   ./deploy.sh --sql-only     # database only: schema, seed, verify, tests
#   ./deploy.sh --skip-apim    # everything except APIM (30-45 min to provision)
#   ./deploy.sh --only-apim    # APIM plus its APIs and policy
#
# Requires the az CLI (logged in) and the .NET SDK. No sqlcmd: infra/sqlrunner
# talks to Azure SQL directly with your Entra token.
#
# Idempotent. Re-running is safe, and running it after destroy.sh rebuilds the
# same names because they are derived, not random.
# ============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

SKIP_APIM=false; ONLY_APIM=false; SQL_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --skip-apim) SKIP_APIM=true ;;
        --only-apim) ONLY_APIM=true ;;
        --sql-only)  SQL_ONLY=true; SKIP_APIM=true ;;
        -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }

az account set --subscription "$SUBSCRIPTION_ID"
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"

echo "Subscription : $SUBSCRIPTION_ID"
echo "Tenant       : $TENANT_ID"
echo "Signed in as : $SQL_ADMIN_UPN"
echo "Region       : $LOCATION"

# ============================================================================
# Database tier
# ============================================================================
if [ "$ONLY_APIM" = false ]; then

step "Resource group $RESOURCE_GROUP"
# A resource group left in 'Deleting' state by a previous destroy would make
# every following command fail, so wait it out rather than erroring.
if [ "$(az group exists -n "$RESOURCE_GROUP")" = "true" ] && \
   [ "$(az group show -n "$RESOURCE_GROUP" --query properties.provisioningState -o tsv 2>/dev/null)" = "Deleting" ]; then
    warn "resource group is still being deleted, waiting"
    az group wait --deleted -n "$RESOURCE_GROUP" --timeout 900 >/dev/null 2>&1 || true
fi
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags "${TAGS[@]}" -o none
ok "ready and tagged"

step "Azure SQL server $SQL_SERVER_NAME (Entra-only authentication)"
if ! az sql server show -g "$RESOURCE_GROUP" -n "$SQL_SERVER_NAME" -o none 2>/dev/null; then
    az sql server create -g "$RESOURCE_GROUP" -n "$SQL_SERVER_NAME" -l "$LOCATION" \
        --enable-ad-only-auth \
        --external-admin-principal-type User \
        --external-admin-name "$SQL_ADMIN_UPN" \
        --external-admin-sid "$CURRENT_USER_OID" \
        --tags "${TAGS[@]}" -o none
    ok "created"
else
    ok "already exists"
fi

az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" \
    -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none
MY_IP=$(curl -fsS https://ifconfig.me 2>/dev/null || true)
if [ -n "$MY_IP" ]; then
    az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" \
        -n AllowDeployer --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" -o none
    ok "firewall allows Azure services and $MY_IP"
fi

step "Azure SQL database $SQL_DB_NAME ($SQL_DB_SKU)"
az sql db create -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" -n "$SQL_DB_NAME" \
    --edition "$SQL_DB_SKU" --capacity 5 --tags "${TAGS[@]}" -o none
ok "ready"

# --- demo Entra groups ------------------------------------------------------
step "Demo Entra groups"
get_or_create_group() {
    local name="$1" id
    id=$(az ad group list --display-name "$name" --query "[0].id" -o tsv 2>/dev/null || true)
    if [ -z "$id" ]; then
        id=$(az ad group create --display-name "$name" --mail-nickname "$name" \
                --description "Azure SQL RLS demo. Safe to delete." \
                --query id -o tsv 2>/dev/null || true)
    fi
    echo "$id"
}

ALPHA_READ=$(get_or_create_group "${DEMO_GROUP_PREFIX}-alpha-read")
ALPHA_WRITE=$(get_or_create_group "${DEMO_GROUP_PREFIX}-alpha-write")
BETA_READ=$(get_or_create_group "${DEMO_GROUP_PREFIX}-beta-read")
BETA_WRITE=$(get_or_create_group "${DEMO_GROUP_PREFIX}-beta-write")

if [ -z "$ALPHA_READ" ] || [ -z "$BETA_READ" ]; then
    warn "could not create Entra groups (insufficient directory permissions)"
    warn "RLS and the tests still run, but on synthetic group IDs only"
    USE_REAL_GROUPS=false
else
    # Asymmetric on purpose: read and write on alpha, read only on beta. That
    # difference is what makes the BLOCK predicate observable in the demo.
    for g in "$ALPHA_READ" "$ALPHA_WRITE" "$BETA_READ"; do
        az ad group member add --group "$g" --member-id "$CURRENT_USER_OID" -o none 2>/dev/null || true
    done
    USE_REAL_GROUPS=true
    ok "alpha read+write, beta read only"
fi

# --- demo users -------------------------------------------------------------
# Without a non-admin identity there is nothing to see: the deployer is the
# Entra admin and bypasses RLS.
step "Demo users"
RW_OID=$(az ad user show --id "$DEMO_USER_READWRITE" --query id -o tsv 2>/dev/null || true)
RO_OID=$(az ad user show --id "$DEMO_USER_READONLY"  --query id -o tsv 2>/dev/null || true)

if [ -n "$RW_OID" ] && [ "$USE_REAL_GROUPS" = true ]; then
    az ad group member add --group "$ALPHA_READ"  --member-id "$RW_OID" -o none 2>/dev/null || true
    az ad group member add --group "$ALPHA_WRITE" --member-id "$RW_OID" -o none 2>/dev/null || true
    ok "$DEMO_USER_READWRITE has read and write on project 1"
else
    warn "read-write demo user not found, skipping ($DEMO_USER_READWRITE)"
fi

if [ -n "$RO_OID" ] && [ "$USE_REAL_GROUPS" = true ]; then
    az ad group member add --group "$BETA_READ" --member-id "$RO_OID" -o none 2>/dev/null || true
    ok "$DEMO_USER_READONLY has read only on project 2"
else
    warn "read-only demo user not found, skipping ($DEMO_USER_READONLY)"
fi

# --- schema, policy, procedures, data ---------------------------------------
step "Building sqlrunner"
dotnet build ./sqlrunner/sqlrunner.csproj -c Release -v q --nologo >/dev/null
RUNNER="dotnet ./sqlrunner/bin/Release/net8.0/sqlrunner.dll"
ok "built"

export SQL_ACCESS_TOKEN
SQL_ACCESS_TOKEN=$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)

step "Schema, RLS policy and procedures"
$RUNNER "$SQL_FQDN" "$SQL_DB_NAME" \
    ./sql/01_schema.sql ./sql/02_policy.sql ./sql/03_procedures.sql
ok "applied"

step "Seeding data"
# The seed carries placeholders for the demo groups so the two example projects
# resolve against real directory objects rather than generated GUIDs.
SEED=$(mktemp /tmp/rls-seed-XXXXXX.sql)
sed -e "s/__ALPHA_WRITE__/${ALPHA_WRITE:-$(uuidgen)}/" \
    -e "s/__ALPHA_READ__/${ALPHA_READ:-$(uuidgen)}/" \
    -e "s/__BETA_WRITE__/${BETA_WRITE:-$(uuidgen)}/" \
    -e "s/__BETA_READ__/${BETA_READ:-$(uuidgen)}/" ./sql/04_seed.sql > "$SEED"
$RUNNER "$SQL_FQDN" "$SQL_DB_NAME" "$SEED"
rm -f "$SEED"
ok "seeded"

step "Registering identities"
GEN_SQL=$(mktemp /tmp/rls-register-XXXXXX.sql)
{
    echo "SET NOCOUNT ON;"
    cat <<SQL
EXEC Security.usp_RefreshUserIdentity;
GO
-- The deployer is the Entra admin and connects as dbo, which bypasses the
-- policy by design. Registering them anyway keeps the access summary honest.
DECLARE @oid UNIQUEIDENTIFIER = '$CURRENT_USER_OID';
DECLARE @pid INT = DATABASE_PRINCIPAL_ID();
DELETE FROM Security.GroupMembership WHERE UserObjectId = @oid;
DELETE FROM Security.UserIdentity    WHERE UserObjectId = @oid OR DatabasePrincipalId = @pid;
INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (@pid, @oid, N'$SQL_ADMIN_UPN');
SQL
    if [ "$USE_REAL_GROUPS" = true ]; then
        cat <<SQL
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES
    (@oid, '$ALPHA_WRITE'), (@oid, '$ALPHA_READ'), (@oid, '$BETA_READ');
SQL
    fi
    cat <<'SQL'
-- Representative breadth: write access on a few hundred projects, which is the
-- realistic shape. Not membership in every group that exists.
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId)
SELECT @oid, pa.EntraIdWrite
FROM dbo.ProjectAccess pa
WHERE pa.ProjectId BETWEEN 100001 AND 100250
  AND NOT EXISTS (SELECT 1 FROM Security.GroupMembership m
                  WHERE m.UserObjectId = @oid AND m.GroupObjectId = pa.EntraIdWrite);
GO
SQL

    # Non-admin demo users. Filtering is only observable when one of these signs
    # in, because the deployer bypasses the policy.
    for PAIR in "${RW_OID}|${DEMO_USER_READWRITE}|rw" "${RO_OID}|${DEMO_USER_READONLY}|ro"; do
        IFS='|' read -r U_OID U_UPN U_KIND <<< "$PAIR"
        [ -z "$U_OID" ] && continue
        cat <<SQL
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$U_UPN')
    CREATE USER [$U_UPN] FROM EXTERNAL PROVIDER;
GO
ALTER ROLE rls_app_user ADD MEMBER [$U_UPN];
GO
EXEC Security.usp_RefreshUserIdentity;
GO
DECLARE @u UNIQUEIDENTIFIER = '$U_OID';
DELETE FROM Security.GroupMembership WHERE UserObjectId = @u;
SQL
        if [ "$U_KIND" = "rw" ]; then
            echo "INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES (@u, '$ALPHA_WRITE'), (@u, '$ALPHA_READ');"
        else
            echo "INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES (@u, '$BETA_READ');"
        fi
        echo "GO"
    done

    cat <<'SQL'
EXEC Security.usp_RecordSyncRun @SyncName = N'EntraGroupMembership', @Status = N'Seeded';
GO
SQL
} > "$GEN_SQL"

$RUNNER "$SQL_FQDN" "$SQL_DB_NAME" "$GEN_SQL"
rm -f "$GEN_SQL"
ok "identities registered"

step "Verifying deployment"
$RUNNER "$SQL_FQDN" "$SQL_DB_NAME" ./sql/05_verify.sql
ok "verification passed"

step "Running RLS enforcement tests"
$RUNNER "$SQL_FQDN" "$SQL_DB_NAME" ./sql/06_test.sql
ok "RLS tests passed"

fi # ONLY_APIM

if [ "$SQL_ONLY" = true ]; then
    echo -e "\n${GREEN}Database ready.${NC} Re-run without --sql-only to deploy the APIs."
    exit 0
fi

# ============================================================================
# Application tier
# ============================================================================
if [ "$ONLY_APIM" = false ]; then

step "Storage, plan and Application Insights"
az storage account create -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" -l "$LOCATION" \
    --sku "$STORAGE_SKU" --kind StorageV2 --tags "${TAGS[@]}" -o none
# The Functions runtime still needs shared key access for its own storage.
az storage account update -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" \
    --allow-shared-key-access true -o none
az appservice plan create -g "$RESOURCE_GROUP" -n "$ASP_NAME" -l "$LOCATION" \
    --sku "$ASP_SKU" --tags "${TAGS[@]}" -o none
az monitor app-insights component create -g "$RESOURCE_GROUP" -a "$APPINSIGHTS_NAME" \
    -l "$LOCATION" --tags "${TAGS[@]}" -o none
APPINSIGHTS_CONN=$(az monitor app-insights component show -g "$RESOURCE_GROUP" \
    -a "$APPINSIGHTS_NAME" --query connectionString -o tsv)
ok "ready"

step "Function apps"
SQL_CONN="Server=tcp:${SQL_FQDN},1433;Initial Catalog=${SQL_DB_NAME};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
for APP in "$FUNCAPP_GRAPHQL" "$FUNCAPP_REST"; do
    az functionapp create -g "$RESOURCE_GROUP" -n "$APP" \
        --storage-account "$STORAGE_ACCOUNT" --plan "$ASP_NAME" \
        --runtime dotnet-isolated --functions-version 4 \
        --tags "${TAGS[@]}" -o none
    az functionapp config appsettings set -g "$RESOURCE_GROUP" -n "$APP" \
        --settings "SqlConnectionString=$SQL_CONN" \
                   "APPLICATIONINSIGHTS_CONNECTION_STRING=$APPINSIGHTS_CONN" -o none
done
ok "created and configured"

step "Building and publishing API code"
publish_app() {
    local project_dir="$1" project_file="$2" app_name="$3"
    pushd "$project_dir" >/dev/null
    rm -rf publish deploy.zip
    # Name the project explicitly: these folders also contain a .sln.
    dotnet publish "$project_file" -c Release -o ./publish -v q --nologo >/dev/null
    (cd publish && zip -qr ../deploy.zip .)
    az functionapp deployment source config-zip -g "$RESOURCE_GROUP" -n "$app_name" --src deploy.zip -o none
    rm -rf publish deploy.zip
    popd >/dev/null
}
publish_app ../graphql-server GraphqlServer.csproj "$FUNCAPP_GRAPHQL"
publish_app ../rest-api RestApiServer.csproj "$FUNCAPP_REST"
ok "both APIs deployed"

fi # ONLY_APIM

# ============================================================================
# API Management
# ============================================================================
if [ "$SKIP_APIM" = false ]; then

step "API Management $APIM_NAME (typically 30-45 minutes on first create)"
if ! az apim show -g "$RESOURCE_GROUP" -n "$APIM_NAME" -o none 2>/dev/null; then
    az apim create -g "$RESOURCE_GROUP" -n "$APIM_NAME" -l "$LOCATION" \
        --publisher-email "$APIM_PUBLISHER_EMAIL" --publisher-name "$APIM_PUBLISHER_NAME" \
        --sku-name "$APIM_SKU" --sku-capacity 1 --tags "${TAGS[@]}" -o none
    ok "created"
else
    ok "already exists"
fi

GRAPHQL_HOST=$(az functionapp show -g "$RESOURCE_GROUP" -n "$FUNCAPP_GRAPHQL" --query defaultHostName -o tsv)
REST_HOST=$(az functionapp show -g "$RESOURCE_GROUP" -n "$FUNCAPP_REST" --query defaultHostName -o tsv)

# APIM strips the API path before forwarding. For REST that leaves /documents to
# append to /api, which is right. For GraphQL it leaves nothing, so the backend
# URL has to name the function itself.
az apim api create -g "$RESOURCE_GROUP" --service-name "$APIM_NAME" --api-id graphql \
    --path graphql --display-name "GraphQL API" \
    --service-url "https://$GRAPHQL_HOST/api/graphql" --protocols https -o none
az apim api create -g "$RESOURCE_GROUP" --service-name "$APIM_NAME" --api-id rest-api \
    --path rest --display-name "REST API" \
    --service-url "https://$REST_HOST/api" --protocols https -o none

# An APIM API with no operations returns 404 for everything. These are pure
# pass-through APIs, so a wildcard per method is all that is needed.
for API in graphql rest-api; do
    for METHOD in GET POST; do
        az apim api operation create -g "$RESOURCE_GROUP" --service-name "$APIM_NAME" \
            --api-id "$API" --operation-id "${API}-${METHOD,,}" \
            --display-name "$METHOD any path" --method "$METHOD" --url-template "/*" \
            -o none 2>/dev/null || true
    done
done
ok "wildcard operations created"

POLICY=$(mktemp /tmp/apim-policy-XXXXXX.xml)
sed "s/__TENANT_ID__/$TENANT_ID/" apim-policy.xml > "$POLICY"

# There is no `az apim api policy` command, so this goes through ARM directly.
# rawxml keeps the policy expressions intact instead of XML-escaping them.
POLICY_BODY=$(mktemp /tmp/apim-policy-XXXXXX.json)
python3 - "$POLICY" "$POLICY_BODY" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    policy = f.read()
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump({"properties": {"format": "rawxml", "value": policy}}, f)
PY

APIM_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}"
for API in graphql rest-api; do
    az rest --method PUT \
        --url "https://management.azure.com${APIM_ID}/apis/${API}/policies/policy?api-version=2022-08-01" \
        --headers "Content-Type=application/json" \
        --body "@$POLICY_BODY" -o none
done
rm -f "$POLICY" "$POLICY_BODY"
ok "APIs and JWT pass-through policy configured"

else
    warn "APIM skipped"
fi

echo -e "\n${GREEN}Deploy complete.${NC}"
echo "  Resource group : $RESOURCE_GROUP"
echo "  Database       : $SQL_FQDN / $SQL_DB_NAME"
[ "$SKIP_APIM" = false ] && echo "  Gateway        : https://${APIM_NAME}.azure-api.net"
echo
echo "Try it:"
echo "  TOKEN=\$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv)"
if [ "$SKIP_APIM" = false ]; then
    echo "  curl -s https://${APIM_NAME}.azure-api.net/rest/health"
    echo "  curl -s https://${APIM_NAME}.azure-api.net/rest/my-access -H \"Authorization: Bearer \$TOKEN\""
    echo "  curl -s https://${APIM_NAME}.azure-api.net/rest/documents -H \"Authorization: Bearer \$TOKEN\""
fi
echo
echo "Sync group membership : ./sync-membership.sh"
echo "Tear everything down  : ./destroy.sh"
