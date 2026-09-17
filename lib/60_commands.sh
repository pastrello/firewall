# ---------------------------------------------------------------------------
# Comandos
# ---------------------------------------------------------------------------
cmd_stats() {
    local tmp="$RUNTIME_DIR/stats.$$" raw_d uniq_d raw_u uniq_u raw_s uniq_s
    ensure_dirs; mkdir -p "$tmp"
    parse_config "$tmp" || { rm -rf "$tmp"; die "Há erros no arquivo de configuração."; }
    raw_d=$(awk '$1=="d:" && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$RULES_FILE")
    uniq_d=$(( $(wc -l < "$tmp/d_numeric.txt") + $(wc -l < "$tmp/d_dns.txt") ))
    raw_u=$(awk '$1=="u:" && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$RULES_FILE"); uniq_u=$(wc -l < "$tmp/u_dns.txt")
    raw_s=$(awk '$1=="s:" && $0 !~ /^[[:space:]]*#/ {n++} END{print n+0}' "$RULES_FILE")
    uniq_s=$(( $(wc -l < "$tmp/s_numeric.txt") + $(wc -l < "$tmp/s_dns.txt") ))
    cat <<EOF_STATS
Arquivo: $RULES_FILE
Linhas totais                  : $(wc -l < "$RULES_FILE")
d: ativos                      : $raw_d
d: únicos (antes de DNS)       : $uniq_d
d: IP/CIDR únicos              : $(wc -l < "$tmp/d_numeric.txt")
d: FQDN snapshot únicos        : $(wc -l < "$tmp/d_dns.txt")
u: dinâmicos ativos            : $raw_u
u: FQDN dinâmicos únicos       : $uniq_u
s: ativos                      : $raw_s
s: únicos                      : $uniq_s
p: portas únicas               : $(wc -l < "$tmp/ports.txt")
m: MAC HTTPS únicos            : $(wc -l < "$tmp/mac_https.txt")
c: MAC total únicos            : $(wc -l < "$tmp/mac_full.txt")
Duplicatas removíveis em d:    : $((raw_d - uniq_d))
Duplicatas removíveis em u:    : $((raw_u - uniq_u))
Política interfaces            : $INTERFACE_POLICY_MODE
DNS dinâmico habilitado        : $DYNAMIC_DNS_ENABLE
EOF_STATS
    if [[ "$OPTIMIZE_NETWORKS" == "1" ]] && command -v python3 >/dev/null 2>&1; then optimize_network_file "$tmp/d_numeric.txt" "$tmp/d_numeric.optimized" "estatística d:"; fi
    rm -rf "$tmp"
}

cmd_check() {
    local resolve="${1:-}" tmp="$RUNTIME_DIR/check.$$"
    ensure_dirs; mkdir -p "$tmp"
    validate_interface_policy || { rm -rf "$tmp"; die "Validação da política de interfaces falhou."; }
    dynamic_validate_config || { rm -rf "$tmp"; die "Validação do DNS dinâmico falhou."; }
    parse_config "$tmp" || { rm -rf "$tmp"; die "Validação falhou."; }
    log "Sintaxe das regras, interfaces e DNS dinâmico: OK."
    if [[ "$resolve" == "--resolve" ]]; then
        build_sets_files "$tmp" || { rm -rf "$tmp"; die "Validação DNS d:/s: falhou."; }
        prepare_dynamic_snapshot "$tmp" || { rm -rf "$tmp"; die "Validação DNS u: falhou."; }
        print_runtime_summary "$tmp"
    fi
    rm -rf "$tmp"
}

cmd_generate() { local server_ip="${1:-${SERVER_IP:-}}"; ensure_dirs; [[ -n "$server_ip" ]] || die "Informe IP_DO_SERVIDOR ou configure SERVER_IP."; build_runtime "$server_ip"; log "Nenhuma regra do kernel foi alterada (modo generate)."; }

validate_restore_file() {
    local file="$1"; ensure_active_set "$SET_DST"; ensure_active_set "$SET_SRC"; ensure_active_set "$SET_DYN_DST"
    if "$IPTABLES_RESTORE" --help 2>&1 | grep -q -- '--test'; then "$IPTABLES_RESTORE" --test < "$file"; log "Validação iptables-restore --test: OK."
    else warn "Esta versão de iptables-restore não oferece --test; validação sintática limitada ao gerador."; fi
}

cmd_apply() {
    local server_ip="${1:-${SERVER_IP:-}}" dir
    require_root; acquire_lock; require_firewall_tools; check_firewalld
    [[ -n "$server_ip" ]] || die "Informe IP_DO_SERVIDOR ou configure SERVER_IP."
    log "Backend: $($IPTABLES --version 2>&1 | head -1)"; build_runtime "$server_ip"; dir="$RUNTIME_DIR/current"; validate_restore_file "$dir/iptables.rules"
    create_backup; ROLLBACK_ARMED=1
    load_ipset_atomic "$SET_DST" "$dir/destinos.final"; load_ipset_atomic "$SET_SRC" "$dir/origens.final"; load_ipset_atomic "$SET_DYN_DST" "$dir/dynamic-destinos.final"
    log "Aplicando filter/nat em lote com iptables-restore..."; "$IPTABLES_RESTORE" < "$dir/iptables.rules"
    cp -f "$dir/dns-cache.new" "$DNS_CACHE"; dynamic_commit_candidate "$dir"; ROLLBACK_ARMED=0; release_lock
    log "Firewall aplicado com sucesso."
    printf '\nResumo pós-aplicação:\n'
    printf '  Política      : %s\n' "$INTERFACE_POLICY_MODE"; printf '  INPUT trusted : %s\n' "$(effective_trusted_interfaces)"
    printf '  %s: %s elementos\n' "$SET_DST" "$($IPSET list "$SET_DST" | awk '/Number of entries:/ {print $4}')"
    printf '  %s: %s elementos\n' "$SET_DYN_DST" "$($IPSET list "$SET_DYN_DST" | awk '/Number of entries:/ {print $4}')"
    printf '  %s: %s elementos\n' "$SET_SRC" "$($IPSET list "$SET_SRC" | awk '/Number of entries:/ {print $4}')"
    printf '  Backup        : %s\n' "$ACTIVE_BACKUP"
}

cmd_refresh_sets() {
    require_root; acquire_lock; require_firewall_tools; check_firewalld
    local tmp="$RUNTIME_DIR/refresh.$$"; mkdir -p "$tmp"
    parse_config "$tmp" || { rm -rf "$tmp"; die "Configuração inválida."; }
    build_sets_files "$tmp" || { rm -rf "$tmp"; die "Falha ao montar sets d:/s:."; }
    prepare_dynamic_snapshot "$tmp" || { rm -rf "$tmp"; die "Falha ao montar set u:."; }
    create_backup; ROLLBACK_ARMED=1
    load_ipset_atomic "$SET_DST" "$tmp/destinos.final"; load_ipset_atomic "$SET_SRC" "$tmp/origens.final"; load_ipset_atomic "$SET_DYN_DST" "$tmp/dynamic-destinos.final"
    cp -f "$tmp/dns-cache.new" "$DNS_CACHE"; dynamic_commit_candidate "$tmp"; ROLLBACK_ARMED=0; release_lock; rm -rf "$tmp"
    log "Sets d:/s:/u: atualizados sem recriar as chains iptables."
}

cmd_status() {
    require_root; ensure_dirs; require_firewall_tools
    printf 'firewall_unidades v%s\niptables: %s\nconfig  : %s\nstate   : %s\npolicy  : %s\ntrusted : %s\n\n' "$VERSION" "$($IPTABLES --version 2>&1 | head -1)" "$RULES_FILE" "$STATE_DIR" "$INTERFACE_POLICY_MODE" "$(effective_trusted_interfaces)"
    local s
    for s in "$SET_DST" "$SET_DYN_DST" "$SET_SRC"; do
        if "$IPSET" list "$s" >/dev/null 2>&1; then "$IPSET" list "$s" | awk -v n="$s" '/^Type:/ {type=$2} /^Number of entries:/ {entries=$4} END {printf "%s: type=%s entries=%s\n",n,type,entries}'
        else printf '%s: inexistente\n' "$s"; fi
    done
    if command -v systemctl >/dev/null 2>&1; then printf 'dnswatch: active=%s enabled=%s\n' "$(systemctl is-active "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)" "$(systemctl is-enabled "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)"; fi
    printf '\nRegras que usam os sets:\n'; "$IPTABLES" -S FORWARD | grep -E "${SET_DST}|${SET_DYN_DST}|${SET_SRC}" || true
}

cmd_diagnose() {
    ensure_dirs
    printf 'firewall_unidades v%s\ndata/hora : %s\nkernel    : %s\n' "$VERSION" "$(now)" "$(uname -r 2>/dev/null || echo desconhecido)"
    [[ -r /etc/os-release ]] && printf 'sistema   : %s\n' "$(awk -F= '$1=="PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)"
    printf 'iptables  : %s\nipset     : %s\ndig       : %s\nip_forward: %s\n' "${IPTABLES:-não encontrado}" "${IPSET:-não encontrado}" "$(command -v dig 2>/dev/null || echo 'não encontrado (bind-utils)')" "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"
    if command -v systemctl >/dev/null 2>&1; then printf 'dnswatch  : active=%s enabled=%s\n' "$(systemctl is-active "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)" "$(systemctl is-enabled "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)"; fi
    print_interface_diagnostics
    printf '\nValidação da política:\n'; if validate_interface_policy && dynamic_validate_config; then printf '  resultado: OK\n'; else printf '  resultado: ERRO\n'; fi
    printf '\nDNS dinâmico v2.3:\n  habilitado        : %s\n  intervalo min/max : %ss / %ss\n  TTL divisor       : %s\n  grace             : %ss\n  stale max         : %ss\n  fail policy       : %s\n' "$DYNAMIC_DNS_ENABLE" "$DYNAMIC_DNS_MIN_INTERVAL" "$DYNAMIC_DNS_MAX_INTERVAL" "$DYNAMIC_DNS_TTL_DIVISOR" "$DYNAMIC_DNS_GRACE" "$DYNAMIC_DNS_STALE_MAX" "$DYNAMIC_DNS_FAIL_POLICY"
}

cmd_dynamic_refresh() {
    dynamic_require_daemon_tools; acquire_lock
    if dynamic_refresh_once; then release_lock; log "Atualização dinâmica manual concluída."
    else release_lock; die "Atualização dinâmica manual falhou; o conjunto anterior foi preservado."; fi
}

dynamic_meta_value() { local key="$1"; [[ -r "$DYNAMIC_META_FILE" ]] && awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1); exit}' "$DYNAMIC_META_FILE"; }

