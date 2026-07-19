#!/usr/bin/env bash
#
# scope-audit.sh — Compare the actual git diff against the Implementation Plan
# in docs/spec.md to detect scope creep, missing files, and drift.
#
# Reads the File Structure from the Implementation Plan section of
# docs/spec.md, then compares it against the current git diff (staged +
# unstaged + untracked). Produces a structured report categorizing every
# changed file as IN_SCOPE, SCOPE_CREEP, or plan items NOT_FOUND.
#
# Designed to be called by the Reviewer agent during REVIEW, but also usable
# as a pre-commit hook or CI step.
#
# Exit codes:
#   0 — All changes within planned scope.
#   1 — Scope creep or missing files detected.
#   2 — Could not parse the spec file.
#
# Usage:
#   ./scripts/scope-audit.sh               # check uncommitted changes
#   ./scripts/scope-audit.sh origin/main   # check branch against main
#   ./scripts/scope-audit.sh staged        # check staged changes only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH="${REPO_ROOT}/docs/spec.md"
BASE_REF="${1:-HEAD}"

if [ ! -f "$SPEC_PATH" ]; then
    echo "[ERROR] docs/spec.md not found at: $SPEC_PATH"
    exit 2
fi

CONTENT=$(cat "$SPEC_PATH")

# ── Extract the planned file list ─────────────────
# Look for the File Structure code block.
FILE_BLOCK=$(echo "$CONTENT" | awk '/^## File Structure/{found=1; next} found && /^```/{if(++cnt==1){next} else{exit}} found && cnt==1')

if [ -z "$FILE_BLOCK" ]; then
    echo "[ERROR] Could not find '## File Structure' section with a code block in docs/spec.md"
    exit 2
fi

# Parse planned files: strip comments, blank lines, and trim.
PLANNED_FILES=()
while IFS= read -r line; do
    line=$(echo "$line" | xargs)
    if [ -n "$line" ] && [[ ! "$line" =~ ^# ]] && [[ ! "$line" =~ ^// ]]; then
        PLANNED_FILES+=("$line")
    fi
done <<< "$FILE_BLOCK"

echo "=== Scope Audit ==="
echo "Planned files: ${#PLANNED_FILES[@]}"
echo "Base ref: $BASE_REF"
echo ""

# ── Get the actual changed files ──────────────────
CHANGED_FILES=()

pushd "$REPO_ROOT" > /dev/null

if [ "$BASE_REF" = "staged" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && CHANGED_FILES+=("$f")
    done < <(git diff --cached --name-only 2>/dev/null || true)
elif [ "$BASE_REF" = "HEAD" ]; then
    # Uncommitted: staged + unstaged + untracked.
    while IFS= read -r f; do
        [ -n "$f" ] && CHANGED_FILES+=("$f")
    done < <( { git diff --cached --name-only 2>/dev/null; git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u || true)
else
    while IFS= read -r f; do
        [ -n "$f" ] && CHANGED_FILES+=("$f")
    done < <(git diff --name-only "$BASE_REF" 2>/dev/null || true)
fi

popd > /dev/null

if [ ${#CHANGED_FILES[@]} -eq 0 ]; then
    echo "[INFO] No changed files detected. Scope is clean."
    exit 0
fi

echo "Changed files (${#CHANGED_FILES[@]}):"
for f in "${CHANGED_FILES[@]}"; do echo "  $f"; done
echo ""

# ── Classify each changed file ────────────────────
IN_SCOPE=()
SCOPE_CREEP=()

for file in "${CHANGED_FILES[@]}"; do
    matched=0
    for plan_file in "${PLANNED_FILES[@]}"; do
        if [ "$file" = "$plan_file" ]; then
            matched=1
            break
        fi
        # Match ** wildcard patterns.
        if [[ "$plan_file" == *"**"* ]]; then
            pattern="${plan_file//\*\*/.*}"
            if [[ "$file" =~ ^${pattern}$ ]]; then
                matched=1
                break
            fi
        fi
        # Match directory prefixes.
        if [[ "$plan_file" == */ ]] && [[ "$file" == "$plan_file"* ]]; then
            matched=1
            break
        fi
    done
    if [ "$matched" -eq 1 ]; then
        IN_SCOPE+=("$file")
    else
        SCOPE_CREEP+=("$file")
    fi
done

# ── Detect planned files NOT created ───────────────
MISSING=()
for plan_file in "${PLANNED_FILES[@]}"; do
    # Skip directory-wide patterns and globs.
    if [[ "$plan_file" == */ ]] || [[ "$plan_file" == *"**"* ]]; then
        continue
    fi
    if [ ! -f "$REPO_ROOT/$plan_file" ]; then
        MISSING+=("$plan_file")
    fi
done

# ── Report ────────────────────────────────────────
echo "=== Results ==="
echo ""

HAS_ISSUES=0

if [ ${#IN_SCOPE[@]} -gt 0 ]; then
    echo "[IN_SCOPE] (${#IN_SCOPE[@]} files)"
    for f in "${IN_SCOPE[@]}"; do echo "  OK  $f"; done
    echo ""
fi

if [ ${#SCOPE_CREEP[@]} -gt 0 ]; then
    HAS_ISSUES=1
    echo "[SCOPE_CREEP] (${#SCOPE_CREEP[@]} files) — touched files NOT in the plan:"
    for f in "${SCOPE_CREEP[@]}"; do echo "  !!  $f"; done
    echo ""
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    HAS_ISSUES=1
    echo "[MISSING] (${#MISSING[@]} files) — planned files NOT created:"
    for f in "${MISSING[@]}"; do echo "  ??  $f"; done
    echo ""
fi

if [ "$HAS_ISSUES" -eq 0 ]; then
    echo "[PASS] All changes are within planned scope. No scope creep detected."
    echo ""
fi

# ── Summary JSON (for programmatic consumers) ─────
json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

json_array() {
    local first=1
    local value
    printf '['
    for value in "$@"; do
        if [ "$first" -eq 0 ]; then
            printf ','
        fi
        json_escape "$value"
        first=0
    done
    printf ']'
}

echo "--- JSON Summary ---"
printf '{"planned":%d,"changed":%d,"in_scope":' "${#PLANNED_FILES[@]}" "${#CHANGED_FILES[@]}"
json_array "${IN_SCOPE[@]}"
printf ',"scope_creep":'
json_array "${SCOPE_CREEP[@]}"
printf ',"missing":'
json_array "${MISSING[@]}"
if [ "$HAS_ISSUES" -eq 0 ]; then
    printf ',"clean":true}\n'
else
    printf ',"clean":false}\n'
fi

if [ "$HAS_ISSUES" -eq 1 ]; then
    exit 1
fi
exit 0
