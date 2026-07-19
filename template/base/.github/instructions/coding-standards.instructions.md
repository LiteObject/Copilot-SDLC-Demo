---
description: "Coding standards for application source. Use when writing or editing files under src/."
applyTo: "src/**"
---
# Coding Standards

- Keep functions short and single-purpose; extract helpers when logic branches grow.
- Use clear, descriptive names; avoid abbreviations.
- Separate business logic from I/O (HTTP, DB, file system) so logic is unit-testable.
- Validate inputs at system boundaries; do not add defensive checks for impossible states.
- No commented-out code, dead code, leftover TODOs, or unused imports.
- Every file must trace back to an item in the Implementation Plan in `docs/spec.md`.
- Never hardcode secrets, keys, tokens, or passwords — use environment variables or a secrets manager.
- The project must build cleanly before handing off to REVIEW: run the build command and confirm zero errors.
