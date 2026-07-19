---
description: "Run the test suite and fix failures by looping QA and Developer through the SDLC Supervisor."
name: "Fix Failing Tests"
agent: "sdlc-supervisor"
argument-hint: "Optional: paste an error or name the failing area"
---
Drive the test-and-fix loop.

1. Set "Current State: TESTING" in [docs/spec.md](../../docs/spec.md).
2. Delegate to QA to run the test suite and report failures verbatim.
3. For each failure, delegate the patch to the Developer, then have QA re-run.
4. Repeat until the suite passes, then set state to DONE and summarize.

Context (optional): ${input:context}
