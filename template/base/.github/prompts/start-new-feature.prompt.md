---
description: "Kick off a new feature through the full SDLC loop with the SDLC Supervisor."
name: "Start New Feature"
agent: "sdlc-supervisor"
argument-hint: "Describe the feature or app to build"
---
Start a new feature using the full SDLC workflow.

1. Initialize or update [docs/spec.md](../../docs/spec.md) with "Current State: GATHERING_REQS".
2. Delegate to the PM to gather and clarify requirements before any planning or coding.
3. Proceed through PLANNING → CODING → REVIEW → TESTING, updating docs/spec.md after each phase.
4. Do not write code until requirements are clear and a plan exists.

Feature request: ${input:feature}
