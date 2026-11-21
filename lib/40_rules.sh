# ---------------------------------------------------------------------------
# Geração de runtime - neutra em relação ao backend (v2.4)
# ---------------------------------------------------------------------------

build_runtime() {
    local server_ip="${1:-${SERVER_IP:-}}"
    local work="$RUNTIME_DIR/build.$$"
    local target="$RUNTIME_DIR/current"
    local rules_file

    mkdir -p "$work"

    validate_interface_policy || { rm -rf "$work"; die "Política de interfaces/serviços locais inválida; nada foi aplicado."; }
    dynamic_validate_config || { rm -rf "$work"; die "Configuração de DNS dinâmico inválida; nada foi aplicado."; }
    parse_config "$work" || { rm -rf "$work"; die "Configuração inválida; nada foi aplicado."; }
    build_sets_files "$work" || { rm -rf "$work"; die "Falha ao preparar destinos/origens."; }
    prepare_dynamic_snapshot "$work" || { rm -rf "$work"; die "Falha ao preparar destinos dinâmicos u:."; }

    if [[ -n "$server_ip" ]]; then
        valid_ipv4_cidr "$server_ip" || { rm -rf "$work"; die "SERVER_IP inválido: $server_ip"; }
        [[ "$server_ip" != */* ]] || { rm -rf "$work"; die "SERVER_IP deve ser informado sem CIDR."; }

        rules_file="$work/$(backend_rules_filename)"
        backend_generate_rules "$work" "$rules_file" "$server_ip"
        printf '%s\n' "$server_ip" > "$work/server_ip.txt"
    fi

    printf '%s\n' "$BACKEND" > "$work/backend.txt"
    printf '%s\n' "$INTERFACE_POLICY_MODE" > "$work/interface_policy_mode.txt"
    effective_trusted_interfaces > "$work/input_trusted_interfaces.txt"

    rm -rf "${target}.old"
    [[ -d "$target" ]] && mv "$target" "${target}.old"
    mv "$work" "$target"
    rm -rf "${target}.old"

    log "Runtime gerado em: $target (backend=$BACKEND)"
    print_runtime_summary "$target"
}

print_runtime_summary() {
    local dir="${1:?diretório runtime ausente}"
    printf '\n%-26s %s\n' "Arquivo de regras:" "$RULES_FILE"
    printf '%-26s %s\n' "Backend:" "$BACKEND"
    printf '%-26s %s\n' "Artefato backend:" "$(backend_rules_filename)"
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
