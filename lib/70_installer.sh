# ---------------------------------------------------------------------------
# Instalação / upgrade da aplicação - v2.4.3
# ---------------------------------------------------------------------------

APP_BACKUP_KEEP="${APP_BACKUP_KEEP:-5}"
APP_BACKUP_DIR_NAME="${APP_BACKUP_DIR_NAME:-.app-backups}"

install_managed_paths() {
    cat <<'EOF_PATHS'
firewall_unidades.sh
install.sh
lib
docs
examples
tests
firewall_unidades.conf.example
README.md
CHANGELOG.md
.editorconfig
EOF_PATHS
}

install_operational_paths() {
    cat <<'EOF_PATHS'
firewall_unidades_v2.conf
regras_firewall.conf
EOF_PATHS
}

install_normalize_target() {
    local target="${1:-$BASE_DIR}"
    readlink -m "$target"
}

install_detect_version() {
    local target="${1:?target ausente}"
    local script="$target/firewall_unidades.sh"
    if [[ -r "$script" ]]; then
        awk -F'"' '/^VERSION="[0-9]/{print $2; exit}' "$script"
    fi
}

install_backup_app() {
    local target="${1:?target ausente}"
    local ts backup path
    [[ -d "$target" ]] || return 0
    [[ -e "$target/firewall_unidades.sh" || -d "$target/lib" ]] || return 0

    ts=$(date '+%Y%m%d_%H%M%S')
    backup="$target/$APP_BACKUP_DIR_NAME/$ts"
    mkdir -p "$backup/app" "$backup/operational"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$target/$path" ]] && cp -a "$target/$path" "$backup/app/"
    done < <(install_managed_paths)

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$target/$path" ]] && cp -a "$target/$path" "$backup/operational/"
    done < <(install_operational_paths)

    printf '%s\n' "$(install_detect_version "$target")" > "$backup/version"
    printf '%s\n' "$(now)" > "$backup/created_at"
    printf '%s\n' "$target" > "$backup/target"

    INSTALL_APP_BACKUP="$backup"
    log "Backup da aplicação criado: $backup"
    install_prune_app_backups "$target"
}

install_prune_app_backups() {
    local target="${1:?target ausente}"
    local root="$target/$APP_BACKUP_DIR_NAME"
    local count=0 d
    [[ -d "$root" ]] || return 0
    while IFS= read -r d; do
        ((count+=1))
        if (( count > APP_BACKUP_KEEP )); then
            rm -rf -- "$d"
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | LC_ALL=C sort -r)
    return 0
}

install_restore_app_backup() {
    local target="${1:?target ausente}"
    local backup="${2:?backup ausente}"
    local path
    [[ -d "$backup/app" ]] || return 1

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rm -rf -- "$target/$path"
    done < <(install_managed_paths)

    if compgen -G "$backup/app/*" >/dev/null; then
        cp -a "$backup/app/." "$target/"
    fi

    log "Arquivos da aplicação restaurados de: $backup"
}

install_validate_source() {
    local source="${1:?source ausente}"
    local file

    [[ -r "$source/firewall_unidades.sh" ]] || die "Fonte inválida: firewall_unidades.sh não encontrado em $source"
    [[ -d "$source/lib" ]] || die "Fonte inválida: diretório lib não encontrado em $source"

    bash -n "$source/firewall_unidades.sh" || die "Falha de sintaxe em firewall_unidades.sh."
    while IFS= read -r -d '' file; do
        bash -n "$file" || die "Falha de sintaxe em: $file"
    done < <(find "$source/lib" -type f -name '*.sh' -print0)
}

install_copy_application() {
    local source="${1:?source ausente}"
    local target="${2:?target ausente}"
    local parent stage path

    parent=$(dirname "$target")
    mkdir -p "$parent"
    stage=$(mktemp -d "$parent/.firewall-unidades-stage.XXXXXX")

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$source/$path" ]] && cp -a "$source/$path" "$stage/"
    done < <(install_managed_paths)

    install_validate_source "$stage"
    mkdir -p "$target"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rm -rf -- "$target/$path"
        [[ -e "$stage/$path" ]] && cp -a "$stage/$path" "$target/"
    done < <(install_managed_paths)

    rm -rf "$stage"
}

install_create_operational_files() {
    local target="${1:?target ausente}"

    if [[ ! -e "$target/firewall_unidades_v2.conf" ]]; then
        cat > "$target/firewall_unidades_v2.conf" <<'EOF_CONF'
# Configuração local do Firewall Unidades.
# Criada automaticamente pelo comando install.
BACKEND="iptables"
LOG_TRAFFIC=0

# Defina SERVER_IP se preferir não informá-lo em generate/apply:
# SERVER_IP="192.168.1.1"
EOF_CONF
        log "Configuração local criada: $target/firewall_unidades_v2.conf"
    fi

    if [[ ! -e "$target/regras_firewall.conf" ]]; then
        cat > "$target/regras_firewall.conf" <<'EOF_RULES'
# Regras do Firewall Unidades.
# Arquivo criado vazio por segurança. Adicione d:/u:/s:/p:/m:/c: conforme necessário.
EOF_RULES
        log "Arquivo de regras criado: $target/regras_firewall.conf"
    fi

    chmod 700 "$target"
    chmod 700 "$target/firewall_unidades.sh"
    [[ -e "$target/install.sh" ]] && chmod 700 "$target/install.sh"
    find "$target/lib" -type d -exec chmod 700 {} + 2>/dev/null || true
    find "$target/lib" -type f -name '*.sh' -exec chmod 700 {} + 2>/dev/null || true
    chmod 600 "$target/firewall_unidades_v2.conf" "$target/regras_firewall.conf"
}

