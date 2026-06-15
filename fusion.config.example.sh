# fusion-agent config — copy this to fusion.config.sh in your repo root and edit.
# fusion.config.sh is gitignored (so your project rules never leak into this shared repo).
# Every value here is optional; fusion.sh has sane defaults.

# --- Reviewer model (the adversary that debates Claude) ----------------------
# Must read the prompt from STDIN and run READ-ONLY. Swap this line to use a
# different CLI (Gemini, a local model, etc.) as long as it reads stdin.
REVIEWER_CMD="codex exec -s read-only -"
REVIEWER_NAME="Codex (gpt-5.5)"

# --- Project memory ----------------------------------------------------------
# Files the reviewer is told to read first (your "rules + locked decisions").
# Space-separated, relative to repo root.
MEMORY_FILES="AGENTS.md CLAUDE.md README.md"

# --- Review rules (optional) -------------------------------------------------
# Extra project-specific rules injected into `review` mode. Leave empty for a
# generic correctness review. Example of the shape (use your own repo's rules):
# PROJECT_RULES="all timestamps are UTC; no raw SQL outside the data layer;
# every API response is paginated; secrets are never logged."
PROJECT_RULES=""

# --- Round cap & state -------------------------------------------------------
ROUND_CAP=3
STATE_DIR=".agent/fusion"

# --- Secret paths never sent to the reviewer ---------------------------------
# The built-in defaults (*.env*, *.pem, *.key, *.p12, id_rsa*, *.keystore,
# *credentials*, *secret*, secrets/) are ALWAYS applied and cannot be removed
# here — so a typo can never weaken secret protection. To exclude MORE paths,
# append them (this is additive, not a replacement):
EXTRA_SECRET_EXCLUDE_GLOBS=()   # e.g. ( 'config/*.token' 'private/' )
