#!/usr/bin/env bash
#
# firewall_unidades_v2.sh
# Gerenciador de firewall otimizado para listas extensas.
# Compatibilidade alvo: EL7/EL8/EL9 (CentOS/RHEL/Rocky equivalentes onde aplicável).
#
# Mantém o formato do regras_firewall.conf:
#   d: destino IP/CIDR/FQDN   -> libera FORWARD para o destino
#   s: origem IP/CIDR/FQDN    -> libera FORWARD para a origem
#   p: porta TCP              -> libera FORWARD para a porta
#   m: MAC                    -> libera TCP/443 para o MAC
#   c: MAC                    -> libera FORWARD total para o MAC
#
# Principais diferenças em relação ao gerador original:
#   - milhares de d:/s: são colocados em ipset (uma regra iptables por conjunto)
#   - regras iptables são aplicadas de uma vez com iptables-restore
#   - FQDNs são resolvidos antes da aplicação e possuem cache de contingência
#   - duplicatas são removidas
#   - CIDRs podem ser consolidados automaticamente quando python3 está disponível
#   - backup/rollback, lock, validação e logs
#   - o REJECT de INPUT fica no final da chain, evitando regras inalcançáveis
#   - FORWARD stateful com ESTABLISHED,RELATED e descarte de INVALID
#   - DROP final explícito, preservando compatibilidade 192.168/16 por regra clara
#   - WireGuard corrigido para --dport e logging com rate-limit configurável
#
# IMPORTANTE:
#   Este gerenciador assume controle exclusivo das tabelas IPv4 filter e nat,
#   assim como o script legado (que executava iptables -F). Não misture com
#   firewalld sem revisar a arquitetura.
#

set -Eeuo pipefail
umask 077

VERSION="2.1.0"

BASE_DIR="${FW_BASE_DIR:-/operacao/firewall.unidades}"
RULES_FILE="${FW_RULES_FILE:-${BASE_DIR}/regras_firewall.conf}"
STATE_DIR="${FW_STATE_DIR:-${BASE_DIR}/.firewall-v2}"
RUNTIME_DIR="${STATE_DIR}/runtime"
BACKUP_DIR="${STATE_DIR}/backups"
LOCK_FILE="${STATE_DIR}/firewall.lock"
LOG_FILE="${STATE_DIR}/firewall-v2.log"
DNS_CACHE="${STATE_DIR}/dns-cache.tsv"
SET_DST="FWU_DST_V4"
SET_SRC="FWU_SRC_V4"
SET_HASH_SIZE=131072
SET_MAXELEM=262144
DNS_TIMEOUT="${DNS_TIMEOUT:-4}"
DNS_JOBS="${DNS_JOBS:-8}"
DNS_CACHE_MAX_AGE="${DNS_CACHE_MAX_AGE:-604800}"
DNS_STRICT="${DNS_STRICT:-0}"
OPTIMIZE_NETWORKS="${OPTIMIZE_NETWORKS:-1}"
ALLOW_FIREWALLD="${ALLOW_FIREWALLD:-0}"
BACKUP_KEEP="${BACKUP_KEEP:-10}"

INPUT_TRUSTED_INTERFACES="${INPUT_TRUSTED_INTERFACES:-eth0 em1 enX0 eno1 tap0 tap1 wg0}"
ALLOW_RFC1918_192_DST="${ALLOW_RFC1918_192_DST:-1}"

WG_FORWARD_ENABLE="${WG_FORWARD_ENABLE:-1}"
WG_FORWARD_DST="${WG_FORWARD_DST:-172.20.0.200/32}"
WG_FORWARD_TCP_PORTS="${WG_FORWARD_TCP_PORTS:-1:1024 3389}"
LOG_TRAFFIC="${LOG_TRAFFIC:-1}"
LOG_RATE="${LOG_RATE:-50/second}"
LOG_BURST="${LOG_BURST:-200}"
LOG_NEW_ONLY="${LOG_NEW_ONLY:-1}"
EXCLUDE_LOG_NET_1="192.168.0.0/16"
EXCLUDE_LOG_NET_2="10.80.0.0/16"
EXCLUDE_LOG_NET_3="172.16.0.0/12"

SETTINGS_FILE="${FW_SETTINGS_FILE:-${BASE_DIR}/firewall_unidades_v2.conf}"
if [[ -r "$SETTINGS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_FILE"
fi

IPTABLES="${IPTABLES:-$(command -v iptables 2>/dev/null || true)}"
IPTABLES_SAVE="${IPTABLES_SAVE:-$(command -v iptables-save 2>/dev/null || true)}"
IPTABLES_RESTORE="${IPTABLES_RESTORE:-$(command -v iptables-restore 2>/dev/null || true)}"
IPSET="${IPSET:-$(command -v ipset 2>/dev/null || true)}"

ACTIVE_BACKUP=""
ROLLBACK_ARMED=0
LOCK_FD=9

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for module in \
    "$SCRIPT_DIR/lib/00_common.sh" \
    "$SCRIPT_DIR/lib/10_parser.sh" \
    "$SCRIPT_DIR/lib/20_dns.sh" \
    "$SCRIPT_DIR/lib/30_ipset.sh" \
    "$SCRIPT_DIR/lib/40_rules.sh" \
    "$SCRIPT_DIR/lib/50_backup.sh" \
    "$SCRIPT_DIR/lib/60_commands.sh"; do
    # shellcheck disable=SC1090
    source "$module"
done

main() {
    local cmd="${1:-}"
    case "$cmd" in
        stats) shift; cmd_stats "$@" ;;
        check) shift; cmd_check "$@" ;;
        generate) shift; cmd_generate "$@" ;;
        apply) shift; cmd_apply "$@" ;;
        refresh-sets) shift; cmd_refresh_sets "$@" ;;
        status) shift; cmd_status "$@" ;;
        diagnose) shift; cmd_diagnose "$@" ;;
        backups) shift; cmd_backups "$@" ;;
        rollback) shift; cmd_rollback "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage >&2; die "Comando desconhecido: $cmd" ;;
    esac
}

main "$@"
