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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY=""
SPEC_PATH=""
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
       [--evidence-directory PATH] [--spec-path PATH] [--record-spec]
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
if [[ -z "$SPEC_PATH" ]]; then
    SPEC_PATH="$REPO_ROOT/docs/spec.md"
fi
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
ALLOWED_TASKS=(install build test lint type_check)

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
    for allowed in build test lint type_check; do [[ "$task" == "$allowed" ]] && valid=1; done
    (( valid == 1 )) || add_error "Unknown validation task '$task'. Use build, test, lint, or type_check."
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

TASKS_TO_CHECK=("${REQUIRED_TASKS[@]}" "${OPTIONAL_TASKS[@]}")
[[ "$INSTALL_TASK" == 'none' ]] || TASKS_TO_CHECK+=("$INSTALL_TASK")
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
        git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'
    else
        git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'
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
    printf ',"optional_tasks":'
    json_array "${OPTIONAL_TASKS[@]}"
    printf ',"command":"validate-sdlc-config","commit_sha":'
    json_escape "$COMMIT_SHA"
    printf ',"tree_digest":'
    json_escape "$TREE_DIGEST"
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
    echo "[INFO] Recorded gate_config_* in $SPEC_PATH"
fi

if (( ${#ERRORS[@]} > 0 )); then exit 1; fi
exit 0
