# Runbook: Emergency Feature Disablement

1. Confirm the risky feature, affected users, incident reference, and approval
   authority.
2. Use the documented feature-control path; do not edit production data or
   configuration by hand when a controlled switch exists.
3. Verify the feature is disabled in each affected environment and that the
   fallback path is healthy.
4. Monitor error rate, latency, availability, throughput, and business outcome
   signals during recovery.
5. Communicate the change and next decision time through the escalation policy.
6. Record the cause, duration, rollback or re-enable criteria, and follow-up
   work in the post-incident review.
