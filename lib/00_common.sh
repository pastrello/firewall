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
firewall_unidades_v2.sh v${VERSION}

Uso:
  $0 check [--resolve]
  $0 stats
  $0 generate [IP_DO_SERVIDOR]
  $0 apply [IP_DO_SERVIDOR]
  $0 refresh-sets
  $0 status
  $0 diagnose
  $0 rollback [DIRETORIO_BACKUP]
  $0 backups

Comandos:
  check         Valida sintaxe do regras_firewall.conf. Com --resolve, testa DNS.
  stats         Mostra quantidade de regras e duplicatas, sem alterar o firewall.
  generate      Gera os arquivos runtime, mas não altera o firewall.
  apply         Faz backup, monta ipsets e aplica filter/nat em lote.
  refresh-sets  Reprocessa d:/s: e troca os ipsets atomicamente, sem recriar iptables.
  status        Mostra resumo do backend, ipsets e regras gerenciadas.
  diagnose      Diagnóstico somente leitura para implantação e troubleshooting.
  rollback      Restaura um backup; sem argumento usa o mais recente.
  backups       Lista backups disponíveis.

IP_DO_SERVIDOR pode também ser definido como SERVER_IP no arquivo:
  ${SETTINGS_FILE}

Exemplos:
  $0 stats
  $0 check --resolve
  $0 generate 192.168.11.1
  $0 apply 192.168.11.1
  $0 refresh-sets
EOF_USAGE
}

ensure_dirs() {
    mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
    chmod 700 "$STATE_DIR" "$RUNTIME_DIR" "$BACKUP_DIR"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Este comando precisa ser executado como root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"
}

require_firewall_tools() {
    [[ -n "$IPTABLES" && -x "$IPTABLES" ]] || die "iptables não encontrado."
    [[ -n "$IPTABLES_SAVE" && -x "$IPTABLES_SAVE" ]] || die "iptables-save não encontrado."
    [[ -n "$IPTABLES_RESTORE" && -x "$IPTABLES_RESTORE" ]] || die "iptables-restore não encontrado."
    [[ -n "$IPSET" && -x "$IPSET" ]] || die "ipset não encontrado. Instale o pacote 'ipset'."
    need_cmd sort
    need_cmd awk
    need_cmd sed
    need_cmd grep
    need_cmd getent
    need_cmd timeout
    need_cmd flock
}

acquire_lock() {
    ensure_dirs
    eval "exec ${LOCK_FD}>\"${LOCK_FILE}\""
    flock -n "$LOCK_FD" || die "Já existe outra execução do firewall em andamento."
}

check_firewalld() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [[ "$ALLOW_FIREWALLD" == "1" ]]; then
            warn "firewalld está ativo. Prosseguindo porque ALLOW_FIREWALLD=1."
        else
            die "firewalld está ativo. Este gerenciador assume controle exclusivo de filter/nat. Desative-o ou revise ALLOW_FIREWALLD conscientemente."
        fi
    fi
}

valid_ipv4_cidr() {
    local value="$1" ip prefix o1 o2 o3 o4 extra o
    ip="$value"
    prefix="32"
    if [[ "$value" == */* ]]; then
        ip="${value%/*}"
        prefix="${value##*/}"
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
        (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    fi
    IFS='.' read -r o1 o2 o3 o4 extra <<< "$ip"
    [[ -n "$o1" && -n "$o2" && -n "$o3" && -n "$o4" && -z "${extra:-}" ]] || return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
    done
    return 0
}

valid_mac() {
    [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_hostname() {
    local h="$1"
    [[ ${#h} -le 253 ]] || return 1
    [[ "$h" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    [[ "$h" != .* && "$h" != *. ]] || return 1
    return 0
}

server_net24() {
    local ip="$1" a b c d extra
    valid_ipv4_cidr "$ip" || die "IP do servidor inválido: $ip"
    [[ "$ip" != */* ]] || die "Informe apenas o IP do servidor, sem CIDR: $ip"
    IFS='.' read -r a b c d extra <<< "$ip"
    printf '%s.%s.%s.0/24\n' "$a" "$b" "$c"
}
