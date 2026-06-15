---
name: fusion-open
description: OPEN question with no answer yet (what to build next, how should page X work) — Claude + an adversarial reviewer model propose INDEPENDENTLY in parallel, then merge via debate to consensus (round cap), present the user a final plan. Use when the user asks an open question and wants both to think — /fusion-open, "let the reviewer think too", "both of you propose", "fusion open".
---

# Fusion open-question (Claude ↔ reviewer propose in parallel)

Full mechanism + rules: `docs/AGENT-FUSION.md`. Unlike `fusion-plan`: here NObody has an answer yet — both sides propose independently, then merge. It is NOT "Claude proposes a plan and the reviewer attacks it".

**When to use this instead of `fusion-plan`:** an open question whose basis lives in the project memory + repo ("what next", "how should the Reports page work", "which priority"). The reviewer reads memory + repo and that is the full picture — equal to Claude opening a fresh session. If the user just locked a constraint that lives ONLY in the chat (not in memory) → put it into the question/proposal so the reviewer sees it.

## Step 1 — Claude proposes INDEPENDENTLY FIRST (before reading the reviewer)
REQUIRED: write your own proposal BEFORE calling the reviewer — so you are not anchored to it. Save `<STATE_DIR>/open-<RUNID>/claude-proposal.md` (RUNID = `<YYYYMMDD-HHMM>-<slug>`): 2-3 directions, each idea + why + trade-offs + concrete tasks, then recommend one + why. Anchor to the project memory (product goals, build order, work in progress) + repo rules.

## Step 2 — Reviewer proposes INDEPENDENTLY (blind, in parallel)
- Run: `bin/fusion.sh open propose "<open question>" <RUNID>`
- The reviewer reads memory + repo and proposes 2-3 directions — it does NOT see Claude's proposal (the script forces blind, to keep independence). Saved to `reviewer-proposal.txt`.
- **exit 3 (FAIL-CLOSED)** → reviewer errored, tell the user.

## Step 3 — Claude merges + reconciles (OBJECTIVE — guard against self-bias)
⚠️ Claude is BOTH a proposer AND the merger → easy to favor your own proposal. Merge by **explicit objective criteria, NO "because it's mine"**: repo/memory rules · blast radius (touches little/much) · token cost · operational complexity · can the (non-technical) user actually use it. Read `reviewer-proposal.txt` next to `claude-proposal.md`:
- **Overlap** (both proposed it independently) = the strongest signal → into the final plan.
- **Complement** (one side saw a direction/risk the other missed) → consider merging in.
- **Divergence** (the two clash on direction/priority) → needs debate.
- **Every REJECTED direction needs a concrete reason** per the criteria above — do not reject the reviewer's idea by silence.

**Early consensus:** if no meaningful divergence remains → finalize NOW, present to the user (Step 5), SKIP the debate. Don't burn tokens on a needless round.

## Step 4 — Debate the divergences (only if they clash, round cap)
- Write the reconciliation file `<STATE_DIR>/open-<RUNID>/debate-<N>.md`: summarize both proposals, list the DIVERGENCES + Claude's argument for each + the reason each rejected direction was rejected (Step 3).
- Run: `bin/fusion.sh open debate <file> <RUNID>` (SAME RUNID → the script counts rounds).
- The script auto-attaches the **verbatim text of both proposals** (`claude-proposal.md` + `reviewer-proposal.txt`) to the prompt → the reviewer first checks whether Claude's summary is honest before arguing; distortion/omission → it returns REVISE. (This is the main anti-bias layer — no separate judge model needed.)
- Handle exit code:
  - **0 (CONSENSUS)** → no divergence left, go to Step 5.
  - **1 (REVISE, under cap)** → read `debate-<N>.txt`: if the reviewer accuses your summary of being skewed → FIX it honestly (don't argue to win); if it's a real disagreement → ACCEPT the valid points, PUSH BACK on the wrong ones. Write the next round and call again.
  - **10 (REVISE, hit cap)** → do NOT keep debating. Present to the user in **5 sections** (agreed / still in conflict / reviewer was right / Claude holds / blind spot) to decide.
  - **3 (FAIL-CLOSED)** → tell the user.

## Step 5 — Present the final plan (3 fixed sections)
Present CONCISELY in exactly 3 sections, do NOT make the user read the debate transcript:
1. **Both agreed** — where the two independent proposals overlapped (highest confidence).
2. **Divergence resolved** — where they clashed, which way it was settled + why (per the Step 3 criteria).
3. **Final recommendation** — the final plan + recommendation.

WAIT for the user's approval before coding (via `fusion-plan` if that plan is non-trivial, or straight to work if the user is OK).

## Arbiter (rare fallback — NOT default)
Add one extra reviewer pass to audit the final for bias ONLY when: (a) a debate round had the reviewer accuse "Claude's summary is dishonest", or (b) the final plan touches schema/API/runtime/secret/deploy/deps heavily. Happy path skips it — the verbatim-two-proposals + audit-prompt in Step 4 is enough; an extra pass is wasted tokens.

## Forbidden
- Do NOT read the reviewer's proposal before writing your own (Step 1 before Step 2).
- Do NOT reject the reviewer's proposal by silence — give a reason (Step 3).
- Do NOT start coding until the user approves.
- Do NOT commit/push (keep the repo's own rules).
