# JSK-43 proposal: hook-chain interaction test

Tracking: Linear JSK-43 (medium priority). Carried forward from JSK-41's
batch-13 retrospective. Sibling tickets: JSK-44 (landed, `b198fcb`),
JSK-45 (landed, `8f210d6`).

## Problem

The `pre-commit` hook (secret-path gate, JSK-35) and the `commit-msg` hook
(silencing-gate, JSK-36) are tested individually but not together. Hook
ordering means `pre-commit` runs first and aborts before `commit-msg` is
ever consulted. A commit that would trip both gates therefore exposes
its second failure mode only on retry — surprising the user and creating
a debugging puzzle ("I fixed the secret-path issue, why is git still
refusing?").

There is no test asserting the chain's actual behaviour. A regression
that broke either gate's exit-code propagation (so the chain swallowed
one of the refusals) would land green.

## Scope

Add an integration test exercising both hooks in sequence in a tmprepo.
Document the chained-refusal UX in both hook headers.

## File layout

**New**: `test/check-hook-chain.sh` — standalone test, modelled on the
setup pattern of `test/check-silencing-gate.sh` and
`test/check-secret-gate.sh`. Builds a tmprepo, installs *both* hooks +
both libs + the patterns MD, runs synthetic commits.

**Modified**:
- `git/hooks/pre-commit` — add ~4-line header note about the chained UX.
- `git/hooks/commit-msg` — same.
- `justfile` — add the new check to the `check:` recipe.
- `git/lib/silencing-gate.sh` — extend `SILENCING_GATE_ALLOWLIST_RE` to
  include `^test/check-hook-chain\.sh$` (the new test contains literal
  `# noqa` fixtures and would otherwise self-trip the gate when the
  test file itself is committed).

## Test cases

Three cases, each asserting one observable behaviour:

### Case 1: `chain-real-commit-pre-commit-fires`

