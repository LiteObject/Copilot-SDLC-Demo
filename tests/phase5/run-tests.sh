#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase5/config-ai-governance-valid.yml"
BASE_SCRIPTS="$ROOT/template/base/scripts"
GOVERNANCE_ROOT="$ROOT/template/extensions/ai-governance"
TEMP="$(mktemp -d "$ROOT/tests/.phase5-bash.XXXXXX")"
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
    cp "$GOVERNANCE_ROOT/scripts"/*.sh "$repo/scripts/"
    cp -R "$GOVERNANCE_ROOT/docs/." "$repo/docs/"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase5@example.test
    git -C "$repo" config user.name 'Phase 5 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'phase 5 fixture'
    printf '%s' "$repo"
}

VALID_REPO="$(new_repo valid)"
set +e
bash "$VALID_REPO/scripts/validate-ai-governance.sh" --repo-root "$VALID_REPO" >/dev/null
config_exit=$?
set -e
assert_condition 'AI governance config validates' "$([[ "$config_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'governance config evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-governance-config-validation.json" && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/record-ai-change.sh" --repo-root "$VALID_REPO" --task-id TASK-42 --agent-role developer --provider github --model GPT-5 --model-version 5.0 --tenant default-tenant --repository this-repository --data-classification internal --instruction-version instructions-v1 --phase CODING --sandbox-reference worktree-42 --tool-grant read --tool-grant search --tool-call 'read docs/spec.md' --tool-call 'edit src/app.py' --changed-file src/app.py --validation build=PASS --validation test=PASS --human-approval 'reviewer|APPROVED|APR-42' --final-disposition APPROVED >/dev/null
record_exit=$?
set -e
assert_condition 'approved AI change is recorded' "$([[ "$record_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'change ledger exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && echo true || echo false)"
assert_condition 'ledger is machine-readable' "$(grep -Eq '"kind":"sdlc-ai-change-ledger"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"final_disposition":"APPROVED"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"phase":"CODING"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && echo true || echo false)"

set +e
bash "$VALID_REPO/scripts/run-ai-governance.sh" --repo-root "$VALID_REPO" --record-spec >/dev/null
evaluation_exit=$?
set -e
assert_condition 'agent evaluation passes' "$([[ "$evaluation_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'evaluation evidence exists' "$(test -f "$VALID_REPO/.sdlc/evidence/agent-evaluation.json" && echo true || echo false)"
assert_condition 'AI governance gate is recorded' "$(grep -Eq '^gate_ai_governance_result:[[:space:]]+PASS[[:space:]]*$' "$VALID_REPO/docs/spec.md" && echo true || echo false)"

before_lines="$(wc -l < "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl")"
set +e
bash "$VALID_REPO/scripts/record-ai-change.sh" --repo-root "$VALID_REPO" --task-id TASK-43 --agent-role developer --provider github --model GPT-5 --model-version 5.0 --tenant default-tenant --repository this-repository --data-classification internal --instruction-version instructions-v1 --phase CODING --sandbox-reference worktree-43 --tool-grant execute --tool-call 'execute deploy' --changed-file src/app.py --validation build=PASS --human-approval 'reviewer|APPROVED|APR-43' --final-disposition APPROVED >/dev/null
tool_exit=$?
set -e
assert_condition 'unapproved tool grant is rejected' "$([[ "$tool_exit" -eq 1 ]] && echo true || echo false)"
after_lines="$(wc -l < "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl")"
assert_condition 'rejected ledger entry is not appended' "$([[ "$before_lines" -eq "$after_lines" ]] && echo true || echo false)"

FAILURE_REPO="$(new_repo failure)"
sed -i 's/printf evaluation-pass/exit 9/' "$FAILURE_REPO/.github/sdlc-config.yml"
set +e
bash "$FAILURE_REPO/scripts/run-ai-governance.sh" --repo-root "$FAILURE_REPO" --record-spec >/dev/null
failure_exit=$?
set -e
assert_condition 'failed agent evaluation blocks governance' "$([[ "$failure_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'failed evaluation is machine-readable' "$(grep -Eq '"result":"FAIL"' "$FAILURE_REPO/.sdlc/evidence/agent-evaluation.json" && grep -Eq '^gate_ai_governance_result:[[:space:]]+FAIL[[:space:]]*$' "$FAILURE_REPO/docs/spec.md" && echo true || echo false)"

rm -f "$VALID_REPO/docs/agent-permissions.md"
set +e
bash "$VALID_REPO/scripts/validate-ai-governance.sh" --repo-root "$VALID_REPO" >/dev/null
missing_exit=$?
set -e
assert_condition 'missing governance document is rejected' "$([[ "$missing_exit" -eq 1 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 5 Bash regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 5 regression cases passed.'