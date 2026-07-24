import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
catalog = json.loads(
    (root / "docs/measurement-catalog.json").read_text(encoding="utf-8")
)
metric_ids = [
    "lead_time",
    "deployment_frequency",
    "change_failure_rate",
    "recovery_time",
    "escaped_defects",
    "security_findings",
    "flaky_test_rate",
    "rollback_rate",
    "slo_attainment",
    "complete_evidence_rate",
    "agent_suggested_defect_rate",
    "human_rework",
    "review_acceptance_rate",
    "scope_drift_rate",
    "validation_pass_rate",
    "model_tool_policy_violations",
    "review_cycle_count",
    "time_saved_or_added",
    "phase0_outcome",
    "phase1_outcome",
    "phase2_outcome",
    "phase3_outcome",
    "phase4_outcome",
    "phase5_outcome",
    "phase6_outcome",
    "phase7_outcome",
    "phase0_leading_indicator",
    "phase1_leading_indicator",
    "phase2_leading_indicator",
    "phase3_leading_indicator",
    "phase4_leading_indicator",
    "phase5_leading_indicator",
    "phase6_leading_indicator",
    "phase7_leading_indicator",
]
catalog_by_id = {metric["id"]: metric for metric in catalog["metrics"]}
baseline_values = {
    "lead_time": 90000.0,
    "deployment_frequency": 2.0,
    "change_failure_rate": 0.5,
    "recovery_time": 3600.0,
    "escaped_defects": 1.0,
    "security_findings": 2.0,
    "flaky_test_rate": 0.5,
    "rollback_rate": 0.5,
    "slo_attainment": 0.99,
    "complete_evidence_rate": 1.0,
    "agent_suggested_defect_rate": 0.5,
    "human_rework": 0.5,
    "review_acceptance_rate": 0.5,
    "scope_drift_rate": 0.5,
    "validation_pass_rate": 1.0,
    "model_tool_policy_violations": 0.0,
    "review_cycle_count": 1.0,
    "time_saved_or_added": 2.0,
}
baseline_values.update(
    {
        f"phase{phase}_{kind}": 1.0
        for phase in range(8)
        for kind in ("outcome", "leading_indicator")
    }
)


def event(event_id, event_type, event_time, **fields):
    return {
        "event_id": event_id,
        "event_type": event_type,
        "model": "dora-ai-v1",
        "event_time": event_time,
        "repository_id": "fixture-repository",
        "service_id": "checkout",
        **fields,
    }


events = [
    event(
        "change-1",
        "change",
        "2026-07-01T00:00:00Z",
        change_id="change-1",
        first_commit_at="2026-06-30T00:00:00+00:00",
    ),
    event(
        "change-2",
        "change",
        "2026-07-02T00:00:00+02:00",
        change_id="change-2",
        first_commit_at="2026-07-02T00:00:00+02:00",
    ),
    event(
        "deployment-1",
        "deployment",
        "2026-07-05T00:00:00Z",
        deployment_id="deployment-1",
        change_id="change-1",
        completed_at="2026-07-01T00:00:00Z",
        environment="production",
        status="succeeded",
        is_retry=False,
    ),
    event(
        "deployment-2",
        "deployment",
        "2026-07-10T00:00:00Z",
        deployment_id="deployment-2",
        change_id="change-2",
        completed_at="2026-07-03T00:00:00Z",
        environment="production",
        status="succeeded",
        is_retry=False,
    ),
    event(
        "deployment-2-retry-record",
        "deployment",
        "2026-07-10T00:01:00Z",
        deployment_id="deployment-2",
        change_id="change-2",
        completed_at="2026-07-03T00:00:00Z",
        environment="production",
        status="succeeded",
        is_retry=True,
    ),
    event(
        "incident-1",
        "incident",
        "2026-07-10T00:00:00Z",
        incident_id="incident-1",
        deployment_id="deployment-2",
        detected_at="2026-07-10T00:00:00Z",
        restored_at="2026-07-10T01:00:00Z",
        classification="production_impact",
        paused_seconds=0,
    ),
    event(
        "rollback-1",
        "rollback",
        "2026-07-10T00:30:00Z",
        deployment_id="deployment-2",
        classification="rollback",
    ),
    event(
        "defect-1",
        "defect",
        "2026-07-11T00:00:00Z",
        defect_id="defect-1",
        change_id="change-1",
        escaped=True,
        suggested_by_agent=False,
    ),
    event(
        "defect-2",
        "defect",
        "2026-07-12T00:00:00Z",
        defect_id="defect-2",
        change_id="change-2",
        escaped=False,
        suggested_by_agent=True,
    ),
    event(
        "finding-1",
        "security_finding",
        "2026-07-13T00:00:00Z",
        finding_id="finding-1",
        severity="high",
    ),
    event(
        "finding-2",
        "security_finding",
        "2026-07-14T00:00:00Z",
        finding_id="finding-2",
        severity="low",
    ),
    event("test-1", "test_run", "2026-07-15T00:00:00Z", run_id="test-1", flaky=True),
    event("test-2", "test_run", "2026-07-16T00:00:00Z", run_id="test-2", flaky=False),
    event("slo-1", "slo", "2026-07-17T00:00:00Z", indicator="availability", value=0.99),
    event(
        "evidence-1",
        "evidence",
        "2026-07-18T00:00:00Z",
        change_id="change-1",
        complete=True,
    ),
    event(
        "evidence-2",
        "evidence",
        "2026-07-18T00:01:00Z",
        change_id="change-2",
        complete=True,
    ),
    event(
        "review-1",
        "review",
        "2026-07-19T00:00:00Z",
        change_id="change-1",
        accepted_without_change=True,
        cycles=1,
    ),
    event(
        "review-2",
        "review",
        "2026-07-19T00:01:00Z",
        change_id="change-2",
        accepted_without_change=False,
        cycles=1,
    ),
    event("rework-1", "rework", "2026-07-19T01:00:00Z", change_id="change-2"),
    event(
        "scope-1", "scope", "2026-07-20T00:00:00Z", change_id="change-1", drift=False
    ),
    event("scope-2", "scope", "2026-07-20T00:01:00Z", change_id="change-2", drift=True),
    event(
        "validation-1",
        "validation",
        "2026-07-21T00:00:00Z",
        change_id="change-1",
        passed=True,
    ),
    event(
        "validation-2",
        "validation",
        "2026-07-21T00:01:00Z",
        change_id="change-2",
        passed=True,
    ),
    event(
        "policy-1",
        "policy_violation",
        "2026-07-21T01:00:00Z",
        change_id="change-1",
        confirmed=False,
    ),
    event(
        "time-1",
        "time_measurement",
        "2026-07-22T00:00:00Z",
        change_id="change-1",
        seconds_delta=2,
        method="declared-before-after-sample",
    ),
    event(
        "time-2",
        "time_measurement",
        "2026-07-22T00:01:00Z",
        change_id="change-2",
        seconds_delta=2,
        method="declared-before-after-sample",
    ),
]
for phase in range(8):
    events.append(
        event(
            f"phase-{phase}-outcome",
            "phase_measurement",
            "2026-07-23T00:00:00Z",
            metric_id=f"phase{phase}_outcome",
            value=1.0,
        )
    )
    events.append(
        event(
            f"phase-{phase}-leading",
            "phase_measurement",
            "2026-07-23T00:01:00Z",
            metric_id=f"phase{phase}_leading_indicator",
            value=1.0,
        )
    )

