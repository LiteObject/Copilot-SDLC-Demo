#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase7/config-measurement-valid.yml"
EXTENSION_FIXTURE="$ROOT/tests/fixtures/phase7/config-extension-gates.yml"
PHASE_FIXTURE="$ROOT/tests/fixtures/phase0/valid-readiness.md"
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
    sed -i 's/executable: python/executable: python3/' "$repo/.github/sdlc-config.yml"
    cp "$ROOT/template/base/docs/spec.md" "$repo/docs/spec.md"
    cp "$BASE_SCRIPTS"/* "$repo/scripts/"
    cp "$MEASUREMENT_ROOT/scripts/"*.sh "$repo/scripts/"
    cp "$MEASUREMENT_ROOT/scripts/"*.py "$repo/scripts/"
    cp "$ROOT/tests/fixtures/phase7/write-measurement-snapshot.py" "$repo/scripts/"
    cp "$MEASUREMENT_ROOT/docs/"* "$repo/docs/"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase7@example.test
    git -C "$repo" config user.name 'Phase 7 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'phase 7 fixture'
    printf '%s' "$repo"
}

new_transition_repo() {
    local name="$1" state="${2:-testing}"
    local repo="$TEMP/$name"
    mkdir -p "$repo/.github" "$repo/docs" "$repo/tests/fixtures/phase0/evidence" "$repo/scripts"
    cp "$EXTENSION_FIXTURE" "$repo/.github/sdlc-config.yml"
    cp "$PHASE_FIXTURE" "$repo/docs/spec.md"
    cp "$BASE_SCRIPTS"/* "$repo/scripts/"
    printf 'fixture gate\n' > "$repo/tests/fixtures/phase0/evidence/gate.txt"
    if [[ "$state" == coding ]]; then
        sed -i 's/current_phase: TESTING/current_phase: CODING/; s/last_transition_to: TESTING/last_transition_to: CODING/; s/`TESTING`/`CODING`/; s/deployment_readiness_enabled: true/deployment_readiness_enabled: false/' "$repo/docs/spec.md"
    else
        sed -i 's/deployment_readiness_enabled: true/deployment_readiness_enabled: false/' "$repo/docs/spec.md"
    fi
    tr -d '\r' < "$repo/docs/spec.md" > "$repo/docs/spec.md.tmp"
    mv "$repo/docs/spec.md.tmp" "$repo/docs/spec.md"
    git -C "$repo" init -q
    git -C "$repo" config user.email phase7@example.test
    git -C "$repo" config user.name 'Phase 7 Tests'
    git -C "$repo" add .
    git -C "$repo" commit -q -m 'phase 7 transition fixture'
    printf '%s' "$repo"
}

add_gate_records() {
    local repo="$1"
    shift
    local records='' name evidence
    mkdir -p "$repo/.sdlc/evidence"
    for name in "$@"; do
        evidence=".sdlc/evidence/$name.txt"
        printf '%s passed\n' "$name" > "$repo/$evidence"
        records+="gate_${name}_command: fixture\n"
        records+="gate_${name}_commit_sha: fixture-commit\n"
        records+="gate_${name}_tree_digest: fixture-tree\n"
        records+="gate_${name}_timestamp: 2026-07-20T00:00:00Z\n"
        records+="gate_${name}_exit_code: 0\n"
        records+="gate_${name}_result: PASS\n"
        records+="gate_${name}_evidence: $evidence\n"
    done
    awk -v records="$records" 'BEGIN { inserted = 0 } /^---$/ && NR > 1 && inserted == 0 { printf "%s", records; inserted = 1 } { print }' "$repo/docs/spec.md" > "$repo/docs/spec.md.tmp"
    mv "$repo/docs/spec.md.tmp" "$repo/docs/spec.md"
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
assert_condition 'all measurement checks are machine-readable' "$(grep -Eq 'measurement_baseline' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement_snapshot' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement_review' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement_snapshot_schema' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement-snapshot-validation' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq '"result":"PASS"' "$VALID_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"
assert_condition 'measurement report is model-bound and complete' "$(grep -Eq 'measurement_report' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'measurement-review-validation' "$VALID_REPO/.sdlc/evidence/measurement-review-validation.json" && grep -Eq '"model": "dora-ai-v1"' "$VALID_REPO/.sdlc/evidence/measurement-report.json" && grep -Eq '"status": "COMPLETE"' "$VALID_REPO/.sdlc/evidence/measurement-report.json" && echo true || echo false)"
PYTHON_EXECUTABLE=''
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON_EXECUTABLE="$candidate"; break; fi
done
REPORT_PATH="$VALID_REPO/.sdlc/evidence/measurement-report.json"
formula_check="$($PYTHON_EXECUTABLE - "$REPORT_PATH" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
print("true" if len(report["metrics"]) == 34 and all(item["status"] == "OK" for item in report["metrics"]) else "false")
PY
)"
assert_condition 'catalog formulas all produce report metrics' "$formula_check"
classification_check="$($PYTHON_EXECUTABLE - "$REPORT_PATH" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
metrics = {item["id"]: item for item in report["metrics"]}
print("true" if metrics["deployment_frequency"]["numerator"] == 2 and metrics["change_failure_rate"]["numerator"] == 1 and metrics["change_failure_rate"]["denominator"] == 2 else "false")
PY
)"
assert_condition 'duplicate retries are excluded and rollback is classified' "$classification_check"
severity_check="$($PYTHON_EXECUTABLE - "$REPORT_PATH" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
metric = next(item for item in report["metrics"] if item["id"] == "security_findings")
print("true" if metric["breakdown"]["high"]["value"] == 1 and metric["breakdown"]["low"]["value"] == 1 else "false")
PY
)"
assert_condition 'security findings retain severity breakdowns' "$severity_check"
timezone_check="$($PYTHON_EXECUTABLE - "$REPORT_PATH" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
metric = next(item for item in report["metrics"] if item["id"] == "lead_time")
print("true" if metric["value"] == 90000 else "false")
PY
)"
assert_condition 'timezone boundaries normalize lead time' "$timezone_check"

ENGINE="$VALID_REPO/scripts/measurement.py"
EVENT_SCHEMA="$VALID_REPO/docs/measurement-events.json"
EDGE_EVENTS="$VALID_REPO/.sdlc/evidence/edge-events.jsonl"
cp "$ROOT/tests/fixtures/phase7/measurement-events-edge.jsonl" "$EDGE_EVENTS"
set +e
"$PYTHON_EXECUTABLE" "$ENGINE" validate-events --events-path "$EDGE_EVENTS" --event-schema-path "$EVENT_SCHEMA" --model dora-ai-v1 --evidence-path "$VALID_REPO/.sdlc/evidence/edge-event-validation.json" >/dev/null
edge_validation_exit=$?
set -e
assert_condition 'boundary, retry, rollback, and late-event fixture validates' "$([[ "$edge_validation_exit" -eq 0 ]] && echo true || echo false)"
VALID_EVENTS="$VALID_REPO/.sdlc/evidence/measurement-events-valid.jsonl"
cp "$VALID_REPO/.sdlc/evidence/measurement-events.jsonl" "$VALID_EVENTS"
cp "$EDGE_EVENTS" "$VALID_REPO/.sdlc/evidence/measurement-events.jsonl"
EDGE_REPORT="$VALID_REPO/.sdlc/evidence/edge-report.json"
set +e
"$PYTHON_EXECUTABLE" "$ENGINE" report --config-path "$VALID_REPO/.github/sdlc-config.yml" --repo-root "$VALID_REPO" --output-path "$EDGE_REPORT" --evidence-path "$VALID_REPO/.sdlc/evidence/edge-report-validation.json" >/dev/null
edge_report_exit=$?
set -e
edge_report_check="$($PYTHON_EXECUTABLE - "$EDGE_REPORT" "$edge_report_exit" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
metrics = {item["id"]: item for item in report["metrics"]}
print("true" if int(sys.argv[2]) == 1 and metrics["deployment_frequency"]["value"] == 1 and metrics["change_failure_rate"]["value"] == 1 and report["completeness"]["late_event_count"] == 1 else "false")
PY
)"
assert_condition 'edge report deduplicates deployment IDs and records late events' "$edge_report_check"
cp "$VALID_EVENTS" "$VALID_REPO/.sdlc/evidence/measurement-events.jsonl"

VALID_SNAPSHOT="$VALID_REPO/.sdlc/evidence/measurement-snapshot-valid.json"
cp "$VALID_REPO/.sdlc/evidence/measurement-snapshot.json" "$VALID_SNAPSHOT"
cp "$ROOT/tests/fixtures/phase7/measurement-snapshot-zero-denominator.json" "$VALID_REPO/.sdlc/evidence/measurement-snapshot.json"
ZERO_REPORT="$VALID_REPO/.sdlc/evidence/zero-denominator-report.json"
set +e
"$PYTHON_EXECUTABLE" "$ENGINE" report --config-path "$VALID_REPO/.github/sdlc-config.yml" --repo-root "$VALID_REPO" --output-path "$ZERO_REPORT" --evidence-path "$VALID_REPO/.sdlc/evidence/zero-denominator-validation.json" >/dev/null
zero_report_exit=$?
set -e
zero_report_check="$($PYTHON_EXECUTABLE - "$ZERO_REPORT" "$zero_report_exit" <<'PY'
import json
import sys

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
print("true" if int(sys.argv[2]) == 1 and report["completeness"]["status"] == "INCOMPLETE" and any(item["status"] == "NO_DATA" for item in report["metrics"]) else "false")
PY
)"
assert_condition 'zero-denominator period is explicit and incomplete' "$zero_report_check"
cp "$VALID_SNAPSHOT" "$VALID_REPO/.sdlc/evidence/measurement-snapshot.json"

MISSING_EVENTS="$VALID_REPO/.sdlc/evidence/missing-events.jsonl"
PRIVACY_EVENTS="$VALID_REPO/.sdlc/evidence/privacy-events.jsonl"
cp "$ROOT/tests/fixtures/phase7/measurement-events-missing-field.jsonl" "$MISSING_EVENTS"
cp "$ROOT/tests/fixtures/phase7/measurement-events-privacy.jsonl" "$PRIVACY_EVENTS"
set +e
"$PYTHON_EXECUTABLE" "$ENGINE" validate-events --events-path "$MISSING_EVENTS" --event-schema-path "$EVENT_SCHEMA" --model dora-ai-v1 --evidence-path "$VALID_REPO/.sdlc/evidence/missing-event-validation.json" >/dev/null
missing_event_exit=$?
"$PYTHON_EXECUTABLE" "$ENGINE" validate-events --events-path "$PRIVACY_EVENTS" --event-schema-path "$EVENT_SCHEMA" --model dora-ai-v1 --evidence-path "$VALID_REPO/.sdlc/evidence/privacy-event-validation.json" >/dev/null
privacy_event_exit=$?
set -e
assert_condition 'missing event fields are rejected' "$([[ "$missing_event_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'privacy-sensitive event fields are rejected' "$([[ "$privacy_event_exit" -eq 1 ]] && grep -Eq 'Privacy-sensitive field' "$VALID_REPO/.sdlc/evidence/privacy-event-validation.json" && echo true || echo false)"

cp "$ROOT/tests/fixtures/phase7/measurement-experiments-invalid.json" "$VALID_REPO/docs/measurement-experiments.json"
set +e
"$PYTHON_EXECUTABLE" "$ENGINE" validate-review --config-path "$VALID_REPO/.github/sdlc-config.yml" --repo-root "$VALID_REPO" --report-path "$REPORT_PATH" --evidence-path "$VALID_REPO/.sdlc/evidence/invalid-experiment-validation.json" >/dev/null
invalid_experiment_exit=$?
set -e
assert_condition 'accepted experiments require a regression check' "$([[ "$invalid_experiment_exit" -eq 1 ]] && grep -Eq 'regression_check' "$VALID_REPO/.sdlc/evidence/invalid-experiment-validation.json" && echo true || echo false)"
assert_condition 'all roadmap phases have both metric types' "$(grep -Eq 'phase0_outcome' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase7_outcome' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase0_leading_indicator' "$VALID_REPO/.sdlc/evidence/measurement.json" && grep -Eq 'phase7_leading_indicator' "$VALID_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"
assert_condition 'measurement gate is recorded' "$(grep -Eq '^gate_measurement_result:[[:space:]]+PASS[[:space:]]*$' "$VALID_REPO/docs/spec.md" && grep -Eq '^measurement_enabled:[[:space:]]+true[[:space:]]*$' "$VALID_REPO/docs/spec.md" && echo true || echo false)"

FAILURE_REPO="$(new_repo failure)"
printf 'raise SystemExit(9)\n' > "$FAILURE_REPO/scripts/write-measurement-snapshot.py"
set +e
bash "$FAILURE_REPO/scripts/run-measurement.sh" --repo-root "$FAILURE_REPO" --record-spec >/dev/null
failure_exit=$?
set -e
assert_condition 'failed measurement task blocks gate' "$([[ "$failure_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'failed measurement evidence is machine-readable' "$(grep -Eq '"result":[[:space:]]*"FAIL"' "$FAILURE_REPO/.sdlc/evidence/measurement.json" && grep -Eq '^gate_measurement_result:[[:space:]]+FAIL[[:space:]]*$' "$FAILURE_REPO/docs/spec.md" && echo true || echo false)"

INVALID_SNAPSHOT_REPO="$(new_repo invalid-snapshot)"
sed -i 's/"privacy_review": "APPROVED"/"privacy_review": "NOT_REVIEWED"/' "$INVALID_SNAPSHOT_REPO/scripts/write-measurement-snapshot.py"
set +e
bash "$INVALID_SNAPSHOT_REPO/scripts/run-measurement.sh" --repo-root "$INVALID_SNAPSHOT_REPO" --record-spec >/dev/null
invalid_snapshot_exit=$?
set -e
assert_condition 'invalid snapshot data blocks measurement gate' "$([[ "$invalid_snapshot_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'invalid snapshot evidence is machine-readable' "$(grep -Eq 'measurement_snapshot_schema' "$INVALID_SNAPSHOT_REPO/.sdlc/evidence/measurement.json" && grep -Eq '"result":"FAIL"' "$INVALID_SNAPSHOT_REPO/.sdlc/evidence/measurement.json" && echo true || echo false)"

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

COMPLETION_REPO="$(new_transition_repo completion-gates)"
set +e
bash "$COMPLETION_REPO/scripts/check-phase.sh" DONE --repo-root "$COMPLETION_REPO" --spec-path "$COMPLETION_REPO/docs/spec.md" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
completion_missing_exit=$?
set -e
assert_condition 'enabled completion gates block direct DONE without deployment' "$([[ "$completion_missing_exit" -eq 2 ]] && echo true || echo false)"
add_gate_records "$COMPLETION_REPO" operational_readiness ai_lifecycle measurement
set +e
bash "$COMPLETION_REPO/scripts/check-phase.sh" DONE --repo-root "$COMPLETION_REPO" --spec-path "$COMPLETION_REPO/docs/spec.md" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
completion_pass_exit=$?
set -e
assert_condition 'enabled completion gates pass direct DONE without deployment' "$([[ "$completion_pass_exit" -eq 0 ]] && echo true || echo false)"

GOVERNANCE_REPO="$(new_transition_repo governance-gate coding)"
add_gate_records "$GOVERNANCE_REPO" build
set +e
bash "$GOVERNANCE_REPO/scripts/check-phase.sh" REVIEW --repo-root "$GOVERNANCE_REPO" --spec-path "$GOVERNANCE_REPO/docs/spec.md" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
governance_missing_exit=$?
set -e
assert_condition 'enabled AI governance blocks review without governance gate' "$([[ "$governance_missing_exit" -eq 2 ]] && echo true || echo false)"
add_gate_records "$GOVERNANCE_REPO" ai_governance
set +e
bash "$GOVERNANCE_REPO/scripts/check-phase.sh" REVIEW --repo-root "$GOVERNANCE_REPO" --spec-path "$GOVERNANCE_REPO/docs/spec.md" --commit-sha fixture-commit --tree-digest fixture-tree >/dev/null
governance_pass_exit=$?
set -e
assert_condition 'enabled AI governance gate passes review' "$([[ "$governance_pass_exit" -eq 0 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 7 Bash regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 7 regression cases passed.'