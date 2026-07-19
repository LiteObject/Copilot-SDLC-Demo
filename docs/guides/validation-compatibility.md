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
