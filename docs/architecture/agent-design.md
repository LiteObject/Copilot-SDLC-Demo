# Building an End-to-End SDLC Experience with GitHub Copilot Customization

A design and planning document for orchestrating requirement gathering, planning, coding, testing, and bug-fixing through a multi-agent setup built entirely on **GitHub Copilot's native customization features** (custom agents, subagents, instructions, and prompt files).

> **Status:** Implemented. The reusable payload is authored under `template/base/` (see [README.md](../../README.md)).
> **Chosen approach:** Copilot customization (in-editor, no backend service).
> **Last updated:** 2026-06-26

---

## 1. Goal

Create a Copilot-driven experience that walks a project through the full software development lifecycle (SDLC):

1. **Gather requirements** (clarify scope, ask questions)
2. **Design** (user flows, screen states, accessibility — frontend projects only)
3. **Plan** (architecture, file structure, tech stack)
4. **Write code** (implement files)
5. **Test** (unit tests, edge cases)
6. **Fix bugs** (cyclic feedback loop: code → test → fail → fix)

---

## 2. Architecture Decision: Multi-Agent Behind a Single Interface

Use a **multi-agent orchestration flow** wrapped behind a **single user-facing entry point** (a *Supervisor / Router* pattern).

### Why multi-agent instead of one mega-prompt

A single LLM prompt trying to gather requirements, write full-stack code, run tests, and debug will hit:

- **Context-window exhaustion**
- **Hallucination**
- **Task drift**

Splitting the problem into specialized roles produces better, more focused results.

### The specialized roles

| Agent | Responsibility |
|-------|----------------|
| **Product Manager (PM)** | Requirement gathering, scope definition, clarifying questions |
| **Designer (UI/UX)** | *(Frontend projects only)* Turns requirements into user flows, screen states, layout, design tokens, and accessibility requirements |
| **Architect** | Turns finalized requirements into file structure, implementation map, and tech-stack decisions |
| **Developer** | Writes/edits files, produces clean code |
| **Reviewer** | Reviews the Developer's code for quality, security, and standards adherence before testing |
| **QA / Tester** | Writes unit tests, reviews edge cases, runs tests, reports failures |

### Supervisor / Worker pattern

The user interacts only with the **Supervisor**. The Supervisor tracks overall project **state** and routes the task to the right worker:

```
State: GATHERING_REQS  →  [DESIGN]  →  PLANNING  →  CODING  →  REVIEW  →  TESTING  →  [DEPLOYMENT_READINESS]  →  DONE
```

`DESIGN` is optional and runs only for frontend or UI-heavy projects; non-UI projects skip from `GATHERING_REQS` straight to `PLANNING`.

```
[User Input]
     │
     ▼
┌──────────────┐      No      ┌─────────────────────────┐
│ Reqs Clear?  ├─────────────►│ PM Agent:               │
└──────┬───────┘              │ Ask clarifying question │
       │ Yes                  └─────────────────────────┘
       ▼
┌──────────────────────┐   frontend only
│ UI-heavy project?    ├──────────────┐
└──────┬───────────────┘              ▼
       │ no UI            ┌──────────────────────┐
       │                 │ Designer Agent:       │
       │                 │ Flows, states, a11y   │
       │                 └──────┬───────────────┘
       ▼◄───────────────────────┘
┌──────────────────────┐
│ Architect Agent:     │
│ Create Spec & Files  │
└──────┬───────────────┘
       ▼
┌──────────────────────┐
│ Developer Agent:     │
│ Implement Code Blocks│
└──────┬───────────────┘
       ▼
┌──────────────────────┐│ Reviewer Agent:      │
│ Review Code Quality  │
└──────┬──────────────┘
       │ Changes requested
       ▼
   (back to Developer Agent for a patch)
       │ Approved
       ▼
┌──────────────────────┐│ QA Agent:            │
│ Write & Run Tests    │
└──────┬───────────────┘
       │ Fail
       ▼
   (back to Developer Agent for a patch)
```

