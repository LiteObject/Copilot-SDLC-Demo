# Project Guidelines

These rules apply to every agent in this workspace (Supervisor, PM, Architect, Developer, Reviewer, QA).

## Configuration

- Stack-specific settings (languages, frameworks, test command, linting) live in [.github/sdlc-config.yml](sdlc-config.yml). Every agent reads this file to discover project conventions. When adapting this repo to a new stack, edit `sdlc-config.yml` first — it is the single place to set language, framework, and tool defaults.

## Workflow

- The project moves through a state machine: `GATHERING_REQS → [DESIGN] → PLANNING → CODING → REVIEW → TESTING → [DEPLOYMENT_READINESS] → DONE`. The `DESIGN` phase is optional (frontend/UI projects only). `DEPLOYMENT_READINESS` is an optional pre-merge gate.
- [docs/spec.md](../docs/spec.md) is the single source of truth for requirements, plan, and current state. Keep it updated as work progresses.
- Do not skip ahead: code is only written after requirements are clear and a plan exists.
- **Before advancing state**, the Supervisor runs `scripts/check-phase.ps1` (or `.sh`) to validate that prerequisite sections in `docs/spec.md` are populated. Do not advance if the script fails.
- The **Developer must verify the project builds cleanly** before handing off to REVIEW.
- The **Reviewer performs a scope audit** — run `scripts/scope-audit.ps1` (or `.sh`) and report the output. The script compares the actual git diff against the Implementation Plan in `docs/spec.md` and categorizes every changed file as `[IN_SCOPE]`, `[SCOPE_CREEP]`, or `[MISSING]`.

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

## Automation Scripts

Utility scripts in `scripts/` reduce LLM hallucination risk for deterministic checks:
- `check-phase.ps1` / `check-phase.sh` — validates `docs/spec.md` is well-formed and prerequisite sections are populated before advancing state.
- `scope-audit.ps1` / `scope-audit.sh` — compares git diff against the Implementation Plan and reports scope creep.
- The scaffold tools remain in the template authoring repository under `tools/`; they are not copied into the target project.

## CI Integration

When the `github-actions` extension is selected, `.github/workflows/sdlc-autonomy.yml` validates the configured test command when the `copilot:fix` label is added to an issue. It does not itself invoke the Copilot coding agent or create a pull request; configure that assignment separately. Enable test validation in `.github/sdlc-config.yml` by setting `integrations.copilot_coding_agent` to `true`.
