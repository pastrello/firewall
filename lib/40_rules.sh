# ---------------------------------------------------------------------------
# Geração do ruleset iptables-restore
# ---------------------------------------------------------------------------
emit_filter_rules() {
    local parsedir="$1" outfile="$2" mac port
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
    while IFS= read -r mac; do [[ -n "$mac" ]] && printf -- '-A FORWARD -m mac --mac-source %s -j ACCEPT\n' "$mac" >> "$outfile"; done < "$parsedir/mac_full.txt"

    if [[ "$WG_FORWARD_ENABLE" == "1" ]]; then
        local wg_port
        printf '\n# VPN WireGuard - portas de destino\n' >> "$outfile"
        for wg_port in $WG_FORWARD_TCP_PORTS; do [[ -n "$wg_port" ]] && printf -- '-A FORWARD -d %s -p tcp --dport %s -j ACCEPT\n' "$WG_FORWARD_DST" "$wg_port" >> "$outfile"; done
    fi

    cat >> "$outfile" <<EOF_FILTER

# Logging de tráfego externo
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_1} -j RETURN
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_2} -j RETURN
-A LOG_INTERNET -d ${EXCLUDE_LOG_NET_3} -j RETURN
EOF_FILTER
    if [[ "$LOG_TRAFFIC" == "1" ]]; then
        local log_state=""; [[ "$LOG_NEW_ONLY" == "1" ]] && log_state="-m conntrack --ctstate NEW "
        if [[ -n "$LOG_RATE" ]]; then printf -- '-A LOG_INTERNET %s-m limit --limit %s --limit-burst %s -j LOG --log-prefix "TRAFFIC_LOG: " --log-level 6\n' "$log_state" "$LOG_RATE" "$LOG_BURST" >> "$outfile"
        else printf -- '-A LOG_INTERNET %s-j LOG --log-prefix "TRAFFIC_LOG: " --log-level 6\n' "$log_state" >> "$outfile"; fi
    fi
    printf -- '-A FORWARD -j LOG_INTERNET\n' >> "$outfile"

    cat >> "$outfile" <<'EOF_FILTER'

-A FORWARD -s 172.16.0.0/16 -j ACCEPT
-A FORWARD -d 172.16.0.0/16 -j ACCEPT
-A FORWARD -s 10.80.0.0/16 -j ACCEPT
-A FORWARD -d 10.80.0.0/16 -j ACCEPT

# Portas TCP globais (p:)
EOF_FILTER
    while IFS= read -r port; do [[ -n "$port" ]] && printf -- '-A FORWARD -p tcp --dport %s -j ACCEPT\n' "$port" >> "$outfile"; done < "$parsedir/ports.txt"
    printf '\n# MACs liberados apenas para HTTPS (m:)\n' >> "$outfile"
    while IFS= read -r mac; do [[ -n "$mac" ]] && printf -- '-A FORWARD -m mac --mac-source %s -p tcp --dport 443 -j ACCEPT\n' "$mac" >> "$outfile"; done < "$parsedir/mac_https.txt"

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

emit_nat_rules() {
    local server_ip="$1" outfile="$2" net24; net24=$(server_net24 "$server_ip")
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

build_runtime() {
    local server_ip="${1:-${SERVER_IP:-}}" work="$RUNTIME_DIR/build.$$" target="$RUNTIME_DIR/current"
    mkdir -p "$work"
    validate_interface_policy || { rm -rf "$work"; die "Política de interfaces/serviços locais inválida; nada foi aplicado."; }
    dynamic_validate_config || { rm -rf "$work"; die "Configuração de DNS dinâmico inválida; nada foi aplicado."; }
    parse_config "$work" || { rm -rf "$work"; die "Configuração inválida; nada foi aplicado."; }
    build_sets_files "$work" || { rm -rf "$work"; die "Falha ao preparar destinos/origens."; }
    prepare_dynamic_snapshot "$work" || { rm -rf "$work"; die "Falha ao preparar destinos dinâmicos u:."; }
    if [[ -n "$server_ip" ]]; then
        valid_ipv4_cidr "$server_ip" || { rm -rf "$work"; die "SERVER_IP inválido: $server_ip"; }
        [[ "$server_ip" != */* ]] || { rm -rf "$work"; die "SERVER_IP deve ser informado sem CIDR."; }
        emit_filter_rules "$work" "$work/iptables.rules"; emit_nat_rules "$server_ip" "$work/iptables.rules"
        printf '%s\n' "$server_ip" > "$work/server_ip.txt"
    fi
    printf '%s\n' "$INTERFACE_POLICY_MODE" > "$work/interface_policy_mode.txt"; effective_trusted_interfaces > "$work/input_trusted_interfaces.txt"
    rm -rf "${target}.old"; [[ -d "$target" ]] && mv "$target" "${target}.old"; mv "$work" "$target"; rm -rf "${target}.old"
    log "Runtime gerado em: $target"; print_runtime_summary "$target"
}

print_runtime_summary() {
    local dir="$1"
    printf '\n%-26s %s\n' "Arquivo de regras:" "$RULES_FILE"
    printf '%-26s %s\n' "Política interfaces:" "$INTERFACE_POLICY_MODE"
    printf '%-26s %s\n' "INPUT confiável:" "$(effective_trusted_interfaces)"
    printf '%-26s %s\n' "Serviços locais:" "${#LOCAL_INPUT_RULES[@]}"
    printf '%-26s %s\n' "Destinos d: finais:" "$(wc -l < "$dir/destinos.final")"
    printf '%-26s %s\n' "Destinos u: FQDN:" "$(wc -l < "$dir/u_dns.txt")"
    printf '%-26s %s\n' "Destinos u: IP atual:" "$(wc -l < "$dir/dynamic-destinos.final")"
    printf '%-26s %s\n' "Origens finais:" "$(wc -l < "$dir/origens.final")"
    printf '%-26s %s\n' "Portas TCP:" "$(wc -l < "$dir/ports.txt")"
    printf '%-26s %s\n' "MAC HTTPS:" "$(wc -l < "$dir/mac_https.txt")"
    printf '%-26s %s\n' "MAC total:" "$(wc -l < "$dir/mac_full.txt")"
    printf '\n'
}
