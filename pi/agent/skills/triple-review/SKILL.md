---
name: triple-review
description: >-
  Stress-test a design proposal by fanning out three independent peer reviews
  via the `delegate` skill — guided (full repo context, structured against
  conventions), blind (proposal-only, treats it as a stand-alone spec), and
  step-back (questions the entire frame using the `step-back` skill). Use when
  the user says "triple review", "triple peer review", "stress-test this
  proposal", "vet this design", or asks for an adversarial review of a design
  doc before implementation.
compatibility: Requires pi on PATH and the `delegate` skill's files installed at `~/.pi/agent/skills/delegate/scripts/` (used by dispatch.sh for sub-agent fan-out — the `delegate` skill itself does not need to be loaded by the parent agent), tmux, jq; proposal must be a readable file in the repo. Usable from either pi or Claude Code as the parent agent.
allowed-tools: Read Write Bash(cat:*) Bash(ls:*) Bash(find:*) Bash(mkdir:*) Bash(wc:*) Bash(sed:*) Bash(sort:*) Bash(tail:*) Bash(tmux:*) Bash(git:*)
claude-compatible: true
# disable-model-invocation: side-effect skill (spawns 3 pi sub-agents, holds tmux session, writes files)
# with loose description triggers — Claude must invoke explicitly via slash-command, not auto-pick.
# Pi ignores this field and continues to dispatch by description.
disable-model-invocation: true
---

# Triple Review

Three independent reviewers, run in parallel. Different vantage points, different blind spots, deliberately uncorrelated.

| Reviewer | Context | Job |
|----------|---------|-----|
| **Guided** | Full repo, AGENTS.md, conventions | Verdicts against documented invariants and known regression classes |
| **Blind** | Proposal text only — nothing else | Treat the doc as a stand-alone spec; flag what an outsider can't reconstruct |
| **Step-back** | Repo + step-back skill | Question the frame: is this the right problem? CONTINUE / SIMPLIFY / REFRAME |

This skill **composes** the [`delegate`](../delegate/SKILL.md) skill — it does not re-implement dispatch. Its job is to build three good prompts, hand them off as three independent (no-`depends`) tasks, and synthesise the results.

Mechanically, it calls `delegate`'s `dispatch.sh` directly by absolute path — the `delegate` skill itself does not need to be loaded by the parent agent. This is what lets Claude Code use `triple-review` even though `delegate` is pi-only.

Orchestration outputs (prompts, results, sessions, synthesis) live under a
per-run `$BATCH_DIR=.pi-delegate/batch-N/` allocated via atomic `mkdir` so
concurrent runs in the same cwd don't clobber each other. The input
(`$PROPOSAL`) stays at the top level so you can re-run reviews on the same
proposal without copying.

## Phase 1 — Locate (or render) the proposal

```bash
# Preflight: dispatch.sh must exist on disk (the delegate skill's files, not
# the loaded skill itself). Fail loudly here, before asking the user for
# Phase 3 approval, rather than at tmux send-keys time.
[ -x ~/.pi/agent/skills/delegate/scripts/dispatch.sh ] || {
  echo "delegate skill scripts missing at ~/.pi/agent/skills/delegate/scripts/dispatch.sh — install pi-side dotfiles first, then re-run"
  # Do NOT exit/return here — under pi's persistent bash that would kill the
  # shell. Surface the error to the user and stop the skill at the chat level.
}

PROPOSAL="${PROPOSAL:-.pi-delegate/proposal.md}"
[ -f "$PROPOSAL" ] || { echo "no proposal at $PROPOSAL"; ls .pi-delegate/*.md 2>/dev/null; }
```

If the default isn't there, ask the user for the path. The proposal must be a single file readable from the repo root.

**If the artefact under review is a code change rather than a design doc**, render it into `$PROPOSAL` first — a short scope/rationale section followed by the relevant `git diff` and any files the diff doesn't fully show. The blind reviewer is constrained to that single file, so a list of "what reviewers should evaluate" is not enough; the proposal must contain enough text for an outsider to judge the change. Do **not** synthesise a proposal out of thin air — if there's nothing to render and nothing to point at, stop.

