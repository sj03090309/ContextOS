#!/bin/bash
# Compatibility entry point. Builds local artifacts without installing/launching.
# Use scripts/install_app.sh explicitly after reviewing the generated bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-install) ;; # packaging is always non-installing
        --to) echo 'Use scripts/install_app.sh <bundle> --to <path> for an explicit installation.' >&2; exit 2 ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done
exec bash scripts/package_app.sh "${ARGS[@]}"
