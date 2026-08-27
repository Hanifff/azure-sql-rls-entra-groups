#!/bin/bash
# ============================================================================
# demo.sh - run the demo without setting anything up first.
#
#   ./demo.sh              reset, then walk the eight-step story
#   ./demo.sh reset        put the data back, nothing else
#   ./demo.sh story        run the story without resetting first
#   ./demo.sh readwrite    the read plus write story, with filtering on
#   ./demo.sh tables       show all five tables, for opening the demo
#   ./demo.sh access       who is entitled to read and write what
#   ./demo.sh who anna     one user in full, with the project mapping
#   ./demo.sh compare      read and write, both users, both modes, one table
#   ./demo.sh step N       run just step N of the write story (1-8)
#   ./demo.sh rwstep N     run just step N of the read plus write story (1-7)
#   ./demo.sh read on      turn read filtering on
#   ./demo.sh read off     turn read filtering off (the default)
#   ./demo.sh bench        logical reads and timings
#   ./demo.sh policy       print the predicate and policy
#   ./demo.sh tests        the 7 enforcement tests
#
# Handles the token, the config and the firewall on its own. If your IP has
# changed since the last run it fixes that too, which is the usual reason a
# demo fails to connect.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}  ok${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

if [ ! -f ./sqlrunner/bin/Release/net8.0/sqlrunner.dll ]; then
    info "building sqlrunner"
    dotnet build ./sqlrunner/sqlrunner.csproj -c Release -v q --nologo >/dev/null || die "build failed"
fi

export SQL_ACCESS_TOKEN
SQL_ACCESS_TOKEN=$(az account get-access-token --resource https://database.windows.net \
    --query accessToken -o tsv 2>/dev/null) || die "could not get a token, try: az login"

SQL_FQDN="${SQL_SERVER_NAME}.database.windows.net"
run() { dotnet ./sqlrunner/bin/Release/net8.0/sqlrunner.dll "$SQL_FQDN" "$SQL_DB_NAME" "$@"; }

# A changed IP is the most common reason this fails, so fix it rather than
# reporting it. Governance policy in some subscriptions also re-disables public
# network access on the server without warning, so check that too.
ensure_connectivity() {
    local probe; probe=$(mktemp /tmp/probe-XXXX.sql)
    echo "SELECT 1 AS ok;" > "$probe"

    if run "$probe" >/dev/null 2>&1; then rm -f "$probe"; return 0; fi

    local access
    access=$(az sql server show -g "$RESOURCE_GROUP" -n "$SQL_SERVER_NAME" \
             --query publicNetworkAccess -o tsv 2>/dev/null)
    if [ "$access" = "Disabled" ]; then
        warn "public network access was disabled on the server, re-enabling"
        az sql server update -g "$RESOURCE_GROUP" -n "$SQL_SERVER_NAME" \
            --enable-public-network true -o none 2>/dev/null
        sleep 10
    fi

    if ! run "$probe" >/dev/null 2>&1; then
        warn "cannot connect, updating the firewall for your current IP"
        local ip; ip=$(curl -fsS https://ifconfig.me 2>/dev/null)
        [ -z "$ip" ] && { rm -f "$probe"; die "could not determine your IP"; }
        az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" \
            -n "demo-$(date +%s)" --start-ip-address "$ip" --end-ip-address "$ip" -o none 2>/dev/null
        sleep 8
        run "$probe" >/dev/null 2>&1 || { rm -f "$probe"; die "still cannot connect to $SQL_FQDN"; }
        ok "firewall updated for $ip"
    else
        ok "public network access restored"
    fi
    rm -f "$probe"
}

toggle_read() {
    local state="$1" value tmp
    [ "$state" = "on" ] && value=1 || value=0
    tmp=$(mktemp /tmp/toggle-XXXX.sql)
    sed "s/@EnableReadFiltering BIT = 1/@EnableReadFiltering BIT = ${value}/g" \
        ./sql/09_toggle_read.sql > "$tmp"
    run "$tmp"
    rm -f "$tmp"
}

ensure_connectivity

# A disabled policy makes every step silently succeed, which is the worst way to
# find out mid-demo. Check before running anything.
check_policy_enabled() {
    local q; q=$(mktemp /tmp/pol-XXXX.sql)
    cat > "$q" <<'SQL'
SET NOCOUNT ON;
SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
        THEN 'MISSING'
    WHEN EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy' AND is_enabled = 0)
        THEN 'DISABLED'
    ELSE 'ENABLED' END AS PolicyState;
SQL
    local state; state=$(run "$q" 2>/dev/null | grep -oE 'MISSING|DISABLED|ENABLED' | head -1)
    rm -f "$q"

    case "$state" in
        ENABLED) return 0 ;;
        DISABLED)
            warn "the security policy is DISABLED, so nothing would be blocked"
            warn "re-enabling it"
            local f; f=$(mktemp /tmp/en-XXXX.sql)
            echo "ALTER SECURITY POLICY Security.ProjectLinePolicy WITH (STATE = ON);" > "$f"
            run "$f" >/dev/null 2>&1
            rm -f "$f"
            ok "re-enabled"
            ;;
        *)
            die "no security policy found. Run ./deploy.sh --sql-only first."
            ;;
    esac
}

