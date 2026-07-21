# Template Authoring Guidelines

This repository authors the reusable Copilot SDLC template. It is not itself a
consumer project.

## Layout

- `template/base/` contains the files installed into every target repository.
- `template/extensions/` contains opt-in capabilities installed only when
  selected by the scaffold command, including `ai-governance` for repositories
  that use coding agents and `ai-lifecycle` for AI-enabled products.
- `tools/` contains authoring-repository scaffolding and validation utilities.
- `docs/architecture/` and `docs/roadmap.md` describe the template; they are
  not copied into consuming repositories.

## Change Rules

- Preserve the target-relative paths inside `template/base/` and extensions.
  Agents in a consuming repository must still find `.github/`, `docs/spec.md`,
  and `scripts/` at the repository root.
- Keep the base payload independent of a particular language, framework, cloud,
  or CI provider. Put optional integrations in an extension.
- Treat `.github/sdlc-config.yml` and `docs/spec.md` as project-owned after
  installation. Scaffold updates must not overwrite them without explicit
  confirmation.
- Update `template/manifest.yml`, the scaffold tools, and the documentation
  whenever a template file is added, removed, or reclassified.
- Validate a clean scaffold installation after changing template layout or
  installer behavior.
- Keep PowerShell and Bash validators, task runners, security/release scripts,
  and governance scripts behaviorally aligned; run `tests/phase0/`,
  `tests/phase1/`, `tests/phase2/`, `tests/phase3/`, `tests/phase4/`,
  `tests/phase5/`, `tests/phase6/`, and `tests/phase7/` harnesses after changes.
- Do not reintroduce arbitrary shell command evaluation into the task registry
  or GitHub Actions workflows.
