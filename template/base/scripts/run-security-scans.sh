#!/usr/bin/env bash
#
# Run configured security tasks and apply the blocking-severity policy.
#
# Each task is delegated to run-sdlc-task.sh, preserving structured executable
# and args invocation. A nonzero task without an explicit severity in its log
# is treated as high. Critical/high findings block by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY=""
SPEC_PATH=""
FEATURE_ID=""
RECORD_SPEC=0

usage() {
    cat <<'EOF'
Usage: ./scripts/run-security-scans.sh [--config-path PATH] [--repo-root PATH]
    [--evidence-directory PATH] [--spec-path PATH] [--feature-id ID] [--record-spec]
EOF
}
while (($# > 0)); do
    case "$1" in
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --spec-path) [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 2; }; SPEC_PATH="$2"; shift 2 ;;
        --feature-id) [[ $# -ge 2 ]] || { echo '[FAIL] --feature-id requires a value.'; exit 2; }; FEATURE_ID="$2"; shift 2 ;;
        --record-spec) RECORD_SPEC=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
requested_evidence_directory="$EVIDENCE_DIRECTORY"
resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" "$EVIDENCE_DIRECTORY" || exit 2
if [[ -z "$FEATURE_ID" ]]; then EVIDENCE_DIRECTORY="$requested_evidence_directory"; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; fi

VALIDATOR="$SCRIPT_DIR/validate-sdlc-config.sh"
validator_args=(--config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT")
[[ -n "$FEATURE_ID" ]] && validator_args+=(--feature-id "$FEATURE_ID")
if (( RECORD_SPEC == 1 )); then validator_args+=(--spec-path "$SPEC_PATH" --record-spec); fi
set +e
bash "$VALIDATOR" "${validator_args[@]}"
validator_exit=$?
set -e
(( validator_exit == 0 )) || exit "$validator_exit"

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}
unquote_value() {
    local value
    value="$(trim_value "$1")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; value="${value//\\\"/\"}"; fi
    printf '%s' "$value"
}
parse_inline() {
    local value="$1" inner item
    PARSED=()
    value="$(trim_value "$value")"
    [[ "$value" == \[*\] ]] || return 1
    inner="${value:1:${#value}-2}"
    [[ -z "$(trim_value "$inner")" ]] && return 0
    IFS=',' read -r -a raw <<< "$inner"
    for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && PARSED+=("$item"); done
}
get_list() {
    local section="$1" field="$2" in_block=0 line value
    LIST_RESULT=()
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == "$section:" ]]; then in_block=1; continue; fi
        if (( in_block == 1 )) && [[ "$line" =~ ^[^[:space:]] ]]; then break; fi
        if (( in_block == 1 )) && [[ "$line" =~ ^[[:space:]]+$field:[[:space:]]*(.*)$ ]]; then
            parse_inline "${BASH_REMATCH[1]}" || return 1
            LIST_RESULT=("${PARSED[@]}")
            return 0
        fi
    done < "$CONFIG_PATH"
}
get_value() {
    local section="$1" field="$2" default="$3" in_block=0 line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == "$section:" ]]; then in_block=1; continue; fi
        if (( in_block == 1 )) && [[ "$line" =~ ^[^[:space:]] ]]; then break; fi
        if (( in_block == 1 )) && [[ "$line" =~ ^[[:space:]]+$field:[[:space:]]*(.*)$ ]]; then printf '%s' "$(unquote_value "${BASH_REMATCH[1]}")"; return 0; fi
    done < "$CONFIG_PATH"
    printf '%s' "$default"
}
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() {
    if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi
}
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
set_spec_field() {
    local key="$1" value="$2" temp="$SPEC_PATH.phase2.tmp"
    [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }
    if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi
    mv "$temp" "$SPEC_PATH"
}

