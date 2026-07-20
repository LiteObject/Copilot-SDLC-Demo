#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/phase3/config-release-valid.yml"
BASE_SCRIPTS="$ROOT/template/base/scripts"
RELEASE_SCRIPTS="$ROOT/template/extensions/release-assurance/scripts"
TEMP="$(mktemp -d "$ROOT/tests/.phase3-bash.XXXXXX")"
FAILURES=0
cleanup() { rm -rf "$TEMP"; }
trap cleanup EXIT
assert_condition() { local label="$1" condition="$2"; if [[ "$condition" == true ]]; then echo "[PASS] $label"; else echo "[FAIL] $label"; ((FAILURES += 1)); fi; }
mkdir -p "$TEMP/.github" "$TEMP/docs" "$TEMP/tests" "$TEMP/scripts" "$TEMP/.sdlc/release"
cp "$FIXTURE" "$TEMP/.github/sdlc-config.yml"
cp "$ROOT/template/base/docs/spec.md" "$TEMP/docs/spec.md"
cp "$BASE_SCRIPTS"/* "$TEMP/scripts/"
printf '%s\n' 'release fixture' > "$TEMP/.sdlc/release/RELEASE_NOTES.md"
printf '%s\n' 'rollback fixture' > "$TEMP/.sdlc/release/ROLLBACK.md"

set +e
bash "$RELEASE_SCRIPTS/validate-release-config.sh" --repo-root "$TEMP" >/dev/null
config_exit=$?
set -e
assert_condition 'release config validates' "$([[ "$config_exit" -eq 0 ]] && echo true || echo false)"
set +e
bash "$RELEASE_SCRIPTS/prepare-release.sh" --repo-root "$TEMP" --record-spec >/dev/null
prepare_exit=$?
set -e
assert_condition 'release preparation succeeds' "$([[ "$prepare_exit" -eq 0 ]] && echo true || echo false)"
assert_condition 'release manifest exists' "$(test -f "$TEMP/.sdlc/release/release-manifest.json" && echo true || echo false)"
assert_condition 'provenance exists' "$(test -f "$TEMP/.sdlc/release/provenance.json" && echo true || echo false)"
set +e
bash "$RELEASE_SCRIPTS/verify-release.sh" --repo-root "$TEMP" >/dev/null
verify_exit=$?
set -e
assert_condition 'release verification succeeds' "$([[ "$verify_exit" -eq 0 ]] && echo true || echo false)"
printf '%s\n' tampered >> "$TEMP/.sdlc/release/artifact.tar.gz"
set +e
bash "$RELEASE_SCRIPTS/verify-release.sh" --repo-root "$TEMP" >/dev/null
tamper_exit=$?
set -e
assert_condition 'artifact tampering is rejected' "$([[ "$tamper_exit" -eq 1 ]] && echo true || echo false)"

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 3 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 3 regression cases passed.'
