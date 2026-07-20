#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
INCIDENT_REFERENCE=''
SEVERITY=''
SUMMARY=''
IMPACT=''
ACTION_OWNER=''
DUE_DATE=''
STATUS='OPEN'
REVIEWER=''
CLOSURE_DECISION=''
CORRECTIVE_ACTIONS=()

while (($# > 0)); do
    case "$1" in
        --incident-reference) [[ $# -ge 2 ]] || { echo '[FAIL] --incident-reference requires a value.'; exit 2; }; INCIDENT_REFERENCE="$2"; shift 2 ;;
        --severity) [[ $# -ge 2 ]] || { echo '[FAIL] --severity requires a value.'; exit 2; }; SEVERITY="$2"; shift 2 ;;
        --summary) [[ $# -ge 2 ]] || { echo '[FAIL] --summary requires a value.'; exit 2; }; SUMMARY="$2"; shift 2 ;;
        --impact) [[ $# -ge 2 ]] || { echo '[FAIL] --impact requires a value.'; exit 2; }; IMPACT="$2"; shift 2 ;;
        --corrective-action) [[ $# -ge 2 ]] || { echo '[FAIL] --corrective-action requires a value.'; exit 2; }; CORRECTIVE_ACTIONS+=("$2"); shift 2 ;;
        --action-owner) [[ $# -ge 2 ]] || { echo '[FAIL] --action-owner requires a value.'; exit 2; }; ACTION_OWNER="$2"; shift 2 ;;
        --due-date) [[ $# -ge 2 ]] || { echo '[FAIL] --due-date requires a value.'; exit 2; }; DUE_DATE="$2"; shift 2 ;;
        --status) [[ $# -ge 2 ]] || { echo '[FAIL] --status requires a value.'; exit 2; }; STATUS="$2"; shift 2 ;;
        --reviewer) [[ $# -ge 2 ]] || { echo '[FAIL] --reviewer requires a value.'; exit 2; }; REVIEWER="$2"; shift 2 ;;
        --closure-decision) [[ $# -ge 2 ]] || { echo '[FAIL] --closure-decision requires a value.'; exit 2; }; CLOSURE_DECISION="$2"; shift 2 ;;
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --help|-h) echo 'Usage: record-incident-review.sh --incident-reference REF --severity sev1|sev2|sev3|sev4 --summary TEXT --impact TEXT --corrective-action TEXT --action-owner OWNER --due-date YYYY-MM-DD [--status OPEN|CLOSED]'; exit 0 ;;
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
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }

BODY="$(get_body)"
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] Operational readiness is disabled.'; exit 0; fi
[[ -n "$INCIDENT_REFERENCE" && -n "$SUMMARY" && -n "$IMPACT" && -n "$ACTION_OWNER" && -n "$DUE_DATE" && ${#CORRECTIVE_ACTIONS[@]} -gt 0 ]] || { echo '[FAIL] Incident reference, summary, impact, corrective action, owner, and due date are required.'; exit 1; }
[[ "$DUE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo '[FAIL] due-date must use YYYY-MM-DD.'; exit 1; }
[[ "$STATUS" == OPEN || "$STATUS" == CLOSED ]] || { echo "[FAIL] Unsupported incident status: $STATUS"; exit 1; }
if [[ "$STATUS" == CLOSED && ( -z "$REVIEWER" || -z "$CLOSURE_DECISION" ) ]]; then echo '[FAIL] Closed incident reviews require reviewer and closure decision.'; exit 1; fi
get_list incident_severities; configured=0; for item in "${LIST_RESULT[@]}"; do [[ "$item" == "$SEVERITY" ]] && configured=1; done; (( configured == 1 )) || { echo "[FAIL] Severity '$SEVERITY' is not configured."; exit 1; }
INCIDENT_PATH="$(get_value incident_record_path)"; safe_path "$INCIDENT_PATH" || { echo "[FAIL] incident_record_path must be repository-relative: $INCIDENT_PATH"; exit 1; }
mkdir -p "$REPO_ROOT/$(dirname "$INCIDENT_PATH")"; ACTIONS=''; for item in "${CORRECTIVE_ACTIONS[@]}"; do escaped="$(json_escape "$item")"; [[ -z "$ACTIONS" ]] && ACTIONS="$escaped" || ACTIONS+=",$escaped"; done
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{ printf '{"schema":1,"kind":"sdlc-incident-review","incident_reference":'; json_escape "$INCIDENT_REFERENCE"; printf ',"severity":'; json_escape "$SEVERITY"; printf ',"status":'; json_escape "$STATUS"; printf ',"service":'; json_escape "$(get_value service_name)"; printf ',"summary":'; json_escape "$SUMMARY"; printf ',"impact":'; json_escape "$IMPACT"; printf ',"corrective_actions":[%s],"action_owner":' "$ACTIONS"; json_escape "$ACTION_OWNER"; printf ',"due_date":'; json_escape "$DUE_DATE"; printf ',"reviewer":'; json_escape "$REVIEWER"; printf ',"closure_decision":'; json_escape "$CLOSURE_DECISION"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"recorded_at":'; json_escape "$TIMESTAMP"; printf ',"result":"PASS","exit_code":0}\n'; } > "$REPO_ROOT/$INCIDENT_PATH"
echo "[PASS] Incident review recorded: $REPO_ROOT/$INCIDENT_PATH"
exit 0
