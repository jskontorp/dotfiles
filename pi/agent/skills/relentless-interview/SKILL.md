---
name: relentless-interview
description: >-
  Use when a plan, spec, or design has unresolved decisions and you must reach
  shared understanding with the human before acting. Triggers: "interview me",
  "interview me relentlessly", "ask me everything", "clarify before you build",
  "nail down the plan", or any task where guessing a fork would waste work.
  Also invoked by guided-plan-implementation at its clarify gate.
claude-compatible: true
---

# Relentless Interview

Drive to shared understanding before acting. Walk down each branch of the design
tree, resolving dependencies one at a time. The output is alignment, not a
transcript.

## Rules

1. **One question at a time.** Never batch. Each answer reshapes the next
   question; a numbered list of five freezes the tree and the human answers one.
2. **Recommend an answer with every question.** State your pick and the one-line
   reason — "I'd go with X because Y; agree?". A menu of options is *not* a
   recommendation; you still have to pick one. Asking open-ended ("how should
   auth work?") offloads your thinking onto the human. Recommend even when
   unsure — a wrong recommendation is corrected faster than a blank is filled.
3. **Explore before you ask.** If the codebase can answer it, read the code.
   Reading is not editing, so "this is just planning, I won't touch code" is no
   excuse. Spend questions only on what code can't tell you: intent, priorities,
   external constraints, taste.
4. **Order by dependency.** Resolve the decision others hinge on first. Don't ask
   about a leaf while its parent is open.

## When to stop

Stop when no remaining decision would change what you build — not when you run
out of questions. If a branch turns out not to matter, say so and skip it.

## Red flags

- A numbered list of questions in one message — you've batched; cut to the first.
- A question with no recommended answer attached.
- Asking something `grep` would answer in ten seconds.
- Still interviewing after the forks are resolved.
