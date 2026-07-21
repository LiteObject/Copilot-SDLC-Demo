#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase8/feature-valid.md"
SCOPE_FIXTURE="$ROOT/tests/fixtures/phase8/feature-scope.md"
CONFIG_FIXTURE="$ROOT/tests/fixtures/phase1/config-valid.yml"
LEGACY_FIXTURE="$ROOT/tests/fixtures/phase0/legacy-spec.md"
BASE_SCRIPTS="$ROOT/template/base/scripts"
PHASE_VALIDATOR="$BASE_SCRIPTS/check-phase.sh"
SCOPE_AUDIT="$BASE_SCRIPTS/scope-audit.sh"
TASK_RUNNER="$BASE_SCRIPTS/run-sdlc-task.sh"
MIGRATOR="$BASE_SCRIPTS/migrate-spec.sh"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase8-bash.XXXXXX")"
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

assert_condition() {
    local label="$1" condition="$2"
    if [[ "$condition" == true ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label"
        ((FAILURES += 1))
    fi
}

write_feature_spec() {
    local path="$1" feature_id="$2"
    mkdir -p "$(dirname "$path")"
    sed "s/alpha/$feature_id/g" "$FIXTURE" > "$path"
}

FEATURE_REPO="$TEMP_ROOT/features"
mkdir -p "$FEATURE_REPO/.github" "$FEATURE_REPO/tests" "$FEATURE_REPO/scripts" \
    "$FEATURE_REPO/.sdlc/evidence/alpha" "$FEATURE_REPO/.sdlc/evidence/beta"
cp "$CONFIG_FIXTURE" "$FEATURE_REPO/.github/sdlc-config.yml"
cp "$BASE_SCRIPTS"/* "$FEATURE_REPO/scripts/"
write_feature_spec "$FEATURE_REPO/docs/specs/alpha/spec.md" alpha
write_feature_spec "$FEATURE_REPO/docs/specs/beta/spec.md" beta
printf '%s\n' 'alpha requirements' > "$FEATURE_REPO/.sdlc/evidence/alpha/requirements.txt"
printf '%s\n' 'beta requirements' > "$FEATURE_REPO/.sdlc/evidence/beta/requirements.txt"

for feature_id in alpha beta; do
    set +e
    bash "$PHASE_VALIDATOR" PLANNING --repo-root "$FEATURE_REPO" --feature-id "$feature_id" \
        --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
    actual=$?
    set -e
    assert_exit_code "feature $feature_id validates independently" "$actual" 0
done

sed -i 's#\.sdlc/evidence/alpha/requirements.txt#.sdlc/evidence/beta/requirements.txt#' "$FEATURE_REPO/docs/specs/alpha/spec.md"
set +e
bash "$PHASE_VALIDATOR" PLANNING --repo-root "$FEATURE_REPO" --feature-id alpha \
    --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
actual=$?
set -e
assert_exit_code 'cross-feature gate evidence is rejected' "$actual" 2
write_feature_spec "$FEATURE_REPO/docs/specs/alpha/spec.md" alpha

set +e
bash "$PHASE_VALIDATOR" PLANNING --repo-root "$FEATURE_REPO" --feature-id Alpha_Bad \
    --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
actual=$?
set -e
assert_exit_code 'invalid feature ID is rejected' "$actual" 1
set +e
bash "$PHASE_VALIDATOR" PLANNING --repo-root "$FEATURE_REPO" --feature-id ../beta \
    --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
actual=$?
set -e
assert_exit_code 'path traversal feature ID is rejected' "$actual" 1

set +e
bash "$TASK_RUNNER" --task test --repo-root "$FEATURE_REPO" \
    --config-path "$FEATURE_REPO/.github/sdlc-config.yml" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'feature task execution succeeds' "$actual" 0
assert_condition 'feature task evidence is namespaced' "$(test -f "$FEATURE_REPO/.sdlc/evidence/alpha/test.json" && echo true || echo false)"
assert_condition 'other feature task evidence is untouched' "$(test ! -f "$FEATURE_REPO/.sdlc/evidence/beta/test.json" && echo true || echo false)"

SCOPE_REPO="$TEMP_ROOT/scope"
mkdir -p "$SCOPE_REPO/docs/specs/alpha" "$SCOPE_REPO/docs/specs/beta" "$SCOPE_REPO/src"
cp "$SCOPE_FIXTURE" "$SCOPE_REPO/docs/specs/alpha/spec.md"
sed 's/alpha/beta/g' "$SCOPE_FIXTURE" > "$SCOPE_REPO/docs/specs/beta/spec.md"
printf '%s\n' base > "$SCOPE_REPO/src/alpha.txt"
git -C "$SCOPE_REPO" init -q
git -C "$SCOPE_REPO" config user.email phase8@example.test
git -C "$SCOPE_REPO" config user.name 'Phase 8 Tests'
git -C "$SCOPE_REPO" add .
git -C "$SCOPE_REPO" commit -q -m 'feature scope base'
printf '%s\n' changed > "$SCOPE_REPO/src/alpha.txt"
set +e
bash "$SCOPE_AUDIT" --repo-root "$SCOPE_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'feature scope allows planned file' "$actual" 0
printf '%s\n' 'changed outside alpha' >> "$SCOPE_REPO/docs/specs/beta/spec.md"
set +e
bash "$SCOPE_AUDIT" --repo-root "$SCOPE_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'feature scope rejects another feature spec' "$actual" 1

MIGRATION_REPO="$TEMP_ROOT/migration"
mkdir -p "$MIGRATION_REPO/docs" "$MIGRATION_REPO/.github"
cp "$LEGACY_FIXTURE" "$MIGRATION_REPO/docs/spec.md"
cp "$MIGRATION_REPO/docs/spec.md" "$MIGRATION_REPO/legacy-before.md"
set +e
bash "$MIGRATOR" --repo-root "$MIGRATION_REPO" --feature-id alpha --force >/dev/null
actual=$?
set -e
assert_exit_code 'feature migration succeeds' "$actual" 0
assert_condition 'legacy spec is preserved' "$(cmp -s "$MIGRATION_REPO/docs/spec.md" "$MIGRATION_REPO/legacy-before.md" && echo true || echo false)"
assert_condition 'feature migration creates target spec' "$(test -f "$MIGRATION_REPO/docs/specs/alpha/spec.md" && echo true || echo false)"
assert_condition 'feature migration records identity' "$(grep -Eq '^feature_id:[[:space:]]+\"alpha\"[[:space:]]*$' "$MIGRATION_REPO/docs/specs/alpha/spec.md" && test "$(find "$MIGRATION_REPO/.sdlc/migrations/alpha" -type f | wc -l)" -eq 1 && echo true || echo false)"

if (( FAILURES > 0 )); then
    echo "[FAIL] $FAILURES Phase 8 regression case(s) failed."
    exit 1
fi
echo '[PASS] All Bash Phase 8 regression cases passed.'
