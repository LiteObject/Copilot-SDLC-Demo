# Operational Readiness Review

Complete this review before production promotion and repeat it after material
architecture, dependency, data, or traffic changes.

## Service Ownership

| Item | Value |
|---|---|
| Service | |
| Owner | |
| On-call / escalation | |
| Health endpoint | |
| Dependencies | |

## Signals and Objectives

| SLI | Formula and source | Objective | Alert / escalation | Runbook |
|---|---|---|---|---|
| Availability | | | | |
| Latency | | | | |
| Error rate | | | | |
| Throughput | | | | |
| Critical business outcome | | | | |

Confirm that structured logs, metrics, distributed traces, and correlation
identifiers are present in the deployed service and visible to the on-call
team. Record links to dashboards and example trace or request identifiers in
the release evidence, without including sensitive values.

## Reliability Review

| Review item | Evidence | Owner | Status |
|---|---|---|---|
| Capacity and scaling | | | NOT_STARTED |
| Backup and recovery | | | NOT_STARTED |
| Dependency failure handling | | | NOT_STARTED |
| Data retention | | | NOT_STARTED |
| Privacy and data access | | | NOT_STARTED |
| Disaster recovery | | | NOT_STARTED |

## Rollout Decision

- [ ] Readiness validation passed.
- [ ] Staging failure drill demonstrated alerting, diagnosis, and rollback.
- [ ] Release-specific health and business outcome checks are defined.
- [ ] On-call and escalation ownership were acknowledged.

Decision: `NOT_READY`

Decision owner: 

Decision date: 

Evidence links: 
