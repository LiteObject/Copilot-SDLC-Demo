#!/usr/bin/env bash
#
# Run one named SDLC validation task or all configured tasks.
#
# The runner invokes structured executable/args records directly. It never
# evaluates a shell command string. Every task writes log and JSON evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_PATH=""
EVIDENCE_DIRECTORY=""
SPEC_PATH=""
TASK='all'
RECORD_SPEC=0

declare -A CFG=()
declare -A LISTS=()
declare -A TASK_EXEC=()
declare -A TASK_ARGS=()
declare -A TASK_ARGS_SET=()
CURRENT_SECTION=""
CURRENT_TASK=""
ACTIVE_LIST=""

usage() {
    cat <<'EOF'
Usage: ./scripts/run-sdlc-task.sh [--task TASK|all] [--config-path PATH]
       [--repo-root PATH] [--evidence-directory PATH] [--spec-path PATH]
       [--record-spec]
EOF
}

while (($# > 0)); do
    case "$1" in
        --task)
            [[ $# -ge 2 ]] || { echo '[FAIL] --task requires a value.'; exit 2; }
            TASK="$2"
            shift 2
            ;;
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

if [[ -z "$CONFIG_PATH" ]]; then CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"; fi
if [[ -z "$SPEC_PATH" ]]; then SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo "[FAIL] Config file not found: $CONFIG_PATH"; exit 1; fi

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
    local value="$1" trimmed inner item
    PARSED_ITEMS=()
    trimmed="$(trim_value "$value")"
    [[ "$trimmed" == '[]' ]] && return 0
    [[ "$trimmed" == \[*\] ]] || { echo "[FAIL] Expected an inline YAML list, got '$value'." >&2; return 1; }
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
                if [[ "$value" == \[*\] ]]; then parse_inline_list "$value" || exit 2; LISTS["$key"]="$(serialize_items "${PARSED_ITEMS[@]}")"; else CFG["$key"]="$(unquote_value "$value")"; fi
            fi
        elif [[ "$CURRENT_SECTION" == 'tasks' && $indent -eq 2 ]]; then
            CURRENT_TASK="$key"
        elif [[ "$CURRENT_SECTION" == 'tasks' && $indent -ge 4 && -n "$CURRENT_TASK" ]]; then
            if [[ "$key" == 'args' ]]; then parse_inline_list "$value" || exit 2; TASK_ARGS["$CURRENT_TASK"]="$(serialize_items "${PARSED_ITEMS[@]}")"; TASK_ARGS_SET["$CURRENT_TASK"]=1; else TASK_EXEC["$CURRENT_TASK"]="$(unquote_value "$value")"; fi
        else
            path="$CURRENT_SECTION.$key"
            if [[ "$value" == \[*\] ]]; then parse_inline_list "$value" || exit 2; LISTS["$path"]="$(serialize_items "${PARSED_ITEMS[@]}")"; elif [[ -n "$(trim_value "$value")" ]]; then CFG["$path"]="$(unquote_value "$value")"; else CFG["$path"]=''; ACTIVE_LIST="$path"; fi
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

get_value() { printf '%s' "${CFG[$1]-${2-}}"; }
get_list() {
    LIST_RESULT=()
    local serialized="${LISTS[$1]-}" item
    [[ -n "$serialized" ]] || return 0
    while IFS= read -r -d $'\x1f' item; do LIST_RESULT+=("$item"); done < <(printf '%s\x1f' "$serialized")
}
command_display() {
    local executable="$1" task_name="$2" serialized="${TASK_ARGS[$2]-}" item output="$executable"
    while IFS= read -r -d $'\x1f' item; do
        output+=" $item"
    done < <([[ -n "$serialized" ]] && printf '%s\x1f' "$serialized" || true)
    printf '%s' "$output"
}
get_commit_sha() { git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
get_tree_digest() {
    if command -v sha256sum >/dev/null 2>&1; then git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | sha256sum | awk '{print $1}'; else git -C "$REPO_ROOT" diff --binary HEAD -- . ':(exclude)docs/spec.md' ':(exclude).sdlc/**' 2>/dev/null | shasum -a 256 | awk '{print $1}'; fi
}
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
json_array() { local first=1 value; printf '['; for value in "$@"; do (( first == 0 )) && printf ','; json_escape "$value"; first=0; done; printf ']'; }
set_spec_field() {
    local key="$1" value="$2" temp="$SPEC_PATH.phase1.tmp"
    [[ -f "$SPEC_PATH" ]] || { echo "[FAIL] Spec file not found for --record-spec: $SPEC_PATH"; return 1; }
    if ! awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; found=1; next } { print } END { if (!found) exit 3 }' "$SPEC_PATH" > "$temp"; then rm -f "$temp"; echo "[FAIL] Spec metadata field '$key' was not found in $SPEC_PATH"; return 1; fi
    mv "$temp" "$SPEC_PATH"
}

VALIDATOR="$SCRIPT_DIR/validate-sdlc-config.sh"
validator_args=(--config-path "$CONFIG_PATH" --repo-root "$REPO_ROOT")
[[ -n "$EVIDENCE_DIRECTORY" ]] && validator_args+=(--evidence-directory "$EVIDENCE_DIRECTORY")
if (( RECORD_SPEC == 1 )); then validator_args+=(--spec-path "$SPEC_PATH" --record-spec); fi
set +e
bash "$VALIDATOR" "${validator_args[@]}"
VALIDATOR_EXIT=$?
set -e
(( VALIDATOR_EXIT == 0 )) || exit "$VALIDATOR_EXIT"

if [[ -z "$EVIDENCE_DIRECTORY" ]]; then EVIDENCE_DIRECTORY="$(get_value validation.evidence_directory .sdlc/evidence)"; fi
EVIDENCE_ROOT="$REPO_ROOT/$EVIDENCE_DIRECTORY"
mkdir -p "$EVIDENCE_ROOT"
COMMIT_SHA="$(get_commit_sha)"
TREE_DIGEST="$(get_tree_digest)"

TASK_NAMES=()
if [[ "$TASK" == 'all' ]]; then
    install_task="$(get_value validation.install_task)"
    [[ -z "$install_task" || "$install_task" == 'none' ]] || TASK_NAMES+=("$install_task")
    get_list validation.required_tasks; TASK_NAMES+=("${LIST_RESULT[@]}")
    get_list validation.optional_tasks; TASK_NAMES+=("${LIST_RESULT[@]}")
else
    TASK_NAMES=("$TASK")
fi

declare -A SEEN=()
for task_name in "${TASK_NAMES[@]}"; do
    [[ -n "${SEEN[$task_name]+present}" ]] && continue
    SEEN["$task_name"]=1
    [[ -n "${TASK_EXEC[$task_name]+present}" ]] || { echo "[FAIL] Task '$task_name' is not configured."; exit 1; }
    executable="${TASK_EXEC[$task_name]}"
    serialized="${TASK_ARGS[$task_name]-}"
    TASK_ARGUMENTS=()
    if [[ -n "$serialized" ]]; then while IFS= read -r -d $'\x1f' item; do TASK_ARGUMENTS+=("$item"); done < <(printf '%s\x1f' "$serialized"); fi
    command="$(command_display "$executable" "$task_name")"
    log_path="$EVIDENCE_ROOT/$task_name.log"
    record_path="$EVIDENCE_ROOT/$task_name.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[RUN] $task_name: $command"
    set +e
    (cd "$REPO_ROOT" && "$executable" "${TASK_ARGUMENTS[@]}" 2>&1 | tee "$log_path")
    exit_code=${PIPESTATUS[0]}
    set -e
    finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if (( exit_code == 0 )); then result='PASS'; else result='FAIL'; fi
    relative_log="${log_path:${#REPO_ROOT}}"
    relative_log="${relative_log#/}"
    {
        printf '{"schema":1,"kind":"sdlc-task","task":'; json_escape "$task_name"; printf ',"executable":'; json_escape "$executable"; printf ',"args":'; json_array "${TASK_ARGUMENTS[@]}"; printf ',"command":'; json_escape "$command"; printf ',"commit_sha":'; json_escape "$COMMIT_SHA"; printf ',"tree_digest":'; json_escape "$TREE_DIGEST"; printf ',"started_at":'; json_escape "$started_at"; printf ',"finished_at":'; json_escape "$finished_at"; printf ',"exit_code":%d,"result":"%s","evidence":' "$exit_code" "$result"; json_escape "$relative_log"; printf '}\n'
    } > "$record_path"
    if (( RECORD_SPEC == 1 )); then
        set_spec_field "gate_${task_name}_command" "\"$command\""
        set_spec_field "gate_${task_name}_commit_sha" "\"$COMMIT_SHA\""
        set_spec_field "gate_${task_name}_tree_digest" "\"$TREE_DIGEST\""
        set_spec_field "gate_${task_name}_timestamp" "\"$finished_at\""
        set_spec_field "gate_${task_name}_exit_code" "$exit_code"
        set_spec_field "gate_${task_name}_result" "$result"
        set_spec_field "gate_${task_name}_evidence" "\"$relative_log\""
    fi
    echo "[$result] $task_name; evidence: $record_path"
    (( exit_code == 0 )) || exit "$exit_code"
done

echo "[PASS] SDLC task run complete: ${TASK_NAMES[*]}"
exit 0
