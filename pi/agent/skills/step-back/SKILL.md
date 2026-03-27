---
name: step-back
description: >-
  Break out of the current problem-solving frame and question assumptions.
  Use when the user says "step back", "take a step back", "what are we
  missing", "are we stuck", "sanity check", or any signal that the current
  approach might be wrong. Also use when the same class of bug has been
  fixed more than twice, or when an architecture rewrite is being proposed.
  Do NOT use for normal code reviews or debugging — this is for questioning
  the frame, not working within it.
---

# Step Back

Stop building. Start analysing.

This skill exists because coding agents are biased toward building.
When asked "what are we missing?", they list implementation gaps within
the current frame. They don't question the frame itself. This skill
forces that question.

**Known failure mode of this skill:** The agent will be tempted to
produce a structured analysis that looks critical but ultimately
endorses the current approach. The conversation context (50-100KB
reinforcing the current frame) is stronger than these instructions
(5KB). Fight this by gathering evidence first, reasoning from
evidence second, and never skipping the evidence-gathering steps.

## When this skill triggers

- User says "step back", "what are we missing", "sanity check"
- The same class of bug has been fixed 3+ times (patching around a
  deeper problem)
- An architecture rewrite is being proposed (lateral move, not
  simplification)
- The user is spending time on infrastructure/plumbing instead of
  the actual problem

## Procedure

### 0. Gather evidence before reasoning

Do this FIRST. Do not skip it. Do not reason from the conversation
history alone — the conversation is the frame you're trying to escape.

**Read the source of truth:**

```bash
# What does the problem statement / requirements actually say?
# Find and read the original spec, task description, scoring docs.
find . -maxdepth 3 -name "*.md" | head -20
```

```bash
# What has the git history looked like? Are we churning?
git log --oneline -30
```

```bash
# Are we fixing the same kind of thing repeatedly?
git log --oneline -50 | grep -iE "fix|patch|workaround|retry|fallback"
```

```bash
# How much code is there? Is complexity proportional to the problem?
find . -name "*.py" -o -name "*.ts" -o -name "*.rs" | head -30 | xargs wc -l 2>/dev/null | tail -1
```

```bash
# Where is the time going? What files change most?
git log --pretty=format: --name-only -30 | sort | uniq -c | sort -rn | head -15
```

Read the key files. Do not rely on the conversation's description of
what they contain — re-read the actual code and actual requirements.

### 1. State the current frame

Write one paragraph describing the current approach. Be concrete:

> "We are building X using Y architecture. The system works by [flow].
> We are currently debugging [specific problem]."

Do not evaluate. Just describe.

### 2. List what the current approach assumes

Enumerate every assumption baked into the current design. These are
things that, if wrong, would make the approach fundamentally misguided
rather than just buggy. Examples:

- "This requires an LLM" — does it? What would this look like with
  regex, parsing, or lookup tables?
- "We need to fetch X at runtime" — do we? Could it be hardcoded,
  cached, or pre-computed?
- "The system must be general-purpose" — must it? Would N specific
  solutions be simpler than 1 general one?
- "This error means the logic is wrong" — or is the logic right but
  wrapped in something that undermines it?

For each assumption, check against the evidence gathered in step 0.
Mark each as:
- **Validated** — tested and confirmed with evidence (cite the evidence)
- **Assumed** — carried forward from initial design, no verification
- **Contradicted** — evidence from step 0 suggests this is wrong

### 3. Argue against the current approach

Spend real effort here. This is not a formality.

**Use the evidence from step 0, not the conversation history.**
If the git log shows the same file being patched 8 times, that's
evidence the file's design is wrong. If the codebase is 2000 lines
for a problem that could be solved in 200, that's evidence of
over-engineering. If the requirements say X but the code does Y,
that's evidence of drift.

Answer each of these:

- **What is the simplest system that solves this problem?** Not the
  current system minus some parts — start from zero. One sentence.
- **What would someone build who doesn't know about the current
  approach?** Give them the requirements file and nothing else.
- **What is the current approach compensating for?** Look at the git
  log: if fixes are concentrated in one layer, that layer is the
  problem. If there's a "fallback" or "retry" mechanism, what is it
  compensating for? Could you remove the thing that causes the
  failures instead of catching them?
- **Where is time going vs. where should it go?** Check the git
  history. Are most changes in infrastructure or in the actual
  problem domain?
- **What does the scoring / success criteria reward that we're
  ignoring?** Re-read the scoring docs from step 0. What have we
  not tested or experimented with?
- **What does the environment provide that we're rebuilding?** Check
  what already exists — pre-created data, free operations, built-in
  features we're reimplementing.

### 4. Present findings

Structure the output as:

```
## Step Back: [one-line summary of what we found]

### Evidence gathered
- Git: [X commits, Y fix-type commits, most-changed files]
- Codebase: [N lines across M files]
- Requirements: [key things re-read from source]
- [any other evidence]

### Current frame
[paragraph from step 1]

### Assumptions
- ✅ [validated — cite evidence]
- ❓ [assumed — what would change if wrong]
- ❌ [contradicted — cite evidence]

### The case against the current approach
[step 3 findings — be blunt, cite evidence for each claim]

### Recommendation
[exactly one of:]

**CONTINUE** — the frame is sound, the problem is execution.
Specific thing to fix: [X]. Evidence: [Y].

**SIMPLIFY** — the frame is right but over-engineered.
Strip [X] and [Y]. Evidence: [Z].

**REFRAME** — the frame is wrong. Build [X] instead.
Evidence: [Y]. The key mistake was: [Z].
```

**Wait for the user's response before making any changes.**

## Constraints

- **Do not propose code changes.** This is analysis, not implementation.
- **Do not reassure.** If the approach is wrong, say so directly.
- **Do not list improvements within the current frame** unless step 3
  produced genuine evidence that the frame is correct.
- **Every claim in step 3 must cite evidence from step 0.** If you
  can't cite evidence, say "I believe X but have no evidence" — that's
  useful information. Do not present speculation as analysis.
- **If step 0 evidence is ambiguous, say so.** "The git history
  doesn't clearly show churn" is better than forcing a conclusion.
- **The default answer is not CONTINUE.** If assumptions are mostly
  unvalidated and evidence is thin, the honest recommendation is
  "we don't know if this frame is right — here's how to find out."