## Phase 2 — Build the three prompts

Allocate a fresh batch dir (atomic, retries on collision), then read the
templates next to this SKILL.md and substitute `{{PROPOSAL_PATH}}`:

```bash
SKILL_DIR="$(cd ~/.pi/agent/skills/triple-review && pwd)"
DELEGATE_DIR=".pi-delegate"
mkdir -p "$DELEGATE_DIR"

# Allocate next free batch dir. mkdir without -p is atomic on POSIX FS —
# racing orchestrators in the same cwd both see e.g. N=2, only one wins
# the mkdir batch-3, the loser re-reads and tries batch-4. The 2>/dev/null
# on `ls` is load-bearing (no-match would emit a literal `batch-*`).
while true; do
  N=$(ls -1d "$DELEGATE_DIR"/batch-* 2>/dev/null | sed -E 's|.*/batch-||' | sort -n | tail -1)
  BATCH="batch-$(( ${N:-0} + 1 ))"
  mkdir "$DELEGATE_DIR/$BATCH" 2>/dev/null && break
done
BATCH_DIR="$DELEGATE_DIR/$BATCH"
mkdir -p "$BATCH_DIR/results"

for r in guided blind stepback; do
  sed "s|{{PROPOSAL_PATH}}|$PROPOSAL|g" "$SKILL_DIR/prompts/$r.md" > "$BATCH_DIR/triple-${r}-prompt.txt"
done
```

The templates are deliberately generic. If the proposal has domain-specific evaluation criteria the user wants enforced (e.g. "must preserve the manifest invariant", "must be idempotent under teardown"), append those as bullets to `$BATCH_DIR/triple-guided-prompt.txt` after the template body — but do not edit the template itself.

## Phase 3 — Show the plan, wait for approval

Surface the plan to the user before dispatching. Per the `delegate` skill contract, this is a hard wait:

```
### Triple Review Plan

Proposal: $PROPOSAL ($(wc -l < "$PROPOSAL") lines)
Batch:    $BATCH  (outputs under $BATCH_DIR/)

| ID | Reviewer  | Reads        | Tools     | Timeout |
|----|-----------|--------------|-----------|---------|
| triple-guided   | Guided    | full repo    | read,bash | 600s    |
| triple-blind    | Blind     | proposal only| read      | 600s    |
| triple-stepback | Step-back | full repo    | read,bash | 600s    |

Sub-agents: 3 (all parallel, no dependencies)
Live view: tmux attach -t pi-delegate  (window name announced after dispatch)

Proceed?
```

