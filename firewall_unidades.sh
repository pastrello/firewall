#!/usr/bin/env bash
#
# firewall_unidades.sh
# Gerenciador de firewall otimizado para listas extensas.
# Compatibilidade alvo: EL7/EL8/EL9 (CentOS/RHEL/Rocky equivalentes onde aplicável).
#
# Formato de regras outbound:
#   d: destino IP/CIDR/FQDN   -> libera FORWARD para o destino (snapshot DNS)
#   u: destino FQDN dinâmico  -> libera FORWARD e acompanha mudanças DNS continuamente
#   s: origem IP/CIDR/FQDN    -> libera FORWARD para a origem
#   p: porta TCP              -> libera FORWARD para a porta
#   m: MAC                    -> libera TCP/443 para o MAC
#   c: MAC                    -> libera FORWARD total para o MAC
#
# v2.2: hardening de interfaces WAN/LAN/VPN e serviços INPUT declarativos.
# v2.3: destinos DNS dinâmicos (u:) com atualização contínua.
# v2.4: abstração de backend; iptables/ipset permanece como implementação padrão.
#
# IMPORTANTE:
#   Este gerenciador assume controle exclusivo das tabelas IPv4 filter e nat,
#   assim como o script legado (que executava iptables -F). Não misture com
#   firewalld sem revisar a arquitetura.

set -Eeuo pipefail
umask 077

VERSION="2.4.3"

case "${1:-}" in
    -V|--version|version)
        printf 'firewall_unidades.sh v%s\n' "$VERSION"
        exit 0
        ;;
esac

BASE_DIR="${FW_BASE_DIR:-/operacao/firewall.unidades}"
RULES_FILE="${FW_RULES_FILE:-${BASE_DIR}/regras_firewall.conf}"
STATE_DIR="${FW_STATE_DIR:-${BASE_DIR}/.firewall-v2}"
RUNTIME_DIR="${STATE_DIR}/runtime"
BACKUP_DIR="${STATE_DIR}/backups"
LOCK_FILE="${STATE_DIR}/firewall.lock"
LOG_FILE="${STATE_DIR}/firewall-v2.log"
DNS_CACHE="${STATE_DIR}/dns-cache.tsv"
DYNAMIC_STATE_DIR="${STATE_DIR}/dynamic"
DYNAMIC_STATE_FILE="${DYNAMIC_STATE_DIR}/state.tsv"
DYNAMIC_STATUS_FILE="${DYNAMIC_STATE_DIR}/status.tsv"
DYNAMIC_META_FILE="${DYNAMIC_STATE_DIR}/meta.env"
DYNAMIC_LOG_FILE="${DYNAMIC_STATE_DIR}/dnswatch.log"

SET_DST="FWU_DST_V4"
SET_SRC="FWU_SRC_V4"
SET_DYN_DST="FWU_DYN_DST_V4"
SET_HASH_SIZE=131072
SET_MAXELEM=262144

DNS_TIMEOUT="${DNS_TIMEOUT:-4}"
DNS_JOBS="${DNS_JOBS:-8}"
DNS_CACHE_MAX_AGE="${DNS_CACHE_MAX_AGE:-604800}"
DNS_STRICT="${DNS_STRICT:-0}"
OPTIMIZE_NETWORKS="${OPTIMIZE_NETWORKS:-1}"
ALLOW_FIREWALLD="${ALLOW_FIREWALLD:-0}"
BACKUP_KEEP="${BACKUP_KEEP:-10}"
BACKEND="${BACKEND:-iptables}"

INTERFACE_POLICY_MODE="${INTERFACE_POLICY_MODE:-compat}"
INTERFACE_MISSING_POLICY="${INTERFACE_MISSING_POLICY:-warn}"
WAN_INTERFACES="${WAN_INTERFACES:-}"
LAN_INTERFACES="${LAN_INTERFACES:-}"
VPN_INTERFACES="${VPN_INTERFACES:-}"
INPUT_TRUSTED_INTERFACES="${INPUT_TRUSTED_INTERFACES:-eth0 em1 enX0 eno1 tap0 tap1 wg0}"
INPUT_TRUSTED_SOURCES="${INPUT_TRUSTED_SOURCES:-10.80.0.0/16 172.20.0.0/24}"

