# Project Spec

> Single source of truth for the SDLC workflow. Agents read and update this file as work progresses.

## Current State

`GATHERING_REQS`

<!-- One of: GATHERING_REQS | DESIGN | PLANNING | CODING | REVIEW | TESTING | DEPLOYMENT_READINESS | DONE -->

## Review Cycle

`0`

<!-- Hard cap: 3. Incremented by the Supervisor each time Reviewer requests changes. Reset to 0 on approval. At 3, escalate to the user instead of looping again. -->

---

## Goal

_(PM fills this in — one or two sentences describing what we're building.)_

## Requirements

_(PM — numbered, each independently verifiable.)_

1.

## Acceptance Criteria

_(PM — observable conditions that define "done".)_

- [ ]

## Out of Scope

_(PM — explicit non-goals.)_

-

---

## Design

_(Designer — frontend/UI projects only. Screens & flows, screen states (empty/loading/error/success), layout & components, design tokens, accessibility target. Skip for non-UI projects.)_

---

## Tech Stack

_(Architect — languages, frameworks, key libraries, test framework + command.)_

## File Structure

_(Architect — the tree of files to create under src/ and tests/.)_

```
src/
tests/
```

## Implementation Plan

_(Architect — ordered files/modules, each mapped to the requirement(s) it satisfies. Developer checks items off.)_

- [ ]

---

## Review Findings

_(Reviewer — verdict (Approved / Changes requested) and any actionable findings: file, issue, suggested fix.)_

---

## Test Results

_(QA — latest test command, pass/fail counts, and any failures with error output.)_

---

## Deployment Readiness

_(Reviewer — optional pre-deployment gate. Checklist results per `.github/instructions/deployment-readiness.instructions.md`: build, tests, secrets, config, deps, cleanup. All must PASS before DONE.)_

| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | Build   | ⬜ | |
| 2 | Tests   | ⬜ | |
| 3 | Secrets | ⬜ | |
| 4 | Config  | ⬜ | |
| 5 | Deps    | ⬜ | |
| 6 | Cleanup | ⬜ | |