cmd_dynamic_status() {
    require_root; ensure_dirs; [[ -n "$IPSET" && -x "$IPSET" ]] || die "ipset não encontrado."
    printf 'firewall_unidades dynamic DNS v%s\n' "$VERSION"
    if command -v systemctl >/dev/null 2>&1; then printf 'service : active=%s enabled=%s\n' "$(systemctl is-active "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)" "$(systemctl is-enabled "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)"; fi
    printf 'ipset   : '; if "$IPSET" list "$SET_DYN_DST" >/dev/null 2>&1; then "$IPSET" list "$SET_DYN_DST" | awk '/Number of entries:/ {print $4 " endereço(s)"}'; else printf 'inexistente\n'; fi
    if [[ -r "$DYNAMIC_META_FILE" ]]; then
        local epoch last next hosts failures resolver; epoch=$(dynamic_meta_value last_cycle_epoch); next=$(dynamic_meta_value next_sleep); hosts=$(dynamic_meta_value configured_hosts); failures=$(dynamic_meta_value failures); resolver=$(dynamic_meta_value resolver)
        if is_uint "$epoch"; then last=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$epoch"); else last="?"; fi
        printf 'último  : %s\npróximo : ~%ss após o último ciclo\nhosts   : %s | falhas DNS: %s | resolver: %s\n' "$last" "${next:-?}" "${hosts:-?}" "${failures:-?}" "${resolver:-?}"
    else printf 'estado  : ainda não há ciclo persistido\n'; fi
    if [[ -s "$DYNAMIC_STATUS_FILE" ]]; then
        printf '\n%-38s %-12s %-7s %s\n' HOST STATUS TTL IPs
        while IFS=$'\t' read -r host status ttl ips detail; do printf '%-38s %-12s %-7s %s' "$host" "$status" "$ttl" "$ips"; [[ -n "$detail" ]] && printf '  (%s)' "$detail"; printf '\n'; done < "$DYNAMIC_STATUS_FILE"
    fi
}

