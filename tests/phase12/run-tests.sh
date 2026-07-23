#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/tools/sdlc.py"
SCAFFOLDER="$ROOT/tools/scaffold-sdlc.sh"
CONFIG_FIXTURE="$ROOT/tests/fixtures/phase1/config-valid.yml"
TEMP_ROOT="$(mktemp -d "$ROOT/tests/.phase12-bash.XXXXXX")"
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

make_source() {
    local destination="$1"
    mkdir -p "$destination"
    cp -R "$ROOT/template" "$destination/template"
    cp -R "$ROOT/tools" "$destination/tools"
}

BASE_REPO="$TEMP_ROOT/base"
set +e
python3 "$CLI" init --target "$BASE_REPO" --version 1.0.0 --extension frontend --agent-surface generic --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'pinned CLI installation succeeds' "$actual" 0
assert_condition 'installer state records CG-6 provenance' "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); required=("templateVersion","extensionVersions","manifestSha256","sourceRevision","platform"); print(str(all(key in s for key in required) and s["templateVersion"] == "1.0.0" and s["extensionVersions"].get("frontend") == "1.0.0").lower())' "$BASE_REPO/.sdlc/sdlc-installer-state.json")"
assert_condition 'installed target includes portable CLI' "$(test -f "$BASE_REPO/scripts/sdlc.py" && echo true || echo false)"
assert_condition 'generic adapter is installed' "$(test -f "$BASE_REPO/AGENTS.md" && echo true || echo false)"

set +e
bash "$SCAFFOLDER" "$BASE_REPO" --agent-surface generic >/dev/null
actual=$?
set -e
assert_exit_code 'repeat compatibility install succeeds' "$actual" 0
assert_condition 'repeat install preserves selected extension' "$(test -f "$BASE_REPO/.github/instructions/frontend-ux.instructions.md" && grep -Eq '"frontend"[[:space:]]*:[[:space:]]*"1.0.0"' "$BASE_REPO/.sdlc/sdlc-installer-state.json" && echo true || echo false)"

set +e
diff_output="$(python3 "$CLI" diff --target "$BASE_REPO" --version 1.0.0 --json)"
actual=$?
set -e
assert_exit_code 'clean installation diff succeeds' "$actual" 0
assert_condition 'clean installation diff has no additions' "$(if grep -Eq '"action": "add"|"action": "update"' <<< "$diff_output"; then echo false; else echo true; fi)"

cp "$CONFIG_FIXTURE" "$BASE_REPO/.github/sdlc-config.yml"
mkdir -p "$BASE_REPO/tests"
set +e
python3 "$CLI" doctor --target "$BASE_REPO" --source "$ROOT" --json >/dev/null
doctor_exit=$?
set -e
assert_exit_code 'doctor passes a configured target' "$doctor_exit" 0
assert_condition 'doctor evidence exists' "$(test -f "$BASE_REPO/.sdlc/evidence/installer-doctor.json" && grep -Eq '"result":[[:space:]]*"PASS"' "$BASE_REPO/.sdlc/evidence/installer-doctor.json" && echo true || echo false)"

set +e
python3 "$CLI" init --target "$TEMP_ROOT/bad-pin" --version 9.9.9 --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'unsupported pinned version is rejected' "$actual" 1
assert_condition 'rejected pin writes no installer state' "$(test ! -f "$TEMP_ROOT/bad-pin/.sdlc/sdlc-installer-state.json" && echo true || echo false)"

INCOMPATIBLE_SOURCE="$TEMP_ROOT/source-incompatible"
make_source "$INCOMPATIBLE_SOURCE"
sed -i 's/supported_installers: \[1.0.0\]/supported_installers: [9.9.9]/' "$INCOMPATIBLE_SOURCE/template/manifest.yml"
set +e
python3 "$CLI" init --target "$TEMP_ROOT/incompatible-installer" --source "$INCOMPATIBLE_SOURCE" --version 1.0.0 --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'incompatible installer version is rejected' "$actual" 1
assert_condition 'incompatible installer writes no state' "$(test ! -f "$TEMP_ROOT/incompatible-installer/.sdlc/sdlc-installer-state.json" && echo true || echo false)"

UPGRADE_SOURCE="$TEMP_ROOT/source-1.1.0"
make_source "$UPGRADE_SOURCE"
sed -i '0,/^  version: 1.0.0/s//  version: 1.1.0/' "$UPGRADE_SOURCE/template/manifest.yml"
printf '\nUpgrade fixture.\n' >> "$UPGRADE_SOURCE/template/base/docs/portable-agent-contract.md"
BEFORE_SPEC="project-owned spec before update"
BEFORE_CONFIG="project-owned config before update"
printf '%s' "$BEFORE_SPEC" > "$BASE_REPO/docs/spec.md"
printf '%s' "$BEFORE_CONFIG" > "$BASE_REPO/.github/sdlc-config.yml"
BEFORE_CONTRACT="$(cat "$BASE_REPO/docs/portable-agent-contract.md")"
set +e
python3 "$CLI" update --target "$BASE_REPO" --source "$UPGRADE_SOURCE" --version 1.1.0 --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'upgrade across pinned releases succeeds' "$actual" 0
assert_condition 'upgrade applies source change' "$(grep -Eq 'Upgrade fixture\.' "$BASE_REPO/docs/portable-agent-contract.md" && echo true || echo false)"
assert_condition 'upgrade preserves project-owned files' "$(if grep -Fxq "$BEFORE_SPEC" "$BASE_REPO/docs/spec.md" && grep -Fxq "$BEFORE_CONFIG" "$BASE_REPO/.github/sdlc-config.yml"; then echo true; else echo false; fi)"