# Extracts one STEP block out of a story file so it can be run on its own.
# Every step keeps its DECLAREs inside its own batch, so a block is self-contained.
run_step() {
    local src="$1" max="$2" n="$3" label="$4"
    case "$n" in
        ''|*[!0-9]*) die "usage: ./demo.sh $label 1..$max" ;;
    esac
    [ "$n" -ge 1 ] && [ "$n" -le "$max" ] || die "usage: ./demo.sh $label 1..$max"

    # The readwrite steps assume step 1 has bound the read predicate.
    if [ "$label" = "rwstep" ] && [ "$n" -gt 1 ] && [ "$n" -lt 7 ]; then
        local q; q=$(mktemp /tmp/rf-XXXX.sql)
        echo "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.security_predicates sp JOIN sys.security_policies p ON p.object_id=sp.object_id WHERE p.name='ProjectLinePolicy' AND sp.predicate_type_desc='FILTER') THEN 'FILTERON' ELSE 'FILTEROFF' END AS s;" > "$q"
        if run "$q" 2>/dev/null | grep -q FILTEROFF; then
            warn "read filtering is off, so this step will not show what it describes"
            warn "run ./demo.sh rwstep 1 first"
        fi
        rm -f "$q"
    fi

    local f; f=$(mktemp /tmp/step-XXXX.sql)
    awk -v want="$n" '
        /^PRINT .=====/ { getline hdr
                          if (hdr ~ / STEP /) {
                              split(hdr, a, "STEP ")
                              cur = a[2] + 0
                              if (cur == want) { inblock = 1; print; print hdr; next }
                              else if (inblock) { exit }
                              else { next }
                          }
                          if (inblock) { print }
                          next }
        inblock { print }
    ' "$src" > "$f"

    [ -s "$f" ] || { rm -f "$f"; die "could not extract step $n from $src"; }
    run "$f"
    rm -f "$f"
}

# All five tables side by side, for opening the demo.
show_tables() {
    local f; f=$(mktemp /tmp/tbl-XXXX.sql)
    cat > "$f" <<'SQL'
PRINT '--- dbo.Document -------------------------------------------';
SELECT TOP 5 * FROM dbo.Document ORDER BY DocumentId;

PRINT '--- dbo.ProjectAccess: project -> the groups that may act ---';
SELECT TOP 5 ProjectId, ProjectName, EntraIdWrite, EntraIdRead FROM dbo.ProjectAccess
ORDER BY CASE WHEN ProjectId IN (12345678, 98765432) THEN 0 ELSE 1 END, ProjectId;

PRINT '--- dbo.DocumentLine: the protected table ------------------';
SELECT TOP 5 DocumentLineId, DocumentId, ProjectId, Comment FROM dbo.DocumentLine ORDER BY DocumentLineId;

PRINT '--- Security.UserIdentity: connection -> Entra object id ----';
SELECT DatabasePrincipalId, UserObjectId, UserPrincipalName, IsActive
FROM Security.UserIdentity
WHERE UserPrincipalName IN (N'anna@contoso.com', N'bjorn@contoso.com')
ORDER BY UserPrincipalName;

PRINT '--- Security.GroupMembership: who is in which group ---------';
SELECT ui.UserPrincipalName, gm.GroupObjectId, gm.SyncedAt
FROM Security.GroupMembership AS gm
JOIN Security.UserIdentity AS ui ON ui.UserObjectId = gm.UserObjectId
WHERE ui.UserPrincipalName IN (N'anna@contoso.com', N'bjorn@contoso.com')
ORDER BY ui.UserPrincipalName;

PRINT '--- row counts ---------------------------------------------';
SELECT
    (SELECT COUNT(*) FROM dbo.Document)              AS Documents,
    (SELECT COUNT(*) FROM dbo.ProjectAccess)         AS Projects,
    (SELECT COUNT(*) FROM dbo.DocumentLine)          AS Lines,
    (SELECT COUNT(*) FROM Security.GroupMembership)  AS Memberships;
SQL
    run "$f"
    rm -f "$f"
}

# One user in full: their groups, the projects those grant, and what they cannot
# reach. Name is restricted to safe characters before substitution.
show_who() {
    local u="${1:-}"
    [ -n "$u" ] || die "usage: ./demo.sh who <user>    e.g. ./demo.sh who anna"
    case "$u" in
        *[!A-Za-z0-9._@-]*) die "invalid user name: $u" ;;
    esac
    local f; f=$(mktemp /tmp/who-XXXX.sql)
    sed "s/{{USER}}/${u}/g" ./sql/12_who.sql > "$f"
    run "$f"
    rm -f "$f"
}

check_policy_enabled

case "${1:-all}" in
    all)
        run ./sql/10_demo_setup.sql
        echo
        read -r -p "Press Enter to start the demo..."
        run ./sql/11_demo_run.sql
        ;;
    reset)  run ./sql/10_demo_setup.sql ;;
    story)  run ./sql/11_demo_run.sql ;;
    readwrite) run ./sql/14_demo_readwrite.sql ;;
    step)   run_step ./sql/11_demo_run.sql      8 "${2:-}" step ;;
    rwstep) run_step ./sql/14_demo_readwrite.sql 7 "${2:-}" rwstep ;;
    tables) show_tables ;;
    who)    show_who "${2:-}" ;;
    access) run ./sql/08_show_access.sql ;;
    compare) run ./sql/13_compare_modes.sql ;;
    bench)  run ./sql/07_benchmark.sql ;;
    tests)  run ./sql/06_test.sql ;;
    policy) cat ./sql/02_policy.sql ;;
    read)
        case "${2:-}" in
            on)  toggle_read on ;;
            off) toggle_read off ;;
            *)   die "usage: ./demo.sh read on|off" ;;
        esac
        ;;
    -h|--help) sed -n '2,20p' "$0" ;;
    *) die "unknown command: $1  (try ./demo.sh --help)" ;;
esac
