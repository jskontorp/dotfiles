# batch: pi-1-2-compat
closed: 2026-10-21

## Standing Directives

- User approved executing the recommended first batch: failure propagation, small config/docs corrections, real-Pi compatibility coverage, and all test suites.
- User approved a new pi-1-2-compat worktree despite a sibling Pi and foreign shared/gitconfig edits in canonical. Leave canonical and that file untouched.
- No commit, merge, relink, external writes, or shared tmux changes without further approval.
- Preserve model defaults pending a user choice; do not enable codemode globally or migrate to MCP.
- Linear filing proposed for post-landing; no answer yet, no Linear writes.
- User approved expanding the batch to diagnose/repair the pre-existing delegate regression and its masking test runner, without weakening assertions.
- Latest directive: polish and simplify, preserving functionality, then commit. Commit is now approved; merge, push, relink, and external writes remain unapproved.
- User approved merging into canonical main while preserving shared/gitconfig; no push or relink. Cleanup commands still require explicit per-call approval.
- User approved proceeding with the landing-record commit; remove the clean merged worktree and branch only with per-call confirmation.

## Verification invariants

- Baseline and final: just check; (cd pi/agent/extensions && tsc --noEmit); node --test pi/agent/extensions/shared/*.test.mjs; just test-skills; just test both.
- Add focused failure-propagation tests and an offline real-installed-Pi compatibility test. No live provider/API calls, credential reads, or outbound writes in runtime tests.
- Keep all runtime test state disposable and outside the user's live agent directory. Test tools/transports must record effects rather than execute destructive operations.
- Do not change existing assertions or suppress checks to obtain green output. Report unrelated baseline failures separately and request approval before fixing them.
- Worktree checks must not run just link/install.sh against the host. Docker install tests are isolated.
- Any remaining gaps (real terminal, Oracle, long-lived-process behavior) are reported explicitly rather than inferred from unit tests.

## Phase log

- Orientation: canonical main at c9e753b; existing shared/gitconfig change and sibling Pi observed. Created isolated worktree on branch pi-1-2-compat using git worktree add; no tmux window created.
- Plan: (1) baseline; (2) failure-propagation fixes/tests; (3) config/docs and runtime coverage; (4) complete verification and diff review. Model choice and global codemode adoption remain deferred.
- Baseline before implementation: just check passed; direct tsc passed; 10/10 shared Node tests passed; just test both passed 143 checks. No surviving delegate-test processes or Docker containers observed afterward.
- Baseline blocker: just test-skills printed 7 failed assertions in delegate/tests/regression-odev-4-1.test.sh (only 1/4 tasks produced .exit files within 45 seconds; tasks 1/2/4 missing exit and headless argv evidence). Other delegate files and all session-scan files passed. The overall command incorrectly exited 0: delegate/tests/run.sh assigns rc=$? inside `if ! "$t"`, capturing the negated status. Both defects predate implementation. Existing regression assertions/invocation left unchanged; root cause of the tmux regression is not yet established.
- User approved the baseline expansion. Five new failure-propagation tests reproduced four failures before fixes and now all pass: child status/output preservation (0/1/7/124/137), delegate runner aggregation, and just-check stage exit propagation. Fixed dispatch PIPESTATUS capture, delegate runner negation, and just check AND-list masking.
- The tmux regression passed 10/10 twice on unchanged retries; live pane capture on the second retry showed all four zsh panes executing the shim. Root cause of the initial intermittent startup failure remains unproven; no assertions or sleeps changed.
- Config/docs phase: added published schema references, explicitly selected regular TUI, preserved model defaults, corrected skill-invocation documentation, replaced doctor's removed legacy routing checks with current shared routing tests and extension-link checks, and made its DOTFILES expectation canonical-aware.
- Runtime coverage phase: real installed Pi 1.2 loaded all seven extensions; direct and codemode-nested gates passed, with zero fake effects. Mixed-UI test exposed separate Linear/Notion helper instances: loader uses moduleCache:false, so the existing module-local mutex was not process-wide. Moved the mutex onto globalThis and routed destructive/secret prompts through it. Runtime test now passes across reload, model changes, offline hook-provided compaction, and persisted resume. Added a duplicate-module unit regression; all 16 focused host tests pass.
- Doctor passed in the worktree, validating canonical links and current routing without credential reads. README documents the test boundaries, pnpm ownership, relink/model-default caveat, and opt-in codemode pilot.
- Approved tmux-test harness repair: use explicit bash --noprofile --norc in test panes rather than inheriting host zsh startup, eliminating that external readiness dependency and its fixed two-second assumption. All ten original assertions retained and passing. The exact original startup event remains unproven; this is isolation of the test harness, not a claimed production delegate fix.
- Final verification passed: just check (including 16 Node tests); direct tsc --noEmit; direct shared Node tests (11/11); just test-skills (all delegate and session-scan suites; original tmux regression 10/10); just test both (143/143); just test-pi (7/7, installed SDK 1.2.0); just doctor; git diff --check. Runtime sandbox isolates HOME, shadows keychain lookup with a refusing fixture, and asserts zero lookup attempts and zero network attempts. No surviving test processes, delegate-test sessions, or Docker containers observed.
- Final diff review complete. Updated AGENTS.md's existing modal regression entry with the independent-module-instance finding and added the runtime test to upgrade/gate-change verification guidance. Proposed additional regression entry for landing approval: shell status masking (Evidence: 0d891ab, 1115932; detection: test/check-failure-propagation.mjs; fixed in this worktree, not landed).
- Deferred by first-batch scope: model selection, global codemode, MCP migration, watcher/archaeology redesign, real interactive terminal and Oracle checks, and validation of the original long-lived-process failure over comparable elapsed time. No new dependencies. No commit, merge, relink, or external writes performed. Worktree retained for user review/landing approval; ledger remains open until landing.
- Landed as merge d6dd4f8 on main (implementation 0a707f7). Post-merge just check, just doctor, just test-skills, just test both (145/145), just test-pi (7/7), direct tsc and Node tests (16/16) passed. git diff --check reports only pre-existing trailing whitespace in shared/gitconfig at lines 23/33; its fingerprint is unchanged (87fcb7b9cfb6cc176f4c3190a6b15ceb3edafbca). Closure-record commit approved; clean worktree/branch removal awaits per-call confirmation. Existing shared/gitconfig edits stay unstaged; no push or relink.
- Polish phase complete: reviewed all 16 changed/untracked files; no foreign worktree edits found. Consolidated confirmation locking through withPromptLock, removed the delegate runner's no-op branch, used the documented nested-call shape, made interactive test cleanup single-path, shortened docs, and recorded the shell-status regression. Post-polish verification passed: just check; just doctor; just test-skills (both suites); just test both (143/143); just test-pi (7/7); direct tsc; direct shared/failure Node tests (16/16); git diff --check. No new dependencies or weakened safety assertions. Approved commit prepared: `Harden Pi 1.2 compatibility and failure reporting`. Ledger remains open because branch integration/landing is not approved; no merge, push, or relink.
