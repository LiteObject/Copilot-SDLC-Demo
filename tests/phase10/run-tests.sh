#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$ROOT/tests/fixtures/phase10"
BASE_SCRIPTS="$ROOT/template/base/scripts"
ADAPTER="$BASE_SCRIPTS/verification.py"
RUNNER="$BASE_SCRIPTS/run-sdlc-task.sh"
CONFIG_VALIDATOR="$BASE_SCRIPTS/validate-sdlc-config.sh"
PHASE_VALIDATOR="$BASE_SCRIPTS/check-phase.sh"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase10-bash.XXXXXX")"
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

new_adapter_repo() {
    local name="$1" repo="$TEMP_ROOT/$1"
    mkdir -p "$repo/src" "$repo/tests" "$repo/.sdlc/reports" "$repo/.sdlc/evidence"
    printf 'def value():\n    return 1\n' > "$repo/src/app.py"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase10@example.test
    git -C "$repo" config user.name 'Phase 10 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'verification base'
    printf 'def value():\n    return 2\n' > "$repo/src/app.py"
    printf '%s' "$repo"
}

run_coverage_case() {
    local label="$1" report="$2" expected_exit="$3" expected_result="$4" repo input_args actual
    repo="$(new_adapter_repo "adapter-$RANDOM")"
    cp "$FIXTURE_ROOT/$report" "$repo/.sdlc/reports/input.json"
    input_args=(coverage --repo-root "$repo" --report-path .sdlc/reports/input.json --provider generic-json --threshold 80 --commit-sha fixture-commit --tree-digest fixture-tree --output-path .sdlc/evidence/coverage.json)
    if [[ "$label" == 'excluded paths produce NOT_APPLICABLE' ]]; then
        rm "$repo/src/app.py"
        printf 'def test_value():\n    return 2\n' > "$repo/tests/test_app.py"
        git -C "$repo" add -A
        git -C "$repo" commit -q -m 'test base'
        printf 'def test_value():\n    return 3\n' > "$repo/tests/test_app.py"
        input_args+=(--exclude 'tests/**')
    elif [[ "$label" == 'no executable changes produce NOT_APPLICABLE' ]]; then
        printf 'def value():\n    return 1\n' > "$repo/src/app.py"
        printf 'base\n' > "$repo/README.md"
        git -C "$repo" add README.md
        git -C "$repo" commit -q -m 'readme base'
        printf 'changed\n' > "$repo/README.md"
    fi
    set +e
    python3 "$ADAPTER" "${input_args[@]}" >/dev/null
    actual=$?
    set -e
    assert_exit_code "$label" "$actual" "$expected_exit"
    assert_condition "$label records $expected_result" "$(grep -Eq '"result"[[:space:]]*:[[:space:]]*"'"$expected_result"'"' "$repo/.sdlc/evidence/coverage.json" && echo true || echo false)"
}

run_mutation_case() {
    local label="$1" report="$2" expected_exit="$3" expected_result="$4" threshold="$5" repo actual
    repo="$(new_adapter_repo "mutation-$RANDOM")"
    cp "$FIXTURE_ROOT/$report" "$repo/.sdlc/reports/input.json"
    set +e
    python3 "$ADAPTER" mutation --repo-root "$repo" --report-path .sdlc/reports/input.json --provider generic-json --threshold "$threshold" --commit-sha fixture-commit --tree-digest fixture-tree --output-path .sdlc/evidence/mutation.json >/dev/null
    actual=$?
    set -e
    assert_exit_code "$label" "$actual" "$expected_exit"
    assert_condition "$label records $expected_result" "$(grep -Eq '"result"[[:space:]]*:[[:space:]]*"'"$expected_result"'"' "$repo/.sdlc/evidence/mutation.json" && echo true || echo false)"
}

run_coverage_case 'coverage passes' coverage-pass.json 0 PASS
run_coverage_case 'low changed-line coverage fails' coverage-low.json 1 FAIL
run_coverage_case 'stale coverage report fails' coverage-stale.json 1 FAIL
run_coverage_case 'changed source missing from coverage report fails' coverage-missing-file.json 1 FAIL
MISSING_REPO="$(new_adapter_repo missing-report)"
set +e
python3 "$ADAPTER" coverage --repo-root "$MISSING_REPO" --report-path .sdlc/reports/does-not-exist.json --provider generic-json --threshold 80 --commit-sha fixture-commit --tree-digest fixture-tree --output-path .sdlc/evidence/coverage.json >/dev/null
actual=$?
set -e
assert_exit_code 'missing coverage report is rejected' "$actual" 1
assert_condition 'missing report evidence is machine-readable' "$(grep -Eq '"result"[[:space:]]*:[[:space:]]*"FAIL"' "$MISSING_REPO/.sdlc/evidence/coverage.json" && echo true || echo false)"
run_coverage_case 'excluded paths produce NOT_APPLICABLE' coverage-excluded.json 0 NOT_APPLICABLE
run_coverage_case 'no executable changes produce NOT_APPLICABLE' coverage-pass.json 0 NOT_APPLICABLE
run_mutation_case 'mutation threshold passes' mutation-pass.json 0 PASS 50
run_mutation_case 'mutation threshold failure blocks' mutation-fail.json 1 FAIL 80
run_mutation_case 'undispositioned survivor blocks' mutation-no-disposition.json 1 FAIL 50

