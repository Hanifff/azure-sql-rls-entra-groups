#!/bin/bash
# ============================================================================
# demo.sh - run the demo without setting anything up first.
#
#   ./demo.sh              reset, then walk the eight-step story
#   ./demo.sh reset        put the data back, nothing else
#   ./demo.sh story        run the story without resetting first
#   ./demo.sh read on      turn read filtering on
#   ./demo.sh read off     turn read filtering off (the default)
#   ./demo.sh access       who can see and write what
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
    access) run ./sql/10_demo_setup.sql ;;
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
