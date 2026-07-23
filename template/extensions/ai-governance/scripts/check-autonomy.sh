#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/autonomy-policy.py"
if command -v python3 >/dev/null 2>&1; then
	PYTHON_EXECUTABLE="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
	PYTHON_EXECUTABLE="$(command -v python)"
else
	echo '[FAIL] Python 3 is required for check-autonomy.' >&2
	exit 1
fi
if [[ ! -f "$CORE" ]]; then
	echo "[FAIL] Autonomy policy engine not found: $CORE" >&2
	exit 1
fi
exec "$PYTHON_EXECUTABLE" "$CORE" "$@"