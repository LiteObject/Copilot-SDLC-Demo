# Measurement Snapshot Schema

The configured `snapshot_path` contains one aggregate measurement report. The
snapshot task must emit JSON with this shape:

```json
{
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
    "late_event_count": 0
  },
  "metrics": [
    {
      "id": "lead_time",
      "definition": "Time from first commit to successful production completion",
      "formula": {"operation": "average_duration", "unit": "seconds", "numerator": {}, "denominator": {}},
      "value": 3.2,
      "baseline_value": 4.1,
      "numerator": 3.2,
      "denominator": 1,
      "unit": "seconds",
      "owner": "measurement-owner",
      "source": "delivery-system",
      "source_ids": {"event_ids": ["event-123"], "deployment_ids": ["deployment-123"], "change_ids": ["change-123"], "incident_ids": []},
      "retention_days": 365,
      "privacy_review": "APPROVED"
    }
  ],
  "improvements": [
    {
      "id": "IMPROVEMENT-001",
      "observed_effect": "Validation pass rate improved",
      "regression": "No regression observed",
      "evidence": "docs/continuous-improvement-log.md",
      "accepted": true
    }
  ],
  "review": {
    "status": "APPROVED",
    "completed_improvements": 1,
    "regressions_reviewed": true,
    "next_prioritized_roadmap": ["Improve escaped-defect measurement"]
  }
}
```

Every configured baseline, delivery, roadmap outcome, and roadmap leading
indicator metric must occur exactly once. AI-product metrics are required only
when `ai_product_metrics_applicable` is `true`. Values and baseline values are
numeric, as are each metric's numerator and positive denominator. The formula
and unit must match `measurement-catalog.json`, and `model_version`, cohort,
completeness, owner, and privacy review are required. Do not include raw
prompts, user content, secrets, credentials, or unnecessary personal or
sensitive data.