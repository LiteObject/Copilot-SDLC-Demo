---
description: "Testing standards. Use when writing or editing tests under tests/."
applyTo: "tests/**"
---
# Testing Standards

- One behavior per test; use descriptive test names that state the expectation.
- Select test layers in the **Test Strategy** section based on risk: unit,
	integration, contract/API, browser/end-to-end, accessibility, performance,
	resilience, fuzz, and property-based tests.
- Cover the happy path plus edge cases, error conditions, and negative security
	behavior for each applicable requirement.
- Map every acceptance criterion to an automated test or an owned manual
	verification with evidence in **Acceptance Test Mapping**.
- When `verification.coverage_enabled` is true, run the named `coverage` task
	and inspect `.sdlc/evidence/coverage.json`; a pasted percentage is not
	evidence. Coverage is changed-line evidence and never replaces the
	configured behavioral, integration, accessibility, performance, or security
	test layers.
- When mutation verification is enabled, inspect `.sdlc/evidence/mutation.json`
	for the tool version, score, survivors, exclusions, and disposition of every
	surviving mutant.
- Tests must be deterministic — no reliance on network, wall-clock time, or test order.
- Never weaken or delete a test just to make the suite pass; fix the code instead.
