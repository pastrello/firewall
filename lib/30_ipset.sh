# ---------------------------------------------------------------------------
# ipset
# ---------------------------------------------------------------------------
ensure_active_set() {
    local name="$1"
    "$IPSET" create "$name" hash:net family inet hashsize "$SET_HASH_SIZE" maxelem "$SET_MAXELEM" -exist
}

load_ipset_atomic() {
    local name="$1" entries="$2"
    local tmp="${name}_NEW"
    local count
    count=$(wc -l < "$entries")
    (( count <= SET_MAXELEM )) || die "O conjunto $name possui $count elementos, acima de SET_MAXELEM=$SET_MAXELEM."

    ensure_active_set "$name"
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
    log "ipset $name atualizado atomicamente: $count elemento(s)."
}

save_set_entries() {
    local name="$1" outfile="$2"
    : > "$outfile"
    if "$IPSET" list "$name" >/dev/null 2>&1; then
        "$IPSET" save "$name" | awk -v n="$name" '$1=="add" && $2==n {print $3}' > "$outfile"
        printf '1\n' > "${outfile}.existed"
    else
        printf '0\n' > "${outfile}.existed"
    fi
}
