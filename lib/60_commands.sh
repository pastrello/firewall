# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------
cmd_stats() {
    local tmp="$RUNTIME_DIR/stats.$$"
    ensure_dirs
    mkdir -p "$tmp"
    if ! parse_config "$tmp"; then
        rm -rf "$tmp"
        die "Há erros no arquivo de configuração."
    fi

    local raw_d uniq_d raw_s uniq_s
    raw_d=$(awk '$1=="d:" && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$RULES_FILE")
    uniq_d=$(( $(wc -l < "$tmp/d_numeric.txt") + $(wc -l < "$tmp/d_dns.txt") ))
    raw_s=$(awk '$1=="s:" && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$RULES_FILE")
    uniq_s=$(( $(wc -l < "$tmp/s_numeric.txt") + $(wc -l < "$tmp/s_dns.txt") ))

    cat <<EOF_STATS
Arquivo: $RULES_FILE
Linhas totais                  : $(wc -l < "$RULES_FILE")
d: ativos                      : $raw_d
d: únicos (antes de DNS)       : $uniq_d
d: IP/CIDR únicos              : $(wc -l < "$tmp/d_numeric.txt")
d: FQDN únicos                 : $(wc -l < "$tmp/d_dns.txt")
s: ativos                      : $raw_s
s: únicos                      : $uniq_s
p: portas únicas               : $(wc -l < "$tmp/ports.txt")
m: MAC HTTPS únicos            : $(wc -l < "$tmp/mac_https.txt")
c: MAC total únicos            : $(wc -l < "$tmp/mac_full.txt")
Duplicatas removíveis em d:    : $((raw_d - uniq_d))
EOF_STATS

    if [[ "$OPTIMIZE_NETWORKS" == "1" ]] && command -v python3 >/dev/null 2>&1; then
        optimize_network_file "$tmp/d_numeric.txt" "$tmp/d_numeric.optimized" "estatística d:"
        printf 'd: IP/CIDR após consolidação    : %s\n' "$(wc -l < "$tmp/d_numeric.optimized")"
    else
        printf 'd: consolidação CIDR            : python3 indisponível/desabilitado\n'
    fi
    rm -rf "$tmp"
}

cmd_check() {
    local resolve="${1:-}"
    local tmp="$RUNTIME_DIR/check.$$"
    ensure_dirs
    mkdir -p "$tmp"
    parse_config "$tmp" || { rm -rf "$tmp"; die "Validação falhou."; }
    log "Sintaxe do arquivo de regras: OK."

    if [[ "$resolve" == "--resolve" ]]; then
        build_sets_files "$tmp" || { rm -rf "$tmp"; die "Validação DNS falhou."; }
        print_runtime_summary "$tmp"
    fi
    rm -rf "$tmp"
}

cmd_generate() {
    local server_ip="${1:-${SERVER_IP:-}}"
    ensure_dirs
    [[ -n "$server_ip" ]] || die "Informe IP_DO_SERVIDOR ou configure SERVER_IP."
    build_runtime "$server_ip"
    log "Nenhuma regra do kernel foi alterada (modo generate)."
}

validate_restore_file() {
    local file="$1"
    ensure_active_set "$SET_DST"
    ensure_active_set "$SET_SRC"
    if "$IPTABLES_RESTORE" --help 2>&1 | grep -q -- '--test'; then
        "$IPTABLES_RESTORE" --test < "$file"
        log "Validação iptables-restore --test: OK."
    else
        warn "Esta versão de iptables-restore não oferece --test; validação sintática limitada ao gerador."
    fi
}

cmd_apply() {
    local server_ip="${1:-${SERVER_IP:-}}"
    require_root
    acquire_lock
    require_firewall_tools
    check_firewalld
    [[ -n "$server_ip" ]] || die "Informe IP_DO_SERVIDOR ou configure SERVER_IP."

    log "Backend: $($IPTABLES --version 2>&1 | head -1)"
    build_runtime "$server_ip"
    local dir="$RUNTIME_DIR/current"
    validate_restore_file "$dir/iptables.rules"

    create_backup
    ROLLBACK_ARMED=1
    load_ipset_atomic "$SET_DST" "$dir/destinos.final"
    load_ipset_atomic "$SET_SRC" "$dir/origens.final"

    log "Aplicando filter/nat em lote com iptables-restore..."
    "$IPTABLES_RESTORE" < "$dir/iptables.rules"
    cp -f "$dir/dns-cache.new" "$DNS_CACHE"

    ROLLBACK_ARMED=0
    log "Firewall aplicado com sucesso."
    printf '\nResumo pós-aplicação:\n'
    printf '  %s: %s elementos\n' "$SET_DST" "$($IPSET list "$SET_DST" | awk '/Number of entries:/ {print $4}')"
    printf '  %s: %s elementos\n' "$SET_SRC" "$($IPSET list "$SET_SRC" | awk '/Number of entries:/ {print $4}')"
    printf '  Regras FORWARD: %s\n' "$($IPTABLES -S FORWARD | wc -l)"
    printf '  Regras INPUT  : %s\n' "$($IPTABLES -S INPUT | wc -l)"
    printf '  Backup        : %s\n' "$ACTIVE_BACKUP"
}

cmd_refresh_sets() {
    require_root
    acquire_lock
    require_firewall_tools
    check_firewalld

    local tmp="$RUNTIME_DIR/refresh.$$"
    mkdir -p "$tmp"
    parse_config "$tmp" || { rm -rf "$tmp"; die "Configuração inválida."; }
    build_sets_files "$tmp" || { rm -rf "$tmp"; die "Falha ao montar sets."; }

    create_backup
    ROLLBACK_ARMED=1
    load_ipset_atomic "$SET_DST" "$tmp/destinos.final"
    load_ipset_atomic "$SET_SRC" "$tmp/origens.final"
    cp -f "$tmp/dns-cache.new" "$DNS_CACHE"
    ROLLBACK_ARMED=0
    rm -rf "$tmp"
    log "Sets atualizados sem recriar as chains iptables."
}

cmd_status() {
    require_root
    ensure_dirs
    require_firewall_tools
    printf 'firewall_unidades_v2 %s\n' "$VERSION"
    printf 'iptables: %s\n' "$($IPTABLES --version 2>&1 | head -1)"
    printf 'config  : %s\n' "$RULES_FILE"
    printf 'state   : %s\n\n' "$STATE_DIR"

    local s
    for s in "$SET_DST" "$SET_SRC"; do
        if "$IPSET" list "$s" >/dev/null 2>&1; then
            "$IPSET" list "$s" | awk -v n="$s" '
                /^Type:/ {type=$2}
                /^Number of entries:/ {entries=$4}
                END {printf "%s: type=%s entries=%s\n", n, type, entries}
            '
        else
            printf '%s: inexistente\n' "$s"
        fi
    done

    printf '\nRegras que usam os sets:\n'
    "$IPTABLES" -S FORWARD | grep -E "${SET_DST}|${SET_SRC}" || true
    printf '\nFinal da chain FORWARD:\n'
    "$IPTABLES" -S FORWARD | tail -10
}

cmd_diagnose() {
    ensure_dirs
    printf 'firewall_unidades v%s\n' "$VERSION"
    printf 'data/hora : %s\n' "$(now)"
    printf 'kernel    : %s\n' "$(uname -r 2>/dev/null || echo desconhecido)"
    if [[ -r /etc/os-release ]]; then
        local pretty
        pretty=$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)
        printf 'sistema   : %s\n' "${pretty:-desconhecido}"
    fi
    printf 'iptables  : %s\n' "${IPTABLES:-não encontrado}"
    [[ -n "$IPTABLES" && -x "$IPTABLES" ]] && printf 'backend   : %s\n' "$($IPTABLES --version 2>&1 | head -1)"
    printf 'ipset     : %s\n' "${IPSET:-não encontrado}"
    printf 'ip_forward: %s\n' "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    printf 'rp_filter : all=%s default=%s\n' \
        "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || echo '?')" \
        "$(cat /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || echo '?')"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            printf 'firewalld : ATIVO\n'
        else
            printf 'firewalld : inativo/não instalado\n'
        fi
    fi

    printf '\nInterfaces IPv4:\n'
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show 2>/dev/null | awk '{printf "  %-12s %s\n", $2, $4}' || true
    else
        printf '  comando ip não encontrado\n'
    fi

    if [[ -n "$IPTABLES" && -x "$IPTABLES" && ${EUID:-$(id -u)} -eq 0 ]]; then
        printf '\nPolicies atuais:\n'
        "$IPTABLES" -S 2>/dev/null | awk '$1=="-P" {print "  " $0}' || true
    else
        printf '\nPolicies atuais: execute como root para consultar.\n'
    fi

    printf '\nParâmetros relevantes para futuro inbound:\n'
    printf '  INPUT_TRUSTED_INTERFACES=%s\n' "$INPUT_TRUSTED_INTERFACES"
    printf '  ALLOW_RFC1918_192_DST=%s\n' "$ALLOW_RFC1918_192_DST"
    printf '  WG_FORWARD_ENABLE=%s\n' "$WG_FORWARD_ENABLE"
}

cmd_backups() {
    ensure_dirs
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r
}

cmd_rollback() {
    local dir="${1:-}"
    require_root
    acquire_lock
    require_firewall_tools
    [[ -n "$dir" ]] || dir=$(latest_backup)
    [[ -n "$dir" ]] || die "Nenhum backup disponível."
    [[ "$dir" == /* ]] || dir="$BACKUP_DIR/$dir"
    ROLLBACK_ARMED=0
    rollback_dir "$dir"
}
