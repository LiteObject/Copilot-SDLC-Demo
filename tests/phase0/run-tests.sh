#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$ROOT/tests/fixtures/phase0"
PHASE_VALIDATOR="$ROOT/template/base/scripts/check-phase.sh"
SCOPE_AUDIT="$ROOT/template/base/scripts/scope-audit.sh"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase0-bash.XXXXXX")"
FAILURES=0

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

assert_exit_code() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        echo "[PASS] $label ($actual)"
    else
        echo "[FAIL] $label: expected $expected, got $actual"
        ((FAILURES += 1))
    fi
}

run_phase_case() {
    local label="$1" fixture="$2" target="$3" expected="$4" commit="${5:-fixture-commit}" tree="${6:-fixture-tree}"
    set +e
    bash "$PHASE_VALIDATOR" "$target" \
        --spec-path "$FIXTURE_ROOT/$fixture" \
        --repo-root "$ROOT" \
        --commit-sha "$commit" \
        --tree-digest "$tree" >/dev/null
    local actual=$?
    set -e
    assert_exit_code "$label" "$actual" "$expected"
}

run_scope_case() {
    local label="$1" expected="$2"
    set +e
    bash "$SCOPE_AUDIT" \
        --repo-root "$SCOPE_ROOT" \
        --spec-path "$SCOPE_ROOT/docs/spec.md" >/dev/null
    local actual=$?
    set -e
    assert_exit_code "$label" "$actual" "$expected"
}

run_phase_case 'valid requirements to planning' valid-planning.md PLANNING 0
run_phase_case 'valid testing to readiness' valid-readiness.md DEPLOYMENT_READINESS 0
run_phase_case 'failed test blocks done' failed-test.md DONE 2
run_phase_case 'failed readiness blocks done' failed-readiness.md DONE 2
run_phase_case 'fourth review cycle is blocked' review-cycle-cap.md CODING 2
run_phase_case 'illegal direct jump is blocked' valid-planning.md DONE 2
run_phase_case 'stale gate revision is blocked' valid-planning.md PLANNING 2 stale-commit

CRLF_SPEC="$TEMP_ROOT/crlf-spec.md"
sed 's/$/\r/' "$FIXTURE_ROOT/valid-planning.md" > "$CRLF_SPEC"
set +e
bash "$PHASE_VALIDATOR" PLANNING --spec-path "$CRLF_SPEC" --repo-root "$ROOT" \
    --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
CRLF_EXIT=$?
set -e
assert_exit_code 'CRLF phase fixture' "$CRLF_EXIT" 0

SCOPE_ROOT="$TEMP_ROOT/scope-repo"
mkdir -p "$SCOPE_ROOT/docs" "$SCOPE_ROOT/src"
cp "$FIXTURE_ROOT/scope-exact.md" "$SCOPE_ROOT/docs/spec.md"
printf '%s\n' allowed > "$SCOPE_ROOT/src/allowed.txt"
git -C "$SCOPE_ROOT" init -q
git -C "$SCOPE_ROOT" config user.email phase0@example.test
git -C "$SCOPE_ROOT" config user.name 'Phase 0 Tests'
git -C "$SCOPE_ROOT" add docs/spec.md
git -C "$SCOPE_ROOT" commit -q -m 'fixture base'
run_scope_case 'exact planned file passes' 0

sed 's/$/\r/' "$FIXTURE_ROOT/scope-exact.md" > "$SCOPE_ROOT/docs/spec.md"
run_scope_case 'CRLF scope fixture' 0

printf '%s\n' creep > "$SCOPE_ROOT/src/unplanned.txt"
run_scope_case 'unplanned file is scope creep' 1

cp "$FIXTURE_ROOT/scope-directory.md" "$SCOPE_ROOT/docs/spec.md"
run_scope_case 'directory scope entry is invalid' 2

cp "$FIXTURE_ROOT/scope-glob-unapproved.md" "$SCOPE_ROOT/docs/spec.md"
run_scope_case 'unapproved glob is invalid' 2

rm -f "$SCOPE_ROOT/src/unplanned.txt" "$SCOPE_ROOT/src/allowed.txt"
cp "$FIXTURE_ROOT/scope-glob-approved.md" "$SCOPE_ROOT/docs/spec.md"
mkdir -p "$SCOPE_ROOT/src/nested"
printf '%s\n' approved > "$SCOPE_ROOT/src/nested/ok.txt"
git -C "$SCOPE_ROOT" add docs/spec.md
git -C "$SCOPE_ROOT" commit -q -m 'approved glob plan'
run_scope_case 'approved glob passes' 0

if (( FAILURES > 0 )); then
    echo "[FAIL] $FAILURES Phase 0 regression case(s) failed."
    exit 1
fi
echo '[PASS] All Phase 0 Bash regression cases passed.'