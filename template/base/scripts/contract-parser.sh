#!/usr/bin/env bash

# Shared adapter for the canonical Python contract parser.

CONTRACT_PARSER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_PARSER_SCRIPT="$CONTRACT_PARSER_DIR/contract_parser.py"
CONTRACT_PARSER_MODE="${SDLC_PARSER_MODE:-standard}"
CANONICAL_CONTRACT_PATH=""
CONTRACT_PYTHON=""

find_contract_python() {
    local candidate
    if [[ -n "${SDLC_PYTHON:-}" ]]; then
        if [[ -x "$SDLC_PYTHON" || -f "$SDLC_PYTHON" ]]; then
            CONTRACT_PYTHON="$SDLC_PYTHON"
            return 0
        fi
        echo "[FAIL] SDLC_PYTHON does not point to an executable Python interpreter: $SDLC_PYTHON" >&2
        return 2
    fi
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CONTRACT_PYTHON="$(command -v "$candidate")"
            return 0
        fi
    done
    echo '[FAIL] Python 3.9 or newer is required for canonical contract parsing. Install Python or set SDLC_PARSER_MODE=compat for a legacy installation.' >&2
    return 2
}

read_canonical_contract() {
    local path="$1" contract="$2" exit_code
    [[ -f "$CONTRACT_PARSER_SCRIPT" ]] || { echo "[FAIL] Canonical contract parser is missing: $CONTRACT_PARSER_SCRIPT" >&2; return 2; }
    [[ -n "$CONTRACT_PYTHON" ]] || find_contract_python || return $?
    CANONICAL_CONTRACT_PATH="$(mktemp "${TMPDIR:-/tmp}/sdlc-contract.XXXXXX")"
    if "$CONTRACT_PYTHON" "$CONTRACT_PARSER_SCRIPT" parse \
        --path "$path" --contract "$contract" --mode "$CONTRACT_PARSER_MODE" \
        --output "$CANONICAL_CONTRACT_PATH"; then
        return 0
    else
        exit_code=$?
        echo "[FAIL] Canonical parser rejected '$path'." >&2
        if [[ -f "$CANONICAL_CONTRACT_PATH" ]]; then
            "$CONTRACT_PYTHON" -c 'import json,sys; p=json.load(open(sys.argv[1], encoding="utf-8")); e=(p.get("errors") or [{}])[0]; line=e.get("line"); column=e.get("column"); location="" if line is None else " at line {}, column {}".format(line, column); print("[FAIL] {}{}".format(e.get("message", "unknown parser error"), location), file=sys.stderr)' "$CANONICAL_CONTRACT_PATH" || true
        fi
        return "$exit_code"
    fi
}

canonical_contract_query() {
    local path="$1" format="${2:-json}"
    [[ -n "$CANONICAL_CONTRACT_PATH" && -f "$CANONICAL_CONTRACT_PATH" ]] || return 2
    "$CONTRACT_PYTHON" "$CONTRACT_PARSER_SCRIPT" query \
        --input "$CANONICAL_CONTRACT_PATH" --path "$path" --format "$format"
}

canonical_contract_has() {
    canonical_contract_query "$1" json >/dev/null 2>&1
}

cleanup_canonical_contract() {
    if [[ -n "$CANONICAL_CONTRACT_PATH" && -f "$CANONICAL_CONTRACT_PATH" ]]; then
        rm -f "$CANONICAL_CONTRACT_PATH"
    fi
    CANONICAL_CONTRACT_PATH=""
}