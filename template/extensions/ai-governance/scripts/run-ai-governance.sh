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
		--help|-h) echo 'Usage: run-ai-governance.sh [--config-path PATH] [--repo-root PATH] [--spec-path PATH] [--evidence-directory PATH] [--record-spec]'; exit 0 ;;
		*) echo "[FAIL] Unknown option: $1"; exit 2 ;;
	esac
done

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ -z "$SPEC_PATH" ]]; then SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
[[ -f "$CONFIG_PATH" ]] || { echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; }

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value; value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
get_body() { awk '/^ai_governance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' <<< "$CONFIG_CONTENT"; }
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//"/\\"}"; value="${value//$'\r'/\r}"; value="${value//$'\n'/\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() { if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi; }
set_spec_field() { local key="$1" value="$2" temp="$SPEC_PATH.phase5.tmp"; [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }; if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi; mv "$temp" "$SPEC_PATH"; }

CONFIG_CONTENT="$(tr -d '\r' < "$CONFIG_PATH")"
BODY="$(get_body)"
if [[ -z "$BODY" || "$(get_value enabled false)" != true ]]; then echo '[SKIP] ai_governance.enabled is false.'; exit 0; fi

VALIDATOR="$SCRIPT_DIR/validate-ai-governance.sh"
bash "$VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
TASK_NAME="$(get_value evaluation_task)"
RUNNER="$REPO_ROOT/scripts/run-sdlc-task.sh"
[[ -f "$RUNNER" ]] || { echo "[FAIL] Task runner not found: $RUNNER"; exit 1; }
echo "[RUN] AI governance evaluation: $TASK_NAME"
set +e
bash "$RUNNER" --task "$TASK_NAME" --repo-root "$REPO_ROOT" --config-path "$CONFIG_PATH" --evidence-directory "$EVIDENCE_DIRECTORY"
TASK_EXIT=$?
set -e
if (( TASK_EXIT == 0 )); then RESULT='PASS'; else RESULT='FAIL'; fi
TASK_EVIDENCE="$REPO_ROOT/$EVIDENCE_DIRECTORY/$TASK_NAME.json"
SUMMARY_RELATIVE="$(get_value evaluation_evidence_path "$EVIDENCE_DIRECTORY/agent-evaluation.json")"
if [[ "$SUMMARY_RELATIVE" == /* || "$SUMMARY_RELATIVE" == ../* || "$SUMMARY_RELATIVE" == */../* || "$SUMMARY_RELATIVE" == '..' || "$SUMMARY_RELATIVE" =~ ^[A-Za-z]:/ ]]; then echo "[FAIL] evaluation_evidence_path must be repository-relative: $SUMMARY_RELATIVE"; exit 1; fi
SUMMARY_PATH="$REPO_ROOT/$SUMMARY_RELATIVE"
mkdir -p "$(dirname "$SUMMARY_PATH")"
ERRORS=(); (( TASK_EXIT == 0 )) || ERRORS+=("Evaluation task '$TASK_NAME' failed with exit code $TASK_EXIT.")
RELATIVE_TASK_EVIDENCE=''; [[ -f "$TASK_EVIDENCE" ]] && RELATIVE_TASK_EVIDENCE="${TASK_EVIDENCE:${#REPO_ROOT}}"; RELATIVE_TASK_EVIDENCE="${RELATIVE_TASK_EVIDENCE#/}"
{
	printf '{"schema":1,"kind":"sdlc-ai-agent-evaluation","command":"scripts/run-ai-governance.sh","task":'; json_escape "$TASK_NAME"; printf ',"commit_sha":'; json_escape "$(get_commit_sha)"; printf ',"tree_digest":'; json_escape "$(get_tree_digest)"; printf ',"evaluated_at":'; json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf ',"exit_code":%d,"result":' "$TASK_EXIT"; json_escape "$RESULT"; printf ',"evidence":'; json_escape "$RELATIVE_TASK_EVIDENCE"; printf ',"errors":'; json_array "${ERRORS[@]}"; printf '}
'
} > "$SUMMARY_PATH"
if (( RECORD_SPEC == 1 )); then
	COMMIT_SHA="$(get_commit_sha)"; TREE_DIGEST="$(get_tree_digest)"; TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; RELATIVE_SUMMARY="${SUMMARY_PATH:${#REPO_ROOT}}"; RELATIVE_SUMMARY="${RELATIVE_SUMMARY#/}"
	set_spec_field ai_governance_enabled true
	set_spec_field gate_ai_governance_command '"scripts/run-ai-governance.sh"'
	set_spec_field gate_ai_governance_commit_sha "\"$COMMIT_SHA\""
	set_spec_field gate_ai_governance_tree_digest "\"$TREE_DIGEST\""
	set_spec_field gate_ai_governance_timestamp "\"$TIMESTAMP\""
	set_spec_field gate_ai_governance_exit_code "$TASK_EXIT"
	set_spec_field gate_ai_governance_result "$RESULT"
	set_spec_field gate_ai_governance_evidence "\"$RELATIVE_SUMMARY\""
fi
if (( TASK_EXIT != 0 )); then echo '[FAIL] AI governance evaluation failed.'; exit 1; fi
echo "[PASS] AI governance evaluation complete: $SUMMARY_PATH"
exit 0