RUNNER_REPO="$TEMP_ROOT/runner"
mkdir -p "$RUNNER_REPO/.github" "$RUNNER_REPO/docs" "$RUNNER_REPO/tests" "$RUNNER_REPO/src" "$RUNNER_REPO/scripts"
cp "$FIXTURE_ROOT/config-verification-valid.yml" "$RUNNER_REPO/.github/sdlc-config.yml"
sed -i 's/executable: python/executable: python3/g' "$RUNNER_REPO/.github/sdlc-config.yml"
cp "$ROOT/template/base/docs/spec.md" "$RUNNER_REPO/docs/spec.md"
cp "$FIXTURE_ROOT/write-coverage-report.py" "$RUNNER_REPO/tests/write-coverage-report.py"
cp "$BASE_SCRIPTS/feature-context.sh" "$BASE_SCRIPTS/validate-sdlc-config.sh" "$BASE_SCRIPTS/run-sdlc-task.sh" "$BASE_SCRIPTS/task-graph.py" "$BASE_SCRIPTS/verification.py" "$RUNNER_REPO/scripts/"
printf 'def value():\n    return 1\n' > "$RUNNER_REPO/src/app.py"
git -C "$RUNNER_REPO" init -q
git -C "$RUNNER_REPO" config user.email phase10@example.test
git -C "$RUNNER_REPO" config user.name 'Phase 10 Tests'
git -C "$RUNNER_REPO" add .
git -C "$RUNNER_REPO" commit -q -m 'runner base'
printf 'def value():\n    return 2\n' > "$RUNNER_REPO/src/app.py"
set +e
bash "$RUNNER_REPO/scripts/run-sdlc-task.sh" --task all --repo-root "$RUNNER_REPO" --config-path "$RUNNER_REPO/.github/sdlc-config.yml" --record-spec >/dev/null
actual=$?
set -e
assert_exit_code 'runner executes coverage adapter' "$actual" 0
assert_condition 'runner writes coverage summary' "$(test -f "$RUNNER_REPO/.sdlc/evidence/coverage.json" && grep -Eq '"result"[[:space:]]*:[[:space:]]*"PASS"' "$RUNNER_REPO/.sdlc/evidence/coverage.json" && echo true || echo false)"
assert_condition 'runner keeps task record separate' "$(test -f "$RUNNER_REPO/.sdlc/evidence/coverage-task.json" && echo true || echo false)"
assert_condition 'runner records machine-readable gate evidence' "$(grep -Eq '^gate_coverage_evidence:[[:space:]]+"\.sdlc/evidence/coverage\.json"' "$RUNNER_REPO/docs/spec.md" && echo true || echo false)"

INVALID_REPO="$TEMP_ROOT/invalid-config"
cp -a "$RUNNER_REPO" "$INVALID_REPO"
sed -i 's/coverage_changed_line_threshold: 80/coverage_changed_line_threshold: 101/' "$INVALID_REPO/.github/sdlc-config.yml"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$INVALID_REPO" --config-path "$INVALID_REPO/.github/sdlc-config.yml" >/dev/null
actual=$?
set -e
assert_exit_code 'threshold outside 0..100 fails config validation' "$actual" 1
sed -i 's/coverage_changed_line_threshold: 101/coverage_changed_line_threshold: 80/; s/risk_profile: low/risk_profile: high/; s/coverage_enabled: true/coverage_enabled: false/; s/coverage_required_risk_profiles: \[low\]/coverage_required_risk_profiles: [high]/' "$INVALID_REPO/.github/sdlc-config.yml"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$INVALID_REPO" --config-path "$INVALID_REPO/.github/sdlc-config.yml" >/dev/null
actual=$?
set -e
assert_exit_code 'required high-risk coverage cannot be disabled' "$actual" 1

