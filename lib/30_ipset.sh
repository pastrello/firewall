# ---------------------------------------------------------------------------
# Compatibilidade interna - v2.4
# ---------------------------------------------------------------------------
# Este módulo deixou de ser carregado pelo firewall_unidades.sh na v2.4.
# A implementação real de conjuntos pertence ao backend selecionado.
#
# Os aliases abaixo são mantidos temporariamente para scripts auxiliares que
# ainda possam ter importado este arquivo diretamente durante a série v2.x.

ensure_active_set() { backend_set_ensure "$@"; }
load_ipset_atomic() { backend_set_load_atomic "$@"; }
save_set_entries() { backend_set_save_backup "$@"; }
