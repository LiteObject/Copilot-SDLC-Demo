---
description: "Risk-based security design, scan, triage, and regression standards."
applyTo: "**"
---
# Security Standards

## Before Coding

The Architect records the risk profile, trust boundaries, external inputs,
authentication and authorization changes, data stores, command/file operations,
secrets, APIs, and infrastructure impacts in the **Security Design Review**
section of `docs/spec.md` when `security.review_required: true` or the change
handles a high-risk capability.

## Scan Policy

Configure applicable named security tasks in `.github/sdlc-config.yml`:
`sast`, `secrets`, `dependency_audit`, `license_audit`, `container_scan`,
`iac_scan`, `dast`, and `security_tests`. Run
`scripts/run-security-scans.ps1` or `.sh`; do not paste arbitrary scanner
commands into the spec or CI workflow.

Critical and high findings block the transition unless the finding has a
traceable exception with an owner, due date, rationale, approver, and retained
evidence. Medium, low, and informational findings still require a disposition
when they are not fixed.

## Regression Expectations

For changes involving external input, authentication, authorization, commands,
file paths, deserialization, secrets, APIs, or sensitive data, add negative
regression coverage for rejection, unauthorized access, malformed input, error
handling, and sensitive-data exposure as applicable. Map each test to an
acceptance criterion in `docs/spec.md`.
