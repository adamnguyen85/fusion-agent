# fusion-agent — Claude Code ↔ an adversarial reviewer model

The canonical doc for the mechanism. The skill files only enforce sequence; the rules live here.

Inspired by [OpenRouter Fusion](https://x.com/OpenRouter/status/2065856853989270011) (a compound model that blends several models into one answer), applied to coding: **two models argue; an answer only ships after it survives the critique.** It does NOT use a Fusion API — instead two coding agents work the same repo: Claude Code (the builder) and a reviewer model run headless via a CLI (Codex `gpt-5.5` by default; swap it in config).

## The three modes

### 1. Plan-debate — `/fusion-plan`
You have a plan and want it stress-tested before building. Claude writes the plan to a file, the reviewer critiques the DESIGN (not implementation — no code exists yet), and they iterate to consensus.

1. Claude writes the plan → `<STATE_DIR>/<runid>/current-plan.md` (gitignored).
2. `bin/fusion.sh plan <planfile> <runid>` → reviewer reads project memory first, critiques the design.
3. Read the verdict (last line `VERDICT: CONSENSUS|REVISE`):
   - **REVISE** → Claude revises: accept the right points, **push back on the wrong ones** (no blind swallowing) → call again.
   - **CONSENSUS** → present the final plan + "what the reviewer caught, what Claude changed/held and why".
4. **Round cap (default 3).** Cap hit without consensus → present in **5 sections** (agreed / still in conflict / reviewer right / Claude holds / blind spot) for the human to decide — no infinite deadlock, no mushing two views together.

### 2. Review — large/complex changes only
Trigger: schema/migration, API contract, runtime/security code, or >2 logic files. **Small UI/UX does NOT call this.**

`bin/fusion.sh review <base> <runid> [test_cmd]` → (if `test_cmd` given) Claude runs the REAL test/build and injects pass/fail into the bundle → builds the diff bundle (tracked diff + **untracked new files**, secrets excluded) → reviewer audits read-only for bugs + rule violations **grounded in real execution** → Claude fixes the real ones, pushes back on the wrong ones → reports. *Verify-by-execution: running the code beats reading the diff; the reviewer still stays read-only, only Claude runs tests.*

### 3. Open-question — `/fusion-open`
Unlike `plan`: there is NO plan to attack yet — both sides propose INDEPENDENTLY, then merge (a 2-model panel, cheap). Use it for "what next / how should page X work / which priority" — the basis lives in memory + repo, so the reviewer reads it directly; Claude does NOT need to pre-write a plan.

1. Claude writes its own proposal FIRST → `<STATE_DIR>/open-<runid>/claude-proposal.md` (before reading the reviewer, to avoid anchoring).
2. `bin/fusion.sh open propose "<question>" <runid>` → reviewer proposes **blind** (does not see Claude's proposal) → `reviewer-proposal.txt`.
3. Claude merges by **objective criteria** (rules/memory · blast radius · token · operations · can the user use it), forbidding "because it's mine"; every rejected direction gets a reason. Overlap = high confidence, divergence = debate. **No divergence left → finalize immediately (early consensus), skip the debate.**
4. Still divergent → `bin/fusion.sh open debate <file> <runid>` → the script auto-attaches the **verbatim text of both proposals** → the reviewer checks whether Claude's summary is honest (distortion → REVISE) before arguing (verdict CONSENSUS/REVISE, **round cap**, early consensus stops). Cap hit → 5-section escalation. *This is the layer against Claude "refereeing its own match" — no separate arbiter model needed.*
5. Present the human **3 fixed sections**: `Both agreed` / `Divergence resolved` / `Final recommendation` — no transcript reading. (An extra arbiter pass is a rare fallback only when the merge is suspected biased or the plan touches schema/API/runtime/secret/deploy/deps.)

## Hard rules of the mechanism
- **The reviewer must NOT edit code** — verdict + findings only. Runs read-only.
- **Fail-CLOSED:** reviewer error / timeout / no valid verdict (exit 3) → Claude **tells the human**, never silently skips.
- **No auto commit/push** — keep your repo's own rules.
- **Secrets stay out:** every diff/ls-files excludes the secret globs in config (`*.env*`, `*.pem`, `*.key`, …).
- Debate state lives in `<STATE_DIR>/` (gitignored) — no repo clutter.

## Exit codes (Claude reads to decide)
| code | meaning |
|---|---|
| 0  | CONSENSUS (plan/open) / review done |
| 1  | REVISE, under cap → revise and call again |
| 10 | REVISE, hit the cap → escalate to the human (5 sections) |
| 3  | FAIL-CLOSED (reviewer error) → tell the human |
| 2  | bad usage |

## How it differs from a compound model (OpenRouter Fusion)
- A **compound model / parallel panel** ([OpenRouter Fusion](https://x.com/OpenRouter/status/2065856853989270011), and clones like fusion-fable): several models answer independently, a judge blends them. One question → one high-quality answer. Repo-blind, costs N×.
- **fusion-agent**: sequential adversarial debate + co-proposal, repo-aware, 2 models max, cheap. The reviewer reads your actual repo and runs against real test output. Different tool for a different job.

## Environment
- A reviewer CLI that reads a prompt from stdin and runs read-only. Default: Codex CLI (`npm i -g @openai/codex`, model `gpt-5.5`, auth via `~/.codex`). Swap `REVIEWER_CMD` in `fusion.config.sh` for any other.
- Run from anywhere inside the target git repo — the script resolves the repo root itself.