---

## 3. Why Copilot Customization (and Not a Custom Extension)

The SDLC loop needs to **edit files** and **run tests** directly in the workspace. That capability lives in the **in-editor surface**, not in a webhook-based GitHub Copilot Extension.

A custom GitHub Copilot Extension (GitHub App + webhook backend) would:

- Respond **into chat over SSE** only.
- **Not** get free local file-editing or "click to accept creating `server.js`" on disk.
- Require backend infrastructure (web service, state store, auth) to operate and secure.

By contrast, **Copilot customization** runs inside VS Code's agent mode and provides **native file-edit and test-execution access** with **no backend to build or maintain**. This is why it is the chosen approach.

---

## 4. Implementation Approach: Copilot Customization

This maps the multi-agent design onto Copilot's **native** features — no web service, no Redis, no webhooks.

| Design concept | Implementation |
|----------------|----------------|
| **Supervisor** | A custom agent (`.agent.md`) that owns and applies validator-approved state transitions (`GATHERING_REQS → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS]`) |
| **PM worker** | Subagent for requirements / clarifying questions |
| **Designer worker** | Subagent for UI/UX flows, screen states, and accessibility (frontend projects only) |
| **Architect worker** | Subagent for file structure + tech-stack spec |
| **Developer worker** | Subagent that writes/edits files |
| **Reviewer worker** | Subagent that reviews code for quality, security, and standards before testing |
| **QA worker** | Subagent that writes tests, runs them, reports failures |
| **Shared rules** | `.github/copilot-instructions.md` + `.instructions.md` files with conventions all agents obey (an `AGENTS.md` at the repo root is an equivalent alternative this repo does not use) |
| **State** | Lives in a tracked spec/todo file; YAML front matter is authoritative and the visible Markdown sections are human-readable evidence |
| **Repeatable kickoffs** | Prompt files (`.prompt.md`) such as "start new feature" |
| **Test/fix loop** | QA agent runs the suite in the integrated terminal, feeds failures back to the Developer agent |
| **Full autonomy (optional)** | Push to GitHub and hand off to the Copilot coding agent for PR-based fixes |

### Why this approach

- Lowest effort to a working SDLC loop.
- Native workspace edit + terminal/test execution.
- No backend infrastructure to operate or secure.
- All artifacts are version-controlled markdown that lives with the repo.

---

## 5. Repository and Payload Layout

The repository is both the authoring workspace and the source for installations.
Only the payload under `template/base/` and selected extensions are copied into a
consuming repository:

```
template/
       manifest.yml                         # payload, extension, and ownership contract
       base/                                 # always-installed target-relative files
              .github/
                     copilot-instructions.md
                     agents/
                     instructions/
                     prompts/
                     sdlc-config.yml
              docs/spec.md
              scripts/check-phase.*
              scripts/migrate-spec.*
              scripts/validate-sdlc-config.*
              scripts/run-sdlc-task.*
              scripts/run-security-scans.*
              scripts/scope-audit.*
       extensions/
              frontend/.github/instructions/
              deployment-readiness/.github/instructions/
              github-actions/.github/workflows/
              release-assurance/.github/workflows/
              release-assurance/.github/instructions/
              release-assurance/scripts/
              operational-readiness/.github/workflows/
              operational-readiness/.github/instructions/
              operational-readiness/docs/
              operational-readiness/scripts/
              ai-governance/.github/workflows/
              ai-governance/.github/instructions/
              ai-governance/docs/
              ai-governance/scripts/
              ai-lifecycle/.github/workflows/
              ai-lifecycle/.github/instructions/
              ai-lifecycle/docs/
              ai-lifecycle/scripts/
tools/
       scaffold-sdlc.ps1                    # Windows/PowerShell installer
       scaffold-sdlc.sh                     # Bash installer
```

