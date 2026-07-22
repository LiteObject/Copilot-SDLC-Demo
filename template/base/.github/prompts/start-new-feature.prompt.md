---
description: "Kick off a new feature through the full SDLC loop with the SDLC Supervisor."
name: "Start New Feature"
agent: "sdlc-supervisor"
argument-hint: "Describe the feature or app to build"
---
Start a new feature using the full SDLC workflow.

1. Ask the SDLC Supervisor to select a normalized feature ID from the request or branch context. For feature-scoped work, initialize `docs/specs/<feature-id>/spec.md`; otherwise preserve the legacy [docs/spec.md](../../docs/spec.md). Use the versioned workflow metadata and `current_phase: GATHERING_REQS`.
2. Delegate to the PM to gather and clarify requirements before any planning or coding.
3. Proceed through PLANNING → CODING → REVIEW → TESTING, updating gate evidence and applying transitions only through the Supervisor validator.
4. Do not write code until requirements are clear and a plan exists.

Feature request: ${input:feature}
