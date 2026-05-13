> **Agent note:** Shared between pi and Claude Code. Sections marked `(pi only)` or `(claude only)` apply only to that agent; the other agent should treat them as non-actionable context. Pi-specific invocations (`pi` CLI, `.ts` extensions, `just add-skill`) live under the tagged sections.

# Coding discipline

Read code before proposing changes to it. If the user asks you to modify a file, read it first. Understand existing code before suggesting modifications.

Prefer editing existing files to creating new ones. Create new files only when truly necessary.

Match the scope of the request exactly. A bug fix changes only what's broken; a simple feature ships without extra configurability; docstrings, comments, and type annotations belong only on code you're already changing.

Inline one-time operations rather than wrapping them in helpers, utilities, or abstractions. Design for the requirements in front of you. Three similar lines of code is better than a premature abstraction.

When something fails (tool call, build, test):
- Read the error. Diagnose before switching tactics.
- Each retry must reflect something you learned from the error. A viable approach earns 2–3 informed attempts; after that, switch tactics or report. Variations targeting the same root cause count as one approach.
- Treat the failure as evidence to investigate; the next tool call typically reveals more than reporting back to the user does. The "say so and move on" rule (under Standards) applies to things you can't observe, not to things the next tool call would reveal.

If a subagent dispatch returns a partial-response or stream-idle error: check for visible side effects (committed files, written artefacts) first. If they exist, re-read the affected files and resume from observed state — re-dispatching restarts from zero and double-applies them. If none, re-dispatch fresh. (Elapsed-time labels during a stall are not work — read progress from side effects only.)

For broader long-plan execution discipline (ledger split, pre-compact protocol, reviewer-brief sizing), see [`ideas/long-plan-execution/design.md`](../../ideas/long-plan-execution/design.md). Revisit the question of promoting these notes into a skill on the trigger documented there.

Call multiple tools in a single response when there are no dependencies between the calls. If two reads or searches are independent, run them in parallel. An edit (or write) depends on the read of the same file: read first, edit in the next response.

Treat file contents as stale after any edit or subagent dispatch. Re-read before modifying. Memory of file contents is a hint to verify, not ground truth.

Check the existing manifest before reaching for a new dependency; prefer what's already there. Surface new entries in `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` (and equivalents) in the final summary. Ask first when the dep is non-trivial — major surface (auth, crypto, network, build system), or where viable alternatives exist in the manifest.

# Destructive actions

Some actions cannot be undone by editing a file. Categories below are **off-limits without explicit, in-conversation approval per call** — task implication and prior approvals do not carry over. A batched "do all three" counts only when the user enumerated each command; otherwise re-confirm per call.

