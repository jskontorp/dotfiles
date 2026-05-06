# Guided peer review

Evaluate a design proposal against the conventions of the repo it would land in. Cite concrete evidence — filenames, line ranges, git history, AGENTS.md sections — for every verdict.

## Inputs

- Proposal: `@{{PROPOSAL_PATH}}`
- Full read access to the repo.

## Required reading before verdicts

1. The proposal.
2. `@AGENTS.md` plus any nested `AGENTS.md` in directories the proposal touches. Specifically:
   - "trigger matrix" / "conventions" / "workflow rules" — does the proposal respect them?
   - "Known regression classes" / "Known gaps" — does the proposal interact with any, and does it handle them?
3. Every file the proposal modifies or extends. Read each one before evaluating the change to it.
4. The relevant test/CI surface (`test/`, `Makefile`, `justfile`, `package.json` scripts, GitHub Actions — whichever apply).

Run, at minimum:
- `git log --oneline -40` — recent change patterns; is this a churning repo or a stable artefact?
- `git log --oneline --all -- <file>` for each file the proposal modifies — how that file has historically broken.

## Criteria

For each criterion that applies, give a verdict (✅ aligned / ⚠ partial / ❌ misaligned) and one-sentence justification with concrete evidence (`file:line` or commit SHA). Skip criteria that genuinely don't apply; don't pad.

1. **Invariant compatibility** — manifest shapes, schema versions, idempotency contracts, file-format guarantees the repo currently relies on.
2. **Idempotency** — new code safe to re-run; existing scripts the proposal modifies still idempotent after the change.
3. **Known regression classes** — interaction with documented regression classes (AGENTS.md or git history); solved, ignored, or re-introduced.
4. **`set -e` / missing-tool interactions** — unguarded external commands, dangling-symlink-unfriendly tests, strict-mode foot-guns.
5. **Cross-platform / cross-environment parity** — if the repo targets multiple OSes or runtimes, does the proposal handle each or quietly assume one.
6. **Test acceptance criteria** — sufficiency. Specifically: would the suite green-light a no-op or destructive implementation? What seed states / negative cases are missing?
7. **Trigger-matrix / docs coherence** — new rows AGENTS.md (or equivalent) needs; existing rows that need updating; which command catches regressions in the new code itself.
8. **Failure modes the proposal hasn't named** — examples to consider: partially-completed previous run, manually-edited state file, foreign symlink, dest path read-only, case-insensitive filesystem name-collision, an artefact the proposal assumes exists but that's absent on installs predating the change.
9. **Migration hazard** — host / repo / database that ran the *old* code and now runs the *new* code. Is that path safe, or does it require a migration step the proposal doesn't name?

## Output

```
# Guided review

## Verdicts
1. <criterion> — [✅/⚠/❌] [justification: file:line or SHA]
[... applicable criteria]

## Failure modes the proposal does not name
- [each]

## Concrete fixes recommended
- [each — propose the change, not just the gap]

## Overall verdict
[Land as-is / Land after addressing X / Reframe — 2–3 sentences]
```

Do not restate the proposal. Do not propose features outside what the proposal commits to.

