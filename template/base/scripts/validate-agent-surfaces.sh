#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Validates generated agent surfaces against the portable contract.

Usage:
  scripts/validate-agent-surfaces.sh [--repo-root <path>]
      [--agent-surface copilot|generic|all]
      [--output-path <path>]
EOF
}

REPO_ROOT="$(pwd -P)"
AGENT_SURFACE='copilot'
OUTPUT_PATH='.sdlc/evidence/agent-surfaces.json'

while (( $# > 0 )); do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || { echo 'Missing value for --repo-root.' >&2; exit 1; }
      REPO_ROOT="$2"
      shift 2
      ;;
    --agent-surface|--surface)
      [[ $# -ge 2 ]] || { echo "Missing value for $1." >&2; exit 1; }
      AGENT_SURFACE="$2"
      shift 2
      ;;
    --output-path)
      [[ $# -ge 2 ]] || { echo 'Missing value for --output-path.' >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
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

case "$AGENT_SURFACE" in
  copilot|generic|all) ;;
  *) echo "Unsupported agent surface: $AGENT_SURFACE" >&2; exit 1 ;;
esac
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"
CONTRACT_RELATIVE='docs/portable-agent-contract.md'
CONTRACT_PATH="$REPO_ROOT/$CONTRACT_RELATIVE"
REQUIRED_RULES=(phase-transitions state-schema gate-commands task-ids permission-rules prohibited-actions evidence-requirements escalation-behavior editor-boundaries)
ERRORS=()

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

sha256_text() {
  local text="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$text" | openssl dgst -sha256 | awk '{print $NF}'
  else
    die 'A SHA-256 utility is required: sha256sum, shasum, or openssl.'
  fi
}

add_error() {
  ERRORS+=("$1")
}

header_value() {
  local path="$1" name="$2"
  sed -nE 's/^<!--[[:space:]]*'"$name"':[[:space:]]*(.*)[[:space:]]*-->[[:space:]]*$/\1/p' "$path" | head -n 1 | sed -E 's/[[:space:]]+$//'
}

validate_adapter() {
  local surface="$1" relative_path="$2" exact_contract="$3" path content value rule marker body
  path="$REPO_ROOT/$relative_path"
  if [[ ! -f "$path" ]]; then
    add_error "$surface adapter is missing: $relative_path"
    return
  fi
  content="$(tr -d '\r' < "$path")"
  grep -Eq '^<!--[[:space:]]*GENERATED FILE:' "$path" || add_error "$surface adapter is not marked as generated: $relative_path"
  value="$(header_value "$path" SDLC_PORTABLE_CONTRACT)"
  [[ "$value" == "$surface" ]] || add_error "$surface adapter has the wrong surface marker: $relative_path"
  value="$(header_value "$path" portable-contract)"
  [[ "$value" == "$CONTRACT_RELATIVE" ]] || add_error "$surface adapter does not point to $CONTRACT_RELATIVE"
  value="$(header_value "$path" portable-contract-sha256 | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "$CONTRACT_HASH" ]] || add_error "$surface adapter has a stale portable contract hash: $relative_path"
  value="$(header_value "$path" template-version)"
  [[ -n "$value" ]] || add_error "$surface adapter is missing a template version: $relative_path"
  if [[ "$surface" == copilot ]]; then
    adapter_template_hash="$(header_value "$path" adapter-template-sha256 | tr '[:upper:]' '[:lower:]')"
    placeholder_content="$(printf '%s' "$content" | sed -E \
      -e 's/^<!--[[:space:]]*adapter-template-sha256:[[:space:]]*.*[[:space:]]*-->[[:space:]]*$/<!-- adapter-template-sha256: {{CopilotAdapterTemplateHash}} -->/' \
      -e 's/^<!--[[:space:]]*portable-contract-sha256:[[:space:]]*.*[[:space:]]*-->[[:space:]]*$/<!-- portable-contract-sha256: {{PortableContractHash}} -->/' \
      -e 's/^<!--[[:space:]]*template-version:[[:space:]]*.*[[:space:]]*-->[[:space:]]*$/<!-- template-version: {{TemplateVersion}} -->/')"
    computed_adapter_template_hash="$(sha256_text "$placeholder_content")"
    [[ -n "$adapter_template_hash" && "$adapter_template_hash" == "$computed_adapter_template_hash" ]] || add_error "$surface adapter content differs from its generated template: $relative_path"
  fi
  for rule in "${REQUIRED_RULES[@]}"; do
    marker="<!-- PORTABLE_RULE: $rule -->"
    grep -Fq "$marker" "$path" || add_error "$surface adapter is missing required rule: $rule"
  done
  if [[ "$exact_contract" == true ]]; then
    body="$(awk 'BEGIN { separator = 0 } separator == 0 && /^$/ { separator = 1; next } separator == 1 { print }' "$path")"
    if [[ "$(printf '%s' "$body" | tr -d '\r')" != "$(tr -d '\r' < "$CONTRACT_PATH" | sed '${/^$/d;}')" ]]; then
      add_error "$surface adapter body differs from the canonical contract: $relative_path"
    fi
  fi
}

if [[ ! -f "$CONTRACT_PATH" ]]; then
  add_error "Canonical contract is missing: $CONTRACT_RELATIVE"
  CONTRACT_HASH=''
else
  CONTRACT_HASH="$(sha256_file "$CONTRACT_PATH")"
  for rule in "${REQUIRED_RULES[@]}"; do
    marker="<!-- PORTABLE_RULE: $rule -->"
    grep -Fq "$marker" "$CONTRACT_PATH" || add_error "Canonical contract is missing required rule marker: $rule"
  done
fi

if [[ "$AGENT_SURFACE" == copilot || "$AGENT_SURFACE" == all ]]; then
  validate_adapter copilot '.github/copilot-instructions.md' false
fi
if [[ "$AGENT_SURFACE" == generic || "$AGENT_SURFACE" == all ]]; then
  validate_adapter generic 'AGENTS.md' true
fi

if [[ "$OUTPUT_PATH" = /* ]]; then
  RECORD_PATH="$OUTPUT_PATH"
else
  RECORD_PATH="$REPO_ROOT/$OUTPUT_PATH"
fi
mkdir -p "$(dirname "$RECORD_PATH")"
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}
{
  printf '{"schema":1,"kind":"sdlc-agent-surface-validation","contract_path":"%s","contract_sha256":"%s","agent_surface":"%s","result":"%s","exit_code":%d,"timestamp":"%s","errors":[' \
    "$(json_escape "$CONTRACT_RELATIVE")" "$(json_escape "$CONTRACT_HASH")" "$(json_escape "$AGENT_SURFACE")" \
    "$(if (( ${#ERRORS[@]} == 0 )); then printf PASS; else printf FAIL; fi)" \
    "$(if (( ${#ERRORS[@]} == 0 )); then printf 0; else printf 1; fi)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for (( index = 0; index < ${#ERRORS[@]}; index++ )); do
    (( index > 0 )) && printf ','
    printf '"%s"' "$(json_escape "${ERRORS[$index]}")"
  done
  printf ']}\n'
} > "$RECORD_PATH"

if (( ${#ERRORS[@]} > 0 )); then
  printf '[FAIL] %s\n' "${ERRORS[@]}" >&2
  exit 1
fi
echo "[PASS] $AGENT_SURFACE agent surface matches $CONTRACT_RELATIVE."