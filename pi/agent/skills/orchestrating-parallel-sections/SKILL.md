---
name: orchestrating-parallel-sections
description: Use when a written plan is already partitioned into file-disjoint sections (merge-fix plans, multi-area refactors with "Section A/B/C — safe to run in parallel") and you are implementing them by dispatching one subagent per section in the current session.
---

# Orchestrating Parallel Sections

## Overview

A plan is already carved into sections that touch **disjoint sets of files**. Dispatch one subagent per section in parallel, then do the part the plan does not: integrate the independent edits and reconcile what diverged.

**Core principle:** parallelism is safe only while the file sets stay disjoint. The moment edits land in one tree, per-agent verification is stale — only the integrated re-check and a divergence reconciliation are authoritative.

**REQUIRED SUB-SKILL:** Use delegate for the dispatch mechanics (focused scope, self-contained prompt, parallel-in-one-message). This skill is the integration layer on top of it.

## When to Use

- A plan document with labelled sections explicitly marked parallel-safe / file-disjoint.
- You will write the code via subagents this session (not a parallel session → that's executing-plans).
- Sections are independent edits, not a sequential implementer→reviewer loop (→ subagent-driven-development).

## The Cycle

### 1. Verify disjointness before dispatching
Map each section to the files it owns. If two sections list the same file, they are NOT parallel-safe — merge them into one agent or sequence them. A file referenced read-only by one section and written by another is fine; say so in both prompts ("read X for reference, do NOT edit it — another agent owns it").

### 2. Dispatch one agent per section, in one message
Each prompt carries:
- **The files it owns** + an explicit "do not touch files outside this list — other agents own them in parallel."
- **Shared spec blocks** the section depends on, pasted verbatim (multiple agents may each need the same shared context).
- **Re-verify before editing:** "confirm the diagnosis still holds against current code + installed dependency versions before changing anything." Plan line numbers and root-cause claims drift; the agent checks, then edits.
- **No commits, no git, no outbound calls.** The orchestrator owns integration, commits, and any PR/Linear/Slack step. Subagents leave changes unstaged and report `file:line` + deviations.

### 3. Integrate — trust only the merged-tree check
When agents return, **re-run the full check suite (typecheck/lint/build/tests) yourself on the integrated tree.** Per-agent green is not integrated green:
- An agent that ran lint mid-flight may report an error caused by **another agent's in-progress edit** (e.g. an import added before its first use). These are transient — they vanish once all edits land. Don't chase them; re-run on the whole.
- An agent's "clean" can hide a conflict that only appears when its edit meets another's.

### 4. Reconcile divergence
Agents that read the **same shared spec independently will solve it differently.** After integration, diff the parallel solutions to any shared problem and decide whether the divergence is acceptable or should converge. Surface it explicitly — the plan author and reviewers expect the sections to match.

## Common Mistakes

| Mistake | Fix |
|---|---|
| Trusting a subagent's "lint clean / lint error" verdict | Re-run all checks on the integrated tree; that result is the only authoritative one |
| Treating a flagged error in another agent's file as real | It's likely a transient mid-flight artifact — re-run on the whole before acting |
| Letting two agents share a file | Not parallel-safe; merge or sequence those sections |
| Assuming agents converged on a shared spec | They didn't — diff their solutions and reconcile |
| Subagent commits / posts the PR reply | Orchestrator owns commits and all outbound steps; subagents report only |
| Pasting the plan's line numbers as ground truth | Tell each agent to re-verify the diagnosis against current code first |

## Real-World Impact

A 3-section SSE merge-fix: two agents flagged the same `'useRef' is unused` lint error — a transient artifact of the third agent adding the import before its usage landed. Integrated re-run was clean. Separately, the two stream hooks diverged on close-detection (one `readystatechange`→CLOSED listener vs an `error`+`abort` pair); reconciling them post-integration closed a real reconnect gap the per-section work missed.
