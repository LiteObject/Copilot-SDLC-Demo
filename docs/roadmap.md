# Future Implementation Roadmap

> Status: Phases 0-7 implemented
>
> Scope: This roadmap describes future work that turns the current Copilot-native
> SDLC template into a more enforceable software-delivery process. Phases are
> ordered by dependency and risk reduction, not by delivery date or commitment.

## Purpose and Boundaries

The current workflow is intentionally lightweight: it uses specialized agents,
a tracked specification, human approval, and local workspace tools to guide
requirements through review and testing. It is a strong starting point for
AI-assisted software delivery, but it is not yet a complete enterprise DevSecOps
or AI-product governance program.

This roadmap therefore has two tracks:

- **Baseline delivery track:** applies to every project using the template.
  It makes workflow gates, quality checks, security validation, release
  controls, and production operation more reliable.
- **AI-product track:** applies when the software being delivered contains an
  LLM, model, retrieval system, agent, or other AI capability. It adds controls
  for model, data, evaluation, safety, and ongoing AI-risk management.

The roadmap does not prescribe one language, CI provider, cloud, test framework,
or security scanner. Each project records its selected tools in
`.github/sdlc-config.yml`; the process then verifies that the selected tools are
actually configured and run.

## Target Maturity

| Phase | Priority | Outcome | Applies to |
|---|---|---|---|
| 0. Workflow integrity | P0 | State transitions and scope checks cannot be bypassed by inconsistent agent instructions or placeholder evidence. | All projects |
| 1. Configured validation | P0 | Build, test, lint, and type-check commands are complete, reproducible, and enforced locally and in CI. | All projects |
| 2. Quality and secure development | P1 | Test strategy and security checks cover more than unit tests and manual review. | All projects |
| 3. Release and supply-chain assurance | P1 | Pull requests, artifacts, deployments, approvals, and rollback have verifiable controls. | All projects |
| 4. Operational readiness | P2 | Released software has observability, service objectives, incident handling, and feedback loops. | All deployed projects |
| 5. AI-assisted development governance | P1 | Use of coding agents, models, prompts, and tools is governed and auditable. | Projects using agents |
| 6. AI-product lifecycle governance | P1 when applicable | AI features are assessed, evaluated, secured, monitored, and retired responsibly. | AI-enabled products |
| 7. Measurement and continuous improvement | P2 | The process is measured and improved using outcome data rather than agent activity alone. | All projects |

## Phase 0: Workflow Integrity

> Implementation status: complete. Versioned spec metadata, transition checks,
> revision-bound gate validation, exact scope policy, legacy-spec migration,
> cross-platform regression fixtures, and native Windows/Linux CI validation
> are implemented.

### Objective

Make the documented state machine authoritative and make every gate evaluate
actual evidence rather than the presence of text in a Markdown section.

### Limitations Addressed

- QA currently instructs a direct transition to `DONE` after tests pass, while
  the Supervisor can optionally require `DEPLOYMENT_READINESS`.
- `check-phase` verifies that a section is non-empty, but does not verify that a
  build, test, security, or deployment check passed.
- The scope audit can become overly broad when the file plan contains a folder
  such as `src/` instead of an exact file list.
- The current review-cycle limit is documented, but its transitions and
  escalation evidence are not independently validated.

### Implementation Work

1. Centralize state mutation in the Supervisor. Worker agents return structured
   results, but do not independently set `Current State` to a terminal phase.
2. Define one transition table for every allowed state change, including the
   enabled and disabled paths for `DEPLOYMENT_READINESS`.
3. Add machine-readable gate data to the tracked specification, such as YAML
   front matter in `docs/spec.md`. It should record the current phase, review
   cycle, command, commit SHA, timestamp, exit code, result, and evidence link
   for every required gate.
4. Update `check-phase.ps1` and `check-phase.sh` to reject a transition when a
   required gate has no result, has a non-zero exit code, is stale for the
   current commit, or has a result other than `PASS`.
5. Replace implicit directory-wide scope with an explicit `planned_files` list.
   Allow glob patterns only when the Architect records their justification and
   the Reviewer approves the wider blast radius.
6. Add regression fixtures for valid and invalid workflow states, including a
   failed test, failed deployment readiness check, a fourth review cycle, and
   a changed file outside the exact plan.

### Completion Criteria

- A passing QA result cannot bypass an enabled deployment-readiness gate.
- A non-passing build, test, scan, or readiness result blocks the next state.
- Scope audit fails when an unplanned file changes and reports the planned-file
  rule that it violated.
- Cross-platform script tests prove the same state decisions on PowerShell and
  Bash.

### Expected Implementation Surfaces

| Area | Expected changes |
|---|---|
| Agent behavior | `.github/agents/sdlc-supervisor.agent.md`, `qa.agent.md`, `reviewer.agent.md` |
| State and evidence | `docs/spec.md` and its documented schema |
| Deterministic checks | `scripts/check-phase.ps1`, `scripts/check-phase.sh`, `scripts/migrate-spec.ps1`, `scripts/migrate-spec.sh`, `scripts/scope-audit.ps1`, `scripts/scope-audit.sh` |
| Regression coverage | `tests/fixtures/phase0/` and automated tests for both validator and migration variants |
| CI validation | `.github/workflows/phase0-validation.yml` runs native Bash/Ubuntu and PowerShell/Windows checks |

Phase 1 surfaces:

| Area | Implemented surface |
|---|---|
| Configuration contract | `template/base/.github/sdlc-config.yml` with `sdlc_config_schema: 1` and structured `tasks` |
| Deterministic validation | `template/base/scripts/validate-sdlc-config.ps1` and `.sh` |
| Named task execution | `template/base/scripts/run-sdlc-task.ps1` and `.sh` |
| Evidence | `.sdlc/evidence/` JSON records and task logs; `gate_<task>_*` spec fields |
| Compatibility | `docs/guides/validation-compatibility.md` |
| Adoption | `tools/scaffold-sdlc.ps1 -ValidateConfig` and `tools/scaffold-sdlc.sh --validate-config` |
| Regression coverage | `tests/fixtures/phase1/` and `tests/phase1/` |
| CI validation | `.github/workflows/phase1-validation.yml` plus the updated GitHub Actions extension |

## Phase 1: Configured, Reproducible Validation

> Implementation status: complete. The versioned config contract, native
> validators, structured task runner, evidence records, compatibility guide,
> scaffold enforcement switch, and CI integration are implemented.

