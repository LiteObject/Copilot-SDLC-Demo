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
        --help|-h) echo 'Usage: validate-ai-lifecycle.sh [--config-path PATH] [--repo-root PATH] [--evidence-directory PATH]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value; value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^ai_lifecycle:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
contains() { local expected="$1" actual; shift; for actual in "$@"; do [[ "$actual" == "$expected" ]] && return 0; done; return 1; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
task_configured() { local task="$1"; [[ -n "$task" ]] && grep -Eq "^  ${task}:[[:space:]]*$" <<< "$CONFIG_CONTENT"; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"
if [[ -z "$BODY" ]]; then echo '[SKIP] ai_lifecycle is not configured.'; exit 0; fi
[[ "$(get_value enabled false)" == true ]] || { echo '[SKIP] ai_lifecycle.enabled is false.'; exit 0; }

BASE_VALIDATOR="$REPO_ROOT/scripts/validate-sdlc-config.sh"
if [[ -f "$BASE_VALIDATOR" ]]; then bash "$BASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" || exit $?; fi

ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
require_value() { local field="$1"; [[ -n "$(get_value "$field")" ]] || add_error "ai_lifecycle.$field is required."; }

for field in risk_owner human_oversight contestability impact_assessment_path inventory_path evaluation_plan_path evaluation_report_path risk_disposition_path red_team_plan_path runtime_controls_path monitoring_plan_path rollback_plan_path decommissioning_plan_path model_card_path system_card_path model_providers models prompt_versions system_instruction_versions tools retrieval_sources embeddings datasets evaluation_datasets safety_filters fallback_behavior material_change_triggers required_metrics alert_thresholds monitoring_cadence reevaluation_cadence evaluation_task red_team_task production_exercise_task rollback_task decommission_task; do require_value "$field"; done
RISK_TIER="$(get_value risk_tier)"
case "$RISK_TIER" in low|medium|high|critical) ;; *) add_error 'ai_lifecycle.risk_tier must be low, medium, high, or critical.' ;; esac
RETENTION="$(get_value retention_days 0)"; [[ "$RETENTION" =~ ^[1-9][0-9]*$ ]] || add_error 'ai_lifecycle.retention_days must be a positive integer.'
for field in require_red_team require_production_exercise tool_authorization_required least_privilege_required rate_limit_required cost_limit_required input_validation_required output_validation_required safety_filter_required pii_handling_required audit_log_required human_escalation_required kill_switch_required safe_fallback_required; do [[ "$(get_value "$field")" == true ]] || add_error "ai_lifecycle.$field must be true."; done

for field in intended_uses prohibited_uses affected_communities applicable_laws model_providers models prompt_versions system_instruction_versions tools retrieval_sources embeddings datasets evaluation_datasets safety_filters material_change_triggers required_metrics alert_thresholds; do
    value="$(get_value "$field")"
    [[ "$value" == \[*\] ]] || add_error "ai_lifecycle.$field must be an inline YAML list."
    get_list "$field"
    (( ${#LIST_RESULT[@]} > 0 )) || add_error "ai_lifecycle.$field must not be empty."
done

PATH_FIELDS=(impact_assessment_path inventory_path evaluation_plan_path evaluation_report_path risk_disposition_path red_team_plan_path runtime_controls_path monitoring_plan_path rollback_plan_path decommissioning_plan_path model_card_path system_card_path)
for field in "${PATH_FIELDS[@]}"; do path="$(get_value "$field")"; safe_path "$path" || add_error "ai_lifecycle.$field must be repository-relative: $path"; done

require_document() {
    local field="$1" path content term
    shift
    path="$REPO_ROOT/$(get_value "$field")"
    if ! safe_path "$(get_value "$field")"; then return; fi
    [[ -f "$path" ]] || { add_error "Required AI lifecycle document is missing: $field"; return; }
    content="$(tr '[:upper:]' '[:lower:]' < "$path")"
    for term in "$@"; do printf '%s' "$content" | grep -Fqi "$term" || add_error "$field must document '$term'."; done
}
require_document impact_assessment_path intended use prohibited use affected harm law oversight contestability 'risk owner'
require_document inventory_path model provider prompt 'system instruction' tool retrieval embedding dataset 'evaluation dataset' 'safety filter' fallback license terms lineage retention 'change history'
require_document evaluation_plan_path representative adversarial 'task quality' reliability grounding hallucination misinformation privacy bias fairness robustness 'prompt injection' jailbreak 'insecure tool invocation' 'retrieval quality' refusal threshold latency cost release-blocking
require_document risk_disposition_path 'risk tier' 'risk owner' decision 'residual risk' mitigations approval
require_document red_team_plan_path 'prompt injection' 'sensitive information' 'supply chain' poisoning 'excessive agency' 'system-prompt' vector misinformation unbounded retest
require_document runtime_controls_path authentication authorization 'least-privilege' 'rate limit' 'cost limit' 'input validation' 'output validation' 'safety filter' pii 'audit log' escalation 'kill switch' fallback
require_document monitoring_plan_path quality safety drift adversarial cost latency 'tool actions' 'user feedback' disproportional threshold 'incident response' containment rollback communication cadence
require_document rollback_plan_path trigger 'kill switch' 'prompt rollback' 'model rollback' 'safe fallback' communication retest
require_document decommissioning_plan_path 'end-of-life' owner notification 'access revocation' 'data deletion' retention embedding credential decommission
require_document model_card_path provider model license terms intended prohibited 'data lineage' evaluation limitations safety privacy rollback
require_document system_card_path model prompt 'system instruction' tool retrieval embedding dataset 'safety filter' fallback affected limitation evaluation 'red-team' runtime monitoring appeal decommission

for field in evaluation_task red_team_task production_exercise_task rollback_task decommission_task; do task="$(get_value "$field")"; task_configured "$task" || add_error "Configured task '$task' for ai_lifecycle.$field is missing from tasks."; done

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$RECORD_DIRECTORY"
RECORD_PATH="$RECORD_DIRECTORY/ai-lifecycle-config-validation.json"
{
    printf '{"schema":1,"kind":"sdlc-ai-lifecycle-config-validation","command":"scripts/validate-ai-lifecycle.sh","commit_sha":'; json_escape "$(get_commit_sha)"; printf ',"timestamp":'; json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf ',"risk_tier":'; json_escape "$RISK_TIER";
    if (( ${#ERRORS[@]} == 0 )); then printf ',"exit_code":0,"result":"PASS"'; else printf ',"exit_code":1,"result":"FAIL"'; fi
    printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}\n'
} > "$RECORD_PATH"
(( ${#ERRORS[@]} == 0 )) || exit 1
echo '[PASS] AI lifecycle configuration is valid.'
exit 0
