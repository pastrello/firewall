# ---------------------------------------------------------------------------
# DNS dinâmico outbound (u:) - v2.3
# ---------------------------------------------------------------------------
DYNAMIC_NEXT_SLEEP="${DYNAMIC_DNS_MAX_INTERVAL:-300}"
DYNAMIC_SET_CHANGED=0

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

dynamic_validate_config() {
    local rc=0 v
    for v in DYNAMIC_DNS_MIN_INTERVAL DYNAMIC_DNS_MAX_INTERVAL DYNAMIC_DNS_TTL_DIVISOR DYNAMIC_DNS_GRACE DYNAMIC_DNS_STALE_MAX DYNAMIC_DNS_LOCK_TIMEOUT; do
        if ! is_uint "${!v:-}"; then warn "$v deve ser inteiro >= 0 (atual='${!v:-}')."; rc=1; fi
    done
    if (( rc == 0 )); then
        (( DYNAMIC_DNS_MIN_INTERVAL >= 1 )) || { warn "DYNAMIC_DNS_MIN_INTERVAL deve ser >= 1."; rc=1; }
        (( DYNAMIC_DNS_MAX_INTERVAL >= DYNAMIC_DNS_MIN_INTERVAL )) || { warn "DYNAMIC_DNS_MAX_INTERVAL deve ser >= DYNAMIC_DNS_MIN_INTERVAL."; rc=1; }
        (( DYNAMIC_DNS_TTL_DIVISOR >= 1 )) || { warn "DYNAMIC_DNS_TTL_DIVISOR deve ser >= 1."; rc=1; }
        (( DYNAMIC_DNS_LOCK_TIMEOUT >= 1 )) || { warn "DYNAMIC_DNS_LOCK_TIMEOUT deve ser >= 1."; rc=1; }
    fi
    case "$DYNAMIC_DNS_FAIL_POLICY" in keep|drop) ;; *) warn "DYNAMIC_DNS_FAIL_POLICY inválido: $DYNAMIC_DNS_FAIL_POLICY (use keep ou drop)."; rc=1 ;; esac
    case "$DYNAMIC_DNS_ENABLE" in 0|1) ;; *) warn "DYNAMIC_DNS_ENABLE deve ser 0 ou 1."; rc=1 ;; esac
    return "$rc"
}

dynamic_compute_sleep() {
    local ttl="${1:-$DYNAMIC_DNS_MAX_INTERVAL}" value
    is_uint "$ttl" || ttl="$DYNAMIC_DNS_MAX_INTERVAL"
    value=$(( ttl / DYNAMIC_DNS_TTL_DIVISOR ))
    (( value < DYNAMIC_DNS_MIN_INTERVAL )) && value="$DYNAMIC_DNS_MIN_INTERVAL"
    (( value > DYNAMIC_DNS_MAX_INTERVAL )) && value="$DYNAMIC_DNS_MAX_INTERVAL"
    printf '%s\n' "$value"
}

dynamic_query_host() {
    local host outfile raw
    host="${1:?host ausente}"
    outfile="${2:?outfile ausente}"
    raw="${outfile}.raw"
    : > "$outfile"; : > "$raw"
    if command -v dig >/dev/null 2>&1; then
        timeout "${DNS_TIMEOUT}s" dig +time="$DNS_TIMEOUT" +tries=1 +noall +answer A "$host" 2>/dev/null > "$raw" || true
        awk '$4=="A" && $2 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
                ip=$5; ttl=$2+0; if (!(ip in best) || ttl < best[ip]) best[ip]=ttl
             }
             END {for (ip in best) print best[ip] "\t" ip}' "$raw" | LC_ALL=C sort -t $'\t' -k2,2 > "$outfile"
    else
        timeout "${DNS_TIMEOUT}s" getent ahostsv4 "$host" 2>/dev/null \
            | awk -v ttl="$DYNAMIC_DNS_MAX_INTERVAL" '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print ttl "\t" $1}' \
            | LC_ALL=C sort -u > "$outfile" || true
    fi
    rm -f "$raw"
    [[ -s "$outfile" ]]
}

