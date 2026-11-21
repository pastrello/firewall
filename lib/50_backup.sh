# ---------------------------------------------------------------------------
# Backup / rollback - neutro em relação ao backend (v2.4)
# ---------------------------------------------------------------------------

create_backup() {
    local ts dir
    ts=$(date '+%Y%m%d_%H%M%S')
    dir="$BACKUP_DIR/$ts"
    mkdir -p "$dir"

    backend_backup_rules "$dir"
    backend_set_save_backup "$SET_DST" "$dir/${SET_DST}.entries"
    backend_set_save_backup "$SET_SRC" "$dir/${SET_SRC}.entries"
    backend_set_save_backup "$SET_DYN_DST" "$dir/${SET_DYN_DST}.entries"

    [[ -r "$DNS_CACHE" ]] && cp -a "$DNS_CACHE" "$dir/dns-cache.tsv" || true
    [[ -d "$DYNAMIC_STATE_DIR" ]] && cp -a "$DYNAMIC_STATE_DIR" "$dir/dynamic" || true
    [[ -d "$RUNTIME_DIR/current" ]] && cp -a "$RUNTIME_DIR/current" "$dir/runtime" || true

    printf '%s\n' "$BACKEND" > "$dir/backend"
    printf '%s\n' "$VERSION" > "$dir/version"
    printf '%s\n' "$(now)" > "$dir/created_at"

    ACTIVE_BACKUP="$dir"
    log "Backup criado: $dir (backend=$BACKEND)"
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
    return 0
}

restore_set_from_backup() {
    local name="${1:?nome do set ausente}"
    local dir="${2:?diretório de backup ausente}"
    local entries="$dir/${name}.entries"
    local existed_file="${entries}.existed"

    [[ -f "$entries" ]] || return 0
    backend_set_load_atomic "$name" "$entries"
    [[ -f "$existed_file" && "$(cat "$existed_file")" == "0" ]] && return 2
    return 0
}

backup_backend_name() {
    local dir="${1:?diretório de backup ausente}"
    if [[ -r "$dir/backend" ]]; then
        cat "$dir/backend"
    elif [[ -s "$dir/iptables.save" ]]; then
        # Backups 2.0-2.3 não tinham metadata de backend.
        printf 'iptables\n'
    else
        printf 'unknown\n'
    fi
}

rollback_dir() {
    local dir="${1:?diretório de backup ausente}"
    local destroy_dst=0 destroy_src=0 destroy_dyn=0 rc backup_backend

    [[ -d "$dir" ]] || die "Backup não encontrado: $dir"
    backup_backend=$(backup_backend_name "$dir")
    [[ "$backup_backend" == "$BACKEND" ]] || die "Backup usa backend '$backup_backend', mas o backend configurado é '$BACKEND'."

    log "Restaurando backup: $dir (backend=$backup_backend)"

    if restore_set_from_backup "$SET_DST" "$dir"; then :; else
        rc=$?; (( rc == 2 )) && destroy_dst=1 || return "$rc"
    fi
    if restore_set_from_backup "$SET_SRC" "$dir"; then :; else
        rc=$?; (( rc == 2 )) && destroy_src=1 || return "$rc"
    fi
    if restore_set_from_backup "$SET_DYN_DST" "$dir"; then :; else
        rc=$?; (( rc == 2 )) && destroy_dyn=1 || return "$rc"
    fi

    backend_restore_rules "$dir"

    (( destroy_dst == 1 )) && backend_set_destroy "$SET_DST"
    (( destroy_src == 1 )) && backend_set_destroy "$SET_SRC"
    (( destroy_dyn == 1 )) && backend_set_destroy "$SET_DYN_DST"

    [[ -r "$dir/dns-cache.tsv" ]] && cp -a "$dir/dns-cache.tsv" "$DNS_CACHE" || true
    if [[ -d "$dir/dynamic" ]]; then
        rm -rf "$DYNAMIC_STATE_DIR"
        cp -a "$dir/dynamic" "$DYNAMIC_STATE_DIR"
    fi

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

    release_lock || true
    exit "$rc"
}
trap on_error ERR
