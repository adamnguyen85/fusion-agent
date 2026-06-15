---
name: fusion-review
description: After writing a large/complex change, have an adversarial reviewer model (Codex/Gemini) audit the diff for bugs + rule violations, backed by REAL test/build output. Use when the user types /fusion-review or says "have the reviewer check this", "fusion review". For changes touching schema/migration, API contracts, runtime, or >2 logic files — NOT small UI tweaks.
---

# Fusion code-review (Claude ↔ reviewer model)

Full mechanism + rules: `docs/AGENT-FUSION.md`. This skill only enforces the sequence.

## Step 1 — Decide if review is warranted
Trigger: schema/migration, API contract, runtime/security-sensitive code, or >2 logic files. **Small UI/UX changes do NOT call this** — keep the repo's normal rules; don't downgrade to just "type-check passes".

## Step 2 — Pick the base + the real test command
- `base` = what to diff against (usually `main` or the branch point `HEAD~N`).
- `test_cmd` = the REAL build/test for the changed area (e.g. `npm test`, `npx tsc --noEmit`, `pytest -q`). Claude runs it — the reviewer stays read-only.

## Step 3 — Run the review
- Run: `bin/fusion.sh review <base> <RUNID> "<test_cmd>"`
  - Examples: `bin/fusion.sh review main 20260615-1500-auth "npm test"`
  - The script runs the real test, injects pass/fail as evidence, bundles the diff (tracked + untracked new files, secrets excluded), and has the reviewer audit it read-only.
- **exit 3 (FAIL-CLOSED)** → reviewer errored, tell the user. Do NOT silently skip.

## Step 4 — Act on findings
- Read `<STATE_DIR>/review-<RUNID>/findings.txt` and `test-output.txt`.
- For each finding: fix the REAL ones (root cause, not symptom); PUSH BACK on the wrong ones with evidence.
- If the test was red, fix to green and rerun before reporting.
- Report to the user: what was real + fixed, what you rejected + why.

## Forbidden
- The reviewer must NOT edit code — only list findings (runs read-only).
- Do NOT commit/push (keep the repo's own rules).
