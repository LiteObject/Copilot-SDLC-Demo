# Validation Compatibility

Phase 1 uses a small, versioned configuration schema and a named task registry.
Tasks are represented as an executable plus an argument list, so the local
runner and CI invoke the same argv without shell evaluation.

## Configuration Contract

Set `sdlc_config_schema: 1`, select a supported `stack.package_manager`, point
`stack.package_manifest` at an existing repository-relative file, and configure
`testing.framework` plus existing `testing.directories`. Required tasks must
include `build` and `test`:

```yaml
validation:
  required_tasks: [build, test]
  optional_tasks: []
  install_task: install
  evidence_directory: .sdlc/evidence

tasks:
  build:
    executable: npm
    args: [run, build]
```

Use `scripts/validate-sdlc-config.ps1` or `.sh` before implementation. Run one
named task with `scripts/run-sdlc-task.ps1 -Task build` or
`scripts/run-sdlc-task.sh --task build`; use `all` to run installation, required
tasks, and configured optional tasks in order.

## Supported Package Managers

| `package_manager` | Typical manifest | Install task | Windows | Linux/macOS | Notes |
|---|---|---|---|---|---|
| `npm` | `package.json` | `npm ci` | PowerShell runner | Bash runner | Use `npm` task args such as `[run, build]`. |
| `yarn` | `package.json` | `yarn install --immutable` | PowerShell runner | Bash runner | Keep the lockfile policy in the task args. |
| `pnpm` | `package.json` | `pnpm install --frozen-lockfile` | PowerShell runner | Bash runner | The configured executable must be available on PATH. |
| `pip` | `requirements.txt` or `pyproject.toml` | Project-specific structured argv | PowerShell runner | Bash runner | Use `python` or the selected environment executable. |
| `poetry` | `pyproject.toml` | Project-specific structured argv | PowerShell runner | Bash runner | Keep environment setup outside arbitrary shell strings. |
| `cargo` | `Cargo.toml` | Project-specific structured argv | PowerShell runner | Bash runner | Use `cargo` task records. |
| `dotnet` | `.sln` or `.csproj` | Project-specific structured argv | PowerShell runner | Bash runner | Point `package_manifest` to the solution/project file. |
| `go` | `go.mod` | Project-specific structured argv | PowerShell runner | Bash runner | Use `go` task records. |
| `none` | none | `none` | PowerShell runner | Bash runner | Use for repositories without dependency installation. |

The validator checks that the selected manifest exists and that every required
or configured optional task has an available executable. It does not install
packages during validation; the `install_task` runs them during `all` execution
or in CI.

## Optional Tools

`lint` and `type_check` are optional task IDs. If a stack has no applicable
linter or type checker, omit the ID from `validation.optional_tasks`. If a tool
is material to the project, list it as a required task so a failure blocks the
validation run. There is no implicit fallback command and no shell `eval`.

## Evidence

Each validation run writes `.sdlc/evidence/config-validation.json`. Each task
writes `<task>.log` and `<task>.json` with the structured command, commit SHA,
tree digest, timestamps, exit code, result, and log path. With `--record-spec` or
`-RecordSpec`, the runner also updates the matching `gate_<task>_*` fields in
`docs/spec.md`.

## Release Assurance

For deployable repositories, install the `release-assurance` extension and set
`release_assurance.enabled: true`. Configure structured `package`, `sbom`,
`deploy`, `smoke_test`, and `rollback` tasks. The extension's preparation
script creates:

- `.sdlc/release/release-manifest.json` with source revision, artifact size,
  SHA-256 digests, SBOM, provenance, environments, and required approvals;
- an SPDX or CycloneDX SBOM reference;
- an in-toto/SLSA-style provenance statement tied to the artifact digest;
- release notes and rollback-instruction requirements.

The release workflow promotes through protected `staging` and `production`
environments. Configure required reviewers and separation-of-duties rules in
GitHub environment settings. A smoke-test failure stops promotion, and
`release-rollback.yml` provides a manual, evidence-retaining rollback path.

## Security Tasks