dynamic_csv_from_file() {
    local file="$1"
    awk 'BEGIN{s=""} NF {s=s (s?",":"") $0} END{print s}' "$file"
}

dynamic_build_candidate() {
    local hosts_file="$1" out_state="$2" out_set="$3" out_status="$4" out_meta="$5"
    local old_state="${DYNAMIC_STATE_FILE}" workdir now_epoch host query current_ips host_ttl ttl ip
    local last_seen old_ttl retire_at age kept grace_count failures=0 configured=0
    local overall_ttl="" status ips_csv detail stale_keep resolver

    dynamic_validate_config || return 1
    workdir=$(mktemp -d "${DYNAMIC_STATE_DIR}/build.XXXXXX")
    now_epoch=$(date +%s)
    : > "$out_state"; : > "$out_set"; : > "$out_status"
    [[ -r "$old_state" ]] || old_state="/dev/null"
    resolver="getent"; command -v dig >/dev/null 2>&1 && resolver="dig"

    if [[ "$DYNAMIC_DNS_ENABLE" != "1" ]]; then
        DYNAMIC_NEXT_SLEEP="$DYNAMIC_DNS_MAX_INTERVAL"
        cat > "$out_meta" <<EOF_META
last_cycle_epoch=$now_epoch
next_sleep=$DYNAMIC_NEXT_SLEEP
configured_hosts=0
set_entries=0
failures=0
resolver=$resolver
enabled=0
EOF_META
        rm -rf "$workdir"
        return 0
    fi

    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        ((configured+=1))
        query="$workdir/query.tsv"; current_ips="$workdir/current.ips"
        : > "$current_ips"; host_ttl="$DYNAMIC_DNS_MAX_INTERVAL"; grace_count=0

        if dynamic_query_host "$host" "$query"; then
            host_ttl=""
            while IFS=$'\t' read -r ttl ip; do
                is_uint "$ttl" || ttl="$DYNAMIC_DNS_MAX_INTERVAL"
                valid_ipv4_cidr "$ip" || continue
                printf '%s\n' "$ip" >> "$current_ips"
                printf '%s\t%s\t%s\t%s\t0\n' "$host" "$ip" "$now_epoch" "$ttl" >> "$out_state"
                if [[ -z "$host_ttl" ]] || (( ttl < host_ttl )); then host_ttl="$ttl"; fi
            done < "$query"
            LC_ALL=C sort -u -o "$current_ips" "$current_ips"
            [[ -n "$host_ttl" ]] || host_ttl="$DYNAMIC_DNS_MAX_INTERVAL"

            while IFS=$'\t' read -r old_host ip last_seen old_ttl retire_at; do
                [[ "$old_host" == "$host" ]] || continue
                valid_ipv4_cidr "$ip" || continue
                grep -Fxq "$ip" "$current_ips" && continue
                is_uint "$last_seen" || last_seen="$now_epoch"
                is_uint "$old_ttl" || old_ttl="$DYNAMIC_DNS_MAX_INTERVAL"
                is_uint "${retire_at:-}" || retire_at=0
                if (( retire_at == 0 )); then retire_at=$((now_epoch + DYNAMIC_DNS_GRACE)); fi
                if (( DYNAMIC_DNS_GRACE > 0 && retire_at > now_epoch )); then
                    printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$last_seen" "$old_ttl" "$retire_at" >> "$out_state"
                    ((grace_count+=1))
                fi
            done < "$old_state"

            ips_csv=$(dynamic_csv_from_file "$current_ips")
            status="RESOLVED"; detail="grace=${grace_count}"
        else
            ((failures+=1)); kept=0; stale_keep=0; : > "$current_ips"
            while IFS=$'\t' read -r old_host ip last_seen old_ttl retire_at; do
                [[ "$old_host" == "$host" ]] || continue
                valid_ipv4_cidr "$ip" || continue
                is_uint "$last_seen" || continue
                is_uint "$old_ttl" || old_ttl="$DYNAMIC_DNS_MAX_INTERVAL"
                is_uint "${retire_at:-}" || retire_at=0
                if (( retire_at > 0 )); then
                    (( retire_at > now_epoch )) || continue
                else
                    age=$((now_epoch - last_seen))
                    if (( age > DYNAMIC_DNS_STALE_MAX )); then
                        if [[ "$DYNAMIC_DNS_FAIL_POLICY" == "drop" ]]; then continue; fi
                        stale_keep=1
                    fi
                fi
                printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$ip" "$last_seen" "$old_ttl" "$retire_at" >> "$out_state"
                printf '%s\n' "$ip" >> "$current_ips"
                ((kept+=1))
            done < "$old_state"
            LC_ALL=C sort -u -o "$current_ips" "$current_ips"
            ips_csv=$(dynamic_csv_from_file "$current_ips")
            host_ttl="$DYNAMIC_DNS_MIN_INTERVAL"
            if (( kept == 0 )); then status="FAILED"; detail="sem-cache"
            elif (( stale_keep == 1 )); then status="STALE_KEEP"; detail="DNS falhou; cache excedeu stale_max e foi mantido por política keep"
            else status="CACHE"; detail="DNS falhou; mantendo último estado válido"; fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$status" "$host_ttl" "${ips_csv:--}" "$detail" >> "$out_status"
        if [[ -z "$overall_ttl" ]] || (( host_ttl < overall_ttl )); then overall_ttl="$host_ttl"; fi
    done < "$hosts_file"

    awk -F '\t' '!seen[$1 SUBSEP $2]++' "$out_state" > "$workdir/state.unique"
    mv -f "$workdir/state.unique" "$out_state"
    awk -F '\t' 'NF>=2 {print $2}' "$out_state" | LC_ALL=C sort -u > "$out_set"

    if (( configured == 0 )); then DYNAMIC_NEXT_SLEEP="$DYNAMIC_DNS_MAX_INTERVAL"
    else
        if (( failures > 0 )); then overall_ttl="$DYNAMIC_DNS_MIN_INTERVAL"; fi
        DYNAMIC_NEXT_SLEEP=$(dynamic_compute_sleep "$overall_ttl")
    fi

    cat > "$out_meta" <<EOF_META
last_cycle_epoch=$now_epoch
next_sleep=$DYNAMIC_NEXT_SLEEP
configured_hosts=$configured
set_entries=$(wc -l < "$out_set")
failures=$failures
resolver=$resolver
enabled=1
EOF_META
    rm -rf "$workdir"
}