install_postcheck() {
    local target="${1:?target ausente}"
    FW_BASE_DIR="$target"     FW_SETTINGS_FILE="$target/firewall_unidades_v2.conf"     FW_RULES_FILE="$target/regras_firewall.conf"         "$target/firewall_unidades.sh" check
}

install_restart_dnswatch_if_active() {
    local service="${DYNAMIC_DNS_SERVICE_NAME:-firewall-dnswatch.service}"
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        systemctl restart "$service"
        log "Serviço reiniciado após upgrade: $service"
    fi
}

install_deploy_from_source() {
    local source="${1:?source ausente}"
    local target="${2:?target ausente}"
    local mode="${3:-install}"
    local old_version new_version

    INSTALL_APP_BACKUP=""
    old_version=$(install_detect_version "$target")
    install_validate_source "$source"
    install_backup_app "$target"
    install_copy_application "$source" "$target"
    install_create_operational_files "$target"

    if ! install_postcheck "$target"; then
        warn "Validação pós-$mode falhou."
        if [[ -n "$INSTALL_APP_BACKUP" ]]; then
            warn "Restaurando versão anterior da aplicação..."
            install_restore_app_backup "$target" "$INSTALL_APP_BACKUP" || true
        fi
        return 1
    fi

    new_version=$(install_detect_version "$target")
    install_restart_dnswatch_if_active

    printf '\nFirewall Unidades %s concluído.\n' "$mode"
    printf '  diretório : %s\n' "$target"
    printf '  anterior  : %s\n' "${old_version:-não instalado}"
    printf '  atual     : %s\n' "${new_version:-desconhecida}"
    [[ -n "$INSTALL_APP_BACKUP" ]] && printf '  backup    : %s\n' "$INSTALL_APP_BACKUP"
    printf '  config    : preservada\n'
    printf '  regras    : preservadas\n'
    printf '  estado    : preservado\n'
}

cmd_install() {
    local target source
    require_root
    need_cmd bash
    need_cmd cp
    need_cmd find
    need_cmd mktemp
    need_cmd readlink

    source=$(readlink -f "$SCRIPT_DIR")
    target=$(install_normalize_target "${1:-$BASE_DIR}")

    if [[ "$source" == "$target" ]]; then
        install_create_operational_files "$target"
        install_validate_source "$target"
        install_postcheck "$target"
        printf 'Firewall Unidades já está no diretório de destino: %s\n' "$target"
        printf 'Versão: %s\n' "$(install_detect_version "$target")"
        return 0
    fi

    install_deploy_from_source "$source" "$target" "install"
}

cmd_upgrade() {
    local target source old_version new_version old_commit=""
    require_root
    need_cmd bash
    need_cmd cp
    need_cmd find
    need_cmd mktemp
    need_cmd readlink

    source=$(readlink -f "$SCRIPT_DIR")
    target=$(install_normalize_target "${1:-$BASE_DIR}")

    if [[ "$source" != "$target" ]]; then
        install_deploy_from_source "$source" "$target" "upgrade"
        return
    fi

    [[ -d "$target/.git" ]] || die "Upgrade in-place requer um checkout Git. Alternativa: execute uma cópia mais nova do projeto e use: ./firewall_unidades.sh upgrade $target"
    need_cmd git

    if [[ -n "$(git -C "$target" status --porcelain --untracked-files=no)" ]]; then
        die "Há alterações em arquivos versionados. Faça commit/stash antes do upgrade."
    fi

    old_version=$(install_detect_version "$target")
    old_commit=$(git -C "$target" rev-parse HEAD)
    INSTALL_APP_BACKUP=""
    install_backup_app "$target"

    log "Atualizando checkout com git pull --ff-only..."
    if ! git -C "$target" pull --ff-only; then
        warn "git pull falhou; nenhuma troca de versão foi concluída."
        return 1
    fi

    if ! install_validate_source "$target" || ! install_postcheck "$target"; then
        warn "Validação da nova versão falhou; restaurando commit anterior $old_commit."
        git -C "$target" reset --hard "$old_commit"
        [[ -n "$INSTALL_APP_BACKUP" ]] && install_restore_app_backup "$target" "$INSTALL_APP_BACKUP" || true
        return 1
    fi

    new_version=$(install_detect_version "$target")
    install_restart_dnswatch_if_active

    printf '\nFirewall Unidades upgrade concluído.\n'
    printf '  diretório : %s\n' "$target"
    printf '  anterior  : %s\n' "${old_version:-desconhecida}"
    printf '  atual     : %s\n' "${new_version:-desconhecida}"
    [[ -n "$INSTALL_APP_BACKUP" ]] && printf '  backup    : %s\n' "$INSTALL_APP_BACKUP"
    printf '  config/regras/estado: preservados\n'
}
