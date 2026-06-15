#!/usr/bin/env bash
# fusion-agent — Claude Code <-> an adversarial reviewer model (Codex / Gemini / ...).
# Three modes: plan-debate, code-review, open-question. See docs/AGENT-FUSION.md.
#
# Usage:
#   fusion.sh plan   <planfile> [runid]            # reviewer critiques a PLAN (no code written yet)
#   fusion.sh review <base>     [runid] [test_cmd] # reviewer audits a diff (code already written)
#   fusion.sh open propose <"question"> [runid]    # OPEN question: reviewer proposes independently (blind)
#   fusion.sh open debate  <debatefile> [runid]    # merge two proposals -> debate, round cap
#
# Exit codes (Claude reads these to decide next step):
#   0  = CONSENSUS (plan/open) | review done
#   1  = REVISE, under cap -> Claude revises and calls again
#   10 = REVISE but HIT the round cap -> escalate to the human, do NOT keep debating
#   3  = FAIL-CLOSED (reviewer error / no valid verdict) -> report to the human, never silently skip
#   2  = bad usage
set -uo pipefail

# Operate on whatever git repo we're invoked from. fusion-agent is repo-aware
# (it diffs, reads memory, writes state) — refuse to run outside a git repo unless
# explicitly opted in, so we never source a config or write .agent in a random cwd.
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
elif [ "${FUSION_ALLOW_NO_GIT:-}" = "1" ]; then
  REPO_ROOT="$(pwd)"
else
  echo "[fusion] not inside a git repo. fusion-agent is repo-aware — run it from your project, or set FUSION_ALLOW_NO_GIT=1 to use the current directory." >&2
  exit 2
fi
cd "$REPO_ROOT" || { echo "[fusion] cannot cd to repo root" >&2; exit 2; }

# ---- Config -------------------------------------------------------------
# Secret-exclude defaults are an INVARIANT: always applied, never removable via
# config. Config may only APPEND extra globs (EXTRA_SECRET_EXCLUDE_GLOBS), so a
# config typo can never weaken secret protection.
DEFAULT_SECRET_EXCLUDE_GLOBS=( '*.env' '*.env.*' '*.pem' '*.key' '*.p12' 'id_rsa*' '*.keystore' '*credentials*' '*secret*' 'secrets/' )
EXTRA_SECRET_EXCLUDE_GLOBS=()   # init before sourcing so `set -u` is safe with no config

# Load per-project config if present (copy fusion.config.example.sh -> fusion.config.sh).
# NOTE: the config is `source`d — it is executable shell, so only run fusion-agent
# in a repo whose fusion.config.sh you trust.
CONFIG="${FUSION_CONFIG:-$REPO_ROOT/fusion.config.sh}"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG" || { echo "[fusion] failed to load config: $CONFIG" >&2; exit 2; }
fi

# Defaults (overridable by config or env).
REVIEWER_CMD="${REVIEWER_CMD:-codex exec -s read-only -}"   # must read the prompt from stdin; YOU must keep it read-only
REVIEWER_NAME="${REVIEWER_NAME:-the reviewer model}"
MEMORY_FILES="${MEMORY_FILES:-AGENTS.md CLAUDE.md README.md}" # files the reviewer must read first
PROJECT_RULES="${PROJECT_RULES:-}"                            # extra project-specific review rules (optional)
STATE_DIR="${STATE_DIR:-.agent/fusion}"
CAP="${ROUND_CAP:-3}"
case "$CAP" in ''|*[!0-9]*) echo "[fusion] ROUND_CAP must be a positive integer (got '$CAP')" >&2; exit 2;; esac
[ "$CAP" -ge 1 ] || { echo "[fusion] ROUND_CAP must be >= 1 (got '$CAP')" >&2; exit 2; }
# Final list = non-removable defaults + any extras from config (append-only).
SECRET_EXCLUDE_GLOBS=( "${DEFAULT_SECRET_EXCLUDE_GLOBS[@]}" )
[ "${#EXTRA_SECRET_EXCLUDE_GLOBS[@]}" -gt 0 ] && SECRET_EXCLUDE_GLOBS+=( "${EXTRA_SECRET_EXCLUDE_GLOBS[@]}" )

# Turn the globs into git pathspec excludes.
SECRET_EXCLUDES=()
for g in "${SECRET_EXCLUDE_GLOBS[@]}"; do SECRET_EXCLUDES+=( ":(exclude)$g" ); done

