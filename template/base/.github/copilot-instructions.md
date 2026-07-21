# Project Guidelines

These rules apply to every agent in this workspace (Supervisor, PM, Architect, Developer, Reviewer, QA).

## Configuration

- Stack-specific settings and the versioned named-task registry live in [.github/sdlc-config.yml](sdlc-config.yml). Every agent reads this file to discover project conventions. When adapting this repo to a new stack, edit `sdlc-config.yml` first, then run `scripts/validate-sdlc-config.ps1` or `.sh` before implementation.

## Workflow

- The project moves through the state machine recorded in the YAML front matter of [docs/spec.md](../docs/spec.md): `GATHERING_REQS → [DESIGN] → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS] → DONE`, with explicit review and failure loops. The visible state fields must match the metadata.
- Workers return gate results and evidence; only the Supervisor changes `current_phase`, `review_cycle`, gate records, and `last_transition_*`. Run `scripts/check-phase.ps1` or `scripts/check-phase.sh` with the target phase before every transition.
- Resolve a feature context before reading workflow state when work is feature-scoped. Use `docs/specs/<feature-id>/spec.md`, pass `-FeatureId <id>` / `--feature-id <id>` to every validator, runner, migration, and optional extension, and keep evidence under `.sdlc/evidence/<feature-id>/`. No global active-feature file is permitted; no feature ID preserves legacy `docs/spec.md` behavior.
- Do not skip ahead: code is only written after requirements are clear and a plan exists.
- **Before advancing state**, the Supervisor runs `scripts/check-phase.ps1` (or `.sh`) to validate that prerequisite sections in `docs/spec.md` are populated. Do not advance if the script fails.
- The **Developer must verify the project builds cleanly** before handing off to REVIEW.
- The **Reviewer performs a scope audit** — run `scripts/scope-audit.ps1` (or `.sh`) and report the output. The script compares the actual git diff against the Implementation Plan in `docs/spec.md` and categorizes every changed file as `[IN_SCOPE]`, `[SCOPE_CREEP]`, or `[MISSING]`.
- **Validation uses named tasks** — run `scripts/run-sdlc-task.ps1 -Task build` on Windows or `scripts/run-sdlc-task.sh --task build` elsewhere; use `all` to install dependencies and run required plus configured optional tasks. Task commands are structured executable/args records, never shell strings.

## Code Style

- Prefer small, focused files and functions with clear names.
- Make only the changes required for the current task; avoid unrelated refactors.
- No commented-out code, placeholder TODOs, or unused imports left behind.
- Never hardcode secrets, keys, or tokens — use environment variables or a secrets manager.

## Architecture

- Application code lives in `src/`. Tests live in `tests/`.
- Keep business logic separate from I/O (HTTP handlers, DB access, file system).

## Build and Test

- Tests must pass before a feature is considered done.
- The QA agent runs the test suite in the integrated terminal and reports failures verbatim.
- The Developer must verify a clean build (zero errors) before the REVIEW phase.

## Conventions

- Every change should be traceable to a requirement in [docs/spec.md](../docs/spec.md).
- When requirements are ambiguous, ask the user rather than guessing.

## Instruction Files

Phase-specific standards are in `.github/instructions/`:
- `coding-standards.instructions.md` — code quality rules for `src/`.
- `testing-standards.instructions.md` — test quality rules for `tests/`.
- `scope-audit.instructions.md` — blast-radius checking (declare → implement → verify). Backed by `scripts/scope-audit.ps1` / `scripts/scope-audit.sh`.
- `frontend-ux.instructions.md` — UX and accessibility rules for UI files when the `frontend` extension is selected.
- `deployment-readiness.instructions.md` — pre-deployment security and build checklist when the `deployment-readiness` extension is selected.
- `ai-governance.instructions.md` — least-privilege tools, untrusted-input handling, human approvals, and audit evidence when the `ai-governance` extension is selected.

## Automation Scripts

Utility scripts in `scripts/` reduce LLM hallucination risk for deterministic checks:
- `check-phase.ps1` / `check-phase.sh` — validates `docs/spec.md` is well-formed and prerequisite sections are populated before advancing state.
- `feature-context.ps1` / `feature-context.sh` — resolves normalized feature IDs, canonical feature specs, and namespaced evidence paths.
- `migrate-spec.ps1` / `migrate-spec.sh` — explicitly migrates a legacy `docs/spec.md`, creates a backup, and initializes workflow metadata; it never writes without `-Force` / `--force`.
- `validate-sdlc-config.ps1` / `validate-sdlc-config.sh` — validates schema, package manager/manifest, test directories, named tasks, command availability, and evidence settings; writes config evidence.
- `run-sdlc-task.ps1` / `run-sdlc-task.sh` — runs structured install/build/test/lint/type-check tasks, retains logs and JSON evidence, and can update `docs/spec.md` gate records.
- `run-security-scans.ps1` / `run-security-scans.sh` — runs configured security tasks, applies blocking severity policy, writes a machine-readable aggregate, and records `gate_security_*`.
- `scope-audit.ps1` / `scope-audit.sh` — compares git diff against the Implementation Plan and reports scope creep.
- `validate-ai-governance.ps1` / `.sh` — validates approved AI providers, models, data boundaries, tools, sandboxes, and evaluation configuration when the `ai-governance` extension is selected.
- `record-ai-change.ps1` / `.sh` — appends an auditable, approval-aware AI change record.
- `run-ai-governance.ps1` / `.sh` — runs the configured agent evaluation task and records revision-bound evidence.
- The scaffold tools remain in the template authoring repository under `tools/`; they are not copied into the target project.

## CI Integration

When the `github-actions` extension is selected, `.github/workflows/sdlc-autonomy.yml` validates the named task registry, installs dependencies, runs configured tasks, uploads evidence, and comments on issues labeled `copilot:fix`. It does not itself invoke the Copilot coding agent or create a pull request; configure that assignment separately. Enable the workflow in `.github/sdlc-config.yml` by setting `integrations.copilot_coding_agent` to `true`.
