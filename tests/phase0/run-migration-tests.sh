#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase0/legacy-spec.md"
MIGRATION="$ROOT/template/base/scripts/migrate-spec.sh"
VALIDATOR="$ROOT/template/base/scripts/check-phase.sh"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase0-migration-bash.XXXXXX")"
FAILURES=0

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

assert_condition() {
    local label="$1" condition="$2"
    if [[ "$condition" == 'true' ]]; then
        echo "[PASS] $label"
    else
        echo "[FAIL] $label"
        ((FAILURES += 1))
    fi
}

mkdir -p "$TEMP_ROOT/docs" "$TEMP_ROOT/.github"
cp "$FIXTURE" "$TEMP_ROOT/docs/spec.md"
printf '%s\n' 'integrations:' '  deployment_readiness_gate: true' > "$TEMP_ROOT/.github/sdlc-config.yml"
cp "$TEMP_ROOT/docs/spec.md" "$TEMP_ROOT/legacy-before.md"

set +e
bash "$MIGRATION" --repo-root "$TEMP_ROOT" >/dev/null
DRY_EXIT=$?
set -e
assert_condition 'migration requires explicit force' "$([[ "$DRY_EXIT" -eq 2 ]] && echo true || echo false)"
assert_condition 'dry run preserves legacy spec' "$(cmp -s "$TEMP_ROOT/docs/spec.md" "$TEMP_ROOT/legacy-before.md" && echo true || echo false)"

set +e
bash "$MIGRATION" --repo-root "$TEMP_ROOT" --force >/dev/null
FORCE_EXIT=$?
set -e
assert_condition 'forced migration succeeds' "$([[ "$FORCE_EXIT" -eq 0 ]] && echo true || echo false)"
assert_condition 'schema is initialized' "$(grep -Eq '^sdlc_schema:[[:space:]]*1[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'current phase is preserved' "$(grep -Eq '^current_phase:[[:space:]]*CODING[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'review cycle is preserved' "$(grep -Eq '^review_cycle:[[:space:]]*2[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'design requirement is inferred' "$(grep -Eq '^design_required:[[:space:]]*true[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'readiness configuration is inferred' "$(grep -Eq '^deployment_readiness_enabled:[[:space:]]*true[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'exact planned files are recovered' "$(grep -Eq '^[[:space:]]*-[[:space:]]*src/app\.ts[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && grep -Eq '^[[:space:]]*-[[:space:]]*tests/app\.test\.ts[[:space:]]*$' "$TEMP_ROOT/docs/spec.md" && echo true || echo false)"
assert_condition 'migration backup exists' "$(test "$(find "$TEMP_ROOT/.sdlc/migrations" -type f | wc -l)" -eq 1 && echo true || echo false)"

set +e
bash "$MIGRATION" --repo-root "$TEMP_ROOT" >/dev/null
IDEMPOTENT_EXIT=$?
set -e
assert_condition 'migration is idempotent after schema initialization' "$([[ "$IDEMPOTENT_EXIT" -eq 0 ]] && echo true || echo false)"

set +e
bash "$VALIDATOR" REVIEW --repo-root "$TEMP_ROOT" --spec-path "$TEMP_ROOT/docs/spec.md" >/dev/null
VALIDATOR_EXIT=$?
set -e
assert_condition 'migrated state is validator-readable but gate-blocked' "$([[ "$VALIDATOR_EXIT" -eq 2 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then
    echo "[FAIL] $FAILURES migration regression case(s) failed."
    exit 1
fi
echo '[PASS] All Bash migration regression cases passed.'