# Comma/space list of secret paths for the prompt text.
SECRET_LIST="$(printf '%s, ' "${SECRET_EXCLUDE_GLOBS[@]}")"; SECRET_LIST="${SECRET_LIST%, }"

SYSTEM_PROMPT="You are $REVIEWER_NAME, the ADVERSARIAL REVIEW PARTNER of Claude Code working on the same repository (by agreement with the repo owner).
REQUIRED reading before you answer: $MEMORY_FILES (project rules, locked decisions, gotchas).
Only read files/areas relevant to the plan or diff in question — do NOT scan the whole repo. NEVER read secret paths ($SECRET_LIST).
Read-only — do NOT modify any file. Answer concisely and go straight to the weak points."

# Run the reviewer with the prompt file on stdin. Reviewer stays read-only.
run_reviewer() { bash -c "$REVIEWER_CMD" < "$1"; }

# Scrub likely secrets from captured test/build output before it reaches the
# reviewer. The SECRET_EXCLUDES pathspec only guards git diff/ls-files; the
# test-output channel was unguarded — so a failing test that prints env could
# leak tokens through Fusion. Redact connection-string credentials,
# secret-named KEY=value / KEY: value pairs, AND JSON-quoted "key":"value"
# (a failing test often dumps JSON; the KEY[:=] regex misses it because the
# closing quote sits between the key and the colon, so the secret leaked).
# Secret names are matched case-insensitively, covering camelCase keys
# (pageAccessToken, clientSecret).
scrub_secrets() {
  perl -pe '
    s{([A-Za-z][A-Za-z0-9+.\-]*://[^:/@\s]+):[^@\s]+@}{$1:***REDACTED***@}g;
    s{("[A-Za-z0-9_-]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET|CREDENTIAL|AUTHORIZATION|BEARER)[A-Za-z0-9_-]*"\s*:\s*)"[^"]*"}{$1"***REDACTED***"}gi;
    s{\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET|CREDENTIAL|AUTHORIZATION|BEARER)[A-Z0-9_]*\s*[:=]\s*).+}{$1***REDACTED***}gi;
  ' "$1"
}

validate_verdict() {
  local out="$1" n="$2" last
  last="$(grep -v '^[[:space:]]*$' "$out" | tail -1 | tr -d '\r')"
  echo
  if [ "$last" = "VERDICT: CONSENSUS" ]; then
    echo "[fusion] round $n -> CONSENSUS"; exit 0
  elif [ "$last" = "VERDICT: REVISE" ]; then
    if [ "$n" -ge "$CAP" ]; then
      echo "[fusion] round $n -> REVISE — HIT CAP $CAP. Escalate to the human, do NOT keep debating."; exit 10
    fi
    echo "[fusion] round $n -> REVISE. Claude revises, then calls again (round $((n+1)))."; exit 1
  else
    echo "[fusion] FAIL-CLOSED: could not parse VERDICT (last line: '$last'). Reviewer error — report to the human." >&2
    exit 3
  fi
}

