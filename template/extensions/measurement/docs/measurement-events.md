# Measurement Event Contract

The installed event schema is `docs/measurement-events.json`, and the
configured event stream is an append-only JSONL file at
`measurement.events_path`. Every record uses the `dora-ai-v1` model and
contains only aggregate delivery, quality, reliability, or AI outcome data.

## Common Fields

Each event has `event_id`, `event_type`, `model`, `event_time` with an explicit
UTC offset, `repository_id`, and `service_id`. Event-specific identifiers are
`change_id`, `deployment_id`, `incident_id`, `feature_id`, or `metric_id` as
appropriate. Do not add prompts, model inputs, source code, credentials,
personal data, or free-form user content.

## Joins and Windows

- A change joins to a deployment by `change_id`; lead time is the successful
  production deployment `completed_at` minus the joined change's
  `first_commit_at`.
- A deployment joins to rollback, hotfix, failed-release, and production-impact
  incident records by `deployment_id`. Change failure uses the configured
  `change_failure_window_days` after deployment completion.
- Restore time uses `detected_at` to `restored_at` on a production-impacting
  incident and subtracts declared `paused_seconds`.
- Evidence, review, rework, scope, validation, and time records join to a
  change by `change_id`. Phase and AI product records join to a metric by
  `metric_id`.
- Time-saved-or-added records carry the configured `time_measurement_method`;
  an event without the declared method is invalid.
- All reporting periods are inclusive calendar dates interpreted in UTC. An
  event with an offset is normalized to UTC before boundary comparison.

The report generator counts a `deployment_id` once and excludes records marked
`is_retry: true`. It records late events outside the reporting period in
`completeness.late_event_count`; it never silently moves them into the period.
Missing event types, missing fields, duplicate event IDs, and zero denominators
make the report incomplete and are retained in validation evidence.

## Retention and Privacy

Retain identifiers only long enough to reproduce the aggregate snapshot, then
apply the configured retention period. Reports link to retained event and
snapshot evidence but do not copy raw event payloads. The event validator
rejects privacy-sensitive field names before aggregation.