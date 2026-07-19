#!/usr/bin/env bash
#
# scaffold-sdlc.sh — Scaffold the Copilot SDLC customization files into a target folder.
#
# Copies the .github customization (agents, instructions, prompts,
# copilot-instructions.md) and docs/spec.md from this repo into a target folder,
# and ensures src/ and tests/ exist. Whole directories are copied, so new or
# renamed agents are picked up automatically.
#
# Usage:
#   ./scripts/scaffold-sdlc.sh <target> [--force]
#
# Examples:
#   ./scripts/scaffold-sdlc.sh ../my-project
#   ./scripts/scaffold-sdlc.sh /code/my-project --force

set -euo pipefail

FORCE=0
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$arg"
      else
        echo "Unexpected argument: $arg" >&2
        exit 1
      fi
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "Usage: $0 <target> [--force]" >&2
  exit 1
fi

# Repo root is the parent of this script's folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCES=(
  ".github/copilot-instructions.md"
  ".github/sdlc-config.yml"
  ".github/agents"
  ".github/instructions"
  ".github/prompts"
  ".github/workflows"
  "docs/spec.md"
  "scripts/check-phase.ps1"
  "scripts/check-phase.sh"
  "scripts/scope-audit.ps1"
  "scripts/scope-audit.sh"
)

# Verify we are running from a populated source repo.
for rel in "${SOURCES[@]}"; do
  if [ ! -e "$REPO_ROOT/$rel" ]; then
    echo "Source not found: $REPO_ROOT/$rel" >&2
    echo "Run this script from a clone of the Copilot-SDLC-Demo repo." >&2
    exit 1
  fi
done

mkdir -p "$TARGET"
TARGET_ROOT="$(cd "$TARGET" && pwd)"

echo "Scaffolding SDLC customization into: $TARGET_ROOT"

for rel in "${SOURCES[@]}"; do
  src="$REPO_ROOT/$rel"
  dest="$TARGET_ROOT/$rel"
  dest_parent="$(dirname "$dest")"
  mkdir -p "$dest_parent"

  if [ -e "$dest" ] && [ "$FORCE" -ne 1 ]; then
    read -r -p "Exists: $rel. Overwrite? (y/N) " answer
    case "$answer" in
      y|Y) ;;
      *) echo "  skipped $rel"; continue ;;
    esac
  fi

  rm -rf "$dest"
  cp -R "$src" "$dest_parent/"
  echo "  copied  $rel"
done

# Ensure src/ and tests/ exist with a .gitkeep.
for dir in src tests; do
  mkdir -p "$TARGET_ROOT/$dir"
  touch "$TARGET_ROOT/$dir/.gitkeep"
  echo "  ensured $dir/"
done

echo ""
echo "Done. Next steps:"
echo "  1. Open '$TARGET_ROOT' in VS Code."
echo "  2. Reload the window so the agents are picked up."
echo "  3. Select the 'sdlc-supervisor' agent and describe what to build."
