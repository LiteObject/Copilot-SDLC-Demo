#!/usr/bin/env bash
#
# Validate the versioned .github/sdlc-config.yml contract.
#
# Tasks use structured executable/args records. This script never evaluates a
# command string and does not require a third-party YAML parser.
#
# Exit codes:
#   0 - configuration is valid
#   1 - configuration is incomplete or invalid
#   2 - configuration could not be parsed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY=""
SPEC_PATH=""
FEATURE_ID=""
RECORD_SPEC=0

declare -A CFG=()
declare -A LISTS=()
declare -A TASK_EXEC=()
declare -A TASK_ARGS=()
declare -A TASK_ARGS_SET=()
CURRENT_SECTION=""
CURRENT_TASK=""
ACTIVE_LIST=""

declare -a ERRORS=()
declare -a WARNINGS=()

usage() {
    cat <<'EOF'
Usage: ./scripts/validate-sdlc-config.sh [--config-path PATH] [--repo-root PATH]
    [--evidence-directory PATH] [--spec-path PATH] [--feature-id ID] [--record-spec]
EOF
}

while (($# > 0)); do
    case "$1" in
        --config-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --config-path requires a value.'; exit 2; }
            CONFIG_PATH="$2"
            shift 2
            ;;
        --repo-root)
            [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }
            REPO_ROOT="$2"
            shift 2
            ;;
        --evidence-directory)
            [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }
            EVIDENCE_DIRECTORY="$2"
            shift 2
            ;;
        --spec-path)
            [[ $# -ge 2 ]] || { echo '[FAIL] --spec-path requires a value.'; exit 2; }
            SPEC_PATH="$2"
            shift 2
            ;;
        --feature-id)
            [[ $# -ge 2 ]] || { echo '[FAIL] --feature-id requires a value.'; exit 2; }
            FEATURE_ID="$2"
            shift 2
            ;;
        --record-spec)
            RECORD_SPEC=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[FAIL] Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"
fi
requested_evidence_directory="$EVIDENCE_DIRECTORY"
resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" "$EVIDENCE_DIRECTORY" || exit 2
if [[ -z "$FEATURE_ID" ]]; then EVIDENCE_DIRECTORY="$requested_evidence_directory"; fi
if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "[FAIL] Config file not found: $CONFIG_PATH"
    exit 1
fi

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
    else
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
    fi
    printf '%s' "$value"
}

serialize_items() {
    local result='' item
    for item in "$@"; do
        [[ -z "$result" ]] && result="$item" || result+=$'\x1f'"$item"
    done
    printf '%s' "$result"
}

parse_inline_list() {
    local value="$1"
    local trimmed inner item
    PARSED_ITEMS=()
    trimmed="$(trim_value "$value")"
    if [[ "$trimmed" == '[]' ]]; then
        return 0
    fi
    if [[ "$trimmed" != \[*\] ]]; then
        echo "[FAIL] Expected an inline YAML list, got '$value'." >&2
        return 1
    fi
    inner="${trimmed:1:${#trimmed}-2}"
    [[ -z "$(trim_value "$inner")" ]] && return 0
    IFS=',' read -r -a raw_items <<< "$inner"
    for item in "${raw_items[@]}"; do
        item="$(unquote_value "$item")"
        [[ -n "$item" ]] || { echo "[FAIL] Empty item in YAML list '$value'." >&2; return 1; }
        PARSED_ITEMS+=("$item")
    done
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%$'\r'}"
    trimmed="$(trim_value "$line")"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

    if [[ "$line" =~ ^([[:space:]]*)([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
        indent="${#BASH_REMATCH[1]}"
        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        ACTIVE_LIST=""
        if (( indent == 0 )); then
            CURRENT_SECTION="$key"
            CURRENT_TASK=""
            if [[ -n "$(trim_value "$value")" ]]; then
                if [[ "$value" == \[*\] ]]; then
                    parse_inline_list "$value" || exit 2
                    LISTS["$key"]="$(serialize_items "${PARSED_ITEMS[@]}")"
                else
                    CFG["$key"]="$(unquote_value "$value")"
                fi
            fi
        elif [[ "$CURRENT_SECTION" == 'tasks' && $indent -eq 2 ]]; then
            CURRENT_TASK="$key"
        elif [[ "$CURRENT_SECTION" == 'tasks' && $indent -ge 4 && -n "$CURRENT_TASK" ]]; then
            if [[ "$key" == 'args' ]]; then
                parse_inline_list "$value" || exit 2
                TASK_ARGS["$CURRENT_TASK"]="$(serialize_items "${PARSED_ITEMS[@]}")"
                TASK_ARGS_SET["$CURRENT_TASK"]=1
            else
                TASK_EXEC["$CURRENT_TASK"]="$(unquote_value "$value")"
            fi
        else
            path="$CURRENT_SECTION.$key"
            if [[ "$value" == \[*\] ]]; then
                parse_inline_list "$value" || exit 2
                LISTS["$path"]="$(serialize_items "${PARSED_ITEMS[@]}")"
            elif [[ -n "$(trim_value "$value")" ]]; then
                CFG["$path"]="$(unquote_value "$value")"
            else
                CFG["$path"]=''
                ACTIVE_LIST="$path"
            fi
        fi
    elif [[ -n "$ACTIVE_LIST" && "$line" =~ ^[[:space:]]*-[[:space:]]*(.*)$ ]]; then
        item="$(unquote_value "${BASH_REMATCH[1]}")"
        existing="${LISTS[$ACTIVE_LIST]-}"
        [[ -z "$existing" ]] && LISTS["$ACTIVE_LIST"]="$item" || LISTS["$ACTIVE_LIST"]+=$'\x1f'"$item"
    else
        echo "[FAIL] Unsupported YAML line: $line"
        exit 2
    fi
done < "$CONFIG_PATH"

get_value() {
    printf '%s' "${CFG[$1]-${2-}}"
}

get_list() {
    LIST_RESULT=()
    local serialized="${LISTS[$1]-}" item
    [[ -n "$serialized" ]] || return 0
    while IFS= read -r -d $'\x1f' item; do
        LIST_RESULT+=("$item")
    done < <(printf '%s\x1f' "$serialized")
}

add_error() {
    ERRORS+=("$1")
    echo "[FAIL] $1"
}

safe_relative_path() {
    local path="$1"
    [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != */../* && "$path" != '..' && ! "$path" =~ ^[A-Za-z]:/ ]]
}

command_display() {
    local executable="$1" serialized="${TASK_ARGS[$2]-}" item output="$executable"
    while IFS= read -r -d $'\x1f' item; do
        [[ "$item" =~ [[:space:]\"\'\;\&\|\<\>\$] ]] && output+=" \"$item\"" || output+=" $item"
    done < <([[ -n "$serialized" ]] && printf '%s\x1f' "$serialized" || true)
    printf '%s' "$output"
}

PACKAGE_MANAGER="$(get_value stack.package_manager)"
MANIFEST="$(get_value stack.package_manifest)"
ALLOWED_PACKAGE_MANAGERS=(npm yarn pnpm pip poetry cargo dotnet go none)
ALLOWED_TASKS=(install build test lint type_check sast secrets dependency_audit license_audit container_scan iac_scan dast security_tests coverage mutation package sbom sign verify_signature deploy smoke_test rollback health_check telemetry_check failure_drill post_release_check agent_evaluation ai_evaluation ai_red_team ai_production_exercise ai_rollback ai_decommission measurement_baseline measurement_snapshot measurement_review)
ALLOWED_TEST_LAYERS=(unit integration contract api e2e accessibility performance resilience fuzz property)
ALLOWED_SEVERITIES=(critical high medium low info)
ALLOWED_VERIFICATION_PROVIDERS=(coverage-py-json generic-json)

if [[ "$(get_value sdlc_config_schema)" != '1' ]]; then
    add_error 'sdlc_config_schema must be 1.'
fi
package_supported=0
for value in "${ALLOWED_PACKAGE_MANAGERS[@]}"; do [[ "$PACKAGE_MANAGER" == "$value" ]] && package_supported=1; done
if (( package_supported == 0 )); then
    add_error "stack.package_manager '$PACKAGE_MANAGER' is unsupported. Supported values: ${ALLOWED_PACKAGE_MANAGERS[*]}."
fi
if [[ "$PACKAGE_MANAGER" == 'none' ]]; then
    [[ -z "$MANIFEST" || "$MANIFEST" == 'none' ]] || add_error "stack.package_manifest must be empty or 'none' when package_manager is none."
elif [[ -z "$MANIFEST" ]]; then
    add_error 'stack.package_manifest is required for a managed package_manager.'
elif ! safe_relative_path "$MANIFEST"; then
    add_error "stack.package_manifest must be a safe repository-relative file: $MANIFEST"
elif [[ ! -f "$REPO_ROOT/$MANIFEST" ]]; then
    add_error "Package manifest does not exist: $MANIFEST"
fi

[[ -n "$(get_value testing.framework)" ]] || add_error 'testing.framework must be configured.'
get_list testing.directories
TEST_DIRECTORIES=("${LIST_RESULT[@]}")
if (( ${#TEST_DIRECTORIES[@]} == 0 )); then
    add_error 'testing.directories must contain at least one directory.'
fi
for directory in "${TEST_DIRECTORIES[@]}"; do
    if ! safe_relative_path "$directory"; then
        add_error "Testing directory must be repository-relative: $directory"
    elif [[ ! -d "$REPO_ROOT/$directory" ]]; then
        add_error "Testing directory does not exist: $directory"
    fi
done

get_list validation.required_tasks
REQUIRED_TASKS=("${LIST_RESULT[@]}")
get_list validation.optional_tasks
OPTIONAL_TASKS=("${LIST_RESULT[@]}")
INSTALL_TASK="$(get_value validation.install_task)"
if (( ${#REQUIRED_TASKS[@]} == 0 )); then
    add_error 'validation.required_tasks must contain build and test.'
fi
for required in build test; do
    found=0
    for task in "${REQUIRED_TASKS[@]}"; do [[ "$task" == "$required" ]] && found=1; done
    (( found == 1 )) || add_error "validation.required_tasks must include '$required'."
done
for task in "${REQUIRED_TASKS[@]}" "${OPTIONAL_TASKS[@]}"; do
    valid=0
    for allowed in build test lint type_check sast secrets dependency_audit license_audit container_scan iac_scan dast security_tests package sbom sign verify_signature deploy smoke_test rollback health_check telemetry_check failure_drill post_release_check; do [[ "$task" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unknown validation task '$task'."
done
for required in "${REQUIRED_TASKS[@]}"; do
    for optional in "${OPTIONAL_TASKS[@]}"; do
        [[ "$required" != "$optional" ]] || add_error "Task '$required' cannot be both required and optional."
    done
done
if [[ "$INSTALL_TASK" != 'none' && "$INSTALL_TASK" != 'install' ]]; then
    add_error "validation.install_task must be install or none, not '$INSTALL_TASK'."
fi
if [[ "$PACKAGE_MANAGER" == 'none' && "$INSTALL_TASK" != 'none' ]]; then
    add_error 'validation.install_task must be none when package_manager is none.'
fi
if [[ "$PACKAGE_MANAGER" != 'none' && "$INSTALL_TASK" == 'none' ]]; then
    add_error 'validation.install_task must be install for a managed package_manager.'
fi

RISK_PROFILE="$(get_value quality_security.risk_profile)"
case "$RISK_PROFILE" in low|medium|high|critical) ;; *) add_error "quality_security.risk_profile '$RISK_PROFILE' must be low, medium, high, or critical." ;; esac
get_list quality_security.required_test_layers
TEST_LAYERS=("${LIST_RESULT[@]}")
if (( ${#TEST_LAYERS[@]} == 0 )); then add_error 'quality_security.required_test_layers must contain at least one test layer.'; fi
for layer in "${TEST_LAYERS[@]}"; do
    valid=0
    for allowed in "${ALLOWED_TEST_LAYERS[@]}"; do [[ "$layer" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unsupported required test layer '$layer'."
done
MAPPING_REQUIRED="$(get_value quality_security.acceptance_mapping_required)"
[[ "$MAPPING_REQUIRED" == true || "$MAPPING_REQUIRED" == false ]] || add_error 'quality_security.acceptance_mapping_required must be true or false.'
SECURITY_REVIEW_REQUIRED="$(get_value security.review_required)"
[[ "$SECURITY_REVIEW_REQUIRED" == true || "$SECURITY_REVIEW_REQUIRED" == false ]] || add_error 'security.review_required must be true or false.'
AI_GOVERNANCE_ENABLED="$(get_value ai_governance.enabled false)"
AI_LIFECYCLE_ENABLED="$(get_value ai_lifecycle.enabled false)"
MEASUREMENT_ENABLED="$(get_value measurement.enabled false)"
get_list security.tasks
SECURITY_TASKS=("${LIST_RESULT[@]}")
get_list security.blocking_severities
BLOCKING_SEVERITIES=("${LIST_RESULT[@]}")
if (( ${#BLOCKING_SEVERITIES[@]} == 0 )); then add_error 'security.blocking_severities must contain at least one severity.'; fi
for severity in "${BLOCKING_SEVERITIES[@]}"; do
    valid=0
    for allowed in "${ALLOWED_SEVERITIES[@]}"; do [[ "$severity" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unsupported blocking severity '$severity'."
done
for security_task in "${SECURITY_TASKS[@]}"; do
    valid=0
    for allowed in sast secrets dependency_audit license_audit container_scan iac_scan dast security_tests; do [[ "$security_task" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unsupported security task '$security_task'."
done
if [[ "$SECURITY_REVIEW_REQUIRED" == true && ${#SECURITY_TASKS[@]} -eq 0 ]]; then
    WARNINGS+=('security.review_required is true but security.tasks is empty; configure at least one scanner or security test task.')
fi

VERIFICATION_CONFIGURED=0
grep -Eq '^verification:[[:space:]]*$' "$CONFIG_PATH" && VERIFICATION_CONFIGURED=1
COVERAGE_ENABLED="$(get_value verification.coverage_enabled)"
COVERAGE_TASK="$(get_value verification.coverage_task coverage)"
COVERAGE_PROVIDER="$(get_value verification.coverage_provider)"
COVERAGE_REPORT_PATH="$(get_value verification.coverage_report_path)"
COVERAGE_THRESHOLD="$(get_value verification.coverage_changed_line_threshold)"
get_list verification.coverage_excluded_paths
COVERAGE_EXCLUDED_PATHS=("${LIST_RESULT[@]}")
get_list verification.coverage_required_risk_profiles
COVERAGE_REQUIRED_RISK_PROFILES=("${LIST_RESULT[@]}")
MUTATION_ENABLED="$(get_value verification.mutation_enabled)"
MUTATION_TASK="$(get_value verification.mutation_task mutation)"
MUTATION_PROVIDER="$(get_value verification.mutation_provider)"
MUTATION_REPORT_PATH="$(get_value verification.mutation_report_path)"
MUTATION_THRESHOLD="$(get_value verification.mutation_threshold)"
get_list verification.mutation_excluded_paths
MUTATION_EXCLUDED_PATHS=("${LIST_RESULT[@]}")
get_list verification.mutation_required_risk_profiles
MUTATION_REQUIRED_RISK_PROFILES=("${LIST_RESULT[@]}")

is_allowed_verification_provider() {
    local candidate="$1" allowed
    for allowed in "${ALLOWED_VERIFICATION_PROVIDERS[@]}"; do
        [[ "$candidate" == "$allowed" ]] && return 0
    done
    return 1
}
is_valid_threshold() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v value="$candidate" 'BEGIN { exit !(value >= 0 && value <= 100) }'
}
if (( VERIFICATION_CONFIGURED == 1 )); then
    for profile in "${COVERAGE_REQUIRED_RISK_PROFILES[@]}" "${MUTATION_REQUIRED_RISK_PROFILES[@]}"; do
        case "$profile" in low|medium|high|critical) ;; '') ;; *) add_error "Verification required risk profile '$profile' is unsupported." ;; esac
    done
    for path in "${COVERAGE_EXCLUDED_PATHS[@]}" "${MUTATION_EXCLUDED_PATHS[@]}"; do
        if [[ -n "$path" ]] && ! safe_relative_path "$path"; then
            add_error "Verification excluded path must be repository-relative: $path"
        fi
    done
    [[ "$COVERAGE_ENABLED" == true || "$COVERAGE_ENABLED" == false ]] || add_error 'verification.coverage_enabled must be true or false.'
    [[ "$MUTATION_ENABLED" == true || "$MUTATION_ENABLED" == false ]] || add_error 'verification.mutation_enabled must be true or false.'
    if [[ "$COVERAGE_ENABLED" == true ]]; then
        [[ "$COVERAGE_TASK" == coverage ]] || add_error 'verification.coverage_task must be coverage.'
        is_allowed_verification_provider "$COVERAGE_PROVIDER" || add_error "Unsupported coverage provider '$COVERAGE_PROVIDER'."
        [[ -n "$COVERAGE_REPORT_PATH" ]] && safe_relative_path "$COVERAGE_REPORT_PATH" || add_error 'verification.coverage_report_path must be a safe repository-relative path.'
        is_valid_threshold "$COVERAGE_THRESHOLD" || add_error 'verification.coverage_changed_line_threshold must be a number from 0 through 100.'
        (( ${#COVERAGE_REQUIRED_RISK_PROFILES[@]} > 0 )) || add_error 'Enabled coverage requires at least one coverage_required_risk_profiles entry.'
    fi
    if [[ "$MUTATION_ENABLED" == true ]]; then
        [[ "$MUTATION_TASK" == mutation ]] || add_error 'verification.mutation_task must be mutation.'
        [[ "$MUTATION_PROVIDER" == generic-json ]] || add_error "Unsupported mutation provider '$MUTATION_PROVIDER'."
        [[ -n "$MUTATION_REPORT_PATH" ]] && safe_relative_path "$MUTATION_REPORT_PATH" || add_error 'verification.mutation_report_path must be a safe repository-relative path.'
        is_valid_threshold "$MUTATION_THRESHOLD" || add_error 'verification.mutation_threshold must be a number from 0 through 100.'
        (( ${#MUTATION_REQUIRED_RISK_PROFILES[@]} > 0 )) || add_error 'Enabled mutation requires at least one mutation_required_risk_profiles entry.'
    fi
    coverage_required=0
    for profile in "${COVERAGE_REQUIRED_RISK_PROFILES[@]}"; do [[ "$profile" == "$RISK_PROFILE" ]] && coverage_required=1; done
    mutation_required=0
    for profile in "${MUTATION_REQUIRED_RISK_PROFILES[@]}"; do [[ "$profile" == "$RISK_PROFILE" ]] && mutation_required=1; done
    if (( coverage_required == 1 )) && [[ "$COVERAGE_ENABLED" != true ]]; then
        add_error "Risk profile '$RISK_PROFILE' requires verification coverage to be enabled."
    fi
    if (( mutation_required == 1 )) && [[ "$MUTATION_ENABLED" != true ]]; then
        add_error "Risk profile '$RISK_PROFILE' requires mutation verification to be enabled."
    fi
fi

TASKS_TO_CHECK=("${REQUIRED_TASKS[@]}" "${OPTIONAL_TASKS[@]}" "${SECURITY_TASKS[@]}")
[[ "$INSTALL_TASK" == 'none' ]] || TASKS_TO_CHECK+=("$INSTALL_TASK")
if (( VERIFICATION_CONFIGURED == 1 )); then
    [[ "$COVERAGE_ENABLED" == true ]] && TASKS_TO_CHECK+=(coverage)
    [[ "$MUTATION_ENABLED" == true ]] && TASKS_TO_CHECK+=(mutation)
fi
for task in "${!TASK_EXEC[@]}"; do
    valid=0
    for allowed in "${ALLOWED_TASKS[@]}"; do [[ "$task" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unknown task registry entry '$task'."
done
for task in "${TASKS_TO_CHECK[@]}"; do
    [[ -n "$task" ]] || continue
    if [[ -z "${TASK_EXEC[$task]+present}" ]]; then
        add_error "Task '$task' is listed but has no tasks.$task record."
        continue
    fi
    executable="${TASK_EXEC[$task]-}"
    [[ -n "$executable" ]] || add_error "tasks.$task.executable is required."
    if printf '%s' "$executable" | grep -Eq '[[:space:];&|<>$]'; then
        add_error "tasks.$task.executable must be a single executable, not shell syntax."
    fi
    [[ -n "${TASK_ARGS_SET[$task]+present}" ]] || add_error "tasks.$task.args must be an inline list."
    command -v "$executable" >/dev/null 2>&1 || add_error "Executable for task '$task' is not available: $executable"
done

if [[ -z "$EVIDENCE_DIRECTORY" ]]; then
    EVIDENCE_DIRECTORY="$(get_value validation.evidence_directory .sdlc/evidence)"
fi
safe_relative_path "$EVIDENCE_DIRECTORY" || add_error "validation.evidence_directory must be repository-relative: $EVIDENCE_DIRECTORY"

if (( ${#ERRORS[@]} == 0 )); then
    echo "[PASS] Configuration schema 1 is valid for package manager '$PACKAGE_MANAGER'."
    optional_display='none'
    (( ${#OPTIONAL_TASKS[@]} > 0 )) && optional_display="${OPTIONAL_TASKS[*]}"
    echo "[PASS] Required tasks: ${REQUIRED_TASKS[*]}; optional tasks: $optional_display."
else
    echo "[FAIL] Configuration validation found ${#ERRORS[@]} error(s)."
fi

get_commit_sha() {
    git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'
}
get_tree_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'
    else
        git -C "$REPO_ROOT" diff --binary HEAD -- . ":(exclude)$SPEC_RELATIVE_PATH" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'
    fi
}
json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
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

COMMIT_SHA="$(get_commit_sha)"
TREE_DIGEST="$(get_tree_digest)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$RECORD_DIRECTORY"
RECORD_PATH="$RECORD_DIRECTORY/config-validation.json"
{
    printf '{"schema":1,"kind":"sdlc-config-validation","config_schema":'
    json_escape "$(get_value sdlc_config_schema)"
    printf ',"package_manager":'
    json_escape "$PACKAGE_MANAGER"
    printf ',"required_tasks":'
    json_array "${REQUIRED_TASKS[@]}"
    printf ',"risk_profile":'
    json_escape "$RISK_PROFILE"
    printf ',"required_test_layers":'
    json_array "${TEST_LAYERS[@]}"
    printf ',"security_tasks":'
    json_array "${SECURITY_TASKS[@]}"
    printf ',"blocking_severities":'
    json_array "${BLOCKING_SEVERITIES[@]}"
    printf ',"optional_tasks":'
    json_array "${OPTIONAL_TASKS[@]}"
    printf ',"command":"validate-sdlc-config","commit_sha":'
    json_escape "$COMMIT_SHA"
    printf ',"tree_digest":'
    json_escape "$TREE_DIGEST"
    printf ',"feature_id":'
    json_escape "$FEATURE_ID"
    printf ',"spec_path":'
    json_escape "$SPEC_RELATIVE_PATH"
    printf ',"timestamp":'
    json_escape "$TIMESTAMP"
    if (( ${#ERRORS[@]} == 0 )); then printf ',"exit_code":0,"result":"PASS"'; else printf ',"exit_code":1,"result":"FAIL"'; fi
    printf ',"errors":'
    json_array "${ERRORS[@]}"
    printf ',"warnings":'
    json_array "${WARNINGS[@]}"
    printf '}\n'
} > "$RECORD_PATH"
echo "[INFO] Validation evidence: $RECORD_PATH"

set_spec_field() {
    local key="$1" value="$2" temp="$SPEC_PATH.phase1.tmp"
    [[ -f "$SPEC_PATH" ]] || { add_error "Spec file not found for --record-spec: $SPEC_PATH"; return; }
    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" key ":" { print key ": " value; found = 1; next }
        { print }
        END { if (!found) exit 3 }
    ' "$SPEC_PATH" > "$temp" || { rm -f "$temp"; add_error "Spec metadata field '$key' was not found in $SPEC_PATH"; return; }
    mv "$temp" "$SPEC_PATH"
}

if (( RECORD_SPEC == 1 )); then
    relative_evidence="${RECORD_PATH#"$REPO_ROOT/"}"
    set_spec_field gate_config_command '"scripts/validate-sdlc-config.sh"'
    set_spec_field gate_config_commit_sha "\"$COMMIT_SHA\""
    set_spec_field gate_config_tree_digest "\"$TREE_DIGEST\""
    set_spec_field gate_config_timestamp "\"$TIMESTAMP\""
    if (( ${#ERRORS[@]} == 0 )); then set_spec_field gate_config_exit_code '0'; set_spec_field gate_config_result 'PASS'; else set_spec_field gate_config_exit_code '1'; set_spec_field gate_config_result 'FAIL'; fi
    set_spec_field gate_config_evidence "\"$relative_evidence\""
    if [[ -n "$FEATURE_ID" ]]; then
        set_spec_field gate_config_feature_id "\"$FEATURE_ID\""
        set_spec_field gate_config_spec_path "\"$SPEC_RELATIVE_PATH\""
    fi
    [[ "$SECURITY_REVIEW_REQUIRED" != true ]] || set_spec_field security_gate_enabled true
    [[ "$AI_GOVERNANCE_ENABLED" != true ]] || set_spec_field ai_governance_enabled true
    [[ "$AI_LIFECYCLE_ENABLED" != true ]] || set_spec_field ai_lifecycle_enabled true
    [[ "$MEASUREMENT_ENABLED" != true ]] || set_spec_field measurement_enabled true
    echo "[INFO] Recorded gate_config_* in $SPEC_PATH"
fi

if (( ${#ERRORS[@]} > 0 )); then exit 1; fi
exit 0
