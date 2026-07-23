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
    cp "$GOVERNANCE_ROOT/scripts/autonomy-policy.py" "$repo/scripts/"
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
bash "$VALID_REPO/scripts/record-ai-change.sh" --repo-root "$VALID_REPO" --task-id TASK-42 --agent-role developer --provider github --model GPT-5 --model-version 5.0 --tenant default-tenant --repository this-repository --data-classification internal --instruction-version instructions-v1 --phase CODING --sandbox-reference worktree-42 --tool-grant read --tool-grant search --tool-call 'read docs/spec.md' --tool-call 'edit src/app.py' --changed-file src/app.py --validation build=PASS --validation test=PASS --human-approval 'reviewer|APPROVED|APR-42' --action local_validation --autonomy-decision-id AUTO-42 --autonomy-decision ALLOW --approval-id APR-42 --autonomy-evidence .sdlc/evidence/autonomy-decisions.jsonl --final-disposition APPROVED >/dev/null
record_exit=$?
set -e
assert_condition 'approved AI change is recorded' "$([[ "$record_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'change ledger exists' "$(test -f "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && echo true || echo false)"
assert_condition 'ledger is machine-readable' "$(grep -Eq '"kind":"sdlc-ai-change-ledger"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"final_disposition":"APPROVED"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"phase":"CODING"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && echo true || echo false)"
assert_condition 'ledger links autonomy decision' "$(grep -Eq '"autonomy_decision_id":"AUTO-42"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"autonomy_decision":"ALLOW"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && grep -Eq '"autonomy_approval_id":"APR-42"' "$VALID_REPO/.sdlc/evidence/ai-change-ledger.jsonl" && echo true || echo false)"

AUTONOMY="$VALID_REPO/scripts/check-autonomy.sh"
set +e
edit_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action edit --phase CODING --changed-file src/app.py --tool-grant edit --iteration 1 --now 2099-01-01T00:00:00Z)"
edit_exit=$?
set -e
assert_condition 'L1 edit is allowed within bounds' "$( [[ "$edit_exit" -eq 0 && "$edit_json" == *'"decision":"ALLOW"'* && "$edit_json" == *'"reason_code":"ALLOWED"'* ]] && echo true || echo false )"

set +e
read_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action read --phase CODING --now 2099-01-01T00:00:00Z)"
read_exit=$?
set -e
assert_condition 'safe read remains available' "$( [[ "$read_exit" -eq 0 && "$read_json" == *'"decision":"ALLOW"'* ]] && echo true || echo false )"

set +e
restricted_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action commit --phase CODING --changed-file src/app.py --tool-grant edit --iteration 1 --now 2099-01-01T00:00:00Z)"
restricted_exit=$?
set -e
assert_condition 'restricted action is denied without approval' "$( [[ "$restricted_exit" -eq 1 && "$restricted_json" == *'"reason_code":"RESTRICTED_ACTION_APPROVAL_REQUIRED"'* ]] && echo true || echo false )"

APPROVAL='APR-43|reviewer|commit|phase=CODING;files=src/app.py|v1|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-43-evidence'
set +e
approved_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action commit --phase CODING --changed-file src/app.py --tool-grant edit --approval "$APPROVAL" --iteration 1 --now 2099-01-01T00:00:00Z)"
approved_exit=$?
set -e
assert_condition 'scoped approval permits restricted action' "$( [[ "$approved_exit" -eq 0 && "$approved_json" == *'"decision":"ALLOW"'* && "$approved_json" == *'"approval_id":"APR-43"'* ]] && echo true || echo false )"

EXPIRED_APPROVAL='APR-44|reviewer|commit|phase=CODING;files=src/app.py|v1|2098-12-31T20:00:00Z|2098-12-31T21:00:00Z|APPROVED|APR-44-evidence'
set +e
expired_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action commit --phase CODING --changed-file src/app.py --tool-grant edit --approval "$EXPIRED_APPROVAL" --iteration 1 --now 2099-01-01T00:00:00Z)"
expired_exit=$?
set -e
assert_condition 'expired approval is denied' "$( [[ "$expired_exit" -eq 1 && "$expired_json" == *'"reason_code":"APPROVAL_EXPIRED"'* ]] && echo true || echo false )"

SCOPE_APPROVAL='APR-45|reviewer|commit|phase=CODING;files=src/other.py|v1|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-45-evidence'
set +e
scope_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action commit --phase CODING --changed-file src/app.py --tool-grant edit --approval "$SCOPE_APPROVAL" --iteration 1 --now 2099-01-01T00:00:00Z)"
scope_exit=$?
set -e
assert_condition 'out-of-scope approval is denied' "$( [[ "$scope_exit" -eq 1 && "$scope_json" == *'"reason_code":"APPROVAL_SCOPE_MISMATCH"'* ]] && echo true || echo false )"

set +e
iteration_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action edit --phase CODING --changed-file src/app.py --tool-grant edit --iteration 4 --now 2099-01-01T00:00:00Z)"
iteration_exit=$?
set -e
assert_condition 'iteration exhaustion escalates' "$( [[ "$iteration_exit" -eq 1 && "$iteration_json" == *'"reason_code":"ITERATION_LIMIT"'* && "$iteration_json" == *'"escalation_required":true'* ]] && echo true || echo false )"

