---
description: "Testing standards. Use when writing or editing tests under tests/."
applyTo: "tests/**"
---
# Testing Standards

- One behavior per test; use descriptive test names that state the expectation.
- Cover the happy path plus edge cases and error conditions for each requirement.
- Map each test (or test group) to an Acceptance Criterion in docs/spec.md.
- Tests must be deterministic — no reliance on network, wall-clock time, or test order.
- Never weaken or delete a test just to make the suite pass; fix the code instead.