cmd_dnswatch_daemon() {
    dynamic_require_daemon_tools; dynamic_validate_config || die "Parâmetros do DNS dinâmico inválidos."; ensure_dirs
    trap 'release_lock; log "DNS watcher encerrado."; exit 0' TERM INT
    log "DNS watcher iniciado (serviço=$DYNAMIC_DNS_SERVICE_NAME, set=$SET_DYN_DST)."
    local sleep_seconds
    while true; do
        sleep_seconds="$DYNAMIC_DNS_MIN_INTERVAL"
        if acquire_lock_wait "$DYNAMIC_DNS_LOCK_TIMEOUT"; then
            if dynamic_refresh_once; then sleep_seconds="$DYNAMIC_NEXT_SLEEP"; else warn "DNS watcher: ciclo falhou; conjunto anterior preservado."; fi
            release_lock
        else warn "DNS watcher: firewall ocupado por outra operação; tentando novamente em ${DYNAMIC_DNS_MIN_INTERVAL}s."; fi
        sleep "$sleep_seconds" & wait $! || true
    done
}

cmd_installservice() {
    require_root; need_cmd systemctl; need_cmd install; need_cmd readlink; dynamic_require_daemon_tools; dynamic_validate_config || die "Configuração do DNS dinâmico inválida."
    local tmp_parse="$RUNTIME_DIR/installservice.$$" unit tmp_unit script_path count
    ensure_dirs; mkdir -p "$tmp_parse"; parse_config "$tmp_parse" || { rm -rf "$tmp_parse"; die "regras_firewall.conf inválido; serviço não instalado."; }
    count=$(wc -l < "$tmp_parse/u_dns.txt"); rm -rf "$tmp_parse"
    (( count > 0 )) || warn "Nenhuma regra u: configurada. O serviço será instalado e ficará ocioso até existir uma."
    "$IPTABLES" -S FORWARD 2>/dev/null | grep -q -- "$SET_DYN_DST" || warn "O ruleset ativo ainda não referencia $SET_DYN_DST. Execute generate/apply da v2.3 para que regras u: tenham efeito."
    script_path=$(readlink -f "$SCRIPT_DIR/firewall_unidades.sh"); [[ -x "$script_path" ]] || die "Script principal não é executável: $script_path"
    unit=$(dynamic_service_unit_path); tmp_unit="${STATE_DIR}/${DYNAMIC_DNS_SERVICE_NAME}.new"; dynamic_write_service_unit "$tmp_unit" "$script_path"
    install -m 0644 "$tmp_unit" "$unit"; rm -f "$tmp_unit"; systemctl daemon-reload; systemctl enable --now "$DYNAMIC_DNS_SERVICE_NAME"
    log "Serviço instalado: $unit"; printf '  script : %s\n  regras : %s\n  u:     : %s hostname(s)\n  status : %s\n' "$script_path" "$RULES_FILE" "$count" "$(systemctl is-active "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true)"
    printf '\nUse: %s dynamic-status\n' "$script_path"
}

cmd_uninstallservice() {
    require_root; need_cmd systemctl; local unit; unit=$(dynamic_service_unit_path)
    systemctl disable --now "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true; rm -f "$unit"; systemctl daemon-reload; systemctl reset-failed "$DYNAMIC_DNS_SERVICE_NAME" 2>/dev/null || true
    log "Serviço $DYNAMIC_DNS_SERVICE_NAME removido. O ipset $SET_DYN_DST e o estado foram preservados."
}

cmd_backups() { ensure_dirs; find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r; }
cmd_rollback() { local dir="${1:-}"; require_root; acquire_lock; require_firewall_tools; [[ -n "$dir" ]] || dir=$(latest_backup); [[ -n "$dir" ]] || die "Nenhum backup disponível."; [[ "$dir" == /* ]] || dir="$BACKUP_DIR/$dir"; ROLLBACK_ARMED=0; rollback_dir "$dir"; release_lock; }
