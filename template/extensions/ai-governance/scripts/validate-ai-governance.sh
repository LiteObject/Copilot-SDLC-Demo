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
		--help|-h) echo 'Usage: validate-ai-governance.sh [--config-path PATH] [--repo-root PATH] [--evidence-directory PATH]'; exit 0 ;;
		*) echo "[FAIL] Unknown option: $1"; exit 2 ;;
	esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value; value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^ai_governance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
contains() { local expected="$1" actual; shift; for actual in "$@"; do [[ "$actual" == "$expected" ]] && return 0; done; return 1; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
task_configured() { local task="$1"; [[ -n "$task" ]] && grep -Eq "^  ${task}:[[:space:]]*$" <<< "$CONFIG_CONTENT"; }
normalize_action() { local value="${1,,}"; value="${value//-/_}"; case "$value" in inspect) printf 'read' ;; execute|run_command) printf 'command' ;; validation) printf 'full_validation' ;; create_branch) printf 'branch' ;; create_pr) printf 'pull_request' ;; update_pr) printf 'pull_request_update' ;; network|new_network_destination) printf 'network_access' ;; rotate_credentials) printf 'credential_rotation' ;; production_configuration) printf 'production_config' ;; *) printf '%s' "$value" ;; esac; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//"/\\"}"; value="${value//$'\r'/\r}"; value="${value//$'\n'/\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"
if [[ -z "$BODY" ]]; then echo '[SKIP] ai_governance is not configured.'; exit 0; fi
[[ "$(get_value enabled false)" == true ]] || { echo '[SKIP] ai_governance.enabled is false.'; exit 0; }

