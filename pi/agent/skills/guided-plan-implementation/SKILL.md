---
name: guided-plan-implementation
description: >-
  Use when you have a written implementation plan and the HUMAN will write the
  production code while you scaffold the tests, direct each change, and verify
  the result. Triggers: "guide me through this plan", "I'll write the code, you
  guide me", "walk me through implementing this", "navigate while I drive". NOT
  for when you write the implementation yourself.
claude-compatible: true
---

# Guided Plan Implementation

You are the **navigator**; the human is the **driver**. You build verified
understanding, write the tests, and hand the human precise directions for each
change — they type the production code. Work one logical section at a time.

## Division of labor (the load-bearing rule)

**Tests are yours. Production code is the human's.** "The human writes the code"
means *implementation* code — it does **not** mean tests get skipped. Writing the
failing test that defines "done" is the navigator's core job; skipping it because
"the human said they'd write the code" guts the whole method. You write tests;
you direct changes; you verify. The human types the implementation.

## Phase 0 — Ingest, assume nothing

Read the plan, then open every file, line reference, sibling implementation,
migration, and contract it cites and confirm each against the actual code. A
plan's "verified facts" are claims to re-check, not ground truth — line numbers
drift and plans are wrong. Produce a short map: what you confirmed, and what you
couldn't (the gaps become interview material).

## Phase 1 — Clarify gate

If any decision remains that would change what gets built, resolve it before
writing a test. **REQUIRED:** use relentless-interview.

## Phase 2 — Per-section loop

For each logical section of the plan, in order:

1. **Write the tests first.** Targeted tests that pin the real contract this
   section establishes — the test that fails if the change is reverted or
   regressed later. (E.g. for a non-destructive operation: seed parent + child
   rows, run it, assert the child rows are unchanged.) No theatre: a test that
   mocks the unit and asserts the mock, or that passes before the code exists,
   proves nothing. Keep the test small enough to explain exactly what regression
   it catches.
2. **Direct the change — default altitude.** A direction contains exactly:
   (a) file + location, (b) what changes, (c) why / which sibling to mirror. It
   stops one notch short of the literal code — enough to type it without
   puzzling, without you having written it. Then stop; let them implement.
3. **Escalate only on request.** When the human asks for more ("need more hits",
   "show me the diff"), give the complete before/after red-green diff: readable
   and directly applicable, optimized for a human to read and apply — not for
   copy-paste minimalism.
4. **Hand back → verify (Phase 3) before the next section.**

## Phase 3 — Verify by reading, not just running

A passing test run is not proof. For the section just handed back, check:

- **Read the diff** the human wrote, line by line.
- **Coverage** — every plan item for this section landed; nothing out of scope
  crept in.
- **Test bite** — the tests would fail if the change were reverted. If not, the
  test is theatre; fix it.
- **Failure modes** — no swallowed errors, silent fallbacks, or drift from the
  plan's stated contract.

Gaps → name them (file + line + what's missing) and loop back. Clean → advance.

## Quick reference

| Phase | You produce | Human produces |
|-------|-------------|----------------|
| 0 Ingest | Verified context map | — |
| 1 Clarify | Resolved decisions (interview) | Answers |
| 2 Tests | Failing targeted tests | — |
| 2 Direct | Below-diff direction (→ full diff on request) | Production code |
| 3 Verify | Read-the-diff verdict + gaps | Fixes |

## Common mistakes

| Mistake | Reality |
|---------|---------|
| "Human writes the code, so I won't write tests" | Tests are the navigator's job. The human types *implementation*, not tests. |
| Trusting the plan's line refs without opening the file | Refs drift; re-verify in Phase 0. |
| Writing all tests up front | Couples sections, floods the driver. One section at a time. |
| Defaulting to full diffs | Robs the human of driving. Below-diff is push; full diff is pull. |
| "Tests pass, so it's done" | Read the diff. A green mock test proves nothing. |
