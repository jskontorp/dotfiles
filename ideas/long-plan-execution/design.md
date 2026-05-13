# Long-plan execution — design notes and audit trail

> **Status:** reference. Not a skill, not active. The harness rules from this work landed in `pi/agent/AGENTS.md` under `# Coding discipline`. The rest of this file is the audit trail behind that decision, preserved for the moment a second repo independently exhibits the same leak class.
>
> **Calendar revisit:** by **2026-11-01**, or on the next ≥10-task plan in any repo other than `volve-ai`, whichever first.

## 1. What triggered this work

A live orchestrator session (Claude Code Opus 4.7 1M-ctx, `tmux dev:7.0`) executing a 4,328-line plan in `work/volve-ai-908/docs/superpowers/plans/2026-05-06-compliance-checklist-v2.md`. During the Task 6+7 cycle, ~100 minutes were lost to two `Stream idle timeout - partial response received` errors against the quality reviewer subagent — API-side stalls on a maximal reviewer brief, not model thinking. Other smaller leaks compounded. Post-`/compact` pacing recovered (Task 8: 1h14m, Task 8.5: 8m), but the workflow needed hardening before Tasks 9–11.

The orchestrator follows the upstream `subagent-driven-development` skill from `obra/superpowers`, installed by-reference via `pi/skill-lock.json` and physically resident at `~/.local/share/pi-skills/subagent-driven-development/`.

## 2. The ten-leak diagnosis

Identified across two analysis passes. Ranked by token / wall-clock impact.

| # | Leak | Evidence |
|---|---|---|
| 1 | Maximal reviewer brief → stream-idle timeouts (×2, ~100 min lost) | Quality-reviewer brief embedded diff review + 5 verification commands + precedent greps + 4-tier triage; ran 44 tool uses / 57.9k tokens / 9m 48s and tripped the stream-idle window twice. |
| 2 | Stream-idle partials weren't auto-retried | Both 38m and 1h2m stalls ended only when user typed "status?" / "what happened?". Harness held partial response. |
| 3 | Spec reviewer missed literal plan-fidelity | Plan said "new module substring_guard.py"; implementer bundled it into verifier.py; spec reviewer checked behaviour, not file paths. Cost ~14m extract + amend. |
| 4 | Orchestrator deliberates what subagents could deliberate | Soft-hyphen (a)/(b)/(c) analysis lived in main context; should have been in implementer's return value. ~800 lines for a one-keystroke decision. |
| 5 | Inline checkpoint reports duplicate the ledger | Tasks 4/5/6+7 each got 60–100 inline lines; on-disk ledger has same content in ~5 lines per task. |
| 6 | Pre-compact protocol over-engineered | 6 checks including substring greps on the state file; one tripped on heading form, forced workaround. |
| 7 | Pre-existing noise re-triaged every task | Same Pyright false-positives and same deferred-test inventory rediscovered by each reviewer. |
| 8 | Re-anchor cost grows over time | Ledger was 119 lines; Judgment-call log will be 50+ entries by Task 20; re-anchoring becomes its own tax. |
| 9 | Standing user directives evicted by `/clear` | Out-of-band guidance ("full review on Task 7", bundling rules) lived only in chat. `/clear` evicts. |
| 10 | Decision-wait gaps idle | Orchestrator blocks foreground while user thinks; mechanical-next-task (when independent) could overlap. |

Two related observations: `/compact` worked when the upstream context was clean; and `Brewed N` / `Crunched N` figures during a partial-response stall are wall-clock dead time, not work.

## 3. Discipline rules (the would-be playbook)

Captured here as reference; not active. Apply by hand if a future plan needs them.

### 3.1 Reviewer-brief discipline

- **Quality reviewer reviews the diff only.** Don't embed pytest, smoke imports, or precedent greps in the brief — those run in orchestrator bash separately.
- **Spec reviewer must verify literal plan-fidelity** — file paths, module names, function signatures match the plan, not just the behaviour they implement.
- **Pass the pre-existing-noise inventory** into every reviewer brief so they stop rediscovering the same false-positives.
- **Reviewers write the full report to `reports/task-N-{spec,quality}.md`** and return ≤5-line executive summaries. Body lives on disk; chat carries the pointer.

### 3.2 Implementer discipline

- **On ambiguity, return options + recommendation + rationale (≤3 lines each).** Don't escalate raw — orchestrator-level deliberation is expensive context.
- **As final step, append a checkpoint to the ledger** (one paragraph: SHA, files touched, verification result, deferred-failures delta).
- **Return one-line summary to orchestrator** (status + SHA + ledger pointer). Body lives on disk.

### 3.3 Ledger split

- **`orchestrator-state.md`** — Position, Up-next, Open decisions, Standing Directives, Verification invariants. Fixed-size; what `/clear` re-anchor reads.
- **`orchestrator-audit.md`** — Judgment-call log, noise inventory, per-task checkpoint history. Read on demand for forensics only.

### 3.4 Standing Directives field

Add to active ledger so `/clear` re-anchor restores out-of-band guidance (per-task review intensity, bundling rules, skip-review tasks).

### 3.5 Pre-compact 3-check (replacing 6-check)

(a) Full agent suite shows the documented N deferred failures. (b) `git log` stack matches ledger Position. (c) Working tree clean. Drop substring-of-state-file checks — circular and fragile.

