---
description: "Run the test suite and fix failures by looping QA and Developer through the SDLC Supervisor."
name: "Fix Failing Tests"
agent: "sdlc-supervisor"
argument-hint: "Optional: paste an error or name the failing area"
---
Drive the test-and-fix loop.

1. Ask the SDLC Supervisor to resolve the feature context and validate the current `TESTING` state in the selected feature spec, or in [docs/spec.md](../../docs/spec.md) for legacy mode; do not set workflow metadata directly.
2. Delegate to QA to run the test suite and report failures verbatim.
3. For each failure, delegate the patch to the Developer, then have QA re-run.
4. Repeat until the suite passes, then return the test gate evidence to the Supervisor. The Supervisor validates `DEPLOYMENT_READINESS` or `DONE` according to the enabled gate.

Context (optional): ${input:context}
