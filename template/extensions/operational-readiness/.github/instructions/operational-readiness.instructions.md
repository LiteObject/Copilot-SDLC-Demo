---
description: "Operational readiness, observability, reliability, incident response, and production feedback controls."
applyTo: "**"
---
# Operational Readiness

Use this extension for services that run in production. Set
`operational_readiness.enabled: true` only after the service owner, on-call
path, health endpoint, telemetry, service objectives, review documents,
runbooks, and operational tasks are configured.

## Required Service Signals

- Emit structured logs with severity, service, environment, timestamp, and a
  correlation identifier. Never put credentials or sensitive payloads in logs.
- Publish metrics for availability, latency, error rate, throughput, and the
  critical business outcome selected by the product owner.
- Propagate correlation identifiers across HTTP, queue, database, and worker
  boundaries. Preserve distributed trace context when a tracing system is in
  use.
- Expose a health endpoint that distinguishes process health from dependency
  readiness. Do not expose secrets, stack traces, or unrestricted diagnostics.

## Objectives and Alerts

Document the SLI formula, target, measurement window, alert threshold,
notification route, escalation owner, and error-budget action for each SLI.
Alerts should be actionable, deduplicated, and linked to a runbook. An alert
without an owner or a diagnostic path is not an operational control.

## Readiness Review

Before production promotion, review capacity, backup and recovery, dependency
failure behavior, data retention, privacy, and disaster recovery. Record the
decision and evidence in the configured readiness review document. Verify the
service owner and on-call path during every material change.

## Incidents and Learning

Use the configured severity levels and incident roles. Communicate impact,
scope, mitigation, and the next update time. Keep a blameless review with a
timeline, contributing factors, corrective actions, owners, due dates, and
links back to requirements or planning work. Record both technical health and
the intended product outcome after release; a technically healthy deployment
is not complete if it does not achieve the intended outcome.

Run the staging failure drill before enabling a new production path. The drill
must demonstrate alerting, diagnosis, rollback, and evidence capture using the
published runbooks.
