#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
TASK_ID=''
AGENT_ROLE=''
PROVIDER=''
MODEL=''
MODEL_VERSION=''
TENANT=''
REPOSITORY=''
DATA_CLASSIFICATION=''
INSTRUCTION_VERSION=''
SANDBOX_REFERENCE=''
PHASE=''
FINAL_DISPOSITION='PENDING'
TOOL_GRANTS=()
TOOL_CALLS=()
MCP_SERVERS=()
NETWORK_DESTINATIONS=()
CREDENTIAL_SCOPES=()
CHANGED_FILES=()
VALIDATIONS=()
HUMAN_APPROVALS=()
ACTIONS=()

while (($# > 0)); do
	case "$1" in
		--task-id) [[ $# -ge 2 ]] || { echo '[FAIL] --task-id requires a value.'; exit 2; }; TASK_ID="$2"; shift 2 ;;
		--agent-role) [[ $# -ge 2 ]] || { echo '[FAIL] --agent-role requires a value.'; exit 2; }; AGENT_ROLE="$2"; shift 2 ;;
		--provider) [[ $# -ge 2 ]] || { echo '[FAIL] --provider requires a value.'; exit 2; }; PROVIDER="$2"; shift 2 ;;
		--model) [[ $# -ge 2 ]] || { echo '[FAIL] --model requires a value.'; exit 2; }; MODEL="$2"; shift 2 ;;
		--model-version) [[ $# -ge 2 ]] || { echo '[FAIL] --model-version requires a value.'; exit 2; }; MODEL_VERSION="$2"; shift 2 ;;
		--tenant|--subscription) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; TENANT="$2"; shift 2 ;;
		--repository) [[ $# -ge 2 ]] || { echo '[FAIL] --repository requires a value.'; exit 2; }; REPOSITORY="$2"; shift 2 ;;
		--data-classification) [[ $# -ge 2 ]] || { echo '[FAIL] --data-classification requires a value.'; exit 2; }; DATA_CLASSIFICATION="$2"; shift 2 ;;
		--instruction-version) [[ $# -ge 2 ]] || { echo '[FAIL] --instruction-version requires a value.'; exit 2; }; INSTRUCTION_VERSION="$2"; shift 2 ;;
		--sandbox-reference|--sandbox) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; SANDBOX_REFERENCE="$2"; shift 2 ;;
		--phase) [[ $# -ge 2 ]] || { echo '[FAIL] --phase requires a value.'; exit 2; }; PHASE="$2"; shift 2 ;;
		--tool-grant|--permission) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; TOOL_GRANTS+=("$2"); shift 2 ;;
		--tool-call) [[ $# -ge 2 ]] || { echo '[FAIL] --tool-call requires a value.'; exit 2; }; TOOL_CALLS+=("$2"); shift 2 ;;
		--mcp-server) [[ $# -ge 2 ]] || { echo '[FAIL] --mcp-server requires a value.'; exit 2; }; MCP_SERVERS+=("$2"); shift 2 ;;
		--network-destination) [[ $# -ge 2 ]] || { echo '[FAIL] --network-destination requires a value.'; exit 2; }; NETWORK_DESTINATIONS+=("$2"); shift 2 ;;
		--credential-scope) [[ $# -ge 2 ]] || { echo '[FAIL] --credential-scope requires a value.'; exit 2; }; CREDENTIAL_SCOPES+=("$2"); shift 2 ;;
		--changed-file|--file) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; CHANGED_FILES+=("$2"); shift 2 ;;
		--validation|--validation-result) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; VALIDATIONS+=("$2"); shift 2 ;;
		--human-approval|--approval) [[ $# -ge 2 ]] || { echo "[FAIL] $1 requires a value."; exit 2; }; HUMAN_APPROVALS+=("$2"); shift 2 ;;
		--action) [[ $# -ge 2 ]] || { echo '[FAIL] --action requires a value.'; exit 2; }; ACTIONS+=("$2"); shift 2 ;;
		--final-disposition) [[ $# -ge 2 ]] || { echo '[FAIL] --final-disposition requires a value.'; exit 2; }; FINAL_DISPOSITION="$2"; shift 2 ;;
		--config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
		--repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
		--evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
		--help|-h) echo 'Usage: record-ai-change.sh --task-id ID --agent-role ROLE --provider PROVIDER --model MODEL --model-version VERSION --tenant TENANT --repository REPOSITORY --data-classification CLASS --instruction-version VERSION --phase PHASE --sandbox-reference REF --tool-grant TOOL --tool-call CALL --changed-file PATH --validation NAME=PASS --human-approval APPROVER|DECISION|REFERENCE [--action ACTION] [--final-disposition APPROVED|REJECTED|PENDING]'; exit 0 ;;
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
contains_or_wildcard() { local expected="$1" actual; shift; for actual in "$@"; do [[ "$actual" == "$expected" || "$actual" == '*' ]] && return 0; done; return 1; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//"/\\"}"; value="${value//$'\r'/\r}"; value="${value//$'\n'/\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() { if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi; }

VALIDATOR="$SCRIPT_DIR/validate-ai-governance.sh"
bash "$VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY" >/dev/null
CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"

ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
for item in TASK_ID AGENT_ROLE PROVIDER MODEL MODEL_VERSION TENANT REPOSITORY DATA_CLASSIFICATION INSTRUCTION_VERSION PHASE; do value="${!item}"; [[ -n "$value" ]] || add_error "--$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required."; done
[[ ${#TOOL_GRANTS[@]} -gt 0 ]] || add_error 'At least one --tool-grant is required.'
[[ ${#TOOL_CALLS[@]} -gt 0 ]] || add_error 'At least one --tool-call is required.'
[[ ${#CHANGED_FILES[@]} -gt 0 ]] || add_error 'At least one --changed-file is required.'
[[ ${#VALIDATIONS[@]} -gt 0 ]] || add_error 'At least one --validation result is required.'
case "$FINAL_DISPOSITION" in APPROVED|REJECTED|PENDING) ;; *) add_error "Unsupported final disposition: $FINAL_DISPOSITION" ;; esac
case "$PHASE" in GATHERING_REQS|DESIGN|PLANNING|CODING|REVIEW|TESTING|DEPLOYMENT_READINESS|DONE) ;; *) add_error "Unsupported phase: $PHASE" ;; esac

get_list approved_providers; PROVIDERS=("${LIST_RESULT[@]}")
get_list approved_models; MODELS=("${LIST_RESULT[@]}")
get_list approved_tenants; TENANTS=("${LIST_RESULT[@]}")
get_list permitted_repositories; REPOSITORIES=("${LIST_RESULT[@]}")
get_list allowed_data_classifications; CLASSIFICATIONS=("${LIST_RESULT[@]}")
get_list tool_allowlist; TOOLS=("${LIST_RESULT[@]}")
get_list mcp_server_allowlist; MCP_ALLOWLIST=("${LIST_RESULT[@]}")
get_list network_destination_allowlist; NETWORK_ALLOWLIST=("${LIST_RESULT[@]}")
get_list credential_scope_allowlist; CREDENTIAL_ALLOWLIST=("${LIST_RESULT[@]}")
get_list phase_tool_grants; PHASE_GRANTS=("${LIST_RESULT[@]}")
get_list restricted_actions; RESTRICTED_ACTIONS=("${LIST_RESULT[@]}")

contains "$PROVIDER" "${PROVIDERS[@]}" || add_error "Provider is not approved: $PROVIDER"
contains "$MODEL" "${MODELS[@]}" || add_error "Model is not approved: $MODEL"
contains "$TENANT" "${TENANTS[@]}" || add_error "Tenant or subscription is not approved: $TENANT"
contains_or_wildcard "$REPOSITORY" "${REPOSITORIES[@]}" || add_error "Repository is not permitted: $REPOSITORY"
contains "$DATA_CLASSIFICATION" "${CLASSIFICATIONS[@]}" || add_error "Data classification is not allowed: $DATA_CLASSIFICATION"
for grant in "${TOOL_GRANTS[@]}"; do contains "$grant" "${TOOLS[@]}" || add_error "Tool grant is not allowlisted: $grant"; done
for server in "${MCP_SERVERS[@]}"; do contains "$server" "${MCP_ALLOWLIST[@]}" || add_error "MCP server is not allowlisted: $server"; done
for destination in "${NETWORK_DESTINATIONS[@]}"; do contains "$destination" "${NETWORK_ALLOWLIST[@]}" || add_error "Network destination is not allowlisted: $destination"; done
for scope in "${CREDENTIAL_SCOPES[@]}"; do contains "$scope" "${CREDENTIAL_ALLOWLIST[@]}" || add_error "Credential scope is not allowlisted: $scope"; done
PHASE_GRANT=''
for grant in "${PHASE_GRANTS[@]}"; do [[ "$grant" == "$PHASE="* ]] && PHASE_GRANT="${grant#*=}"; done
[[ -n "$PHASE_GRANT" ]] || add_error "No phase tool grant is configured for: $PHASE"
IFS='|' read -r -a PHASE_TOOLS <<< "$PHASE_GRANT"
PHASE_SCOPE_BREACH=0
for grant in "${TOOL_GRANTS[@]}"; do contains "$grant" "${PHASE_TOOLS[@]}" || PHASE_SCOPE_BREACH=1; done
for file in "${CHANGED_FILES[@]}"; do safe_path "$file" || add_error "Changed file must be a safe repository-relative path: $file"; [[ "$file" != */ ]] || add_error "Changed file must be an exact file, not a directory: $file"; done

APPROVAL_JSON=''
APPROVED_APPROVALS=0
for approval in "${HUMAN_APPROVALS[@]}"; do
	IFS='|' read -r approver decision reference approval_time extra <<< "$approval"
	[[ -n "$approver" && -n "$decision" && -n "$reference" && -z "${extra-}" ]] || { add_error 'Human approval must use approver|DECISION|reference[|timestamp].'; continue; }
	[[ -n "$approval_time" ]] || approval_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	case "$decision" in APPROVED) (( APPROVED_APPROVALS += 1 )) ;; REJECTED|PENDING) ;; *) add_error "Unsupported human approval decision: $decision" ;; esac
	approval_object="$(printf '{"approver":%s,"decision":%s,"reference":%s,"timestamp":%s}' "$(json_escape "$approver")" "$(json_escape "$decision")" "$(json_escape "$reference")" "$(json_escape "$approval_time")")"
	[[ -z "$APPROVAL_JSON" ]] && APPROVAL_JSON="$approval_object" || APPROVAL_JSON+=" ,$approval_object"
done

VALIDATION_JSON=''
VALIDATION_FAILURE=0
for validation in "${VALIDATIONS[@]}"; do
	if [[ "$validation" == *=* ]]; then validation_name="${validation%%=*}"; validation_result="${validation#*=}"; else validation_name="$validation"; validation_result='PASS'; fi
	[[ -n "$validation_name" ]] || { add_error 'Validation names cannot be empty.'; continue; }
	case "$validation_result" in PASS) ;; FAIL|CHANGES_REQUESTED) VALIDATION_FAILURE=1 ;; *) add_error "Unsupported validation result: $validation_result" ;; esac
	validation_object="$(printf '{"name":%s,"result":%s}' "$(json_escape "$validation_name")" "$(json_escape "$validation_result")")"
	[[ -z "$VALIDATION_JSON" ]] && VALIDATION_JSON="$validation_object" || VALIDATION_JSON+=" ,$validation_object"
done

if (( PHASE_SCOPE_BREACH == 1 && APPROVED_APPROVALS == 0 )); then add_error "Tool grant is outside the '$PHASE' phase boundary and requires an APPROVED widening decision."; fi
if (( PHASE_SCOPE_BREACH == 1 && APPROVED_APPROVALS > 0 )); then ACTIONS+=(phase_scope_widened); fi
RESTRICTED_ACTION=0
for action in "${ACTIONS[@]}"; do contains "$action" "${RESTRICTED_ACTIONS[@]}" && RESTRICTED_ACTION=1; done
if (( RESTRICTED_ACTION == 1 && APPROVED_APPROVALS == 0 )); then add_error 'Restricted actions require an APPROVED human approval.'; fi
if [[ "$FINAL_DISPOSITION" != PENDING && ${#HUMAN_APPROVALS[@]} -eq 0 ]]; then add_error 'A final disposition requires a human approval record.'; fi
if [[ "$FINAL_DISPOSITION" == APPROVED && ( $APPROVED_APPROVALS -eq 0 || $VALIDATION_FAILURE -eq 1 ) ]]; then add_error 'APPROVED disposition requires an approved human decision and all validations to PASS.'; fi
if [[ "$(get_value sandbox_required false)" == true && -z "$SANDBOX_REFERENCE" ]]; then add_error 'sandbox_reference is required by ai_governance.sandbox_required.'; fi

LEDGER_PATH="$(get_value ledger_path)"
safe_path "$LEDGER_PATH" || add_error "ai_governance.ledger_path must be repository-relative: $LEDGER_PATH"
if (( ${#ERRORS[@]} > 0 )); then exit 1; fi

LEDGER_FULL_PATH="$REPO_ROOT/$LEDGER_PATH"
mkdir -p "$(dirname "$LEDGER_FULL_PATH")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
	printf '{"schema":1,"kind":"sdlc-ai-change-ledger","task_id":'; json_escape "$TASK_ID"; printf ',"agent_role":'; json_escape "$AGENT_ROLE"; printf ',"provider":'; json_escape "$PROVIDER"; printf ',"model":'; json_escape "$MODEL"; printf ',"model_version":'; json_escape "$MODEL_VERSION"; printf ',"tenant":'; json_escape "$TENANT"; printf ',"repository":'; json_escape "$REPOSITORY"; printf ',"data_classification":'; json_escape "$DATA_CLASSIFICATION"; printf ',"instruction_version":'; json_escape "$INSTRUCTION_VERSION"; printf ',"sandbox_reference":'; json_escape "$SANDBOX_REFERENCE"; printf ',"tool_grants":'; json_array "${TOOL_GRANTS[@]}"; printf ',"tool_calls":'; json_array "${TOOL_CALLS[@]}"; printf ',"mcp_servers":'; json_array "${MCP_SERVERS[@]}"; printf ',"network_destinations":'; json_array "${NETWORK_DESTINATIONS[@]}"; printf ',"credential_scopes":'; json_array "${CREDENTIAL_SCOPES[@]}"; printf ',"changed_files":'; json_array "${CHANGED_FILES[@]}"; printf ',"human_approvals":[%s],"validations":[%s],"actions":' "$APPROVAL_JSON" "$VALIDATION_JSON"; json_array "${ACTIONS[@]}"; printf ',"final_disposition":'; json_escape "$FINAL_DISPOSITION"; printf ',"commit_sha":'; json_escape "$(get_commit_sha)"; printf ',"tree_digest":'; json_escape "$(get_tree_digest)"; printf ',"recorded_at":'; json_escape "$TIMESTAMP"; printf '}
'
} | sed "s/{\"schema\":1/{\"schema\":1,\"phase\":\"$PHASE\"/" >> "$LEDGER_FULL_PATH"
echo "[PASS] AI change recorded: $LEDGER_PATH"
exit 0