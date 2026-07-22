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
SCAFFOLDER="$ROOT/tools/scaffold-sdlc.sh"
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
    awk -v feature_id="$feature_id" '{ gsub(/alpha/, feature_id); print }' "$FIXTURE" > "$path"
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

awk '{ gsub(/\.sdlc\/evidence\/alpha\/requirements\.txt/, ".sdlc/evidence/beta/requirements.txt"); print }' "$FEATURE_REPO/docs/specs/alpha/spec.md" > "$FEATURE_REPO/docs/specs/alpha/spec.tmp"
mv "$FEATURE_REPO/docs/specs/alpha/spec.tmp" "$FEATURE_REPO/docs/specs/alpha/spec.md"
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
awk '{ gsub(/alpha/, "beta"); print }' "$SCOPE_FIXTURE" > "$SCOPE_REPO/docs/specs/beta/spec.md"
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

SHARED_REPO="$TEMP_ROOT/shared"
mkdir -p "$SHARED_REPO/docs/specs/alpha" "$SHARED_REPO/src"
awk '$0 ~ /^approved_globs: \[\]/ { print "  - package.json"; print; next } { print }' "$SCOPE_FIXTURE" > "$SHARED_REPO/docs/specs/alpha/spec.md"
printf '%s\n' base > "$SHARED_REPO/src/alpha.txt"
printf '%s\n' '{"name":"fixture"}' > "$SHARED_REPO/package.json"
git -C "$SHARED_REPO" init -q
git -C "$SHARED_REPO" config user.email phase8@example.test
git -C "$SHARED_REPO" config user.name 'Phase 8 Tests'
git -C "$SHARED_REPO" add .
git -C "$SHARED_REPO" commit -q -m 'shared file base'
printf '%s\n' '{"name":"changed"}' > "$SHARED_REPO/package.json"
set +e
bash "$SCOPE_AUDIT" --repo-root "$SHARED_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'unapproved shared file is rejected' "$actual" 1
awk 'BEGIN { replacement = "approved_shared_files:"; record = "  - package.json|Add fixture dependency|architect|fixture-commit|2026-07-21T00:00:00Z" } $0 ~ /^approved_shared_files: \[\]/ { print replacement; print record; next } { print }' "$SHARED_REPO/docs/specs/alpha/spec.md" > "$SHARED_REPO/docs/specs/alpha/spec.tmp"
mv "$SHARED_REPO/docs/specs/alpha/spec.tmp" "$SHARED_REPO/docs/specs/alpha/spec.md"
set +e
bash "$SCOPE_AUDIT" --repo-root "$SHARED_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'approved shared file passes' "$actual" 0

CONFLICT_REPO="$TEMP_ROOT/conflict"
mkdir -p "$CONFLICT_REPO/docs/specs/alpha" "$CONFLICT_REPO/docs/specs/beta" "$CONFLICT_REPO/src"
tr -d '\r' < "$SCOPE_FIXTURE" | awk '$0 == "  - src/alpha.txt" { print; print "  - src/shared.txt"; next } { print }' > "$CONFLICT_REPO/docs/specs/alpha/spec.md"
awk '{ gsub(/alpha/, "beta"); print }' "$CONFLICT_REPO/docs/specs/alpha/spec.md" > "$CONFLICT_REPO/docs/specs/beta/spec.md"
printf '%s\n' alpha > "$CONFLICT_REPO/src/alpha.txt"
printf '%s\n' base > "$CONFLICT_REPO/src/shared.txt"
git -C "$CONFLICT_REPO" init -q
git -C "$CONFLICT_REPO" config user.email phase8@example.test
git -C "$CONFLICT_REPO" config user.name 'Phase 8 Tests'
git -C "$CONFLICT_REPO" add .
git -C "$CONFLICT_REPO" commit -q -m 'feature conflict base'
printf '%s\n' changed > "$CONFLICT_REPO/src/shared.txt"
set +e
bash "$SCOPE_AUDIT" --repo-root "$CONFLICT_REPO" --feature-id alpha >/dev/null
actual=$?
set -e
assert_exit_code 'same-file feature conflict is rejected' "$actual" 2

SCAFFOLD_REPO="$TEMP_ROOT/scaffold"
mkdir -p "$SCAFFOLD_REPO/docs"
printf '%s' 'legacy project spec' > "$SCAFFOLD_REPO/docs/spec.md"
set +e
bash "$SCAFFOLDER" "$SCAFFOLD_REPO" --feature-id checkout-flow >/dev/null
actual=$?
set -e
assert_exit_code 'feature scaffold succeeds' "$actual" 0
assert_condition 'feature scaffold preserves legacy spec' "$(cmp -s "$SCAFFOLD_REPO/docs/spec.md" <(printf '%s' 'legacy project spec') && echo true || echo false)"
assert_condition 'feature scaffold creates feature spec' "$(test -f "$SCAFFOLD_REPO/docs/specs/checkout-flow/spec.md" && echo true || echo false)"
assert_condition 'feature scaffold records identity' "$(grep -Eq '^feature_id:[[:space:]]+\"checkout-flow\"[[:space:]]*$' "$SCAFFOLD_REPO/docs/specs/checkout-flow/spec.md" && grep -Eq '^spec_path:[[:space:]]+\"docs/specs/checkout-flow/spec.md\"[[:space:]]*$' "$SCAFFOLD_REPO/docs/specs/checkout-flow/spec.md" && echo true || echo false)"
assert_condition 'feature scaffold creates task graph starter' "$(test -f "$SCAFFOLD_REPO/docs/specs/checkout-flow/tasks.json" && grep -q 'schema_version' "$SCAFFOLD_REPO/docs/specs/checkout-flow/tasks.json" && grep -q 'tasks' "$SCAFFOLD_REPO/docs/specs/checkout-flow/tasks.json" && echo true || echo false)"

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
