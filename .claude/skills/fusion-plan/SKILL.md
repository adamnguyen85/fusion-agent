---
name: fusion-plan
description: Push a plan Claude just proposed through an adversarial reviewer model (Codex/Gemini) to debate it to consensus before building. Use when the user types /fusion-plan or says "have the reviewer critique this plan", "debate this with Codex", "fusion plan". For NON-trivial plans (touches schema/API/runtime/secret/deploy/deps or >2 logic files).
---

# Fusion plan-debate (Claude ↔ reviewer model)

Full mechanism + rules: `docs/AGENT-FUSION.md`. This skill only enforces the sequence. Do NOT skip steps.

## Step 1 — Pin the plan to debate
- The plan = the non-trivial plan Claude JUST proposed to the user (most recent turn), NOT yet approved.
- No clear plan in the conversation → STOP, ask the user "which plan do you want debated".

## Step 2 — Write the plan to a file (pack enough context for the reviewer)
The reviewer can NOT read the user↔Claude conversation — it only has your project memory files + this plan file + the repo (read-only). A thin plan file means a blind debate. Write `<STATE_DIR>/<RUNID>/current-plan.md` (RUNID = `<YYYYMMDD-HHMM>-<slug>`) with 5 sections:

1. **Context** (REQUIRED — distilled from the chat, do NOT paste the raw transcript): the goal, constraints/decisions the user just locked in, directions considered then REJECTED + why. This is the reviewer's "big picture". **Cite SOURCES** (file + section, e.g. `AGENTS.md`, `CLAUDE.md`, a design doc) so the reviewer can verify rather than trust your summary — this blocks biased framing.
2. **Plan**: the work, step by step.
3. **Files touched**: concrete paths (so the reviewer knows where to read, no blind review).
4. **Assumptions**: what you're relying on.
5. **Expected tests**: how this plan gets verified.

Distill the *why + constraints*, enough for a focused debate — don't dump the whole chat (noisy + token-heavy).

## Step 3 — Call the reviewer
- Run: `bin/fusion.sh plan <STATE_DIR>/<RUNID>/current-plan.md <RUNID>`
- The script injects the system prompt (read memory first, "this is a PLAN, no code yet"), validates the verdict, counts rounds (cap).

## Step 4 — Handle by exit code
- **0 (CONSENSUS)** → present the final plan to the user + a summary: "what the reviewer caught, what Claude changed/held and why". WAIT for approval before coding.
- **1 (REVISE, under cap)** → read `<STATE_DIR>/<RUNID>/critique-*.txt`. Revise the plan: ACCEPT the valid points, PUSH BACK on the wrong ones (don't swallow blindly). Overwrite `current-plan.md` and repeat Step 3 (SAME RUNID → the script auto-increments the round).
- **10 (REVISE, hit cap)** → do NOT keep debating. Present to the user in **5 sections** (forces disagreement into the open instead of mushing it together):
  1. **Agreed** — what both sides converged on (highest confidence).
  2. **Still in conflict** — where the two sides still clash: each side's position + evidence, what the user must decide.
  3. **Reviewer was right** — points Claude accepted/fixed.
  4. **Claude holds** — points Claude argued and won, why.
  5. **Blind spot** — what both might be missing (Claude raises it, even outside the debate).
  Then let the user decide the conflicts in section 2.
- **3 (FAIL-CLOSED)** → reviewer errored / no valid verdict. Tell the user "fusion unavailable — present the plan as-is, or wait?". Do NOT silently skip.

## Forbidden
- Do NOT start coding until the user approves the final plan.
- Do NOT commit/push (keep the repo's own rules).
