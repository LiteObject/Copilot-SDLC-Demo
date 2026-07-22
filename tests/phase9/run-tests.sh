#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$ROOT/tests/fixtures/phase9"
TASK_GRAPH="$ROOT/template/base/scripts/task-graph.py"
SCOPE_AUDIT="$ROOT/template/base/scripts/scope-audit.sh"
TASK_RUNNER="$ROOT/template/base/scripts/run-sdlc-task.sh"
BASE_SCRIPTS="$ROOT/template/base/scripts"
CONFIG_FIXTURE="$ROOT/tests/fixtures/phase1/config-valid.yml"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase9-bash.XXXXXX")"
FAILURES=0

cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

assert_exit_code() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" -eq "$expected" ]]; then echo "[PASS] $label ($actual)"; else echo "[FAIL] $label: expected $expected, got $actual"; ((FAILURES += 1)); fi
}
assert_condition() {
    local label="$1" condition="$2"
    if [[ "$condition" == true ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; ((FAILURES += 1)); fi
}
new_graph_repo() {
    local name="$1"
    local fixture="$2"
    local repo="$TEMP_ROOT/$name"
    mkdir -p "$repo/.github" "$repo/docs/specs/alpha" "$repo/scripts" "$repo/src" "$repo/tests" "$repo/.sdlc/evidence/alpha"
    cp "$CONFIG_FIXTURE" "$repo/.github/sdlc-config.yml"
    cp "$FIXTURE_ROOT/feature-task-spec.md" "$repo/docs/specs/alpha/spec.md"
    cp "$FIXTURE_ROOT/$fixture" "$repo/docs/specs/alpha/tasks.json"
    cp "$FIXTURE_ROOT/evidence/alpha/TASK-001.json" "$repo/.sdlc/evidence/alpha/TASK-001.json"
    cp "$FIXTURE_ROOT/evidence/alpha/TASK-001-failed.json" "$repo/.sdlc/evidence/alpha/TASK-001-failed.json"
    cp "$BASE_SCRIPTS/feature-context.sh" "$repo/scripts/feature-context.sh"
    cp "$BASE_SCRIPTS/task-graph.py" "$repo/scripts/task-graph.py"
    cp "$BASE_SCRIPTS/validate-sdlc-config.sh" "$repo/scripts/validate-sdlc-config.sh"
    cp "$TASK_RUNNER" "$repo/scripts/run-sdlc-task.sh"
    printf '%s\n' alpha > "$repo/src/alpha.txt"
    printf '%s\n' test > "$repo/tests/alpha.txt"
    printf '%s' "$repo"
}
run_graph_case() {
    local label="$1" fixture="$2" expected="$3" target_phase="${4-}" repo args
    repo="$(new_graph_repo "$(date +%s%N)" "$fixture")"
    args=("$TASK_GRAPH" validate --repo-root "$repo" --feature-id alpha --commit-sha fixture-commit --tree-digest fixture-tree)
    [[ -n "$target_phase" ]] && args+=(--target-phase "$target_phase")
    set +e
    python3 "${args[@]}" >/dev/null
    local actual=$?
    set -e
    assert_exit_code "$label" "$actual" "$expected"
}

run_graph_case 'valid DAG passes' tasks-valid.json 0
SUMMARY_REPO="$(new_graph_repo summary tasks-valid.json)"
set +e
SUMMARY_OUTPUT="$(python3 "$TASK_GRAPH" summary --repo-root "$SUMMARY_REPO" --feature-id alpha --commit-sha fixture-commit --tree-digest fixture-tree 2>&1)"
actual=$?
set -e
assert_exit_code 'task graph summary succeeds' "$actual" 0
assert_condition 'task graph summary shows ready task' "$(grep -Eq 'READY:[[:space:]]*TASK-002' <<< "$SUMMARY_OUTPUT" && echo true || echo false)"
run_graph_case 'duplicate task IDs fail' tasks-duplicate.json 2
run_graph_case 'dependency cycle fails' tasks-cycle.json 2
run_graph_case 'missing acceptance mapping fails' tasks-missing-mapping.json 2
run_graph_case 'DONE task without evidence fails' tasks-missing-evidence.json 2
run_graph_case 'stale task evidence fails' tasks-stale-evidence.json 2
run_graph_case 'failed task evidence fails with handoff' tasks-failed-evidence.json 2
run_graph_case 'approved blocked task passes validation' tasks-blocked.json 0 REVIEW
run_graph_case 'unsafe task scope fails' tasks-unsafe-scope.json 2
run_graph_case 'incomplete graph blocks REVIEW' tasks-valid.json 2 REVIEW
run_graph_case 'incomplete release graph blocks DONE' tasks-valid.json 2 DONE

SCOPE_REPO="$(new_graph_repo scope tasks-blocked.json)"
git -C "$SCOPE_REPO" init -q
git -C "$SCOPE_REPO" config user.email phase9@example.test
git -C "$SCOPE_REPO" config user.name 'Phase 9 Tests'
git -C "$SCOPE_REPO" add .
git -C "$SCOPE_REPO" commit -q -m 'task scope base'
printf '%s\n' changed > "$SCOPE_REPO/src/alpha.txt"
set +e
bash "$SCOPE_AUDIT" --repo-root "$SCOPE_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'task-derived scope passes audit' "$actual" 0

RECORD_REPO="$(new_graph_repo record tasks-valid.json)"
set +e
bash "$TASK_RUNNER" --task test --task-id TASK-002 --repo-root "$RECORD_REPO" --config-path "$RECORD_REPO/.github/sdlc-config.yml" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'task runner records graph evidence' "$actual" 0
assert_condition 'recorded evidence targets TASK-002' "$(if grep -Eq '\"task\"[[:space:]]*:[[:space:]]*\"TASK-002\"' "$RECORD_REPO/.sdlc/evidence/alpha/test.json" && grep -Eq '\"task\"[[:space:]]*:[[:space:]]*\"TASK-002\"' "$RECORD_REPO/docs/specs/alpha/tasks.json"; then echo true; else echo false; fi)"
assert_condition 'recorded evidence preserves verification task' "$(if grep -Eq '\"verification_task\"[[:space:]]*:[[:space:]]*\"test\"' "$RECORD_REPO/.sdlc/evidence/alpha/test.json"; then echo true; else echo false; fi)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 9 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 9 regression cases passed.'