The authoring repository also runs the Phase 0 and Phase 1 validator, migration,
and task suites from `.github/workflows/phase0-validation.yml` and
`.github/workflows/phase1-validation.yml` on native Ubuntu and Windows runners.
Phase 3 release-bundle tests run from `.github/workflows/phase3-validation.yml`.

After installation, `template/base/.github/agents/` becomes `.github/agents/`
at the target root. The base payload remains independent of a specific language
or cloud. Frontend UX, deployment readiness, and GitHub Actions are opt-in
extensions so a target repository receives only the capabilities it selects.

---

## 6. Components

### 6.1 Supervisor agent
- Owns the state machine: `GATHERING_REQS → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS] → DONE`.
- Decides which worker to delegate to based on current state and user input.
- Maintains a tracked spec/todo file as the source of truth for project state.
- Records gate command, result, exit code, timestamp, revision, and evidence, then runs `check-phase` before applying a transition.
- Is the only agent allowed to mutate `current_phase`, `review_cycle`, gate records, and `last_transition_*` metadata.

### 6.2 PM agent
- Gathers and clarifies requirements.
- Asks targeted questions until scope is clear; writes finalized requirements to the spec file.
- Routes to the Designer (frontend projects) or straight to the Architect (non-UI projects).

### 6.3 Designer agent *(frontend projects only)*
- Converts finalized requirements into user flows, screen states, layout, design tokens, and accessibility requirements.
- Writes a **Design** section to the spec file that the Architect and Developer build against; chooses no frameworks or file structure.

### 6.4 Architect agent
- Converts finalized requirements (and the Design section, if present) into a file structure, implementation map, and tech-stack decisions.
- Produces the plan the Developer agent will follow.

### 6.5 Developer agent
- Implements/edits files according to the Architect's plan.
- Produces clean, idiomatic code; makes only the changes required.

### 6.6 Reviewer agent
- Reviews the Developer's code against the coding standards and security (OWASP Top 10) concerns.
- For UI code, checks the implementation against the Design section and the frontend UX & accessibility standards.
- Checks spec fidelity and maintainability; approves or routes specific change requests back to the Developer via the Supervisor.
- Returns `PASS` or `CHANGES_REQUESTED` with revision-bound evidence; it does not mutate workflow state.

### 6.7 QA agent
- Writes unit tests and covers edge cases.
- Runs the test suite in the integrated terminal.
- Reports failures back so the Supervisor can route to the Developer agent for a patch.
- Returns `PASS` or `FAIL` with revision-bound evidence; it does not mark the workflow `DONE`.

