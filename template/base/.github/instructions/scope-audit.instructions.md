---
description: "Blast-radius checker for implementation work. Declare allowed files before coding, then verify no cross-domain contamination after. Use during REVIEW or before committing."
applyTo: "src/**"
---
# Scope Audit - Declare -> Implement -> Verify

Enforce the rule: **implement the plan; do not touch files outside it.** The
machine-readable `planned_files` list in the YAML front matter of
`docs/spec.md` is authoritative. The visible File Structure section is useful
for people but is not the scope input to the audit script.

For feature-scoped work, the authoritative file is
`docs/specs/<feature-id>/spec.md`. Resolve the feature before reading the plan
and run the audit with `--feature-id <feature-id>` or `-FeatureId <feature-id>`.
The audit excludes only that feature's spec and evidence namespace; another
feature's spec is a changed product file and is reported as scope creep.
Known shared surfaces require an exact `approved_shared_files` record in the
feature spec using `path|justification|approver|revision_commit_sha|timestamp`.
The audit reports approved shared changes as `[SHARED_SCOPE]` and same-file
claims by another feature as `[CONFLICT]`.
When `docs/specs/<feature-id>/tasks.json` exists, the effective planned scope
also includes the union of every task's exact `planned_files`. The task graph
validator is the source for that union; the scope audit remains the final
check for changed files, missing files, shared approvals, and conflicts.

## When to Use

- Before the Developer starts implementing (declare allowed scope).
- During REVIEW, after the Developer marks files done (verify actual footprint).
- As a gate before merging — catch cross-domain contamination before it ships.

## Workflow

### Step 1 — Declare Scope (Developer, before coding)

Before writing any code, the Developer reads the **Implementation Plan** in
`docs/spec.md` and records exact repository-relative paths under
`planned_files`. Directory entries such as `src/` are invalid. Any file NOT in
this set is off-limits unless the Architect updates the plan.

Glob patterns are exceptional. A matching `approved_globs` entry must contain
five pipe-separated fields:

```text
pattern|justification|approver|revision_commit_sha|timestamp
```

The pattern must match a `planned_files` entry, every field must be non-empty,
and the revision must match `revision_commit_sha` when that field is present.

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

# Check one feature on Windows:
./scripts/scope-audit.ps1 -FeatureId checkout-flow

# Check one feature on Bash:
./scripts/scope-audit.sh --feature-id checkout-flow

# Check a branch against main:
./scripts/scope-audit.sh origin/main

# Check only staged changes:
./scripts/scope-audit.sh staged
```

The script produces a machine-readable report with these categories:
- `[IN_SCOPE]` — changed files that appear in the plan → OK.
- `[SCOPE_CREEP]` — changed files NOT in the plan → flag in review findings.
- `[MISSING]` — planned files NOT created → flag in review findings.
- `[WORKFLOW]` — `docs/spec.md` state/evidence and `.sdlc/` generated evidence changes excluded from product scope.
- `[PLAN_INVALID]` — directory entries, malformed paths, or unapproved globs.

It also emits a JSON summary for programmatic consumers. The Reviewer must run this script (not manually reason about `git diff` output) and report its results verbatim.

### Decision Rules

| Finding | Action |
|---------|--------|
| All changes within planned files | Scope check passes |
| Extra files touched | Reviewer flags `[SCOPE CREEP]` -> routes to Developer to revert or Architect to update the plan |
| Planned file not implemented | Reviewer flags `[MISSING]` -> routes to Developer to implement |
| Directory entry or unapproved glob | Reviewer flags `[PLAN_INVALID]` -> Architect records exact paths or approved evidence |

### What Counts as "In Scope"

- Files explicitly listed in front matter `planned_files`.
- Approved glob matches with a complete `approved_globs` record.
- Configuration files that the plan says must change (e.g., `package.json` for new dependencies).

### What is Out of Scope (flag it)

- Refactoring of unrelated files ("while I was in there...").
- Whitespace or formatting changes to files not in the plan.
- New utility/helper files not documented in the plan.
- Changes to CI/CD, Docker, or infrastructure files not in the plan.

`docs/spec.md` and `.sdlc/` are workflow-managed and reported separately. They must still be
reviewed for unauthorized requirement, plan, or evidence changes; excluding it
from product scope does not make those edits automatically valid.