if [[ -z "$EVIDENCE_DIRECTORY" ]]; then EVIDENCE_DIRECTORY="$(get_value validation evidence_directory .sdlc/evidence)"; fi
# The helper above expects the dotted path form used by the config parser.
if [[ "$EVIDENCE_DIRECTORY" == '.sdlc/evidence' && -z "$(get_value validation evidence_directory '')" ]]; then EVIDENCE_DIRECTORY='.sdlc/evidence'; fi
get_list security tasks || { echo '[FAIL] Could not parse security.tasks.'; exit 2; }
SECURITY_TASKS=("${LIST_RESULT[@]}")
get_list security blocking_severities || { echo '[FAIL] Could not parse security.blocking_severities.'; exit 2; }
BLOCKING_SEVERITIES=("${LIST_RESULT[@]}")
(( ${#BLOCKING_SEVERITIES[@]} > 0 )) || BLOCKING_SEVERITIES=(critical high)
EVIDENCE_ROOT="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$EVIDENCE_ROOT"
COMMIT_SHA="$(get_commit_sha)"
TREE_DIGEST="$(get_tree_digest)"
TASK_RUNNER="$SCRIPT_DIR/run-sdlc-task.sh"
OVERALL_EXIT=0
FINDING_TASKS=()
FINDING_SEVERITIES=()
FINDING_RESULTS=()
FINDING_BLOCKING=()
FINDING_EXITS=()

for task in "${SECURITY_TASKS[@]}"; do
    set +e
    task_args=(--task "$task" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY")
    [[ -n "$FEATURE_ID" ]] && task_args+=(--feature-id "$FEATURE_ID")
    bash "$TASK_RUNNER" "${task_args[@]}" >/dev/null
    task_exit=$?
    set -e
    log_path="$EVIDENCE_ROOT/$task.log"
    severity=''
    if [[ -f "$log_path" ]]; then
        for candidate in critical high medium low info; do
            if grep -Eiq "(^|[^[:alnum:]_])$candidate([^[:alnum:]_]|$)" "$log_path"; then severity="$candidate"; break; fi
        done
    fi
    [[ -n "$severity" ]] || { (( task_exit != 0 )) && severity='high' || severity='info'; }
    blocking=false
    for policy in "${BLOCKING_SEVERITIES[@]}"; do [[ "$severity" == "$policy" ]] && blocking=true; done
    [[ "$blocking" == true ]] && OVERALL_EXIT=1
    FINDING_TASKS+=("$task")
    FINDING_SEVERITIES+=("$severity")
    if (( task_exit == 0 )); then FINDING_RESULTS+=(PASS); else FINDING_RESULTS+=(FAIL); fi
    FINDING_BLOCKING+=("$blocking")
    FINDING_EXITS+=("$task_exit")
done

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD_PATH="$EVIDENCE_ROOT/security-scan.json"
{
    printf '{"schema":1,"kind":"sdlc-security-scan","command":"scripts/run-security-scans.sh","feature_id":'; json_escape "$FEATURE_ID"; printf ',"spec_path":'; json_escape "$SPEC_RELATIVE_PATH"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"timestamp":'; json_escape "$TIMESTAMP"; printf ',"exit_code":%d,"result":"%s","blocking_severities":' "$OVERALL_EXIT" "$([[ "$OVERALL_EXIT" -eq 0 ]] && echo PASS || echo FAIL)"; json_array "${BLOCKING_SEVERITIES[@]}"; printf ',"findings":['
    for (( index=0; index<${#FINDING_TASKS[@]}; index++ )); do
        (( index > 0 )) && printf ','
        printf '{"task":'; json_escape "${FINDING_TASKS[$index]}"; printf ',"severity":'; json_escape "${FINDING_SEVERITIES[$index]}"; printf ',"result":'; json_escape "${FINDING_RESULTS[$index]}"; printf ',"blocking":%s,"exit_code":%d,"evidence":' "${FINDING_BLOCKING[$index]}" "${FINDING_EXITS[$index]}"; json_escape "$EVIDENCE_DIRECTORY/${FINDING_TASKS[$index]}.log"; printf '}'
    done
    printf ']}\n'
} > "$RECORD_PATH"
echo "[INFO] Security evidence: $RECORD_PATH"
if (( RECORD_SPEC == 1 )); then
    relative_evidence="${RECORD_PATH:${#REPO_ROOT}}"; relative_evidence="${relative_evidence#/}"
    set_spec_field gate_security_command '"scripts/run-security-scans.sh"'
    set_spec_field gate_security_commit_sha "\"$COMMIT_SHA\""
    set_spec_field gate_security_tree_digest "\"$TREE_DIGEST\""
    set_spec_field gate_security_timestamp "\"$TIMESTAMP\""
    set_spec_field gate_security_exit_code "$OVERALL_EXIT"
    if (( OVERALL_EXIT == 0 )); then set_spec_field gate_security_result PASS; else set_spec_field gate_security_result FAIL; fi
    set_spec_field gate_security_evidence "\"$relative_evidence\""
    if [[ -n "$FEATURE_ID" ]]; then
        set_spec_field gate_security_feature_id "\"$FEATURE_ID\""
        set_spec_field gate_security_spec_path "\"$SPEC_RELATIVE_PATH\""
    fi
fi
if (( OVERALL_EXIT != 0 )); then echo '[FAIL] Blocking security findings detected.'; exit 1; fi
echo '[PASS] Security scan policy passed.'
exit 0