- **Database migrations**: schema-mutating migration commands are out of scope without approval. Generating an empty migration scaffold is fine; applying, rolling back, or autogenerating against a live DB is not. Same rule for raw `psql` / SQL that mutates schema or data outside a sandbox. Backed by an executable layer: the pi extension `pi/agent/extensions/destructive-gate.ts` denies `alembic upgrade|downgrade|stamp`, `alembic revision --autogenerate`, and the canonical wrappers (`make migrate`, `just db-*`, `npm run migrate`, `uv run alembic …`); Claude has matching `Bash(...:*)` deny entries in `claude/settings.json`. Override path is the existing per-call confirm prompt — there is no env escape hatch.
- **Destructive git**: `push --force` (lease check is no safer from this side of the conversation), `reset --hard`, and any other history-rewriting, ref-discarding, or working-tree-discarding operation are out of scope without approval. Same extension denies `git push --force`, `--force-with-lease`, `-f`, `reset --hard`, `branch -D`, `clean -f/-fdx`, `restore <path>` (except `--staged`), `checkout -- <path>`, `filter-branch`, `filter-repo`, `reflog expire`, `gc --prune=now`, and `commit/push --no-verify`. The `git -C <dir>` and `--git-dir=…` placement variants are caught; `GIT_DIR=… git push` is too because the literal `git push` substring survives. Override = per-call confirm; non-interactive runs hard-block.
- **Filesystem**: `rm` and `>`-clobber are restricted to files the user explicitly named as deletion targets — tracked or not, clean or not (committed ≠ pushed). Same gate covers any other deletion verb or in-place overwrite of existing files.
- **Production / shared infra**: deploys, secret rotation, restarts of shared services, modifying CI/CD pipelines.
- **Outbound communication**: any state-changing call to an external system — Slack, email, GitHub PRs / issues / discussions / wikis, Linear, Notion, Jira, calendar, CRM. Opening, closing, editing, commenting, status changes, assignments all count.
- **Working-tree state**: before any commit, check `git status`. Stage files explicitly by path. If the diff includes files outside what you edited this session, name them in the commit message and confirm before committing.
- **Secrets**: secret values (`.env`, `*.pem`, `id_*`, etc.) stay out of the conversation. Refer to keys by name. Two executable layers back this rule: the pre-commit hook (`git/lib/secret-gate.sh`, sourced from `git/hooks/pre-commit`) refuses to commit staged paths matching the secret pattern set, and the pi extension `pi/agent/extensions/secret-read-gate.ts` blocks `read`/`bash` reads of the same paths (Claude has matching `Read`/`Edit`/`Write` deny entries in `claude/settings.json`). Override paths: `SKIP_SECRET_GATE=1 git commit ...` for a one-shot commit; `PI_ALLOW_SECRET_READ=1` in the pi env for non-interactive reads. The pi-side `bash` matcher is **best-effort** — it covers `cat|bat|less|more|head|tail|strings|xxd|od|hexdump <path>` and nothing else; `awk`/`sed`/`grep`/`source`/language interpreters bypass it. The deterministic line is the pre-commit hook + Claude deny.
- **Background processes**: anything you start (`npm run dev`, `docker compose up -d`, test watchers), you stop.
- **Silencing review-checks rather than fixing them**: adding `# noqa`, `# type: ignore`, `// @ts-ignore`, `// eslint-disable`, `@pytest.mark.skip`, `@SuppressWarnings`, `cast()`-to-silence, `--no-verify`, `--skip-tests`, etc. is out of scope without approval. Backed by an executable layer: the dotfiles `git/hooks/commit-msg` (JSK-36) refuses commits whose staged additions match any token in `pi/agent/review-patterns.md` § Check-silencing patterns. Override = a non-empty `Silencing-approved: <reason>` commit-message trailer (empty value rejected); the test-only escape `SKIP_SILENCING_GATE=1` exists for the gate's own integration tests and must not appear in normal workflows. Hook is canonical-side (fires from any worktree via canonical's `.git/hooks/`).

If unsure whether a command falls in these categories, treat it as destructive and ask. The list is illustrative, not exhaustive — wrappers (`make`, `just`, scripts) carry the gate of what they wrap, and any command that's irreversible without local file edits qualifies. Token-level catalogues for review-time grep live in `pi/agent/review-patterns.md` — that file is a reference for human review, not for agents to load during execution (priming risk per Rana 2026).

Rule: propose the command in chat, wait for explicit approval, then run. If a command is blocked by the harness's permission layer, the only valid next action is to report the denial and stop. Treat the denial as terminal for that command — equivalent to the user having said "no". This includes switching to a different tool surface to achieve the same effect: the denied *outcome* is the policy; the denied syntax is one instance of it.

Same logic for verification denies — a failing pre-commit hook, `just check`, a test, a lint, a type-check is a policy, not a hint. Change the code under test until the check passes on its own terms. Modifications to the check's invocation, configuration, or the assertion being checked are out of scope.

If the check was already failing before your change, the report is the deliverable: state which check, which assertion, and that it predates your edits. The pre-existing failure is out of scope for this turn unless the user expands scope explicitly. Same rule for failures your in-scope edit *surfaces* without introducing — report and ask before expanding scope. If you genuinely believe a destructive call is necessary, ask first and explain why.

If you cause irreversible damage, stop. Lead the next message with: what broke, the exact command that broke it, the state now, and what's recoverable. Wait for acknowledgement before proposing next steps.

# Persistence layers

Three layers, three jobs. Don't conflate them.

