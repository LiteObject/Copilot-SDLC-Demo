#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Generates the generic portable agent surface.

Usage:
  scripts/generate-agent-surfaces.sh [--repo-root <path>] [--surface generic]
      [--template-version <version>] [--preview] [--force] [--update]

The generic surface is written to AGENTS.md. Existing project-owned or
modified files are preserved unless --update is explicitly supplied.
EOF
}

REPO_ROOT="$(pwd -P)"
SURFACE='generic'
TEMPLATE_VERSION=''
PREVIEW=0
FORCE=0
UPDATE=0

while (( $# > 0 )); do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo 'Missing value for --repo-root.' >&2; exit 1; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --surface|--agent-surface)
      [[ $# -ge 2 ]] || { echo "Missing value for $1." >&2; exit 1; }
      SURFACE="$2"
      shift 2
      ;;
    --template-version)
      [[ $# -ge 2 ]] || { echo 'Missing value for --template-version.' >&2; exit 1; }
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --preview)
      PREVIEW=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --update|--update-agent-surface)
      UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

[[ "$SURFACE" == generic ]] || { echo "Unsupported agent surface: $SURFACE" >&2; exit 1; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
CONTRACT_RELATIVE='docs/portable-agent-contract.md'
CONTRACT_PATH="$REPO_ROOT/$CONTRACT_RELATIVE"
OUTPUT_PATH="$REPO_ROOT/AGENTS.md"
STATE_PATH="$REPO_ROOT/.sdlc/sdlc-installer-state.json"

die() {
  echo "$1" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    die 'A SHA-256 utility is required: sha256sum, shasum, or openssl.'
  fi
}

state_value() {
  local key="$1"
  [[ -f "$STATE_PATH" ]] || return 0
  sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$STATE_PATH" | head -n 1
}

recorded_output_hash() {
  [[ -f "$STATE_PATH" ]] || return 0
  awk '
    /"path"[[:space:]]*:[[:space:]]*"AGENTS\.md"/ { found = 1 }
    found && /"hash"[[:space:]]*:/ {
      match($0, /"hash"[[:space:]]*:[[:space:]]*"([^"]*)"/, value)
      print value[1]
      exit
    }
  ' "$STATE_PATH"
}

show_diff() {
  local current="$1" candidate="$2"
  if [[ -f "$current" ]]; then
    if command -v diff >/dev/null 2>&1; then
      set +e
      diff -u "$current" "$candidate"
      set -e
    else
      echo "--- $current"
      echo "+++ generated candidate"
    fi
  else
    echo '--- /dev/null'
    echo "+++ $current"
    sed 's/^/+/' "$candidate"
  fi
}

[[ -f "$CONTRACT_PATH" ]] || die "Portable agent contract not found: $CONTRACT_PATH"
CONTRACT_HASH="$(sha256_file "$CONTRACT_PATH")"
if [[ -z "$TEMPLATE_VERSION" ]]; then
  TEMPLATE_VERSION="$(state_value templateVersion || true)"
fi
[[ -n "$TEMPLATE_VERSION" ]] || TEMPLATE_VERSION='unknown'

CANDIDATE_PATH="$(mktemp "${TMPDIR:-/tmp}/sdlc-agents.XXXXXX")"
cleanup() { rm -f "$CANDIDATE_PATH"; }
trap cleanup EXIT
{
  printf '%s\n' '<!-- GENERATED FILE: do not edit directly. -->'
  printf '%s\n' '<!-- SDLC_PORTABLE_CONTRACT: generic -->'
  printf '<!-- portable-contract: %s -->\n' "$CONTRACT_RELATIVE"
  printf '<!-- portable-contract-sha256: %s -->\n' "$CONTRACT_HASH"
  printf '<!-- template-version: %s -->\n' "$TEMPLATE_VERSION"
  printf '\n'
  tr -d '\r' < "$CONTRACT_PATH"
} > "$CANDIDATE_PATH"

if [[ -f "$OUTPUT_PATH" ]] && cmp -s "$OUTPUT_PATH" "$CANDIDATE_PATH"; then
  echo "[PASS] $OUTPUT_PATH is current."
  exit 0
fi

if (( PREVIEW == 1 || UPDATE == 1 )) || [[ -f "$OUTPUT_PATH" ]]; then
  show_diff "$OUTPUT_PATH" "$CANDIDATE_PATH"
fi
if (( PREVIEW == 1 )); then
  echo '[PREVIEW] No agent surface files were changed.'
  exit 0
fi

recorded_hash="$(recorded_output_hash || true)"
current_hash=''
if [[ -f "$OUTPUT_PATH" ]]; then
  current_hash="$(sha256_file "$OUTPUT_PATH")"
fi
can_refresh=0
if (( FORCE == 1 )) && [[ -n "$recorded_hash" && "$current_hash" == "$recorded_hash" ]]; then
  can_refresh=1
fi

if (( UPDATE == 0 )) && [[ -f "$OUTPUT_PATH" && $can_refresh -eq 0 ]]; then
  echo "[KEEP] Existing $OUTPUT_PATH was preserved. Use --update after reviewing the diff to replace a project-owned or modified adapter." >&2
  exit 0
fi

cp "$CANDIDATE_PATH" "$OUTPUT_PATH"
echo "[UPDATED] $OUTPUT_PATH"