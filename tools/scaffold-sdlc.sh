#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Installs the Copilot SDLC base payload into a target folder.

Usage:
  ./tools/scaffold-sdlc.sh <target> [--extension <name>] [--force] [--validate-config]

Options:
  --template <name>       Template name; base is currently available.
  --extension <name>      Install an extension from template/extensions.
  --variable Name=Value   Render a template variable.
  --force                 Refresh unchanged template-owned files.
  --validate-config       Run the installed config validator and fail until configured.
EOF
}

if (( BASH_VERSINFO[0] < 4 )); then
  echo 'This installer requires Bash 4 or newer.' >&2
  exit 1
fi

FORCE=0
VALIDATE_CONFIG=0
TARGET=''
TEMPLATE='base'
EXTENSIONS=()
VARIABLES=()

while (( $# > 0 )); do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --validate-config)
      VALIDATE_CONFIG=1
      shift
      ;;
    --template)
      [[ $# -ge 2 ]] || { echo 'Missing value for --template.' >&2; exit 1; }
      TEMPLATE="$2"
      shift 2
      ;;
    --extension|--extensions)
      [[ $# -ge 2 ]] || { echo "Missing value for $1." >&2; exit 1; }
      EXTENSIONS+=("$2")
      shift 2
      ;;
    --variable|--variables)
      [[ $# -ge 2 ]] || { echo "Missing value for $1." >&2; exit 1; }
      VARIABLES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (( $# > 0 )); do
        if [[ -n "$TARGET" ]]; then
          echo "Unexpected argument: $1" >&2
          exit 1
        fi
        TARGET="$1"
        shift
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      TARGET="$1"
      shift
      ;;
  esac
done


if [[ -z "$TARGET" ]]; then
  usage >&2
  exit 1
fi
if [[ "$TEMPLATE" == 'default' ]]; then
  TEMPLATE='base'
fi
if [[ "$TEMPLATE" != 'base' ]]; then
  echo "Template '$TEMPLATE' is not available. The repository provides the 'base' template." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_ROOT="$REPO_ROOT/template/base"
EXTENSIONS_ROOT="$REPO_ROOT/template/extensions"
STATE_RELATIVE='.sdlc/sdlc-installer-state.json'
STATE_KEY="$STATE_RELATIVE"
MANIFEST_PATH="$REPO_ROOT/template/manifest.yml"

if [[ ! -d "$TEMPLATE_ROOT" ]]; then
  echo "Base template not found: $TEMPLATE_ROOT" >&2
  exit 1
fi

declare -A planned_source=()
declare -A planned_render=()
declare -A planned_layer=()
declare -a plan_order=()

die() {
  echo "$1" >&2
  exit 1
}

normalize_path() {
  local value="$1"
  value="${value//\\//}"
  while [[ "$value" == ./* ]]; do
    value="${value#./}"
  done
  value="${value#/}"
  printf '%s' "$value"
}

assert_safe_relative_path() {
  local value="$1"
  case "$value" in
    ''|/*|../*|*/../*|..)
      die "Template output path must be relative to the target: $value"
      ;;
  esac
}

add_file_to_plan() {
  local root="$1"
  local file="$2"
  local layer="$3"
  local relative="${file#"$root"/}"
  local output render

  [[ "$relative" == .git/* || "$relative" == .git ]] && return
  output="$(normalize_path "$relative")"
  render=0
  case "$output" in
    *.template)
      output="${output%.template}"
      render=1
      ;;
    *.tmpl)
      output="${output%.tmpl}"
      render=1
      ;;
  esac
  assert_safe_relative_path "$output"

  if [[ -n "${planned_source[$output]+present}" ]]; then
    if [[ "${planned_layer[$output]}" == "$layer" ]]; then
      die "Template layer '$layer' produces more than one file for '$output'."
    fi
  else
    plan_order+=("$output")
  fi

  planned_source["$output"]="$file"
  planned_render["$output"]="$render"
  planned_layer["$output"]="$layer"
}

add_root_to_plan() {
  local root="$1"
  local layer="$2"
  local file

  while IFS= read -r -d '' file; do
    add_file_to_plan "$root" "$file" "$layer"
  done < <(find "$root" -type f -print0)
}

resolve_extension_root() {
  local name="$1"
  local candidate

  [[ -n "$name" ]] || die 'Extension names cannot be empty.'
  if [[ "$name" == /* || "$name" == */* ]]; then
    [[ -d "$name" ]] || die "Extension path not found: $name"
    (cd "$name" && pwd)
    return
  fi

  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid extension name: $name"
  candidate="$EXTENSIONS_ROOT/$name"
  [[ -d "$candidate" ]] || die "Extension '$name' was not found: $candidate"
  (cd "$candidate" && pwd)
}

read_manifest_base_installs() {
  local manifest="$1"
  [[ -f "$manifest" ]] || die "Template manifest not found: $manifest"
  tr -d '\r' < "$manifest" | awk '
    {
      tmp = $0
      sub(/^[ \t]+/, "", tmp)
      if (tmp == "" || tmp ~ /^#/) next
      match($0, /^[ ]*/)
      indent = RLENGTH
      if (indent == 0) {
        inbase = (tmp ~ /^base:/)
        ininstalls = 0
        next
      }
      if (!inbase) next
      if (ininstalls) {
        if (indent > installs_indent && tmp ~ /^-/) {
          val = tmp
          sub(/^-[ \t]*/, "", val)
          sub(/[ \t]+$/, "", val)
          if (val != "") print val
          next
        }
        ininstalls = 0
      }
      if (tmp ~ /^installs:/) {
        ininstalls = 1
        installs_indent = indent
      }
    }
  '
}

assert_manifest_covers_base() {
  local manifest="$1"
  (( ${#manifest_installs[@]} > 0 )) || die "Template manifest lists no base.installs entries: $manifest"

  local uncovered=() unmatched=()
  local output entry covered matched

  for output in "${base_outputs[@]}"; do
    covered=0
    for entry in "${manifest_installs[@]}"; do
      if [[ "$entry" == */ ]]; then
        [[ "$output" == "$entry"* ]] && { covered=1; break; }
      else
        [[ "$output" == "$entry" ]] && { covered=1; break; }
      fi
    done
    (( covered )) || uncovered+=("$output")
  done

  for entry in "${manifest_installs[@]}"; do
    matched=0
    for output in "${base_outputs[@]}"; do
      if [[ "$entry" == */ ]]; then
        [[ "$output" == "$entry"* ]] && { matched=1; break; }
      else
        [[ "$output" == "$entry" ]] && { matched=1; break; }
      fi
    done
    (( matched )) || unmatched+=("$entry")
  done

  if (( ${#uncovered[@]} > 0 || ${#unmatched[@]} > 0 )); then
    local message="template/manifest.yml is out of sync with template/base."
    (( ${#uncovered[@]} > 0 )) && message+=" Base files missing from the manifest: ${uncovered[*]}."
    (( ${#unmatched[@]} > 0 )) && message+=" Manifest entries with no matching base file: ${unmatched[*]}."
    message+=" Update base.installs in $manifest."
    die "$message"
  fi
}

add_root_to_plan "$TEMPLATE_ROOT" "template '$TEMPLATE'"

base_outputs=("${plan_order[@]}")
manifest_installs=()
while IFS= read -r manifest_item; do
  [[ -n "$manifest_item" ]] || continue
  manifest_installs+=("$(normalize_path "$manifest_item")")
done < <(read_manifest_base_installs "$MANIFEST_PATH")
assert_manifest_covers_base "$MANIFEST_PATH"

resolved_extensions=()
for extension in "${EXTENSIONS[@]}"; do
  extension_root="$(resolve_extension_root "$extension")"
  duplicate=0
  for resolved in "${resolved_extensions[@]}"; do
    [[ "$resolved" == "$extension_root" ]] && duplicate=1
  done
  if (( duplicate == 1 )); then
    continue
  fi
  resolved_extensions+=("$extension_root")
  add_root_to_plan "$extension_root" "extension '$extension'"
done

(( ${#plan_order[@]} > 0 )) || die "Template '$TEMPLATE' does not contain any installable files."
[[ "${plan_order[*]}" != *"$STATE_KEY"* ]] || die "Templates cannot install '$STATE_RELATIVE'."

mkdir -p "$TARGET"
TARGET_ROOT="$(cd "$TARGET" && pwd -P)"
PROJECT_NAME="$(basename "$TARGET_ROOT")"

declare -A tokens=()
tokens[ProjectName]="$PROJECT_NAME"
tokens[ProjectRoot]="$TARGET_ROOT"
tokens[Template]="$TEMPLATE"
for definition in "${VARIABLES[@]}"; do
  [[ "$definition" == *=* ]] || die "Template variable '$definition' must use Name=Value form."
  name="${definition%%=*}"
  value="${definition#*=}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid template variable name: $name"
  tokens["$name"]="$value"
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    die 'A SHA-256 utility is required: sha256sum, shasum, or openssl.'
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

state_path="$TARGET_ROOT/$STATE_RELATIVE"
state_dir="$(dirname "$state_path")"
declare -A managed_hash=()
if [[ -e "$state_path" ]]; then
  [[ -f "$state_path" ]] || die "Installer state path is not a file: $state_path"
  grep -Eq '"schemaVersion"[[:space:]]*:[[:space:]]*1' "$state_path" || die "Unrecognized installer state: $state_path"
  grep -Eq '"installer"[[:space:]]*:[[:space:]]*"Copilot-SDLC-Demo"' "$state_path" || die "Unrecognized installer state: $state_path"
  pending_path=''
  while IFS= read -r line; do
    path_value="$(printf '%s\n' "$line" | sed -nE 's/.*"path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    hash_value="$(printf '%s\n' "$line" | sed -nE 's/.*"hash"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    [[ -n "$path_value" ]] && pending_path="$(normalize_path "$path_value")"
    if [[ -n "$hash_value" && -n "$pending_path" ]]; then
      assert_safe_relative_path "$pending_path"
      [[ "$pending_path" != "$STATE_KEY" ]] || die "Installer state contains its own state path."
      managed_hash["$pending_path"]="$hash_value"
      pending_path=''
    fi
  done < "$state_path"
fi
[[ ! -f "$state_dir" ]] || die "Cannot write installer state because '$state_dir' is a file."

is_project_owned() {
  case "$1" in
    .github/sdlc-config.yml|docs/spec.md) return 0 ;;
    *) return 1 ;;
  esac
}

render_or_copy() {
  local source="$1"
  local destination="$2"
  local render="$3"

  mkdir -p "$(dirname "$destination")"
  if [[ "$render" == 1 ]]; then
    local content name token
    content="$(<"$source")"
    for name in "${!tokens[@]}"; do
      content="${content//\{\{$name\}\}/${tokens[$name]}}"
    done
    printf '%s' "$content" > "$destination"
  else
    cp "$source" "$destination"
  fi
}

declare -A next_hash=()
written=0
untouched=0
echo "Installing SDLC template '$TEMPLATE' into: $TARGET_ROOT"

for relative in "${plan_order[@]}"; do
  source="${planned_source[$relative]}"
  destination="$TARGET_ROOT/$relative"

  if is_project_owned "$relative"; then
    if [[ -e "$destination" ]]; then
      echo "  kept    $relative (project-owned)"
      (( untouched += 1 ))
    else
      render_or_copy "$source" "$destination" "${planned_render[$relative]}"
      echo "  installed $relative (project-owned default)"
      (( written += 1 ))
    fi
    continue
  fi

  if [[ -e "$destination" ]]; then
    if [[ ! -f "$destination" ]]; then
      echo "  skipped $relative: destination is a directory" >&2
      (( untouched += 1 ))
      continue
    fi
    if [[ -z "${managed_hash[$relative]+present}" ]]; then
      echo "  kept    $relative (project-owned)"
      (( untouched += 1 ))
      continue
    fi

    recorded_hash="${managed_hash[$relative]}"
    current_hash="$(sha256_file "$destination")"
    if [[ "$current_hash" != "$recorded_hash" ]]; then
      echo "  kept    $relative (modified after install)"
      (( untouched += 1 ))
      continue
    fi

    next_hash["$relative"]="$recorded_hash"
    if (( FORCE == 0 )); then
      echo "  kept    $relative (installer-owned; use --force to refresh)"
      (( untouched += 1 ))
      continue
    fi
    verb='updated'
  else
    verb='installed'
  fi

  render_or_copy "$source" "$destination" "${planned_render[$relative]}"
  next_hash["$relative"]="$(sha256_file "$destination")"
  echo "  $verb  $relative"
  (( written += 1 ))
done

mkdir -p "$state_dir"
state_tmp="$state_path.tmp"
{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "installer": "Copilot-SDLC-Demo",\n'
  printf '  "template": "%s",\n' "$(json_escape "$TEMPLATE")"
  printf '  "extensions": ['
  for (( index = 0; index < ${#EXTENSIONS[@]}; index++ )); do
    (( index > 0 )) && printf ', '
    printf '"%s"' "$(json_escape "${EXTENSIONS[$index]}")"
  done
  printf '],\n  "files": [\n'
  sorted_keys=()
  if (( ${#next_hash[@]} > 0 )); then
    mapfile -t sorted_keys < <(printf '%s\n' "${!next_hash[@]}" | LC_ALL=C sort)
  fi
  for (( index = 0; index < ${#sorted_keys[@]}; index++ )); do
    relative="${sorted_keys[$index]}"
    (( index > 0 )) && printf ',\n'
    printf '    {"path": "%s", "hash": "%s"}' "$(json_escape "$relative")" "$(json_escape "${next_hash[$relative]}")"
  done
  printf '\n  ]\n}\n'
} > "$state_tmp"
mv "$state_tmp" "$state_path"
echo "  recorded installer ownership in $STATE_RELATIVE"
echo
echo "Done. Wrote $written file(s); left $untouched existing file(s) untouched."
echo "Project-owned files are preserved; use --force to refresh unchanged template-owned files."
if (( VALIDATE_CONFIG == 1 )); then
  bash "$TARGET_ROOT/scripts/validate-sdlc-config.sh" --repo-root "$TARGET_ROOT"
  echo "Configuration validation passed."
else
  echo "[INCOMPLETE] Run scripts/validate-sdlc-config.sh after configuring .github/sdlc-config.yml. Use --validate-config to enforce this during scaffolding."
fi
echo "Open '$TARGET_ROOT' in VS Code and reload the window to pick up the agents."
