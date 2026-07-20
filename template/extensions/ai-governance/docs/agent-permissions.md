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

## Restricted Actions

Commit, merge, deploy, credential rotation, and production configuration changes
are restricted actions. Agents may prepare a change or command for review but
must not perform it without a recorded human approval.

Sandbox type: `worktree`

Sandbox required: `true`

Command confirmation required: `true`
