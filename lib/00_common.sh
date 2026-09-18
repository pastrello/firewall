# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
now() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
    local msg="[$(now)] $*"
    printf '%s\n' "$msg"
    if [[ -d "$STATE_DIR" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}
warn() { log "[AVISO] $*" >&2; }
die()  { log "[ERRO] $*" >&2; exit 1; }

usage() {
    cat <<EOF_USAGE
firewall_unidades.sh v${VERSION}

Uso:
  $0 check [--resolve]
  $0 stats
  $0 generate [IP_DO_SERVIDOR]
  $0 apply [IP_DO_SERVIDOR]
  $0 refresh-sets
  $0 status
  $0 diagnose
  $0 backend-info
  $0 dynamic-refresh
  $0 dynamic-status
  $0 installservice
  $0 uninstallservice
  $0 rollback [DIRETORIO_BACKUP]
  $0 backups

Comandos:
  check            Valida regras e política. Com --resolve, testa DNS d:/s:/u:.
  stats            Mostra quantidade de regras e duplicatas sem alterar firewall.
  generate         Gera runtime, incluindo snapshot atual de u:, sem alterar kernel.
  apply            Faz backup, monta ipsets e aplica filter/nat em lote.
  refresh-sets     Reprocessa d:/s:/u: e troca os ipsets atomicamente.
  status           Mostra backend, ipsets e regras gerenciadas.
  diagnose         Diagnóstico somente leitura para implantação/troubleshooting.
  backend-info      Mostra backend selecionado e mecanismos disponíveis.
  dynamic-refresh  Força uma atualização imediata do ipset de destinos u:.
  dynamic-status   Mostra estado do DNS watcher e destinos dinâmicos.
  installservice   Instala/habilita/inicia firewall-dnswatch.service no systemd.
  uninstallservice Para/desabilita/remove o serviço, sem apagar o ipset atual.
  rollback         Restaura um backup; sem argumento usa o mais recente.
  backups          Lista backups disponíveis.

Backend v2.4:
  BACKEND="iptables"   # nftables entra na v2.5

Formato dinâmico:
  u: pastrello.ddns.net

IP_DO_SERVIDOR pode também ser definido como SERVER_IP no arquivo:
  ${SETTINGS_FILE}

Fluxo recomendado:
  $0 diagnose
  $0 check --resolve
  $0 generate 192.168.11.1
  # revise o ruleset
  $0 apply 192.168.11.1
  $0 installservice
  $0 dynamic-status
EOF_USAGE
}

ensure_dirs() {
    mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$DYNAMIC_STATE_DIR"
    chmod 700 "$STATE_DIR" "$RUNTIME_DIR" "$BACKUP_DIR" "$DYNAMIC_STATE_DIR"
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Este comando precisa ser executado como root."; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

require_common_tools() {
    need_cmd sort
    need_cmd awk
    need_cmd sed
    need_cmd grep
    need_cmd getent
    need_cmd timeout
    need_cmd flock
    need_cmd cmp
}

acquire_lock() {
    ensure_dirs
    eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
    flock -n "$LOCK_FD" || die "Já existe outra execução do firewall em andamento."
    LOCK_HELD=1
}

acquire_lock_wait() {
    local timeout_seconds="${1:-20}"
    ensure_dirs
    eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
    if flock -w "$timeout_seconds" "$LOCK_FD"; then
        LOCK_HELD=1
        return 0
    fi
    eval "exec ${LOCK_FD}>&-" || true
    LOCK_HELD=0
    return 1
}

release_lock() {
    if [[ "${LOCK_HELD:-0}" == "1" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" || true
        LOCK_HELD=0
    fi
}

check_firewalld() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [[ "$ALLOW_FIREWALLD" == "1" ]]; then warn "firewalld está ativo. Prosseguindo porque ALLOW_FIREWALLD=1.";
        else die "firewalld está ativo. Este gerenciador assume controle exclusivo de filter/nat. Desative-o ou revise ALLOW_FIREWALLD conscientemente."; fi
    fi
}

valid_ipv4_cidr() {
    local value="$1" ip prefix o1 o2 o3 o4 extra o
    ip="$value"; prefix="32"
    if [[ "$value" == */* ]]; then
        ip="${value%/*}"; prefix="${value##*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
        (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    [[ -n "$o1" && -n "$o2" && -n "$o3" && -n "$o4" && -z "${extra:-}" ]] || return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1; (( 10#$o <= 255 )) || return 1; done
}

valid_mac() { [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_hostname() { local h="$1"; [[ ${#h} -le 253 ]] && [[ "$h" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$h" != .* && "$h" != *. ]]; }

server_net24() {
    local ip="$1" a b c d extra
    valid_ipv4_cidr "$ip" || die "IP do servidor inválido: $ip"
    [[ "$ip" != */* ]] || die "Informe apenas o IP do servidor, sem CIDR: $ip"
    IFS='.' read -r a b c d extra <<< "$ip"
    printf '%s.%s.%s.0/24\n' "$a" "$b" "$c"
}
