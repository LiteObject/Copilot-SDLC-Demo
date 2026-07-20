#!/usr/bin/env bash
# Verify release manifest, artifact digest, SBOM, provenance, and signature.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_PATH=""
EVIDENCE_DIRECTORY='.sdlc/evidence'
while (($# > 0)); do
    case "$1" in
        --repo-root) [[ $# -ge 2 ]] || { echo '[FAIL] --repo-root requires a value.'; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
        --manifest-path) [[ $# -ge 2 ]] || { echo '[FAIL] --manifest-path requires a value.'; exit 2; }; MANIFEST_PATH="$2"; shift 2 ;;
        --evidence-directory) [[ $# -ge 2 ]] || { echo '[FAIL] --evidence-directory requires a value.'; exit 2; }; EVIDENCE_DIRECTORY="$2"; shift 2 ;;
        --help|-h) echo 'Usage: verify-release.sh [--repo-root PATH] [--manifest-path PATH]'; exit 0 ;;
        *) echo "[FAIL] Unknown option: $1"; exit 2 ;;
    esac
done
if [[ -z "$MANIFEST_PATH" ]]; then MANIFEST_PATH="$REPO_ROOT/.sdlc/release/release-manifest.json"; fi
[[ -f "$MANIFEST_PATH" ]] || { echo "[FAIL] Release manifest not found: $MANIFEST_PATH"; exit 1; }
json_value() { local key="$1" file="$2"; sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -n1; }
nested_value() { local section="$1" key="$2" file="$3"; sed -nE "s/.*\"$section\"[[:space:]]*:[[:space:]]*\{[^}]*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"[^}]*\}.*/\1/p" "$file" | head -n1; }
resolve_path() { local relative="$1"; [[ "$relative" != /* && "$relative" != ../* && "$relative" != */../* && "$relative" != '..' ]] || { echo "[FAIL] Unsafe manifest path: $relative"; return 1; }; printf '%s/%s' "$REPO_ROOT" "$relative"; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
ERRORS=()
add_error() { ERRORS+=("$1"); echo "[FAIL] $1"; }
ARTIFACT_REL="$(nested_value artifact path "$MANIFEST_PATH")"; ARTIFACT_SHA="$(nested_value artifact sha256 "$MANIFEST_PATH")"; SBOM_REL="$(nested_value sbom path "$MANIFEST_PATH")"; SBOM_SHA="$(nested_value sbom sha256 "$MANIFEST_PATH")"; PROVENANCE_REL="$(nested_value provenance path "$MANIFEST_PATH")"
ARTIFACT_PATH="$(resolve_path "$ARTIFACT_REL")"; SBOM_PATH="$(resolve_path "$SBOM_REL")"; PROVENANCE_PATH="$(resolve_path "$PROVENANCE_REL")"
[[ -f "$ARTIFACT_PATH" ]] || add_error "Artifact missing: $ARTIFACT_REL"; [[ ! -f "$ARTIFACT_PATH" || "$(sha256_file "$ARTIFACT_PATH")" == "$ARTIFACT_SHA" ]] || add_error 'Artifact SHA-256 does not match the release manifest.'
[[ -f "$SBOM_PATH" ]] || add_error "SBOM missing: $SBOM_REL"; [[ ! -f "$SBOM_PATH" || "$(sha256_file "$SBOM_PATH")" == "$SBOM_SHA" ]] || add_error 'SBOM SHA-256 does not match the release manifest.'
SBOM_FORMAT="$(json_value format "$MANIFEST_PATH")"; if [[ -f "$SBOM_PATH" ]]; then [[ "$SBOM_FORMAT" != cyclonedx-json || $(grep -Eic '"bomFormat"[[:space:]]*:[[:space:]]*"CycloneDX"' "$SBOM_PATH") -gt 0 ]] || add_error 'SBOM is not CycloneDX JSON.'; [[ "$SBOM_FORMAT" != spdx-json || $(grep -Eic '"spdxVersion"[[:space:]]*:' "$SBOM_PATH") -gt 0 ]] || add_error 'SBOM is not SPDX JSON.'; fi
[[ -f "$PROVENANCE_PATH" ]] || add_error "Provenance missing: $PROVENANCE_REL"; if [[ -f "$PROVENANCE_PATH" ]]; then grep -Fq "\"name\":\"$ARTIFACT_REL\"" "$PROVENANCE_PATH" || add_error 'Provenance subject does not name the artifact.'; grep -Fq "\"sha256\":\"$ARTIFACT_SHA\"" "$PROVENANCE_PATH" || add_error 'Provenance subject does not match the artifact digest.'; fi
SIGNATURE_REL="$(sed -nE 's/.*"signature"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$MANIFEST_PATH" | head -n1)"; [[ -z "$SIGNATURE_REL" || -f "$(resolve_path "$SIGNATURE_REL")" ]] || add_error "Signature missing: $SIGNATURE_REL"
RECORD_DIRECTORY="$REPO_ROOT/$EVIDENCE_DIRECTORY"; mkdir -p "$RECORD_DIRECTORY"; RECORD_PATH="$RECORD_DIRECTORY/release-verification.json"
json_escape() { local value="$1"; value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\r'/\\r}"; value="${value//$'\n'/\\n}"; printf '"%s"' "$value"; }
{
    printf '{"schema":1,"kind":"sdlc-release-verification","manifest":'; json_escape "${MANIFEST_PATH#"$REPO_ROOT/"}"; printf ',"checked_at":'; json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; if (( ${#ERRORS[@]} == 0 )); then printf ',"result":"PASS","exit_code":0'; else printf ',"result":"FAIL","exit_code":1'; fi; printf ',"errors":['; for (( i=0; i<${#ERRORS[@]}; i++ )); do (( i > 0 )) && printf ','; json_escape "${ERRORS[$i]}"; done; printf ']}\n'
} > "$RECORD_PATH"
(( ${#ERRORS[@]} == 0 )) || exit 1
echo '[PASS] Release manifest and supply-chain evidence verified.'
exit 0
