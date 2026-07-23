# Agent Permissions and Trust Boundaries

The YAML configuration is the machine-readable allowlist. This document
explains how each grant is used and who may approve a wider boundary.

## Global Allowlists

| Boundary | Allowed entries | Owner |
|---|---|---|
| Tools | | |
| MCP servers | | |
| Network destinations | | |
| Credential scopes | | |

An empty MCP, network, or credential list means no external connection or
credential scope is allowed.

## Phase Grants

| Phase | Tools | Read-only? | Approval needed to widen |
|---|---|---|---|
| Requirements and design | | | Yes |
| Planning | | | Yes |
| Coding | | | Yes |
| Review | | | Yes |
| Testing | | | Yes |
| Deployment readiness | | | Yes |

Use the least privilege required by the current phase. A grant in one phase
does not carry forward automatically.

## Autonomy Policy

`ai_governance.autonomy_level` selects the maximum graduated level. The policy
must also declare `policy_version`, `policy_expires_at`, `max_iterations`,
`max_changed_files`, `allowed_branches`, `action_classes`,
`approval_requirements`, and `approval_expiration_hours`. An absent or invalid
policy is fail-closed and permits only L0 read, analyze, and propose actions.

Run `scripts/check-autonomy.ps1` or `scripts/check-autonomy.sh` before edits,
commands, network access, and branch or pull-request handoffs. Keep the JSONL
decision evidence with the selected feature evidence directory. The decision
ID and approval ID must be passed to the AI change ledger.

## Restricted Actions

Commit, merge, deploy, credential rotation, and production configuration changes
are restricted actions. Agents may prepare a change or command for review but
must not perform it without a recorded human approval.

Sandbox type: `worktree`

Sandbox required: `true`

Command confirmation required: `true`

## Approval Record

Store approvals as machine-readable records with these fields:

`approval_id`, `approver`, `action`, `scope`, `policy_version`, `timestamp`,
`expiration`, `decision`, and `evidence`.

The scope must identify the applicable feature, phase, branch, and changed-file
patterns when those boundaries apply. An approval outside its scope or after
its expiration is invalid.
