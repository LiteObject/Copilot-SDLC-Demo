# Distribution And Upgrades

CG-6 provides one installer contract for Windows PowerShell, Bash, and direct
Python execution. The authoring checkout is the template source; a target
repository receives the deterministic gate scripts and a copy of the diagnostic
CLI.

## Compatibility Policy

The current template release is `1.0.0`. Template versions in the `1.x` line
support installer CLI versions in the `1.x` line. Python `3.9` or newer is
required for the CLI. Bash installations require Bash `4` or newer. Windows
installations require PowerShell `5.1` or newer, or PowerShell `7` when using
`pwsh`.

The manifest at `template/manifest.yml` is the compatibility authority. Every
extension declares its own version and supported template range. The installer
rejects a missing dependency, conflicting extension, or incompatible template
range before writing files.

Project-owned `docs/spec.md` and `.github/sdlc-config.yml` are never refreshed
by an update. A template-owned file that was modified after installation is
preserved and reported as a conflict. No update command silently replaces a
conflict.

## Install A Pinned Version

Run from the template authoring checkout:

```powershell
python tools/sdlc.py init --target ../my-project --version 1.0.0
```

```bash
python3 tools/sdlc.py init --target ../my-project --version 1.0.0
```

Select extensions and agent surfaces explicitly:

```powershell
python tools/sdlc.py init --target ../my-project --version 1.0.0 `
  --extension frontend --agent-surface all
```

The compatibility wrappers delegate to the same CLI:

```powershell
./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension frontend
```

```bash
./tools/scaffold-sdlc.sh ../my-project --extension frontend
```

The first install records the selected template and extension versions, the
manifest SHA-256, source revision, platform, portable-contract hash, and
managed file hashes in `.sdlc/sdlc-installer-state.json`.

## Preview And Update

Preview an installation or update without writing files:

```powershell
python tools/sdlc.py diff --target ../my-project --version 1.0.0
```

```bash
python3 tools/sdlc.py diff --target ../my-project --version 1.0.0
```

Update from a newer checkout or extracted release. Unchanged managed files may
be refreshed; modified files and project-owned files remain protected:

```powershell
python tools/sdlc.py update --target ../my-project --source ../copilot-sdlc-1.1.0 --version 1.1.0
```

After reviewing `sdlc diff`, explicitly accept replacement of known
template-owned conflicts when that is the intended decision:

```powershell
python tools/sdlc.py update --target ../my-project --version 1.1.0 --accept-conflicts
```

This flag never applies to `docs/spec.md` or `.github/sdlc-config.yml`. The
accepted paths are recorded in the update evidence under `.sdlc/evidence/`.

Remove an installed extension only when its files are still installer-owned:

```bash
python3 tools/sdlc.py update --target ../my-project --remove-extension frontend
```

A modified extension file is retained and reported as a removal conflict.

## Diagnose And Validate

`doctor` checks runtimes, installer state, manifest and template drift,
project-owned protection, managed-file integrity, extension setup, portable
contract freshness, generated surfaces, and the installed configuration and
surface validators:

```powershell
python tools/sdlc.py doctor --target ../my-project --source .
python tools/sdlc.py validate --target ../my-project --source .
```

The result is also written to `.sdlc/evidence/installer-doctor.json`. A clean
scaffold normally reports incomplete configuration until the target's named
validation tasks are configured. Use the installed config validator or rerun
`init --validate-config` after editing `.github/sdlc-config.yml`.

## Rollback

Every update stores a snapshot under `.sdlc/installer-history/` and writes an
update record under `.sdlc/evidence/`. Roll back the latest update as long as no
post-update edit has changed the files being restored:

```powershell
python scripts/sdlc.py rollback --target .
```

```bash
python3 scripts/sdlc.py rollback --target .
```

Rollback skips project-owned files and reports a conflict rather than
overwriting a post-update edit. The rollback result is stored as
`.sdlc/evidence/installer-rollback-<history-id>.json`.

## Release Archives

Create a deterministic archive, sidecar release manifest, and SHA-256 file:

```powershell
python tools/sdlc.py release --output-dir dist
```

Verify the archive and its checksum:

```bash
python3 tools/sdlc.py release --verify dist/copilot-sdlc-1.0.0.zip
```

The sidecar release manifest records the template version, manifest hash,
expanded installed base files, source archive paths, and file count. Verification
fails if the archive checksum, embedded manifest, or manifest-covered base files
do not match.
