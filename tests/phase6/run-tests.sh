#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase6/config-ai-lifecycle-valid.yml"
BASE_SCRIPTS="$ROOT/template/base/scripts"
LIFECYCLE_ROOT="$ROOT/template/extensions/ai-lifecycle"
TEMP="$(mktemp -d "$ROOT/tests/.phase6-bash.XXXXXX")"
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
    cp "$LIFECYCLE_ROOT/scripts/"*.sh "$repo/scripts/"
    cp "$LIFECYCLE_ROOT/docs/"*.md "$repo/docs/"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase6@example.test
    git -C "$repo" config user.name 'Phase 6 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'phase 6 fixture'
    printf '%s' "$repo"
}

VALID_REPO="$(new_repo valid)"
set +e
bash "$VALID_REPO/scripts/validate-ai-lifecycle.sh" --repo-root "$VALID_REPO" >/dev/null
config_exit=$?
set -e
assert_condition 'AI lifecycle config validates' "$([[ "$config_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'lifecycle config evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-lifecycle-config-validation.json" && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/run-ai-lifecycle.sh" --repo-root "$VALID_REPO" --record-spec >/dev/null
lifecycle_exit=$?
set -e
assert_condition 'AI lifecycle checks pass' "$([[ "$lifecycle_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'lifecycle evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-lifecycle.json" && echo true || echo false)"
assert_condition 'configured evaluation report exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-evaluation.json" && echo true || echo false)"
assert_condition 'AI lifecycle gate is recorded' "$(grep -Eq '^gate_ai_lifecycle_result:[[:space:]]+PASS[[:space:]]*$' "$VALID_REPO/docs/spec.md" && grep -Eq '^ai_lifecycle_enabled:[[:space:]]+true[[:space:]]*$' "$VALID_REPO/docs/spec.md" && echo true || echo false)"
assert_condition 'all lifecycle checks are machine-readable' "$(grep -Eq 'ai_evaluation' "$VALID_REPO/.sdlc/evidence/ai-lifecycle.json" && grep -Eq 'ai_red_team' "$VALID_REPO/.sdlc/evidence/ai-lifecycle.json" && grep -Eq 'ai_production_exercise' "$VALID_REPO/.sdlc/evidence/ai-lifecycle.json" && grep -Eq '"result":"PASS"' "$VALID_REPO/.sdlc/evidence/ai-lifecycle.json" && echo true || echo false)"

FAILURE_REPO="$(new_repo failure)"
sed -i 's/printf ai-evaluation-pass/exit 9/' "$FAILURE_REPO/.github/sdlc-config.yml"
set +e
bash "$FAILURE_REPO/scripts/run-ai-lifecycle.sh" --repo-root "$FAILURE_REPO" --record-spec >/dev/null
failure_exit=$?
set -e
assert_condition 'failed evaluation blocks lifecycle gate' "$([[ "$failure_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'failed lifecycle evidence is machine-readable' "$(grep -Eq '"result":"FAIL"' "$FAILURE_REPO/.sdlc/evidence/ai-lifecycle.json" && grep -Eq '^gate_ai_lifecycle_result:[[:space:]]+FAIL[[:space:]]*$' "$FAILURE_REPO/docs/spec.md" && echo true || echo false)"

rm -f "$VALID_REPO/docs/ai-runtime-controls.md"
set +e
bash "$VALID_REPO/scripts/validate-ai-lifecycle.sh" --repo-root "$VALID_REPO" >/dev/null
missing_exit=$?
set -e
assert_condition 'missing runtime controls document is rejected' "$([[ "$missing_exit" -eq 1 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 6 Bash regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 6 regression cases passed.'
