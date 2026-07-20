# Runbook: Secret Rotation

1. Identify the credential, owning service, consumers, expiry, and rotation
   authority without putting the secret value in logs or tickets.
2. Create the replacement in the approved secret manager and verify access
   policy and audit logging.
3. Roll consumers to the replacement using a reversible overlap window when
   supported.
4. Run health and dependency checks, then revoke the old credential.
5. Confirm that no configuration, logs, artifacts, or incident records contain
   the secret value.
6. Record the rotation reference and next expiry review.