Phase 2 security tasks use the IDs `sast`, `secrets`, `dependency_audit`,
`license_audit`, `container_scan`, `iac_scan`, `dast`, and `security_tests`.
List applicable IDs under `security.tasks`, configure each in `tasks`, and run
`scripts/run-security-scans.ps1` or `.sh`. A nonzero task without an explicit
severity is classified as `high`; the configured `security.blocking_severities`
policy determines whether the aggregate gate fails. The aggregate result is
retained as `.sdlc/evidence/security-scan.json` and `gate_security_*`.

## AI-assisted Development Governance

For repositories that use coding agents, install the `ai-governance` extension
and set `ai_governance.enabled: true`. Configure the approved providers,
models, tenants, repositories, data classifications, tool/MCP/network/credential
allowlists, phase grants, sandbox policy, and `agent_evaluation` task. The
validator also requires policy, permissions, prompt-injection, evaluation-plan,
and scenario documents.

Run `scripts/validate-ai-governance.ps1` or `.sh` before agent work. Record each
agent-mediated change with `scripts/record-ai-change.ps1` or `.sh`; the script
rejects non-allowlisted grants and restricted actions without an `APPROVED`
human decision. The record includes the task, role, provider, model and version,
instruction version, tool grants and calls, changed files, validation results,
approvals, and final disposition in the configured JSONL ledger.

Run `scripts/run-ai-governance.ps1 -RecordSpec` or
`scripts/run-ai-governance.sh --record-spec` before handoff. The configured
evaluation task must exercise representative planning, testing, security,
scope-drift, prompt-injection, and unsafe-tool-use scenarios. A failed task
records `FAIL` evidence and blocks the governance handoff.

## AI Product Lifecycle Governance

For products that expose or depend on AI, install the `ai-lifecycle` extension
and set `ai_lifecycle.enabled: true`. This extension is conditional; using AI
to assist coding does not by itself require it. Configure the risk tier, named
risk owner, intended and prohibited uses, affected communities, applicable
law, versioned model and data inventory, required runtime controls, monitoring
signals, and the `ai_evaluation`, `ai_red_team`, `ai_production_exercise`,
`ai_rollback`, and `ai_decommission` task records.

The validator requires the impact assessment, inventory, evaluation plan and
report path, risk disposition, red-team plan, runtime-control plan, production
monitoring plan, rollback plan, decommissioning plan, model card, and system
card. It also checks that authorization, least privilege, rate and cost limits,
input/output validation, safety filters, PII handling, audit logs, human
escalation, kill-switch, and safe-fallback controls are declared.

Run `scripts/validate-ai-lifecycle.ps1` or `.sh`, then
`scripts/run-ai-lifecycle.ps1 -RecordSpec` or
`scripts/run-ai-lifecycle.sh --record-spec`. The runner executes the configured
evaluation, red-team, and production-exercise tasks, writes
`.sdlc/evidence/ai-lifecycle.json` and the configured evaluation report, and
records `gate_ai_lifecycle_*` in `docs/spec.md`.

## Measurement and Continuous Improvement

For projects using the Phase 7 extension, set `measurement.enabled: true` and
configure the named owner, cadence, retention, metric catalogs, privacy review,
and `measurement_baseline`, `measurement_snapshot`, and `measurement_review`
tasks. The snapshot task must write the configured JSON snapshot path using
schema `1` and kind `sdlc-measurement-snapshot`; the runner validates every
configured metric's value, baseline, definition, source, retention, owner, and
privacy review, plus approved improvement and regression evidence.

Run `scripts/validate-measurement.ps1` or `.sh`, then
`scripts/run-measurement.ps1 -RecordSpec` or
`scripts/run-measurement.sh --record-spec`. Python 3 is required by the
snapshot validator; use `python` on Windows or `python3` on Bash systems for
the configured snapshot task. Measurement is cadence-based by default. Set
`measurement.require_completion_gate: true` only when the measurement gate
must block the final transition to `DONE`.

The core phase validator requires enabled AI governance before `CODING` hands
off to `REVIEW`, and enabled operational-readiness or AI-lifecycle gates before
`DONE`. Deployment readiness and release assurance remain opt-in, so a project
without CI/CD deployment can use the direct `TESTING -> DONE` path.
