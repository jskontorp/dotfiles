# Persistent AI-plan artefact location — investigation

Scope: where should `writing-plans`-style plan markdown files live in Jørgen's dotfiles-managed Claude Code + pi setup? Is `mem0` a useful layer above? Should the upstream `obra/superpowers/writing-plans` skill be accepted as-is, forked, or skipped?

---

## TL;DR

1. **Location: commit to the repo at `docs/plans/<feature>.md`** (drop the `superpowers/` segment — it's upstream branding, not useful). Plans are a reviewable artefact of how a feature was built; they deserve the same durability as code.
2. **Fork by copying.** The upstream SKILL.md is 152 lines with a single hardcoded path. One line diverges from your conventions; the "user preferences override this default" sentence is already baked into the upstream skill. Forking is ~30 seconds of work and decouples you from an unstable upstream path convention.
3. **mem0: no.** It solves a different problem (runtime memory for chatbots, auto-extracted facts retrieved on new prompts). Your stated goal — "logging feedback and finding patterns to make targeted changes to my agentic setup" — is the Langfuse plan you already drafted. mem0 would add a second memory store with no clear read path into your feedback loop.
4. **Commit to git: yes, for plans.** No for ticket state. The difference is audience: plans are part of how you build (PR-reviewable, teammate-visible); ticket state is session scratch that `solve-ticket` already correctly keeps outside the worktree.

---

## A. Plan-file location options

### Candidates

| Option | Path | Where it lives |
|---|---|---|
| 1. Upstream default | `<repo>/docs/superpowers/plans/YYYY-MM-DD-<feature>.md` | In the repo, committed |
| 2. solve-ticket style | `<repo-parent>_worktrees/.claude-state/plans/<feature>.md` | Outside worktree, invisible to git |
| 3. Per-user | `~/.claude/plans/<repo>/<feature>.md` | User state, never touches repos |
| 4. Hybrid | Option 1 in repo + `~/.claude/plans-index.json` | Both |

### Pros/cons

| | Discoverability | Git history | Cross-session | Per-repo vs. per-user | Forward-compat |
|---|---|---|---|---|---|
| **1. Upstream** | High (visible in repo tree, show up in PRs) | Committed — permanent record | Same repo, works | Per-repo (correct granularity) | Brittle: you inherit `docs/superpowers/` branding and any upstream path change |
| **2. solve-ticket-style** | Low (outside worktree, only `solve-ticket` knows about it) | Never committed — plans vanish on worktree removal | Survives worktree churn but not machine churn | Per-repo-per-machine | Invisible to anyone else on the team; can't be referenced in PR review |
| **3. Per-user** | Medium (one central dir, but no repo coupling) | Never committed | Survives across repos, lost with the laptop | Per-user, loses repo correlation unless encoded in filename | Disconnected from the work — nobody else will ever see these |
| **4. Hybrid** | High (repo path) + search index | Plan committed, index user-local | Best of both | Per-repo plans, per-user index | More moving parts: index drift, migration pain |

### Recommendation: Option 1, modified to `<repo>/docs/plans/`

- Commit plans. They describe *how* a feature was built; they are PR-quality artefacts, not scratch.
- Drop the `superpowers/` path segment. It leaks upstream-skill branding into your repo layout. `docs/plans/` is self-describing.
- Date-prefix filenames are fine (`2026-04-23-<feature>.md`) — upstream's convention is reasonable and costs nothing.
- **Against Option 2 (solve-ticket-style):** solve-ticket lives outside the worktree because ticket state is *session scratch that mutates during a live agent loop* (current phase, peer-review round, dev-server PID). Plans are a *pre-commit artefact*. Different lifecycle, different audience, different location. Don't overfit the pattern.
- **Against Option 3 (per-user):** loses the repo-as-source-of-truth property. If a plan was used to build a feature, a teammate reviewing the PR should be able to read it. Hiding it on your laptop defeats half its value.
- **Against Option 4 (hybrid index):** "analysis-at-scale" is already the job of the Langfuse plan in `LANGFUSE_PLAN.md`. A plans-index.json would be a second channel for the same question ("what patterns recur in my work?"), with worse tooling and no aggregation across other signal. Don't build it.

---

## B. mem0 assessment

### What mem0 actually is

- Open-source library + hosted platform. Apache-2 core ([github.com/mem0ai/mem0](https://github.com/mem0ai/mem0)), hosted tier adds managed infra.
- **Active memory engine**, not observability. Stores user/agent/session memories in a vector DB (default: OpenAI `text-embedding-3-small`), with hybrid search (semantic + BM25 + entity boosting).
- Auto-extracts facts via an LLM pass during `memory.add(messages, user_id=...)`. Retrieves relevant memories on new prompts to inject into context.
- Deployment: Python SDK, TypeScript SDK, REST API, hosted service. Local stack needs docker-compose plus an external LLM for extraction (OpenAI by default).
- Integration path with Claude Code: a `.claude-plugin` directory exists in the repo; there's an "OpenClaw" plugin released April 2026. Generic MCP is the intended "universal AI integration" route.

### Observability vs. memory

| | mem0 | Langfuse |
|---|---|---|
| Purpose | Inject relevant past-conversation memories into new prompts | Capture traces of agent turns, score them, analyse patterns |
| Write time | On conversation end (`memory.add`) | On every tool call / turn (hook-driven) |
| Read time | Per-prompt retrieval before agent responds | Offline analysis in UI or batch SDK pulls |
| Failure mode | Wrong memory retrieved → bad response | None (read-only log) |

These are orthogonal. Neither replaces the other.

### Is mem0 relevant to Jørgen's stated goal?

**No.**

The goal — *"logging feedback and finding patterns to make targeted changes to my agentic setup"* — is analysis over a log of agent behaviour, not runtime context augmentation. The Langfuse plan already drafted (`LANGFUSE_PLAN.md`, 390 lines) is the correct tool for that goal: Stop hook forwards turns, `UserPromptSubmit` hook captures `!fb` feedback markers, weekly LLM clustering pass produces `~/.claude/analysis/report-*.md`, patterns map to edits in CLAUDE.md / hookify rules / skill descriptions.

mem0 would pull the agent's context in a different direction: at prompt time, inject "you previously said X about Y, and user feedback was Z." That's **performance tuning mid-session**, not **retrospective introspection of your stack**. Different outcome.

Second strike: mem0 requires an LLM provider for the extraction pass, which means every agent turn quietly sends transcripts to OpenAI (or whatever extractor is configured). Your Langfuse plan is careful about sanitization (P6.A); mem0 pulls you back into "data leaves my network before I've filtered it". Solvable, but added friction against no-clear-benefit.

### Sketch if you did want mem0 anyway (not recommended)

- Where: `~/.claude/mem0/` with a local docker-compose stack, wire into a `UserPromptSubmit` hook that retrieves-and-appends relevant memories to the prompt, and a Stop hook that calls `memory.add` with turn content.
- Minimal integration: ~100 lines across two hooks + a docker-compose at `services/mem0/`.
- Would duplicate, not complement, the Langfuse Stop hook you're about to build.

---

## C. Should `writing-plans` be forked?

### Upstream properties (verified)

- Source: [obra/superpowers/skills/writing-plans/SKILL.md](https://github.com/obra/superpowers/blob/main/skills/writing-plans/SKILL.md)
- Size: **152 lines**
- Hardcoded paths: **one** — `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- One line literally says: `(User preferences for plan location override this default)` — upstream is opt-in to divergence
- Dependencies on upstream: references `superpowers:subagent-driven-development` and `superpowers:executing-plans` skills for the execution handoff. Those skills are also in the `obra/superpowers` repo — if you fork `writing-plans` but don't install the two sibling skills, the "Execution Handoff" section becomes dead text.

### Options

| Option | Effort | Upstream updates | Risk |
|---|---|---|---|
| **Accept upstream** | 0 | Auto via `skill-lock.json` + `just update-skill` | Creates `docs/superpowers/` in every repo; upstream may change path convention |
| **Fork by copying** | ~30s: `cp` + one line edit + remove from `skill-lock.json` | Manual `git pull obra/superpowers` + diff | You own the skill; upstream improvements need hand-merging |
| **Don't install, write native** | ~1h | Fully owned | Reinvents 150 lines of reasonable prescriptive content |

### Recommendation: fork by copying

Rationale:
- 152 lines with one line that needs to change. Diff cost is trivial.
- The upstream skill is *prescriptive* (TDD, DRY, placeholder-free, task granularity) in ways that are independent of the path. Those prescriptions are worth keeping — don't rewrite from scratch to save one path change.
- `docs/superpowers/` leaks the name of an upstream skill into every repo directory tree. Not a functional problem; it's an aesthetic/coupling one that adds up across ~10 repos.
- The "Execution Handoff" section references `superpowers:subagent-driven-development` and `superpowers:executing-plans`. Decide now whether you install those two siblings too. If not, edit that section out of the fork; if yes, install all three (they're in the same repo — one `skill-lock.json` entry covers the directory).

### Mechanics

```bash
# one-time
mkdir -p ~/code/personal/dotfiles/pi/agent/skills/writing-plans
curl -sL https://raw.githubusercontent.com/obra/superpowers/main/skills/writing-plans/SKILL.md \
  > ~/code/personal/dotfiles/pi/agent/skills/writing-plans/SKILL.md
# edit the single "Save plans to:" line to docs/plans/YYYY-MM-DD-<feature>.md
# remove writing-plans from pi/skill-lock.json if present (it isn't currently)
just link
```

Upstream sync cadence: every ~3 months, `curl` the latest, `diff` against your fork, cherry-pick any non-path improvements. Small enough to eyeball.

---

## D. Commit-to-git vs. gitignore — per location

| Location | Commit? | Rationale |
|---|---|---|
| **`<repo>/docs/plans/` (option 1, recommended)** | **Commit.** | Plan is an artefact of how the feature was built. Reviewable in the same PR as the implementation. Teammates get context for free. Analysis-at-scale benefits: `git log docs/plans/` across repos is a zero-cost retrospective tool. |
| `_worktrees/.claude-state/` (option 2) | Not applicable (outside worktree). | Correct for session scratch — ticket state, peer-review rounds, dev-server PIDs. Wrong for plans: you can't PR-review what teammates can't see. |
| `~/.claude/plans/` (option 3) | Never committed (user-local). | Acceptable *only* for throwaway / non-repo work (e.g. "plan my migration from zsh to fish"). For repo work, this choice loses the review path. |

### Arguments for committing

- Analysis-at-scale: `rg -l "approach rejected" docs/plans/` across N repos is a free retrospective. No Langfuse query, no mem0 call.
- Teammate context: reviewer of a complex PR can read the plan to see what was considered and rejected. Especially valuable for "why didn't you just do X?" questions.
- Durability: survives laptop wipe, worktree deletion, session expiry. Git is the most reliable store you already have.
- Documentation compounding: good plans become the basis of ADRs or internal docs with trivial editing.

### Arguments against committing (and why they don't hold up here)

- *"Plans contain half-formed thoughts, rejected approaches, ugly reasoning."* So do commit messages and PR descriptions. This is a writing-discipline problem, not a storage-location problem. The upstream `writing-plans` skill explicitly requires no placeholders, concrete code, exact paths — the output is not a scratchpad.
- *"Not everyone on the team wants to see AI-generated plans."* Fair in a team context. Solo repos: no cost. Team repos: add `docs/plans/` to `.gitignore` at the repo level per-team-norm if needed — the skill still works, just the files stay local. Per-project override, not a global default.
- *"Plans go stale after the feature ships."* True. Keep them anyway as historical record; staleness doesn't corrupt them, and the date prefix makes age obvious.

### Explicit non-commits

- `solve-ticket` state files (`$TICKET.md`, `$TICKET.env`, peer-review rounds): **keep gitignored**, outside worktree. These are in-flight session state; they mutate during the agent's run; they'd pollute history. Don't co-locate with plans.

---

## Recommended path forward

1. **Fork `writing-plans` into dotfiles.** `cp` upstream SKILL.md → `dotfiles/pi/agent/skills/writing-plans/SKILL.md`, change the `Save plans to:` line to `docs/plans/YYYY-MM-DD-<feature>.md`, decide whether to strip or keep the `superpowers:subagent-driven-development` / `superpowers:executing-plans` references. Run `just link`.
2. **Also install the two sibling skills** (`subagent-driven-development`, `executing-plans`) from `obra/superpowers` via `just add-skill` — unless you want to rewrite the "Execution Handoff" section out of your fork. The upstream skill is useless without an execution path and rewriting that section is more effort than installing two more skills.
3. **Do not install mem0.** Stay with the Langfuse plan as the single observability channel. Revisit only if a concrete case emerges where the agent needs *to remember across sessions in-context* — not if the goal is still analytical.
4. **Decide your team convention on committing `docs/plans/`.** Default to committed. Per-repo `.gitignore` override if a specific repo's team pushes back.
5. **Optional, not blocking:** after a few real uses, if you find plans collecting in a way that *is* worth cross-repo analysis (which Langfuse won't cover), add a `just plans` recipe that `rg`s across all registered repos in `projects.conf`. Cheap, transparent, no index file needed.

---

## Open questions for the user

1. **`superpowers:*` sibling skills** — install `subagent-driven-development` and `executing-plans` alongside the fork, or rip the "Execution Handoff" section out? If you already have a preferred execution pattern (e.g. Task tool with inline loops), the upstream sibling skills may add ceremony with no payoff.
2. **Single plan dir or date-prefixed?** Upstream: `YYYY-MM-DD-<feature>.md`. Alternative: `<feature>.md` with git mtime as the date. Upstream's choice is slightly more robust (filename carries the date even outside git). Default to upstream; override if you have a strong preference.
3. **Per-project commit gate.** Some repos (e.g. `volve-ai`) are shared with teammates who may not want AI plans in the tree. Add `docs/plans/` to the project-specific `.gitignore` there? Or commit and let the convention prove itself?
4. **Fork the path — but also the granularity prescriptions?** The upstream skill is opinionated about TDD/DRY/frequent-commits/2-5-minute steps. If those don't match your practice for all plan types (e.g. research plans vs. implementation plans), consider two skills: `writing-implementation-plans` (fork as-is) and `writing-research-plans` (shorter, looser). Not needed on day one.
5. **Feedback loop into Langfuse.** When a plan is used to execute a feature, is there value in tagging the resulting Langfuse traces with the plan filename? Enables queries like "turns driven by plan X had feedback score Y." Cheap to add to the Stop hook in `LANGFUSE_PLAN.md` P4.A. Not a blocker; note it for later.
