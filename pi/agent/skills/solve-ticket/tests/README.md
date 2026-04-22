# solve-ticket tests

Plain-bash regression tests for the scripts under `../scripts/`. No test framework dep — mirrors the repo's `test/verify.sh` pattern.

## Running

```sh
./run.sh              # all tests
./workspace-setup.test.sh   # one file
just test-skill solve-ticket   # via justfile
```

## Design

- Each `*.test.sh` is an executable script sourcing `lib/helpers.sh`.
- Each test case calls `setup_sandbox` (new `$TMP`, overridden `HOME`/`GIT_CONFIG_*`, PATH-prepended `$STUB_DIR`) and `teardown_sandbox` after.
- Stubs are short inline bash bodies written into `$STUB_DIR` via `make_stub`. Call counts, argv, and sequenced outputs live in `$STUB_STATE_DIR`.
- Fixture lockfiles under `lib/fixtures/` are empty `touch`es — existence markers only. `$PM` is always stubbed; real `pnpm install` never runs.

## When to switch to bats-core

- Total test cases > ~40
- Need selective runs (`bats --filter=...`) or parallel execution
- CI runtime > 30s
- Helpers > 200 LOC

Today we're at ~20 cases and ~120 LOC of helpers. Nowhere near.

## Not covered

- The "neither `timeout` nor `gtimeout` exists" path in `peer-review-spawn.sh` — would require sandboxing PATH so completely that every real command used by the script is stub-linked. Tested manually. All other exit codes have coverage.
- Real integration against `pi` binary. The pi spawn is stubbed; we assert on argv and env, not on pi's actual behaviour.
- CI. None exists for this repo; these tests are dev-loop-only, same as `test/verify.sh`.
