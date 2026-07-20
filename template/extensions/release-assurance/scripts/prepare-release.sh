#!/usr/bin/env bash
# Build and record a traceable release bundle.

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
        --help|-h) echo 'Usage: prepare-release.sh [--config-path PATH] [--repo-root PATH] [--spec-path PATH] [--record-spec]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done
if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ -z "$SPEC_PATH" ]]; then SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo "[FAIL] Config not found: $CONFIG_PATH"; exit 1; fi

trim_value() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"; printf '%s' "$value"; }
unquote_value() { local value="$(trim_value "$1")"; if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then value="${value:1:${#value}-2}"; elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then value="${value:1:${#value}-2}"; else value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"; fi; printf '%s' "$value"; }
RELEASE_BODY="$(awk '/^release_assurance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found{print}' "$CONFIG_PATH")"
if [[ -z "$RELEASE_BODY" ]]; then echo '[SKIP] Release assurance is not configured.'; exit 0; fi
get_value() { local field="$1" default="${2-}" value; value="$(printf '%s\n' "$RELEASE_BODY" | sed -nE "s/^[[:space:]]+$field:[[:space:]]*(.*)$/\1/p" | head -n1)"; value="$(unquote_value "$value")"; [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$default"; }
get_list() { local field="$1" value item; value="$(get_value "$field")"; LIST_RESULT=(); [[ "$value" == \[*\] ]] || return 0; value="${value:1:${#value}-2}"; IFS=',' read -r -a raw <<< "$value"; for item in "${raw[@]}"; do item="$(unquote_value "$item")"; [[ -n "$item" ]] && LIST_RESULT+=("$item"); done; }
if [[ "$(get_value enabled false)" != true ]]; then echo '[SKIP] Release assurance is disabled.'; exit 0; fi

RELEASE_VALIDATOR="$SCRIPT_DIR/validate-release-config.sh"
bash "$RELEASE_VALIDATOR" --config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"
RUNNER="$REPO_ROOT/scripts/run-sdlc-task.sh"
RELEASE_DIR="$REPO_ROOT/.sdlc/release"
mkdir -p "$RELEASE_DIR"
run_task() { local task="$1"; args=(--task "$task" --repo-root "$REPO_ROOT" --evidence-directory "$EVIDENCE_DIRECTORY"); (( RECORD_SPEC == 1 )) && args+=(--spec-path "$SPEC_PATH" --record-spec); bash "$RUNNER" "${args[@]}"; }
ARTIFACT_PATH="$REPO_ROOT/$(get_value artifact_path)"
SBOM_PATH="$REPO_ROOT/$(get_value sbom_path)"
PROVENANCE_PATH="$REPO_ROOT/$(get_value provenance_path)"
RELEASE_NOTES_PATH="$REPO_ROOT/$(get_value release_notes_path)"
ROLLBACK_PATH="$REPO_ROOT/$(get_value rollback_instructions_path)"
run_task "$(get_value artifact_task)"
[[ -f "$ARTIFACT_PATH" ]] || { echo "[FAIL] Artifact was not produced: $ARTIFACT_PATH"; exit 1; }
run_task "$(get_value sbom_task)"
[[ -f "$SBOM_PATH" ]] || { echo "[FAIL] SBOM was not produced: $SBOM_PATH"; exit 1; }
SBOM_FORMAT="$(get_value sbom_format)"
if [[ "$SBOM_FORMAT" == cyclonedx-json ]] && ! grep -Eiq '"bomFormat"[[:space:]]*:[[:space:]]*"CycloneDX"' "$SBOM_PATH"; then echo '[FAIL] SBOM is not a CycloneDX JSON document.'; exit 1; fi
if [[ "$SBOM_FORMAT" == spdx-json ]] && ! grep -Eiq '"spdxVersion"[[:space:]]*:' "$SBOM_PATH"; then echo '[FAIL] SBOM is not an SPDX JSON document.'; exit 1; fi
if [[ "$(get_value require_signed_artifact)" == true ]]; then run_task "$(get_value signing_task)"; [[ -f "$REPO_ROOT/$(get_value signature_path)" ]] || { echo '[FAIL] Signature was not produced.'; exit 1; }; fi
[[ -f "$RELEASE_NOTES_PATH" ]] || { echo "[FAIL] Release notes are required: $RELEASE_NOTES_PATH"; exit 1; }
[[ -f "$ROLLBACK_PATH" ]] || { echo "[FAIL] Rollback instructions are required: $ROLLBACK_PATH"; exit 1; }

sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
TREE_DIGEST="$(git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256_file /dev/stdin)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARTIFACT_REL="${ARTIFACT_PATH#"$REPO_ROOT/"}"
SBOM_REL="${SBOM_PATH#"$REPO_ROOT/"}"
PROVENANCE_REL="${PROVENANCE_PATH#"$REPO_ROOT/"}"
ARTIFACT_SHA="$(sha256_file "$ARTIFACT_PATH")"
SBOM_SHA="$(sha256_file "$SBOM_PATH")"
REMOTE_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
cat > "$PROVENANCE_PATH" <<EOF
{"_type":"https://in-toto.io/Statement/v1","subject":[{"name":"$ARTIFACT_REL","digest":{"sha256":"$ARTIFACT_SHA"}}],"predicateType":"https://slsa.dev/provenance/v1","predicate":{"buildDefinition":{"buildType":"https://github.com/copilot-sdlc/release","externalParameters":{"repository":"$REMOTE_URL","revision":"$COMMIT_SHA"},"resolvedDependencies":[{"uri":"git","digest":{"sha1":"$COMMIT_SHA"}}]},"runDetails":{"builder":{"id":"copilot-sdlc/release-assurance"},"metadata":{"startedOn":"$TIMESTAMP","finishedOn":"$TIMESTAMP"}}}}
EOF
get_list promotion_environments; ENVIRONMENTS=("${LIST_RESULT[@]}"); get_list required_approvals; APPROVALS=("${LIST_RESULT[@]}")
MANIFEST_PATH="$RELEASE_DIR/release-manifest.json"
{
    printf '{"schema":1,"kind":"sdlc-release-manifest","version":'; json_escape "${GITHUB_REF_NAME:-${COMMIT_SHA:0:12}}"; printf ',"source_commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"source_tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"created_at":'; json_escape "$TIMESTAMP"; printf ',"artifact":{"path":'; json_escape "$ARTIFACT_REL"; printf ',"sha256":'; json_escape "$ARTIFACT_SHA"; printf ',"bytes":%s},"sbom":{"path":' "$(wc -c < "$ARTIFACT_PATH")"; json_escape "$SBOM_REL"; printf ',"sha256":'; json_escape "$SBOM_SHA"; printf ',"format":'; json_escape "$SBOM_FORMAT"; printf '},"provenance":{"path":'; json_escape "$PROVENANCE_REL"; printf '},"promotion_environments":'; json_array "${ENVIRONMENTS[@]}"; printf ',"required_approvals":'; json_array "${APPROVALS[@]}"; printf '}\n'
} > "$MANIFEST_PATH"
if (( RECORD_SPEC == 1 )); then
    relative_evidence="${MANIFEST_PATH:${#REPO_ROOT}}"; relative_evidence="${relative_evidence#/}"
    set_spec_field() { local key="$1" value="$2" temp="$SPEC_PATH.phase3.tmp"; awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp" || { rm -f "$temp"; return 1; }; mv "$temp" "$SPEC_PATH"; }
    set_spec_field gate_release_command '"scripts/prepare-release.sh"'; set_spec_field gate_release_commit_sha "\"$COMMIT_SHA\""; set_spec_field gate_release_tree_digest "\"$TREE_DIGEST\""; set_spec_field gate_release_timestamp "\"$TIMESTAMP\""; set_spec_field gate_release_exit_code 0; set_spec_field gate_release_result PASS; set_spec_field gate_release_evidence "\"$relative_evidence\""
fi
echo "[PASS] Release prepared: $MANIFEST_PATH"
exit 0
