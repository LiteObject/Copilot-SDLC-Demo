#!/usr/bin/env bash
#
# Compare changed files with the explicit planned_files scope in docs/spec.md.
#
# Exact paths are the default. Glob patterns are accepted only when a matching
# approved_globs record contains pattern, justification, approver, revision,
# and timestamp fields separated by '|'. Directory entries such as src/ are
# rejected.
#
# Exit codes:
#   0 - scope is clean
#   1 - scope creep or missing files detected
#   2 - the scope plan could not be parsed or is invalid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/feature-context.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH=""
FEATURE_ID=""
SPEC_RELATIVE_PATH='docs/spec.md'
BASE_REF='HEAD'

usage() {
    cat <<'EOF'
Usage: ./scripts/scope-audit.sh [BASE_REF] [--feature-id ID] [--spec-path PATH] [--repo-root PATH]
EOF
}

while (($# > 0)); do
    case "$1" in
        --spec-path)
            [[ $# -ge 2 ]] || { echo '[ERROR] --spec-path requires a value.'; exit 2; }
            SPEC_PATH="$2"
            shift 2
            ;;
        --feature-id)
            [[ $# -ge 2 ]] || { echo '[ERROR] --feature-id requires a value.'; exit 2; }
            FEATURE_ID="$2"
            shift 2
            ;;
        --repo-root)
            [[ $# -ge 2 ]] || { echo '[ERROR] --repo-root requires a value.'; exit 2; }
            REPO_ROOT="$2"
            shift 2
            ;;
        --base-ref)
            [[ $# -ge 2 ]] || { echo '[ERROR] --base-ref requires a value.'; exit 2; }
            BASE_REF="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            if [[ "$BASE_REF" != 'HEAD' ]]; then
                echo "[ERROR] Unexpected argument: $1"
                exit 2
            fi
            BASE_REF="$1"
            shift
            ;;
    esac
done

if ! resolve_feature_context "$REPO_ROOT" "$SPEC_PATH" "$FEATURE_ID" ''; then exit 2; fi
if [[ ! -f "$SPEC_PATH" ]]; then
    echo "[ERROR] docs/spec.md not found at: $SPEC_PATH"
    exit 2
fi

CONTENT="$(tr -d '\r' < "$SPEC_PATH")"
if ! FRONT_MATTER="$(printf '%s\n' "$CONTENT" | awk '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { found = 1; exit }
    inside { print }
    END { if (!found) exit 2 }
')"; then
    echo "[ERROR] docs/spec.md must start with YAML front matter delimited by '---'."
    exit 2
fi

declare -A META=()
declare -a PLANNED_FILES=()
declare -a APPROVED_GLOBS=()
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
        if [[ "$key" == 'planned_files' || "$key" == 'approved_globs' ]]; then
            if [[ "$value" == '[]' ]]; then
                :
            elif [[ -z "$value" ]]; then
                ACTIVE_LIST="$key"
            else
                echo "[ERROR] Metadata list '$key' must use [] or an indented YAML list."
                exit 2
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
        echo "[ERROR] Unsupported YAML front matter line: $line"
        exit 2
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
        echo "[ERROR] Spec feature_id '$declared_feature_id' does not match requested feature '$FEATURE_ID'."
        exit 2
    fi
    if [[ "$declared_spec_path" != "$SPEC_RELATIVE_PATH" ]]; then
        echo "[ERROR] Spec spec_path '$declared_spec_path' does not match '$SPEC_RELATIVE_PATH'."
        exit 2
    fi
fi

for key in sdlc_schema planned_files approved_globs; do
    if [[ -z "${META[$key]+present}" ]]; then
        echo "[ERROR] Required workflow metadata '$key' is missing."
        exit 2
    fi
done
if [[ "$(meta_get sdlc_schema)" != '1' ]]; then
    echo "[ERROR] Unsupported sdlc_schema '$(meta_get sdlc_schema)'. Expected '1'."
    exit 2
fi

normalize_path() {
    local value="$1"
    value="${value//\\//}"
    while [[ "$value" == ./* ]]; do
        value="${value#./}"
    done
    printf '%s' "$value"
}

is_glob() {
    [[ "$1" == *'*'* || "$1" == *'?'* || "$1" == *'['* ]]
}

has_valid_glob_approval() {
    local pattern="$1"
    local revision="$(meta_get revision_commit_sha)"
    local record approval_pattern justification approver approval_revision timestamp
    for record in "${APPROVED_GLOBS[@]}"; do
        IFS='|' read -r approval_pattern justification approver approval_revision timestamp <<< "$record"
        approval_pattern="$(normalize_path "$approval_pattern")"
        justification="$(trim_value "${justification-}")"
        approver="$(trim_value "${approver-}")"
        approval_revision="$(trim_value "${approval_revision-}")"
        timestamp="$(trim_value "${timestamp-}")"
        if [[ "$approval_pattern" == "$pattern" && -n "$justification" && -n "$approver" &&
              -n "$approval_revision" && -n "$timestamp" &&
              ( -z "$revision" || "$approval_revision" == "$revision" ) ]]; then
            return 0
        fi
    done
    return 1
}

glob_to_regex() {
    local pattern="$1"
    local regex='' char next index=0
    while (( index < ${#pattern} )); do
        char="${pattern:index:1}"
        if [[ "$char" == '*' && "${pattern:index+1:1}" == '*' ]]; then
            regex+='.*'
            ((index += 2))
            continue
        fi
        case "$char" in
            '*') regex+='[^/]*' ;;
            '?') regex+='[^/]' ;;
            '.'|'+'|'^'|'$'|'('|')'|'|'|'{'|'}'|'['|']'|'\\') regex+="\\$char" ;;
            *) regex+="$char" ;;
        esac
        ((index += 1))
    done
    printf '^%s$' "$regex"
}

declare -a PLAN_PATTERNS=()
declare -a PLAN_IS_GLOB=()
declare -a PLAN_APPROVED=()
declare -a INVALID_PLAN=()
declare -a UNAPPROVED_GLOBS=()

for raw_path in "${PLANNED_FILES[@]}"; do
    path="$(normalize_path "$raw_path")"
    [[ -n "$path" ]] || continue
    if [[ "$path" == /* || "$path" =~ ^[A-Za-z]:/ || "$path" =~ (^|/)\.\.(/|$) ]]; then
        INVALID_PLAN+=("$path (path must be relative)")
        continue
    fi
    if [[ "$path" == */ ]]; then
        INVALID_PLAN+=("$path (directory entries are not allowed; list exact files)")
        continue
    fi
    PLAN_PATTERNS+=("$path")
    if is_glob "$path"; then
        PLAN_IS_GLOB+=(1)
        if has_valid_glob_approval "$path"; then
            PLAN_APPROVED+=(1)
        else
            PLAN_APPROVED+=(0)
            UNAPPROVED_GLOBS+=("$path")
        fi
    else
        PLAN_IS_GLOB+=(0)
        PLAN_APPROVED+=(1)
    fi
done

echo '=== Scope Audit ==='
[[ -n "$FEATURE_ID" ]] && echo "Feature: $FEATURE_ID"
echo "Planned files: ${#PLAN_PATTERNS[@]}"
echo "Base ref: $BASE_REF"
echo
if (( ${#INVALID_PLAN[@]} > 0 )); then
    echo "[PLAN_INVALID] (${#INVALID_PLAN[@]})"
    printf '  !!  %s\n' "${INVALID_PLAN[@]}"
    echo
fi
if (( ${#UNAPPROVED_GLOBS[@]} > 0 )); then
    echo "[PLAN_INVALID] (${#UNAPPROVED_GLOBS[@]}) unapproved glob patterns"
    for pattern in "${UNAPPROVED_GLOBS[@]}"; do
        echo "  !!  $pattern requires an approved_globs record"
    done
    echo
fi

declare -a CHANGED_FILES=()
pushd "$REPO_ROOT" >/dev/null
if [[ "$BASE_REF" == 'staged' ]]; then
    mapfile -t CHANGED_FILES < <(git diff --cached --name-only 2>/dev/null | tr -d '\r' | sort -u || true)
elif [[ "$BASE_REF" == 'HEAD' ]]; then
    mapfile -t CHANGED_FILES < <({ git diff --cached --name-only 2>/dev/null; git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | tr -d '\r' | sort -u || true)
else
    mapfile -t CHANGED_FILES < <(git diff --name-only "$BASE_REF" 2>/dev/null | tr -d '\r' | sort -u || true)
fi
popd >/dev/null

if (( ${#CHANGED_FILES[@]} == 0 )); then
    echo '[INFO] No changed files detected.'
else
    echo "Changed files (${#CHANGED_FILES[@]}):"
    printf '  %s\n' "${CHANGED_FILES[@]}"
    echo
fi

declare -a WORKFLOW_CHANGES=()
declare -a IN_SCOPE=()
declare -a SCOPE_CREEP=()

for file in "${CHANGED_FILES[@]}"; do
    file="$(normalize_path "$file")"
    is_feature_workflow=0
    if [[ -n "$FEATURE_ID" && ( "$file" == "$SPEC_RELATIVE_PATH" || "$file" == ".sdlc/evidence/$FEATURE_ID" || "$file" == ".sdlc/evidence/$FEATURE_ID"/* ) ]]; then
        is_feature_workflow=1
    fi
    is_legacy_workflow=0
    if [[ -z "$FEATURE_ID" && ( "$file" == 'docs/spec.md' || "$file" == '.sdlc' || "$file" == .sdlc/* ) ]]; then
        is_legacy_workflow=1
    fi
    if (( is_feature_workflow == 1 || is_legacy_workflow == 1 )); then
        WORKFLOW_CHANGES+=("$file")
        continue
    fi
    matched=0
    for ((index = 0; index < ${#PLAN_PATTERNS[@]}; index++)); do
        pattern="${PLAN_PATTERNS[$index]}"
        if (( ${PLAN_IS_GLOB[$index]} == 1 )); then
            if (( ${PLAN_APPROVED[$index]} == 1 )) && [[ "$file" =~ $(glob_to_regex "$pattern") ]]; then
                matched=1
                break
            fi
        elif [[ "$file" == "$pattern" ]]; then
            matched=1
            break
        fi
    done
    if (( matched == 1 )); then
        IN_SCOPE+=("$file")
    else
        SCOPE_CREEP+=("$file")
    fi
done

declare -a MISSING=()
for ((index = 0; index < ${#PLAN_PATTERNS[@]}; index++)); do
    (( ${PLAN_IS_GLOB[$index]} == 1 )) && continue
    if [[ ! -f "$REPO_ROOT/${PLAN_PATTERNS[$index]}" ]]; then
        MISSING+=("${PLAN_PATTERNS[$index]}")
    fi
done

echo '=== Results ==='
echo
if (( ${#WORKFLOW_CHANGES[@]} > 0 )); then
    echo "[WORKFLOW] (${#WORKFLOW_CHANGES[@]} files excluded from product scope)"
    printf '  OK  %s\n' "${WORKFLOW_CHANGES[@]}"
    echo
fi
if (( ${#IN_SCOPE[@]} > 0 )); then
    echo "[IN_SCOPE] (${#IN_SCOPE[@]} files)"
    printf '  OK  %s\n' "${IN_SCOPE[@]}"
    echo
fi
if (( ${#SCOPE_CREEP[@]} > 0 )); then
    echo "[SCOPE_CREEP] (${#SCOPE_CREEP[@]} files) - changed files not in planned_files:"
    printf '  !!  %s\n' "${SCOPE_CREEP[@]}"
    echo
fi
if (( ${#MISSING[@]} > 0 )); then
    echo "[MISSING] (${#MISSING[@]} files) - exact planned files not present:"
    printf '  ??  %s\n' "${MISSING[@]}"
    echo
fi
if (( ${#INVALID_PLAN[@]} == 0 && ${#UNAPPROVED_GLOBS[@]} == 0 && ${#SCOPE_CREEP[@]} == 0 && ${#MISSING[@]} == 0 )); then
    echo '[PASS] All changes are within the approved planned scope.'
fi

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

clean=true
if (( ${#INVALID_PLAN[@]} > 0 || ${#UNAPPROVED_GLOBS[@]} > 0 || ${#SCOPE_CREEP[@]} > 0 || ${#MISSING[@]} > 0 )); then
    clean=false
fi
echo '--- JSON Summary ---'
printf '{"planned":%d,"changed":%d,"workflow":' "${#PLAN_PATTERNS[@]}" "${#CHANGED_FILES[@]}"
json_array "${WORKFLOW_CHANGES[@]}"
printf '%s' ',"in_scope":'
json_array "${IN_SCOPE[@]}"
printf '%s' ',"scope_creep":'
json_array "${SCOPE_CREEP[@]}"
printf '%s' ',"missing":'
json_array "${MISSING[@]}"
printf '%s' ',"invalid_plan":'
json_array "${INVALID_PLAN[@]}"
printf '%s' ',"unapproved_globs":'
json_array "${UNAPPROVED_GLOBS[@]}"
printf ',"clean":%s}\n' "$clean"

if (( ${#INVALID_PLAN[@]} > 0 || ${#UNAPPROVED_GLOBS[@]} > 0 )); then
    exit 2
fi
if (( ${#SCOPE_CREEP[@]} > 0 || ${#MISSING[@]} > 0 )); then
    exit 1
fi
exit 0
