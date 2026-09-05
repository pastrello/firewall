# ---------------------------------------------------------------------------
# Política de interfaces e serviços locais (v2.2)
# ---------------------------------------------------------------------------

valid_port_spec() {
    local value="$1" first last
    if [[ "$value" =~ ^[0-9]{1,5}$ ]]; then
        valid_port "$value"
        return
    fi
    if [[ "$value" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
        first="${BASH_REMATCH[1]}"
        last="${BASH_REMATCH[2]}"
        valid_port "$first" && valid_port "$last" && (( 10#$first <= 10#$last ))
        return
    fi
    return 1
}

word_in_list() {
    local needle="$1" list="${2:-}" item
    for item in $list; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

unique_words() {
    local list="${1:-}"
    printf '%s\n' $list 2>/dev/null | awk 'NF && !seen[$0]++ {out=out sep $0; sep=" "} END{print out}'
}

interface_role() {
    local iface="$1"
    if word_in_list "$iface" "$WAN_INTERFACES"; then
        printf 'WAN\n'
    elif word_in_list "$iface" "$LAN_INTERFACES"; then
        printf 'LAN\n'
    elif word_in_list "$iface" "$VPN_INTERFACES"; then
        printf 'VPN\n'
    else
        printf 'UNCLASSIFIED\n'
    fi
}

effective_trusted_interfaces() {
    if [[ "$INTERFACE_POLICY_MODE" == "roles" ]]; then
        unique_words "$LAN_INTERFACES $VPN_INTERFACES"
    else
        unique_words "$INPUT_TRUSTED_INTERFACES"
    fi
}

expand_iface_selector() {
    local selector="$1"
    case "$selector" in
        @wan) unique_words "$WAN_INTERFACES" ;;
        @lan) unique_words "$LAN_INTERFACES" ;;
        @vpn) unique_words "$VPN_INTERFACES" ;;
        *) printf '%s\n' "$selector" ;;
    esac
}

check_interface_exists() {
    local iface="$1" context="${2:-configuração}"
    [[ "$iface" == @* ]] && return 0
    [[ -d "/sys/class/net/$iface" ]] && return 0
    case "$INTERFACE_MISSING_POLICY" in
        ignore) return 0 ;;
        warn) warn "Interface '$iface' ($context) não existe atualmente no sistema."; return 0 ;;
        error) warn "Interface '$iface' ($context) não existe atualmente no sistema."; return 1 ;;
        *) warn "INTERFACE_MISSING_POLICY inválido: $INTERFACE_MISSING_POLICY"; return 1 ;;
    esac
}

lists_overlap() {
    local left="${1:-}" right="${2:-}" item
    for item in $left; do
        word_in_list "$item" "$right" && { printf '%s\n' "$item"; return 0; }
    done
    return 1
}

decode_local_input_rule() {
    local rule="$1" token key value
    local name="" iface="" proto="" port="" src="any" enabled="1"

    for token in $rule; do
        [[ "$token" == *=* ]] || { warn "Regra LOCAL_INPUT_RULES inválida (esperado chave=valor): $rule"; return 1; }
        key="${token%%=*}"
        value="${token#*=}"
        case "$key" in
            name) name="$value" ;;
            iface) iface="$value" ;;
            proto) proto="$value" ;;
            port) port="$value" ;;
            src) src="$value" ;;
            enabled) enabled="$value" ;;
            *) warn "Chave desconhecida '$key' em LOCAL_INPUT_RULES: $rule"; return 1 ;;
        esac
    done

    [[ -n "$name" ]] || name="local-service"
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || { warn "Nome inválido em LOCAL_INPUT_RULES: $name"; return 1; }
    [[ -n "$iface" ]] || { warn "LOCAL_INPUT_RULES sem iface: $rule"; return 1; }
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { warn "Protocolo inválido em LOCAL_INPUT_RULES '$name': $proto"; return 1; }
    valid_port_spec "$port" || { warn "Porta inválida em LOCAL_INPUT_RULES '$name': $port"; return 1; }
    [[ "$enabled" == "0" || "$enabled" == "1" ]] || { warn "enabled deve ser 0 ou 1 em LOCAL_INPUT_RULES '$name'"; return 1; }
    if [[ "$src" != "any" ]]; then
        valid_ipv4_cidr "$src" || { warn "Origem inválida em LOCAL_INPUT_RULES '$name': $src (v2.2 aceita any ou IPv4/CIDR)"; return 1; }
    fi

    printf '%s|%s|%s|%s|%s|%s\n' "$name" "$iface" "$proto" "$port" "$src" "$enabled"
}

