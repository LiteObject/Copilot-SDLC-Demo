# Future Implementation Roadmap

> Status: Proposed
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

## Phase 3: Release, Deployment, and Supply-Chain Assurance

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

## Phase 7: Measurement and Continuous Improvement

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