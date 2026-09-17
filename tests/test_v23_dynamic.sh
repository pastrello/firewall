#!/usr/bin/env bash
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/firewall-v23-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP/state"; RUNTIME_DIR="$STATE_DIR/runtime"; BACKUP_DIR="$STATE_DIR/backups"; DYNAMIC_STATE_DIR="$STATE_DIR/dynamic"
DYNAMIC_STATE_FILE="$DYNAMIC_STATE_DIR/state.tsv"; DYNAMIC_STATUS_FILE="$DYNAMIC_STATE_DIR/status.tsv"; DYNAMIC_META_FILE="$DYNAMIC_STATE_DIR/meta.env"
LOG_FILE="$STATE_DIR/test.log"; LOCK_FILE="$STATE_DIR/test.lock"; VERSION="test"; SETTINGS_FILE="$TMP/none"
mkdir -p "$RUNTIME_DIR" "$BACKUP_DIR" "$DYNAMIC_STATE_DIR"
DNS_TIMEOUT=1; DYNAMIC_DNS_ENABLE=1; DYNAMIC_DNS_MIN_INTERVAL=30; DYNAMIC_DNS_MAX_INTERVAL=300; DYNAMIC_DNS_TTL_DIVISOR=2
DYNAMIC_DNS_GRACE=300; DYNAMIC_DNS_STALE_MAX=3600; DYNAMIC_DNS_FAIL_POLICY=keep; DYNAMIC_DNS_LOCK_TIMEOUT=20
source "$ROOT_DIR/lib/00_common.sh"; source "$ROOT_DIR/lib/10_parser.sh"; source "$ROOT_DIR/lib/25_dynamic_dns.sh"
failures=0; pass(){ printf 'OK   %s\n' "$1"; }; fail(){ printf 'FAIL %s\n' "$1"; failures=$((failures+1)); }
[[ "$(dynamic_compute_sleep 60)" == 30 ]] && pass "TTL 60 -> 30s" || fail "TTL 60 -> 30s"
[[ "$(dynamic_compute_sleep 100)" == 50 ]] && pass "TTL 100 -> 50s" || fail "TTL 100 -> 50s"
[[ "$(dynamic_compute_sleep 10)" == 30 ]] && pass "intervalo mínimo" || fail "intervalo mínimo"
[[ "$(dynamic_compute_sleep 1000)" == 300 ]] && pass "intervalo máximo" || fail "intervalo máximo"
RULES_FILE="$TMP/regras.conf"
printf 'd: 203.0.113.10\nu: Pastrello.DDNS.NET\nu: pastrello.ddns.net\ns: 10.0.0.0/8\np: 443\n' > "$RULES_FILE"
mkdir -p "$TMP/parsed"
parse_config "$TMP/parsed" && [[ "$(cat "$TMP/parsed/u_dns.txt")" == pastrello.ddns.net ]] && pass "parser u: deduplica" || fail "parser u: deduplica"
printf 'u: 203.0.113.10\n' > "$RULES_FILE"; mkdir -p "$TMP/invalid"
parse_config "$TMP/invalid" >/dev/null 2>&1 && fail "u: rejeita IP" || pass "u: rejeita IP"
HOSTS="$TMP/hosts"; printf 'dyn.example.test\n' > "$HOSTS"
dynamic_query_host(){ printf '60\t198.51.100.10\n' > "$2"; return 0; }
dynamic_build_candidate "$HOSTS" "$TMP/s1" "$TMP/set1" "$TMP/st1" "$TMP/m1"
grep -Fxq 198.51.100.10 "$TMP/set1" && pass "primeira resolução" || fail "primeira resolução"; cp "$TMP/s1" "$DYNAMIC_STATE_FILE"
dynamic_query_host(){ printf '60\t198.51.100.20\n' > "$2"; return 0; }
dynamic_build_candidate "$HOSTS" "$TMP/s2" "$TMP/set2" "$TMP/st2" "$TMP/m2"
if grep -Fxq 198.51.100.20 "$TMP/set2" && grep -Fxq 198.51.100.10 "$TMP/set2"; then pass "grace mantém IP anterior"; else fail "grace mantém IP anterior"; fi
cp "$TMP/s1" "$DYNAMIC_STATE_FILE"; dynamic_query_host(){ : > "$2"; return 1; }
dynamic_build_candidate "$HOSTS" "$TMP/s3" "$TMP/set3" "$TMP/st3" "$TMP/m3"
if grep -Fxq 198.51.100.10 "$TMP/set3" && grep -q $'dyn.example.test\tCACHE' "$TMP/st3"; then pass "falha DNS preserva cache"; else fail "falha DNS preserva cache"; fi
(( failures == 0 )) || { printf '\n%d teste(s) falharam.\n' "$failures"; exit 1; }
printf '\nTodos os testes v2.3 passaram.\n'
