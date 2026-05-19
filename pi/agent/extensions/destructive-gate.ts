// Destructive-action gate for pi.
//
// Mirrors the deny-list semantics of claude/settings.json (the "deny" array
// under the local Claude permissions block) so pi has parity with Claude on
// dangerous bash invocations. Without this, pi's only gate for destructive
// shell calls is the prose in pi/agent/AGENTS.md "# Destructive actions",
// which has been violated in practice (force-push to a feature branch
// without execution-time confirmation).
//
// Behaviour: intercept `tool_call` for the `bash` tool, regex-match against
// the destructive pattern list, and on match prompt the user with the
// verbatim command. Default selection is "No" so a stray Enter blocks. In
// non-interactive mode (no UI), hard-block.
//
// Pattern list follows the destructive-actions categories in
// pi/agent/AGENTS.md and the Claude deny-list in claude/settings.json. Keep
// the two in sync — they are the cross-agent enforcement parity layer. The
// canonical token catalogue lives in pi/agent/review-patterns.md.
//
// What this does NOT cover: outbound communication (Slack/email/PRs), prod
// deploys, secret rotation. Those route through their own tools
// (linear-routing.ts, notion-routing.ts) or live outside the bash surface;
// gating them here would create false positives on routine reads.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Pattern = {
	id: string;
	// Regex applied to the full command string. Use word boundaries (\b) and
	// anchor-as-needed; do not anchor to start-of-string because commands are
	// often prefixed (e.g. `cd foo && git push --force ...`).
	re: RegExp;
};

// `git` itself accepts cwd/dir overrides between the binary name and the
// verb: `git -C <dir>`, `git --git-dir=<path>`, `git -c key=val`. A naive
// `\bgit\s+<verb>\b` lets `git -C foo push --force` slip past. GIT_*=val env
// prefixes (`GIT_DIR=… git push`) still expose the literal `git push`
// substring, so they're caught by the same shape.
//
// This fragment matches zero-or-more of those leading flags between `git`
// and the verb. Keep it permissive — false-positive cost is a confirm
// prompt; false-negative cost is a destructive op.
const GIT_OPTS = "(?:\\s+(?:-C\\s+\\S+|--git-dir(?:=|\\s+)\\S+|--work-tree(?:=|\\s+)\\S+|-c\\s+\\S+))*";

function gitVerb(verb: string, tail = ""): RegExp {
	return new RegExp(`\\bgit${GIT_OPTS}\\s+${verb}\\b${tail}`);
}