### Objective

Turn the currently illustrative stack configuration into a validated contract
that works the same way on a developer machine and in CI.

### Limitations Addressed

- The template remains visibly incomplete until each adopting project configures
   the versioned schema, package manifest, framework, test directories, and
   named validation tasks.
- CI must use the same named task runner as local validation, including install,
   build, test, lint, type-check, and retained gate evidence where configured.
- Task execution must not rely on shell `eval` or arbitrary command strings.

### Implementation Work

1. Define a versioned schema for `.github/sdlc-config.yml` with required task
   IDs for build and test, optional lint/type-check IDs, package-manager and
   manifest fields, and an evidence directory.
2. Add `validate-sdlc-config.ps1` and `validate-sdlc-config.sh` to verify the
   schema, command presence, supported package manager, test directories, and
   deployment-gate prerequisites before agents start implementation.
3. Define a small, named task registry where each task is an executable plus an
   argument list. The runner invokes the structured argv directly.
4. Update the scaffold script to require or guide stack configuration during
   adoption, and leave a project visibly incomplete until validation succeeds.
5. Run the same validation runner locally, in pull requests, and in the
   optional autonomy workflow. Capture command output as build artifacts and
   reference it in the gate evidence.
6. Add a compatibility matrix documenting supported package managers, operating
   systems, and the fallback behavior when a project has no applicable
   type-checker or linter.

### Completion Criteria

- A new adoption remains visibly incomplete and can fail fast with an actionable
   error when `-ValidateConfig` or `--validate-config` is selected until required
   stack configuration is complete.
- Local and CI execution invoke the same named validation tasks.
- The CI workflow installs declared dependencies, validates configuration, and
  runs each required task without `eval`.
- A gate record includes the command, repository revision, result, and retained
  output for each validation task.

## Phase 2: Quality and Secure Development Baseline

> Implementation status: complete. Risk-based test strategy, acceptance-test
> mapping, security design review guidance, configurable security tasks,
> machine-readable severity policy, negative security expectations, and native
> Windows/Linux regression CI are implemented.

### Objective

Expand verification from unit-test execution and manual review into a
risk-based test and security program.

### Limitations Addressed

- The present QA guidance emphasizes unit tests but does not define integration,
  API, end-to-end, accessibility, performance, resilience, fuzz, or property
  testing expectations.
- Security review and deployment readiness cover useful basics, but depend on
  manual inspection and simple search commands.
- Threat modeling, vulnerability triage, and security-test evidence are absent.

### Implementation Work

1. Add a test-strategy section to the architecture plan. It selects required
   test layers based on the feature's risk: unit, integration, contract/API,
   browser/end-to-end, accessibility, performance, resilience, fuzz, and
   property-based tests.
2. Require each acceptance criterion to map to one or more automated tests or
   to a documented manual verification procedure with an owner and evidence.
3. Add security design review before coding for changes that process external
   input, authenticate users, access data stores, execute commands, manage
   secrets, expose APIs, or change infrastructure.
4. Integrate configurable SAST, secret scanning, dependency and license
   scanning, container and infrastructure-as-code scanning, and DAST where a
   running application is available.
5. Define severity policy: critical and high findings block delivery; lower
   findings require a documented disposition, owner, due date, and risk
   acceptance when applicable.
6. Add regression and negative security tests for authentication, authorization,
   input validation, error handling, and sensitive-data exposure relevant to
   each feature.

### Completion Criteria

- Every planned feature declares its required test layers and security review
  needs before coding begins.
- Pull-request validation produces machine-readable results for enabled scans.
- Blocking vulnerabilities cannot reach release readiness without an approved,
  traceable exception.
- Test and scan results are tied to the same commit evaluated by the Reviewer.

### Standards Alignment

