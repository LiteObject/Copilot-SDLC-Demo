---
description: "Blast-radius checker for implementation work. Declare allowed files before coding, then verify no cross-domain contamination after. Use during REVIEW or before committing."
applyTo: "src/**"
---
# Scope Audit — Declare → Implement → Verify

Enforce the rule: **implement the plan, don't touch files outside it.**

## When to Use

- Before the Developer starts implementing (declare allowed scope).
- During REVIEW, after the Developer marks files done (verify actual footprint).
- As a gate before merging — catch cross-domain contamination before it ships.

## Workflow

### Step 1 — Declare Scope (Developer, before coding)

Before writing any code, the Developer reads the **Implementation Plan** in `docs/spec.md` and records the exact list of planned files. These become the **allowed file set**. Any file NOT in this set is off-limits unless the Architect updates the plan.

### Step 2 — Implement (Developer)

The Developer creates/modifies ONLY files in the allowed set. If implementation reveals that a file outside the set must change:
- **Stop** and flag it to the Supervisor.
- The Supervisor routes to the Architect to update the plan.
- Resume only after the plan is updated.

### Step 3 — Verify (Reviewer, during REVIEW)

The Reviewer runs the scope-audit script, which compares the actual git diff against the allowed file set:

```bash
# Check uncommitted changes against the plan
./scripts/scope-audit.sh

# Or on Windows:
./scripts/scope-audit.ps1

# Check a branch against main:
./scripts/scope-audit.sh origin/main

# Check only staged changes:
./scripts/scope-audit.sh staged
```

The script produces a machine-readable report with three categories:
- `[IN_SCOPE]` — changed files that appear in the plan → OK.
- `[SCOPE_CREEP]` — changed files NOT in the plan → flag in review findings.
- `[MISSING]` — planned files NOT created → flag in review findings.

It also emits a JSON summary for programmatic consumers. The Reviewer must run this script (not manually reason about `git diff` output) and report its results verbatim.

### Decision Rules

| Finding | Action |
|---------|--------|
| All changes within planned files | Scope check passes |
| Extra files touched | Reviewer flags `[SCOPE CREEP]` → routes to Developer to revert or Architect to update plan |
| Planned file not implemented | Reviewer flags `[MISSING]` → routes to Developer to implement |

### What Counts as "In Scope"

- Files explicitly listed in the Implementation Plan's file structure.
- Test files under `tests/` that correspond to planned source files (tests are always in scope for the QA phase).
- Configuration files that the plan says must change (e.g., `package.json` for new dependencies).

### What is Out of Scope (flag it)

- Refactoring of unrelated files ("while I was in there…").
- Whitespace or formatting changes to files not in the plan.
- New utility/helper files not documented in the plan.
- Changes to CI/CD, Docker, or infrastructure files not in the plan.
