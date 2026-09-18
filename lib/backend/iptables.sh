# ---------------------------------------------------------------------------
# Backend iptables + ipset - v2.4
# ---------------------------------------------------------------------------
# Implementa a semântica existente da v2.3.1 sem alteração funcional.

IPTABLES="${IPTABLES:-$(command -v iptables 2>/dev/null || true)}"
IPTABLES_SAVE="${IPTABLES_SAVE:-$(command -v iptables-save 2>/dev/null || true)}"
IPTABLES_RESTORE="${IPTABLES_RESTORE:-$(command -v iptables-restore 2>/dev/null || true)}"
IPSET="${IPSET:-$(command -v ipset 2>/dev/null || true)}"

backend_require_tools() {
    [[ -n "$IPTABLES" && -x "$IPTABLES" ]] || die "iptables não encontrado."
    [[ -n "$IPTABLES_SAVE" && -x "$IPTABLES_SAVE" ]] || die "iptables-save não encontrado."
    [[ -n "$IPTABLES_RESTORE" && -x "$IPTABLES_RESTORE" ]] || die "iptables-restore não encontrado."
    [[ -n "$IPSET" && -x "$IPSET" ]] || die "ipset não encontrado. Instale o pacote 'ipset'."
    require_common_tools
}

backend_rules_filename() { printf 'iptables.rules\n'; }

backend_set_ensure() {
    local name="${1:?nome do set ausente}"
    "$IPSET" create "$name" hash:net family inet hashsize "$SET_HASH_SIZE" maxelem "$SET_MAXELEM" -exist
}

backend_set_load_atomic() {
    local name="${1:?nome do set ausente}"
    local entries="${2:?arquivo de entradas ausente}"
    local tmp="${name}_NEW" count
    count=$(wc -l < "$entries")
    (( count <= SET_MAXELEM )) || die "O conjunto $name possui $count elementos, acima de SET_MAXELEM=$SET_MAXELEM."

    backend_set_ensure "$name"
    "$IPSET" destroy "$tmp" 2>/dev/null || true
    {
        printf 'create %s hash:net family inet hashsize %s maxelem %s\n' "$tmp" "$SET_HASH_SIZE" "$SET_MAXELEM"
        while IFS= read -r value; do
            [[ -n "$value" ]] || continue
            printf 'add %s %s\n' "$tmp" "$value"
        done < "$entries"
    } | "$IPSET" restore

    "$IPSET" swap "$tmp" "$name"
    "$IPSET" destroy "$tmp"
    log "backend=iptables: ipset $name atualizado atomicamente: $count elemento(s)."
}

backend_set_export_entries() {
    local name="${1:?nome do set ausente}"
    local outfile="${2:?arquivo de saída ausente}"
    : > "$outfile"
    if backend_set_exists "$name"; then
        "$IPSET" save "$name" | awk -v n="$name" '$1=="add" && $2==n {print $3}' | LC_ALL=C sort -u > "$outfile"
    fi
}

backend_set_save_backup() {
    local name="${1:?nome do set ausente}"
    local outfile="${2:?arquivo de backup ausente}"
    backend_set_export_entries "$name" "$outfile"
    if backend_set_exists "$name"; then printf '1\n' > "${outfile}.existed"; else printf '0\n' > "${outfile}.existed"; fi
}

backend_set_destroy() {
    local name="${1:?nome do set ausente}"
    "$IPSET" destroy "$name" 2>/dev/null || true
}

backend_set_exists() {
    local name="${1:?nome do set ausente}"
    "$IPSET" list "$name" >/dev/null 2>&1
}

backend_set_count() {
    local name="${1:?nome do set ausente}"
    if backend_set_exists "$name"; then
        "$IPSET" list "$name" | awk '/Number of entries:/ {print $4; found=1} END{if(!found) print 0}'
    else
        printf '0\n'
    fi
}

