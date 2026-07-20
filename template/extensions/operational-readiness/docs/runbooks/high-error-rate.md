# Runbook: High Error Rate

1. Confirm the alert window, affected endpoint, environment, and correlation
   identifiers.
2. Compare error rate, latency, traffic, dependency health, and the latest
   release marker.
3. Inspect a representative trace and structured log without copying sensitive
   payloads into the incident record.
4. Mitigate with the smallest reversible action: pause rollout, disable the
   risky feature, or route traffic to the last known good version.
5. Verify recovery with the health check and the error-budget dashboard.
6. Record the incident timeline and open corrective actions.
