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
        --help|-h) echo 'Usage: validate-operational-readiness.sh [--config-path PATH] [--repo-root PATH] [--evidence-directory PATH]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^operational_readiness:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$CONFIG_PATH"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
task_configured() { local task="$1"; [[ -n "$task" ]] && printf '%s\n' "$CONFIG_CONTENT" | grep -Fqx "  $task:"; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"
if [[ -z "$BODY" ]]; then echo '[SKIP] operational_readiness is not configured.'; exit 0; fi
[[ "$(get_value enabled false)" == true ]] || { echo '[SKIP] operational_readiness.enabled is false.'; exit 0; }
BASE_VALIDATOR="$REPO_ROOT/scripts/validate-sdlc-config.sh"
if [[ -f "$BASE_VALIDATOR" ]]; then bash "$BASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" || exit $?; fi

ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
require_value() { local field="$1"; [[ -n "$(get_value "$field")" ]] || add_error "operational_readiness.$field is required."; }
for field in service_name service_owner on_call health_endpoint slo_availability slo_latency slo_error_rate slo_throughput slo_business_outcome readiness_review_path incident_response_path alert_policy_path escalation_policy_path feedback_path incident_record_path health_check_task telemetry_check_task failure_drill_task post_release_check_task; do require_value "$field"; done
HEALTH_ENDPOINT="$(get_value health_endpoint)"
if [[ -n "$HEALTH_ENDPOINT" && ( "$HEALTH_ENDPOINT" != /* || "$HEALTH_ENDPOINT" == *'..'/* || "$HEALTH_ENDPOINT" == */'..' ) ]]; then add_error 'health_endpoint must be an absolute repository service path without traversal.'; fi
get_list required_telemetry; TELEMETRY=("${LIST_RESULT[@]}"); get_list required_slis; SLIS=("${LIST_RESULT[@]}"); get_list readiness_review_items; REVIEW_ITEMS=("${LIST_RESULT[@]}"); get_list incident_severities; SEVERITIES=("${LIST_RESULT[@]}")
for item in structured_logs metrics distributed_traces correlation_ids; do contains=0; for actual in "${TELEMETRY[@]}"; do [[ "$actual" == "$item" ]] && contains=1; done; (( contains == 1 )) || add_error "required_telemetry must include '$item'."; done
for item in availability latency error_rate throughput business_outcome; do contains=0; for actual in "${SLIS[@]}"; do [[ "$actual" == "$item" ]] && contains=1; done; (( contains == 1 )) || add_error "required_slis must include '$item'."; done
for item in capacity backup_recovery dependency_failure data_retention privacy disaster_recovery; do contains=0; for actual in "${REVIEW_ITEMS[@]}"; do [[ "$actual" == "$item" ]] && contains=1; done; (( contains == 1 )) || add_error "readiness_review_items must include '$item'."; done
for item in sev1 sev2 sev3; do contains=0; for actual in "${SEVERITIES[@]}"; do [[ "$actual" == "$item" ]] && contains=1; done; (( contains == 1 )) || add_error "incident_severities must include '$item'."; done
RETENTION="$(get_value retention_days 0)"; [[ "$RETENTION" =~ ^[1-9][0-9]*$ ]] || add_error 'retention_days must be a positive integer.'
for field in readiness_review_path incident_response_path alert_policy_path escalation_policy_path feedback_path incident_record_path; do path="$(get_value "$field")"; if ! safe_path "$path"; then add_error "operational_readiness.$field must be repository-relative: $path"; fi; done
for field in readiness_review_path incident_response_path alert_policy_path escalation_policy_path; do path="$(get_value "$field")"; [[ -f "$REPO_ROOT/$path" ]] || add_error "Required operational document is missing: $path"; done
get_list runbooks; RUNBOOKS=("${LIST_RESULT[@]}"); (( ${#RUNBOOKS[@]} >= 5 )) || add_error 'runbooks must contain the five common operational runbooks.'
for path in "${RUNBOOKS[@]}"; do safe_path "$path" || add_error "Runbook path must be repository-relative: $path"; [[ -f "$REPO_ROOT/$path" ]] || add_error "Required runbook is missing: $path"; done
for field in health_check_task telemetry_check_task failure_drill_task post_release_check_task; do task="$(get_value "$field")"; task_configured "$task" || add_error "Configured task '$task' for operational_readiness.$field is missing from tasks."; done

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"; mkdir -p "$RECORD_DIRECTORY"; COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{ printf '{"schema":1,"kind":"sdlc-operational-readiness-config-validation","command":"scripts/validate-operational-readiness.sh","commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"timestamp":'; json_escape "$TIMESTAMP"; printf ',"service":'; json_escape "$(get_value service_name)"; if (( ${#ERRORS[@]} == 0 )); then printf ',"exit_code":0,"result":"PASS"'; else printf ',"exit_code":1,"result":"FAIL"'; fi; printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}\n'; } > "$RECORD_DIRECTORY/operational-readiness-config-validation.json"
(( ${#ERRORS[@]} == 0 )) || exit 1
echo '[PASS] Operational readiness configuration is valid.'
exit 0