backend_emit_filter_rules() {
    local parsedir="${1:?parsedir ausente}"
    local outfile="${2:?outfile ausente}"
    local mac port

    cat > "$outfile" <<'EOF_FILTER'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:LOG_INTERNET - [0:0]

# INPUT base
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
EOF_FILTER

    emit_trusted_input_rules "$outfile"
    emit_local_input_rules "$outfile"
    emit_trusted_source_rules "$outfile"

    cat >> "$outfile" <<'EOF_FILTER'

-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate INVALID -j DROP

# MACs com acesso total (c:)
EOF_FILTER

    while IFS= read -r mac; do
        [[ -n "$mac" ]] && printf -- '-A FORWARD -m mac --mac-source %s -j ACCEPT\n' "$mac" >> "$outfile"
    done < "$parsedir/mac_full.txt"

    if [[ "$WG_FORWARD_ENABLE" == "1" ]]; then
        local wg_port
        printf '\n# VPN WireGuard - portas de destino\n' >> "$outfile"
        for wg_port in $WG_FORWARD_TCP_PORTS; do
            [[ -n "$wg_port" ]] && printf -- '-A FORWARD -d %s -p tcp --dport %s -j ACCEPT\n' "$WG_FORWARD_DST" "$wg_port" >> "$outfile"
        done
    fi

    cat >> "$outfile" <<EOF_FILTER

# Logging de tráfego externo
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_1} -j RETURN
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_2} -j RETURN
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_3} -j RETURN
EOF_FILTER

    if [[ "$LOG_TRAFFIC" == "1" ]]; then
        local log_state=""
        [[ "$LOG_NEW_ONLY" == "1" ]] && log_state="-m conntrack --ctstate NEW "
        if [[ -n "$LOG_RATE" ]]; then
            printf -- '-A LOG_INTERNET %s-m limit --limit %s --limit-burst %s -j LOG --log-prefix "TRAFFIC_LOG: " --log-level 6\n' "$log_state" "$LOG_RATE" "$LOG_BURST" >> "$outfile"
        else
            printf -- '-A LOG_INTERNET %s-j LOG --log-prefix "TRAFFIC_LOG: " --log-level 6\n' "$log_state" >> "$outfile"
        fi
    fi
    printf -- '-A FORWARD -j LOG_INTERNET\n' >> "$outfile"

    cat >> "$outfile" <<'EOF_FILTER'

-A FORWARD -s 172.16.0.0/16 -j ACCEPT
-A FORWARD -d 172.16.0.0/16 -j ACCEPT
-A FORWARD -s 10.80.0.0/16 -j ACCEPT
-A FORWARD -d 10.80.0.0/16 -j ACCEPT

# Portas TCP globais (p:)
EOF_FILTER

    while IFS= read -r port; do
        [[ -n "$port" ]] && printf -- '-A FORWARD -p tcp --dport %s -j ACCEPT\n' "$port" >> "$outfile"
    done < "$parsedir/ports.txt"

    printf '\n# MACs liberados apenas para HTTPS (m:)\n' >> "$outfile"
    while IFS= read -r mac; do
        [[ -n "$mac" ]] && printf -- '-A FORWARD -m mac --mac-source %s -p tcp --dport 443 -j ACCEPT\n' "$mac" >> "$outfile"
    done < "$parsedir/mac_https.txt"

    cat >> "$outfile" <<EOF_FILTER

# Listas grandes / dinâmicas: uma regra por ipset
-A FORWARD -m set --match-set ${SET_DST} dst -j ACCEPT
-A FORWARD -m set --match-set ${SET_DYN_DST} dst -j ACCEPT
-A FORWARD -m set --match-set ${SET_SRC} src -j ACCEPT
EOF_FILTER

    [[ "$ALLOW_RFC1918_192_DST" == "1" ]] && printf -- '-A FORWARD -d 192.168.0.0/16 -j ACCEPT\n' >> "$outfile"
    cat >> "$outfile" <<'EOF_FILTER'
-A FORWARD -j DROP
COMMIT
EOF_FILTER
}

