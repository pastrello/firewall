# ---------------------------------------------------------------------------
# Geração do ruleset iptables-restore
# ---------------------------------------------------------------------------
emit_filter_rules() {
    local parsedir="$1" outfile="$2"
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

# Tudo que chega ao próprio firewall e não foi autorizado acima é rejeitado.
-A INPUT -j REJECT --reject-with icmp-host-prohibited

# FORWARD stateful: respostas de conexões já autorizadas não precisam repetir
# a política de saída e INVALID é descartado cedo.
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -m conntrack --ctstate INVALID -j DROP

# MACs com acesso total (c:) - equivalentes ao antigo -I FORWARD
EOF_FILTER

    while IFS= read -r mac; do
        [[ -n "$mac" ]] || continue
        printf -- '-A FORWARD -m mac --mac-source %s -j ACCEPT\n' "$mac" >> "$outfile"
    done < "$parsedir/mac_full.txt"

    if [[ "$WG_FORWARD_ENABLE" == "1" ]]; then
        local wg_port
        printf '\n# VPN WireGuard - portas de destino\n' >> "$outfile"
        for wg_port in $WG_FORWARD_TCP_PORTS; do
            [[ -n "$wg_port" ]] || continue
            printf -- '-A FORWARD -d %s -p tcp --dport %s -j ACCEPT\n' "$WG_FORWARD_DST" "$wg_port" >> "$outfile"
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

# Redes internas liberadas
-A FORWARD -s 172.16.0.0/16 -j ACCEPT
-A FORWARD -d 172.16.0.0/16 -j ACCEPT
-A FORWARD -s 10.80.0.0/16 -j ACCEPT
-A FORWARD -d 10.80.0.0/16 -j ACCEPT

# Portas TCP globais (p:)
EOF_FILTER

    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        printf -- '-A FORWARD -p tcp --dport %s -j ACCEPT\n' "$port" >> "$outfile"
    done < "$parsedir/ports.txt"

    printf '\n# MACs liberados apenas para HTTPS (m:)\n' >> "$outfile"
    while IFS= read -r mac; do
        [[ -n "$mac" ]] || continue
        printf -- '-A FORWARD -m mac --mac-source %s -p tcp --dport 443 -j ACCEPT\n' "$mac" >> "$outfile"
    done < "$parsedir/mac_https.txt"

    cat >> "$outfile" <<EOF_FILTER

# Listas grandes: uma regra por ipset
-A FORWARD -m set --match-set ${SET_DST} dst -j ACCEPT
-A FORWARD -m set --match-set ${SET_SRC} src -j ACCEPT

# Compatibilidade explícita com o legado: 192.168/16 era implicitamente
# permitido porque a regra final usava ! -d 192.168.0.0/16.
EOF_FILTER

    if [[ "$ALLOW_RFC1918_192_DST" == "1" ]]; then
        printf -- '-A FORWARD -d 192.168.0.0/16 -j ACCEPT\n' >> "$outfile"
    fi

    cat >> "$outfile" <<'EOF_FILTER'

# Política final explícita. Tudo que não foi autorizado acima é bloqueado.
-A FORWARD -j DROP
COMMIT
EOF_FILTER
}

emit_nat_rules() {
    local server_ip="$1" outfile="$2" net24
    net24=$(server_net24 "$server_ip")

    cat >> "$outfile" <<EOF_NAT
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# Não mascara tráfego 192.168/16 -> 10.80.0/24
-A POSTROUTING -s 192.168.0.0/16 -d 10.80.0.0/24 -j RETURN

# NAT da rede /24 do servidor para fora de 192.168/16
-A POSTROUTING -s ${net24} ! -d 192.168.0.0/16 -j MASQUERADE
COMMIT
EOF_NAT
}

build_runtime() {
    local server_ip="${1:-${SERVER_IP:-}}"
    local work="$RUNTIME_DIR/build.$$"
    local target="$RUNTIME_DIR/current"
    mkdir -p "$work"

    validate_interface_policy || { rm -rf "$work"; die "Política de interfaces/serviços locais inválida; nada foi aplicado."; }
    parse_config "$work" || { rm -rf "$work"; die "Configuração inválida; nada foi aplicado."; }
    build_sets_files "$work" || { rm -rf "$work"; die "Falha ao preparar destinos/origens."; }

    if [[ -n "$server_ip" ]]; then
        valid_ipv4_cidr "$server_ip" || { rm -rf "$work"; die "SERVER_IP inválido: $server_ip"; }
        [[ "$server_ip" != */* ]] || { rm -rf "$work"; die "SERVER_IP deve ser informado sem CIDR."; }
        emit_filter_rules "$work" "$work/iptables.rules"
        emit_nat_rules "$server_ip" "$work/iptables.rules"
        printf '%s\n' "$server_ip" > "$work/server_ip.txt"
    fi
    printf '%s\n' "$INTERFACE_POLICY_MODE" > "$work/interface_policy_mode.txt"
    effective_trusted_interfaces > "$work/input_trusted_interfaces.txt"

    rm -rf "${target}.old"
    [[ -d "$target" ]] && mv "$target" "${target}.old"
    mv "$work" "$target"
    rm -rf "${target}.old"

    log "Runtime gerado em: $target"
    print_runtime_summary "$target"
}

print_runtime_summary() {
    local dir="$1"
    printf '\n%-24s %s\n' "Arquivo de regras:" "$RULES_FILE"
    printf '%-24s %s\n' "Política interfaces:" "$INTERFACE_POLICY_MODE"
    printf '%-24s %s\n' "INPUT confiável:" "$(effective_trusted_interfaces)"
    printf '%-24s %s\n' "Serviços locais:" "${#LOCAL_INPUT_RULES[@]}"
    printf '%-24s %s\n' "Destinos finais:" "$(wc -l < "$dir/destinos.final")"
    printf '%-24s %s\n' "Origens finais:" "$(wc -l < "$dir/origens.final")"
    printf '%-24s %s\n' "Portas TCP:" "$(wc -l < "$dir/ports.txt")"
    printf '%-24s %s\n' "MAC HTTPS:" "$(wc -l < "$dir/mac_https.txt")"
    printf '%-24s %s\n' "MAC total:" "$(wc -l < "$dir/mac_full.txt")"
    printf '%-24s %s\n' "FQDN destinos:" "$(wc -l < "$dir/d_dns.txt")"
    printf '%-24s %s\n' "FQDN origens:" "$(wc -l < "$dir/s_dns.txt")"
    printf '\n'
}