LOCAL_INPUT_RULES=(
    "name=legacy-port300-eth0 iface=eth0 proto=tcp port=300 src=any"
    "name=legacy-port300-eth1-lan iface=eth1 proto=tcp port=300 src=192.168.1.0/24"
    "name=legacy-port300-eth1-public iface=eth1 proto=tcp port=300 src=200.195.133.27/32"
    "name=legacy-port300-eth1-vpn iface=eth1 proto=tcp port=300 src=10.100.1.0/24"
    "name=legacy-port300-enX0 iface=enX0 proto=tcp port=300 src=any"
    "name=legacy-port300-enX1-lan iface=enX1 proto=tcp port=300 src=192.168.1.0/24"
    "name=legacy-port300-enX1-public iface=enX1 proto=tcp port=300 src=200.195.133.27/32"
    "name=legacy-port300-enX1-vpn iface=enX1 proto=tcp port=300 src=10.100.1.0/24"
)

# v2.3: DNS dinâmico (u:)
DYNAMIC_DNS_ENABLE="${DYNAMIC_DNS_ENABLE:-1}"
DYNAMIC_DNS_MIN_INTERVAL="${DYNAMIC_DNS_MIN_INTERVAL:-30}"
DYNAMIC_DNS_MAX_INTERVAL="${DYNAMIC_DNS_MAX_INTERVAL:-300}"
DYNAMIC_DNS_TTL_DIVISOR="${DYNAMIC_DNS_TTL_DIVISOR:-2}"
DYNAMIC_DNS_GRACE="${DYNAMIC_DNS_GRACE:-300}"
DYNAMIC_DNS_STALE_MAX="${DYNAMIC_DNS_STALE_MAX:-3600}"
DYNAMIC_DNS_FAIL_POLICY="${DYNAMIC_DNS_FAIL_POLICY:-keep}"
DYNAMIC_DNS_LOCK_TIMEOUT="${DYNAMIC_DNS_LOCK_TIMEOUT:-20}"
DYNAMIC_DNS_SERVICE_NAME="${DYNAMIC_DNS_SERVICE_NAME:-firewall-dnswatch.service}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

ALLOW_RFC1918_192_DST="${ALLOW_RFC1918_192_DST:-1}"
WG_FORWARD_ENABLE="${WG_FORWARD_ENABLE:-1}"
WG_FORWARD_DST="${WG_FORWARD_DST:-172.20.0.200/32}"
WG_FORWARD_TCP_PORTS="${WG_FORWARD_TCP_PORTS:-1:1024 3389}"
LOG_TRAFFIC="${LOG_TRAFFIC:-0}"
LOG_RATE="${LOG_RATE:-50/second}"
LOG_BURST="${LOG_BURST:-200}"
LOG_NEW_ONLY="${LOG_NEW_ONLY:-1}"
EXCLUDE_LOG_NET_1="192.168.0.0/16"
EXCLUDE_LOG_NET_2="10.80.0.0/16"
EXCLUDE_LOG_NET_3="172.16.0.0/12"

SETTINGS_FILE="${FW_SETTINGS_FILE:-${BASE_DIR}/firewall_unidades_v2.conf}"
if [[ -r "$SETTINGS_FILE" ]]; then
    source "$SETTINGS_FILE"
fi


ACTIVE_BACKUP=""
ROLLBACK_ARMED=0
LOCK_FD=9
LOCK_HELD=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for module in \
    "$SCRIPT_DIR/lib/00_common.sh" \
    "$SCRIPT_DIR/lib/10_parser.sh" \
    "$SCRIPT_DIR/lib/15_interfaces.sh" \
    "$SCRIPT_DIR/lib/20_dns.sh"; do
    source "$module"
done

source "$SCRIPT_DIR/lib/backend/00_backend.sh"
backend_load "$SCRIPT_DIR" "$BACKEND"

for module in \
    "$SCRIPT_DIR/lib/25_dynamic_dns.sh" \
    "$SCRIPT_DIR/lib/40_rules.sh" \
    "$SCRIPT_DIR/lib/50_backup.sh" \
    "$SCRIPT_DIR/lib/60_commands.sh" \
    "$SCRIPT_DIR/lib/70_installer.sh"; do
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
        backend-info) shift; cmd_backend_info "$@" ;;
        dynamic-refresh) shift; cmd_dynamic_refresh "$@" ;;
        dynamic-status) shift; cmd_dynamic_status "$@" ;;
        dnswatch-daemon) shift; cmd_dnswatch_daemon "$@" ;;
        installservice) shift; cmd_installservice "$@" ;;
        uninstallservice) shift; cmd_uninstallservice "$@" ;;
        install) shift; cmd_install "$@" ;;
        upgrade) shift; cmd_upgrade "$@" ;;
        backups) shift; cmd_backups "$@" ;;
        rollback) shift; cmd_rollback "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage >&2; die "Comando desconhecido: $cmd" ;;
    esac
}

main "$@"