events_path = Path(".sdlc/evidence/measurement-events.jsonl")
events_path.parent.mkdir(parents=True, exist_ok=True)
events_path.write_text(
    "".join(json.dumps(item, sort_keys=True) + "\n" for item in events),
    encoding="utf-8",
)

metrics = []
for metric_id in metric_ids:
    catalog_metric = catalog_by_id[metric_id]
    source_ids = {
        "event_ids": [f"{metric_id}-event"],
        "deployment_ids": (
            ["deployment-1"]
            if metric_id in {"lead_time", "change_failure_rate", "rollback_rate"}
            else []
        ),
        "change_ids": ["change-1"] if metric_id == "lead_time" else [],
        "incident_ids": ["incident-1"] if metric_id == "recovery_time" else [],
    }
    metrics.append(
        {
            "id": metric_id,
            "definition": catalog_metric["name"],
            "formula": catalog_metric["formula"],
            "value": baseline_values[metric_id],
            "baseline_value": baseline_values[metric_id],
            "numerator": 1.0,
            "denominator": 1.0,
            "unit": catalog_metric["unit"],
            "owner": "measurement-owner",
            "source": catalog_metric["event_source"],
            "source_ids": source_ids,
            "retention_days": 365,
            "privacy_review": "APPROVED",
        }
    )
snapshot = {
    "schema": 1,
    "kind": "sdlc-measurement-snapshot",
    "model": "dora-ai-v1",
    "model_version": "dora-ai-v1",
    "period": {"start": "2026-07-01", "end": "2026-09-30"},
    "captured_at": "2026-09-30T12:00:00Z",
    "owner": "measurement-owner",
    "cohort": {"name": "all-services", "field": "service_id"},
    "privacy_review": "APPROVED",
    "completeness": {
        "status": "COMPLETE",
        "score": 1.0,
        "missing_event_types": [],
        "late_event_count": 0,
    },
    "metrics": metrics,
    "improvements": [
        {
            "id": "IMPROVEMENT-001",
            "observed_effect": "Validation pass rate improved.",
            "regression": "No regression observed.",
            "evidence": "docs/continuous-improvement-log.md",
            "accepted": True,
        }
    ],
    "review": {
        "status": "APPROVED",
        "completed_improvements": 1,
        "regressions_reviewed": True,
        "next_prioritized_roadmap": ["Improve escaped-defect measurement."],
    },
}
snapshot_path = Path(".sdlc/evidence/measurement-snapshot.json")
snapshot_path.parent.mkdir(parents=True, exist_ok=True)
snapshot_path.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
