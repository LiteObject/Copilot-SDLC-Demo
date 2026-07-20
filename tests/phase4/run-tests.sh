#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase4/config-operational-valid.yml"
BASE_SCRIPTS="$ROOT/template/base/scripts"
OPERATIONAL_ROOT="$ROOT/template/extensions/operational-readiness"
TEMP="$(mktemp -d "$ROOT/tests/.phase4-bash.XXXXXX")"
FAILURES=0
cleanup() { rm -rf "$TEMP"; }
trap cleanup EXIT
assert_condition() { local label="$1" condition="$2"; if [[ "$condition" == true ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; (( FAILURES += 1 )); fi; }
new_repo() {
    local name="$1"
    local repo="$TEMP/$name"
    mkdir -p "$repo/.github" "$repo/docs" "$repo/tests" "$repo/scripts"
    cp "$FIXTURE" "$repo/.github/sdlc-config.yml"
    cp "$ROOT/template/base/docs/spec.md" "$repo/docs/spec.md"
    cp "$BASE_SCRIPTS"/* "$repo/scripts/"
    cp "$OPERATIONAL_ROOT/scripts"/*.sh "$repo/scripts/"
    cp -R "$OPERATIONAL_ROOT/docs/." "$repo/docs/"
    printf '%s' "$repo"
}

VALID_REPO="$(new_repo valid)"
set +e
bash "$VALID_REPO/scripts/validate-operational-readiness.sh" --repo-root "$VALID_REPO" >/dev/null
config_exit=$?
set -e
assert_condition 'operational config validates' "$([[ "$config_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'config evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/operational-readiness-config-validation.json" && echo true || echo false)"
set +e
bash "$VALID_REPO/scripts/run-operational-readiness.sh" --repo-root "$VALID_REPO" --record-spec >/dev/null
readiness_exit=$?
set -e
assert_condition 'readiness checks pass' "$([[ "$readiness_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'readiness summary exists' "$(test -f "$VALID_REPO/.sdlc/evidence/operational-readiness.json" && echo true || echo false)"
assert_condition 'readiness gate is recorded' "$(grep -Eq '^gate_operational_readiness_result:[[:space:]]+PASS[[:space:]]*$' "$VALID_REPO/docs/spec.md" && echo true || echo false)"

FAILURE_REPO="$(new_repo failure-drill)"
sed -i '/^  failure_drill:/{n;n;s/exit 0/exit 7/;}' "$FAILURE_REPO/.github/sdlc-config.yml"
set +e
bash "$FAILURE_REPO/scripts/run-operational-readiness.sh" --repo-root "$FAILURE_REPO" --failure-drill >/dev/null
failure_exit=$?
set -e
assert_condition 'failed staging drill blocks readiness' "$([[ "$failure_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'failed drill is machine-readable' "$(grep -Eq '"mode"[[:space:]]*:[[:space:]]*"failure-drill"' "$FAILURE_REPO/.sdlc/evidence/operational-readiness.json" && grep -Eq '"result"[[:space:]]*:[[:space:]]*"FAIL"' "$FAILURE_REPO/.sdlc/evidence/operational-readiness.json" && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/record-production-outcome.sh" --repo-root "$VALID_REPO" --release-reference release-42 --environment production --technical-result PASS --business-result PASS --business-outcome 'Checkout completion met its objective.' --user-feedback 'No critical customer complaints.' >/dev/null
outcome_exit=$?
set -e
assert_condition 'successful production outcome is recorded' "$([[ "$outcome_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'production outcome evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/production-outcome.json" && echo true || echo false)"
set +e
bash "$VALID_REPO/scripts/record-production-outcome.sh" --repo-root "$VALID_REPO" --release-reference release-43 --environment production --technical-result FAIL --business-result PARTIAL --business-outcome 'Checkout completion degraded.' --user-feedback 'Customers reported failed checkout.' >/dev/null
outcome_fail_exit=$?
set -e
assert_condition 'failed production outcome blocks completion' "$([[ "$outcome_fail_exit" -eq 1 ]] && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/record-incident-review.sh" --repo-root "$VALID_REPO" --incident-reference INC-42 --severity sev2 --summary 'Checkout errors increased.' --impact 'Customers could not complete checkout.' --corrective-action 'Add dependency timeout alert.' --action-owner platform-team --due-date 2026-08-01 >/dev/null
incident_exit=$?
set -e
assert_condition 'incident review is recorded' "$([[ "$incident_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'incident evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/incident-review.json" && echo true || echo false)"

rm -f "$VALID_REPO/docs/alert-policy.md"
set +e
bash "$VALID_REPO/scripts/validate-operational-readiness.sh" --repo-root "$VALID_REPO" >/dev/null
missing_exit=$?
set -e
assert_condition 'missing operational document is rejected' "$([[ "$missing_exit" -eq 1 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 4 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 4 regression cases passed.'