backend_emit_nat_rules() {
    local server_ip="${1:?server_ip ausente}"
    local outfile="${2:?outfile ausente}"
    local net24
    net24=$(server_net24 "$server_ip")
    cat >> "$outfile" <<EOF_NAT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 192.168.0.0/16 -d 10.80.0.0/24 -j RETURN
-A POSTROUTING -s ${net24} ! -d 192.168.0.0/16 -j MASQUERADE
COMMIT
EOF_NAT
}

backend_generate_rules() {
    local parsedir="${1:?parsedir ausente}"
    local outfile="${2:?outfile ausente}"
    local server_ip="${3:?server_ip ausente}"
    backend_emit_filter_rules "$parsedir" "$outfile"
    backend_emit_nat_rules "$server_ip" "$outfile"
}

backend_validate_rules() {
    local file="${1:?arquivo de regras ausente}"
    backend_set_ensure "$SET_DST"
    backend_set_ensure "$SET_SRC"
    backend_set_ensure "$SET_DYN_DST"
    if "$IPTABLES_RESTORE" --help 2>&1 | grep -q -- '--test'; then
        "$IPTABLES_RESTORE" --test < "$file"
        log "backend=iptables: validação iptables-restore --test: OK."
    else
        warn "iptables-restore não oferece --test; validação sintática limitada ao gerador."
    fi
}

backend_apply_rules() {
    local file="${1:?arquivo de regras ausente}"
    log "Aplicando backend=iptables em lote com iptables-restore..."
    "$IPTABLES_RESTORE" < "$file"
}

backend_backup_rules() {
    local dir="${1:?diretório de backup ausente}"
    "$IPTABLES_SAVE" > "$dir/iptables.save"
}

backend_restore_rules() {
    local dir="${1:?diretório de backup ausente}"
    [[ -s "$dir/iptables.save" ]] || die "Backup sem iptables.save: $dir"
    "$IPTABLES_RESTORE" < "$dir/iptables.save"
}

backend_ruleset_uses_set() {
    local name="${1:?nome do set ausente}"
    "$IPTABLES" -S FORWARD 2>/dev/null | grep -q -- "$name"
}

backend_print_status() {
    printf 'backend : iptables\n'
    printf 'engine  : %s\n' "$("$IPTABLES" --version 2>&1 | head -1)"
    printf 'ipset   : %s\n' "$IPSET"
    local s
    for s in "$SET_DST" "$SET_DYN_DST" "$SET_SRC"; do
        if backend_set_exists "$s"; then
            printf '%s: type=hash:net entries=%s\n' "$s" "$(backend_set_count "$s")"
        else
            printf '%s: inexistente\n' "$s"
        fi
    done
    printf '\nRegras que usam os sets:\n'
    "$IPTABLES" -S FORWARD | grep -E "${SET_DST}|${SET_DYN_DST}|${SET_SRC}" || true
}

backend_print_diagnose() {
    printf 'backend   : iptables\n'
    printf 'iptables  : %s\n' "${IPTABLES:-não encontrado}"
    if [[ -n "$IPTABLES" && -x "$IPTABLES" ]]; then
        printf 'engine    : %s\n' "$("$IPTABLES" --version 2>&1 | head -1)"
    fi
    printf 'ipset     : %s\n' "${IPSET:-não encontrado}"
}

backend_print_info() {
    printf 'Backend configurado : iptables\n'
    if [[ -n "$IPTABLES" && -x "$IPTABLES" ]]; then
        printf 'iptables            : %s\n' "$("$IPTABLES" --version 2>&1 | head -1)"
    else
        printf 'iptables            : não encontrado\n'
    fi
    if [[ -n "$IPSET" && -x "$IPSET" ]]; then
        printf 'ipset               : %s\n' "$IPSET"
    else
        printf 'ipset               : não encontrado\n'
    fi
    if command -v nft >/dev/null 2>&1; then
        printf 'nft disponível       : %s (backend planejado para v2.5)\n' "$(nft --version 2>&1 | head -1)"
    else
        printf 'nft disponível       : não\n'
    fi
}
