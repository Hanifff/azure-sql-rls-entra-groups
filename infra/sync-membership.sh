#!/bin/bash
# ============================================================================
# sync-membership.sh - the group membership sync, as a runnable script.
#
#   ./sync-membership.sh                  # sync the signed-in user
#   ./sync-membership.sh <oid> [<oid>...] # sync specific Entra object IDs
#   ./sync-membership.sh --all            # sync every user in Security.UserIdentity
#
# This is the demo-scale stand-in for the production component: a timer
# triggered Function or Logic App doing the same three steps on a schedule.
#
#   1. refresh Security.UserIdentity from the database's own principals
#   2. ask Microsoft Graph for each user's TRANSITIVE group membership
#   3. merge the result, so removals revoke access as well as additions
#
# It uses your delegated Graph permissions through the az CLI, so it needs no
# admin consent. The production version authenticates as a managed identity
# holding GroupMember.Read.All and uses a delta query instead of a full read.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

SYNC_ALL=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --all) SYNC_ALL=true ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) ARGS+=("$arg") ;;
    esac
done

if [ ! -f ./sqlrunner/bin/Release/net8.0/sqlrunner.dll ]; then
    dotnet build ./sqlrunner/sqlrunner.csproj -c Release -v q --nologo >/dev/null \
        || die "could not build sqlrunner"
fi
RUNNER=(dotnet ./sqlrunner/bin/Release/net8.0/sqlrunner.dll)

SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
SQL_ACCESS_TOKEN=$(az account get-access-token --resource https://database.windows.net --query accessToken -o tsv) \
    || die "could not acquire a SQL access token"
export SQL_ACCESS_TOKEN

WORKDIR=$(mktemp -d /tmp/rls-sync-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. keep the principal-to-object-ID map current -------------------------
step "Refreshing Security.UserIdentity"
echo "EXEC Security.usp_RefreshUserIdentity;" > "$WORKDIR/refresh.sql"
"${RUNNER[@]}" "$SQL_FQDN" "$SQL_DB_NAME" "$WORKDIR/refresh.sql" >/dev/null \
    || die "could not refresh Security.UserIdentity"
ok "done"

# --- decide which users to sync ---------------------------------------------
if [ "$SYNC_ALL" = true ]; then
    cat > "$WORKDIR/users.sql" <<'SQL'
SET NOCOUNT ON;
SELECT CAST(UserObjectId AS CHAR(36)) AS oid FROM Security.UserIdentity;
SQL
    "${RUNNER[@]}" "$SQL_FQDN" "$SQL_DB_NAME" "$WORKDIR/users.sql" \
        | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | sort -u > "$WORKDIR/oids.txt"
elif [ ${#ARGS[@]} -gt 0 ]; then
    printf '%s\n' "${ARGS[@]}" > "$WORKDIR/oids.txt"
else
    az ad signed-in-user show --query id -o tsv > "$WORKDIR/oids.txt" \
        || die "could not determine the signed-in user"
fi

USER_COUNT=$(grep -c . "$WORKDIR/oids.txt" || true)
[ "$USER_COUNT" -eq 0 ] && die "no users to sync"
ok "$USER_COUNT user(s) to sync"

# --- 2 and 3. read membership from Graph, merge into SQL --------------------
: > "$WORKDIR/merge.sql"
echo "SET NOCOUNT ON;" >> "$WORKDIR/merge.sql"
TOTAL_GROUPS=0

while read -r OID; do
    [ -z "$OID" ] && continue
    step "Reading transitive group membership for $OID"

    # getMemberObjects returns transitive membership, so nested groups are
    # included. memberOf would return direct membership only and silently miss
    # anything inherited through nesting.
    if ! az rest --method POST \
            --url "https://graph.microsoft.com/v1.0/users/${OID}/getMemberObjects" \
            --headers "Content-Type=application/json" \
            --body '{"securityEnabledOnly": true}' \
            --query "value" -o tsv > "$WORKDIR/groups.txt" 2>"$WORKDIR/graph.err"; then
        warn "Graph call failed: $(head -1 "$WORKDIR/graph.err")"
        continue
    fi

    COUNT=$(grep -c . "$WORKDIR/groups.txt" || true)
    if [ "$COUNT" -eq 0 ]; then
        warn "no groups returned for this user"
    else
        ok "$COUNT groups"
    fi
    TOTAL_GROUPS=$((TOTAL_GROUPS + COUNT))

    {
        echo "DECLARE @g Security.GroupIdList;"
        # An empty list is meaningful: it removes every membership the user had.
        if [ "$COUNT" -gt 0 ]; then
            sed -e "s/^/INSERT INTO @g (GroupObjectId) VALUES ('/" -e "s/$/');/" "$WORKDIR/groups.txt"
        fi
        echo "EXEC Security.usp_MergeGroupMembership @UserObjectId = '${OID}', @Groups = @g;"
        echo "GO"
    } >> "$WORKDIR/merge.sql"
done < "$WORKDIR/oids.txt"

{
    echo "EXEC Security.usp_RecordSyncRun @SyncName = N'EntraGroupMembership',"
    echo "     @Status = N'Success', @RowsChanged = ${TOTAL_GROUPS};"
    echo "GO"
} >> "$WORKDIR/merge.sql"

step "Merging into Security.GroupMembership"
"${RUNNER[@]}" "$SQL_FQDN" "$SQL_DB_NAME" "$WORKDIR/merge.sql" >/dev/null \
    || die "merge failed"
ok "merged"

echo -e "\n${GREEN}Sync complete.${NC} ${USER_COUNT} user(s), ${TOTAL_GROUPS} membership rows."