validate_local_input_rules() {
    local rc=0 rule parsed name selector proto port src enabled iface expanded
    local -a rules=("${LOCAL_INPUT_RULES[@]-}")

    for rule in "${rules[@]}"; do
        [[ -n "$rule" ]] || continue
        parsed=$(decode_local_input_rule "$rule") || { rc=1; continue; }
        IFS='|' read -r name selector proto port src enabled <<< "$parsed"
        [[ "$enabled" == "1" ]] || continue
        expanded=$(expand_iface_selector "$selector")
        [[ -n "$expanded" ]] || { warn "Regra local '$name' usa '$selector', mas o papel não possui interfaces."; rc=1; continue; }
        for iface in $expanded; do
            check_interface_exists "$iface" "LOCAL_INPUT_RULES:$name" || rc=1
            if [[ "$INTERFACE_POLICY_MODE" == "roles" ]] && word_in_list "$iface" "$WAN_INTERFACES" && [[ "$src" == "any" ]]; then
                warn "Regra local '$name' expõe ${proto}/${port} na WAN '$iface' para src=any. A exposição é explícita, mas deve ser revisada."
            fi
        done
    done
    return "$rc"
}

validate_trusted_sources() {
    local src rc=0
    for src in $INPUT_TRUSTED_SOURCES; do
        valid_ipv4_cidr "$src" || { warn "Origem inválida em INPUT_TRUSTED_SOURCES: $src"; rc=1; }
    done
    return "$rc"
}

emit_trusted_source_rules() {
    local outfile="$1" src iface trusted
    [[ -n "${INPUT_TRUSTED_SOURCES:-}" ]] || return 0
    printf '\n# Redes de origem historicamente confiáveis para INPUT\n' >> "$outfile"
    if [[ "$INTERFACE_POLICY_MODE" == "roles" ]]; then
        trusted=$(effective_trusted_interfaces)
        for iface in $trusted; do
            for src in $INPUT_TRUSTED_SOURCES; do
                printf -- '-A INPUT -i %s -s %s -j ACCEPT\n' "$iface" "$src" >> "$outfile"
            done
        done
    else
        for src in $INPUT_TRUSTED_SOURCES; do
            printf -- '-A INPUT -s %s -j ACCEPT\n' "$src" >> "$outfile"
        done
    fi
}

validate_interface_policy() {
    local rc=0 iface overlap

    case "$INTERFACE_POLICY_MODE" in
        compat|roles) ;;
        *) warn "INTERFACE_POLICY_MODE inválido: $INTERFACE_POLICY_MODE (use compat ou roles)"; return 1 ;;
    esac
    case "$INTERFACE_MISSING_POLICY" in
        ignore|warn|error) ;;
        *) warn "INTERFACE_MISSING_POLICY inválido: $INTERFACE_MISSING_POLICY (use ignore, warn ou error)"; return 1 ;;
    esac

    if [[ "$INTERFACE_POLICY_MODE" == "compat" ]]; then
        warn "INTERFACE_POLICY_MODE=compat: preservando INPUT_TRUSTED_INTERFACES do legado. Use roles após classificar WAN/LAN/VPN."
        for iface in $WAN_INTERFACES; do
            if word_in_list "$iface" "$INPUT_TRUSTED_INTERFACES"; then
                warn "Interface WAN '$iface' também está em INPUT_TRUSTED_INTERFACES. Em modo compat ela recebe ACCEPT genérico."
            fi
        done
    else
        overlap=$(lists_overlap "$WAN_INTERFACES" "$LAN_INTERFACES" || true)
        [[ -z "$overlap" ]] || { warn "Interface '$overlap' classificada simultaneamente como WAN e LAN."; rc=1; }
        overlap=$(lists_overlap "$WAN_INTERFACES" "$VPN_INTERFACES" || true)
        [[ -z "$overlap" ]] || { warn "Interface '$overlap' classificada simultaneamente como WAN e VPN."; rc=1; }
        overlap=$(lists_overlap "$LAN_INTERFACES" "$VPN_INTERFACES" || true)
        [[ -z "$overlap" ]] || { warn "Interface '$overlap' classificada simultaneamente como LAN e VPN."; rc=1; }

        for iface in $WAN_INTERFACES; do
            if word_in_list "$iface" "$INPUT_TRUSTED_INTERFACES"; then
                warn "WAN '$iface' não pode permanecer em INPUT_TRUSTED_INTERFACES quando INTERFACE_POLICY_MODE=roles."
                rc=1
            fi
        done
        [[ -n "${WAN_INTERFACES// /}" ]] || warn "Nenhuma WAN foi classificada. Outbound continua possível, mas inbound exigirá WAN explícita."
        [[ -n "${LAN_INTERFACES// /}${VPN_INTERFACES// /}" ]] || warn "Nenhuma interface LAN/VPN foi classificada como confiável para INPUT."
    fi

    for iface in $WAN_INTERFACES; do check_interface_exists "$iface" "WAN_INTERFACES" || rc=1; done
    for iface in $LAN_INTERFACES; do check_interface_exists "$iface" "LAN_INTERFACES" || rc=1; done
    for iface in $VPN_INTERFACES; do check_interface_exists "$iface" "VPN_INTERFACES" || rc=1; done
    if [[ "$INTERFACE_POLICY_MODE" == "compat" ]]; then
        for iface in $INPUT_TRUSTED_INTERFACES; do check_interface_exists "$iface" "INPUT_TRUSTED_INTERFACES" || rc=1; done
    fi

    validate_trusted_sources || rc=1
    validate_local_input_rules || rc=1
    return "$rc"
}

