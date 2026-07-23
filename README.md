# Copilot SDLC Template Authoring Repository

This repository authors a reusable **end-to-end SDLC experience** using only
GitHub Copilot's native customization features. It is the template source and
maintenance workspace, not a consumer application repository.

It implements the **Supervisor / Worker** multi-agent pattern described in
[docs/architecture/agent-design.md](docs/architecture/agent-design.md):

```
@sdlc-supervisor  (entry point, owns the state machine)
   ├── pm          → gather & clarify requirements
   ├── designer    → user flows, states & accessibility (frontend only)
   ├── architect   → spec, file structure, tech stack
   ├── developer   → write / edit code
   ├── reviewer    → review code for quality & security
   └── qa          → write & run tests, report failures
```

## Loop Engineering — the design philosophy

This workspace is built on **loop engineering**: the practice of designing a
system that prompts your agents for you, rather than prompting them turn by turn
yourself. A well-engineered loop discovers work, hands tasks to agents, verifies
results, persists state, and decides the next action — on a schedule or until a
goal is met — while you stay in control of anything irreversible.

### The five pieces of a loop (and how we implement them)

| Piece | What it means | Our implementation |
|---|---|---|
| **Automations** | Work that runs on a schedule, discovers and triages without you | The SDLC Supervisor state machine advances phases automatically; prompts like `start-new-feature` and `fix-failing-tests` kick off loops |
| **Worktrees** | Parallel agents isolated so they don't collide | Each subagent works in its own bounded phase with a clean context; the scope audit prevents cross-domain contamination |
| **Skills** | Project knowledge written down once, read by every agent | Base `.github/instructions/` files codify coding, testing, and scope rules; UX and deployment-readiness guidance are extensions |
| **Sub-agents** | One agent ideates or implements; a different one checks the work | PM → Architect → Developer → Reviewer → QA chain ensures no agent grades its own output |
| **State file** | Memory that survives between runs, outside any single conversation | The installed `docs/spec.md` is the version-controlled source of truth tracking phase, requirements, plan, findings, and test results |

The same pattern appears across the industry — automations for heartbeat,
worktrees for isolation, skills for compounding knowledge, sub-agents for the
maker/checker split, and a state file as the spine. The names vary but the
architecture is the same.

---

## How the SDLC maps to AI agents

The classic software development lifecycle is run by a team of specialized AI
agents instead of one general-purpose prompt. Each agent owns one phase, does its
work, and records the result in the installed
[`docs/spec.md`](template/base/docs/spec.md) so the next agent has
a shared, version-controlled source of truth. A human stays in the loop —
reviewing and accepting file edits and test runs — so this assists your SDLC
rather than running unattended.

| SDLC phase | Agent | Writes to `docs/spec.md` |
|------------|-------|--------------------------|
| Requirements | **PM** | Goal, requirements, acceptance criteria, out-of-scope |
| Design (frontend only) | **Designer** | Screens & flows, states, design tokens, accessibility |
| Plan | **Architect** | Tech stack, file structure, implementation plan |
| Code | **Developer** | Checks off plan items as files land in `src/`; verifies build |
| Review | **Reviewer** | Review verdict, scope audit, and findings; changes loop back to Developer |
| Test & Fix | **QA** | Test command and results; failures loop back to Developer |
| Deployment Readiness _(optional)_ | **Reviewer** | Pre-deploy checklist: build, tests, secrets, config, deps, cleanup |

The **Supervisor** owns the `GATHERING_REQS → [DESIGN] → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS] → DONE` state
machine and routes work to the right agent. The optional `DESIGN` phase runs only
for frontend or UI-heavy projects. `DEPLOYMENT_READINESS` is an optional pre-merge
gate that validates build, security, and configuration before marking the feature done. For the full rationale (why split the
work, and why Copilot customization over a backend), see
[docs/architecture/agent-design.md](docs/architecture/agent-design.md).

## Future Roadmap

The current implementation is a lightweight, human-supervised AI-assisted SDLC
template. [docs/roadmap.md](docs/roadmap.md) defines the dependency-ordered work
needed to add enforceable workflow gates, wider quality and security validation,
release and operational controls, lifecycle controls needed when the product
itself uses AI, and distribution and upgrade controls. Phases 0 through 12 are
implemented; optional extensions remain opt-in where their product or process
controls apply.

## Repository layout

The repository separates reusable target content from authoring and optional
integration content:

```
Copilot-SDLC-Demo/
├─ template/
│  ├─ manifest.yml                  <- template contract and ownership rules
│  ├─ base/                         <- installed into every target repository
│  │  ├─ .github/                   <- agents, base instructions, prompts, config
│  │  ├─ docs/spec.md               <- installed project state template
│  │  └─ scripts/                   <- phase, config, task, migration, surface, and scope validation scripts
│  └─ extensions/                   <- opt-in target capabilities
│     ├─ deployment-readiness/
│     ├─ frontend/
│     ├─ github-actions/
│     ├─ release-assurance/
│     ├─ operational-readiness/
│     ├─ ai-governance/
│     ├─ ai-lifecycle/
│     └─ measurement/
├─ tools/
│  ├─ scaffold-sdlc.ps1             <- Windows/PowerShell installer
│  ├─ scaffold-sdlc.sh              <- Bash installer
│  ├─ sdlc.py                       <- distribution CLI entry point
│  ├─ sdlc.ps1                      <- PowerShell CLI wrapper
│  └─ sdlc.sh                       <- Bash CLI wrapper
├─ docs/
│  ├─ architecture/agent-design.md <- authoring and orchestration design
│  ├─ guides/distribution-upgrades.md <- CG-6 installation and update contract
│  └─ roadmap.md                    <- future implementation roadmap
├─ tests/phase0/                    <- authoring-repository workflow fixtures and harnesses
├─ tests/phase1/                    <- config and named-task validation harnesses
├─ tests/phase2/                    <- quality and security policy harnesses
├─ tests/phase3/                    <- release assurance harnesses
├─ tests/phase4/                    <- operational readiness harnesses
├─ tests/phase5/                    <- AI governance harnesses
├─ tests/phase6/                    <- AI product lifecycle harnesses
├─ tests/phase7/                    <- measurement and continuous-improvement harnesses
├─ tests/phase8/                    <- feature-scoped workflow harnesses
├─ tests/phase9/                    <- task graph and task-level evidence harnesses
├─ tests/phase10/                   <- meaningful verification gate harnesses
├─ tests/phase11/                   <- portable agent surface harnesses
├─ tests/phase12/                   <- distribution and upgrade harnesses
├─ .github/copilot-instructions.md  <- authoring-repository rules
├─ README.md                        <- this file
└─ LICENSE
```

The payload preserves target-relative paths. For example,
`template/base/.github/agents/` becomes `.github/agents/` in a consuming
repository. The installers do not create `src/` or `tests/`; those directories
belong to the consuming project's own stack.

## Prerequisites

- **VS Code** recent enough to support custom agents (`.agent.md`) and subagents.
- An active **GitHub Copilot** subscription with **agent mode** enabled.
- Custom agents/subagents enabled in settings. If `@sdlc-supervisor` does not
  appear in the chat agent picker, enable custom agents and **reload the window**
  (Command Palette → *Developer: Reload Window*).
- **Bash 4 or newer** for the shell installer (`tools/scaffold-sdlc.sh`); use
  PowerShell on Windows if Bash is unavailable.
- A generic agent surface does not require VS Code or Copilot. It uses the
  portable contract and the installed deterministic scripts.

## Use the generated workflow

After installing the payload into a target repository:

1. Open the target repository as a workspace in VS Code.
2. In Copilot Chat, select the **`sdlc-supervisor`** agent (or type `@sdlc-supervisor`).
3. Describe what you want to build, e.g. *"Build a todo REST API."*
4. The supervisor walks the project through
  `GATHERING_REQS → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS] → DONE`,
  delegating to each worker and keeping `docs/spec.md` up to date as the
  single source of truth.

Or jump straight to a step with a prompt: type `/` in chat and pick
**start-new-feature** or **fix-failing-tests**.

## Install it in your own project

Use one of the installers to copy the base payload into a new or existing
repository. Optional extensions are selected explicitly.

### Quick scaffold (script)

From a clone of this repo, run the script for your shell and point it at a target
folder:

```powershell
# Windows / PowerShell
./tools/scaffold-sdlc.ps1 -Target ../my-project

# Add the generated generic AGENTS.md surface
./tools/scaffold-sdlc.ps1 -Target ../my-project -AgentSurface generic

# Install and validate both Copilot and generic surfaces, updating adapters only
# through an explicit diff-previewing command when needed
./tools/scaffold-sdlc.ps1 -Target ../my-project -AgentSurface all -UpdateAgentSurface

# Fail adoption until the project's named validation tasks are configured
./tools/scaffold-sdlc.ps1 -Target ../my-project -ValidateConfig

# Add frontend UX and accessibility guidance
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension frontend

# Add artifact, SBOM, provenance, promotion, smoke-test, and rollback controls
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension release-assurance

# Add observability, service objectives, incident, runbook, and feedback controls
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension operational-readiness

# Add AI-assisted development governance and audit controls
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension ai-governance

# Add lifecycle controls for an AI-enabled product
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension ai-lifecycle

# Add outcome measurement and continuous-improvement controls
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension measurement
```

```bash
# macOS / Linux / WSL
./tools/scaffold-sdlc.sh ../my-project

# Add the generated generic AGENTS.md surface
./tools/scaffold-sdlc.sh ../my-project --agent-surface generic

# Install and validate both Copilot and generic surfaces, explicitly updating
# adapters only after the installer previews their diffs
./tools/scaffold-sdlc.sh ../my-project --agent-surface all --update-agent-surface

# Fail adoption until the project's named validation tasks are configured
./tools/scaffold-sdlc.sh ../my-project --validate-config

# Add frontend UX and accessibility guidance
./tools/scaffold-sdlc.sh ../my-project --extension frontend

# Add artifact, SBOM, provenance, promotion, smoke-test, and rollback controls
./tools/scaffold-sdlc.sh ../my-project --extension release-assurance

# Add observability, service objectives, incident, runbook, and feedback controls
./tools/scaffold-sdlc.sh ../my-project --extension operational-readiness

# Add AI-assisted development governance and audit controls
./tools/scaffold-sdlc.sh ../my-project --extension ai-governance

# Add lifecycle controls for an AI-enabled product
./tools/scaffold-sdlc.sh ../my-project --extension ai-lifecycle

# Add outcome measurement and continuous-improvement controls
./tools/scaffold-sdlc.sh ../my-project --extension measurement
```

The installers discover files under `template/base` and selected extension
directories, preserve project-owned files, and record hashes in
`.sdlc/sdlc-installer-state.json`. Before writing anything, they validate that
`template/base` matches the `base.installs` list in `template/manifest.yml` and
stop if the two have drifted. On later runs, `-Force` or `--force` refreshes
only unchanged template-owned files. `.github/sdlc-config.yml` and `docs/spec.md`
are project-owned after installation and are never overwritten. The installers
do not create `src/` or `tests/`. The default `copilot` surface preserves the
existing Copilot-only behavior. `generic` adds a generated root `AGENTS.md`,
and `all` selects both adapters. Generated adapters include the template version
and portable-contract hash; modified or pre-existing adapters are preserved by
default. Use `-UpdateAgentSurface` or `--update-agent-surface` to preview and
explicitly replace one, then run the installed portability validator.

### Distribution and upgrades

The versioned distribution CLI is the common contract behind both scaffold
wrappers. Run it from the authoring checkout for installation, previews,
updates, and release creation:

```powershell
python tools/sdlc.py init --target ../my-project --version 1.0.0
python tools/sdlc.py diff --target ../my-project --version 1.0.0
python tools/sdlc.py doctor --target ../my-project --source .
python tools/sdlc.py validate --target ../my-project --source .
python tools/sdlc.py update --target ../my-project --source ../template-1.1.0 --version 1.1.0
python tools/sdlc.py rollback --target ../my-project
python tools/sdlc.py release --output-dir dist
```

The Bash equivalents use `python3`. The compatibility commands
`tools/scaffold-sdlc.ps1` and `tools/scaffold-sdlc.sh` delegate to the same
planner and ownership rules. The full compatibility policy, pinned-install
flow, dry-run behavior, conflict handling, rollback evidence, and checksum
verification are documented in
[docs/guides/distribution-upgrades.md](docs/guides/distribution-upgrades.md).

### Portable agent surfaces

The installed [portable agent contract](template/base/docs/portable-agent-contract.md)
defines phase transitions, the schema, named gate commands and task IDs,
permission rules, prohibited actions, evidence records, and escalation behavior.
The Copilot instructions are an editor-specific adapter; subagent delegation and
interactive approval UX are not available on every surface. The generic adapter
uses the same contract and scripts, so it can run deterministic gates without
VS Code or Copilot.

Validate the selected projections after installation:

```powershell
./scripts/validate-agent-surfaces.ps1 -AgentSurface copilot
./scripts/validate-agent-surfaces.ps1 -AgentSurface generic
./scripts/validate-agent-surfaces.ps1 -AgentSurface all
```

```bash
./scripts/validate-agent-surfaces.sh --agent-surface copilot
./scripts/validate-agent-surfaces.sh --agent-surface generic
./scripts/validate-agent-surfaces.sh --agent-surface all
```

When the canonical contract changes, validation fails until the selected
projection is regenerated. Review the diff and run
`scripts/generate-agent-surfaces.ps1 -Update` or
`scripts/generate-agent-surfaces.sh --update` for the generic adapter; use the
scaffold's explicit update option for the Copilot adapter. Validation writes
`.sdlc/evidence/agent-surfaces.json`.

When the `operational-readiness` extension is enabled, configure the service
owner, on-call route, telemetry, SLIs/SLOs, review documents, runbooks, and
named operational tasks in `.github/sdlc-config.yml`. Run
`scripts/validate-operational-readiness.ps1` or `.sh`, then
`scripts/run-operational-readiness.ps1 -RecordSpec` or
`scripts/run-operational-readiness.sh --record-spec`. Use the failure-drill
switch in staging before production promotion, and record the technical and
business outcome plus any incident review under `.sdlc/evidence/`.

When the `ai-governance` extension is enabled, configure approved providers,
models, tenants, repositories, data classifications, tools, MCP servers,
network destinations, credential scopes, phase grants, sandbox requirements,
and the `agent_evaluation` task in `.github/sdlc-config.yml`. Run
`scripts/validate-ai-governance.ps1` or `.sh` before agent work. Record every
agent-mediated change with `record-ai-change.ps1` or `.sh`; restricted actions
and approved final dispositions require a human approval record. Run
`scripts/run-ai-governance.ps1 -RecordSpec` or
`scripts/run-ai-governance.sh --record-spec` before handoff.

When the `ai-lifecycle` extension is enabled, configure the AI impact
assessment, versioned system inventory, evaluation and red-team plans, risk
disposition, runtime controls, monitoring, rollback, and decommissioning
documents. Configure `ai_evaluation`, `ai_red_team`, and
`ai_production_exercise` as structured tasks, then run
`scripts/validate-ai-lifecycle.ps1` or `.sh` and
`scripts/run-ai-lifecycle.ps1 -RecordSpec` or
`scripts/run-ai-lifecycle.sh --record-spec`. The lifecycle gate records
evaluation, red-team, and production-exercise evidence and blocks on failed
quality or safety tasks.

When the `measurement` extension is enabled, configure a named measurement
owner, fixed cadence, baseline and delivery metrics, roadmap outcome and
leading-indicator metrics, retention, privacy review, and the
`measurement_baseline`, `measurement_snapshot`, and `measurement_review` tasks.
Run `scripts/validate-measurement.ps1` or `.sh`, then
`scripts/run-measurement.ps1 -RecordSpec` or
`scripts/run-measurement.sh --record-spec`. Store aggregate snapshots only;
exclude unnecessary personal or sensitive content. The gate retains the task
evidence, validates the configured JSON snapshot, and retains the quarterly
process-review record under `.sdlc/evidence/`. Set
`measurement.require_completion_gate: true` only when measurement must block
the final SDLC transition; the normal cadence does not block every feature.

The core phase validator applies enabled extension gates at their relevant
handoffs. Deployment readiness remains conditional: repositories and features
without CI/CD deployment can keep it disabled and transition directly from
`TESTING` to `DONE` after the applicable non-deployment gates pass.

### Use a repository URL with an agent

You can give an agent the URL of this repository as the template source. Ask it
to clone the source repository if needed and run the scaffold script against the
target repository. The agent needs read access to the source and write access to
the target; a URL does not grant either permission. Private source repositories
also require the agent's GitHub authentication to be available.

Use a prompt such as:

> Use `<repo-url>` as the template source. Copy its reusable `.github`
> customization, `docs/spec.md`, and SDLC validation scripts into this repository
> using the scaffold script. Preserve existing project files, ask before
> overwriting conflicts, and do not copy the demo application or unrelated files.
> Then adapt `.github/sdlc-config.yml` and `docs/spec.md` to this project's stack.

The URL-based workflow is a convenient way to direct an agent, but the scaffold
script remains the source of truth for which files are copied.

### Manual copy

1. Copy the contents of `template/base/` into the root of your repo, preserving
  target-relative paths.
2. Copy a selected extension, such as `template/extensions/frontend/`, over the
  same target root.
3. Treat `.github/sdlc-config.yml` and `docs/spec.md` as project-owned files.
4. Reload the VS Code window so the agents are picked up.
5. Select **`sdlc-supervisor`** and describe what you want to build.

### Adapt it to your stack

Start with the **configuration file** — it is the single place to set stack defaults:

- **Stack and validation tasks:** edit `.github/sdlc-config.yml` in the consuming repo. The source default is [template/base/.github/sdlc-config.yml](template/base/.github/sdlc-config.yml).
  Every agent reads this file. Set `sdlc_config_schema: 1`, the package manager
  and manifest, `testing.framework`/`directories`, and the structured
  `validation`/`tasks` registry. Do not add a shell command string.
- **Models & tools:** edit the YAML frontmatter at the top of each
  `.github/agents/*.agent.md` file.
- **Coding conventions:** edit the installed
  `.github/instructions/coding-standards.instructions.md` in the consuming repo
  (its `applyTo` controls which files it governs). The source default is
  [template/base/.github/instructions/coding-standards.instructions.md](template/base/.github/instructions/coding-standards.instructions.md).
- **Frontend UX & accessibility:** when the `frontend` extension is selected,
  edit the installed `.github/instructions/frontend-ux.instructions.md` to match
  your design system and accessibility target. The source default is
  [template/extensions/frontend/.github/instructions/frontend-ux.instructions.md](template/extensions/frontend/.github/instructions/frontend-ux.instructions.md).
- **Test framework & commands:** edit the `testing` section in
  `.github/sdlc-config.yml` and the installed
  `.github/instructions/testing-standards.instructions.md`. The source default
  is [template/base/.github/instructions/testing-standards.instructions.md](template/base/.github/instructions/testing-standards.instructions.md).
- **Validation compatibility:** see [docs/guides/validation-compatibility.md](docs/guides/validation-compatibility.md) for supported package managers, operating systems, and optional lint/type-check fallback behavior. Run `scripts/validate-sdlc-config.ps1` or `.sh`, then `scripts/run-sdlc-task.ps1 -Task all` or `scripts/run-sdlc-task.sh --task all`.
- **Default tech stack:** note your preferences in the installed
  `.github/copilot-instructions.md` and `.github/sdlc-config.yml` in the
  consuming repo so every agent obeys them. The source default is
  [template/base/.github/copilot-instructions.md.template](template/base/.github/copilot-instructions.md.template).

### Starting a new feature

The installed `docs/spec.md` is the tracked source of truth. The template source
is [template/base/docs/spec.md](template/base/docs/spec.md). For a fresh feature,
reset `current_phase` and the visible **Current State** to `GATHERING_REQS`, set
`review_cycle` to `0`, clear gate records to `NOT_RUN`, and clear the Goal,
Requirements, Design, Plan, and Test Results sections. Only the Supervisor may
apply later transitions after running `scripts/check-phase`.

### Workflow integrity checks

The YAML front matter in `docs/spec.md` records the schema version, enabled
optional gates, revision-bound gate evidence, review-cycle count, exact
`planned_files`, and any approved glob records. The visible Markdown state is
checked against that metadata. Worker agents return results; the Supervisor is
the only agent that changes phase or gate metadata.

Run the authoring-repository regression harnesses with:

```powershell
./tests/phase0/run-tests.ps1
```

```bash
./tests/phase0/run-tests.sh
```

The harnesses exercise both validator variants against the same workflow cases,
including failed gates, stale evidence, CRLF input, review-cycle exhaustion,
exact scope, invalid directory scope, and approved globs.

