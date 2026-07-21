#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh" 2>/dev/null || . "$SCRIPT_DIR/../../../base/scripts/feature-context.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
SPEC_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
FEATURE_ID=""
FAILURE_DRILL=0
RECORD_SPEC=0

while (($# > 0)); do
    case "$1" in
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --spec-path) [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 2; }; SPEC_PATH="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --feature-id) [[ $# -ge 2 ]] || { echo '[FAIL] --feature-id requires a value.'; exit 2; }; FEATURE_ID="$2"; shift 2 ;;
        --failure-drill) FAILURE_DRILL=1; shift ;;
        --record-spec) RECORD_SPEC=1; shift ;;
        --help|-h) echo 'Usage: run-operational-readiness.sh [--config-path PATH] [--repo-root PATH] [--spec-path PATH] [--evidence-directory PATH] [--failure-drill] [--record-spec]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" "$EVIDENCE_DIRECTORY" || exit 2
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^operational_readiness:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$CONFIG_PATH"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
set_spec_field() { local key="$1" value="$2" temp="$SPEC_PATH.phase4.tmp"; [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }; if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi; mv "$temp" "$SPEC_PATH"; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() { if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi; }

BODY="$(get_body)"
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] Operational readiness is disabled.'; exit 0; fi
VALIDATOR="$SCRIPT_DIR/validate-operational-readiness.sh"
bash "$VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
RUNNER="$REPO_ROOT/scripts/run-sdlc-task.sh"
TASK_FIELDS=(health_check_task telemetry_check_task post_release_check_task)
if (( FAILURE_DRILL == 1 )); then TASK_FIELDS=(health_check_task telemetry_check_task failure_drill_task post_release_check_task); fi
ERRORS=()
CHECKS_JSON=()
run_check() {
    local field="$1" task="$2" exit_code result evidence relative_evidence
    task="$(get_value "$field")"
    echo "[RUN] Operational check: $task"
    set +e
    runner_args=(--task "$task" --repo-root "$REPO_ROOT" --config-path "$CONFIG_PATH" --evidence-directory "$EVIDENCE_DIRECTORY")
    [[ -n "$FEATURE_ID" ]] && runner_args+=(--feature-id "$FEATURE_ID")
    bash "$RUNNER" "${runner_args[@]}"
    exit_code=$?
    set -e
    if (( exit_code == 0 )); then result='PASS'; else result='FAIL'; fi
    evidence="$REPO_ROOT/$EVIDENCE_DIRECTORY/$task.log"
    relative_evidence="${evidence:${#REPO_ROOT}}"; relative_evidence="${relative_evidence#/}"
    check_json="$(printf '{\"task\":%s,\"purpose\":%s,\"exit_code\":%d,\"result\":%s,\"evidence\":%s}' "$(json_escape "$task")" "$(json_escape "$field")" "$exit_code" "$(json_escape "$result")" "$(json_escape "$relative_evidence")")"
    CHECKS_JSON+=("$check_json")
    if (( exit_code != 0 )); then ERRORS+=("Operational task '$task' failed with exit code $exit_code."); fi
}
for field in "${TASK_FIELDS[@]}"; do run_check "$field" ''; done

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"; mkdir -p "$RECORD_DIRECTORY"; SUMMARY_PATH="$RECORD_DIRECTORY/operational-readiness.json"; COMMIT_SHA="$(get_commit_sha)"; TREE_DIGEST="$(get_tree_digest)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; SERVICE_NAME="$(get_value service_name)"; MODE='readiness'; (( FAILURE_DRILL == 1 )) && MODE='failure-drill'; CHECKS=''; for item in "${CHECKS_JSON[@]}"; do [[ -z "$CHECKS" ]] && CHECKS="$item" || CHECKS+=",$item"; done
if (( ${#ERRORS[@]} == 0 )); then RESULT='PASS'; EXIT_CODE=0; else RESULT='FAIL'; EXIT_CODE=1; fi
{ printf '{"schema":1,"kind":"sdlc-operational-readiness","command":"scripts/run-operational-readiness.sh","service":'; json_escape "$SERVICE_NAME"; printf ',"mode":'; json_escape "$MODE"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"checked_at":'; json_escape "$TIMESTAMP"; printf ',"exit_code":%d,"result":%s,"checks":[%s],"errors":' "$EXIT_CODE" "$(json_escape "$RESULT")" "$CHECKS"; json_array "${ERRORS[@]}"; printf '}\n'; } > "$SUMMARY_PATH"
if (( RECORD_SPEC == 1 )); then
    relative_summary="${SUMMARY_PATH:${#REPO_ROOT}}"; relative_summary="${relative_summary#/}"
    set_spec_field gate_operational_readiness_command '"scripts/run-operational-readiness.sh"'
    set_spec_field gate_operational_readiness_commit_sha "\"$COMMIT_SHA\""
    set_spec_field gate_operational_readiness_tree_digest "\"$TREE_DIGEST\""
    set_spec_field gate_operational_readiness_timestamp "\"$TIMESTAMP\""
    set_spec_field gate_operational_readiness_exit_code "$EXIT_CODE"
    set_spec_field gate_operational_readiness_result "$RESULT"
    set_spec_field gate_operational_readiness_evidence "\"$relative_summary\""
    if [[ -n "$FEATURE_ID" ]]; then
        set_spec_field gate_operational_readiness_feature_id "\"$FEATURE_ID\""
        set_spec_field gate_operational_readiness_spec_path "\"$SPEC_RELATIVE_PATH\""
    fi
fi
if (( EXIT_CODE != 0 )); then echo '[FAIL] Operational readiness checks failed.'; exit 1; fi
echo "[PASS] Operational readiness checks complete: $SUMMARY_PATH"
exit 0
