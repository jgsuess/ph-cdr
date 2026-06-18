#!/usr/bin/env bash
# Install local git hooks for ph-cdr.
# Run once after cloning: bash scripts/install-hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_SRC="${SCRIPT_DIR}/hooks"
HOOKS_DST="$(git -C "$SCRIPT_DIR" rev-parse --git-dir)/hooks"

for hook in "$HOOKS_SRC"/*; do
  name=$(basename "$hook")
  dest="${HOOKS_DST}/${name}"
  cp "$hook" "$dest"
  chmod +x "$dest"
  echo "  installed: .git/hooks/${name}"
done

echo ""
echo "Git hooks installed. Commits will now be validated against"
echo "conventional commits format (feat|fix|docs|ci|chore|...)."
