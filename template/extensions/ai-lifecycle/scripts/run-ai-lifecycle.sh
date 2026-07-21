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
        --help|-h) echo 'Usage: run-ai-lifecycle.sh [--config-path PATH] [--repo-root PATH] [--spec-path PATH] [--evidence-directory PATH] [--record-spec]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ -z "$SPEC_PATH" ]]; then SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value; value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^ai_lifecycle:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() { if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi; }
set_spec_field() { local key="$1" value="$2" temp="$SPEC_PATH.phase6.tmp"; [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }; if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi; mv "$temp" "$SPEC_PATH"; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] AI lifecycle is disabled.'; exit 0; fi
VALIDATOR="$SCRIPT_DIR/validate-ai-lifecycle.sh"
bash "$VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
RUNNER="$REPO_ROOT/scripts/run-sdlc-task.sh"
[[ -f "$RUNNER" ]] || { echo "[FAIL] Task runner not found: $RUNNER"; exit 1; }

ERRORS=()
CHECKS_JSON=()
run_check() {
    local field="$1" task exit_code result evidence relative_evidence check_json
    task="$(get_value "$field")"
    echo "[RUN] AI lifecycle check: $task"
    set +e
    bash "$RUNNER" --task "$task" --repo-root "$REPO_ROOT" --config-path "$CONFIG_PATH" --evidence-directory "$EVIDENCE_DIRECTORY"
    exit_code=$?
    set -e
    if (( exit_code == 0 )); then result='PASS'; else result='FAIL'; fi
    evidence="$REPO_ROOT/$EVIDENCE_DIRECTORY/$task.log"
    relative_evidence=''
    [[ -f "$evidence" ]] && relative_evidence="${evidence:${#REPO_ROOT}}" && relative_evidence="${relative_evidence#/}"
    check_json="$(printf '{\"task\":%s,\"purpose\":%s,\"exit_code\":%d,\"result\":%s,\"evidence\":%s}' "$(json_escape "$task")" "$(json_escape "$field")" "$exit_code" "$(json_escape "$result")" "$(json_escape "$relative_evidence")")"
    CHECKS_JSON+=("$check_json")
    if (( exit_code != 0 )); then ERRORS+=("AI lifecycle task '$task' failed with exit code $exit_code."); fi
}
for field in evaluation_task red_team_task production_exercise_task; do run_check "$field"; done

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$RECORD_DIRECTORY"
SUMMARY_PATH="$RECORD_DIRECTORY/ai-lifecycle.json"
REPORT_RELATIVE="$(get_value evaluation_report_path)"
safe_path "$REPORT_RELATIVE" || { echo "[FAIL] ai_lifecycle.evaluation_report_path must be repository-relative: $REPORT_RELATIVE"; exit 1; }
REPORT_PATH="$REPO_ROOT/$REPORT_RELATIVE"
mkdir -p "$(dirname "$REPORT_PATH")"
COMMIT_SHA="$(get_commit_sha)"
TREE_DIGEST="$(get_tree_digest)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RESULT='PASS'; EXIT_CODE=0; (( ${#ERRORS[@]} == 0 )) || { RESULT='FAIL'; EXIT_CODE=1; }
CHECKS=''; for item in "${CHECKS_JSON[@]}"; do [[ -z "$CHECKS" ]] && CHECKS="$item" || CHECKS+=",$item"; done
{
    printf '{"schema":1,"kind":"sdlc-ai-lifecycle","command":"scripts/run-ai-lifecycle.sh","risk_tier":'; json_escape "$(get_value risk_tier)"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"checked_at":'; json_escape "$TIMESTAMP"; printf ',"exit_code":%d,"result":%s,"checks":[%s],"errors":' "$EXIT_CODE" "$(json_escape "$RESULT")" "$CHECKS";
    json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
    json_array "${ERRORS[@]}"; printf '}\n'
} > "$SUMMARY_PATH"
cp "$SUMMARY_PATH" "$REPORT_PATH"

if (( RECORD_SPEC == 1 )); then
    relative_summary="${SUMMARY_PATH:${#REPO_ROOT}}"; relative_summary="${relative_summary#/}"
    set_spec_field ai_lifecycle_enabled true
    set_spec_field gate_ai_lifecycle_command '"scripts/run-ai-lifecycle.sh"'
    set_spec_field gate_ai_lifecycle_commit_sha "\"$COMMIT_SHA\""
    set_spec_field gate_ai_lifecycle_tree_digest "\"$TREE_DIGEST\""
    set_spec_field gate_ai_lifecycle_timestamp "\"$TIMESTAMP\""
    set_spec_field gate_ai_lifecycle_exit_code "$EXIT_CODE"
    set_spec_field gate_ai_lifecycle_result "$RESULT"
    set_spec_field gate_ai_lifecycle_evidence "\"$relative_summary\""
fi
if (( EXIT_CODE != 0 )); then echo '[FAIL] AI lifecycle checks failed.'; exit 1; fi
echo "[PASS] AI lifecycle checks complete: $SUMMARY_PATH"
exit 0
