#!/bin/bash
# Explicit local install/update. Old bundle retained; never launches/kills apps.
set -euo pipefail
exec python3 "$(dirname "$0")/install_app.py" "$@"
