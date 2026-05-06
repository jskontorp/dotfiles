# Step-back review

Question the frame of a design proposal — not the details inside it.

## Procedure

Use the `step-back` skill at `~/.pi/agent/skills/step-back/SKILL.md`. Follow it literally:

- **Step 0 (evidence-gathering) is mandatory.** Read the relevant repo files: anything the proposal modifies, the repo's `AGENTS.md`, the test/CI surface, the entry-point scripts. Run `git log` queries to see whether this is a churning area or a stable artefact, whether the problem the proposal claims to solve has shown up in commit history or open issues, and whether simpler primitives that already exist in the repo could solve it.
- Every claim in Step 3 must cite evidence gathered in Step 0.

## Inputs

- Proposal: `@{{PROPOSAL_PATH}}`
- Full repo read access.

## Frame to question

The proposal commits to a particular framing — a use case, a chosen mechanism, a tier-structure, an in-scope/out-of-scope boundary. Identify those commitments by reading the proposal's "Context", "Design", or equivalent opening sections. Then question each:

- Mark each as **Validated** / **Assumed** / **Contradicted** by evidence from Step 0.
- For each, ask: is this commitment supported by the repo's history, by an open ticket or test gap, by user friction the maintainer has documented? Or is it a self-justifying symmetry?
- Specifically consider: is the proposal solving a problem that an existing primitive (test harness, lint, doc, single existing command) already solves more cheaply? Is the riskiest piece of the proposal (the change to a tested, well-trodden file) worth its blast radius given the use case?

## Argue against the proposal

Do not list "improvements within the proposed frame" unless your evidence supports the frame. The step-back skill explicitly warns against that failure mode. Do not reassure. If the right answer is "this whole thing isn't needed", say so directly and cite the evidence.

Do not propose code.

## Output

Use the format the step-back skill specifies in its Step 4:

```
## Step Back: [one-line summary]

### Evidence gathered
[git, codebase, requirements bullets]

### Current frame
[paragraph]

### Assumptions
- ✅ / ❓ / ❌ [each, with cited evidence]

### The case against the current approach
[evidence-cited bullets]

### Recommendation
**CONTINUE** | **SIMPLIFY** | **REFRAME**
[justification]
```
