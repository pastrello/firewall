# ---------------------------------------------------------------------------
# DNS + otimização de redes
# ---------------------------------------------------------------------------
resolve_host_to_file() {
    local host="$1" outfile="$2"
    timeout "${DNS_TIMEOUT}s" getent ahostsv4 "$host" 2>/dev/null \
        | awk '{print $1}' \
        | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/' \
        | LC_ALL=C sort -u > "$outfile" || true
}

resolve_dns_list() {
    local hosts_file="$1" result_file="$2" cache_out="$3" label="$4"
    local workdir="$RUNTIME_DIR/dns-${label}.$$"
    local now_epoch host idx=0 batch=0 pids="" pid file
    now_epoch=$(date +%s)
    mkdir -p "$workdir"
    : > "$result_file"
    : > "$cache_out"

    [[ -s "$hosts_file" ]] || { rm -rf "$workdir"; return 0; }

    log "Resolvendo DNS (${label}): $(wc -l < "$hosts_file") nome(s), até ${DNS_JOBS} em paralelo..."

    while IFS= read -r host; do
        ((idx+=1))
        file="$workdir/$idx.ip"
        resolve_host_to_file "$host" "$file" &
        pid=$!
        printf '%s\t%s\t%s\n' "$idx" "$pid" "$host" >> "$workdir/jobs.tsv"
        pids="$pids $pid"
        ((batch+=1))
        if (( batch >= DNS_JOBS )); then
            for pid in $pids; do wait "$pid" || true; done
            pids=""
            batch=0
        fi
    done < "$hosts_file"
    for pid in $pids; do wait "$pid" || true; done

    local failures=0 cache_used=0 resolved=0 ip age
    while IFS=$'\t' read -r idx pid host; do
        file="$workdir/$idx.ip"
        if [[ -s "$file" ]]; then
            while IFS= read -r ip; do
                valid_ipv4_cidr "$ip" || continue
                printf '%s\n' "$ip" >> "$result_file"
                printf '%s\t%s\t%s\n' "$now_epoch" "$host" "$ip" >> "$cache_out"
                ((resolved+=1))
            done < "$file"
        else
            local cached=0
            if [[ -r "$DNS_CACHE" ]]; then
                while IFS=$'\t' read -r epoch chost cip; do
                    [[ "$chost" == "$host" ]] || continue
                    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
                    age=$((now_epoch - epoch))
                    (( age >= 0 && age <= DNS_CACHE_MAX_AGE )) || continue
                    valid_ipv4_cidr "$cip" || continue
                    printf '%s\n' "$cip" >> "$result_file"
                    printf '%s\t%s\t%s\n' "$epoch" "$host" "$cip" >> "$cache_out"
                    cached=1
                    ((cache_used+=1))
                done < "$DNS_CACHE"
            fi
            if (( cached == 0 )); then
                warn "DNS sem resposta/cache válido para: $host"
                ((failures+=1))
            else
                warn "DNS falhou para $host; usando cache anterior."
            fi
        fi
    done < "$workdir/jobs.tsv"

    LC_ALL=C sort -u -o "$result_file" "$result_file"
    rm -rf "$workdir"

    log "DNS ${label}: ${resolved} endereço(s) resolvido(s), ${cache_used} de cache, ${failures} nome(s) sem resultado."
    if (( failures > 0 && DNS_STRICT == 1 )); then
        return 1
    fi
    return 0
}

optimize_network_file() {
    local infile="$1" outfile="$2" label="$3"
    local before after
    before=$(wc -l < "$infile")

    if [[ "$OPTIMIZE_NETWORKS" == "1" ]] && command -v python3 >/dev/null 2>&1; then
        python3 - "$infile" "$outfile" <<'PY'
import ipaddress, sys
src, dst = sys.argv[1], sys.argv[2]
nets = []
with open(src, 'r') as f:
    for line in f:
        value = line.strip()
        if not value:
            continue
        nets.append(ipaddress.ip_network(value, strict=False))
collapsed = ipaddress.collapse_addresses(set(nets))
with open(dst, 'w') as f:
    for net in collapsed:
        f.write(str(net) + "\n")
PY
    else
        LC_ALL=C sort -u "$infile" > "$outfile"
    fi

    after=$(wc -l < "$outfile")
    log "Otimização ${label}: ${before} entrada(s) -> ${after} rede(s)/host(s)."
}

build_sets_files() {
    local parsedir="$1"
    local dns_dst="$parsedir/d_dns.resolved"
    local dns_src="$parsedir/s_dns.resolved"
    local cache_dst="$parsedir/cache-d.tsv"
    local cache_src="$parsedir/cache-s.tsv"
    local combined_dst="$parsedir/d_combined.txt"
    local combined_src="$parsedir/s_combined.txt"

    resolve_dns_list "$parsedir/d_dns.txt" "$dns_dst" "$cache_dst" "destinos" || return 1
    resolve_dns_list "$parsedir/s_dns.txt" "$dns_src" "$cache_src" "origens" || return 1

    cat "$parsedir/d_numeric.txt" "$dns_dst" | LC_ALL=C sort -u > "$combined_dst"
    cat "$parsedir/s_numeric.txt" "$dns_src" | LC_ALL=C sort -u > "$combined_src"

    optimize_network_file "$combined_dst" "$parsedir/destinos.final" "destinos"
    optimize_network_file "$combined_src" "$parsedir/origens.final" "origens"

    cat "$cache_dst" "$cache_src" | LC_ALL=C sort -u > "$parsedir/dns-cache.new"
}
