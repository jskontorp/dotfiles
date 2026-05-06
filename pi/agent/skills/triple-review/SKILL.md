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
compatibility: Requires pi, tmux, jq (via the delegate skill); proposal must be a readable file in the repo
allowed-tools: Read Write Bash(cat:*) Bash(ls:*) Bash(find:*) Bash(mkdir:*) Bash(wc:*) Bash(sed:*) Bash(sort:*) Bash(tail:*) Bash(tmux:*) Bash(git:*)
claude-compatible: false
---

# Triple Review

Three independent reviewers, run in parallel. Different vantage points, different blind spots, deliberately uncorrelated.

| Reviewer | Context | Job |
|----------|---------|-----|
| **Guided** | Full repo, AGENTS.md, conventions | Verdicts against documented invariants and known regression classes |
| **Blind** | Proposal text only — nothing else | Treat the doc as a stand-alone spec; flag what an outsider can't reconstruct |
| **Step-back** | Repo + step-back skill | Question the frame: is this the right problem? CONTINUE / SIMPLIFY / REFRAME |

This skill **composes** the [`delegate`](../delegate/SKILL.md) skill — it does not re-implement dispatch. Its job is to build three good prompts, hand them off as three independent (no-`depends`) tasks, and synthesise the results.

## Phase 1 — Locate (or render) the proposal

```bash
PROPOSAL="${PROPOSAL:-.pi-delegate/proposal.md}"
[ -f "$PROPOSAL" ] || { echo "no proposal at $PROPOSAL"; ls .pi-delegate/*.md 2>/dev/null; }
```

If the default isn't there, ask the user for the path. The proposal must be a single file readable from the repo root.

**If the artefact under review is a code change rather than a design doc**, render it into `$PROPOSAL` first — a short scope/rationale section followed by the relevant `git diff` and any files the diff doesn't fully show. The blind reviewer is constrained to that single file, so a list of "what reviewers should evaluate" is not enough; the proposal must contain enough text for an outsider to judge the change. Do **not** synthesise a proposal out of thin air — if there's nothing to render and nothing to point at, stop.

## Phase 2 — Build the three prompts

Read the templates next to this SKILL.md and substitute `{{PROPOSAL_PATH}}`:

```bash
SKILL_DIR="$(cd ~/.pi/agent/skills/triple-review && pwd)"
mkdir -p .pi-delegate

for r in guided blind stepback; do
  sed "s|{{PROPOSAL_PATH}}|$PROPOSAL|g" "$SKILL_DIR/prompts/$r.md" > ".pi-delegate/triple-${r}-prompt.txt"
done
```

The templates are deliberately generic. If the proposal has domain-specific evaluation criteria the user wants enforced (e.g. "must preserve the manifest invariant", "must be idempotent under teardown"), append those as bullets to `.pi-delegate/triple-guided-prompt.txt` after the template body — but do not edit the template itself.

## Phase 3 — Show the plan, wait for approval

Surface the plan to the user before dispatching. Per the `delegate` skill contract, this is a hard wait:

```
### Triple Review Plan

Proposal: $PROPOSAL ($(wc -l < "$PROPOSAL") lines)

| ID | Reviewer  | Reads        | Tools     | Timeout |
|----|-----------|--------------|-----------|---------|
| triple-guided   | Guided    | full repo    | read,bash | 600s    |
| triple-blind    | Blind     | proposal only| read      | 600s    |
| triple-stepback | Step-back | full repo    | read,bash | 600s    |

Sub-agents: 3 (all parallel, no dependencies)
Live view: tmux attach -t pi-delegate

Proceed?
```

