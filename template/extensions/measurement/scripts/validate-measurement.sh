#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'

while (($# > 0)); do
    case "$1" in
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --help|-h) echo 'Usage: validate-measurement.sh [--config-path PATH] [--repo-root PATH] [--evidence-directory PATH]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}
unquote_value() {
    local value
    value="$(trim_value "$1")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
    else
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
    fi
    printf '%s' "$value"
}
CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(awk '/^measurement:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT")"
get_value() {
    local field="$1" default="${2-}" value
    value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"
    value="$(unquote_value "$value")"
    [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"
}
get_list() {
    local field="$1" raw inner item
    LIST_RESULT=()
    LIST_FORMAT=0
    raw="$(get_value "$field")"
    [[ "$raw" == \[*\] ]] || return 0
    LIST_FORMAT=1
    inner="${raw:1:${#raw}-2}"
    [[ -n "$(trim_value "$inner")" ]] || return 0
    IFS=',' read -r -a parts <<< "$inner"
    for item in "${parts[@]}"; do
        item="$(trim_value "$item")"
        item="${item#\"}"; item="${item%\"}"
        item="${item#\'}"; item="${item%\'}"
        [[ -n "$item" ]] && LIST_RESULT+=("$item")
    done
}
safe_path() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]
}
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//"/\\"}"
    value="${value//$'\r'/\r}"
    value="${value//$'\n'/\n}"
    printf '"%s"' "$value"
}
json_array() {
    local first=1 value
    printf '['
    for value in "$@"; do
        (( first == 0 )) && printf ','
        json_escape "$value"
        first=0
    done
    printf ']'
}
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
contains() {
    local wanted="$1" item
    shift
    for item in "$@"; do [[ "$item" == "$wanted" ]] && return 0; done
    return 1
}
check_required_list() {
    local field="$1" expected item
    shift
    expected=("$@")
    get_list "$field"
    local actual=("${LIST_RESULT[@]}")
    [[ "$LIST_FORMAT" == 1 ]] || add_error "measurement.$field must be an inline YAML list."
    for item in "${expected[@]}"; do
        contains "$item" "${actual[@]}" || add_error "measurement.$field must include '$item'."
    done
}
test_document() {
    local field="$1" path="$2" term
    shift 2
    if [[ ! -f "$REPO_ROOT/$path" ]]; then
        add_error "Required measurement document is missing: $field"
        return
    fi
    for term in "$@"; do
        grep -Fqi -- "$term" "$REPO_ROOT/$path" || add_error "$field must document '$term'."
    done
}
test_document_if_safe() {
    local field="$1" path="$2"
    shift 2
    safe_path "$path" || return 0
    test_document "$field" "$path" "$@"
}

ERRORS=()
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then
    if [[ -z "$BODY" ]]; then echo '[SKIP] measurement is not configured.'; else echo '[SKIP] measurement.enabled is false.'; fi
    exit 0
fi

BASE_VALIDATOR="$REPO_ROOT/scripts/validate-sdlc-config.sh"
if [[ -f "$BASE_VALIDATOR" ]]; then
    bash "$BASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
fi

for field in model cohort change_failure_window_days time_measurement_method owner cadence measurement_plan_path baseline_path metric_catalog_path catalog_path event_schema_path events_path report_path experiment_path privacy_review_path improvement_log_path quarterly_review_path snapshot_path baseline_task snapshot_task review_task; do
    [[ -n "$(get_value "$field")" ]] || add_error "measurement.$field is required."
done
CADENCE="$(get_value cadence)"
[[ "$CADENCE" == monthly || "$CADENCE" == quarterly ]] || add_error 'measurement.cadence must be monthly or quarterly.'
RETENTION="$(get_value retention_days)"
[[ "$RETENTION" =~ ^[1-9][0-9]*$ ]] || add_error 'measurement.retention_days must be a positive integer.'
FAILURE_WINDOW="$(get_value change_failure_window_days)"
[[ "$FAILURE_WINDOW" =~ ^[1-9][0-9]*$ ]] || add_error 'measurement.change_failure_window_days must be a positive integer.'
AI_APPLICABLE="$(get_value ai_product_metrics_applicable false)"
[[ "$AI_APPLICABLE" == true || "$AI_APPLICABLE" == false ]] || add_error 'measurement.ai_product_metrics_applicable must be true or false.'
REQUIRE_COMPLETION_GATE="$(get_value require_completion_gate false)"
[[ "$REQUIRE_COMPLETION_GATE" == true || "$REQUIRE_COMPLETION_GATE" == false ]] || add_error 'measurement.require_completion_gate must be true or false.'

check_required_list baseline_metrics lead_time deployment_frequency change_failure_rate recovery_time escaped_defects security_findings review_cycle_count flaky_test_rate rollback_rate slo_attainment
check_required_list delivery_metrics complete_evidence_rate agent_suggested_defect_rate human_rework review_acceptance_rate scope_drift_rate validation_pass_rate model_tool_policy_violations time_saved_or_added
check_required_list phase_outcome_metrics phase0_outcome phase1_outcome phase2_outcome phase3_outcome phase4_outcome phase5_outcome phase6_outcome phase7_outcome
check_required_list phase_leading_indicators phase0_leading_indicator phase1_leading_indicator phase2_leading_indicator phase3_leading_indicator phase4_leading_indicator phase5_leading_indicator phase6_leading_indicator phase7_leading_indicator
if [[ "$AI_APPLICABLE" == true ]]; then
    check_required_list ai_product_metrics task_quality safety_rate abstention_escalation_rate user_reported_harms cost latency drift incident_recurrence