prepare_dynamic_snapshot() {
    local parsedir hosts
    parsedir="${1:?parsedir ausente}"
    hosts="${parsedir}/u_dns.txt"
    [[ -f "$hosts" ]] || : > "$hosts"
    dynamic_build_candidate "$hosts" "$parsedir/dynamic-state.candidate" "$parsedir/dynamic-destinos.final" "$parsedir/dynamic-status.candidate" "$parsedir/dynamic-meta.candidate"
}

dynamic_commit_candidate() {
    local dir="$1"
    ensure_dirs
    [[ -f "$dir/dynamic-state.candidate" ]] && cp -f "$dir/dynamic-state.candidate" "${DYNAMIC_STATE_FILE}.new"
    [[ -f "$dir/dynamic-status.candidate" ]] && cp -f "$dir/dynamic-status.candidate" "${DYNAMIC_STATUS_FILE}.new"
    [[ -f "$dir/dynamic-meta.candidate" ]] && cp -f "$dir/dynamic-meta.candidate" "${DYNAMIC_META_FILE}.new"
    [[ -f "${DYNAMIC_STATE_FILE}.new" ]] && mv -f "${DYNAMIC_STATE_FILE}.new" "$DYNAMIC_STATE_FILE"
    [[ -f "${DYNAMIC_STATUS_FILE}.new" ]] && mv -f "${DYNAMIC_STATUS_FILE}.new" "$DYNAMIC_STATUS_FILE"
    [[ -f "${DYNAMIC_META_FILE}.new" ]] && mv -f "${DYNAMIC_META_FILE}.new" "$DYNAMIC_META_FILE"
}