Use [NIST SSDF](https://csrc.nist.gov/pubs/sp/800/218/final) as the baseline
for secure software practices. Tool choices remain project-specific; the
enforced outcomes are evidence, triage, remediation, and repeatability.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `quality_security` and `security` sections in `template/base/.github/sdlc-config.yml` |
| Spec contract | `Test Strategy`, `Acceptance Test Mapping`, `Security Design Review`, and `Security Findings` in `template/base/docs/spec.md` |
| Security execution | `template/base/scripts/run-security-scans.ps1` and `.sh` |
| Blocking policy | `gate_security_*` plus machine-readable `.sdlc/evidence/security-scan.json` |
| Review/QA guidance | `template/base/.github/instructions/security-standards.instructions.md`, testing standards, Reviewer, and QA agents |
| Regression coverage | `tests/fixtures/phase2/` and `tests/phase2/` |
| CI validation | `.github/workflows/phase2-validation.yml` and updated GitHub Actions extension |

## Phase 3: Release, Deployment, and Supply-Chain Assurance

> Implementation status: complete. The opt-in release-assurance extension now
> validates release configuration, creates immutable artifact manifests with
> checksums, validates SBOMs, generates provenance, gates promotion through
> protected environments and smoke tests, and exposes manual rollback with
> retained evidence.

### Objective

Make a successful test run only one part of a controlled path from reviewed
source to a deployable, traceable artifact.

### Limitations Addressed

- The optional GitHub workflow validates a labeled issue only; it is not a full
  pull-request, artifact, deployment, or rollback pipeline.
- Artifact integrity, SBOMs, provenance, signed releases, environment approval,
  infrastructure deployment, smoke testing, and rollback are not defined.

### Implementation Work

1. Add pull-request workflows that validate configuration, install dependencies,
   run required quality and security checks, and publish a summarized status.
2. Build immutable, versioned artifacts and retain their checksums, build logs,
   test evidence, and source revision.
3. Generate an SPDX or CycloneDX SBOM for each release artifact and scan it
   against vulnerability and license policy.
4. Generate and verify build provenance aligned with the
   [SLSA specification](https://slsa.dev/spec/v1.2/). Pin CI actions and
   third-party build inputs according to the project's supply-chain policy.
5. Define environment promotion rules: development, test, staging, and
   production configuration; secrets source; approval requirements; deployment
   windows; and separation of duties for high-risk changes.
6. Use versioned, reviewed infrastructure-as-code where infrastructure changes
   are required. Include plan/what-if output and post-deployment smoke tests.
7. Define release notes, change records, deployment health checks, and a tested
   rollback procedure before production promotion.

### Completion Criteria

- Every production artifact can be traced to an approved source revision,
  validated build, SBOM, and provenance record.
- A release cannot promote without required approvals and successful
  environment-specific checks.
- A failed post-deployment smoke or health check automatically stops promotion
  and exposes the documented rollback path.
- Deployment-readiness evidence is stored with the release rather than only in
  a transient chat session.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `release_assurance` contract in `template/base/.github/sdlc-config.yml` |
| Release extension | `template/extensions/release-assurance/` |
| Config validation | `scripts/validate-release-config.ps1` and `.sh` |
| Artifact/provenance | `scripts/prepare-release.ps1` and `.sh` |
| Verification | `scripts/verify-release.ps1` and `.sh` |
| Promotion | `release-assurance.yml` with staging/production environments and smoke gates |
| Rollback | `release-rollback.yml` and configured `rollback_task` |
| Evidence | Release manifest, SHA-256 digests, SBOM, provenance, logs, and rollback evidence |
| Regression coverage | `tests/fixtures/phase3/` and `tests/phase3/` |

Release assurance remains opt-in. Projects and features that do not deploy can
leave the deployment-readiness and release-assurance controls disabled and use
the direct testing-to-done workflow path.

## Phase 4: Operational Readiness and Reliability

### Objective

Extend the lifecycle beyond deployment so teams can detect, diagnose, recover
from, and learn from production failures.

### Limitations Addressed

- There is no observability standard, service-level objective, incident process,
  change-impact monitoring, or post-release learning loop.

### Implementation Work

1. Require structured logs, metrics, distributed traces, health endpoints, and
   correlation identifiers for deployable services.
2. Define service-level indicators and objectives for availability, latency,
   error rate, throughput, and critical business outcomes. Establish alert and
   escalation rules tied to error budgets where appropriate.
3. Add production-readiness review items for capacity, backup/recovery,
   dependency failure handling, data retention, privacy, and disaster recovery.
4. Create runbooks for common alerts, degraded dependencies, rollbacks, secret
   rotation, and emergency disablement of risky features.
5. Define incident response roles, severity levels, communication requirements,
   and a blameless post-incident review process with tracked corrective actions.
6. Feed production defects, alerts, and user feedback back into the requirements
   and planning phases as prioritized work.

### Completion Criteria

- Each deployed service has documented health checks, telemetry, ownership,
  service objectives, and an on-call or escalation path.
- A staging failure drill demonstrates alerting, diagnosis, and rollback using
  the published runbook.
- Post-release checks capture both technical health and the feature's intended
  outcome before a rollout is declared complete.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `operational_readiness` contract in `template/base/.github/sdlc-config.yml` and revision-bound fields in `docs/spec.md` |
| Operational extension | `template/extensions/operational-readiness/` |
| Config validation | `scripts/validate-operational-readiness.ps1` and `.sh` |
| Readiness gate | `scripts/run-operational-readiness.ps1` and `.sh` with health, telemetry, post-release, and staging failure-drill tasks |
| Runbooks and policy | Readiness review, alert, escalation, incident-response, and five common runbooks |
| Feedback evidence | `record-production-outcome.*` and `record-incident-review.*` |
| Automation | Scheduled/manual `operational-readiness.yml` with retained evidence |
| Regression coverage | `tests/fixtures/phase4/` and `tests/phase4/` |

## Phase 5: Governance of AI-Assisted Development

### Objective

Control the risks introduced when AI agents read repository content, invoke
tools, create code, and interact with external systems.

### Limitations Addressed

- Tool permissions are role-scoped, but there is no explicit policy for approved
  models, data classification, prompt handling, MCP servers, sandboxing, or
  audit retention.
- The current process does not record the model, prompt/instruction version,
  tool calls, or human approval associated with an agent-generated change.
- Prompt injection and untrusted tool output are not treated as explicit threats
  to coding agents.

### Implementation Work

1. Publish an AI-assisted development policy that defines approved providers,
   models, subscriptions/tenants, permitted repositories, data classifications,
   prohibited inputs, retention requirements, and intellectual-property review.
2. Maintain an allowlist for agent tools, MCP servers, network destinations, and
   credential scopes. Default agents to the least privilege required for their
   phase and require explicit approval to widen that scope.
3. Run agents in isolated worktrees or sandboxes when practical. Prevent agents
   from directly committing, merging, deploying, rotating credentials, or
   changing production configuration without a human-controlled approval step.
4. Treat repository text, issue content, web pages, tool output, and retrieved
   documents as untrusted input. Add instructions and automated checks for
   prompt-injection resistance, command confirmation, and safe handling of
   secrets and sensitive data.
5. Record an auditable change ledger containing task identifier, agent role,
   model and version, instruction version, tool grants, tool calls, changed
   files, human approvals, validation results, and final disposition.
6. Periodically evaluate agent behavior with representative tasks to measure
   planning accuracy, test quality, security-finding precision, rate of
   unapproved scope changes, and human rework required.

### Completion Criteria

- Every agent-mediated change has an attributable task, approved permission
  boundary, validation evidence, and human reviewer or approver.
- Sensitive repositories cannot use unapproved models, tools, or external MCP
  connections.
- High-impact actions always require an explicit, recorded human decision.
- Prompt-injection and unsafe-tool-use scenarios are exercised as part of the
  agent evaluation suite.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `ai_governance` contract in `template/base/.github/sdlc-config.yml`, `agent_evaluation` task support, and revision-bound fields in `docs/spec.md` |
| Governance extension | `template/extensions/ai-governance/` |
| Policy and trust boundaries | AI-assisted development policy, permission allowlist, prompt-injection threat model, evaluation plan, and representative scenarios |
| Config validation | `scripts/validate-ai-governance.ps1` and `.sh` |
| Change ledger | `scripts/record-ai-change.ps1` and `.sh` with allowlist and human-approval enforcement |
| Evaluation gate | `scripts/run-ai-governance.ps1` and `.sh` with task evidence and `gate_ai_governance_*` recording |
| Transition enforcement | Enabled AI governance is required before `CODING -> REVIEW` |
| Automation | Scheduled/manual `ai-governance.yml` with retained evidence |
| Regression coverage | `tests/fixtures/phase5/` and `tests/phase5/` |

## Phase 6: Lifecycle Governance for AI-Enabled Products

### Objective

Add a formal lifecycle for products that expose or depend on AI capabilities.
This phase is conditional: conventional software does not need model evaluation
or model-risk controls simply because agents helped write its code.

### Limitations Addressed

- The process currently has no intended-use assessment, risk tiering, model or
  data provenance, evaluation thresholds, red teaming, safety review, fairness
  or privacy assessment, runtime monitoring, model rollback, or decommissioning
  process.
- It does not explicitly address the LLM risks of prompt injection, sensitive
  information disclosure, supply chain compromise, data/model poisoning,
  improper output handling, excessive agency, system-prompt leakage, vector
  weaknesses, misinformation, and unbounded consumption.

### Implementation Work

1. Add an AI impact-assessment gate before architecture. Document intended and
   prohibited uses, users and affected communities, harm scenarios, applicable
   laws and policy, risk tolerance, human oversight, contestability, and a
   named risk owner.
2. Maintain a versioned inventory for models, providers, prompts, system
   instructions, tools, retrieval sources, embeddings, datasets, evaluation
   datasets, safety filters, and fallback behavior. Record licenses, terms,
   data lineage, retention, and change history.
3. Require a written evaluation plan before implementation. Define representative
   and adversarial test datasets, measurement methodology, quality thresholds,
   safety thresholds, latency/cost budgets, and release-blocking criteria.
4. Build automated evaluation pipelines covering task quality, reliability,
   grounding, hallucination/misinformation, privacy, bias/fairness where
   applicable, robustness, prompt injection, jailbreak resistance, insecure
   tool invocation, retrieval quality, and refusal/fallback behavior.
5. Conduct risk-proportionate red teaming before high-impact releases. Track
   findings, mitigations, residual risk, executive or product-owner acceptance,
   and retest evidence.
6. Enforce runtime controls: authentication and authorization for tools,
   least-privilege service identities, rate and cost limits, input/output
   validation, content and safety filters, PII handling, audit logs, human
   escalation, kill switches, and safe fallback experiences.
7. Monitor production quality, safety events, data/model drift, adversarial
   activity, cost, latency, tool actions, user feedback, and disproportional
   impact. Define alert thresholds, incident response, re-evaluation cadence,
   prompt/model rollback, and end-of-life/decommission procedures.
8. Produce user-appropriate documentation such as model cards, system cards,
   known limitations, data-use disclosures, and support or appeal mechanisms.

### Completion Criteria

- An AI feature cannot ship without an approved impact assessment, inventory,
  evaluation report, risk disposition, and production monitoring plan.
- Automated evaluations meet documented release thresholds and run on every
  material model, prompt, retrieval, tool, or safety-policy change.
- High-risk tool actions are guarded by authorization, rate limits, audit logs,
  and a human escalation or disablement path.
- A production exercise demonstrates detection, containment, rollback, and
  stakeholder communication for an AI safety or security incident.

### Standards Alignment

Structure this work around the [NIST AI RMF Playbook](https://airc.nist.gov/AI_RMF_Knowledge_Base/Playbook)
functions: Govern, Map, Measure, and Manage. Use the
[OWASP Top 10 for LLM and GenAI Applications](https://genai.owasp.org/llm-top-10/)
to define the threat and test catalog. These references guide risk-based
implementation; they do not by themselves grant compliance certification.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `ai_lifecycle` contract in `template/base/.github/sdlc-config.yml`, lifecycle task IDs, and revision-bound fields in `docs/spec.md` |
| Lifecycle extension | `template/extensions/ai-lifecycle/` |
| Impact and inventory | Impact assessment, versioned AI system inventory, risk disposition, model card, and system card templates |
| Evaluation and red teaming | Evaluation plan, adversarial scenario catalog, configured evaluation/red-team tasks, and release-blocking evidence |
| Runtime and operations | Runtime control, production monitoring, rollback, and decommissioning plans with required safety controls |
| Config validation | `scripts/validate-ai-lifecycle.ps1` and `.sh` |
| Lifecycle gate | `scripts/run-ai-lifecycle.ps1` and `.sh` with evaluation, red-team, production-exercise, and `gate_ai_lifecycle_*` evidence |
| Transition enforcement | Enabled AI lifecycle is required on the final transition to `DONE` |
| Automation | Scheduled/manual `ai-lifecycle.yml` with retained evidence |
| Regression coverage | `tests/fixtures/phase6/` and `tests/phase6/` |

## Phase 7: Measurement and Continuous Improvement

> Implementation status: complete. The opt-in measurement extension validates
> named metric ownership, definitions, sources, retention, privacy review, and
> roadmap coverage; runs baseline, snapshot, and review tasks; retains
> machine-readable evidence; and provides quarterly automation.

### Objective

Improve the process using delivery outcomes, quality, safety, and user impact
rather than measuring agent activity or code volume.

### Implementation Work

1. Establish a baseline before major process changes: lead time, deployment
   frequency, change-failure rate, recovery time, escaped defects, security
   findings, review-cycle count, flaky-test rate, and rollback rate.
2. Add AI-assisted delivery measures: percentage of changes with complete
   evidence, agent-suggested defect rate, human rework, review acceptance rate,
   scope-drift rate, validation pass rate, and model/tool policy violations.
3. For AI-enabled products, measure task quality, safety rate, abstention or
   escalation rate, user-reported harms, cost, latency, drift, and incident
   recurrence without logging unnecessary personal or sensitive content.
4. Review metrics at a fixed cadence. Turn recurring failures into changes to
   prompts, guardrails, test suites, instructions, tools, or requirements, then
   measure whether the change improved the original outcome.
5. Publish a lightweight quarterly process review with completed improvements,
   unresolved risks, exception trends, and the next prioritized roadmap items.

### Completion Criteria

- Metrics have named owners, definitions, sources, retention rules, and privacy
  review.
- Each roadmap phase has at least one outcome measure and one leading indicator.
- Process changes are accepted only after documenting the observed effect and
  any regressions.

### Implemented Surfaces

| Area | Implemented surface |
|---|---|
| Configuration | `measurement` contract in `template/base/.github/sdlc-config.yml`, Phase 7 task IDs, and revision-bound fields in `docs/spec.md` |
| Measurement extension | `template/extensions/measurement/` |
| Metric governance | Baseline, delivery, AI-product, and roadmap outcome/leading-indicator catalogs with named ownership, privacy rules, and validated JSON snapshots |
| Continuous improvement | Improvement log and quarterly process-review templates with observed-effect and regression fields |
| Config validation | `scripts/validate-measurement.ps1` and `.sh` |
| Measurement gate | `scripts/run-measurement.ps1` and `.sh` with baseline, snapshot, review, and `gate_measurement_*` evidence |
| Transition enforcement | Measurement is cadence-based by default; `measurement.require_completion_gate: true` requires the gate before `DONE` |
| Automation | Scheduled/manual `measurement.yml` with retained evidence |
| Regression coverage | `tests/fixtures/phase7/` and `tests/phase7/` |

## Competitive Gap Closure

> Status: future work. Phases 0-7 establish a strong, enforceable baseline, but
> the process still needs the following capabilities to match the strongest
> spec-driven development, agent-orchestration, and delivery platforms. These
> items are intentionally written as implementation-ready backlog entries for
> an AI agent or engineering team.

### Where It Falls Short of the Best

| Gap | Current limitation | Future item |
|---|---|---|
| Workflow concurrency | A single project-owned `docs/spec.md` serializes unrelated features and can conflict across worktrees or pull requests. | CG-1: Feature-scoped workflow state |
| Work decomposition | The Architect records a file plan, but the process has no dependency-aware task graph with task-level evidence. | CG-2: Task graph and task-level evidence |
| Verification strength | A passing test command can still provide weak coverage or no meaningful regression protection. | CG-3: Meaningful verification gates |
| Autonomy control | Human supervision is the default, but there is no explicit, auditable ladder between assisted editing and bounded PR automation. | CG-4: Graduated autonomy |
| Agent portability | The workflow is authored primarily for VS Code Copilot custom agents and does not project the same contract to other agent surfaces. | CG-5: Portable agent surfaces |
| Adoption and updates | Clone-plus-script installation is reliable but has more friction than a versioned package, template repository, or upgrade command. | CG-6: Distribution and upgrade experience |
| Measurement comparability | Phase 7 defines useful metrics but does not anchor them to a known delivery model with stable formulas and event sources. | CG-7: DORA and AI outcome metrics |
| Contract parsing | PowerShell and Bash maintain parallel hand-written parsers for a deliberately small YAML subset, creating long-term syntax and parity risk. | CG-8: Contract parser hardening |

The gaps are not reasons to weaken the current controls. They identify the next
layer of capability: preserve deterministic gates and human control while making
the workflow easier to parallelize, verify, adopt, measure, and run outside one
editor. The recommended dependency order is `CG-1` and `CG-2`, then `CG-3` and
`CG-4`, followed by `CG-5` through `CG-8` as the pilot data and distribution
needs become clearer.

### Top Recommendations: Future Implementation Items

#### CG-1. Feature-Scoped Workflow State (P1)

**Objective:** Allow multiple features to move through the SDLC concurrently
without sharing mutable phase, review-cycle, planned-file, or gate metadata.

**Design contract:**

- Make `docs/specs/<feature-id>/spec.md` the canonical path for new feature
  workflows. Keep `docs/spec.md` as the default legacy-compatible path until a
  target repository explicitly opts into feature-scoped mode.
- Require `feature-id` to be a normalized, repository-relative safe identifier:
  lowercase letters, numbers, and single hyphens only; reject empty values,
  path separators, `.`/`..`, absolute paths, and collisions after
  normalization.
- Namespace feature evidence under `.sdlc/evidence/<feature-id>/` and feature
  task logs under the same feature directory. A gate for one feature must never
  satisfy or overwrite a gate for another feature.
- Add a feature context to every gate record: feature ID, spec path, source
  revision, working-tree digest, and evidence path. Keep the existing revision
  binding and scope-audit rules unchanged.
- Permit shared project files only through an explicit shared-file policy. A
  feature's default scope remains its own spec plus the exact files declared in
  its plan; edits to shared configuration, dependency manifests, workflows, or
  generated lockfiles require an approved shared-scope record.
- Do not introduce a single mutable global active-feature file. The Supervisor
  should select a feature from the user request, branch/worktree context, or an
  explicit `--feature-id`/`--spec-path` argument.

**Implementation tasks:**

1. Add `--feature-id` and `--spec-path` support to both PowerShell and Bash
   versions of `check-phase`, `scope-audit`, `run-sdlc-task`, security gates,
   and every optional-extension runner that reads or writes `docs/spec.md`.
2. Centralize feature path validation in a shared, documented contract so the
   PowerShell and Bash installers and validators reject the same identifiers.
3. Update the Supervisor, worker agents, prompts, and shared instructions to
   create or select a feature spec before reading workflow state. Pass the
   resolved spec and evidence roots to every worker and command.
4. Update scaffold and migration behavior so existing `docs/spec.md` files are
   preserved, legacy mode remains functional, and migration to a feature spec
   creates a backup plus an explicit feature ID. Never silently split one
   legacy workflow into multiple features.
5. Update `template/manifest.yml`, the authoring documentation, and the
   compatibility guide with the new target-relative directories and migration
   rules.
6. Add fixtures for two independent features, same-file conflict detection,
   shared-file approval, invalid feature IDs, path traversal, stale evidence in
   one feature, and legacy `docs/spec.md` behavior. Run the same cases through
   PowerShell and Bash.

**Completion criteria:**

- Two feature specs can pass validation independently in the same repository
  without gate, evidence, or review-cycle collisions.
- A command given feature A cannot read, write, or accept evidence from feature
  B unless an explicit shared-file or shared-evidence rule allows it.
- Scope audit reports the feature context and rejects an unplanned shared-file
  change.
- Existing adopters using `docs/spec.md` continue to pass without migration.
- A failed or stale gate in one feature cannot block or falsely advance another
  feature.

**Expected implementation surfaces:** `template/base/.github/agents/`,
`template/base/.github/prompts/`, `template/base/.github/instructions/`,
`template/base/scripts/`, `template/base/docs/spec.md`,
`template/base/.github/sdlc-config.yml`, `tools/scaffold-sdlc.*`,
`template/manifest.yml`, `docs/guides/validation-compatibility.md`, and new
Phase 8 fixtures and harnesses.

**Implementation status:** The first CG-1 slice is implemented. Feature IDs
resolve to canonical specs and evidence namespaces across phase validation,
scope auditing, task execution, security gates, migration, and the enabled
extension runners; worker guidance and cross-platform Phase 8 regression
coverage are included. Scaffold-level feature creation and explicit shared-file
approval remain follow-up work before this item is considered complete.

#### CG-2. Task Graph and Task-Level Evidence (P1)

**Objective:** Replace a file-only implementation checklist with a
dependency-aware graph of independently verifiable work items.

**Task contract:** Define a versioned machine-readable task document per
feature, preferably `docs/specs/<feature-id>/tasks.json` once CG-8 establishes
the canonical contract parser. Each task must contain:

```json
{
  "id": "TASK-001",
  "title": "Implement the request validator",
  "description": "Reject malformed and unsupported input before persistence.",
  "requirement_refs": ["REQ-001"],
  "acceptance_refs": ["AC-001"],
  "depends_on": [],
  "planned_files": ["src/validation/request-validator.ts"],
  "verification_tasks": ["test", "security_tests"],
  "status": "TODO",
  "evidence": []
}
```

Allowed task statuses are `TODO`, `IN_PROGRESS`, `BLOCKED`, and `DONE`.
Evidence entries must include the named task, command or structured task ID,
revision, tree digest, exit code, result, and evidence path. Dependencies must
form a directed acyclic graph; unknown task IDs, duplicate IDs, cycles, and
unmapped requirements are validation errors.

**Implementation tasks:**

1. Add a schema version and validator for the task document. Validate unique
   IDs, required references, safe repository-relative paths, dependency
   existence, cycle freedom, allowed statuses, and allowed verification task
   IDs from `.github/sdlc-config.yml`.
2. Extend the Architect output contract so every task maps to one or more
   requirements and acceptance criteria, declares exact target files, names
   dependencies, and identifies the verification that can mark it complete.
3. Derive the effective scope from the union of task `planned_files` plus
   explicitly approved shared files. Keep the existing exact-file and approved
   glob rules as the final scope boundary.
4. Add task-aware Supervisor transitions: coding may start only when prerequisite
   tasks are complete or intentionally blocked with an approved disposition;
   review may start only when all coding tasks are complete; testing must report
   task-level failures; and `DONE` requires every release-blocking task to have
   current passing evidence.
5. Prevent workers from marking a task `DONE` without evidence. The Supervisor
   remains the only writer of workflow state and final task status; workers
   return proposed status plus evidence for validation.
6. Add a task graph view or text summary to the handoff and session recap so a
   human can see blocked, ready, and completed tasks without parsing raw JSON.
7. Add regression fixtures for a valid DAG, duplicate IDs, cycles, missing
   requirement mappings, missing evidence, stale evidence, blocked tasks, and
   a task whose files exceed the approved scope.

**Completion criteria:**

- An Architect plan cannot advance when an acceptance criterion has no task or
  approved manual verification mapping.
- A cyclic or incomplete task graph fails before coding begins.
- A task marked `DONE` without current passing evidence cannot satisfy a phase
  gate.
- Scope audit and task scope produce the same changed-file decision.
- A failed task identifies its requirement, acceptance criterion, files, and
  next actionable worker handoff.

**Dependencies:** CG-1 supplies the feature namespace. CG-8 should be completed
before making `tasks.json` mandatory, although a compatibility implementation
may initially validate the document with the existing contract adapters.

#### CG-3. Meaningful Verification Gates (P1)

**Objective:** Ensure that a successful test command demonstrates useful
regression protection rather than merely exiting with status zero.

**Policy:** Verification must remain risk-based. Do not impose one coverage
threshold on every repository. Low-risk changes may require only the existing
test gate; higher-risk profiles or explicitly selected test layers must opt into
additional evidence.

**Implementation tasks:**

1. Add structured verification settings to `.github/sdlc-config.yml`, including
   the coverage task/provider, changed-line coverage threshold, excluded paths,
   optional mutation task and threshold, and the risk profiles for which each
   check is required. Store thresholds as policy data, not shell fragments.
2. Add a coverage adapter that reads a supported machine-readable report,
   intersects it with the changed files and changed executable lines, and emits
   `.sdlc/evidence/coverage.json` with source revision, tree digest, covered
   lines, total changed lines, percentage, exclusions, and result.
3. Define no-change behavior explicitly: a feature with no executable changes
   may pass changed-line coverage with a recorded `NOT_APPLICABLE` result, but
   the overall test gate must still run the configured tests.
4. Add optional mutation testing for high-risk or security-sensitive changes.
   Mutation evidence must record the tool version, mutation count, killed and
   survived mutants, exclusions, threshold, and disposition of survivors.
5. Require tests for acceptance criteria and relevant negative security behavior
   to be mapped to task IDs. Coverage alone must never replace behavioral,
   integration, accessibility, performance, or security tests selected by the
   risk profile.
6. Make the Reviewer and QA agents inspect machine-readable verification
   evidence rather than accepting a pasted coverage number or command output.
7. Add fixtures for missing reports, stale reports, low changed-line coverage,
   generated/vendor exclusions, no executable changes, mutation threshold
   failure, and a passing report with an unmapped acceptance criterion.

**Completion criteria:**

- A configured coverage requirement fails when the report is missing, stale,
  malformed, or below the changed-line threshold.
- Coverage and mutation results are bound to the same revision and tree digest
  as the phase gate.
- The validator never treats a manually supplied percentage as evidence.
- High-risk changes cannot pass solely because a unit-test command returned zero.
- Every exception has an owner, rationale, expiration, and human approval.

**Expected implementation surfaces:** `.github/sdlc-config.yml`,
`docs/spec.md`, `scripts/run-sdlc-task.*`, new verification adapter scripts,
security and testing instructions, Reviewer and QA agents, and Phase 8
fixtures.

#### CG-4. Graduated Autonomy (P1)

**Objective:** Make agent autonomy an explicit policy that can increase with
evidence and remain bounded by human approval for irreversible or high-impact
actions.

Define these initial levels in the configuration contract:

| Level | Permitted behavior | Required approval |
|---|---|---|
| `L0` | Read, analyze, and propose changes only. | Human accepts every edit and command. |
| `L1` | Edit files and run allowlisted local validation in an isolated workspace. | Human reviews the resulting diff and gate evidence. |
| `L2` | Run the full configured validation loop and prepare a branch or pull request. | Human approves the pull request and any external side effect. |
| `L3` | Repeatedly repair bounded, low-risk failures and update a pull request. | Branch protection and a human merge approval remain mandatory. |
| `L4` | Execute a pre-approved batch of low-risk maintenance tasks on a schedule. | Pre-approved policy, automatic expiry, and human review of the batch report. |

Commit, merge, deploy, production configuration, credential rotation, secret
access, policy changes, and new network destinations remain human-approval
actions at every level unless a separate signed organizational policy explicitly
authorizes them.

**Implementation tasks:**

1. Add `ai_governance.autonomy_level`, action classes, approval requirements,
   maximum iteration count, maximum changed-file count, allowed branches, and
   policy-expiration fields to `.github/sdlc-config.yml`.
2. Implement a fail-closed `check-autonomy` command that receives an intended
   action, phase, feature ID, changed-file set, tool grants, and current policy.
   It must return an allow/deny decision plus a machine-readable reason.
3. Invoke the decision before edits, command execution, network access, and
   handoffs that can create a branch or pull request. Integrate the decision
   with the AI change ledger so the requested action, decision, approval ID,
   and final disposition are linked.
4. Add an approval record format with approver identity, action, scope, policy
   version, timestamp, expiration, decision, and evidence. Reject approvals
   outside their scope or after expiration.
5. Add bounded-loop controls: stop after the configured iteration or scope
   limit, preserve the failure evidence, and escalate instead of silently
   broadening the plan.
6. Update the Supervisor and AI-governance instructions to describe the default
   level, escalation path, sandbox requirements, and prohibited actions.
7. Add a test matrix for each level, denied restricted actions, expired or
   mismatched approvals, scope expansion, iteration exhaustion, and prompt or
   tool output attempting to widen permissions.

**Completion criteria:**

- A repository has an explicit autonomy level; missing or invalid policy fails
  closed to the safest level.
- The same action receives the same decision in PowerShell, Bash, local agent
  execution, and CI policy checks.
- No autonomy level bypasses the existing phase gates, scope audit, security
  policy, or protected environment approvals.
- Every automated action has a ledger record that a reviewer can correlate to
  its approvals, changed files, and validation evidence.

#### CG-5. Portable Agent Surfaces (P2)

**Objective:** Preserve one process contract while allowing teams to use agent
surfaces other than VS Code Copilot.

**Implementation tasks:**

1. Separate the canonical workflow contract from editor-specific syntax. Keep
   phase names, state schema, gate commands, task IDs, permission rules, and
   evidence formats in portable documentation and scripts.
2. Add a generated root `AGENTS.md` projection containing the essential
   workflow, scope, safety, and validation rules. Mark it as generated and
   include the template version and source hash so drift is detectable.
3. Add adapter templates for the supported agent surfaces selected by the
   project. Each adapter must point to the same Supervisor contract and must
   not define a competing state machine or weaker approval policy.
4. Add a scaffold option such as `--agent-surface copilot|generic|all` and make
   the default preserve the current Copilot-only installation behavior.
5. Add a portability validator that compares required rules across generated
   surfaces: phase transitions, prohibited actions, named validation commands,
   evidence requirements, and escalation behavior.
6. Update documentation to identify which capabilities are editor-specific,
   including subagent delegation and interactive file-approval UX, and which
   capabilities remain portable through scripts and checked-in evidence.
7. Test generation, regeneration, user edits, template updates, and conflict
   handling. Never overwrite a project-owned manually maintained adapter
   without an explicit update command and diff preview.

**Completion criteria:**

- A target can run the deterministic gates without VS Code or Copilot.
- Generated agent surfaces produce equivalent phase and permission decisions
  for the same fixture inputs.
- A change to the canonical contract causes a portability validation failure
  until all selected projections are regenerated.
- The documentation does not claim feature parity where an adapter lacks
  interactive delegation or editor-specific capabilities.

#### CG-6. Distribution and Upgrade Experience (P2)

**Objective:** Make installation, version pinning, diagnostics, and safe updates
as easy as the current scripts are reliable.

**Implementation tasks:**

1. Publish the repository as a versioned GitHub template and release archive
   with a changelog, checksum, supported installer versions, and a documented
   compatibility policy. Keep the source repository usable for authoring.
2. Define one user-facing CLI contract, for example:
   `sdlc init`, `sdlc update`, `sdlc doctor`, `sdlc diff`, and `sdlc validate`.
   The existing PowerShell and Bash installers may remain compatibility
   wrappers, but they must delegate to the same manifest and ownership logic.
3. Record the installed template version, extension versions, manifest hash,
   source revision, and platform in `.sdlc/sdlc-installer-state.json`.
4. Implement `doctor` checks for missing runtimes, unsupported shell versions,
   manifest drift, conflicting project-owned files, invalid configuration,
   stale generated projections, and incomplete extension setup.
5. Implement `diff` and dry-run output before update. Updates may refresh only
   unchanged template-owned files by default; modified template-owned files
   require an explicit conflict decision and project-owned files are never
   overwritten automatically.
6. Add extension compatibility metadata and reject incompatible combinations
   before writing files. Keep update and rollback evidence under `.sdlc/`.
7. Test clean installation, repeat installation, pinned version installation,
   upgrade across two releases, downgrade/rollback, conflict preservation,
   extension removal, path traversal, and both supported operating systems.

**Completion criteria:**

- A new adopter can install a pinned version, see a dry-run, validate the
  result, and identify the next configuration steps with one documented flow.
- Updates are reversible and cannot overwrite project-owned `docs/spec.md` or
  `.github/sdlc-config.yml`.
- The CLI, PowerShell wrapper, and Bash wrapper produce the same plan and
  ownership decisions.
- Release artifacts are checksum-verifiable and their manifest matches the
  files installed by the scaffold.

#### CG-7. DORA and AI Outcome Metrics (P2)

**Objective:** Make Phase 7 comparable with established delivery measurement
practice while retaining the repository's privacy and outcome-first design.

Add a versioned `measurement.model` such as `dora-ai-v1`. Define every metric
with an owner, numerator, denominator, event source, cohort, time window,
missing-data rule, retention period, and privacy classification.

**Required delivery metrics:**

- **Deployment frequency:** successful production deployments per service and
  reporting period, excluding retries and non-production deployments.
- **Lead time for changes:** elapsed time from the first commit included in a
  production deployment to that deployment's successful completion. Record the
  source and deployment IDs used to calculate it.
- **Change failure rate:** percentage of production deployments that require a
  rollback, hotfix, failed release, or incident within the configured window.
- **Time to restore service:** elapsed time from a production-impacting failure
  being detected to service restoration, with paused time defined explicitly.
- **Reliability and quality supplements:** escaped defects, security findings
  by severity, flaky-test rate, rollback rate, and SLO attainment.

**Required AI-assisted delivery metrics where applicable:** complete-evidence
rate, agent-suggested defect rate, human rework rate, review acceptance rate,
scope-drift rate, validation pass rate, policy-violation rate, average review
cycles, and time saved or added as measured by a declared method. Do not use
lines of code, prompt count, or agent activity as a standalone productivity
proxy.

**Implementation tasks:**

1. Extend the measurement configuration and catalog with stable metric IDs,
   formulas, event schemas, owners, cohorts, and DORA/AI model version.
2. Define minimal event records that use repository, change, deployment,
   incident, and feature identifiers rather than unnecessary personal data.
   Document how events are joined and how missing or late events are handled.
3. Update baseline and snapshot validators to reject ambiguous formulas,
   missing denominators, unowned metrics, incompatible units, and snapshots
   from the wrong model version.
4. Add a report generator that emits aggregate period summaries, trend deltas,
   confidence or completeness indicators, and links to retained evidence.
5. Add a quarterly review workflow that turns a deteriorating outcome into a
   tracked improvement experiment with hypothesis, intervention, expected
   measure, observed effect, regression check, and decision.
6. Add fixtures for each formula, zero-denominator periods, missing events,
   duplicate deployments, rollback classification, timezone boundaries, and
   privacy-sensitive fields.

**Completion criteria:**

- Two teams using the same model calculate the same metric from equivalent
  events.
- Every published snapshot identifies its model version, cohort, period,
  completeness, owner, and privacy review.
- A process change is not declared effective without an observed outcome and a
  regression check.
- Metrics can be aggregated without retaining prompts, source code, personal
  data, or sensitive model inputs.

#### CG-8. Contract Parser Hardening (P2)

**Objective:** Remove semantic drift and syntax brittleness from the parallel
  PowerShell and Bash contract readers while preserving predictable installation
  on supported platforms.

**Implementation tasks:**

1. Inventory the machine-readable contracts currently parsed by scripts,
   including `docs/spec.md` front matter, `.github/sdlc-config.yml`, extension
   configuration, and future task documents. Document the supported syntax,
   unsupported syntax, and version for each contract.
2. Define a canonical schema and parser interface that returns normalized JSON
   plus source location and validation errors. The interface must preserve
   ordering where it affects task execution and must reject duplicate keys,
   ambiguous scalars, aliases, anchors, unsafe tags, and unexpected fields.
3. Implement one standards-compliant parser path and make both PowerShell and
   Bash validators call it or consume its canonical output. If a runtime or
   parser dependency is required, pin and validate it during `doctor` and fail
   with an actionable message; never silently fall back to a different parser.
4. Keep a narrowly documented zero-dependency compatibility mode only for
   legacy installations, and mark it deprecated with an explicit removal
   version. It must reject syntax that the compatibility parser cannot interpret
   rather than guessing.
5. Add a conformance corpus containing valid and invalid YAML/JSON cases,
   quoting, comments, CRLF, Unicode, duplicate keys, nested structures,
   multiline values, list ordering, and malicious path or command values.
   Compare normalized output and exit decisions across Windows and Linux.
6. Version the contract schemas and provide migration diagnostics. A schema
   change must identify the exact field, migration action, and whether existing
   evidence must be regenerated.
7. Update the authoring guide and compatibility matrix with parser prerequisites,
   supported platforms, failure modes, and the policy for third-party parser
   updates.

**Completion criteria:**

- PowerShell and Bash return identical normalized values and validation results
  for the conformance corpus.
- Unsupported syntax fails clearly; it is never partially parsed or silently
  ignored.
- Duplicate keys and unsafe YAML features are rejected before any task runs.
- A parser or schema update is tested against all existing phase fixtures and
  cannot invalidate evidence without reporting the required migration.

**Dependencies:** Coordinate this work with CG-2 and CG-6. The task graph and
the distribution CLI should use the canonical parser rather than introducing
another format-specific reader.

### Cross-Item Definition of Done

Every competitive-gap item must be piloted in at least one consuming repository
before becoming a default. The pilot must include:

1. A migration or installation path that preserves existing project-owned
   files and evidence.
2. Native Windows and Linux regression coverage for the same decision cases.
3. Machine-readable evidence bound to the evaluated revision and working-tree
   digest.
4. Documentation for configuration, failure recovery, rollback, and removal.
5. An explicit owner, versioned schema or policy, and a deprecation path for
   replaced behavior.

The Supervisor must not make a new capability mandatory merely because its
script exists. Promote it from opt-in to default only after the pilot shows that
the control is usable, produces actionable failures, and does not create
unbounded review or evidence overhead.

## Delivery Principles

- Implement phases incrementally and validate them on a pilot repository before
  making them mandatory for all adopters.
- Keep human approval for irreversible or high-impact actions, even when agents
  can prepare the change or evidence.
- Prefer portable interfaces and configurable tool adapters over hard-coding a
  specific CI service, cloud provider, model vendor, or scanner.
- Make exceptions explicit, time-bound, attributable, and visible to reviewers.
- Do not represent the process as compliant with a standard until required
  controls, evidence, and independent assessment are in place.

## Suggested Implementation Sequence

1. Complete Phase 0 before adding further automation; otherwise new gates can
   be bypassed by inconsistent workflow state.
2. Complete Phase 1 next so every project has reproducible evidence for the
   existing build and test gates.
3. Add Phase 2 and Phase 3 together for repositories that ship production
   software, starting with the highest-risk services.
4. Add Phase 4 before broad production rollout and Phase 5 before granting
   coding agents access to sensitive repositories or external tools.
5. Apply Phase 6 only to AI-enabled products, beginning with an impact
   assessment and evaluation baseline before implementing runtime controls.
6. Start Phase 7 measurements during the pilot and use them to prioritize the
   next increments rather than treating this document as a fixed checklist.
7. For post-Phase 7 competitive gaps, implement CG-1 and CG-2 first so feature
   concurrency and task-level scope exist before strengthening verification or
   autonomy. Pilot CG-3 and CG-4 next, then deliver portability, distribution,
   measurement-model, and parser work as separate versioned increments.