emit_trusted_input_rules() {
    local outfile="$1" iface trusted
    trusted=$(effective_trusted_interfaces)
    if [[ "$INTERFACE_POLICY_MODE" == "roles" ]]; then
        printf '\n# Interfaces confiáveis por papel (LAN/VPN). WAN nunca entra aqui.\n' >> "$outfile"
    else
        printf '\n# Compatibilidade: interfaces integralmente confiáveis do legado.\n' >> "$outfile"
    fi
    for iface in $trusted; do
        printf -- '-A INPUT -i %s -j ACCEPT\n' "$iface" >> "$outfile"
    done
}

emit_local_input_rules() {
    local outfile="$1" rule parsed name selector proto port src enabled iface expanded
    local -a rules=("${LOCAL_INPUT_RULES[@]-}")
    printf '\n# Serviços locais declarativos\n' >> "$outfile"
    for rule in "${rules[@]}"; do
        [[ -n "$rule" ]] || continue
        parsed=$(decode_local_input_rule "$rule") || return 1
        IFS='|' read -r name selector proto port src enabled <<< "$parsed"
        [[ "$enabled" == "1" ]] || continue
        expanded=$(expand_iface_selector "$selector")
        for iface in $expanded; do
            printf '# local-service: %s\n' "$name" >> "$outfile"
            if [[ "$src" == "any" ]]; then
                printf -- '-A INPUT -m conntrack --ctstate NEW -p %s -i %s --dport %s -j ACCEPT\n' "$proto" "$iface" "$port" >> "$outfile"
            else
                printf -- '-A INPUT -m conntrack --ctstate NEW -p %s -i %s --dport %s -s %s -j ACCEPT\n' "$proto" "$iface" "$port" "$src" >> "$outfile"
            fi
        done
    done
}

print_interface_diagnostics() {
    local iface value trusted
    printf '\nPolítica de interfaces:\n'
    printf '  modo             : %s\n' "$INTERFACE_POLICY_MODE"
    printf '  WAN              : %s\n' "${WAN_INTERFACES:-<não definida>}"
    printf '  LAN              : %s\n' "${LAN_INTERFACES:-<não definida>}"
    printf '  VPN              : %s\n' "${VPN_INTERFACES:-<não definida>}"
    trusted=$(effective_trusted_interfaces)
    printf '  INPUT confiável  : %s\n' "${trusted:-<nenhuma>}"
    printf '  interface ausente: %s\n' "$INTERFACE_MISSING_POLICY"

    printf '\nEstado das interfaces declaradas:\n'
    for iface in $(unique_words "$WAN_INTERFACES $LAN_INTERFACES $VPN_INTERFACES $INPUT_TRUSTED_INTERFACES"); do
        [[ -n "$iface" ]] || continue
        if [[ -d "/sys/class/net/$iface" ]]; then
            printf '  %-12s %-12s presente\n' "$iface" "$(interface_role "$iface")"
        else
            printf '  %-12s %-12s AUSENTE\n' "$iface" "$(interface_role "$iface")"
        fi
    done

    printf '\nrp_filter por interface classificada:\n'
    for iface in $(unique_words "$WAN_INTERFACES $LAN_INTERFACES $VPN_INTERFACES"); do
        [[ -n "$iface" ]] || continue
        value=$(cat "/proc/sys/net/ipv4/conf/$iface/rp_filter" 2>/dev/null || echo '?')
        printf '  %-12s role=%-4s rp_filter=%s\n' "$iface" "$(interface_role "$iface")" "$value"
    done

    value=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')
    [[ "$value" == "1" ]] || warn "net.ipv4.ip_forward=$value; roteamento/FORWARD IPv4 normalmente requer valor 1."

    if [[ $(wc -w <<< "$WAN_INTERFACES") -gt 1 ]]; then
        for iface in $WAN_INTERFACES; do
            value=$(cat "/proc/sys/net/ipv4/conf/$iface/rp_filter" 2>/dev/null || echo '?')
            [[ "$value" != "1" ]] || warn "WAN '$iface' usa rp_filter=1 (strict). Em multi-WAN/roteamento assimétrico isso merece revisão; modo 2 (loose) é frequentemente mais apropriado."
        done
    fi
}