fi

declare -A METRIC_SEEN=()
for field in baseline_metrics delivery_metrics ai_product_metrics phase_outcome_metrics phase_leading_indicators; do
    get_list "$field"
    for metric_id in "${LIST_RESULT[@]}"; do
        if [[ -n "${METRIC_SEEN[$metric_id]+present}" ]]; then add_error "Metric '$metric_id' is configured more than once."; fi
        METRIC_SEEN["$metric_id"]=1
        [[ "$metric_id" =~ ^[a-z][a-z0-9_]*$ ]] || add_error "Metric id '$metric_id' must use lowercase letters, numbers, and underscores."
    done
done

for field in measurement_plan_path baseline_path metric_catalog_path catalog_path event_schema_path events_path report_path experiment_path privacy_review_path improvement_log_path quarterly_review_path snapshot_path; do
    path="$(get_value "$field")"
    safe_path "$path" || add_error "measurement.$field must be repository-relative: $path"
done
test_document_if_safe measurement_plan_path "$(get_value measurement_plan_path)" Outcome 'leading indicator' cadence owner retention privacy
test_document_if_safe baseline_path "$(get_value baseline_path)" Baseline Definition Owner Source Retention
test_document_if_safe metric_catalog_path "$(get_value metric_catalog_path)" 'Metric ID' Definition Owner Source Retention 'Privacy review'
test_document_if_safe catalog_path "$(get_value catalog_path)" 'sdlc-measurement-catalog' 'dora-ai-v1' metrics
test_document_if_safe event_schema_path "$(get_value event_schema_path)" 'sdlc-measurement-event-schema' common_required event_types
test_document_if_safe experiment_path "$(get_value experiment_path)" 'sdlc-measurement-experiments' model experiments
test_document_if_safe privacy_review_path "$(get_value privacy_review_path)" 'Data minimization' Sensitive 'Personal data' Aggregation Retention Access 'Review outcome'
test_document_if_safe improvement_log_path "$(get_value improvement_log_path)" 'Observed effect' Regression Owner Evidence Accepted
test_document_if_safe quarterly_review_path "$(get_value quarterly_review_path)" Period 'Completed improvements' 'Unresolved risks' 'Exception trends' 'Next prioritized roadmap' Regression

for field in baseline_task snapshot_task review_task; do
    task="$(get_value "$field")"
    grep -Eq "^  ${task}:[[:space:]]*$" "$CONFIG_PATH" || add_error "Configured task '$task' for measurement.$field is missing from tasks."
done

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$RECORD_DIRECTORY"
CANONICAL_VALIDATOR="$SCRIPT_DIR/measurement.py"
PYTHON_EXECUTABLE=''
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON_EXECUTABLE="$candidate"; break; fi
done
if [[ ! -f "$CANONICAL_VALIDATOR" ]]; then
    add_error "Canonical measurement validator is missing: $CANONICAL_VALIDATOR"
elif [[ -z "$PYTHON_EXECUTABLE" ]]; then
    add_error 'Python 3 is required for the canonical measurement validator.'
else
    set +e
    "$PYTHON_EXECUTABLE" "$CANONICAL_VALIDATOR" validate-contract --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-path "$RECORD_DIRECTORY/measurement-model-validation.json"
    CANONICAL_EXIT=$?
    set -e
    (( CANONICAL_EXIT == 0 )) || add_error 'Canonical measurement model validation failed.'
fi
COMMIT_SHA="$(get_commit_sha)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( ${#ERRORS[@]} == 0 )); then RESULT='PASS'; EXIT_CODE=0; else RESULT='FAIL'; EXIT_CODE=1; fi
{
    printf '{"schema":1,"kind":"sdlc-measurement-config-validation","command":"scripts/validate-measurement.sh","commit_sha":'; json_escape "$COMMIT_SHA"
    printf ',"timestamp":'; json_escape "$TIMESTAMP"
    printf ',"model":'; json_escape "$(get_value model)"
    printf ',"cohort":'; json_escape "$(get_value cohort)"
    printf ',"change_failure_window_days":'; json_escape "$FAILURE_WINDOW"
    printf ',"owner":'; json_escape "$(get_value owner)"
    printf ',"cadence":'; json_escape "$CADENCE"
    printf ',"require_completion_gate":'; json_escape "$REQUIRE_COMPLETION_GATE"
    printf ',"exit_code":%d,"result":' "$EXIT_CODE"; json_escape "$RESULT"
    printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}\n'
} > "$RECORD_DIRECTORY/measurement-config-validation.json"
if (( ${#ERRORS[@]} > 0 )); then exit 1; fi
echo '[PASS] Measurement configuration is valid.'
exit 0