# Runbook: Degraded Dependency

1. Identify the failing dependency, affected operations, timeout rate, and
   retry volume.
2. Confirm whether the dependency failure is partial, regional, or total.
3. Enable the documented fallback, queueing, circuit breaker, or read-only
   path. Do not increase retries without checking load and recovery behavior.
4. Notify the dependency owner through the escalation policy.
5. Verify that user-visible impact and recovery are reflected in the service
   objectives and business outcome metrics.
6. Capture dependency failure evidence and a follow-up action.