### 3.6 `/compact` vs `/clear`

`/compact` is acceptable if upstream leaks are plugged. `/clear` + re-anchor (from a sibling session that refreshes the ledger first) is the heavier instrument when bloat has accumulated. The active ledger's own header should warn against orchestrator self-summary.

### 3.7 Decision-wait parallelism

When the next task is fully independent of a pending user decision, dispatch in background while user thinks. Gate strictly on independence; otherwise risk discarding work.

## 4. Composition-pattern analysis (rejected design)

The original proposal was to ship a new global skill `pi/agent/skills/orchestrating-plans/` with tightened reviewer prompt templates + an AGENTS.md co-invocation rule. Four composition options were considered:

- **Plan A: Skill-as-complement.** Author the skill alongside upstream; rely on description match + AGENTS.md to compel pairing.
- **Plan B: Replace upstream at install-time.** Intercept the symlink; cleanest semantic, but breaks `just update-skill` and requires `install.sh` changes.
- **Plan C: Disable upstream + ship ours under upstream's name.** Permanent drift risk; same maintenance burden.
- **Plan D: Skill-as-complement + AGENTS.md enforcing co-invocation.** The chosen design.

## 5. Why Plan D was rejected (triple-review synthesis)

Three independent reviewers (guided / blind / step-back) found convergent defects:

1. **The "AGENTS.md outranks skills" mechanism is unverified.** `using-superpowers` is not in this repo's `skill-lock.json` and not at `~/.local/share/pi-skills/`; the cited priority hierarchy could not be located.
2. **Shadow-prompt drift after `just update-skill`** is undetected; no test compares local templates against upstream filenames.
3. **The composition is behavioural-only — no engine path.** Skill files don't compose; only the model's choice composes them.
4. **Acceptance criteria green-light an empty stub.** `just check` / `just test` validate registration and mirror invariants only.
5. **Stream-idle re-dispatch was under-specified** — concrete duplicate-side-effect risk; bundling with plan-execution dilutes the rule's standalone value.

Step-back's reframe (the sharpest of the three): the *instance* is N=1; the dotfiles `AGENTS.md` rule against premature abstraction governs. Cheaper primitives exist — PR upstream, or plan-local notes. Don't promote one postmortem to a globally-auto-firing skill.

A subsequent single-reviewer sanity check on the simplified plan added: drop the `EXECUTION-NOTES.template.md` artefact entirely (no consumer; `ideas/` convention is concrete artefacts not parameterised templates); tag Claude-only terminology in AGENTS.md; add a calendar revisit + an in-context pointer so the trigger has a surface that fires.

## 6. What landed

Only the standalone-valuable harness rules:

- `pi/agent/AGENTS.md` `# Coding discipline` extension: stream-idle re-dispatch with idempotency caveat (inspect-then-resume vs re-dispatch fresh) + generic metric-hygiene phrasing + one-line pointer to this file.
- This audit trail (`ideas/long-plan-execution/design.md`).

Nothing else. No skill, no template, no plan-local notes (the only known consumer was retired).

## 7. Re-evaluation trigger

Promote the discipline into a skill (or a parameterised template) when:

> ≥2 stream-idle stalls in a single review cycle on a plan with ≥10 tasks, in a repo **other than** `volve-ai`.

**Amended 2026-05-13** (post batch-13 retrospective): also promote when:

> A same-class regression recurs across phases in a single batch because the first incident wasn't carried forward in resume context. (Evidence: batch-13 Phase 2–3, `GIT_INDEX_FILE` poisoning hit twice across cherry-picks, second instance corrupted canonical's `.git/config`. Maps to leaks #7 (re-triaged noise) and #9 (Standing Directives evicted by `/clear`), not the original trigger's #1/#2 (stream-idle stalls).)

The original trigger watches for **per-batch friction at scale** (≥10-task plan stalling). The amendment watches for **leak compounding within a single batch** (failure profile differs but warrants the same response: persist context across phases). Either is sufficient to revisit.

Minimal slice of §3.3 + §3.4 (`state.md` with Standing Directives + Verification invariants only) shipped 2026-05-13 in `pi/agent/AGENTS.md` § "Persistence layers". The rest of this design remains reference, activated incrementally as evidence demands.

Below these bars, the harness rules in AGENTS.md are sufficient and the discipline lessons are extracted by hand from this file as needed.

**Calendar revisit:** by **2026-11-01**. If neither the empirical trigger nor the calendar date has produced a reason to revisit by then, re-read this file once and decide whether to retire it or extend the date.

## 8. Optional: PR upstream

If the prompt-template tightenings in §3.1 / §3.2 prove out empirically (not yet validated), they could be PR'd to `obra/superpowers` directly — that's where the canonical templates live, and acceptance would deliver the discipline to every consumer via `just update-skill`. Skip if the lessons turn out to be too project-specific to generalise.

## 9. Source artefacts

Preserved in `.pi-delegate/` at the time of the design work:

- `proposal.md` — the original full design document for Plan D.
- `triple-review-synthesis.md` — synthesis of three independent peer reviews.
- `results/triple-{guided,blind,stepback}.md` — individual reviewer reports.
- `results/sanity-review.md` — single-reviewer sanity check on the simplified plan.

These can be referenced for the second-repo moment but are not authoritative — this file is.
