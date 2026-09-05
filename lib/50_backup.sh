# ---------------------------------------------------------------------------
# Backup / rollback
# ---------------------------------------------------------------------------
create_backup() {
    local ts dir
    ts=$(date '+%Y%m%d_%H%M%S')
    dir="$BACKUP_DIR/$ts"
    mkdir -p "$dir"

    "$IPTABLES_SAVE" > "$dir/iptables.save"
    save_set_entries "$SET_DST" "$dir/${SET_DST}.entries"
    save_set_entries "$SET_SRC" "$dir/${SET_SRC}.entries"
    [[ -r "$DNS_CACHE" ]] && cp -a "$DNS_CACHE" "$dir/dns-cache.tsv" || true
    [[ -d "$RUNTIME_DIR/current" ]] && cp -a "$RUNTIME_DIR/current" "$dir/runtime" || true
    printf '%s\n' "$VERSION" > "$dir/version"
    printf '%s\n' "$(now)" > "$dir/created_at"

    ACTIVE_BACKUP="$dir"
    log "Backup criado: $dir"
    prune_backups
}

prune_backups() {
    local count=0 d
    while IFS= read -r d; do
        ((count+=1))
        if (( count > BACKUP_KEEP )); then
            rm -rf -- "$d"
        fi
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | LC_ALL=C sort -r)
}

restore_set_from_backup() {
    local name="$1" dir="$2"
    local entries="$dir/${name}.entries"
    local existed_file="${entries}.existed"
    [[ -f "$entries" ]] || return 0
    load_ipset_atomic "$name" "$entries"
    if [[ -f "$existed_file" && "$(cat "$existed_file")" == "0" ]]; then
        return 2
    fi
    return 0
}

rollback_dir() {
    local dir="$1" destroy_dst=0 destroy_src=0
    [[ -d "$dir" ]] || die "Backup não encontrado: $dir"
    [[ -s "$dir/iptables.save" ]] || die "Backup sem iptables.save: $dir"

    log "Restaurando backup: $dir"
    local rc
    if restore_set_from_backup "$SET_DST" "$dir"; then
        :
    else
        rc=$?
        (( rc == 2 )) && destroy_dst=1 || return "$rc"
    fi
    if restore_set_from_backup "$SET_SRC" "$dir"; then
        :
    else
        rc=$?
        (( rc == 2 )) && destroy_src=1 || return "$rc"
    fi
    "$IPTABLES_RESTORE" < "$dir/iptables.save"

    (( destroy_dst == 1 )) && "$IPSET" destroy "$SET_DST" 2>/dev/null || true
    (( destroy_src == 1 )) && "$IPSET" destroy "$SET_SRC" 2>/dev/null || true
    [[ -r "$dir/dns-cache.tsv" ]] && cp -a "$dir/dns-cache.tsv" "$DNS_CACHE" || true

    log "Rollback concluído."
}

latest_backup() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' 2>/dev/null | LC_ALL=C sort -r | head -1
}

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-?}"
    local armed="$ROLLBACK_ARMED"
    trap - ERR
    ROLLBACK_ARMED=0
    warn "Falha na linha $line (rc=$rc)."
    if (( armed == 1 )) && [[ -n "$ACTIVE_BACKUP" && -d "$ACTIVE_BACKUP" ]]; then
        warn "Tentando rollback automático..."
        set +e
        rollback_dir "$ACTIVE_BACKUP"
        local rr=$?
        set -e
        if (( rr == 0 )); then
            warn "Rollback automático concluído."
        else
            warn "Rollback automático também falhou. Verifique imediatamente o console do servidor."
        fi
    fi
    exit "$rc"
}
trap on_error ERR
