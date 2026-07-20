#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_ROOT="$ROOT/tests/fixtures/phase2"
CONFIG_VALIDATOR="$ROOT/template/base/scripts/validate-sdlc-config.sh"
SECURITY_RUNNER="$ROOT/template/base/scripts/run-security-scans.sh"
SPEC_TEMPLATE="$ROOT/template/base/docs/spec.md"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase2-bash.XXXXXX")"
FAILURES=0

cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT
assert_condition() { local label="$1" condition="$2"; if [[ "$condition" == true ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; ((FAILURES += 1)); fi; }
new_test_repo() { local name="$1" fixture="$2" repo="$TEMP_ROOT/$1"; mkdir -p "$repo/.github" "$repo/docs" "$repo/tests"; cp "$FIXTURE_ROOT/$fixture" "$repo/.github/sdlc-config.yml"; cp "$SPEC_TEMPLATE" "$repo/docs/spec.md"; printf '%s' "$repo"; }

pass_repo="$(new_test_repo security-pass config-security-pass.yml)"
set +e
bash "$CONFIG_VALIDATOR" --repo-root "$pass_repo" --record-spec >/dev/null
pass_config_exit=$?
set -e
assert_condition 'security config passes validation' "$([[ "$pass_config_exit" -eq 0 ]] && echo true || echo false)"
set +e
bash "$SECURITY_RUNNER" --repo-root "$pass_repo" --record-spec >/dev/null
pass_scan_exit=$?
set -e
assert_condition 'passing security scan policy succeeds' "$([[ "$pass_scan_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'security summary evidence exists' "$(test -f "$pass_repo/.sdlc/evidence/security-scan.json" && echo true || echo false)"
assert_condition 'passing security gate is recorded' "$(grep -Eq '^gate_security_result:[[:space:]]+PASS[[:space:]]*$' "$pass_repo/docs/spec.md" && echo true || echo false)"
assert_condition 'security review enables security gate' "$(grep -Eq '^security_gate_enabled:[[:space:]]+true[[:space:]]*$' "$pass_repo/docs/spec.md" && echo true || echo false)"

high_repo="$(new_test_repo security-high config-security-high.yml)"
set +e
bash "$SECURITY_RUNNER" --repo-root "$high_repo" --record-spec >/dev/null
high_scan_exit=$?
set -e
assert_condition 'blocking security finding fails policy' "$([[ "$high_scan_exit" -eq 1 ]] && echo true || echo false)"
assert_condition 'blocking security summary exists' "$(test -f "$high_repo/.sdlc/evidence/security-scan.json" && echo true || echo false)"
assert_condition 'high severity is machine-readable' "$(grep -Eq '"severity"[[:space:]]*:[[:space:]]*"high"' "$high_repo/.sdlc/evidence/security-scan.json" && echo true || echo false)"
assert_condition 'blocking finding is machine-readable' "$(grep -Eq '"blocking"[[:space:]]*:[[:space:]]*true' "$high_repo/.sdlc/evidence/security-scan.json" && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 2 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 2 regression cases passed.'