Stage two files:
- `id_ed25519` (file path matches secret-gate's deny pattern set)
- `src/silenced.py` containing `x = 1  # noqa` (diff content triggers silencing-gate)

Run real `git commit -m "WIP"`. Assert all three:
- Exit code non-zero.
- stderr contains the secret-gate's refusal message (e.g. "refusing to
  commit: staged paths match deny patterns" — exact substring TBD by
  reading the gate's error format).
- stderr does *NOT* contain the silencing-gate's refusal message —
  this is the load-bearing assertion proving `pre-commit` aborted
  before `commit-msg` ran.

### Case 2: `chain-after-secret-fix-silencing-fires`

Reset the index. Re-stage only `src/silenced.py` (simulating "user fixed
the secret-path issue by removing the key file"). Run real
`git commit -m "WIP"`. Assert:

- Exit code non-zero.
- stderr contains the silencing-gate's refusal message — proves the
  second issue is reachable on retry.

### Case 3: `chain-standalone-commit-msg`

With the same staged set as Case 2, invoke `git/hooks/commit-msg`
directly (`$HOOK /tmp/msgfile`). Assert:

- Exit code non-zero, with the same silencing-gate refusal message.

This case is borderline-required vs nice-to-have. The argument for
keeping it: gives users a documented debugging command ("run the
commit-msg hook standalone to test your fix without re-staging").
The argument against: case 2 already verifies the second refusal
fires; case 3 is a strict subset that adds little.

## Header documentation

Add to top of `git/hooks/pre-commit` (after the existing comment block):

```
# Hook chain: this is the first hook to run. The commit-msg hook
# (silencing-gate, JSK-36) runs *after* this one returns 0. Commits
# that trip both gates will only surface this gate's refusal on the
# first attempt; the silencing-gate refusal becomes visible on retry
# once the secret-path issue is fixed. See JSK-43 for the chain test.
```

Add to top of `git/hooks/commit-msg` (after the existing comment block):

```
# Hook chain: pre-commit (secret-path gate, JSK-35) runs first and
# aborts on refusal before this hook is consulted. To test a fix in
# isolation without re-staging the secret-path bait, run this hook
# standalone: `git/hooks/commit-msg path/to/COMMIT_EDITMSG`. See
# JSK-43 for the chain test.
```

## Sequencing in `just check`

Add to `justfile`'s `check:` recipe alongside the other check scripts,
placed *after* `check-secret-gate.sh` and `check-silencing-gate.sh`
(so the chain test's failure messages reference gates the user has
already seen pass):

```
printf "\nhook chain (JSK-43):\n"
bash {{DOTFILES}}/test/check-hook-chain.sh
```

## Self-exemption from related lints

- `test/check-hook-chain.sh` must start with the canonical
  `unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR`
  idiom (lint-enforced by JSK-44 since it'll contain `git init`).
- Path `test/check-hook-chain.sh` added to
  `SILENCING_GATE_ALLOWLIST_RE` so the literal `# noqa` fixture strings
  in this file don't self-trip the gate.
- Secret-gate is content-pattern based, not path-based. Fixtures using
  literal strings like `id_ed25519` (as filenames staged inside the
  tmprepo) are safe; the test does not write real key material.

## Fixture-target lessons applied (from JSK-45)

JSK-45's first implementation cascaded three test failures because the
pass-case fixture overwrote `git/lib/silencing-gate.sh` (the hook's
runtime dependency). For this test:

- `src/silenced.py` is the silencing-gate fixture — a fresh path not
  used by either hook.
- `id_ed25519` is the secret-gate fixture — staged inside the tmprepo
  at root, NOT a real key, no surprises.
- Neither hook nor lib is overwritten during the test run.

## Acceptance

- `bash test/check-hook-chain.sh` standalone: all three cases pass.
- `just check` from any worktree: rc=0.
- `just test` (Docker, full suite): 137+3=140 expected? Or remains 137
  if the Docker harness only counts the headline pass/fail of each
  check script. (Confirm by running.)
- The headers of `git/hooks/pre-commit` and `git/hooks/commit-msg`
  reference JSK-43 and the chained-refusal UX.

## Out of scope

- Refactoring either gate's implementation. This is a test-only change
  except for header comments and the silencing-gate allowlist entry.
- Adding a "did you mean to fix both issues?" UX nudge in either hook's
  refusal message. Possible follow-up, but creep beyond this ticket.
- The pre-commit hook self-check (JSK-46) — separate ticket, full
  triple-review treatment, deferred to a fresh session.

## Risks

1. **Secret-gate fixture must trigger reliably.** The gate matches on
   filename patterns. Staging a file *named* `id_ed25519` (with empty
   or stub content) should match. To be confirmed by reading the
   gate's pattern list (`git/lib/secret-gate.sh`) before implementation.

2. **stderr-vs-stdout capture.** Both gates print refusal messages to
   stderr. The test must capture both streams; the negative assertion
   ("silencing-gate message NOT present") must run against captured
   stderr, not stdout. Easy to get wrong; explicit `2>&1` redirection
   in the test.

3. **Test fragility on exact error-message strings.** If a gate's
   wording is reworded later, the test breaks. Mitigation: assert on
   a unique substring per gate (e.g. "secret-gate" / "silencing-gate"
   identifier strings if present) rather than full message text.

4. **CI vs local environment differences.** The Docker harness for
   `just test` runs a fresh repo without `.git/info/exclude` markers
   etc. Confirm the new check works under Docker before declaring done.

## Estimated size

- `test/check-hook-chain.sh`: ~100-120 lines (setup ~40, cases ~60-80).
- `git/hooks/pre-commit` header: +5 lines.
- `git/hooks/commit-msg` header: +5 lines.
- `git/lib/silencing-gate.sh` allowlist: +1 token in regex.
- `justfile` `check:` recipe: +2 lines.

Total: ~115-135 added lines across 5 files. One commit.
