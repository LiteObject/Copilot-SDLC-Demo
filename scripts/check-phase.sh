#!/usr/bin/env bash
#
# check-phase.sh — Validate the SDLC state file (docs/spec.md) before advancing
# phases.
#
# Checks that docs/spec.md is well-formed and that the current phase's required
# sections are populated. Designed to be called by the SDLC Supervisor agent
# before advancing state, and also usable as a manual pre-flight check.
#
# Exit codes:
#   0 — All checks passed.
#   1 — State file missing or malformed.
#   2 — Current phase prerequisites not met.
#
# Usage:
#   ./scripts/check-phase.sh              # validate current phase
#   ./scripts/check-phase.sh CODING       # validate prerequisites for CODING

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_PATH="${REPO_ROOT}/docs/spec.md"
PHASE="${1:-}"

if [ ! -f "$SPEC_PATH" ]; then
    echo "[FAIL] docs/spec.md not found at: $SPEC_PATH"
    exit 1
fi

CONTENT=$(cat "$SPEC_PATH" | tr -d '\r')

# ── Extract current state ──────────────────────────
VALID_STATES=("GATHERING_REQS" "DESIGN" "PLANNING" "CODING" "REVIEW" "TESTING" "DEPLOYMENT_READINESS" "DONE")

CURRENT_STATE=$(echo "$CONTENT" | awk '/^## Current State$/{found=1; next} found && /`/{gsub(/`/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}')

if [ -z "$CURRENT_STATE" ]; then
    echo "[FAIL] Could not find '## Current State' section with a valid state value."
    exit 1
fi

VALID=0
for s in "${VALID_STATES[@]}"; do
    if [ "$CURRENT_STATE" = "$s" ]; then
        VALID=1
        break
    fi
done

if [ "$VALID" -eq 0 ]; then
    echo "[FAIL] Invalid Current State: '$CURRENT_STATE'. Must be one of: ${VALID_STATES[*]}"
    exit 1
fi

# ── Phase prerequisite checks ──────────────────────
# Ordered state list (indices matter).
STATES=("GATHERING_REQS" "DESIGN" "PLANNING" "CODING" "REVIEW" "TESTING" "DEPLOYMENT_READINESS" "DONE")

# Determine target phase: if explicit, use it; otherwise the phase AFTER current.
if [ -n "$PHASE" ]; then
    TARGET_PHASE="$PHASE"
else
    CURRENT_INDEX=-1
    for i in "${!STATES[@]}"; do
        if [ "${STATES[$i]}" = "$CURRENT_STATE" ]; then
            CURRENT_INDEX=$i
            break
        fi
    done
    NEXT_INDEX=$((CURRENT_INDEX + 1))
    if [ "$NEXT_INDEX" -ge "${#STATES[@]}" ]; then
        echo "[PASS] Already at final state: $CURRENT_STATE"
        exit 0
    fi
    TARGET_PHASE="${STATES[$NEXT_INDEX]}"
fi

# Sections required to be populated BEFORE entering each phase.
declare -A SECTIONS
SECTIONS["GATHERING_REQS"]="Goal|Requirements|Acceptance Criteria|Out of Scope"
SECTIONS["DESIGN"]="Design"
SECTIONS["PLANNING"]="Tech Stack|File Structure|Implementation Plan"
SECTIONS["CODING"]="Implementation Plan"
SECTIONS["REVIEW"]="Review Findings"
SECTIONS["TESTING"]="Test Results"
SECTIONS["DEPLOYMENT_READINESS"]="Deployment Readiness"
SECTIONS["DONE"]=""

# Find the index of the target phase.
TARGET_INDEX=-1
for i in "${!STATES[@]}"; do
    if [ "${STATES[$i]}" = "$TARGET_PHASE" ]; then
        TARGET_INDEX=$i
        break
    fi
done

if [ "$TARGET_INDEX" -lt 0 ]; then
    echo "[FAIL] Invalid target phase: '$TARGET_PHASE'. Must be one of: ${STATES[*]}"
    exit 1
fi

echo "Checking phase prerequisites up to: $TARGET_PHASE (current state: $CURRENT_STATE)"

ALL_PASSED=1

for ((idx = 0; idx < TARGET_INDEX; idx++)); do
    STATE="${STATES[$idx]}"
    REQUIRED="${SECTIONS[$STATE]:-}"

    if [ -z "$REQUIRED" ]; then
        continue
    fi

    # Skip DESIGN when the workflow has already bypassed it for a non-UI project.
    if [ "$STATE" = "DESIGN" ]; then
        if [ "$CURRENT_STATE" != "DESIGN" ]; then
            echo "[SKIP] Phase 'DESIGN' was bypassed for this project."
            continue
        fi
    fi

    # Skip DEPLOYMENT_READINESS if the config flag is off.
    if [ "$STATE" = "DEPLOYMENT_READINESS" ]; then
        CONFIG_PATH="$REPO_ROOT/.github/sdlc-config.yml"
        if [ -f "$CONFIG_PATH" ]; then
            if grep -q 'deployment_readiness_gate:\s*false' "$CONFIG_PATH"; then
                echo "[SKIP] Phase 'DEPLOYMENT_READINESS' is disabled in .github/sdlc-config.yml."
                continue
            fi
        fi
    fi

    IFS='|' read -ra SECTION_LIST <<< "$REQUIRED"
    for SECTION in "${SECTION_LIST[@]}"; do
        # Extract everything between "## <section>" and the next "## " or "---" or end of file.
        BODY=$(echo "$CONTENT" | awk "/^## $SECTION$/{found=1; next} /^## |^---$/{if(found) exit} found{print}")

        if [ -z "$BODY" ] && ! echo "$CONTENT" | grep -q "^## $SECTION$"; then
            echo "[FAIL] Phase '$STATE': section '## $SECTION' not found."
            ALL_PASSED=0
            continue
        fi

        # Strip placeholders, HTML comments, code fences, empty checkboxes, and blank list items.
        CLEAN=$(echo "$BODY" \
            | sed '/^[[:space:]]*```/d' \
            | sed 's/<!--.*-->//g' \
            | sed '/^_.*PM.*_$/d' \
            | sed '/^_.*Designer.*_$/d' \
            | sed '/^_.*Architect.*_$/d' \
            | sed '/^_.*Reviewer.*_$/d' \
            | sed '/^_.*QA.*_$/d' \
            | sed 's/(PM[^)]*)//g' \
            | sed 's/(Designer[^)]*)//g' \
            | sed 's/(Architect[^)]*)//g' \
            | sed 's/(Reviewer[^)]*)//g' \
            | sed 's/(QA[^)]*)//g' \
            | sed 's/^- \[ \]$//g' \
            | sed 's/^[[:space:]]*-[[:space:]]*$//g' \
            | sed -E 's/^[[:space:]]*[0-9]+\.[[:space:]]*$//g' \
            | sed '/^$/d' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$CLEAN" ]; then
            echo "[FAIL] Phase '$STATE': section '## $SECTION' appears empty."
            ALL_PASSED=0
        else
            echo "[PASS] Phase '$STATE': section '## $SECTION' is populated."
        fi
    done
done

# ── Final result ───────────────────────────────────
if [ "$ALL_PASSED" -eq 1 ]; then
    echo "[PASS] All prerequisite checks passed for phase: $TARGET_PHASE"
    exit 0
else
    echo "[FAIL] Some prerequisite checks failed. See output above."
    exit 2
fi