dynamic_current_set_entries() {
    local outfile="${1:?outfile ausente}"
    backend_set_export_entries "$SET_DYN_DST" "$outfile"
}

dynamic_load_if_changed() {
    local entries="$1" current
    current=$(mktemp "${DYNAMIC_STATE_DIR}/current.XXXXXX")
    backend_set_ensure "$SET_DYN_DST"
    dynamic_current_set_entries "$current"
    if cmp -s "$current" "$entries"; then DYNAMIC_SET_CHANGED=0
    else
        backend_set_load_atomic "$SET_DYN_DST" "$entries" || { rm -f "$current"; return 1; }
        DYNAMIC_SET_CHANGED=1
    fi
    rm -f "$current"
}

dynamic_refresh_once() {
    local tmp parsed count
    ensure_dirs
    tmp=$(mktemp -d "${RUNTIME_DIR}/dynamic-refresh.XXXXXX"); parsed="$tmp/parsed"; mkdir -p "$parsed"
    if ! parse_config "$parsed"; then rm -rf "$tmp"; warn "DNS dinâmico: regras inválidas; mantendo ipset anterior."; return 1; fi
    if ! prepare_dynamic_snapshot "$parsed"; then rm -rf "$tmp"; warn "DNS dinâmico: falha ao preparar candidato; mantendo ipset anterior."; return 1; fi
    if ! dynamic_load_if_changed "$parsed/dynamic-destinos.final"; then rm -rf "$tmp"; warn "DNS dinâmico: falha ao atualizar ipset; mantendo estado persistente anterior."; return 1; fi
    dynamic_commit_candidate "$parsed"
    count=$(wc -l < "$parsed/dynamic-destinos.final")
    if (( DYNAMIC_SET_CHANGED == 1 )); then log "DNS dinâmico: $SET_DYN_DST alterado para $count endereço(s); próximo ciclo em ${DYNAMIC_NEXT_SLEEP}s."
    else log "DNS dinâmico: sem mudança de IP ($count endereço(s)); próximo ciclo em ${DYNAMIC_NEXT_SLEEP}s."; fi
    rm -rf "$tmp"
}

dynamic_require_daemon_tools() {
    require_root; backend_require_tools
    command -v dig >/dev/null 2>&1 || die "O serviço DNS dinâmico requer 'dig'. Instale o pacote bind-utils (dnf/yum install bind-utils)."
}

dynamic_service_unit_path() { printf '%s/%s\n' "$SYSTEMD_UNIT_DIR" "$DYNAMIC_DNS_SERVICE_NAME"; }

systemd_escape_value() {
    local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; printf '%s' "$value"
}

dynamic_write_service_unit() {
    local unit="$1" script_path="$2" e_base e_rules e_state e_settings e_script
    e_base=$(systemd_escape_value "$BASE_DIR"); e_rules=$(systemd_escape_value "$RULES_FILE")
    e_state=$(systemd_escape_value "$STATE_DIR"); e_settings=$(systemd_escape_value "$SETTINGS_FILE")
    e_script=$(systemd_escape_value "$script_path")
    cat > "$unit" <<EOF_UNIT
[Unit]
Description=Firewall Unidades Dynamic DNS Watcher
Documentation=https://github.com/pastrello/firewall
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Environment="FW_BASE_DIR=$e_base"
Environment="FW_RULES_FILE=$e_rules"
Environment="FW_STATE_DIR=$e_state"
Environment="FW_SETTINGS_FILE=$e_settings"
ExecStart="$e_script" dnswatch-daemon
Restart=always
RestartSec=5
TimeoutStopSec=20
Nice=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF_UNIT
}
