#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/firewall-v24-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
RUNTIME_DIR="$STATE_DIR/runtime"
BACKUP_DIR="$STATE_DIR/backups"
DYNAMIC_STATE_DIR="$STATE_DIR/dynamic"
DYNAMIC_STATE_FILE="$DYNAMIC_STATE_DIR/state.tsv"
DYNAMIC_STATUS_FILE="$DYNAMIC_STATE_DIR/status.tsv"
DYNAMIC_META_FILE="$DYNAMIC_STATE_DIR/meta.env"
LOG_FILE="$STATE_DIR/test.log"
LOCK_FILE="$STATE_DIR/test.lock"
VERSION="test"
SETTINGS_FILE="$TMP/none"
BACKEND="iptables"
LOCK_FD=9
LOCK_HELD=0
ROLLBACK_ARMED=0
ACTIVE_BACKUP=""
BACKUP_KEEP=10

SET_DST="FWU_DST_V4"
SET_SRC="FWU_SRC_V4"
SET_DYN_DST="FWU_DYN_DST_V4"
SET_HASH_SIZE=1024
SET_MAXELEM=4096

INTERFACE_POLICY_MODE="roles"
INTERFACE_MISSING_POLICY="ignore"
WAN_INTERFACES=""
LAN_INTERFACES=""
VPN_INTERFACES=""
INPUT_TRUSTED_INTERFACES=""
INPUT_TRUSTED_SOURCES=""
LOCAL_INPUT_RULES=()

ALLOW_RFC1918_192_DST=1
WG_FORWARD_ENABLE=0
WG_FORWARD_DST="172.20.0.200/32"
WG_FORWARD_TCP_PORTS="3389"
LOG_TRAFFIC=0
LOG_NEW_ONLY=1
LOG_RATE="50/second"
LOG_BURST=200
EXCLUDE_LOG_NET_1="192.168.0.0/16"
EXCLUDE_LOG_NET_2="10.80.0.0/16"
EXCLUDE_LOG_NET_3="172.16.0.0/12"

mkdir -p "$RUNTIME_DIR" "$BACKUP_DIR" "$DYNAMIC_STATE_DIR"

source "$ROOT_DIR/lib/00_common.sh"
source "$ROOT_DIR/lib/15_interfaces.sh"
source "$ROOT_DIR/lib/backend/00_backend.sh"
backend_load "$ROOT_DIR" "$BACKEND"
source "$ROOT_DIR/lib/50_backup.sh"

failures=0
pass() { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures=$((failures+1)); }

[[ "$(backend_rules_filename)" == "iptables.rules" ]] && pass "arquivo de regras do backend" || fail "arquivo de regras do backend"

for fn in backend_generate_rules backend_validate_rules backend_apply_rules backend_set_load_atomic backend_backup_rules backend_restore_rules; do
    declare -F "$fn" >/dev/null 2>&1 && pass "API $fn" || fail "API $fn"
done

PARSED="$TMP/parsed"
mkdir -p "$PARSED"
: > "$PARSED/mac_full.txt"
: > "$PARSED/mac_https.txt"
printf '443\n' > "$PARSED/ports.txt"

RULESET="$TMP/iptables.rules"
backend_generate_rules "$PARSED" "$RULESET" "192.168.17.10"

grep -Fq -- "-A FORWARD -m set --match-set $SET_DST dst -j ACCEPT" "$RULESET" &&
    pass "set estático no ruleset" || fail "set estático no ruleset"
grep -Fq -- "-A FORWARD -m set --match-set $SET_DYN_DST dst -j ACCEPT" "$RULESET" &&
    pass "set dinâmico no ruleset" || fail "set dinâmico no ruleset"
grep -Fq -- "-A POSTROUTING -s 192.168.17.0/24 ! -d 192.168.0.0/16 -j MASQUERADE" "$RULESET" &&
    pass "NAT legado preservado" || fail "NAT legado preservado"

LEGACY_BACKUP="$TMP/legacy-backup"
mkdir -p "$LEGACY_BACKUP"
printf '*filter\nCOMMIT\n' > "$LEGACY_BACKUP/iptables.save"
[[ "$(backup_backend_name "$LEGACY_BACKUP")" == "iptables" ]] &&
    pass "backup antigo reconhecido como iptables" || fail "backup antigo reconhecido como iptables"

mkdir -p "$BACKUP_DIR/20261121_000000"
if prune_backups; then
    pass "prune_backups retorna sucesso sem excedentes"
else
    fail "prune_backups retorna sucesso sem excedentes"
fi

if ( BACKEND="nftables"; backend_load "$ROOT_DIR" "$BACKEND" ) >/dev/null 2>&1; then
    fail "nftables ainda não pode ser selecionado na v2.4"
else
    pass "nftables bloqueado até v2.5"
fi

if (( failures > 0 )); then
    printf '\n%d teste(s) falharam.\n' "$failures"
    exit 1
fi
printf '\nTodos os testes v2.4 passaram.\n'
