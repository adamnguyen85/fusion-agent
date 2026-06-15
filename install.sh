#!/usr/bin/env bash
# fusion-agent installer.
# Installs the three skills into the current repo's .claude/skills and makes
# bin/fusion.sh executable. Run from the root of the repo you want to use it in,
# OR pass a target repo path: ./install.sh /path/to/your/repo
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$(pwd)}"

if [ ! -d "$TARGET/.git" ]; then
  echo "warning: $TARGET is not a git repo root. fusion.sh resolves the git root at runtime, but skills install into .claude/skills here." >&2
fi

echo "Installing fusion-agent into: $TARGET"

# 1) Skills -> <target>/.claude/skills/
mkdir -p "$TARGET/.claude/skills"
for s in fusion-plan fusion-open fusion-review; do
  cp -R "$SRC/.claude/skills/$s" "$TARGET/.claude/skills/"
  echo "  + .claude/skills/$s"
done

# 2) Make the script executable.
chmod +x "$SRC/bin/fusion.sh"
echo "  + bin/fusion.sh is executable"

# 3) Seed config if absent.
if [ ! -f "$TARGET/fusion.config.sh" ]; then
  cp "$SRC/fusion.config.example.sh" "$TARGET/fusion.config.sh"
  echo "  + fusion.config.sh (copied from example — EDIT it: reviewer command, memory files, project rules)"
else
  echo "  = fusion.config.sh already exists, left untouched"
fi

cat <<EOF

Done. Next:
  1. Edit $TARGET/fusion.config.sh (reviewer command + MEMORY_FILES + PROJECT_RULES).
  2. Make sure your reviewer CLI works headless (default: 'codex exec -s read-only -').
  3. Add $SRC/bin to PATH, or call it as $SRC/bin/fusion.sh.
  4. Add '.agent/' and 'fusion.config.sh' to your repo's .gitignore.
  5. In Claude Code: /fusion-plan, /fusion-open, /fusion-review.

See docs/AGENT-FUSION.md for the full mechanism.
EOF
