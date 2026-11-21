#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-install}"
TARGET=""

case "$MODE" in
    install|upgrade)
        shift || true
        TARGET="${1:-/operacao/firewall.unidades}"
        ;;
    -h|--help|help)
        cat <<'EOF_HELP'
Firewall Unidades - bootstrap de instalação/upgrade

Uso:
  bash install.sh install [DIRETORIO]
  bash install.sh upgrade [DIRETORIO]
  bash install.sh [DIRETORIO]

Padrão:
  DIRETORIO=/operacao/firewall.unidades

Exemplos:
  bash install.sh
  bash install.sh upgrade
  bash install.sh upgrade /operacao/firewall.unidades
EOF_HELP
        exit 0
        ;;
    *)
        TARGET="$MODE"
        MODE="install"
        ;;
esac

exec "$ROOT_DIR/firewall_unidades.sh" "$MODE" "$TARGET"
