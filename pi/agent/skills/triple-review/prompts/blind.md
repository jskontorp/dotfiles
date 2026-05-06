# Blind peer review

Critique a design proposal as a stand-alone document, with no other context.

## Inputs

- Proposal: `@{{PROPOSAL_PATH}}` — read once.
- Nothing else. Do **not** read source code, READMEs, configs, or any other file in the repo.

The restriction is the point: if the proposal can't survive being read on its own, that's the finding. Do not speculate about "what the codebase probably does" — unverifiable speculation is exactly what this review must not produce.

## What to find

- **Ambiguities** — phrases the proposal mentions but doesn't define precisely enough to implement without guessing.
- **Unstated assumptions** — claims that depend on behaviour the proposal doesn't describe.
- **Missing failure modes** — bad states the design would land in but doesn't acknowledge.
- **Internal contradictions** — places where two parts of the proposal disagree.
- **Acceptance-criteria gaps** — tests that would pass even if the implementation were a no-op, destructive, or partial.
- **Edge cases at the boundaries** — paths with spaces, symlinks-to-symlinks, atomicity, race conditions on interrupt; what "empty" / "absent" / "valid" mean for boundary values.
- **Scope creep risks** — features the proposal hints at that would balloon if implemented carelessly.
- **Adversarial inputs** — states a hostile or sloppy user could create that the design doesn't handle: `chmod 000` a critical file, replace it with a symlink loop, delete state between phases, run two operations in parallel.

Be specific. If something is hand-wavy, name it and quote the phrase. Do not summarise the proposal back; do not pad with praise.

## Output

```
# Blind review

## Ambiguities and underspecified bits
- [each, one bullet, quote the relevant phrase from the proposal]

## Unstated assumptions
- [each]

## Missing failure modes
- [each]

## Internal contradictions
- [each, or "none found"]

## Acceptance-criteria gaps
- [tests that would pass with broken implementations]

## Edge cases the design ignores
- [each]

## What I would want clarified before approving this
- [3–5 sharpest questions]

## Verdict
[Approve / Approve with revisions / Block — one paragraph]
```

If the proposal doesn't say something, that itself is a finding — flag it. Do not invent details.
