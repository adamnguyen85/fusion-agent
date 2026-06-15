# fusion-agent

**Two AI coding agents argue on your repo so an answer only ships after it survives the critique.**

`fusion-agent` pairs **Claude Code** (the builder) with an **adversarial reviewer model** (Codex `gpt-5.5` by default, swappable) running headless and read-only. Instead of one model confidently shipping a plausible-but-wrong answer, a second model reads your actual repo, attacks the weak points, and they iterate to consensus — with a round cap so it never deadlocks.

It's a set of three [Claude Code](https://claude.com/claude-code) skills + one shell script. No API keys beyond the two CLIs you already have.

> Inspired by the idea behind OpenRouter Fusion (panel + cross-examination), but local, cheap, and repo-aware. See [how it differs](#how-it-differs) below.

## The three modes

| Mode | When | What happens |
|---|---|---|
| **`/fusion-plan`** | You have a plan, before building | Claude writes the plan to a file; the reviewer critiques the *design*; they debate to consensus (round cap). |
| **`/fusion-open`** | An open question, no answer yet | Both propose **independently in parallel** (reviewer is blind to Claude's idea), Claude merges by objective criteria, debate the divergences. |
| **`/fusion-review`** | Large change already written | Claude runs the **real test/build**, bundles the diff (secrets excluded), the reviewer audits read-only grounded in actual pass/fail. |

Every mode is **fail-closed** (a reviewer error or unparseable verdict → it tells you, never silently skips) and **never auto-commits or pushes**. The reviewer is **read-only by default** (the bundled `codex exec -s read-only -` is sandboxed); if you swap in a custom `REVIEWER_CMD`, keeping it read-only is your responsibility.

## Install

You need:
- [Claude Code](https://claude.com/claude-code)
- A reviewer CLI that reads a prompt from stdin. Default is the [Codex CLI](https://github.com/openai/codex): `npm i -g @openai/codex` (model `gpt-5.5`, auth via `~/.codex`), run sandboxed read-only. Any other CLI works — just point `REVIEWER_CMD` at it, but you are then responsible for keeping that command read-only.

> **Trust note:** `fusion.config.sh` is `source`d as shell and `REVIEWER_CMD` is executed — only run fusion-agent in a repo whose config you trust. It also refuses to run outside a git repo unless you set `FUSION_ALLOW_NO_GIT=1`.

```bash
git clone https://github.com/adamnguyen85/fusion-agent.git
cd /path/to/your/repo
/path/to/fusion-agent/install.sh
```

The installer copies the three skills into `your-repo/.claude/skills/`, makes `bin/fusion.sh` executable, and seeds `fusion.config.sh` from the example. Then:

1. **Edit `fusion.config.sh`** — the reviewer command, which files are your "project memory", and any project-specific review rules.
2. Add `bin/` to your `PATH` (or call `fusion.sh` by full path).
3. Add `.agent/` and `fusion.config.sh` to your repo's `.gitignore`.

## Configure

`fusion.config.sh` (copied from [`fusion.config.example.sh`](fusion.config.example.sh)) is where everything project-specific lives, so the core stays generic:

```sh
REVIEWER_CMD="codex exec -s read-only -"   # swap for gemini / a local model — must read stdin, run read-only
REVIEWER_NAME="Codex (gpt-5.5)"
MEMORY_FILES="AGENTS.md CLAUDE.md README.md" # files the reviewer reads first (your rules + decisions)
PROJECT_RULES=""                             # extra rules injected into review mode (optional)
ROUND_CAP=3
EXTRA_SECRET_EXCLUDE_GLOBS=()                # append MORE secret paths; built-in defaults always apply and can't be removed
```

## Usage

In Claude Code, just type the skill:

- `/fusion-plan` — after Claude proposes a non-trivial plan, push it through the reviewer to consensus.
- `/fusion-open` — ask an open question ("what should we build next?", "how should the Reports page work?") and have both agents propose independently, then reconcile.
- `/fusion-review` — after a large change, have the reviewer audit it against real test output.

Or drive the script directly:

```bash
bin/fusion.sh plan   .agent/fusion/<runid>/current-plan.md <runid>
bin/fusion.sh review main <runid> "npm test"
bin/fusion.sh open propose "How should the Reports page work?" <runid>
bin/fusion.sh open debate .agent/fusion/open-<runid>/debate-1.md <runid>
```

### Exit codes

| code | meaning |
|---|---|
| `0`  | CONSENSUS / review done |
| `1`  | REVISE, under the cap → revise and call again |
| `10` | REVISE, hit the cap → escalate to the human (5-section summary) |
| `3`  | FAIL-CLOSED (reviewer error) → tell the human |
| `2`  | bad usage |

## Reducing merge bias

In `/fusion-open`, Claude is both a *proposer* and the *merger* — a conflict of interest. fusion-agent reduces it cheaply, without adding a third model: the debate prompt attaches the **verbatim text of both proposals**, and the reviewer must first check whether Claude's reconciliation is honest (dropped or distorted a point, tilted toward its own idea) *before* it argues. Distortion → `REVISE`. Round 1 is also **blind** (the reviewer never sees Claude's proposal), so the two directions are genuinely independent. This lowers the risk of a skewed merge; it isn't a guarantee — if you want a hard check, the skill's optional arbiter pass re-audits the final.

## How it differs

- **Parallel panel + judge** (OpenRouter Fusion, [fusion-fable](https://github.com/duolahypercho/fusion-fable)): N models answer independently, one judge synthesizes. Great for one high-quality answer to one question. Repo-blind, costs N×.
- **fusion-agent**: sequential adversarial debate + co-proposal, **repo-aware**, **2 models max**, cheap. The reviewer reads your real repo and runs against real test output.

Different tool for a different job — pick the panel when you want the best single answer to an isolated question; pick fusion-agent when you want a plan/diff hardened against a skeptic who knows your codebase.

## License

[MIT](LICENSE)
