#!/usr/bin/env bash
#
# Validate docs/spec.md before the Supervisor applies a workflow transition.
#
# Exit codes:
#   0 - all checks passed
#   1 - state file missing or malformed
#   2 - transition or phase prerequisites not met

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH=""
FEATURE_ID=""
SPEC_RELATIVE_PATH='docs/spec.md'
TARGET_PHASE=""
EXPECTED_COMMIT_SHA=""
EXPECTED_TREE_DIGEST=""

usage() {
    cat <<'EOF'
Usage: ./scripts/check-phase.sh [TARGET_PHASE] [--feature-id ID] [--spec-path PATH] [--repo-root PATH]
       [--commit-sha SHA] [--tree-digest DIGEST]
EOF
}

while (($# > 0)); do
    case "$1" in
        --spec-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 1; }
            SPEC_PATH="$2"
            shift 2
            ;;
        --feature-id)
            [[ $# -ge 2 ]] || { echo '[FAIL] --feature-id requires a value.'; exit 1; }
            FEATURE_ID="$2"
            shift 2
            ;;
        --repo-root)
            [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 1; }
            REPO_ROOT="$2"
            shift 2
            ;;
        --commit-sha)
            [[ $# -ge 2 ]] || { echo '[FAIL] --commit-sha requires a value.'; exit 1; }
            EXPECTED_COMMIT_SHA="$2"
            shift 2
            ;;
        --tree-digest)
            [[ $# -ge 2 ]] || { echo '[FAIL] --tree-digest requires a value.'; exit 1; }
            EXPECTED_TREE_DIGEST="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "[FAIL] Unknown option: $1"
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$TARGET_PHASE" ]]; then
                echo "[FAIL] Unexpected argument: $1"
                exit 1
            fi
            TARGET_PHASE="$1"
            shift
            ;;
    esac
done

if ! resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" ''; then exit 1; fi

if [[ ! -f "$SPEC_PATH" ]]; then
    echo "[FAIL] docs/spec.md not found at: $SPEC_PATH"
    exit 1
fi

CONTENT="$(tr -d '\r' < "$SPEC_PATH")"

if ! FRONT_MATTER="$(printf '%s\n' "$CONTENT" | awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { found = 1; exit }
    inside { print }
    END { if (!found) exit 2 }
')"; then
    echo "[FAIL] docs/spec.md must start with YAML front matter delimited by '---'."
    exit 1
fi

declare -A META=()
declare -a PLANNED_FILES=()
declare -a APPROVED_GLOBS=()
declare -a APPROVED_SHARED_FILES=()
ACTIVE_LIST=""

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
        value="${value//\\\"/\"}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

while IFS= read -r line; do
    [[ -z "$(trim_value "$line")" ]] && continue
    [[ "$(trim_value "$line")" == \#* ]] && continue

    if [[ "$line" =~ ^([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="$(unquote_value "${BASH_REMATCH[2]}")"
        META["$key"]="$value"
        ACTIVE_LIST=""
        if [[ "$key" == 'planned_files' || "$key" == 'approved_globs' || "$key" == 'approved_shared_files' ]]; then
            if [[ "$value" == '[]' ]]; then
                :
            elif [[ -z "$value" ]]; then
                ACTIVE_LIST="$key"
            else
                echo "[FAIL] Metadata list '$key' must use [] or an indented YAML list."
                exit 1
            fi
        fi
    elif [[ -n "$ACTIVE_LIST" && "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
        item="$(unquote_value "${BASH_REMATCH[1]}")"
        if [[ "$ACTIVE_LIST" == 'planned_files' ]]; then
            PLANNED_FILES+=("$item")
        else
            APPROVED_GLOBS+=("$item")
        fi
    else
        echo "[FAIL] Unsupported YAML front matter line: $line"
        exit 1
    fi
done <<< "$FRONT_MATTER"

meta_get() {
    printf '%s' "${META[$1]-}"
}

if [[ -n "$FEATURE_ID" ]]; then
    declared_feature_id="$(meta_get feature_id)"
    declared_spec_path="${META[spec_path]-}"
    declared_spec_path="${declared_spec_path//\\//}"
    if [[ "$declared_feature_id" != "$FEATURE_ID" ]]; then
        echo "[FAIL] Spec feature_id '$declared_feature_id' does not match requested feature '$FEATURE_ID'."
        exit 1
    fi
    if [[ "$declared_spec_path" != "$SPEC_RELATIVE_PATH" ]]; then
        echo "[FAIL] Spec spec_path '$declared_spec_path' does not match '$SPEC_RELATIVE_PATH'."
        exit 1
    fi
fi

require_metadata_key() {
    local key="$1"
    if [[ -z "${META[$key]+present}" ]]; then
        echo "[FAIL] Required workflow metadata '$key' is missing."
        exit 1
    fi
}

for key in sdlc_schema current_phase design_required deployment_readiness_enabled security_gate_enabled review_cycle last_transition_to planned_files approved_globs; do
    require_metadata_key "$key"
done

if [[ "$(meta_get sdlc_schema)" != '1' ]]; then
    echo "[FAIL] Unsupported sdlc_schema '$(meta_get sdlc_schema)'. Expected '1'."
    exit 1
fi

VALID_STATES=(GATHERING_REQS DESIGN PLANNING CODING REVIEW TESTING DEPLOYMENT_READINESS DONE)
declare -A PHASE_INDEX=(
    [GATHERING_REQS]=0
    [DESIGN]=1
    [PLANNING]=2
    [CODING]=3
    [REVIEW]=4
    [TESTING]=5
    [DEPLOYMENT_READINESS]=6
    [DONE]=7
)

is_valid_state() {
    [[ -n "${PHASE_INDEX[$1]+present}" ]]
}

CURRENT_STATE="$(meta_get current_phase)"
if ! is_valid_state "$CURRENT_STATE"; then
    echo "[FAIL] Invalid current_phase '$CURRENT_STATE'. Must be one of: ${VALID_STATES[*]}"
    exit 1
fi

VISIBLE_STATE="$(printf '%s\n' "$CONTENT" | awk '
    /^## Current State$/ { found = 1; next }
    found && /`/ { gsub(/`/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
')"
VISIBLE_CYCLE="$(printf '%s\n' "$CONTENT" | awk '
    /^## Review Cycle$/ { found = 1; next }
    found && /`/ { gsub(/`/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
')"
if [[ "$VISIBLE_STATE" != "$CURRENT_STATE" ]]; then
    echo "[FAIL] Visible 'Current State' does not match current_phase '$CURRENT_STATE'."
    exit 1
fi

REVIEW_CYCLE="$(meta_get review_cycle)"
if ! [[ "$REVIEW_CYCLE" =~ ^[0-3]$ ]]; then
    echo '[FAIL] review_cycle must be an integer from 0 through 3.'
    exit 1
fi
if [[ "$VISIBLE_CYCLE" != "$REVIEW_CYCLE" ]]; then
    echo "[FAIL] Visible 'Review Cycle' does not match review_cycle '$REVIEW_CYCLE'."
    exit 1
fi

for flag in design_required deployment_readiness_enabled security_gate_enabled; do
    value="$(meta_get "$flag")"
    if [[ "$value" != 'true' && "$value" != 'false' ]]; then
        echo "[FAIL] Metadata '$flag' must be true or false, not '$value'."
        exit 1
    fi
done

DESIGN_REQUIRED="$(meta_get design_required)"
DEPLOYMENT_READINESS_ENABLED="$(meta_get deployment_readiness_enabled)"
SECURITY_GATE_ENABLED="$(meta_get security_gate_enabled)"

release_assurance_enabled() {
    [[ -f "$REPO_ROOT/.github/sdlc-config.yml" ]] || return 1
    awk '/^release_assurance:[[:space:]]*$/{found=1; next} found && /^[^[:space:]]/{exit} found && /^[[:space:]]+enabled:[[:space:]]*true[[:space:]]*$/{enabled=1} END { exit(enabled ? 0 : 1) }' "$REPO_ROOT/.github/sdlc-config.yml"
}

config_flag_enabled() {
    local section="$1" field="$2"
    [[ -f "$REPO_ROOT/.github/sdlc-config.yml" ]] || return 1
    awk -v section="$section" -v field="$field" '
        $0 ~ "^" section ":[[:space:]]*$" { found = 1; next }
        found && /^[^[:space:]]/ { exit }
        found && $0 ~ "^[[:space:]]+" field ":[[:space:]]*true[[:space:]]*$" { enabled = 1 }
        END { exit(enabled ? 0 : 1) }
    ' "$REPO_ROOT/.github/sdlc-config.yml"
}

AI_GOVERNANCE_ENABLED=0
config_flag_enabled ai_governance enabled && AI_GOVERNANCE_ENABLED=1
OPERATIONAL_READINESS_ENABLED=0
config_flag_enabled operational_readiness enabled && OPERATIONAL_READINESS_ENABLED=1
AI_LIFECYCLE_ENABLED=0
config_flag_enabled ai_lifecycle enabled && AI_LIFECYCLE_ENABLED=1
MEASUREMENT_COMPLETION_GATE_ENABLED=0
if config_flag_enabled measurement enabled && config_flag_enabled measurement require_completion_gate; then
    MEASUREMENT_COMPLETION_GATE_ENABLED=1
fi

if [[ "$(meta_get last_transition_to)" != "$CURRENT_STATE" ]]; then
    echo "[FAIL] last_transition_to '$(meta_get last_transition_to)' does not match current_phase '$CURRENT_STATE'."
    exit 1
fi
if [[ "$CURRENT_STATE" != 'GATHERING_REQS' && "$(meta_get last_transition_actor)" != 'supervisor' && "$(meta_get last_transition_actor)" != 'migration' ]]; then
    echo '[FAIL] Non-initial workflow states must be applied by the supervisor or an evidenced migration.'
    exit 1
fi
if [[ "$(meta_get last_transition_actor)" == 'migration' ]]; then
    migration_evidence="$(meta_get last_transition_evidence)"
    migration_path="$migration_evidence"
    [[ "$migration_path" = /* ]] || migration_path="$REPO_ROOT/$migration_path"
    if [[ -z "$migration_evidence" || ! -f "$migration_path" ]]; then
        echo '[FAIL] Migration bootstrap requires an existing last_transition_evidence file.'
        exit 1
    fi
fi
if [[ "$CURRENT_STATE" == 'DESIGN' && "$DESIGN_REQUIRED" != 'true' ]]; then
    echo '[FAIL] Current phase DESIGN is disabled by workflow metadata.'
    exit 1
fi
if [[ "$CURRENT_STATE" == 'DEPLOYMENT_READINESS' && "$DEPLOYMENT_READINESS_ENABLED" != 'true' ]]; then
    echo '[FAIL] Current phase DEPLOYMENT_READINESS is disabled by workflow metadata.'
    exit 1
fi

if [[ -z "$TARGET_PHASE" ]]; then
    case "$CURRENT_STATE" in
        GATHERING_REQS) [[ "$DESIGN_REQUIRED" == 'true' ]] && TARGET_PHASE='DESIGN' || TARGET_PHASE='PLANNING' ;;
        DESIGN) TARGET_PHASE='PLANNING' ;;
        PLANNING) TARGET_PHASE='CODING' ;;
        CODING) TARGET_PHASE='REVIEW' ;;
        REVIEW) TARGET_PHASE='TESTING' ;;
        TESTING) [[ "$DEPLOYMENT_READINESS_ENABLED" == 'true' ]] && TARGET_PHASE='DEPLOYMENT_READINESS' || TARGET_PHASE='DONE' ;;
        DEPLOYMENT_READINESS) TARGET_PHASE='DONE' ;;
        DONE) echo '[PASS] Already at final state: DONE'; exit 0 ;;
    esac
fi

if ! is_valid_state "$TARGET_PHASE"; then
    echo "[FAIL] Invalid target phase '$TARGET_PHASE'. Must be one of: ${VALID_STATES[*]}"
    exit 1
fi

ALL_PASSED=1
TRANSITION="$CURRENT_STATE -> $TARGET_PHASE"
case "$TRANSITION" in
    'GATHERING_REQS -> DESIGN'|'GATHERING_REQS -> PLANNING'|'DESIGN -> PLANNING'|'PLANNING -> CODING'|'CODING -> REVIEW'|'REVIEW -> CODING'|'REVIEW -> TESTING'|'REVIEW -> GATHERING_REQS'|'TESTING -> CODING'|'TESTING -> DEPLOYMENT_READINESS'|'TESTING -> DONE'|'DEPLOYMENT_READINESS -> CODING'|'DEPLOYMENT_READINESS -> DONE') ;;
    *) echo "[FAIL] Illegal workflow transition: $TRANSITION"; ALL_PASSED=0 ;;
esac
if [[ "$TARGET_PHASE" == 'DESIGN' && "$DESIGN_REQUIRED" != 'true' ]]; then
    echo '[FAIL] DESIGN is disabled, so the target phase is invalid.'
    ALL_PASSED=0
fi
if [[ "$TARGET_PHASE" == 'DEPLOYMENT_READINESS' && "$DEPLOYMENT_READINESS_ENABLED" != 'true' ]]; then
    echo '[FAIL] DEPLOYMENT_READINESS is disabled, so the target phase is invalid.'
    ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'CODING' && "$REVIEW_CYCLE" -ge 3 ]]; then
    echo '[FAIL] Review cycle cap reached; REVIEW cannot return to CODING. Escalate instead.'
    ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'GATHERING_REQS' && "$REVIEW_CYCLE" -ne 3 ]]; then
    echo '[FAIL] Escalation to GATHERING_REQS requires review_cycle 3.'
    ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'GATHERING_REQS' ]]; then
    escalation_evidence="$(meta_get last_transition_evidence)"
    escalation_path="$escalation_evidence"
    [[ "$escalation_path" = /* ]] || escalation_path="$REPO_ROOT/$escalation_path"
    if [[ -z "$escalation_evidence" || ! -f "$escalation_path" ]]; then
        echo '[FAIL] Review-cycle escalation requires an existing last_transition_evidence file.'
        ALL_PASSED=0
    fi
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'TESTING' && "$REVIEW_CYCLE" -ne 0 ]]; then
    echo '[FAIL] Approved review must reset review_cycle to 0 before TESTING.'
    ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'TESTING' && "$TARGET_PHASE" == 'DONE' && "$DEPLOYMENT_READINESS_ENABLED" == 'true' ]]; then
    echo '[FAIL] TESTING cannot transition directly to DONE while readiness is enabled.'
    ALL_PASSED=0
fi
if release_assurance_enabled && [[ "$CURRENT_STATE" == 'TESTING' && "$TARGET_PHASE" == 'DONE' ]]; then
    test_gate release PASS || ALL_PASSED=0
fi

sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        return 1
    fi
}

get_current_commit_sha() {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true
}

get_current_tree_digest() {
    local diff_payload untracked_file full_path file_hash
    local -a parts=()
    diff_payload="$(git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>/dev/null || true)"
    if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        return 0
    fi
    parts+=("tracked:$diff_payload")
    while IFS= read -r -d '' untracked_file; do
        [[ "$untracked_file" == '.sdlc' || "$untracked_file" == .sdlc/* ]] && continue
        full_path="$REPO_ROOT/$untracked_file"
        if [[ -f "$full_path" ]]; then
            file_hash="$(sha256sum "$full_path" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$full_path" | awk '{print $1}')"
            parts+=("untracked:$untracked_file:$file_hash")
        fi
    done < <(git -C "$REPO_ROOT" ls-files --others --exclude-standard -z 2>/dev/null || true)
    printf '%s\n' "${parts[@]}" | LC_ALL=C sort | sha256_text
}

if [[ -z "$EXPECTED_COMMIT_SHA" ]]; then
    EXPECTED_COMMIT_SHA="$(get_current_commit_sha)"
fi
if [[ -z "$EXPECTED_TREE_DIGEST" ]]; then
    EXPECTED_TREE_DIGEST="$(get_current_tree_digest)"
fi

test_gate() {
    local name="$1"
    shift
    local prefix="gate_$name"
    local result="${META[${prefix}_result]-}"
    local command="${META[${prefix}_command]-}"
    local commit="${META[${prefix}_commit_sha]-}"
    local tree="${META[${prefix}_tree_digest]-}"
    local timestamp="${META[${prefix}_timestamp]-}"
    local exit_code="${META[${prefix}_exit_code]-}"
    local evidence="${META[${prefix}_evidence]-}"
    local valid=1
    local allowed_result allowed=0 evidence_path

    for allowed_result in "$@"; do
        [[ "$result" == "$allowed_result" ]] && allowed=1
    done
    if (( allowed == 0 )); then
        echo "[FAIL] Gate '$name': result '$result' is not allowed."
        valid=0
    fi
    for field in command commit_sha tree_digest timestamp exit_code evidence; do
        value="${META[${prefix}_${field}]-}"
        if [[ -z "$value" ]]; then
            echo "[FAIL] Gate '$name': field '$field' is required."
            valid=0
        fi
    done
    if ! [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
        echo "[FAIL] Gate '$name': exit_code must be an integer."
        valid=0
    elif [[ "$result" == 'PASS' && "$exit_code" -ne 0 ]] ||
         [[ "$result" != 'PASS' && "$exit_code" -eq 0 ]]; then
        echo "[FAIL] Gate '$name': result '$result' conflicts with exit_code '$exit_code'."
        valid=0
    fi
    if [[ "$commit" != "$EXPECTED_COMMIT_SHA" ]]; then
        echo "[FAIL] Gate '$name': commit_sha '$commit' is stale; expected '$EXPECTED_COMMIT_SHA'."
        valid=0
    fi
    if [[ "$tree" != "$EXPECTED_TREE_DIGEST" ]]; then
        echo "[FAIL] Gate '$name': tree_digest is stale for the current working tree."
        valid=0
    fi
    evidence_path="$evidence"
    [[ "$evidence_path" = /* ]] || evidence_path="$REPO_ROOT/$evidence_path"
    if [[ -z "$evidence" || ! -f "$evidence_path" ]]; then
        echo "[FAIL] Gate '$name': evidence file '$evidence' does not exist."
        valid=0
    fi
    if [[ -n "$FEATURE_ID" ]]; then
        record_feature_id="${META[${prefix}_feature_id]-}"
        record_spec_path="${META[${prefix}_spec_path]-}"
        record_spec_path="${record_spec_path//\\//}"
        evidence_prefix=".sdlc/evidence/$FEATURE_ID/"
        normalized_evidence="${evidence//\\//}"
        if [[ "$record_feature_id" != "$FEATURE_ID" ]]; then
            echo "[FAIL] Gate '$name': feature_id '$record_feature_id' does not match '$FEATURE_ID'."
            valid=0
        fi
        if [[ "$record_spec_path" != "$SPEC_RELATIVE_PATH" ]]; then
            echo "[FAIL] Gate '$name': spec_path '$record_spec_path' does not match '$SPEC_RELATIVE_PATH'."
            valid=0
        fi
        if [[ "$evidence" = /* || "$normalized_evidence" != "$evidence_prefix"* ]]; then
            echo "[FAIL] Gate '$name': evidence must be under '$evidence_prefix'."
            valid=0
        fi
    fi
    if (( valid == 1 )); then
        echo "[PASS] Gate '$name': evidence is valid for the current revision."
        return 0
    fi
    return 1
}

get_validation_contract() {
    VALIDATION_REQUIRED=()
    VALIDATION_INSTALL='none'
    local config_path="$REPO_ROOT/.github/sdlc-config.yml" line items item in_validation=0
    [[ -f "$config_path" ]] || return 1
    grep -Eq '^sdlc_config_schema:[[:space:]]*1[[:space:]]*$' "$config_path" || return 1
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" == 'validation:' ]]; then
            in_validation=1
            continue
        fi
        if (( in_validation == 1 )) && [[ "$line" =~ ^[^[:space:]] ]]; then break; fi
        if (( in_validation == 1 )) && [[ "$line" =~ ^[[:space:]]+required_tasks:[[:space:]]*\[(.*)\] ]]; then
            items="${BASH_REMATCH[1]}"
            IFS=',' read -r -a raw_items <<< "$items"
            for item in "${raw_items[@]}"; do
                item="$(trim_value "$item")"
                item="${item//\"/}"
                [[ -n "$item" ]] && VALIDATION_REQUIRED+=("$item")
            done
        elif (( in_validation == 1 )) && [[ "$line" =~ ^[[:space:]]+install_task:[[:space:]]*(.*)$ ]]; then
            VALIDATION_INSTALL="$(trim_value "${BASH_REMATCH[1]}")"
            VALIDATION_INSTALL="${VALIDATION_INSTALL//\"/}"
        fi
    done < "$config_path"
    return 0
}

test_configured_task_gates() {
    local target_phase="$1" current_state="$2" task
    get_validation_contract || return 0
    local -a tasks=()
    if [[ "$current_state" == 'CODING' && "$target_phase" == 'REVIEW' ]]; then
        for task in "${VALIDATION_REQUIRED[@]}"; do
            [[ "$task" != 'test' ]] && tasks+=("$task")
        done
        [[ "$VALIDATION_INSTALL" == 'install' ]] && tasks+=(install)
    elif [[ "$current_state" == 'TESTING' && "$target_phase" == 'DONE' ]] ||
         [[ "$current_state" == 'TESTING' && "$target_phase" == 'DEPLOYMENT_READINESS' ]]; then
        tasks+=("${VALIDATION_REQUIRED[@]}")
        [[ "$VALIDATION_INSTALL" == 'install' ]] && tasks+=(install)
    else
        return 0
    fi
    local passed=1
    local -A seen_tasks=()
    for task in "${tasks[@]}"; do
        [[ -n "${seen_tasks[$task]+present}" ]] && continue
        seen_tasks["$task"]=1
        if ! test_gate "$task" PASS; then passed=0; fi
    done
    return $((1 - passed))
}

get_config_section_value() {
    local section="$1" key="$2" config_path="$REPO_ROOT/.github/sdlc-config.yml"
    [[ -f "$config_path" ]] || return 0
    awk -v section="$section" -v key="$key" '
        { sub(/\r$/, "", $0) }
        $0 == section ":" { inside = 1; next }
        inside && /^[^[:space:]]/ { exit }
        inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
            value = $0
            sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$config_path"
}

get_config_section_list() {
    local section="$1" key="$2" config_path="$REPO_ROOT/.github/sdlc-config.yml"
    [[ -f "$config_path" ]] || return 0
    awk -v section="$section" -v key="$key" '
        { sub(/\r$/, "", $0) }
        function emit(value, count, items, idx) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^\[.*\]$/) {
                sub(/^\[/, "", value); sub(/\]$/, "", value)
                count = split(value, items, ",")
                for (idx = 1; idx <= count; idx++) {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", items[idx])
                    gsub(/^"|"$/, "", items[idx])
                    if (items[idx] != "") print items[idx]
                }
            }
        }
        $0 == section ":" { inside = 1; next }
        inside && /^[^[:space:]]/ { exit }
        inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
            value = $0
            sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            emit(value)
            active = (value == "")
            next
        }
        inside && active && /^[[:space:]]+-[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+-[[:space:]]*/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/^"|"$/, "", value)
            if (value != "") print value
            next
        }
    ' "$config_path"
}

get_verification_contract() {
    VERIFICATION_CONFIGURED=0
    VERIFICATION_RISK_PROFILE=''
    VERIFICATION_COVERAGE_ENABLED='false'
    VERIFICATION_MUTATION_ENABLED='false'
    VERIFICATION_COVERAGE_REQUIRED_PROFILES=()
    VERIFICATION_MUTATION_REQUIRED_PROFILES=()
    local config_path="$REPO_ROOT/.github/sdlc-config.yml"
    [[ -f "$config_path" ]] || return 0
    grep -Eq '^verification:[[:space:]]*$' "$config_path" || return 0
    VERIFICATION_CONFIGURED=1
    VERIFICATION_RISK_PROFILE="$(get_config_section_value quality_security risk_profile)"
    VERIFICATION_COVERAGE_ENABLED="$(get_config_section_value verification coverage_enabled)"
    VERIFICATION_MUTATION_ENABLED="$(get_config_section_value verification mutation_enabled)"
    mapfile -t VERIFICATION_COVERAGE_REQUIRED_PROFILES < <(get_config_section_list verification coverage_required_risk_profiles)
    mapfile -t VERIFICATION_MUTATION_REQUIRED_PROFILES < <(get_config_section_list verification mutation_required_risk_profiles)
}

test_verification_record() {
    local kind="$1" prefix evidence python_executable='' output
    prefix="gate_$kind"
    evidence="${META[${prefix}_evidence]-}"
    [[ -f "$SCRIPT_DIR/verification.py" ]] || { echo '[FAIL] Verification adapter not found.'; return 1; }
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then python_executable="$candidate"; break; fi
    done
    [[ -n "$python_executable" ]] || { echo '[FAIL] Python 3 is required for verification evidence validation.'; return 1; }
    set +e
    output="$($python_executable "$SCRIPT_DIR/verification.py" validate-record --record-kind "$kind" --record-path "$evidence" --repo-root "$REPO_ROOT" --commit-sha "$EXPECTED_COMMIT_SHA" --tree-digest "$EXPECTED_TREE_DIGEST" 2>&1)"
    local validation_exit=$?
    set -e
    if (( validation_exit != 0 )); then
        echo "[FAIL] Verification '$kind' evidence is invalid: $output"
        return 1
    fi
    echo "[PASS] Verification '$kind' evidence matches the current report and revision."
    return 0
}

test_verification_gates() {
    get_verification_contract
    (( VERIFICATION_CONFIGURED == 1 )) || return 0
    local passed=1 profile coverage_required=0 mutation_required=0
    for profile in "${VERIFICATION_COVERAGE_REQUIRED_PROFILES[@]}"; do [[ "$profile" == "$VERIFICATION_RISK_PROFILE" ]] && coverage_required=1; done
    for profile in "${VERIFICATION_MUTATION_REQUIRED_PROFILES[@]}"; do [[ "$profile" == "$VERIFICATION_RISK_PROFILE" ]] && mutation_required=1; done
    if (( coverage_required == 1 )); then
        if [[ "$VERIFICATION_COVERAGE_ENABLED" != true ]]; then
            echo "[FAIL] Risk profile '$VERIFICATION_RISK_PROFILE' requires verification coverage to be enabled."
            passed=0
        else
            test_gate coverage PASS || passed=0
            test_verification_record coverage || passed=0
        fi
    fi
    if (( mutation_required == 1 )); then
        if [[ "$VERIFICATION_MUTATION_ENABLED" != true ]]; then
            echo "[FAIL] Risk profile '$VERIFICATION_RISK_PROFILE' requires mutation verification to be enabled."
            passed=0
        else
            test_gate mutation PASS || passed=0
            test_verification_record mutation || passed=0
        fi
    fi
    return $((1 - passed))
}

test_task_graph_gate() {
    [[ -n "$FEATURE_ID" && ( "$TARGET_PHASE" == 'CODING' || "$TARGET_PHASE" == 'REVIEW' || "$TARGET_PHASE" == 'TESTING' || "$TARGET_PHASE" == 'DEPLOYMENT_READINESS' || "$TARGET_PHASE" == 'DONE' ) ]] || return 0
    [[ -f "$REPO_ROOT/docs/specs/$FEATURE_ID/tasks.json" ]] || return 0
    local task_graph="$SCRIPT_DIR/task-graph.py" python_executable=''
    [[ -f "$task_graph" ]] || { echo "[FAIL] Task graph validator not found: $task_graph"; return 1; }
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1; then python_executable="$candidate"; break; fi
    done
    [[ -n "$python_executable" ]] || { echo '[FAIL] Python 3 is required when a feature tasks.json exists.'; return 1; }
    local output
    set +e
    output="$($python_executable "$task_graph" validate --repo-root "$REPO_ROOT" --feature-id "$FEATURE_ID" --spec-path "$SPEC_PATH" --target-phase "$TARGET_PHASE" --commit-sha "$EXPECTED_COMMIT_SHA" --tree-digest "$EXPECTED_TREE_DIGEST" 2>&1)"
    local graph_exit=$?
    set -e
    if (( graph_exit != 0 )); then
        echo '[FAIL] Task graph gate failed:'
        printf '  %s\n' "$output"
        return 1
    fi
    echo "[PASS] Task graph is valid for feature '$FEATURE_ID' and target phase '$TARGET_PHASE'."
    return 0
}

test_completion_extension_gates() {
    local passed=1
    if (( OPERATIONAL_READINESS_ENABLED == 1 )); then test_gate operational_readiness PASS || passed=0; fi
    if (( AI_LIFECYCLE_ENABLED == 1 )); then test_gate ai_lifecycle PASS || passed=0; fi
    if (( MEASUREMENT_COMPLETION_GATE_ENABLED == 1 )); then test_gate measurement PASS || passed=0; fi
    return $((1 - passed))
}

get_section_body() {
    local section="$1"
    awk -v section="$section" '
        $0 == "## " section { found = 1; next }
        found && ($0 ~ /^## / || $0 ~ /^---[[:space:]]*$/) { exit }
        found { print }
    ' <<< "$CONTENT"
}

section_is_populated() {
    local section="$1"
    local body clean
    if ! grep -q "^## $section$" <<< "$CONTENT"; then
        return 1
    fi
    body="$(get_section_body "$section")"
    clean="$(printf '%s\n' "$body" | awk '
        BEGIN { comment = 0 }
        /<!--/ { comment = 1 }
        !comment { print }
        /-->/ { comment = 0 }
    ' | sed -E \
        -e '/^[[:space:]]*```/d' \
        -e '/^_.*(PM|Designer|Architect|Reviewer|QA).*_$/d' \
        -e 's/\((PM|Designer|Architect|Reviewer|QA)[^)]*\)//g' \
        -e 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*$//g' \
        -e 's/^[[:space:]]*-?[[:space:]]*$//g' \
        -e 's/^[[:space:]]*[0-9]+\.[[:space:]]*$//g' \
        -e '/^[[:space:]]*$/d' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -n "$clean" ]]
}

phase2_enabled() {
    [[ -f "$REPO_ROOT/.github/sdlc-config.yml" ]] && grep -Eq '^quality_security:[[:space:]]*$' "$REPO_ROOT/.github/sdlc-config.yml"
}

declare -A REQUIRED_SECTIONS=(
    [GATHERING_REQS]='Goal|Requirements|Acceptance Criteria|Out of Scope'
    [DESIGN]='Design'
    [PLANNING]='Tech Stack|File Structure|Implementation Plan'
    [CODING]='Implementation Plan'
    [REVIEW]='Review Findings'
    [TESTING]='Test Results'
    [DEPLOYMENT_READINESS]='Deployment Readiness'
    [DONE]=''
)

check_required_sections() {
    local target_index="${PHASE_INDEX[$TARGET_PHASE]}"
    local state section required_sections
    local passed=1
    local phase2=0
    phase2_enabled && phase2=1
    for state in "${VALID_STATES[@]}"; do
        (( PHASE_INDEX[$state] >= target_index )) && break
        if [[ "$state" == 'DESIGN' && "$DESIGN_REQUIRED" != 'true' ]]; then
            echo "[SKIP] Phase 'DESIGN' is disabled for this project."
            continue
        fi
        if [[ "$state" == 'DEPLOYMENT_READINESS' && "$DEPLOYMENT_READINESS_ENABLED" != 'true' ]]; then
            echo "[SKIP] Phase 'DEPLOYMENT_READINESS' is disabled for this project."
            continue
        fi
        required_sections="${REQUIRED_SECTIONS[$state]}"
        if (( phase2 == 1 )) && [[ "$state" == 'PLANNING' ]]; then
            required_sections+='|Test Strategy|Acceptance Test Mapping'
            [[ "$SECURITY_GATE_ENABLED" != 'true' ]] || required_sections+='|Security Design Review'
        fi
        [[ -n "$required_sections" ]] || continue
        IFS='|' read -r -a section_list <<< "$required_sections"
        for section in "${section_list[@]}"; do
            if [[ "$section" == 'Security Design Review' && "$SECURITY_GATE_ENABLED" == 'true' ]] && get_section_body "$section" | grep -Eiq 'Status:[[:space:]]*NOT_REQUIRED'; then
                echo "[FAIL] Phase '$state': security review is required but remains NOT_REQUIRED."
                passed=0
                continue
            fi
            if section_is_populated "$section"; then
                echo "[PASS] Phase '$state': section '## $section' is populated."
            else
                if grep -q "^## $section$" <<< "$CONTENT"; then
                    echo "[FAIL] Phase '$state': section '## $section' appears empty."
                else
                    echo "[FAIL] Phase '$state': section '## $section' not found."
                fi
                passed=0
            fi
        done
    done
    return $((1 - passed))
}

test_task_graph_gate || ALL_PASSED=0

if [[ "$CURRENT_STATE" == 'GATHERING_REQS' && "$TARGET_PHASE" == 'DESIGN' ||
      "$CURRENT_STATE" == 'GATHERING_REQS' && "$TARGET_PHASE" == 'PLANNING' ]]; then
    test_gate requirements PASS || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'DESIGN' && "$TARGET_PHASE" == 'PLANNING' ]]; then
    test_gate design PASS || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'PLANNING' && "$TARGET_PHASE" == 'CODING' ]]; then
    test_gate config PASS || ALL_PASSED=0
    test_gate planning PASS || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'CODING' && "$TARGET_PHASE" == 'REVIEW' ]]; then
    test_gate build PASS || ALL_PASSED=0
    [[ "$SECURITY_GATE_ENABLED" != 'true' ]] || test_gate security PASS || ALL_PASSED=0
    (( AI_GOVERNANCE_ENABLED == 0 )) || test_gate ai_governance PASS || ALL_PASSED=0
    test_configured_task_gates "$TARGET_PHASE" "$CURRENT_STATE" || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'CODING' ]]; then
    test_gate review CHANGES_REQUESTED || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'TESTING' ]]; then
    test_gate review PASS || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'REVIEW' && "$TARGET_PHASE" == 'GATHERING_REQS' ]]; then
    test_gate review CHANGES_REQUESTED || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'TESTING' && "$TARGET_PHASE" == 'CODING' ]]; then
    test_gate test FAIL || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'TESTING' && ( "$TARGET_PHASE" == 'DEPLOYMENT_READINESS' || "$TARGET_PHASE" == 'DONE' ) ]]; then
    test_gate test PASS || ALL_PASSED=0
    test_configured_task_gates "$TARGET_PHASE" "$CURRENT_STATE" || ALL_PASSED=0
    test_verification_gates || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'DEPLOYMENT_READINESS' && "$TARGET_PHASE" == 'CODING' ]]; then
    test_gate deployment_readiness FAIL || ALL_PASSED=0
fi
if [[ "$CURRENT_STATE" == 'DEPLOYMENT_READINESS' && "$TARGET_PHASE" == 'DONE' ]]; then
    test_gate deployment_readiness PASS || ALL_PASSED=0
    if release_assurance_enabled; then test_gate release PASS || ALL_PASSED=0; fi
fi
if [[ "$CURRENT_STATE" == 'TESTING' && "$TARGET_PHASE" == 'DONE' ||
      "$CURRENT_STATE" == 'DEPLOYMENT_READINESS' && "$TARGET_PHASE" == 'DONE' ]]; then
    test_completion_extension_gates || ALL_PASSED=0
fi

if check_required_sections; then
    :
else
    ALL_PASSED=0
fi

echo "Checking phase prerequisites up to: $TARGET_PHASE (current state: $CURRENT_STATE)"
if (( ALL_PASSED == 1 )); then
    echo "[PASS] All transition and prerequisite checks passed for phase: $TARGET_PHASE"
    exit 0
fi

echo '[FAIL] Some transition, gate, or prerequisite checks failed. See output above.'
exit 2
