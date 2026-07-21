# Measurement Snapshot Schema

The configured `snapshot_path` contains one aggregate measurement report. The
snapshot task must emit JSON with this shape:

```json
{
  "schema": 1,
  "kind": "sdlc-measurement-snapshot",
  "period": {"start": "2026-07-01", "end": "2026-09-30"},
  "captured_at": "2026-09-30T12:00:00Z",
  "owner": "measurement-owner",
  "metrics": [
    {
      "id": "lead_time",
      "definition": "Time from approved work to completion",
      "value": 3.2,
      "baseline_value": 4.1,
      "unit": "days",
      "owner": "measurement-owner",
      "source": "delivery-system",
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
numeric; do not include raw prompts, user content, secrets, credentials, or
unnecessary personal or sensitive data.