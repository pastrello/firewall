#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="/tmp/firewall-test-state"
LOG_FILE="$STATE_DIR/test.log"
VERSION="test"
SETTINGS_FILE="/tmp/none"
mkdir -p "$STATE_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/00_common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/15_interfaces.sh"

failures=0
pass() { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures+1)); }

INTERFACE_MISSING_POLICY="ignore"
INPUT_TRUSTED_SOURCES="10.80.0.0/16 172.20.0.0/24"
LOCAL_INPUT_RULES=("name=test iface=@lan proto=tcp port=300 src=10.0.0.0/8")

# compat preserva lista legada
INTERFACE_POLICY_MODE="compat"
INPUT_TRUSTED_INTERFACES="eth0 wg0"
WAN_INTERFACES="eth1"
LAN_INTERFACES="eth0"
VPN_INTERFACES="wg0"
[[ "$(effective_trusted_interfaces)" == "eth0 wg0" ]] && pass "compat preserva INPUT_TRUSTED_INTERFACES" || fail "compat preserva INPUT_TRUSTED_INTERFACES"

# roles usa somente LAN+VPN
INTERFACE_POLICY_MODE="roles"
[[ "$(effective_trusted_interfaces)" == "eth0 wg0" ]] && pass "roles confia somente LAN/VPN" || fail "roles confia somente LAN/VPN"
! word_in_list "eth1" "$(effective_trusted_interfaces)" && pass "WAN excluída do trust efetivo" || fail "WAN excluída do trust efetivo"

# WAN na lista legada deve falhar em roles
INPUT_TRUSTED_INTERFACES="eth0 eth1 wg0"
if validate_interface_policy >/dev/null 2>&1; then
    fail "roles rejeita WAN em INPUT_TRUSTED_INTERFACES"
else
    pass "roles rejeita WAN em INPUT_TRUSTED_INTERFACES"
fi

# configuração válida em roles
INPUT_TRUSTED_INTERFACES="eth0 wg0"
if validate_interface_policy >/dev/null 2>&1; then
    pass "roles aceita classificação coerente"
else
    fail "roles aceita classificação coerente"
fi

# sobreposição de papéis deve falhar
LAN_INTERFACES="eth0 eth1"
if validate_interface_policy >/dev/null 2>&1; then
    fail "roles rejeita sobreposição WAN/LAN"
else
    pass "roles rejeita sobreposição WAN/LAN"
fi
LAN_INTERFACES="eth0"

# parser de serviço local
parsed=$(decode_local_input_rule "name=web iface=@wan proto=tcp port=8443 src=203.0.113.0/24 enabled=1")
[[ "$parsed" == "web|@wan|tcp|8443|203.0.113.0/24|1" ]] && pass "parser LOCAL_INPUT_RULES" || fail "parser LOCAL_INPUT_RULES"

# faixa de portas
valid_port_spec "1000:2000" && pass "faixa de portas válida" || fail "faixa de portas válida"
! valid_port_spec "2000:1000" && pass "faixa invertida rejeitada" || fail "faixa invertida rejeitada"

if (( failures > 0 )); then
    printf '\n%d teste(s) falharam.\n' "$failures"
    exit 1
fi
printf '\nTodos os testes v2.2 passaram.\n'