GRAPH_REPO="$TEMP_ROOT/graph"
mkdir -p "$GRAPH_REPO/.github" "$GRAPH_REPO/docs/specs/alpha" "$GRAPH_REPO/scripts"
cp "$FIXTURE_ROOT/config-verification-valid.yml" "$GRAPH_REPO/.github/sdlc-config.yml"
cp "$FIXTURE_ROOT/tasks-coverage-only.json" "$GRAPH_REPO/docs/specs/alpha/tasks.json"
cp "$ROOT/tests/fixtures/phase9/feature-task-spec.md" "$GRAPH_REPO/docs/specs/alpha/spec.md"
cp "$BASE_SCRIPTS/task-graph.py" "$GRAPH_REPO/scripts/task-graph.py"
set +e
graph_output="$(python3 "$GRAPH_REPO/scripts/task-graph.py" validate --repo-root "$GRAPH_REPO" --feature-id alpha --commit-sha fixture-commit --tree-digest fixture-tree 2>&1)"
actual=$?
set -e
assert_exit_code 'coverage-only task graph is rejected' "$actual" 2
assert_condition 'coverage-only rejection explains next verification' "$(grep -Eq 'cannot use coverage or mutation as its only verification' <<< "$graph_output" && echo true || echo false)"

PHASE_REPO="$TEMP_ROOT/phase-gate"
mkdir -p "$PHASE_REPO/.github" "$PHASE_REPO/docs" "$PHASE_REPO/tests/fixtures/phase0/evidence" "$PHASE_REPO/scripts" "$PHASE_REPO/.sdlc/evidence"
cp "$FIXTURE_ROOT/config-verification-valid.yml" "$PHASE_REPO/.github/sdlc-config.yml"
cp "$ROOT/tests/fixtures/phase0/valid-readiness.md" "$PHASE_REPO/docs/spec.md"
sed -i 's/deployment_readiness_enabled: true/deployment_readiness_enabled: false/' "$PHASE_REPO/docs/spec.md"
printf '\n## Test Strategy\nUnit verification covers the fixture behavior.\n\n## Acceptance Test Mapping\nEvery acceptance criterion maps to the fixture test.\n' >> "$PHASE_REPO/docs/spec.md"
tr -d '\r' < "$PHASE_REPO/docs/spec.md" > "$PHASE_REPO/docs/spec.normalized"
mv "$PHASE_REPO/docs/spec.normalized" "$PHASE_REPO/docs/spec.md"
cp "$BASE_SCRIPTS/feature-context.sh" "$BASE_SCRIPTS/check-phase.sh" "$BASE_SCRIPTS/verification.py" "$PHASE_REPO/scripts/"
printf 'gate\n' > "$PHASE_REPO/tests/fixtures/phase0/evidence/gate.txt"
git -C "$PHASE_REPO" init -q
git -C "$PHASE_REPO" config user.email phase10@example.test
git -C "$PHASE_REPO" config user.name 'Phase 10 Tests'
git -C "$PHASE_REPO" add .
git -C "$PHASE_REPO" commit -q -m 'phase gate base'
set +e
bash "$PHASE_REPO/scripts/check-phase.sh" DONE --repo-root "$PHASE_REPO" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
actual=$?
set -e
assert_exit_code 'required coverage gate blocks completion when absent' "$actual" 2
coverage_records=$'gate_build_command: fixture build\ngate_build_commit_sha: fixture-commit\ngate_build_tree_digest: fixture-tree\ngate_build_timestamp: 2026-07-22T00:00:00Z\ngate_build_exit_code: 0\ngate_build_result: PASS\ngate_build_evidence: tests/fixtures/phase0/evidence/gate.txt\ngate_coverage_command: fixture coverage\ngate_coverage_commit_sha: fixture-commit\ngate_coverage_tree_digest: fixture-tree\ngate_coverage_timestamp: 2026-07-22T00:00:00Z\ngate_coverage_exit_code: 0\ngate_coverage_result: PASS\ngate_coverage_evidence: .sdlc/evidence/coverage.json\n'
mkdir -p "$PHASE_REPO/.sdlc/reports"
printf '{"schema":1,"commit_sha":"fixture-commit","tree_digest":"fixture-tree","files":{}}\n' > "$PHASE_REPO/.sdlc/reports/coverage.json"
python3 "$PHASE_REPO/scripts/verification.py" coverage --repo-root "$PHASE_REPO" --report-path .sdlc/reports/coverage.json --provider generic-json --threshold 80 --commit-sha fixture-commit --tree-digest fixture-tree --output-path .sdlc/evidence/coverage.json >/dev/null
awk -v records="$coverage_records" 'BEGIN { inserted = 0 } /^---$/ && NR > 1 && inserted == 0 { printf "%s", records; inserted = 1 } { print }' "$PHASE_REPO/docs/spec.md" > "$PHASE_REPO/docs/spec.tmp"
mv "$PHASE_REPO/docs/spec.tmp" "$PHASE_REPO/docs/spec.md"
set +e
bash "$PHASE_REPO/scripts/check-phase.sh" DONE --repo-root "$PHASE_REPO" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
actual=$?
set -e
assert_exit_code 'current coverage gate permits completion' "$actual" 0

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 10 Bash regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 10 regression cases passed.'