BASE_VALIDATOR="$REPO_ROOT/scripts/validate-sdlc-config.sh"
if [[ -f "$BASE_VALIDATOR" ]]; then bash "$BASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" || exit $?; fi

ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
require_value() { local field="$1"; [[ -n "$(get_value "$field")" ]] || add_error "ai_governance.$field is required."; }
for field in policy_path permissions_path threat_model_path evaluation_plan_path evaluation_scenarios_path ledger_path evaluation_evidence_path approved_providers approved_models approved_tenants permitted_repositories allowed_data_classifications prohibited_inputs tool_allowlist mcp_server_allowlist network_destination_allowlist credential_scope_allowlist phase_tool_grants restricted_actions approval_required_actions sandbox_type untrusted_input_policy autonomy_level policy_version policy_expires_at max_iterations max_changed_files allowed_branches action_classes approval_requirements approval_expiration_hours evaluation_task; do require_value "$field"; done
for field in sandbox_required command_confirmation_required; do value="$(get_value "$field")"; [[ "$value" == true || "$value" == false ]] || add_error "ai_governance.$field must be true or false."; done
[[ "$(get_value sandbox_required)" != true || "$(get_value sandbox_type)" != none ]] || add_error 'sandbox_type must not be none when sandbox_required is true.'
case "$(get_value sandbox_type)" in worktree|container|vm|none) ;; *) add_error 'sandbox_type must be worktree, container, vm, or none.' ;; esac
[[ "$(get_value command_confirmation_required)" == true ]] || add_error 'command_confirmation_required must be true.'
[[ "$(get_value untrusted_input_policy)" == treat_as_data ]] || add_error 'untrusted_input_policy must be treat_as_data.'
case "$(get_value autonomy_level)" in L0|L1|L2|L3|L4) ;; *) add_error 'autonomy_level must be L0, L1, L2, L3, or L4.' ;; esac
[[ "$(get_value policy_version)" != '' ]] || add_error 'policy_version must not be empty.'
POLICY_EXPIRES_AT="$(get_value policy_expires_at)"; [[ "$POLICY_EXPIRES_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || add_error 'policy_expires_at must be an ISO-8601 UTC timestamp ending in Z.'
if [[ "$POLICY_EXPIRES_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
	POLICY_EXPIRY_EPOCH="$(date -u -d "$POLICY_EXPIRES_AT" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$POLICY_EXPIRES_AT" +%s 2>/dev/null || true)"
	[[ -n "$POLICY_EXPIRY_EPOCH" && "$POLICY_EXPIRY_EPOCH" -gt "$(date -u +%s)" ]] || add_error 'policy_expires_at has expired or is not a valid UTC timestamp.'
fi
MAX_ITERATIONS="$(get_value max_iterations)"; [[ "$MAX_ITERATIONS" =~ ^[1-9][0-9]*$ ]] || add_error 'max_iterations must be a positive integer.'
MAX_CHANGED_FILES="$(get_value max_changed_files)"; [[ "$MAX_CHANGED_FILES" =~ ^[0-9]+$ ]] || add_error 'max_changed_files must be a non-negative integer.'
APPROVAL_EXPIRATION_HOURS="$(get_value approval_expiration_hours)"; [[ "$APPROVAL_EXPIRATION_HOURS" =~ ^[1-9][0-9]*$ ]] || add_error 'approval_expiration_hours must be a positive integer.'
RETENTION="$(get_value audit_retention_days "$(get_value retention_days)")"; [[ "$RETENTION" =~ ^[1-9][0-9]*$ ]] || add_error 'audit_retention_days must be a positive integer.'

get_list approved_providers; PROVIDERS=("${LIST_RESULT[@]}")
get_list approved_models; MODELS=("${LIST_RESULT[@]}")
get_list approved_tenants; TENANTS=("${LIST_RESULT[@]}")
get_list permitted_repositories; REPOSITORIES=("${LIST_RESULT[@]}")
get_list allowed_data_classifications; CLASSIFICATIONS=("${LIST_RESULT[@]}")
get_list prohibited_inputs; PROHIBITED=("${LIST_RESULT[@]}")
get_list tool_allowlist; TOOLS=("${LIST_RESULT[@]}")
get_list phase_tool_grants; GRANTS=("${LIST_RESULT[@]}")
get_list restricted_actions; RESTRICTED=("${LIST_RESULT[@]}")
get_list approval_required_actions; APPROVALS=("${LIST_RESULT[@]}")
get_list allowed_branches; ALLOWED_BRANCHES=("${LIST_RESULT[@]}")
get_list action_classes; ACTION_CLASSES=("${LIST_RESULT[@]}")
get_list approval_requirements; APPROVAL_REQUIREMENTS=("${LIST_RESULT[@]}")
for field in approved_providers approved_models approved_tenants permitted_repositories allowed_data_classifications prohibited_inputs tool_allowlist mcp_server_allowlist network_destination_allowlist credential_scope_allowlist phase_tool_grants restricted_actions approval_required_actions allowed_branches action_classes approval_requirements; do value="$(get_value "$field")"; [[ "$value" == \[*\] ]] || add_error "ai_governance.$field must be an inline YAML list."; done
(( ${#PROVIDERS[@]} > 0 )) || add_error 'approved_providers must not be empty.'
(( ${#MODELS[@]} > 0 )) || add_error 'approved_models must not be empty.'
(( ${#TENANTS[@]} > 0 )) || add_error 'approved_tenants must not be empty.'
(( ${#REPOSITORIES[@]} > 0 )) || add_error 'permitted_repositories must not be empty.'
for item in public internal; do contains "$item" "${CLASSIFICATIONS[@]}" || add_error "allowed_data_classifications must include '$item'."; done
for item in secrets credentials personal_data untrusted_instructions; do contains "$item" "${PROHIBITED[@]}" || add_error "prohibited_inputs must include '$item'."; done
for item in read search; do contains "$item" "${TOOLS[@]}" || add_error "tool_allowlist must include '$item'."; done
for item in commit merge deploy rotate_credentials production_config; do contains "$item" "${RESTRICTED[@]}" || add_error "restricted_actions must include '$item'."; contains "$item" "${APPROVALS[@]}" || add_error "approval_required_actions must include '$item'."; done
KNOWN_ACTIONS=(read analyze propose edit command local_validation full_validation branch pull_request pull_request_update network_access maintenance_batch commit merge deploy production_config credential_rotation secret_access policy_change)
NORMALIZED_CLASSES=(); for action in "${ACTION_CLASSES[@]}"; do normalized="$(normalize_action "$action")"; NORMALIZED_CLASSES+=("$normalized"); contains "$normalized" "${KNOWN_ACTIONS[@]}" || add_error "Unsupported action class: $normalized."; done
for branch in "${ALLOWED_BRANCHES[@]}"; do [[ -n "$branch" && ! "$branch" =~ [[:space:]] && "$branch" != *..* ]] || add_error "Invalid allowed branch pattern: $branch."; done
for entry in "${APPROVAL_REQUIREMENTS[@]}"; do [[ "$entry" =~ ^([^=]+)=(human|policy|none)$ ]] || add_error "Invalid approval requirement: $entry."; done
for action in "${RESTRICTED[@]}"; do normalized="$(normalize_action "$action")"; contains "$normalized" "${NORMALIZED_CLASSES[@]}" || add_error "Restricted action must be listed in action_classes: $normalized."; contains "$action" "${APPROVALS[@]}" || contains "$normalized" "${APPROVALS[@]}" || add_error "Restricted action must require approval: $normalized."; requirement_found=0; for entry in "${APPROVAL_REQUIREMENTS[@]}"; do [[ "$(normalize_action "${entry%%=*}")" == "$normalized" && "${entry#*=}" == human ]] && requirement_found=1; done; (( requirement_found == 1 )) || add_error "Restricted action must have a human approval requirement: $normalized."; done
for grant in "${GRANTS[@]}"; do [[ "$grant" =~ ^[A-Z_]+=.+$ ]] || add_error "Invalid phase_tool_grants entry: $grant"; done
for phase in GATHERING_REQS PLANNING CODING REVIEW TESTING DEPLOYMENT_READINESS; do found=0; for grant in "${GRANTS[@]}"; do [[ "$grant" == "$phase="* ]] && found=1; done; (( found == 1 )) || add_error "phase_tool_grants must define '$phase'."; done

for field in policy_path permissions_path threat_model_path evaluation_plan_path evaluation_scenarios_path ledger_path evaluation_evidence_path; do path="$(get_value "$field")"; safe_path "$path" || add_error "ai_governance.$field must be repository-relative: $path"; done
require_document() { local field="$1"; shift; local path="$REPO_ROOT/$(get_value "$field")" term content; [[ -f "$path" ]] || { add_error "Required governance document is missing: $field"; return; }; content="$(tr '[:upper:]' '[:lower:]' < "$path")"; for term in "$@"; do printf '%s' "$content" | grep -Fqi "$term" || add_error "$field must document '$term'."; done; }
require_document policy_path provider model retention intellectual approval
require_document permissions_path tool mcp network credential least privilege phase
require_document threat_model_path 'prompt injection' untrusted command secret
require_document evaluation_plan_path 'planning accuracy' 'test quality' 'security-finding precision' scope 'human rework'
require_document evaluation_scenarios_path prompt-injection unsafe-tool-use
EVALUATION_TASK="$(get_value evaluation_task)"; task_configured "$EVALUATION_TASK" || add_error "Configured task '$EVALUATION_TASK' for ai_governance.evaluation_task is missing from tasks."

RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"; mkdir -p "$RECORD_DIRECTORY"; RECORD_PATH="$RECORD_DIRECTORY/ai-governance-config-validation.json"
{
	printf '{"schema":1,"kind":"sdlc-ai-governance-config-validation","command":"scripts/validate-ai-governance.sh","commit_sha":'; json_escape "$(get_commit_sha)"; printf ',"timestamp":'; json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; if (( ${#ERRORS[@]} == 0 )); then printf ',"exit_code":0,"result":"PASS"'; else printf ',"exit_code":1,"result":"FAIL"'; fi; printf ',"approved_providers":'; json_array "${PROVIDERS[@]}"; printf ',"approved_models":'; json_array "${MODELS[@]}"; printf ',"tools":'; json_array "${TOOLS[@]}"; printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}
'
} > "$RECORD_PATH"
(( ${#ERRORS[@]} == 0 )) || exit 1
echo '[PASS] AI governance configuration is valid.'
exit 0