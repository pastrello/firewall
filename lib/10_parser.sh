# ---------------------------------------------------------------------------
# Parser do regras_firewall.conf
# ---------------------------------------------------------------------------
parse_config() {
    local outdir="$1"
    local invalid="$outdir/invalid.txt"
    local parsed="$outdir/parsed.tsv"

    [[ -r "$RULES_FILE" ]] || die "Arquivo de regras não encontrado ou sem leitura: $RULES_FILE"
    mkdir -p "$outdir"
    : > "$invalid"; : > "$parsed"

    awk -v invalid="$invalid" '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            t=$1; v=$2;
            if (t=="d:" || t=="u:" || t=="s:" || t=="p:" || t=="m:" || t=="c:") {
                if (v=="") print NR "\tvalor ausente\t" $0 >> invalid;
                else print t "\t" v;
            } else print NR "\ttipo desconhecido\t" $0 >> invalid;
        }
    ' "$RULES_FILE" > "$parsed"

    : > "$outdir/d_numeric.raw"; : > "$outdir/d_dns.raw"; : > "$outdir/u_dns.raw"
    : > "$outdir/s_numeric.raw"; : > "$outdir/s_dns.raw"; : > "$outdir/ports.raw"
    : > "$outdir/mac_https.raw"; : > "$outdir/mac_full.raw"

    while IFS=$'\t' read -r type value; do
        case "$type" in
            d:)
                if valid_ipv4_cidr "$value"; then printf '%s\n' "$value" >> "$outdir/d_numeric.raw"
                elif valid_hostname "$value"; then printf '%s\n' "${value,,}" >> "$outdir/d_dns.raw"
                else printf '%s\t%s\t%s\n' "?" "destino inválido" "$value" >> "$invalid"; fi ;;
            u:)
                if valid_hostname "$value" && ! valid_ipv4_cidr "$value"; then printf '%s\n' "${value,,}" >> "$outdir/u_dns.raw"
                else printf '%s\t%s\t%s\n' "?" "destino dinâmico u: deve ser FQDN válido" "$value" >> "$invalid"; fi ;;
            s:)
                if valid_ipv4_cidr "$value"; then printf '%s\n' "$value" >> "$outdir/s_numeric.raw"
                elif valid_hostname "$value"; then printf '%s\n' "${value,,}" >> "$outdir/s_dns.raw"
                else printf '%s\t%s\t%s\n' "?" "origem inválida" "$value" >> "$invalid"; fi ;;
            p:)
                if valid_port "$value"; then printf '%s\n' "$value" >> "$outdir/ports.raw"
                else printf '%s\t%s\t%s\n' "?" "porta inválida" "$value" >> "$invalid"; fi ;;
            m:)
                if valid_mac "$value"; then printf '%s\n' "${value^^}" >> "$outdir/mac_https.raw"
                else printf '%s\t%s\t%s\n' "?" "MAC m: inválido" "$value" >> "$invalid"; fi ;;
            c:)
                if valid_mac "$value"; then printf '%s\n' "${value^^}" >> "$outdir/mac_full.raw"
                else printf '%s\t%s\t%s\n' "?" "MAC c: inválido" "$value" >> "$invalid"; fi ;;
        esac
    done < "$parsed"

    local f
    for f in d_numeric d_dns u_dns s_numeric s_dns ports mac_https mac_full; do
        LC_ALL=C sort -u "$outdir/${f}.raw" > "$outdir/${f}.txt"
    done

    if [[ -s "$invalid" ]]; then
        warn "Foram encontradas linhas inválidas no arquivo de configuração:"
        sed -n '1,30p' "$invalid" >&2
        local n; n=$(wc -l < "$invalid")
        (( n <= 30 )) || warn "... e mais $((n-30)) ocorrência(s)."
        return 1
    fi
}