MODE="${1:-}"
case "$MODE" in
  plan)
    PLANFILE="${2:?missing planfile}"
    [ -f "$PLANFILE" ] || { echo "planfile not found: $PLANFILE" >&2; exit 2; }
    RUNID="${3:-$(date +%Y%m%d-%H%M%S)}"
    OUTDIR="$STATE_DIR/$RUNID"; mkdir -p "$OUTDIR"
    N=$(( $(ls "$OUTDIR"/critique-*.txt 2>/dev/null | wc -l | tr -d ' ') + 1 ))
    [ "$N" -le "$CAP" ] || { echo "[fusion] already past cap $CAP for run $RUNID" >&2; exit 10; }
    PROMPT="$OUTDIR/prompt-$N.md"
    {
      echo "$SYSTEM_PROMPT"; echo
      echo "=== THIS IS A PLAN DEBATE — NO CODE WRITTEN YET ==="
      echo "Do NOT go hunting the repo for files/scripts/implementation of this plan (it does NOT exist yet — Claude only builds AFTER both sides agree and the human approves)."
      echo "Only critique the DESIGN in the plan below: holes, over-engineering, rule violations, simpler approaches, operational risk."
      echo "If the plan is already good enough to implement, return CONSENSUS — do not nitpick for the sake of it."
      echo
      echo "=== PLAN (round $N/$CAP) ==="; cat "$PLANFILE"; echo
      echo "Open your reply with one line: \"Read: <file/section>\" (avoid blind judgement when context is missing)."
      echo "The LAST line must match exactly (no extra text): VERDICT: CONSENSUS  or  VERDICT: REVISE"
    } > "$PROMPT"
    cp "$PLANFILE" "$OUTDIR/plan-$N.md"
    OUT="$OUTDIR/critique-$N.txt"
    run_reviewer "$PROMPT" | tee "$OUT"; rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || { echo "[fusion] FAIL-CLOSED: reviewer exit $rc — report to the human." >&2; exit 3; }
    validate_verdict "$OUT" "$N"
    ;;
  review)
    BASE="${2:?missing base (e.g. main or HEAD)}"
    RUNID="${3:-$(date +%Y%m%d-%H%M%S)}"
    TEST_CMD="${4:-}"
    OUTDIR="$STATE_DIR/review-$RUNID"; mkdir -p "$OUTDIR"
    BUNDLE="$OUTDIR/bundle.diff"
    # Claude runs the REAL test/build (Claude drives it, NOT the reviewer — reviewer stays read-only).
    # Real pass/fail is stronger evidence than reading the diff alone.
    TEST_OUT="$OUTDIR/test-output.txt"; TEST_RC=""
    if [ -n "$TEST_CMD" ]; then
      echo "[fusion] running real test: $TEST_CMD" >&2
      bash -c "$TEST_CMD" > "$TEST_OUT" 2>&1; TEST_RC=$?
      echo "[fusion] test exit=$TEST_RC -> $TEST_OUT" >&2
    fi
    {
      echo "### TRACKED CHANGES (vs $BASE) ###"
      git diff "$BASE" -- . "${SECRET_EXCLUDES[@]}"
      echo; echo "### UNTRACKED NEW FILES ###"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "NEW FILE: $f"
        git diff --no-index /dev/null "$f" 2>/dev/null || true
        echo
      done < <(git ls-files --others --exclude-standard -- . "${SECRET_EXCLUDES[@]}")
    } > "$BUNDLE"
    PROMPT="$OUTDIR/prompt.md"
    {
      echo "$SYSTEM_PROMPT"; echo
      echo "=== CODE REVIEW (large/complex change) ==="
      echo "Find correctness BUGS and PROJECT-RULE violations."
      [ -n "$PROJECT_RULES" ] && { echo "Project-specific rules to enforce:"; echo "$PROJECT_RULES"; }
      echo "You may read callers/shared utils around the diff (read-only) — do NOT review blind."
      echo "Each finding: \`file:line\` + [HIGH|MED|LOW] + the problem + the rule/reason. Do NOT edit code, only list findings."
      if [ -n "$TEST_CMD" ]; then
        echo
        echo "=== REAL EXECUTION RESULT (test/build, exit=$TEST_RC) ==="
        echo "Command: $TEST_CMD"
        echo "EXECUTION EVIDENCE — trust this over speculation. If the tests pass but you still suspect a broken path, say 'not covered by tests'."
        echo '```'; scrub_secrets "$TEST_OUT"; echo '```'
      fi
      echo
      echo "=== DIFF BUNDLE ==="; cat "$BUNDLE"
    } > "$PROMPT"
    OUT="$OUTDIR/findings.txt"
    run_reviewer "$PROMPT" | tee "$OUT"; rc=${PIPESTATUS[0]}
    [ "$rc" -eq 0 ] || { echo "[fusion] FAIL-CLOSED: reviewer exit $rc — report to the human." >&2; exit 3; }
    echo; echo "[fusion] review done -> $OUT"
    ;;
  open)
    # OPEN question (no answer yet): both sides propose IN PARALLEL, INDEPENDENTLY -> Claude merges -> debate, cap.
    SUB="${2:?missing sub-mode: propose | debate}"
    case "$SUB" in
      propose)
        # Round 1 BLIND: reviewer proposes from the question + project memory only, does NOT see Claude's proposal.
        QUESTION="${3:?missing open question}"
        RUNID="${4:-$(date +%Y%m%d-%H%M%S)}"
        OUTDIR="$STATE_DIR/open-$RUNID"; mkdir -p "$OUTDIR"
        PROMPT="$OUTDIR/propose-prompt.md"
        {
          echo "$SYSTEM_PROMPT"; echo
          echo "=== OPEN QUESTION — INDEPENDENT PROPOSAL (round 1, BLIND) ==="
          echo "This open question has no answer yet. Claude is proposing IN PARALLEL and INDEPENDENTLY — you do NOT see Claude's proposal (deliberate: two independent directions, merged afterward, is where a panel beats a single model)."
          echo "Do NOT guess what Claude thinks. Read the project memory + repo yourself, propose 2-3 viable DIRECTIONS — each: the idea + why + trade-offs + concrete tasks. End with: RECOMMEND one direction + why."
          echo "Do NOT write code. Stay within the project rules + product goals in the memory files."
          echo
          echo "=== QUESTION ==="; echo "$QUESTION"; echo
          echo "Open your reply with one line: \"Read: <file/section>\"."
        } > "$PROMPT"
        OUT="$OUTDIR/reviewer-proposal.txt"
        run_reviewer "$PROMPT" | tee "$OUT"; rc=${PIPESTATUS[0]}
        [ "$rc" -eq 0 ] || { echo "[fusion] FAIL-CLOSED: reviewer exit $rc — report to the human." >&2; exit 3; }
        echo; echo "[fusion] reviewer proposal done -> $OUT. Claude compares with its own; aligned -> finalize, divergent -> 'open debate <file> $RUNID'."
        ;;
      debate)
        # Round 2+: Claude writes the merge/divergence file -> reviewer critiques + verdict. Round cap.
        DEBATEFILE="${3:?missing debatefile}"
        [ -f "$DEBATEFILE" ] || { echo "debatefile not found: $DEBATEFILE" >&2; exit 2; }
        RUNID="${4:-$(date +%Y%m%d-%H%M%S)}"
        OUTDIR="$STATE_DIR/open-$RUNID"; mkdir -p "$OUTDIR"
        N=$(( $(ls "$OUTDIR"/debate-*.txt 2>/dev/null | wc -l | tr -d ' ') + 1 ))
        [ "$N" -le "$CAP" ] || { echo "[fusion] already past cap $CAP for run $RUNID" >&2; exit 10; }
        CLAUDE_PROP="$OUTDIR/claude-proposal.md"
        REVIEWER_PROP="$OUTDIR/reviewer-proposal.txt"
        PROMPT="$OUTDIR/debate-prompt-$N.md"
        {
          echo "$SYSTEM_PROMPT"; echo
          echo "=== MERGE TWO PROPOSALS — DEBATE (round $N/$CAP) ==="
          echo "Both sides (Claude + you) proposed independently. Claude is the MERGING party — but Claude is also one of the proposers, so it MAY be biased. Below are the VERBATIM original proposals from both sides + Claude's reconciliation."
          echo "STEP 1 (required, before debating): check Claude's reconciliation against the two verbatim proposals — is the summary HONEST? Did it drop or distort any of your points, or tilt toward Claude's own proposal? If so -> name it explicitly and return VERDICT: REVISE."
          echo "STEP 2: if the summary is honest -> argue the divergences: what you HOLD (why), what you CONCEDE. Goal is to converge on one plan better than either. No meaningful divergence left -> CONSENSUS, do not nitpick."
          echo
          echo "=== [VERBATIM] CLAUDE'S PROPOSAL ==="; [ -f "$CLAUDE_PROP" ] && cat "$CLAUDE_PROP" || echo "(missing claude-proposal.md)"; echo
          echo "=== [VERBATIM] YOUR PROPOSAL (your own, from the propose round) ==="; [ -f "$REVIEWER_PROP" ] && cat "$REVIEWER_PROP" || echo "(missing reviewer-proposal.txt)"; echo
          echo "=== RECONCILIATION + DEBATE POINTS (written by Claude — CHECK honesty vs the two verbatim proposals above) ==="; cat "$DEBATEFILE"; echo
          echo "Open your reply with one line: \"Read: <file/section>\"."
          echo "The LAST line must match exactly (no extra text): VERDICT: CONSENSUS  or  VERDICT: REVISE"
        } > "$PROMPT"
        cp "$DEBATEFILE" "$OUTDIR/debate-input-$N.md"
        OUT="$OUTDIR/debate-$N.txt"
        run_reviewer "$PROMPT" | tee "$OUT"; rc=${PIPESTATUS[0]}
        [ "$rc" -eq 0 ] || { echo "[fusion] FAIL-CLOSED: reviewer exit $rc — report to the human." >&2; exit 3; }
        validate_verdict "$OUT" "$N"
        ;;
      *) echo "open sub-mode must be: propose | debate" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "Usage: fusion.sh plan   <planfile> [runid]" >&2
    echo "       fusion.sh review <base>     [runid] [test_cmd]" >&2
    echo "       fusion.sh open propose <\"question\"> [runid]   # round 1 blind" >&2
    echo "       fusion.sh open debate  <debatefile>  [runid]   # round 2+ verdict, round cap" >&2
    exit 2 ;;
esac