### 6.8 Shared rules & prompts
- `copilot-instructions.md`: conventions every agent obeys (this repo's shared-rules file; an `AGENTS.md` at the repo root is an equivalent alternative).
- `.instructions.md` files scoped via `applyTo` for coding, testing, optional frontend UX, and optional deployment-readiness standards.
- `.prompt.md` files for repeatable kickoffs (new feature, fix failing tests).

### 6.9 Configured validation
- `.github/sdlc-config.yml` uses schema version 1 and a named task registry with structured executable/args records.
- `validate-sdlc-config` validates package-manager compatibility, manifests, test directories, task completeness, and executable availability.
- `run-sdlc-task` invokes the same named tasks locally and in CI, retaining logs and JSON evidence tied to the source revision.

### 6.10 Quality and secure development
- The Architect records risk profile, required test layers, acceptance-criterion mappings, and security-design impacts in `docs/spec.md` before coding.
- The Reviewer runs configured security tasks through `run-security-scans`, which emits machine-readable findings and blocks configured severities.
- QA adds risk-selected and negative security coverage rather than assuming every feature needs only unit tests.

### 6.11 Release assurance
- The opt-in `release-assurance` extension validates release configuration and creates a checksum-bound artifact manifest, SBOM, and SLSA-style provenance statement.
- GitHub environments provide human approval for staging and production promotion; smoke tests gate each promotion.
- A separate manual workflow invokes the configured rollback task and retains the incident reference and evidence.

### 6.12 Operational readiness
- The opt-in `operational-readiness` extension validates service ownership, health endpoints, structured logs, metrics, traces, correlation identifiers, SLIs, SLOs, review items, runbooks, and incident policy.
- `run-operational-readiness` executes health, telemetry, and post-release checks and can run a staging failure drill that blocks on alert, diagnosis, or rollback failure.
- `record-production-outcome` and `record-incident-review` retain technical health, business outcome, user feedback, incident severity, and corrective-action evidence under `.sdlc/evidence/`.
- A scheduled and manually triggered workflow uploads the evidence and keeps the staging failure drill repeatable.

### 6.13 AI-assisted development governance
- The opt-in `ai-governance` extension validates approved providers, models, tenants, repositories, data classifications, tools, MCP servers, network destinations, credential scopes, phase grants, sandbox requirements, and untrusted-input controls.
- `record-ai-change` rejects non-allowlisted boundaries and restricted actions without an explicit human approval, then appends task, agent, model, instruction, grant, tool-call, file, validation, approval, and disposition evidence to a JSONL ledger.
- `run-ai-governance` executes the configured representative and adversarial evaluation task, records revision-bound results, and can update the `gate_ai_governance_*` fields in `docs/spec.md`.
- The extension instructions treat repository content, issue text, web pages, retrieved documents, model output, and tool output as untrusted data. The workflow retains validation and evaluation evidence without granting write or deployment permissions.

### 6.14 AI product lifecycle governance
- The opt-in `ai-lifecycle` extension applies only to products that expose or depend on AI; AI-assisted coding alone does not enable it.
- `validate-ai-lifecycle` checks the impact assessment, versioned system inventory, evaluation and red-team plans, risk disposition, runtime controls, monitoring, rollback, decommissioning, model card, and system card.
- `run-ai-lifecycle` executes configured evaluation, red-team, and production-exercise tasks, writes the configured evaluation report plus lifecycle evidence, and records `gate_ai_lifecycle_*` in `docs/spec.md`.
- The lifecycle instructions require material-change reevaluation, risk-proportionate red teaming, runtime authorization and safety controls, production monitoring, kill-switch or rollback evidence, and user-appropriate limitations, data-use, support, and appeal documentation.

---

## 7. Test / Fix Loop

1. **QA agent** runs the test suite in the integrated terminal and records a gate result.
2. On failure, it captures the error output and reports it to the **Supervisor**.
3. The Supervisor validates `TESTING → CODING` and routes the failure to the **Developer agent** to issue a patch.
4. Loop repeats (`CODING → REVIEW → TESTING`) until tests pass; the Supervisor then validates either `TESTING → DEPLOYMENT_READINESS` or `TESTING → DONE`.
5. **Optional full autonomy:** push to GitHub and assign the issue to the **Copilot coding agent**, which opens a PR, lets CI run, and iterates on fixes.

---

## 8. Resources

- **VS Code Copilot customization:** custom agents (`.agent.md`), subagents, instructions (`.instructions.md`), prompt files (`.prompt.md`), and `copilot-instructions.md` (or an equivalent `AGENTS.md`).
- **GitHub Copilot coding agent:** for optional autonomous test-and-fix-via-PR once the repo is on GitHub.

---

## 9. Resolved Decisions

- [x] The tracked spec/state file lives at `docs/spec.md`.
- [x] Target folder conventions: agents in `.github/agents/`, instructions in `.github/instructions/`, prompts in `.github/prompts/`; authored under `template/base/`.
- [x] A `REVIEW` phase and Reviewer agent sit between `CODING` and `TESTING`.
- [ ] Target tech stacks the Architect/Developer agents should default to (left to each project).
- [ ] Test framework(s) the QA agent should standardize on (left to each project).
- [ ] Whether to wire in the GitHub Copilot coding agent for autonomous PR fixes (optional, per project).
