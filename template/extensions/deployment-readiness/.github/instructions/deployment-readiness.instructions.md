---
description: "Pre-deployment checklist validating security, configuration, and build readiness before shipping. Use when preparing for staging or production deployment."
applyTo: "src/**"
---
# Deployment Readiness Check

A pre-deployment gate that runs after `TESTING` passes and before the feature is considered `DONE`. Validates that the codebase is safe to deploy.

## When to Use

- After all tests pass and before merging to main.
- Before deploying to staging or production.
- As part of release candidate validation.
- When setting up a new environment.

## Checklist

Run each section. A single `FAIL` blocks deployment.

### 1. Build Verification

```bash
# Confirm the project builds cleanly from scratch
# Replace with the actual build command for the project's tech stack
npm run build          # Node/TypeScript projects
# dotnet build         # .NET projects
# python -m compileall src/  # Python projects
```

**Gate:** Build must exit with code 0 and produce no errors.

### 2. Test Suite Final Run

```bash
# Run the full test suite one last time
npm test               # Node projects
# pytest               # Python projects
# dotnet test          # .NET projects
```

**Gate:** 100% pass rate. No skipped or flaky tests.

### 3. Secret & Credential Scan

```bash
# Search for hardcoded secrets, keys, tokens, or passwords
# Never committed to source control
grep -rn --include="*.{ts,js,py,cs,go,rs,yaml,json,env}" \
  -E '(SECRET|PASSWORD|API_KEY|TOKEN|PRIVATE.?KEY)\s*=\s*["\x27][a-zA-Z0-9_\-]{8,}' \
  src/ --exclude-dir=node_modules --exclude-dir=__pycache__ --exclude-dir=.venv
```

**Gate:** Zero matches. If any are found, they must be moved to environment variables or a secrets manager.

### 4. Configuration Audit

Verify environment-specific configuration:

- **Debug mode** is OFF for production builds.
- **CORS origins** are explicit (no wildcard `*` in production).
- **Error pages** do not leak stack traces or internal paths.
- **Logging level** is appropriate for the target environment (info/warn for production).

### 5. Dependency Audit

```bash
# Check for known vulnerabilities in dependencies
npm audit              # Node projects
# pip-audit            # Python projects
# dotnet list package --vulnerable  # .NET projects
```

**Gate:** Zero critical or high-severity vulnerabilities. Medium-severity findings must be reviewed and acknowledged.

### 6. Dead Code & Cleanup

```bash
# Verify no commented-out code, leftover TODOs, or debug prints remain
grep -rn --include="*.{ts,js,py,cs,go,rs}" \
  -E '(TODO|FIXME|HACK|XXX|console\.(log|debug|warn)|print\(|Debug\.)' \
  src/ --exclude-dir=node_modules --exclude-dir=__pycache__
```

**Gate:** Zero intentional debug output. TODOs must have an associated ticket reference.

## Output Format

Produce a table:

```
| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | Build   | PASS / FAIL | ... |
| 2 | Tests   | PASS / FAIL | ... |
| 3 | Secrets | PASS / FAIL | ... |
| 4 | Config  | PASS / FAIL | ... |
| 5 | Deps    | PASS / FAIL | ... |
| 6 | Cleanup | PASS / FAIL | ... |
```

**All PASS** → Ready to deploy.  
**Any FAIL** → Route fix to Developer, then re-run the full checklist.
