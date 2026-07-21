#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
SPEC_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
RECORD_SPEC=0

while (($# > 0)); do
    case "$1" in
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --spec-path) [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 2; }; SPEC_PATH="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --record-spec) RECORD_SPEC=1; shift ;;
        --help|-h) echo 'Usage: run-measurement.sh [--config-path PATH] [--repo-root PATH] [--spec-path PATH] [--evidence-directory PATH] [--record-spec]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ -z "$SPEC_PATH" ]]; then SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value; value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(awk '/^measurement:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT")"
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" raw inner item; LIST_RESULT=(); raw="$(get_value "$field")"; [[ "$raw" == \[*\] ]] || return 0; inner="${raw:1:${#raw}-2}"; [[ -n "$(trim_value "$inner")" ]] || return 0; IFS=',' read -r -a parts <<< "$inner"; for item in "${parts[@]}"; do item="$(trim_value "$item")"; item="${item#\"}"; item="${item%\"}"; item="${item#\'}"; item="${item%\'}"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//"/\\"}"; value="${value//$'\r'/\r}"; value="${value//$'\n'/\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do if (( first == 0 )); then printf ','; fi; json_escape "$value"; first=0; done; printf ']'; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() { if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi; }
set_spec_field() { local key="$1" value="$2" temp="$SPEC_PATH.phase7.tmp"; [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }; if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi; mv "$temp" "$SPEC_PATH"; }

if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] Measurement is disabled.'; exit 0; fi
VALIDATOR="$SCRIPT_DIR/validate-measurement.sh"
bash "$VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
RUNNER="$REPO_ROOT/scripts/run-sdlc-task.sh"
[[ -f "$RUNNER" ]] || { echo "[FAIL] Task runner not found: $RUNNER"; exit 1; }
PYTHON_EXECUTABLE=''
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON_EXECUTABLE="$candidate"; break; fi
done
SNAPSHOT_VALIDATOR="$SCRIPT_DIR/validate-measurement-snapshot.py"

ERRORS=()
CHECKS_JSON=()
run_check() {
    local field="$1" task exit_code result evidence relative_evidence
    task="$(get_value "$field")"
    echo "[RUN] Measurement check: $task"
    set +e
    bash "$RUNNER" --task "$task" --repo-root "$REPO_ROOT" --config-path "$CONFIG_PATH" --evidence-directory "$EVIDENCE_DIRECTORY"
    exit_code=$?
    set -e
    if (( exit_code == 0 )); then result='PASS'; else result='FAIL'; fi
    evidence="$REPO_ROOT/$EVIDENCE_DIRECTORY/$task.log"
    relative_evidence=''
    if [[ -f "$evidence" ]]; then relative_evidence="${evidence:${#REPO_ROOT}}"; relative_evidence="${relative_evidence#/}"; fi
    CHECKS_JSON+=("$(printf '{\"task\":%s,\"purpose\":%s,\"exit_code\":%d,\"result\":%s,\"evidence\":%s}' "$(json_escape "$task")" "$(json_escape "$field")" "$exit_code" "$(json_escape "$result")" "$(json_escape "$relative_evidence")")")
    if (( exit_code != 0 )); then ERRORS+=("Measurement task '$task' failed with exit code $exit_code."); fi
}
for field in baseline_task snapshot_task review_task; do run_check "$field"; done

SNAPSHOT_RELATIVE="$(get_value snapshot_path)"
safe_path "$SNAPSHOT_RELATIVE" || { echo "[FAIL] measurement.snapshot_path must be repository-relative: $SNAPSHOT_RELATIVE"; exit 1; }
SNAPSHOT_EVIDENCE=''
[[ -f "$REPO_ROOT/$SNAPSHOT_RELATIVE" ]] && SNAPSHOT_EVIDENCE="$SNAPSHOT_RELATIVE"
RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$RECORD_DIRECTORY"
SNAPSHOT_VALIDATION_PATH="$RECORD_DIRECTORY/measurement-snapshot-validation.json"
SNAPSHOT_EXIT_CODE=1
EXPECTED_METRICS=()
for field in baseline_metrics delivery_metrics phase_outcome_metrics phase_leading_indicators; do
    get_list "$field"
    EXPECTED_METRICS+=("${LIST_RESULT[@]}")
done
if [[ "$(get_value ai_product_metrics_applicable false)" == true ]]; then
    get_list ai_product_metrics
    EXPECTED_METRICS+=("${LIST_RESULT[@]}")
fi
if [[ -z "$PYTHON_EXECUTABLE" ]]; then
    ERRORS+=("Python 3 is required to validate the measurement snapshot.")
elif [[ ! -f "$SNAPSHOT_VALIDATOR" ]]; then
    ERRORS+=("Measurement snapshot validator is missing: $SNAPSHOT_VALIDATOR")
else
    SNAPSHOT_ARGUMENTS=(
        "$SNAPSHOT_VALIDATOR"
        --snapshot-path "$REPO_ROOT/$SNAPSHOT_RELATIVE"
        --repo-root "$REPO_ROOT"
        --owner "$(get_value owner)"
        --retention-days "$(get_value retention_days)"
        --validation-evidence-path "$SNAPSHOT_VALIDATION_PATH"
    )
    for metric in "${EXPECTED_METRICS[@]}"; do SNAPSHOT_ARGUMENTS+=(--metric "$metric"); done
    set +e
    "$PYTHON_EXECUTABLE" "${SNAPSHOT_ARGUMENTS[@]}"
    SNAPSHOT_EXIT_CODE=$?
    set -e
    if (( SNAPSHOT_EXIT_CODE != 0 )); then ERRORS+=("Measurement snapshot validation failed with exit code $SNAPSHOT_EXIT_CODE."); fi
fi
SNAPSHOT_VALIDATION_EVIDENCE=''
[[ -f "$SNAPSHOT_VALIDATION_PATH" ]] && SNAPSHOT_VALIDATION_EVIDENCE="${SNAPSHOT_VALIDATION_PATH:${#REPO_ROOT}}" && SNAPSHOT_VALIDATION_EVIDENCE="${SNAPSHOT_VALIDATION_EVIDENCE#/}"
CHECKS_JSON+=("$(printf '{\"task\":\"measurement_snapshot_schema\",\"purpose\":\"snapshot_validation\",\"exit_code\":%d,\"result\":%s,\"evidence\":%s}' "$SNAPSHOT_EXIT_CODE" "$(if (( SNAPSHOT_EXIT_CODE == 0 )); then json_escape PASS; else json_escape FAIL; fi)" "$(json_escape "$SNAPSHOT_VALIDATION_EVIDENCE")")")
COMMIT_SHA="$(get_commit_sha)"
TREE_DIGEST="$(get_tree_digest)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( ${#ERRORS[@]} == 0 )); then RESULT='PASS'; EXIT_CODE=0; else RESULT='FAIL'; EXIT_CODE=1; fi
CHECKS=''
for item in "${CHECKS_JSON[@]}"; do
    if [[ -n "$CHECKS" ]]; then CHECKS+=","; fi
    CHECKS+="$item"
done
get_list baseline_metrics; BASELINE_JSON="$(json_array "${LIST_RESULT[@]}")"
get_list delivery_metrics; DELIVERY_JSON="$(json_array "${LIST_RESULT[@]}")"
get_list ai_product_metrics; AI_JSON="$(json_array "${LIST_RESULT[@]}")"
get_list phase_outcome_metrics; OUTCOME_JSON="$(json_array "${LIST_RESULT[@]}")"
get_list phase_leading_indicators; LEADING_JSON="$(json_array "${LIST_RESULT[@]}")"
{
    printf '{"schema":1,"kind":"sdlc-measurement","command":"scripts/run-measurement.sh","owner":'; json_escape "$(get_value owner)"; printf ',"cadence":'; json_escape "$(get_value cadence)"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"measured_at":'; json_escape "$TIMESTAMP"; printf ',"snapshot_evidence":'; json_escape "$SNAPSHOT_EVIDENCE"; printf ',"snapshot_validation_evidence":'; json_escape "$SNAPSHOT_VALIDATION_EVIDENCE"; printf ',"metrics":{"baseline":%s,"delivery":%s,"ai_product":%s,"phase_outcomes":%s,"phase_leading_indicators":%s},"exit_code":%d,"result":' "$BASELINE_JSON" "$DELIVERY_JSON" "$AI_JSON" "$OUTCOME_JSON" "$LEADING_JSON" "$EXIT_CODE"; json_escape "$RESULT"; printf ',"checks":[%s],"errors":' "$CHECKS"; json_array "${ERRORS[@]}"; printf '}\n'
} > "$RECORD_DIRECTORY/measurement.json"
if (( RECORD_SPEC == 1 )); then
    set_spec_field measurement_enabled true
    set_spec_field gate_measurement_command '"scripts/run-measurement.sh"'
    set_spec_field gate_measurement_commit_sha "\"$COMMIT_SHA\""
    set_spec_field gate_measurement_tree_digest "\"$TREE_DIGEST\""
    set_spec_field gate_measurement_timestamp "\"$TIMESTAMP\""
    set_spec_field gate_measurement_exit_code "$EXIT_CODE"
    set_spec_field gate_measurement_result "$RESULT"
    set_spec_field gate_measurement_evidence "\"$EVIDENCE_DIRECTORY/measurement.json\""
fi
if (( EXIT_CODE != 0 )); then echo '[FAIL] Measurement checks failed.'; exit 1; fi
echo "[PASS] Measurement checks complete: $RECORD_DIRECTORY/measurement.json"
exit 0