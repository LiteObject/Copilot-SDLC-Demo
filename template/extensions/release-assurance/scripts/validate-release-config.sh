#!/usr/bin/env bash
# Validate the opt-in release-assurance configuration contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'

usage() { cat <<'EOF'
Usage: ./scripts/validate-release-config.sh [--config-path PATH] [--repo-root PATH]
       [--evidence-directory PATH]
EOF
}
while (($# > 0)); do
    case "$1" in
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; fi

get_release_body() { awk '/^release_assurance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$CONFIG_PATH"; }
trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$RELEASE_BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
task_configured() { local task="$1"; [[ "$task" == 'none' ]] && return 0; [[ -n "$task" ]] || return 1; grep -Eq "^  ${task}:[[:space:]]*$" <<< "$CONFIG_CONTENT"; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
RELEASE_BODY="$(get_release_body)"
if [[ -z "$RELEASE_BODY" ]]; then echo '[SKIP] release_assurance is not configured.'; exit 0; fi
ENABLED="$(get_value enabled false)"
[[ "$ENABLED" == true ]] || { echo '[SKIP] release_assurance.enabled is false.'; exit 0; }
BASE_VALIDATOR="$REPO_ROOT/scripts/validate-sdlc-config.sh"
if [[ -f "$BASE_VALIDATOR" ]]; then bash "$BASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" || exit $?; fi

ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
for field in artifact_task artifact_path sbom_task sbom_path sbom_format smoke_test_task rollback_task release_notes_path rollback_instructions_path deployment_task provenance_path; do value="$(get_value "$field")"; [[ -n "$value" ]] || add_error "release_assurance.$field is required."; done
SBOM_FORMAT="$(get_value sbom_format)"
[[ "$SBOM_FORMAT" == cyclonedx-json || "$SBOM_FORMAT" == spdx-json ]] || add_error "release_assurance.sbom_format '$SBOM_FORMAT' is unsupported."
REQUIRE_PROVENANCE="$(get_value require_provenance)"; REQUIRE_SIGNATURE="$(get_value require_signed_artifact)"
[[ "$REQUIRE_PROVENANCE" == true || "$REQUIRE_PROVENANCE" == false ]] || add_error 'release_assurance.require_provenance must be true or false.'
[[ "$REQUIRE_SIGNATURE" == true || "$REQUIRE_SIGNATURE" == false ]] || add_error 'release_assurance.require_signed_artifact must be true or false.'
for field in artifact_path sbom_path provenance_path signature_path release_notes_path rollback_instructions_path; do value="$(get_value "$field")"; [[ -z "$value" ]] || safe_path "$value" || add_error "release_assurance.$field must be repository-relative: $value"; done
get_list promotion_environments; ENVIRONMENTS=("${LIST_RESULT[@]}"); get_list required_approvals; APPROVALS=("${LIST_RESULT[@]}")
(( ${#ENVIRONMENTS[@]} > 0 )) || add_error 'promotion_environments must contain at least one environment.'
(( ${#APPROVALS[@]} > 0 )) || add_error 'required_approvals must identify release approvers.'
for field in artifact_task sbom_task smoke_test_task rollback_task deployment_task; do task="$(get_value "$field")"; task_configured "$task" || add_error "Configured task '$task' for release_assurance.$field is missing from tasks."; done
if [[ "$REQUIRE_SIGNATURE" == true ]]; then task_configured "$(get_value signing_task)" || add_error "Configured signing task is missing from tasks."; [[ -n "$(get_value signature_path)" ]] || add_error 'signature_path is required when require_signed_artifact is true.'; fi

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"; mkdir -p "$RECORD_DIRECTORY"; RECORD_PATH="$RECORD_DIRECTORY/release-config-validation.json"
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    printf '{"schema":1,"kind":"sdlc-release-config-validation","command":"scripts/validate-release-config.sh","commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"timestamp":'; json_escape "$TIMESTAMP"; if (( ${#ERRORS[@]} == 0 )); then printf ',"exit_code":0,"result":"PASS"'; else printf ',"exit_code":1,"result":"FAIL"'; fi; printf ',"environments":'; json_array "${ENVIRONMENTS[@]}"; printf ',"required_approvals":'; json_array "${APPROVALS[@]}"; printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}\n'
} > "$RECORD_PATH"
(( ${#ERRORS[@]} == 0 )) || exit 1
echo '[PASS] Release assurance configuration is valid.'
exit 0
