# Incident Response and Post-Incident Review

## Roles

| Role | Responsibility | Named owner |
|---|---|---|
| Incident commander | Owns severity, priorities, and the response timeline. | |
| Operations lead | Coordinates diagnosis, mitigation, rollback, and recovery. | |
| Communications lead | Shares impact, status, and next update times. | |
| Scribe | Maintains the timeline, evidence, decisions, and action items. | |

## Severity

| Severity | Meaning | Initial response | Update cadence |
|---|---|---|---|
| SEV1 | Broad outage, data loss, or immediate safety/security impact. | Page the incident commander and service owner. | Every 30 minutes or sooner. |
| SEV2 | Material degradation or a major customer workflow unavailable. | Page the on-call owner and notify the service owner. | Every 60 minutes. |
| SEV3 | Limited impact with a workaround or contained degradation. | Assign an owner during business hours. | At agreed checkpoints. |
| SEV4 | Minor defect, question, or non-urgent operational task. | Track in normal planning. | At closure. |

## Response Record

Record the incident reference, severity, impact, affected users, start and end
times, detection source, mitigation, rollback decision, communications, and
evidence links. Keep credentials, tokens, and unnecessary personal data out of
the record.

## Blameless Review

Within the configured review window, capture:

- a factual timeline and contributing conditions;
- what detection and runbooks did or did not make possible;
- the customer and business outcome;
- corrective actions with an owner, due date, priority, and linked requirement
  or planning item;
- the reviewer and closure decision.

Do not frame corrective actions as individual blame. Track them to completion
and feed recurring defects, alerts, and user feedback into the next planning
cycle.
