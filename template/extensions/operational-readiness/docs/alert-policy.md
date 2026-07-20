# Alert Policy

Every production alert must identify the service, signal, threshold, window,
owner, escalation route, and linked runbook. Prefer multi-window, symptom-based
alerts over noisy low-level alarms.

| Signal | Warning | Critical | Owner | Runbook |
|---|---|---|---|---|
| Availability | | | | |
| Latency | | | | |
| Error rate | | | | |
| Throughput | | | | |
| Business outcome | | | | |

Document how alerts consume the error budget, how duplicates are grouped, and
when an alert is silenced. A silence must have an expiry and an owner.
