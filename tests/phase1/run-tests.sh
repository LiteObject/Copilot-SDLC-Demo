#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$ROOT/tests/fixtures/phase1"
CONFIG_VALIDATOR="$ROOT/template/base/scripts/validate-sdlc-config.sh"
TASK_RUNNER="$ROOT/template/base/scripts/run-sdlc-task.sh"
PHASE_VALIDATOR="$ROOT/template/base/scripts/check-phase.sh"
SPEC_TEMPLATE="$ROOT/template/base/docs/spec.md"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase1-bash.XXXXXX")"
FAILURES=0

if [[ -d '/c/Program Files/nodejs' ]]; then
    export PATH="/c/Program Files/nodejs:$PATH"
fi

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

assert_condition() {
    local label="$1" condition="$2"
    if [[ "$condition" == 'true' ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; ((FAILURES += 1)); fi
}

new_test_repo() {
    local name="$1" fixture="$2" repo="$TEMP_ROOT/$1"
    mkdir -p "$repo/.github" "$repo/docs" "$repo/tests"
    cp "$FIXTURE_ROOT/$fixture" "$repo/.github/sdlc-config.yml"
    cp "$SPEC_TEMPLATE" "$repo/docs/spec.md"
    printf '%s' "$repo"
}

valid_repo="$(new_test_repo valid config-valid.yml)"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$valid_repo" --record-spec >/dev/null
valid_config_exit=$?
set -e
assert_condition 'valid config passes Bash validation' "$([[ "$valid_config_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'config evidence exists' "$(test -f "$valid_repo/.sdlc/evidence/config-validation.json" && echo true || echo false)"

set +e
bash "$TASK_RUNNER" --repo-root "$valid_repo" --task all --record-spec >/dev/null
valid_task_exit=$?
set -e
assert_condition 'all configured tasks pass' "$([[ "$valid_task_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'build log exists' "$(test -f "$valid_repo/.sdlc/evidence/build.log" && echo true || echo false)"
assert_condition 'test JSON evidence exists' "$(test -f "$valid_repo/.sdlc/evidence/test.json" && echo true || echo false)"
assert_condition 'config gate is recorded' "$(grep -Eq '^gate_config_result:[[:space:]]+PASS[[:space:]]*$' "$valid_repo/docs/spec.md" && echo true || echo false)"
assert_condition 'build gate is recorded' "$(grep -Eq '^gate_build_result:[[:space:]]+PASS[[:space:]]*$' "$valid_repo/docs/spec.md" && echo true || echo false)"
assert_condition 'test gate is recorded' "$(grep -Eq '^gate_test_result:[[:space:]]+PASS[[:space:]]*$' "$valid_repo/docs/spec.md" && echo true || echo false)"

invalid_repo="$(new_test_repo invalid config-invalid.yml)"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$invalid_repo" >/dev/null
invalid_exit=$?
set -e
assert_condition 'invalid config fails validation' "$([[ "$invalid_exit" -eq 1 ]] && echo true || echo false)"

shell_invalid_repo="$(new_test_repo shell-invalid config-shell-invalid.yml)"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$shell_invalid_repo" >/dev/null
shell_invalid_exit=$?
set -e
assert_condition 'shell syntax in executable is rejected' "$([[ "$shell_invalid_exit" -eq 1 ]] && echo true || echo false)"

failing_repo="$(new_test_repo failing config-failing-test.yml)"
set +e
bash "$TASK_RUNNER" --repo-root "$failing_repo" --task test --record-spec >/dev/null
failing_exit=$?
set -e
assert_condition 'failing named task returns its process code' "$([[ "$failing_exit" -eq 3 ]] && echo true || echo false)"
assert_condition 'failed task gate is recorded' "$(grep -Eq '^gate_test_result:[[:space:]]+FAIL[[:space:]]*$' "$failing_repo/docs/spec.md" && echo true || echo false)"
assert_condition 'failed task evidence exists' "$(test -f "$failing_repo/.sdlc/evidence/test.json" && echo true || echo false)"

set +e
bash "$PHASE_VALIDATOR" CODING --spec-path "$FIXTURE_ROOT/config-gated-coding.md" --repo-root "$ROOT" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
config_gate_exit=$?
set -e
assert_condition 'config gate is required before coding' "$([[ "$config_gate_exit" -eq 0 ]] && echo true || echo false)"

cp "$FIXTURE_ROOT/configured-review.md" "$valid_repo/docs/spec.md"
set +e
bash "$PHASE_VALIDATOR" REVIEW --spec-path "$valid_repo/docs/spec.md" --repo-root "$valid_repo" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
configured_review_exit=$?
set -e
assert_condition 'configured required build gate is enforced before review' "$([[ "$configured_review_exit" -eq 0 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 1 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 1 regression cases passed.'