set +e
widen_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action local_validation --phase CODING --changed-file src/app.py --tool-grant execute --iteration 1 --now 2099-01-01T00:00:00Z)"
widen_exit=$?
set -e
assert_condition 'permission widening is denied' "$( [[ "$widen_exit" -eq 1 && "$widen_json" == *'"reason_code":"TOOL_GRANT_NOT_ALLOWLISTED"'* ]] && echo true || echo false )"

EXPIRED_POLICY_REPO="$(new_repo expired-policy)"
sed -i 's/2099-12-31T23:59:59Z/2000-01-01T00:00:00Z/' "$EXPIRED_POLICY_REPO/.github/sdlc-config.yml"
set +e
expired_policy_read="$(bash "$EXPIRED_POLICY_REPO/scripts/check-autonomy.sh" --repo-root "$EXPIRED_POLICY_REPO" --action read --phase CODING --now 2099-01-01T00:00:00Z)"
expired_policy_read_exit=$?
set -e
assert_condition 'expired policy falls back to safe L0 read' "$( [[ "$expired_policy_read_exit" -eq 0 && "$expired_policy_read" == *'"reason_code":"SAFE_L0_FALLBACK"'* ]] && echo true || echo false )"

VERSION_APPROVAL='APR-46|reviewer|commit|phase=CODING;files=src/app.py|v2|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-46-evidence'
set +e
version_json="$(bash "$AUTONOMY" --repo-root "$VALID_REPO" --action commit --phase CODING --changed-file src/app.py --tool-grant edit --approval "$VERSION_APPROVAL" --iteration 1 --now 2099-01-01T00:00:00Z)"
version_exit=$?
set -e
assert_condition 'policy-version-mismatched approval is denied' "$( [[ "$version_exit" -eq 1 && "$version_json" == *'"reason_code":"APPROVAL_POLICY_MISMATCH"'* ]] && echo true || echo false )"

LEVEL_REPO="$(new_repo levels)"
sed -i 's/autonomy_level: L1/autonomy_level: L0/' "$LEVEL_REPO/.github/sdlc-config.yml"
set +e
l0_read="$(bash "$LEVEL_REPO/scripts/check-autonomy.sh" --repo-root "$LEVEL_REPO" --action read --phase CODING --now 2099-01-01T00:00:00Z)"; l0_read_exit=$?
l0_edit="$(bash "$LEVEL_REPO/scripts/check-autonomy.sh" --repo-root "$LEVEL_REPO" --action edit --phase CODING --changed-file src/app.py --tool-grant edit --now 2099-01-01T00:00:00Z)"; l0_edit_exit=$?
set -e
assert_condition 'L0 allows read' "$( [[ "$l0_read_exit" -eq 0 && "$l0_read" == *'"decision":"ALLOW"'* ]] && echo true || echo false )"
assert_condition 'L0 denies edits' "$( [[ "$l0_edit_exit" -eq 1 && "$l0_edit" == *'"decision":"DENY"'* ]] && echo true || echo false )"
sed -i 's/autonomy_level: L0/autonomy_level: L2/' "$LEVEL_REPO/.github/sdlc-config.yml"
set +e
l2_full="$(bash "$LEVEL_REPO/scripts/check-autonomy.sh" --repo-root "$LEVEL_REPO" --action full_validation --phase TESTING --changed-file src/app.py --tool-grant edit --now 2099-01-01T00:00:00Z)"; l2_full_exit=$?
set -e
assert_condition 'L2 allows full validation' "$( [[ "$l2_full_exit" -eq 0 && "$l2_full" == *'"decision":"ALLOW"'* ]] && echo true || echo false )"
sed -i 's/autonomy_level: L2/autonomy_level: L3/' "$LEVEL_REPO/.github/sdlc-config.yml"
set +e
l3_pr="$(bash "$LEVEL_REPO/scripts/check-autonomy.sh" --repo-root "$LEVEL_REPO" --action pull_request_update --phase CODING --branch feature/test --changed-file src/app.py --tool-grant edit --now 2099-01-01T00:00:00Z)"; l3_pr_exit=$?
set -e
assert_condition 'L3 allows bounded pull-request updates' "$( [[ "$l3_pr_exit" -eq 0 && "$l3_pr" == *'"decision":"ALLOW"'* ]] && echo true || echo false )"
sed -i 's/autonomy_level: L3/autonomy_level: L4/' "$LEVEL_REPO/.github/sdlc-config.yml"
set +e
l4_batch="$(bash "$LEVEL_REPO/scripts/check-autonomy.sh" --repo-root "$LEVEL_REPO" --action maintenance_batch --phase TESTING --changed-file src/app.py --tool-grant edit --now 2099-01-01T00:00:00Z)"; l4_batch_exit=$?
set -e
assert_condition 'L4 allows policy-bound maintenance' "$( [[ "$l4_batch_exit" -eq 0 && "$l4_batch" == *'"decision":"ALLOW"'* ]] && echo true || echo false )"

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