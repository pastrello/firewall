#!/usr/bin/env bash
#
# firewall_unidades.sh
# Gerenciador de firewall otimizado para listas extensas.
# Compatibilidade alvo: EL7/EL8/EL9 (CentOS/RHEL/Rocky equivalentes onde aplicável).
#
# Formato de regras outbound preservado:
#   d: destino IP/CIDR/FQDN   -> libera FORWARD para o destino
#   s: origem IP/CIDR/FQDN    -> libera FORWARD para a origem
#   p: porta TCP              -> libera FORWARD para a porta
#   m: MAC                    -> libera TCP/443 para o MAC
#   c: MAC                    -> libera FORWARD total para o MAC
#
# v2.2 acrescenta hardening de interfaces:
#   - papéis WAN/LAN/VPN explícitos
#   - modo compat para migração sem corte inesperado
#   - WAN nunca recebe ACCEPT genérico em INPUT no modo roles
#   - serviços locais passam a ser declarativos (LOCAL_INPUT_RULES)
#   - validação de interface ausente/sobreposição
#   - diagnóstico de ip_forward/rp_filter por interface
#
# IMPORTANTE:
#   Este gerenciador assume controle exclusivo das tabelas IPv4 filter e nat,
#   assim como o script legado (que executava iptables -F). Não misture com
#   firewalld sem revisar a arquitetura.

set -Eeuo pipefail
umask 077

VERSION="2.2.0"

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

# v2.2: política de interfaces. O default compat evita quebra em upgrades.
INTERFACE_POLICY_MODE="${INTERFACE_POLICY_MODE:-compat}"   # compat | roles
INTERFACE_MISSING_POLICY="${INTERFACE_MISSING_POLICY:-warn}" # ignore | warn | error
WAN_INTERFACES="${WAN_INTERFACES:-}"
LAN_INTERFACES="${LAN_INTERFACES:-}"
VPN_INTERFACES="${VPN_INTERFACES:-}"

# Lista antiga. Só recebe ACCEPT genérico quando INTERFACE_POLICY_MODE=compat.
INPUT_TRUSTED_INTERFACES="${INPUT_TRUSTED_INTERFACES:-eth0 em1 enX0 eno1 tap0 tap1 wg0}"
INPUT_TRUSTED_SOURCES="${INPUT_TRUSTED_SOURCES:-10.80.0.0/16 172.20.0.0/24}"

# Regras locais legadas da porta 300, agora declarativas e sobrescrevíveis
# no firewall_unidades_v2.conf. Formato:
# name=... iface=<if|@wan|@lan|@vpn> proto=tcp|udp port=N|N:N src=any|IPv4/CIDR enabled=0|1
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
    "$SCRIPT_DIR/lib/15_interfaces.sh" \
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
