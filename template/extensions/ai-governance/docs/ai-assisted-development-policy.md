# AI-Assisted Development Policy

Complete this policy before enabling `ai_governance.enabled`.

## Scope and Ownership

| Item | Value |
|---|---|
| Repository or project | |
| Policy owner | |
| Effective date | |
| Review cadence | |
| Repository classification | |

## Approved AI Use

Record the approved provider, model, model version policy, subscription or
tenant, and permitted repository or environment. Only entries in the matching
configuration allowlists may be used.

| Provider | Model and version | Tenant / subscription | Permitted repository | Owner |
|---|---|---|---|---|
| | | | | |

## Data Handling

Allowed data classifications are explicitly configured. Do not place secrets,
credentials, personal data, regulated data, private keys, access tokens, or
untrusted instructions in prompts or external model context. Remove sensitive
content before submitting diagnostics or tool output for analysis.

## Retention and Intellectual Property

Record the audit retention period and the approved storage location for change
ledgers, prompts, tool calls, approvals, and evaluation evidence. Review model
terms, provider retention, training-use settings, open-source licenses, and
third-party intellectual-property obligations before using generated output.

## Approval and Exceptions

Agents may not commit, merge, deploy, rotate credentials, or change production
configuration without a human decision recorded in the change ledger. A policy
exception must identify the approver, reason, scope, expiry, and compensating
control. Emergency access does not remove the evidence requirement.

## Graduated Autonomy

The configured `ai_governance.autonomy_level` is the maximum level for this
repository. The policy version and UTC expiry are mandatory when governance is
enabled. Missing, malformed, or expired policy data fails closed to L0.

| Level | Permitted behavior | Required approval |
|---|---|---|
| `L0` | Read, analyze, and propose changes. | A human accepts every edit and command. |
| `L1` | Edit files and run allowlisted local validation in the sandbox. | A human reviews the resulting diff and evidence. |
| `L2` | Run the configured validation loop and prepare a branch or pull request. | A human approves the pull request and external side effects. |
| `L3` | Repair bounded low-risk failures and update a pull request. | Branch protection and human merge approval remain mandatory. |
| `L4` | Run a pre-approved batch of low-risk maintenance tasks. | A policy with expiry and human review of the batch report. |

Before an edit, command, network access, or branch/pull-request handoff, run
`scripts/check-autonomy.ps1` or `scripts/check-autonomy.sh`. The command
receives the intended action, phase, feature ID, changed files, tool grants,
branch, iteration, and any scoped approval. A denied decision must stop the
operation and escalate; it must not broaden scope or permissions.

An approval record contains `approval_id`, approver identity, action, scope,
policy version, UTC timestamp, UTC expiration, decision, and evidence. The
checker rejects approvals that are expired, belong to another policy version,
or do not cover the requested phase, feature, branch, or changed files.

Commit, merge, deploy, production configuration, credential rotation, secret
access, and policy changes remain human-approval actions at every level unless
a separately signed organizational policy authorizes otherwise.

Policy status: `NOT_APPROVED`

Policy owner:

Approval reference:
