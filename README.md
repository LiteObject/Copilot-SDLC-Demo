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
release and operational controls, AI-agent governance, and the lifecycle controls
needed when the product itself uses AI.

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
│  │  └─ scripts/                   <- phase and scope validation scripts
│  └─ extensions/                   <- opt-in target capabilities
│     ├─ deployment-readiness/
│     ├─ frontend/
│     └─ github-actions/
├─ tools/
│  ├─ scaffold-sdlc.ps1             <- Windows/PowerShell installer
│  └─ scaffold-sdlc.sh              <- Bash installer
├─ docs/
│  ├─ architecture/agent-design.md <- authoring and orchestration design
│  └─ roadmap.md                    <- future implementation roadmap
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

# Add frontend UX and accessibility guidance
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension frontend
```

```bash
# macOS / Linux / WSL
./tools/scaffold-sdlc.sh ../my-project

# Add frontend UX and accessibility guidance
./tools/scaffold-sdlc.sh ../my-project --extension frontend
```

The installers discover files under `template/base` and selected extension
directories, preserve project-owned files, and record hashes in
`.sdlc/sdlc-installer-state.json`. On later runs, `-Force` or `--force` refreshes
only unchanged template-owned files. `.github/sdlc-config.yml` and `docs/spec.md`
are project-owned after installation and are never overwritten. The installers
do not create `src/` or `tests/`.

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

- **Stack, test command, linting:** edit `.github/sdlc-config.yml` in the consuming repo. The source default is [template/base/.github/sdlc-config.yml](template/base/.github/sdlc-config.yml).
  Every agent reads this file. Set `languages`, `frameworks`, `testing.command`,
  `linting.commands`, and `conventions` to match your project.
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
- **Default tech stack:** note your preferences in the installed
  `.github/copilot-instructions.md` and `.github/sdlc-config.yml` in the
  consuming repo so every agent obeys them. The source default is
  [template/base/.github/copilot-instructions.md](template/base/.github/copilot-instructions.md).

### Starting a new feature

The installed `docs/spec.md` is the tracked source of truth. The template source
is [template/base/docs/spec.md](template/base/docs/spec.md). For a fresh feature,
reset its **Current State** to `GATHERING_REQS` and clear the Goal, Requirements,
Design, Plan, and Test Results sections — the supervisor refills them as it works.

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
> [template/base/.github/copilot-instructions.md](template/base/.github/copilot-instructions.md) apply to every
> agent (an `AGENTS.md` at the repo root is an equivalent alternative this repo
> does not use).

## License

MIT — see [LICENSE](LICENSE). The customization files are examples; reuse and adapt them freely.
