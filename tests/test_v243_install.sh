#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/firewall-install-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
RUNTIME_DIR="$STATE_DIR/runtime"
BACKUP_DIR="$STATE_DIR/backups"
DYNAMIC_STATE_DIR="$STATE_DIR/dynamic"
LOG_FILE="$STATE_DIR/test.log"
LOCK_FILE="$STATE_DIR/test.lock"
VERSION="2.4.3"
BASE_DIR="$TMP/target"
SCRIPT_DIR="$ROOT_DIR"
DYNAMIC_DNS_SERVICE_NAME="firewall-dnswatch.service"

mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$DYNAMIC_STATE_DIR"

source "$ROOT_DIR/lib/00_common.sh"
source "$ROOT_DIR/lib/70_installer.sh"

failures=0
pass() { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures+1)); }

TARGET="$TMP/target"

install_deploy_from_source "$ROOT_DIR" "$TARGET" "install"

[[ -x "$TARGET/firewall_unidades.sh" ]] &&
    pass "instala script principal" || fail "instala script principal"

[[ -r "$TARGET/firewall_unidades_v2.conf" ]] &&
    grep -Fxq 'LOG_TRAFFIC=0' "$TARGET/firewall_unidades_v2.conf" &&
    pass "cria configuração segura com log desativado" || fail "cria configuração segura com log desativado"

[[ -r "$TARGET/regras_firewall.conf" ]] &&
    pass "cria arquivo de regras" || fail "cria arquivo de regras"

[[ "$("$TARGET/firewall_unidades.sh" -V)" == "firewall_unidades.sh v2.4.3" ]] &&
    pass "-V funciona sem carregar backend" || fail "-V funciona sem carregar backend"

cat > "$TARGET/firewall_unidades_v2.conf" <<'EOF_CONF'
BACKEND="iptables"
LOG_TRAFFIC=1
CUSTOM_SENTINEL="preservar"
EOF_CONF
printf 'd: 203.0.113.77\n' > "$TARGET/regras_firewall.conf"

install_deploy_from_source "$ROOT_DIR" "$TARGET" "upgrade"

grep -Fxq 'CUSTOM_SENTINEL="preservar"' "$TARGET/firewall_unidades_v2.conf" &&
    pass "upgrade preserva configuração local" || fail "upgrade preserva configuração local"

grep -Fxq 'd: 203.0.113.77' "$TARGET/regras_firewall.conf" &&
    pass "upgrade preserva regras locais" || fail "upgrade preserva regras locais"

BACKUP_COUNT=$(find "$TARGET/$APP_BACKUP_DIR_NAME" -mindepth 1 -maxdepth 1 -type d | wc -l)
(( BACKUP_COUNT >= 1 )) &&
    pass "upgrade cria backup da aplicação" || fail "upgrade cria backup da aplicação"

LATEST=$(find "$TARGET/$APP_BACKUP_DIR_NAME" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r | head -1)
[[ -r "$LATEST/operational/firewall_unidades_v2.conf" ]] &&
    [[ -r "$LATEST/operational/regras_firewall.conf" ]] &&
    pass "backup inclui config e regras" || fail "backup inclui config e regras"

if (( failures > 0 )); then
    printf '\n%d teste(s) falharam.\n' "$failures"
    exit 1
fi

printf '\nTodos os testes de install/upgrade passaram.\n'