The blind reviewer's `read` toolset is intentional — combined with the prompt's hard "do not read any other file" instruction, it constrains the reviewer to the proposal text. (`bash` is excluded so the reviewer can't `cat` its way around the constraint.)

## Phase 4 — Hand off to `delegate`

Dispatch as three independent tasks. Use the delegate skill's `dispatch.sh` directly — there is no orchestration logic here that the delegate skill doesn't already have:

```bash
DELEGATE_DIR=".pi-delegate"
RESULTS_DIR="$DELEGATE_DIR/results"
DELEGATE_SCRIPTS="$(cd ~/.pi/agent/skills/delegate/scripts && pwd)"
CWD="$(pwd)"
mkdir -p "$RESULTS_DIR"

# Reuse the existing pi-delegate session if another delegate run is in
# flight; pick the next free batch-N window so we don't clobber a parallel
# agent's panes. (The delegate skill itself uses additional windows for
# >4 tasks; this is the same convention.)
if tmux has-session -t pi-delegate 2>/dev/null; then
  # Use ERE (sed -E) for cross-platform support — BSD sed (macOS) doesn't
  # accept BRE `\+`. Strip any tmux marker suffix (`*`, `-`, `!`, `Z`) too,
  # in case a future format string includes them.
  N=$(tmux list-windows -t pi-delegate -F '#{window_name}' 2>/dev/null \
      | sed -E -n 's/^batch-([0-9]+).*$/\1/p' | sort -n | tail -1)
  BATCH="batch-$(( ${N:-0} + 1 ))"
  tmux new-window -t pi-delegate -n "$BATCH"
else
  BATCH="batch-1"
  tmux new-session -d -s pi-delegate -n "$BATCH"
fi

# triple-guided gets pane 0 (first task — uses send-keys into the existing pane)
tmux send-keys -t "pi-delegate:$BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-guided '$CWD' 600 '$CWD/.pi-delegate/triple-guided-prompt.txt' '$CWD/$RESULTS_DIR' '' read,bash" Enter

# triple-blind and triple-stepback split into new panes
tmux split-window -t "pi-delegate:$BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-blind '$CWD' 600 '$CWD/.pi-delegate/triple-blind-prompt.txt' '$CWD/$RESULTS_DIR' '' read"
tmux split-window -t "pi-delegate:$BATCH" \
  "$DELEGATE_SCRIPTS/dispatch.sh triple-stepback '$CWD' 600 '$CWD/.pi-delegate/triple-stepback-prompt.txt' '$CWD/$RESULTS_DIR' '' read,bash"
tmux select-layout -t "pi-delegate:$BATCH" tiled
```

Tell the user: **`Watch live: tmux attach -t pi-delegate`**

## Phase 5 — Poll

```bash
"$DELEGATE_SCRIPTS/../scripts/poll.sh" "$RESULTS_DIR" "$DELEGATE_DIR/status.json" \
  "triple-guided,triple-blind,triple-stepback" 5 700
```

(Note the `MAX_WAIT` here is the per-task timeout + slack, not 3× — they run in parallel.)

## Phase 6 — Synthesise

Read all three result files. Write `.pi-delegate/triple-review-synthesis.md` and surface it inline. Be slightly opinionated — take the input seriously, but pick a path. The synthesis must do four things, in order:

1. **Headline verdict** — one line per reviewer (Approve / Approve with revisions / Block; CONTINUE / SIMPLIFY / REFRAME), so disagreement is visible at a glance.
2. **Convergent findings** — issues raised by ≥2 reviewers. These are the strongest signals. Cite which reviewers and what each said in one line.
3. **Divergent findings** — issues raised by exactly one reviewer that the others didn't notice or didn't have the context to notice. Mark each with the reviewer who raised it; these are not weaker, they're complementary.
4. **Recommendation + 3–5 sharpest actions** — your call as the parent agent. Pick a path (land / land with fixes / split / reframe / block) and justify it from the convergent findings. When reviewers disagree on the load-bearing question, name the disagreement explicitly and explain which side you're taking and why — do not bury the dissent, but do not refuse to take a position either. Verdict-averaging ("two said approve so we approve") is the failure mode to avoid.

## Notes

- **No fourth synthesis sub-agent.** The parent agent already has the three reports plus the conversation context; spinning up another sub-agent loses fidelity and costs an invocation. The synthesis is done in-band.
- **Models.** Default to whatever the parent agent is running. If the user wants reviewer diversity (different model per reviewer for genuine independence), pass `--model` per task in Phase 4 — e.g. guided on a code-reasoning model, blind on a literal/critical model, step-back on a model trained for self-critique. The skill does not enforce diversity by default because model quality varies more than vantage point in practice.
- **Re-runs.** Re-running the skill on the same proposal overwrites the result files. If you want to compare two runs, copy `.pi-delegate/results/` aside first.
- **Out of scope.** This skill does not edit the proposal, does not implement the design, does not open PRs. Its only output is the synthesis. Acting on the findings is the user's call.