set +e
python3 "$CLI" rollback --target "$BASE_REPO" >/dev/null
actual=$?
set -e
assert_exit_code 'rollback succeeds' "$actual" 0
assert_condition 'rollback restores managed files' "$(if grep -Fq 'Upgrade fixture.' "$BASE_REPO/docs/portable-agent-contract.md"; then echo false; elif grep -Eq '"lastOperation"[[:space:]]*:[[:space:]]*"rollback"' "$BASE_REPO/.sdlc/sdlc-installer-state.json"; then echo true; else echo false; fi)"
assert_condition 'rollback evidence exists' "$(test "$(find "$BASE_REPO/.sdlc/evidence" -name 'installer-rollback-*.json' | wc -l)" -gt 0 && echo true || echo false)"

CONFLICT_REPO="$TEMP_ROOT/conflict"
set +e
python3 "$CLI" init --target "$CONFLICT_REPO" --version 1.0.0 --shell bash >/dev/null
set -e
printf '\nuser conflict\n' >> "$CONFLICT_REPO/scripts/check-phase.sh"
set +e
python3 "$CLI" update --target "$CONFLICT_REPO" --version 1.0.0 --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'modified template file requires update decision' "$actual" 2
assert_condition 'update preserves modified template file' "$(grep -Eq 'user conflict' "$CONFLICT_REPO/scripts/check-phase.sh" && grep -Eq 'scripts/check-phase.sh' "$CONFLICT_REPO/.sdlc/sdlc-installer-state.json" && echo true || echo false)"
set +e
python3 "$CLI" update --target "$CONFLICT_REPO" --version 1.0.0 --accept-conflicts --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'explicit conflict decision succeeds' "$actual" 0
assert_condition 'accepted conflict refreshes the template file' "$(latest_update="$(find "$CONFLICT_REPO/.sdlc/evidence" -name 'installer-update-*.json' | sort | tail -n 1)"; if grep -Fq 'user conflict' "$CONFLICT_REPO/scripts/check-phase.sh"; then echo false; elif grep -Fq '"acceptedConflicts"' "$latest_update" && grep -Fq 'scripts/check-phase.sh' "$latest_update"; then echo true; else echo false; fi)"

set +e
python3 "$CLI" update --target "$BASE_REPO" --version 1.0.0 --remove-extension frontend --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'extension removal succeeds' "$actual" 0
assert_condition 'extension files are removed when unchanged' "$(test ! -f "$BASE_REPO/.github/instructions/frontend-ux.instructions.md" && grep -Eq '"extensions"[[:space:]]*:[[:space:]]*\[\]' "$BASE_REPO/.sdlc/sdlc-installer-state.json" && echo true || echo false)"

set +e
OUTSIDE_EXTENSION="$TEMP_ROOT/../outside-extension"
mkdir -p "$OUTSIDE_EXTENSION"
python3 "$CLI" init --target "$TEMP_ROOT/path-traversal" --extension "$OUTSIDE_EXTENSION" --shell bash >/dev/null
actual=$?
set -e
assert_exit_code 'extension path traversal is rejected' "$actual" 1
rm -rf "$OUTSIDE_EXTENSION"

RELEASE_DIR="$TEMP_ROOT/release"
set +e
python3 "$CLI" release --output-dir "$RELEASE_DIR" >/dev/null
release_exit=$?
archive="$(find "$RELEASE_DIR" -name '*.zip' -print -quit)"
python3 "$CLI" release --verify "$archive" >/dev/null
verify_exit=$?
set -e
assert_exit_code 'release archive is created' "$release_exit" 0
assert_exit_code 'release checksum verification succeeds' "$verify_exit" 0
assert_condition 'release sidecars exist' "$(test -f "$archive.sha256" && test -f "${archive%.zip}.release.json" && echo true || echo false)"
printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$(basename "$archive")" > "$archive.sha256"
set +e
python3 "$CLI" release --verify "$archive" >/dev/null
actual=$?
set -e
assert_exit_code 'tampered release checksum is rejected' "$actual" 1

if (( FAILURES > 0 )); then echo "[FAIL] $FAILURES Phase 12 Bash CG-6 regression case(s) failed."; exit 1; fi
echo '[PASS] All Bash Phase 12 CG-6 regression cases passed.'
