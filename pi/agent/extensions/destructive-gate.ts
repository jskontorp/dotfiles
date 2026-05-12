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
// the two in sync — they are the cross-agent enforcement parity layer.
//
// What this does NOT cover: outbound communication (Slack/email/PRs), prod
// deploys, secret rotation, db migrations. Those route through their own
// tools (linear-routing.ts, notion-routing.ts) or live outside the bash
// surface; gating them here would create false positives on routine reads.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

type Pattern = {
	id: string;
	// Regex applied to the full command string. Use word boundaries (\b) and
	// anchor-as-needed; do not anchor to start-of-string because commands are
	// often prefixed (e.g. `cd foo && git push --force ...`).
	re: RegExp;
};

const PATTERNS: Pattern[] = [
	// --- Destructive git ---
	// Force-push in any shape: --force, -f (with surrounding word boundary so
	// `-ff` or random `-f` inside other tokens doesn't match), --force-with-lease.
	{ id: "git push --force", re: /\bgit\s+push\s+(?:[^&|;]*\s)?--force(?![-\w])/ },
	{ id: "git push -f", re: /\bgit\s+push\s+(?:[^&|;]*\s)?-f(?!\w)/ },
	{ id: "git push --force-with-lease", re: /\bgit\s+push\s+(?:[^&|;]*\s)?--force-with-lease/ },
	// History rewrites and irreversible local ops.
	{ id: "git reset --hard", re: /\bgit\s+reset\s+(?:[^&|;]*\s)?--hard\b/ },
	{ id: "git branch -D", re: /\bgit\s+branch\s+(?:[^&|;]*\s)?-D\b/ },
	{ id: "git clean -f", re: /\bgit\s+clean\s+(?:[^&|;]*\s)?-[a-eg-zA-Z]*f/ },
	{ id: "git filter-branch", re: /\bgit\s+filter-branch\b/ },
	{ id: "git reflog expire", re: /\bgit\s+reflog\s+expire\b/ },
	{ id: "git gc --prune=now", re: /\bgit\s+gc\s+(?:[^&|;]*\s)?--prune=now\b/ },
	// Verification bypass.
	{ id: "git commit --no-verify", re: /\bgit\s+commit\s+(?:[^&|;]*\s)?--no-verify\b/ },
	{ id: "git push --no-verify", re: /\bgit\s+push\s+(?:[^&|;]*\s)?--no-verify\b/ },
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
