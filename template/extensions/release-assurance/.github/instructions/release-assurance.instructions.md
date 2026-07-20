---
description: "Release artifact, supply-chain, promotion, smoke-test, and rollback controls."
applyTo: "**"
---
# Release Assurance

Use this extension for repositories that produce deployable artifacts. Set
`release_assurance.enabled: true` only after configuring the package, SBOM,
signing if required, deployment, smoke-test, and rollback tasks in
`.github/sdlc-config.yml`.

## Release Bundle

Run `scripts/validate-release-config.ps1` or `.sh`, then
`scripts/prepare-release.ps1 -RecordSpec` or
`scripts/prepare-release.sh --record-spec`. The preparation step requires:

- an immutable artifact at `artifact_path`;
- an SPDX or CycloneDX JSON SBOM at `sbom_path`;
- source commit and working-tree evidence;
- generated SLSA-style provenance tied to the artifact digest;
- release notes and rollback instructions;
- a signature file when `require_signed_artifact` is true.

Verify the bundle with `scripts/verify-release.ps1` or `.sh` before promotion.
Do not replace the generated manifest with a manually typed checksum.

## Promotion

Configure GitHub environments named in `promotion_environments`. Add required
reviewers and separation-of-duties rules to the staging and production
Environments settings. Environment approval is the human control; the workflow
must not bypass it with a personal access token or an automatic approval.

Promotion order is development, staging, production. A deployment task and
post-deployment smoke-test task must pass before the next environment is
eligible. A failed smoke test stops the workflow and leaves the rollback task
available.

## Rollback

Keep `rollback_instructions_path` under version control and test the configured
`rollback_task` in a non-production environment. Use the manual rollback
workflow for production recovery; record the task output and incident/change
reference in `.sdlc/evidence/`.

Actions used by release workflows must be pinned according to the repository's
supply-chain policy. Retain release manifests, checksums, SBOM, provenance,
logs, approvals, smoke-test evidence, and rollback evidence with the release.
