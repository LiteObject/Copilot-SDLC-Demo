---
sdlc_schema: 1
current_phase: GATHERING_REQS
design_required: false
deployment_readiness_enabled: false
security_gate_enabled: false
review_cycle: 0
revision_commit_sha: ""
revision_tree_digest: ""
last_transition_from: ""
last_transition_to: GATHERING_REQS
last_transition_timestamp: ""
last_transition_actor: ""
last_transition_evidence: ""
planned_files: []
approved_globs: []
gate_requirements_command: ""
gate_requirements_commit_sha: ""
gate_requirements_tree_digest: ""
gate_requirements_timestamp: ""
gate_requirements_exit_code: ""
gate_requirements_result: NOT_RUN
gate_requirements_evidence: ""
gate_config_command: ""
gate_config_commit_sha: ""
gate_config_tree_digest: ""
gate_config_timestamp: ""
gate_config_exit_code: ""
gate_config_result: NOT_RUN
gate_config_evidence: ""
gate_install_command: ""
gate_install_commit_sha: ""
gate_install_tree_digest: ""
gate_install_timestamp: ""
gate_install_exit_code: ""
gate_install_result: NOT_RUN
gate_install_evidence: ""
gate_design_command: ""
gate_design_commit_sha: ""
gate_design_tree_digest: ""
gate_design_timestamp: ""
gate_design_exit_code: ""
gate_design_result: NOT_RUN
gate_design_evidence: ""
gate_planning_command: ""
gate_planning_commit_sha: ""
gate_planning_tree_digest: ""
gate_planning_timestamp: ""
gate_planning_exit_code: ""
gate_planning_result: NOT_RUN
gate_planning_evidence: ""
gate_build_command: ""
gate_build_commit_sha: ""
gate_build_tree_digest: ""
gate_build_timestamp: ""
gate_build_exit_code: ""
gate_build_result: NOT_RUN
gate_build_evidence: ""
gate_security_command: ""
gate_security_commit_sha: ""
gate_security_tree_digest: ""
gate_security_timestamp: ""
gate_security_exit_code: ""
gate_security_result: NOT_RUN
gate_security_evidence: ""
gate_review_command: ""
gate_review_commit_sha: ""
gate_review_tree_digest: ""
gate_review_timestamp: ""
gate_review_exit_code: ""
gate_review_result: NOT_RUN
gate_review_evidence: ""
gate_test_command: ""
gate_test_commit_sha: ""
gate_test_tree_digest: ""
gate_test_timestamp: ""
gate_test_exit_code: ""
gate_test_result: NOT_RUN
gate_test_evidence: ""
gate_lint_command: ""
gate_lint_commit_sha: ""
gate_lint_tree_digest: ""
gate_lint_timestamp: ""
gate_lint_exit_code: ""
gate_lint_result: NOT_RUN
gate_lint_evidence: ""
gate_type_check_command: ""
gate_type_check_commit_sha: ""
gate_type_check_tree_digest: ""
gate_type_check_timestamp: ""
gate_type_check_exit_code: ""
gate_type_check_result: NOT_RUN
gate_type_check_evidence: ""
gate_deployment_readiness_command: ""
gate_deployment_readiness_commit_sha: ""
gate_deployment_readiness_tree_digest: ""
gate_deployment_readiness_timestamp: ""
gate_deployment_readiness_exit_code: ""
gate_deployment_readiness_result: NOT_RUN
gate_deployment_readiness_evidence: ""
---

# Project Spec

> Single source of truth for the SDLC workflow. Agents read and update this file as work progresses.

The YAML front matter is the authoritative workflow record. Keep the visible
`Current State` and `Review Cycle` values synchronized with `current_phase` and
`review_cycle`. Only the Supervisor applies state transitions after the phase
validator passes. Gate records use `PASS`, `FAIL`, or `CHANGES_REQUESTED` and
must include the command, revision, timestamp, exit code, and evidence path.
`planned_files` contains exact repository-relative files; directory entries are
invalid. A glob requires a matching `approved_globs` record in the form
`pattern|justification|approver|revision_commit_sha|timestamp`.

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
