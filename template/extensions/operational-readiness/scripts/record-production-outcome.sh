#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
RELEASE_REFERENCE=''
ENVIRONMENT=''
TECHNICAL_RESULT=''
BUSINESS_RESULT=''
BUSINESS_OUTCOME=''
USER_FEEDBACK=''
INCIDENT_REFERENCE=''
ROLLBACK_USED=false

while (($# > 0)); do
    case "$1" in
        --release-reference) [[ $# -ge 2 ]] || { echo '[FAIL] --release-reference requires a value.'; exit 2; }; RELEASE_REFERENCE="$2"; shift 2 ;;
        --environment) [[ $# -ge 2 ]] || { echo '[FAIL] --environment requires a value.'; exit 2; }; ENVIRONMENT="$2"; shift 2 ;;
        --technical-result) [[ $# -ge 2 ]] || { echo '[FAIL] --technical-result requires a value.'; exit 2; }; TECHNICAL_RESULT="$2"; shift 2 ;;
        --business-result) [[ $# -ge 2 ]] || { echo '[FAIL] --business-result requires a value.'; exit 2; }; BUSINESS_RESULT="$2"; shift 2 ;;
        --business-outcome) [[ $# -ge 2 ]] || { echo '[FAIL] --business-outcome requires a value.'; exit 2; }; BUSINESS_OUTCOME="$2"; shift 2 ;;
        --user-feedback) [[ $# -ge 2 ]] || { echo '[FAIL] --user-feedback requires a value.'; exit 2; }; USER_FEEDBACK="$2"; shift 2 ;;
        --incident-reference) [[ $# -ge 2 ]] || { echo '[FAIL] --incident-reference requires a value.'; exit 2; }; INCIDENT_REFERENCE="$2"; shift 2 ;;
        --rollback-used) ROLLBACK_USED=true; shift ;;
        --config-path) [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }; CONFIG_PATH="$2"; shift 2 ;;
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --help|-h) echo 'Usage: record-production-outcome.sh --release-reference REF --environment ENV --technical-result RESULT --business-result RESULT --business-outcome TEXT --user-feedback TEXT [--incident-reference REF] [--rollback-used] [--repo-root PATH]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^operational_readiness:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$CONFIG_PATH"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
safe_path() { local path="$1"; [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }

BODY="$(get_body)"
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] Operational readiness is disabled.'; exit 0; fi
[[ -n "$RELEASE_REFERENCE" && -n "$BUSINESS_OUTCOME" && -n "$USER_FEEDBACK" ]] || { echo '[FAIL] Release reference, business outcome, and user feedback are required.'; exit 1; }
case "$ENVIRONMENT" in development|test|staging|production) ;; *) echo "[FAIL] Unsupported environment: $ENVIRONMENT"; exit 1 ;; esac
case "$TECHNICAL_RESULT" in PASS|FAIL|PARTIAL) ;; *) echo "[FAIL] Unsupported technical result: $TECHNICAL_RESULT"; exit 1 ;; esac
case "$BUSINESS_RESULT" in PASS|FAIL|PARTIAL) ;; *) echo "[FAIL] Unsupported business result: $BUSINESS_RESULT"; exit 1 ;; esac
FEEDBACK_PATH="$(get_value feedback_path)"; safe_path "$FEEDBACK_PATH" || { echo "[FAIL] feedback_path must be repository-relative: $FEEDBACK_PATH"; exit 1; }
mkdir -p "$REPO_ROOT/$(dirname "$FEEDBACK_PATH")"
if [[ "$TECHNICAL_RESULT" == PASS && "$BUSINESS_RESULT" == PASS ]]; then RESULT='PASS'; EXIT_CODE=0; else RESULT='FAIL'; EXIT_CODE=1; fi
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{ printf '{"schema":1,"kind":"sdlc-production-outcome","release_reference":'; json_escape "$RELEASE_REFERENCE"; printf ',"environment":'; json_escape "$ENVIRONMENT"; printf ',"service":'; json_escape "$(get_value service_name)"; printf ',"technical_result":'; json_escape "$TECHNICAL_RESULT"; printf ',"business_result":'; json_escape "$BUSINESS_RESULT"; printf ',"business_outcome":'; json_escape "$BUSINESS_OUTCOME"; printf ',"user_feedback":'; json_escape "$USER_FEEDBACK"; printf ',"incident_reference":'; json_escape "$INCIDENT_REFERENCE"; printf ',"rollback_used":%s,"commit_sha":' "$ROLLBACK_USED"; json_escape "$COMMIT_SHA"; printf ',"recorded_at":'; json_escape "$TIMESTAMP"; printf ',"result":'; json_escape "$RESULT"; printf ',"exit_code":%d}\n' "$EXIT_CODE"; } > "$REPO_ROOT/$FEEDBACK_PATH"
if (( EXIT_CODE != 0 )); then echo "[FAIL] Production outcome is not successful: $FEEDBACK_PATH"; exit 1; fi
echo "[PASS] Production outcome recorded: $REPO_ROOT/$FEEDBACK_PATH"
exit 0
