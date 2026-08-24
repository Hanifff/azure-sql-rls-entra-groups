#!/bin/bash
# ============================================================================
# demo.sh - run the demo. Nothing to set up first.
#
#   ./demo.sh          who can see what, then the enforcement tests
#   ./demo.sh access   who can see what
#   ./demo.sh tests    the 5 enforcement tests
#   ./demo.sh bench    logical reads and timings
#
# Handles the token, the config and the firewall itself. Run ./setup.sh and
# infra/deploy.sh --sql-only first.
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "\n${BLUE}==>${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}error:${NC} $*" >&2; exit 1; }

[ -f ./sqlrunner/bin/Release/net8.0/sqlrunner.dll ] || \
    dotnet build ./sqlrunner/sqlrunner.csproj -c Release -v q --nologo >/dev/null || die "build failed"

export SQL_ACCESS_TOKEN
SQL_ACCESS_TOKEN=$(az account get-access-token --resource https://database.windows.net \
    --query accessToken -o tsv 2>/dev/null) || die "no token, try: az login"

run() {
    dotnet ./sqlrunner/bin/Release/net8.0/sqlrunner.dll \
        "${SQL_SERVER_NAME}.database.windows.net" "$SQL_DB_NAME" "$@"
}

# A changed IP is the usual reason this fails, so fix it rather than report it.
PROBE=$(mktemp /tmp/probe-XXXX.sql); echo "SELECT 1;" > "$PROBE"
if ! run "$PROBE" >/dev/null 2>&1; then
    warn "cannot connect, adding your current IP to the firewall"
    IP=$(curl -fsS https://ifconfig.me) || die "could not determine your IP"
    az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SQL_SERVER_NAME" \
        -n "demo-$(date +%s)" --start-ip-address "$IP" --end-ip-address "$IP" -o none
    sleep 8
    run "$PROBE" >/dev/null 2>&1 || die "still cannot connect"
fi
rm -f "$PROBE"

case "${1:-all}" in
    all)
        info "Who can see and write what"
        run ./sql/08_show_access.sql
        info "Enforcement tests"
        run ./sql/06_test_rls.sql
        ;;
    access) run ./sql/08_show_access.sql ;;
    tests)  run ./sql/06_test_rls.sql ;;
    bench)  run ./sql/07_benchmark.sql ;;
    -h|--help) sed -n '2,12p' "$0" ;;
    *) die "unknown command: $1" ;;
esac