Phase 2 adds risk-selected test layers, acceptance-criterion mappings, security
design review, configurable security task IDs, and machine-readable blocking
severity evidence. Run `scripts/run-security-scans.ps1 -RecordSpec` or
`scripts/run-security-scans.sh --record-spec` after configuring the security
tasks in `.github/sdlc-config.yml`.

For repositories that ship artifacts, install the `release-assurance` extension.
It adds release configuration validation, artifact checksums, SBOM and
provenance generation, manifest verification, protected-environment promotion,
smoke-test gates, and a manual rollback workflow. Configure the extension only
after setting `release_assurance.enabled: true` and its package/SBOM/deploy/
smoke/rollback tasks.

### Migrate an existing project

The installer preserves an existing project-owned `docs/spec.md`; it does not
silently rewrite legacy state. In the consuming repository, preview the
migration first, then rerun it with explicit confirmation:

```powershell
./scripts/migrate-spec.ps1
./scripts/migrate-spec.ps1 -Force
```

```bash
./scripts/migrate-spec.sh
./scripts/migrate-spec.sh --force
```

Migration preserves the current phase, review cycle, meaningful Design section,
and exact file entries, initializes gate records to `NOT_RUN`, and writes a
backup under `.sdlc/migrations/`. The Supervisor must populate fresh gate
evidence before advancing the migrated workflow.

### Optional: issue-triggered test validation via GitHub

Once the repo is on GitHub, the optional workflow can validate the configured test
command for issues labeled `copilot:fix`. It reports whether validation was
skipped, passed, or failed. The workflow does not itself assign the Copilot coding
agent or create pull requests; configure that integration separately if needed.

> These files are illustrative scaffolding. Adjust tool sets, models, default
> tech stacks, and test frameworks to fit your real project.

## Anatomy of an agent file

Each agent lives in `.github/agents/<name>.agent.md`: YAML frontmatter (its
configuration) followed by a Markdown body (its system prompt). Recreating these
from scratch requires getting the frontmatter right, so the fields are:

| Field | Purpose |
|-------|---------|
| `name` | Display name shown in the chat agent picker. |
| `description` | When to use the agent; how the Supervisor (and VS Code) decide to route to it. |
| `tools` | The capabilities the agent may use. Keep this minimal — it is the agent's permission boundary. |
| `model` | Ordered list of acceptable models (first available is used). |
| `user-invocable` | `false` for workers so users don't call them directly — only the Supervisor delegates to them. Omitted on the Supervisor, which is the entry point. |
| `agents` | (Supervisor only) the subagents it is allowed to delegate to. |
| `argument-hint` | (Supervisor only) placeholder text for the user's first message. |

### Tool grants (and why)

Tools are deliberately scoped so each agent can only do its job. This is a key
part of the design — for example, the Reviewer can run the deterministic scope
audit but cannot edit code, which keeps review and implementation separate.

| Agent | `tools` | Why |
|-------|---------|-----|
| `sdlc-supervisor` | `read, search, edit, todo, agent, bash` | Coordinates the workflow: reads/updates `docs/spec.md` (`edit`), tracks phases (`todo`), delegates (`agent`), and runs the `check-phase` validation script (`bash`). It does not write or execute application code. |
| `pm` | `read, edit, search` | Writes requirements into `docs/spec.md`; no code or test execution. |
| `designer` | `read, edit, search` | Writes the UI/UX design into `docs/spec.md` for frontend projects; no code or test execution. |
| `architect` | `read, edit, search` | Writes the plan into `docs/spec.md`; no code or test execution. |
| `developer` | `read, edit, search, execute` | Writes files under `src/` and may run a command to verify a fix. |
| `reviewer` | `read, search, bash` | Review-only: can read code and run the `scope-audit` validation script, but **cannot** edit application code or tests, enforcing the review/implementation split. |
| `qa` | `read, edit, search, execute` | Writes tests under `tests/` and runs the suite in the terminal (`execute`). |

> All workers set `user-invocable: false`; only `sdlc-supervisor` is invoked
> directly. The shared rules in
> The portable rules in
> [template/base/docs/portable-agent-contract.md](template/base/docs/portable-agent-contract.md)
> apply to every agent. The generated Copilot adapter and optional root
> `AGENTS.md` projection point to that same contract; neither may weaken it.

## License

MIT — see [LICENSE](LICENSE). The customization files are examples; reuse and adapt them freely.