const PATTERNS: Pattern[] = [
	// --- Destructive git: force-push in any shape ---
	// --force, -f (with surrounding word boundary so `-ff` or random `-f`
	// inside other tokens doesn't match), --force-with-lease (the deceptive
	// case — looks safer, isn't, since the lease check protects only
	// against remote-side races, not against the agent acting on stale
	// local state).
	{ id: "git push --force", re: gitVerb("push", "(?:[^&|;]*\\s)?--force(?![-\\w])") },
	{ id: "git push -f", re: gitVerb("push", "(?:[^&|;]*\\s)?-f(?!\\w)") },
	{ id: "git push --force-with-lease", re: gitVerb("push", "(?:[^&|;]*\\s)?--force-with-lease") },
	// History rewrites and irreversible local ops.
	{ id: "git reset --hard", re: gitVerb("reset", "(?:[^&|;]*\\s)?--hard") },
	{ id: "git branch -D", re: gitVerb("branch", "(?:[^&|;]*\\s)?-D") },
	{ id: "git clean -f", re: gitVerb("clean", "(?:[^&|;]*\\s)?-[a-eg-zA-Z]*f") },
	{ id: "git filter-branch", re: gitVerb("filter-branch") },
	{ id: "git filter-repo", re: gitVerb("filter-repo") },
	{ id: "git reflog expire", re: gitVerb("reflog\\s+expire") },
	{ id: "git gc --prune=now", re: gitVerb("gc", "(?:[^&|;]*\\s)?--prune=now") },
	// Working-tree-discarding restore/checkout. Path-discard detection from
	// regex alone is leaky; we deny the obvious shapes and rely on the
	// per-call override for the rare legitimate use:
	//   - `git restore <path>` (any non-flag arg) — discards uncommitted.
	//     EXEMPTED: `git restore --staged …` (only un-stages, non-destructive).
	//   - `git checkout -- <path>` and `git checkout .` — same shape, older syntax.
	//     Branch-switch (`git checkout main`) is NOT caught (no `--` / `.`).
	{
		id: "git restore (discards uncommitted)",
		// drift-test sees this id; keep aligned with test/check-destructive-gate.sh
		// Edge case: `git restore --staged --worktree <path>` DOES discard the
		// worktree, but the `--staged` token trips the negative lookahead and
		// the combo slips. Per-call confirm prompt is the safety net for that
		// rare shape; we accept the leak to keep `--staged`-only legitimate.
		// Match `git restore` with at least one non-flag arg, but not when
		// any of the args is `--staged` (which only un-stages).
		re: gitVerb("restore", "(?=(?:[^&|;]*\\s)?\\S)(?!(?:[^&|;]*\\s)?--staged\\b)"),
	},
	{
		id: "git checkout -- <path>",
		re: gitVerb("checkout", "(?:[^&|;]*\\s)?--\\s+\\S"),
	},
	{
		id: "git checkout .",
		// `\.(?:\s|/|$)` catches both `git checkout .` and `git checkout ./foo`
		// (the latter is also a path-discard shape; the bare-`.` regex used to
		// slip it). Branch names conventionally don't lead with `./`.
		re: gitVerb("checkout", "(?:[^&|;]*\\s)?\\.(?:\\s|/|$)"),
	},
	// Verification bypass.
	{ id: "git commit --no-verify", re: gitVerb("commit", "(?:[^&|;]*\\s)?--no-verify") },
	{ id: "git push --no-verify", re: gitVerb("push", "(?:[^&|;]*\\s)?--no-verify") },
	// --- Database migrations ---
	// Schema-mutating alembic verbs and their common wrappers. The pi-side
	// regex catches substring shapes (`uv run alembic upgrade …`,
	// `poetry run alembic upgrade …`) for free; Claude's prefix-match
	// format can only enumerate, so see claude/settings.json for the
	// per-runner entries we explicitly added.
	//
	// `alembic revision --autogenerate` is the destructive shape (it
	// introspects the live DB); manual `alembic revision -m "msg"` is
	// non-destructive. We deny only the autogenerate shape here; Claude
	// over-blocks all `alembic revision` because its format can't express
	// the flag-conditional.
	{ id: "alembic upgrade", re: /\balembic\s+upgrade\b/ },
	{ id: "alembic downgrade", re: /\balembic\s+downgrade\b/ },
	{ id: "alembic stamp", re: /\balembic\s+stamp\b/ },
	{
		id: "alembic revision --autogenerate",
		re: /\balembic\s+revision\b[^&|;]*--autogenerate/,
	},
	// Wrapper-aware: `make migrate`, `just db-*`, `npm run migrate`. These
	// are the canonical wrappers from review-patterns.md. `just db-*`
	// over-blocks read-only recipes (`just db-shell`, `just db-status`) —
	// accept the friction; the per-call override is the escape.
	{ id: "make migrate", re: /\bmake\s+migrate\b/ },
	{ id: "just db-* (migration wrapper)", re: /\bjust\s+db-\S+/ },
	{ id: "npm run migrate", re: /\bnpm\s+run\s+migrate\b/ },
	// --- Filesystem ---
	// Match `rm -rf` (and -fr, -Rf, -rfv, etc.) targeting roots. The target
	// expressions are anchored after a whitespace so `foo/~` etc. don't match.
	// Order matters: capture broad shapes first.
	{ id: "rm -rf $HOME", re: /\brm\s+-[rRfvi]*[rR][rRfvi]*f[rRfvi]*\s+\$HOME(?:\b|\/)/ },
	{ id: "rm -rf $HOME (-f then -r)", re: /\brm\s+-[rRfvi]*f[rRfvi]*[rR][rRfvi]*\s+\$HOME(?:\b|\/)/ },
	{ id: "rm -rf ~", re: /\brm\s+-[rRfvi]+\s+~(?:\/|\s|$)/ },
	{ id: "rm -rf /", re: /\brm\s+-[rRfvi]+\s+\/(?:\s|$)/ },
];

function matchPattern(command: string): Pattern | null {
	for (const p of PATTERNS) {
		if (p.re.test(command)) return p;
	}
	return null;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event: any, ctx: any) => {
		if (event.toolName !== "bash") return;

		const command = String(event.input?.command ?? "");
		if (!command) return;

		const matched = matchPattern(command);
		if (!matched) return;

		// Non-interactive mode: hard-block. There's no way to ask the user, and
		// silently allowing destructive commands defeats the gate. The agent
		// should surface the block reason and stop.
		if (!ctx.hasUI) {
			return {
				block: true,
				reason:
					`Destructive command blocked (no UI for confirmation): ${matched.id}\n\n` +
					`Command: ${command}\n\n` +
					`Re-run pi interactively, or have the user execute this command directly.`,
			};
		}

		// Interactive: prompt with the verbatim command. "No" is first so the
		// default focus blocks; the user must deliberately pick "Yes" to allow.
		const choice = await ctx.ui.select(
			`⚠️  Destructive command (${matched.id})\n\n  ${command}\n\nAllow this command to run?`,
			["No", "Yes"],
		);

		if (choice !== "Yes") {
			return {
				block: true,
				reason:
					`User blocked destructive command: ${matched.id}\n\n` +
					`Command: ${command}\n\n` +
					`Stop and ask the user how to proceed. Do not retry with a workaround.`,
			};
		}
		return; // allow
	});
}