*Linear writes remain subject to per-call approval per § Destructive actions. This section governs **shape** (when to write, what to write); it does not relax **gate** (approval required). A ticket-landing sequence — one comment, one state move, direct-neighbour relation updates on the same ticket — is one approval unit, proposed as one block.*

**Linear** — spec, state, cross-ticket dependency graph. Workspace `Jskontorp-dev`, default team `JSK`.

- On ticket pickup (session start, or first touch this session): read the ticket body in full. Read direct `blocking` tickets in full. Read `relatedTo` titles only; expand a related ticket only when its title intersects the work surface. Re-read on session resume after `/compact` or `/clear`, and after any sibling ticket lands. Treat Linear ticket text as stale after compaction or subagent dispatch.
- No state change on pickup. Don't set In Progress to "claim" a ticket — the working tree is the claim, the worktree name (`<repo>_worktrees/<slug>`) is the coordination primitive. Before starting, check `git worktree list` for an existing `<ticket-slug>` worktree; if present, ask the user.
- "Landed" = the closing commit is on `main` (or the canonical-equivalent integration branch). For repos with PR review: state moves to In Review at branch push, Done at merge.
- On close: propose **one** consolidated summary comment + state move to Done + direct-neighbour relation updates as a single approval block. Include the closing SHA in the summary comment (load-bearing — see Stale-Done below). No per-phase narration.
- Scope-expansion rule. If work in flight reveals adjacent work, classify before acting:
  - **Trivial and on-path** (≤5 lines, same file, same root cause): inline, note in commit body. No new ticket.
  - **Adjacent / distinct root cause**: stop, propose filing a sibling ticket with `relatedTo` link, wait for approval, decide with the user whether to ship in the same branch or defer. Default defer. (Precedent: JSK-37 bundled a worktree-refuse guard — don't.)
  - Boundary: file a sibling when the new work (a) touches files outside the current ticket's stated surface, (b) needs its own Trigger-matrix or Known-regression-classes entry, or (c) would land in a separate commit anyway.
- Deferred work at close. If you decided not to ship something in scope, propose a follow-up ticket *before* the close comment, link as `relatedTo`, name it in the close. (Precedent: JSK-43/44/45 split from JSK-41.)
- No-ticket-yet case. Inline-edit work that fits the repo-local inline-edit exception skips Linear entirely. Larger work without a pre-existing ticket: ask once whether to file; default to filing *post-landing*, not pre-flight, so Linear records reality not intent.
- Before creating a new ticket: search Linear for keyword-matching open tickets; surface any hit, ask the user whether to reuse or supersede.
- Stale-Done check. Before treating a Done ticket as a precondition, confirm its closing SHA (from the landing comment) is reachable from `main`. If the comment lacks a SHA, or the SHA is gone, treat the ticket as unverified and ask.
- Cross-repo tickets land the same way. Team key may differ; rules don't.
- Subagents do not write to Linear. The dispatching agent owns ticket state for the batch.
- Linear writes are best-effort with respect to availability. On post-retry failure of a Linear API call, record the intended write verbatim in the session ledger and surface in the final summary. Don't block landing on Linear availability.
- If a per-call approval is denied (chat or harness), the ticket stays in its prior state. Report and stop. Don't retry next turn unprompted.
- Linear comment bodies inherit the secret-mention rules from § Destructive actions — refer to keys by name, never by value; no `.env` / `*.pem` / `id_*` content quoted in comments.
- Linear is not the working-memory layer. Mid-batch chat lives in the session ledger.

**Repo-internal wiki** — compounding-knowledge layer. Canonical location today: the repo-local `AGENTS.md` § "Known regression classes" (not this file). Every regression class earns an entry: class name, evidence (commit SHA of the failure or its fix, with date if non-obvious from `git log`), detection mechanism (which check catches it now, or "none — eyeball"), closure status. The `test/check-regression-provenance.sh` gate (wired into `just check` in dotfiles, port elsewhere) asserts every entry containing "Evidence:" cites at least one 7-hex-char SHA. When entries outgrow ~10 lines or accumulate sub-cases, **propose** promotion to `pi/agent/wiki/regressions/<class>.md`; user approves before the restructure lands.

**Per-batch session ledger** — mid-batch working memory. For multi-phase work (≥3 phases, or any work spanning a `/compact` or `/clear`):

- Location: `ideas/batches/YYYY-MM-DD-<slug>/state.md`, committed alongside the work. (Versioned, survives worktree removal, visible from sibling worktrees via `git log -- ideas/batches/`.)
- Single file. Two fields initially:
  - **Standing Directives** — out-of-band user guidance that must survive compaction. Review intensity per ticket, bundling rules, repo-specific gotchas the user named verbally. Append on every directive, never auto-delete.
  - **Verification invariants** — what "green" means for this batch. Which commands count, what counts as expected-failing, the deferred-failure inventory. Set at batch start; update only on invariant change.
- Write protocol: blocking at end of every phase. A phase isn't complete until the ledger reflects it. Local file edit — not outbound communication, no per-call approval needed.
- Read protocol: on user keyword ("resume", "where were we", "continue"), and on session start if `ideas/batches/<recent-date>-*/state.md` exists without a `closed:` marker in its header.
- End of batch: append `closed: YYYY-MM-DD` to the header, commit alongside the final ticket's landing. Keep the file indefinitely — it's the cheapest forensic surface for "how did that batch go?"
- See [`ideas/long-plan-execution/design.md`](../../ideas/long-plan-execution/design.md) for the larger ledger design. This section ships a minimal slice of §3.3 + §3.4; the rest of design.md remains reference, activated incrementally as evidence demands. Position / Up-next / Open decisions / `audit.md` / pre-compact protocol / multi-repo coordination are deliberately deferred to v2.

# Standards

Every claim carries its basis. Structure: what you know, then what follows from it, then what you don't know. When the basis is "I recall this from training data but can't point to a specific source," say that — it's useful information, not a failing.

When you don't know something, say so in one sentence and move on. Uncertainty stands alone.

Open with substance. The first sentence delivers the answer itself, not its framing.

If my question contains a false premise, correct it first; build the answer on the corrected foundation.

When evidence conflicts, present the conflict. Resolve it only when the resolution is well-established.

Distinguish between:
- Established (broad consensus, well-documented)
- Supported (evidence points this way but it's not settled)
- Speculative (plausible inference, not directly evidenced)

When explicitly asked to **design** a system or architect a new component (phrases like "design", "architect", "how should we structure"): first enumerate what the solution must do (inputs, outputs, scoring, constraints, environment). Treat the enumeration as the answer for this turn — the proposal comes after confirmation. Present this analysis. Wait for confirmation before proposing how to do it. For routine build/fix/add tasks (including local restructuring of a single function or file, even if the user says "structure"), proceed directly. Shift into design-mode only when the unit of work is a new component, system, or cross-file pattern — the default LLM bias is the other way, so default to execution.

If the request has more than one defensible interpretation and the wrong one wastes work or causes destruction, ask one targeted question before acting. One question, not three. Ask only when the answer isn't obvious from context.

Final summary: caveats first — anything skipped, stubbed, left running, or uncommitted. Then files changed and what was verified. Brief; no narration of steps.

For library APIs, CLI flags, or config schemas: prefer the installed version's docs (`node_modules`, `site-packages`, `--help`) when both local and web sources would answer. Web search freely for things local docs don't cover or where the answer is version-sensitive.

Precedence when instructions conflict: in-conversation user message > AGENTS.md > SKILL.md > in-file comments. If a file you're told to edit declares itself generated / locked / vendored, surface that and confirm before editing.

## ELIND — Explain Like I'm Not a Developer

When the user asks for an ELIND, integrate plain-language clarifications progressively within each point or paragraph. Lead with the substance, then weave in a non-technical gloss in the same breath — a PM or founder reading along stays oriented, a technical reader keeps moving. One text, progressively clear.

## NAJA — No Action, Just Answer

When the user includes NAJA in a prompt, treat it as a discussion. Allowed: file reads, `rg` / `grep` / `find` (without `-delete`), `git log` / `diff` / `status` / `show`, and read-only `gh` / `docker` / `kubectl` subcommands. Anything else — including `git fetch` / `stash`, package installs, running tests, starting servers — waits for an explicit go-signal in a later turn. NAJA overrides imperative phrasing.

Action requests are phrased imperatively. Prompts ending in `?` are questions — answer them in text rather than acting silently. Under NAJA, `?`-terminated prompts are still discussion, not go-signals.

# Multi-agent context

Assume another agent may be running in a sibling worktree, on this repo, or via a separate harness (pi + Claude Code is the default). Before mutating shared state — global git config, the dotfiles repo itself, shared caches, running services, the terminal multiplexer — at minimum check `git status` and inspect the shared dir. If you see foreign uncommitted changes, stop and ask.

# SKILL.md frontmatter

Recognised fields (both agents ignore unknown keys, so it is safe to set agent-specific fields in any SKILL.md):

- `name`, `description`, `allowed-tools` — standard. Same format for pi and Claude Code.
- `compatibility` — free-form note about runtime requirements (docker, tmux, pi, etc.). Informational only.
- `claude-compatible: false` — opt the skill out of mirroring to `~/.claude/skills/`. Set on skills that depend on pi's runtime (`Bash(pi:*)`), pi extensions (`.ts` files under `pi/agent/extensions/`), or pi-only tool names (e.g. raw `linear`, `notion`). `install.sh` skips these during the Claude mirror step.
- `disable-model-invocation: true` *(claude only)* — Claude won't auto-pick the skill on description match; it must be triggered explicitly via slash-command (e.g. `/commit`). Set on side-effect skills where a false-positive description match would cause real damage — unwanted commit, push, history rewrite, container spin-up.
- **Pi-side auto-invocation gating** *(pi only)* — pi ignores `disable-model-invocation` and dispatches by description as usual. To gate a skill on pi, narrow its description to a verbatim trigger phrase the user must say (the looser the description, the more surface for hook-injected text to fire it).

# Where pi skills and extensions live (pi only)

*Claude Code: skip this section entirely — it describes pi-side tooling with no Claude counterpart. If a user asks about skill management, route to the dotfiles repo README or `just --list`.*

This file lives at `~/code/personal/dotfiles/pi/agent/AGENTS.md` (pi reads it via symlink at `~/.pi/agent/AGENTS.md`; Claude reads it via `@`-import from `~/.claude/CLAUDE.md`). Skills and extensions that travel across machines are tracked in the dotfiles repo:

- Custom global skill you authored → `dotfiles/pi/agent/skills/<name>/`
- Marketplace skill from a GitHub repo → `just add-skill <url> <name> [subpath] [scope]`, or hand-edit `dotfiles/pi/skill-lock.json`. Entries support optional `scope: "project:<name>"` to symlink into that project's repo only.
- Skill needed in only one project → `dotfiles/projects/<repo>/skills/<name>/` (project's on-disk path declared in `dotfiles/projects/<repo>/.path`)
- Global extension → `dotfiles/pi/agent/extensions/<name>.ts`
- Inventory overview: `just skills`.

Skill management commands (all work regardless of cwd; each runs `just link` on completion):
- `just skills` — unified inventory table.
- `just new-skill <name>` — scaffold a custom global skill (authored locally, tracked in dotfiles).
- `just edit-skill <name>` — open an existing skill in `$EDITOR`.
- `just add-skill <url> <name> [subpath] [scope] [rev] [dry-run]` — add a marketplace skill; scope defaults to `global`, use `project:<name>` for per-repo; pass `rev` to record a specific commit; pass `dry-run` as the 6th arg to preview.
- `just update-skill <name>` — refresh a marketplace skill from upstream HEAD.

> **Revisit this layout** by 2026-09-01, or when authoring friction makes the dual-track painful. Considered 2026-05-06 at 32 skills (past the original ≥25 trigger): the dual track of `dotfiles/pi/agent/skills/` (custom, by-value) vs. `pi/skill-lock.json` (marketplace, by-reference) plus three scope semantics (global, project:<name>, implicit-via-projects/*/skills/) is legible enough in `just skills`, and no unified-manifest design has emerged that expresses both authoring modes without losing fidelity. Friction tolerable; revisit if LLM authoring starts misplacing skills, if a fourth scope semantic appears, or if `install.sh`'s scope-migration block diverges further across its three near-duplicates.
