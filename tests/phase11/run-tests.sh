#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAFFOLDER="$ROOT/tools/scaffold-sdlc.sh"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase11-bash.XXXXXX")"
FAILURES=0

cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

assert_exit_code() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" -eq "$expected" ]]; then echo "[PASS] $label ($actual)"; else echo "[FAIL] $label: expected $expected, got $actual"; ((FAILURES += 1)); fi
}

assert_condition() {
  local label="$1" condition="$2"
  if [[ "$condition" == true ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; ((FAILURES += 1)); fi
}

run_scaffold() {
  local target="$1" surface="${2:-copilot}" update="${3:-0}"
  local args=("$target" --agent-surface "$surface")
  (( update == 1 )) && args+=(--update-agent-surface)
  set +e
  bash "$SCAFFOLDER" "${args[@]}" >/dev/null
  local actual=$?
  set -e
  printf '%s' "$actual"
}

run_validator() {
  local target="$1" surface="$2"
  set +e
  bash "$target/scripts/validate-agent-surfaces.sh" --repo-root "$target" --agent-surface "$surface" >/dev/null
  local actual=$?
  set -e
  printf '%s' "$actual"
}

run_generator_update() {
  local target="$1"
  set +e
  bash "$target/scripts/generate-agent-surfaces.sh" --repo-root "$target" --surface generic --update >/dev/null
  local actual=$?
  set -e
  printf '%s' "$actual"
}

COPILOT_REPO="$TEMP_ROOT/copilot"
actual="$(run_scaffold "$COPILOT_REPO")"
assert_exit_code 'default Copilot scaffold succeeds' "$actual" 0
assert_condition 'default Copilot scaffold does not create AGENTS.md' "$(test ! -f "$COPILOT_REPO/AGENTS.md" && echo true || echo false)"
assert_condition 'Copilot adapter records source hash and template version' "$(grep -Eq '^<!--[[:space:]]*portable-contract-sha256:[[:space:]]*[0-9a-f]{64}[[:space:]]*-->' "$COPILOT_REPO/.github/copilot-instructions.md" && grep -Eq '^<!--[[:space:]]*template-version:[[:space:]]*1\.0\.0[[:space:]]*-->' "$COPILOT_REPO/.github/copilot-instructions.md" && echo true || echo false)"
actual="$(run_validator "$COPILOT_REPO" copilot)"
assert_exit_code 'default Copilot adapter validates' "$actual" 0

GENERIC_REPO="$TEMP_ROOT/generic"
actual="$(run_scaffold "$GENERIC_REPO" generic)"
assert_exit_code 'generic scaffold succeeds' "$actual" 0
assert_condition 'generic scaffold creates AGENTS.md' "$(test -f "$GENERIC_REPO/AGENTS.md" && echo true || echo false)"
actual="$(run_validator "$GENERIC_REPO" generic)"
assert_exit_code 'generic adapter validates' "$actual" 0

printf '\nContract drift fixture.\n' >> "$GENERIC_REPO/docs/portable-agent-contract.md"
actual="$(run_validator "$GENERIC_REPO" generic)"
assert_exit_code 'contract drift blocks generic validation' "$actual" 1
actual="$(run_generator_update "$GENERIC_REPO")"
assert_exit_code 'explicit generic regeneration succeeds' "$actual" 0
actual="$(run_validator "$GENERIC_REPO" generic)"
assert_exit_code 'regenerated generic adapter validates' "$actual" 0

printf '\nManual adapter edit.\n' >> "$GENERIC_REPO/AGENTS.md"
cp "$GENERIC_REPO/AGENTS.md" "$TEMP_ROOT/generic-before.md"
actual="$(run_scaffold "$GENERIC_REPO" generic)"
assert_exit_code 'modified generated adapter scaffold succeeds' "$actual" 0
assert_condition 'modified generated adapter is preserved' "$(cmp -s "$GENERIC_REPO/AGENTS.md" "$TEMP_ROOT/generic-before.md" && echo true || echo false)"
actual="$(run_validator "$GENERIC_REPO" generic)"
assert_exit_code 'modified generated adapter fails portability validation' "$actual" 1
actual="$(run_scaffold "$GENERIC_REPO" generic 1)"
assert_exit_code 'explicit generic adapter update succeeds' "$actual" 0
actual="$(run_validator "$GENERIC_REPO" generic)"
assert_exit_code 'explicitly updated generic adapter validates' "$actual" 0

MANUAL_REPO="$TEMP_ROOT/manual"
mkdir -p "$MANUAL_REPO"
printf '# Project-owned adapter\n' > "$MANUAL_REPO/AGENTS.md"
cp "$MANUAL_REPO/AGENTS.md" "$TEMP_ROOT/manual-before.md"
actual="$(run_scaffold "$MANUAL_REPO" generic)"
assert_exit_code 'manual adapter scaffold succeeds' "$actual" 0
assert_condition 'manual adapter is preserved by default' "$(cmp -s "$MANUAL_REPO/AGENTS.md" "$TEMP_ROOT/manual-before.md" && echo true || echo false)"
actual="$(run_validator "$MANUAL_REPO" generic)"
assert_exit_code 'manual adapter fails until explicitly adopted' "$actual" 1
actual="$(run_scaffold "$MANUAL_REPO" generic 1)"
assert_exit_code 'explicit manual adapter update succeeds' "$actual" 0
actual="$(run_validator "$MANUAL_REPO" generic)"
assert_exit_code 'adopted manual adapter validates' "$actual" 0

printf '\nManual Copilot adapter edit.\n' >> "$COPILOT_REPO/.github/copilot-instructions.md"
actual="$(run_validator "$COPILOT_REPO" copilot)"
assert_exit_code 'modified Copilot adapter fails validation' "$actual" 1
actual="$(run_scaffold "$COPILOT_REPO" all 1)"
assert_exit_code 'all-surface explicit update succeeds' "$actual" 0
actual="$(run_validator "$COPILOT_REPO" all)"
assert_exit_code 'all selected surfaces validate together' "$actual" 0

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 11 Bash CG-5 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 11 CG-5 regression cases passed.'