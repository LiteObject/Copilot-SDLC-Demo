#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase7/config-measurement-valid.yml"
BASE_SCRIPTS="$ROOT/template/base/scripts"
MEASUREMENT_ROOT="$ROOT/template/extensions/measurement"
TEMP="$(mktemp -d "$ROOT/tests/.phase7-bash.XXXXXX")"
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
    cp "$MEASUREMENT_ROOT/scripts/"*.sh "$repo/scripts/"
    cp "$MEASUREMENT_ROOT/docs/"*.md "$repo/docs/"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase7@example.test
    git -C "$repo" config user.name 'Phase 7 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'phase 7 fixture'
    printf '%s' "$repo"
}

VALID_REPO="$(new_repo valid)"
set +e
bash "$VALID_REPO/scripts/validate-measurement.sh" --repo-root "$VALID_REPO" >/dev/null
config_exit=$?
set -e
assert_condition 'measurement config validates' "$([[ "$config_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'measurement config evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/measurement-config-validation.json" && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/run-measurement.sh" --repo-root "$VALID_REPO" --record-spec >/dev/null
measurement_exit=$?
set -e
assert_condition 'measurement checks pass' "$([[ "$measurement_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'measurement evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"
assert_condition 'all measurement checks are machine-readable' "$(grep -Eq 'measurement_baseline' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement_snapshot' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement_review' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq '"result":"PASS"' "$VALID_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"
assert_condition 'all roadmap phases have both metric types' "$(grep -Eq 'phase0_outcome' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase7_outcome' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase0_leading_indicator' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase7_leading_indicator' "$VALID_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"
assert_condition 'measurement gate is recorded' "$(grep -Eq '^gate_measurement_result:[[:space:]]+PASS[[:space:]]*$' "$VALID_REPO/docs/spec.md" && grep -Eq '^measurement_enabled:[[:space:]]+true[[:space:]]*$' "$VALID_REPO/docs/spec.md" && echo true || echo false)"

FAILURE_REPO="$(new_repo failure)"
sed -i 's/printf measurement-snapshot-pass/exit 9/' "$FAILURE_REPO/.github/sdlc-config.yml"
set +e
bash "$FAILURE_REPO/scripts/run-measurement.sh" --repo-root "$FAILURE_REPO" --record-spec >/dev/null
failure_exit=$?
set -e
assert_condition 'failed measurement task blocks gate' "$([[ "$failure_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'failed measurement evidence is machine-readable' "$(grep -Eq '"result":[[:space:]]*"FAIL"' "$FAILURE_REPO/.sdlc/evidence/measurement.json" && grep -Eq '^gate_measurement_result:[[:space:]]+FAIL[[:space:]]*$' "$FAILURE_REPO/docs/spec.md" && echo true || echo false)"

INVALID_OWNER_REPO="$(new_repo invalid-owner)"
sed -i 's/owner: measurement-owner/owner: ""/' "$INVALID_OWNER_REPO/.github/sdlc-config.yml"
set +e
bash "$INVALID_OWNER_REPO/scripts/validate-measurement.sh" --repo-root "$INVALID_OWNER_REPO" >/dev/null
owner_exit=$?
set -e
assert_condition 'missing measurement owner is rejected' "$([[ "$owner_exit" -eq 1 ]] && echo true || echo false)"

rm -f "$VALID_REPO/docs/measurement-privacy-review.md"
set +e
bash "$VALID_REPO/scripts/validate-measurement.sh" --repo-root "$VALID_REPO" >/dev/null
missing_exit=$?
set -e
assert_condition 'missing privacy review is rejected' "$([[ "$missing_exit" -eq 1 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 7 Bash regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 7 regression cases passed.'