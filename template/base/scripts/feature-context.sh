#!/usr/bin/env bash
#
# Shared feature workflow path contract for the SDLC shell scripts.
#
# Call resolve_feature_context REPO_ROOT SPEC_PATH FEATURE_ID EVIDENCE_DIRECTORY.
# It updates the caller's REPO_ROOT, SPEC_PATH, FEATURE_ID,
# SPEC_RELATIVE_PATH, EVIDENCE_DIRECTORY, and FEATURE_EVIDENCE_PREFIX variables.

resolve_feature_context() {
    local requested_root="$1"
    local requested_spec_path="$2"
    local requested_feature_id="$3"
    local requested_evidence_directory="$4"
    local expected_spec_path expected_evidence_directory requested_spec_relative

    REPO_ROOT="$(cd "$requested_root" 2>/dev/null && pwd)" || {
        echo "[FAIL] Repository root does not exist: $requested_root" >&2
        return 1
    }
    FEATURE_ID="$requested_feature_id"
    if [[ -n "$FEATURE_ID" ]]; then
        if ! [[ "$FEATURE_ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
            echo "[FAIL] Feature ID '$FEATURE_ID' is invalid. Use lowercase letters, numbers, and single hyphens only." >&2
            return 1
        fi
        SPEC_RELATIVE_PATH="docs/specs/$FEATURE_ID/spec.md"
        expected_spec_path="$REPO_ROOT/$SPEC_RELATIVE_PATH"
        if [[ -n "$requested_spec_path" ]]; then
            requested_spec_relative="${requested_spec_path//\\//}"
            while [[ "$requested_spec_relative" == ./* ]]; do requested_spec_relative="${requested_spec_relative#./}"; done
            if [[ "$requested_spec_relative" == /* || "$requested_spec_relative" =~ ^[A-Za-z]:/ ]]; then
                [[ "$requested_spec_relative" == "$expected_spec_path" ]] || {
                    echo "[FAIL] Feature '$FEATURE_ID' must use spec path '$SPEC_RELATIVE_PATH'." >&2
                    return 1
                }
            elif [[ "$requested_spec_relative" != "$SPEC_RELATIVE_PATH" ]]; then
                echo "[FAIL] Feature '$FEATURE_ID' must use spec path '$SPEC_RELATIVE_PATH'." >&2
                return 1
            fi
        fi
        SPEC_PATH="$expected_spec_path"
        expected_evidence_directory=".sdlc/evidence/$FEATURE_ID"
        if [[ -n "$requested_evidence_directory" ]]; then
            requested_evidence_directory="${requested_evidence_directory//\\//}"
            while [[ "$requested_evidence_directory" == ./* ]]; do requested_evidence_directory="${requested_evidence_directory#./}"; done
            if [[ "$requested_evidence_directory" != '.sdlc/evidence' &&
                  "$requested_evidence_directory" != "$expected_evidence_directory" ]]; then
                echo "[FAIL] Feature '$FEATURE_ID' must use evidence directory '$expected_evidence_directory'." >&2
                return 1
            fi
        fi
        EVIDENCE_DIRECTORY="$expected_evidence_directory"
        FEATURE_EVIDENCE_PREFIX="$expected_evidence_directory/"
        return 0
    fi

    SPEC_RELATIVE_PATH='docs/spec.md'
    if [[ -n "$requested_spec_path" ]]; then SPEC_PATH="$requested_spec_path"; else SPEC_PATH="$REPO_ROOT/docs/spec.md"; fi
    EVIDENCE_DIRECTORY="$requested_evidence_directory"
    FEATURE_EVIDENCE_PREFIX='.sdlc/evidence/'
}
