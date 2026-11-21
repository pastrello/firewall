# ---------------------------------------------------------------------------
# Backend dispatcher - v2.4
# ---------------------------------------------------------------------------
# A camada comum conhece apenas a API de backend. Implementações concretas
# vivem em lib/backend/<backend>.sh.

backend_load() {
    local script_dir="${1:?script_dir ausente}"
    local selected="${2:-iptables}"

    case "$selected" in
        iptables)
            # shellcheck disable=SC1090
            source "$script_dir/lib/backend/iptables.sh"
            ;;
        nftables)
            die "BACKEND=nftables está reservado para a v2.5 e ainda não pode ser aplicado na v2.4."
            ;;
        *)
            die "BACKEND inválido: $selected (v2.4 suporta: iptables)."
            ;;
    esac

    backend_assert_api
}

backend_assert_api() {
    local fn missing=0
    for fn in         backend_require_tools         backend_rules_filename         backend_generate_rules         backend_validate_rules         backend_apply_rules         backend_backup_rules         backend_restore_rules         backend_set_ensure         backend_set_load_atomic         backend_set_export_entries         backend_set_save_backup         backend_set_destroy         backend_set_exists         backend_set_count         backend_ruleset_uses_set         backend_print_status         backend_print_diagnose         backend_print_info; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            warn "Backend '$BACKEND' não implementa função obrigatória: $fn"
            missing=1
        fi
    done
    (( missing == 0 )) || die "Backend '$BACKEND' incompleto."
}

backend_configured_name() { printf '%s\n' "$BACKEND"; }