The blind reviewer's `read` toolset is intentional — combined with the prompt's hard "do not read any other file" instruction, it constrains the reviewer to the proposal text. (`bash` is excluded so the reviewer can't `cat` its way around the constraint.)

## Phase 4 — Hand off to `delegate`

Dispatch as three independent tasks. Use the delegate skill's `dispatch.sh` directly — there is no orchestration logic here that the delegate skill doesn't already have.

**Two independent batch IDs.** The FS `$BATCH` was allocated in Phase 2 (per-cwd). The tmux `$TMUX_BATCH` is allocated here (per-machine, shared across cwds via the global `pi-delegate` session). They are deliberately decoupled — across two cwds, FS `batch-1` exists twice (fresh `.pi-delegate/` each) while tmux window names must stay unique within the one session.

```bash
DELEGATE_SCRIPTS="$(cd ~/.pi/agent/skills/delegate/scripts && pwd)"
CWD="$(pwd)"
RESULTS_DIR="$BATCH_DIR/results"  # already created in Phase 2

# Reuse the existing pi-delegate session if another delegate/triple-review
# run is in flight; pick the next free batch-N window. Independent of $BATCH.
# Use ERE (sed -E) — BSD sed (macOS) doesn't accept BRE `\+`. Strip any tmux
# marker suffix (`*`, `-`, `!`, `Z`) too.
if tmux has-session -t pi-delegate 2>/dev/null; then
  N=$(tmux list-windows -t pi-delegate -F '#{window_name}' 2>/dev/null \
      | sed -E -n 's/^batch-([0-9]+).*$/\1/p' | sort -n | tail -1)
  TMUX_BATCH="batch-$(( ${N:-0} + 1 ))"
  tmux new-window -t pi-delegate -n "$TMUX_BATCH"
else
  TMUX_BATCH="batch-1"
  tmux new-session -d -s pi-delegate -n "$TMUX_BATCH"
fi

# triple-guided gets pane 0 (first task — send-keys into the existing pane)
tmux send-keys -t "pi-delegate:$TMUX_BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-guided '$CWD' 600 '$CWD/$BATCH_DIR/triple-guided-prompt.txt' '$CWD/$RESULTS_DIR' '' read,bash" Enter

# triple-blind and triple-stepback split into new panes
tmux split-window -t "pi-delegate:$TMUX_BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-blind '$CWD' 600 '$CWD/$BATCH_DIR/triple-blind-prompt.txt' '$CWD/$RESULTS_DIR' '' read"
tmux split-window -t "pi-delegate:$TMUX_BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-stepback '$CWD' 600 '$CWD/$BATCH_DIR/triple-stepback-prompt.txt' '$CWD/$RESULTS_DIR' '' read,bash"
tmux select-layout -t "pi-delegate:$TMUX_BATCH" tiled
```

Tell the user, printing both names explicitly (no claim of equality):

```
Watch live: tmux attach -t pi-delegate \; select-window -t pi-delegate:$TMUX_BATCH
FS outputs: $BATCH_DIR/
```

## Phase 5 — Poll

```bash
"$DELEGATE_SCRIPTS/../scripts/poll.sh" "$RESULTS_DIR" "$BATCH_DIR/status.json" \
  "triple-guided,triple-blind,triple-stepback" 5 700
```

(Note the `MAX_WAIT` here is the per-task timeout + slack, not 3× — they run in parallel.)

## Phase 6 — Synthesise

Read all three result files. Write `$BATCH_DIR/triple-review-synthesis.md` and surface it inline. Be slightly opinionated — take the input seriously, but pick a path. The synthesis must do four things, in order:

1. **Headline verdict** — one line per reviewer (Approve / Approve with revisions / Block; CONTINUE / SIMPLIFY / REFRAME), so disagreement is visible at a glance.
2. **Convergent findings** — issues raised by ≥2 reviewers. These are the strongest signals. Cite which reviewers and what each said in one line.
3. **Divergent findings** — issues raised by exactly one reviewer that the others didn't notice or didn't have the context to notice. Mark each with the reviewer who raised it; these are not weaker, they're complementary.
4. **Recommendation + 3–5 sharpest actions** — your call as the parent agent. Pick a path (land / land with fixes / split / reframe / block) and justify it from the convergent findings. When reviewers disagree on the load-bearing question, name the disagreement explicitly and explain which side you're taking and why — do not bury the dissent, but do not refuse to take a position either. Verdict-averaging ("two said approve so we approve") is the failure mode to avoid.

## Notes

- **No fourth synthesis sub-agent.** The parent agent already has the three reports plus the conversation context; spinning up another sub-agent loses fidelity and costs an invocation. The synthesis is done in-band.
- **Models.** Default to whatever the parent agent is running. If the user wants reviewer diversity (different model per reviewer for genuine independence), pass `--model` per task in Phase 4 — e.g. guided on a code-reasoning model, blind on a literal/critical model, step-back on a model trained for self-critique. The skill does not enforce diversity by default because model quality varies more than vantage point in practice.
- **Re-runs.** Each run allocates a fresh `$BATCH_DIR`, so re-runs do **not** overwrite prior results — they accumulate as `batch-N/`. Manual `rm -rf .pi-delegate/batch-*` to clean up. The top-level `$PROPOSAL` is unaffected.
- **Migration.** If `.pi-delegate/{results,*-prompt.txt,triple-review-synthesis.md}` exists at the top level from a pre-batch version of this skill, it's inert under the new code path. Ask the user before removing it; don't `rm` it autonomously.
- **Out of scope.** This skill does not edit the proposal, does not implement the design, does not open PRs. Its only output is the synthesis. Acting on the findings is the user's call.
