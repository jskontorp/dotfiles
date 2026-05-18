# batch: delegate-tighten

started: 2026-05-18
closed: 2026-05-18
branch: delegate-tighten
ticket: (filed post-landing)
origin: odev:4.1 post-mortem (2026-05-18) → plan → double-review (batch-1, guided + blind)

commits:
- 95009cb  feat(delegate): watcher kills pi on file-timeout / MAX_WAIT, dispatch maps to 124
- f158838  feat(delegate): tighten TUI gate — require attached client + min pane height
- 015855c  docs(delegate): document tightened TUI gate, headless mode, 124 sentinel

## Standing Directives

- **Split into 3 commits** for bisect:
  - Commit A — `watcher.sh` PID-kill + `dispatch.sh` background/wait restructure.
  - Commit B — `dispatch.sh` TUI gate tightening (`session_attached` + `pane_height ≥ DELEGATE_MIN_PANE_HEIGHT`).
  - Commit C — `SKILL.md` doc updates (drop `unset TMUX_PANE` line, keep `&`-background pattern, document `124` sentinel + env var).
- **Use `setsid` + process-group kill** (`kill -- -$PI_PGID`) so signal forwarding reaches pi's children and skips the `timeout`-PID hazard.
- **Marker-based exit-code sentinel.** Watcher touches `$RESULTS_DIR/${TASK_ID}.watcher-killed` before signalling; `dispatch.sh` checks for it post-wait and writes `124` to `$EXIT_FILE` so `poll.sh` continues to report `"timeout"` (preserves today's classification, addresses guided reviewer's concern).
- **Kill from BOTH watcher branches** — file-timeout AND `MAX_WAIT`. Single helper inside `watcher.sh`, called from both sites.
- **`HEIGHT >= 20` becomes env var** `DELEGATE_MIN_PANE_HEIGHT`, default 20, rationale inline-commented.
- **`triple-review` blast radius is OUT OF SCOPE** for this branch. File a sibling JSK ticket before landing this one if the gate change creates interactive UX regression for triple-review users.
- **Test mechanism:** `tests/fixtures/pi-shim.sh` writes argv to `$RESULTS_DIR/$TASK_ID.args`, optionally sleeps forever (mode flag). Prepended to `PATH` per test. Drives all 4 cells of TUI-gate × 2 kill-path tests + 1 end-to-end regression that replays odev:4.1.

## Verification invariants

Green = all of:
- `just check` clean from canonical (pre-commit fires from worktrees via canonical hook fallback).
- `just test-skill delegate` green — existing `tests/run.sh` (`is-terminal.test.sh` + `per-batch-allocation.test.sh`) plus three new test files:
  1. `tests/file-timeout-kills-pi.test.sh` — `pi-shim` sleeps; assert PI process group dead within `FILE_TIMEOUT + 5s`; assert `$EXIT_FILE` contains `124`; assert `.watcher-killed` marker present.
  2. `tests/tui-gate.test.sh` — 4 cells (attached × pane_height ≥/< 20), assert `.args` file contains `--no-session` (headless) vs `--session-dir` (TUI) accordingly.
  3. `tests/regression-odev-4-1.test.sh` — detached `tmux new-session -d -x 80 -y 24`, split 4 panes, dispatch 4 tasks with pi-shim, assert all 4 complete with non-`timeout` exits within 30s.
- `just test` green (full Docker suite) before merge.

Expected-failing / deferred: none.

## Position

- [x] Spawn worktree (`./dev delegate-tighten`).
- [x] Initialise ledger.
- [x] Commit A — watcher.sh + dispatch.sh restructure + tests/fixtures/pi-shim.sh + file-timeout-kills-pi.test.sh (95009cb).
- [x] Commit B — TUI gate + tui-gate.test.sh + regression-odev-4-1.test.sh (f158838).
- [x] Commit C — SKILL.md doc.
- [ ] Triple-review sibling-ticket decision (file or punt) — punt unless interactive smoke surfaces a regression.
- [ ] File primary ticket post-landing.
- [ ] PR + merge.

## Open decisions

- Whether to also wire `pane_width` into the gate — deferred (blind raised; pi has no documented minimum). Revisit only if testing surfaces a width-driven render failure.
- Whether `triple-review/SKILL.md` needs an "attach now or accept headless" prompt before the `tmux new-session -d` line — file sibling ticket only if interactive smoke surfaces a regression.
