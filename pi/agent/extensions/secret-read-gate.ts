// Secret-read gate for pi (JSK-35).
//
// Mirrors the path patterns in git/lib/secret-gate.sh and the Read/Edit/Write
// deny entries in claude/settings.json. The three surfaces enforce the same
// "Secrets" bullet from pi/agent/AGENTS.md; keep them in sync when changing
// patterns.
//
// Behaviour:
//   - Intercept tool_call for the built-in `read` tool: regex-match `path`
//     against the secret pattern set; on match prompt the user (default No)
//     and block on No / non-interactive.
//   - Intercept tool_call for `bash`: best-effort match commands of the form
//     `<reader> <secret-path>` where <reader> is one of cat|bat|less|more|
//     head|tail|strings|xxd|od|hexdump. THIS IS LEAKY by design — `awk`,
//     `sed`, `grep`, `source`, `python -c`, heredocs, variable expansion,
//     and any language interpreter all bypass it. The deterministic line of
//     defence is the pre-commit hook (Layer A) plus the Claude deny block;
//     this extension is the in-session second line.
//
// Override:
//   - Interactive: pick "Yes" at the prompt.
//   - Non-interactive (subagents, `pi -p`): set PI_ALLOW_SECRET_READ=1 in the
//     environment for the pi invocation. Without it, a non-interactive read
//     of a secret path hard-blocks.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Patterns mirror SECRET_GATE_PATTERNS in git/lib/secret-gate.sh. Each entry
// is { id, re } where `id` shows up in the prompt and `re` matches the path.
type Pattern = { id: string; re: RegExp };

const SECRET_PATTERNS: Pattern[] = [
	{ id: ".env*", re: /(^|\/)\.env(\.[^/]+)?$/ },
	{ id: ".envrc", re: /(^|\/)\.envrc$/ },
	{ id: "private key file", re: /\.(pem|key|ppk|p12|pfx|jks|keystore)$/ },
	{ id: "ssh private key", re: /(^|\/)(id_rsa|id_dsa|id_ecdsa|id_ed25519)$/ },
	{
		id: "tool credential file",
		re: /(^|\/)(\.pgpass|\.netrc|\.htpasswd|\.npmrc|\.pypirc|\.terraformrc)$/,
	},
	{ id: "aws credentials", re: /(^|\/)\.aws\/credentials$/ },
	{ id: "kubeconfig", re: /((^|\/)\.kube\/config$|(^|\/)kubeconfig$)/ },
	{
		id: "secret bundle",
		re: /(^|\/)(secrets|credentials|service-account[^/]*|service_account[^/]*)\.(ya?ml|json)$/,
	},
	{ id: "tfvars", re: /\.tfvars(\.json)?$/ },
];

// Exempt suffixes (`.env.example`, `secrets.template.json`, etc.) — these
// are conventionally checked-in samples, not real secrets.
const EXEMPT_SUFFIX_RE = /\.(example|sample|template|dist)$/;

function matchSecretPath(path: string): Pattern | null {
	if (!path) return null;
	if (EXEMPT_SUFFIX_RE.test(path)) return null;
	for (const p of SECRET_PATTERNS) {
		if (p.re.test(path)) return p;
	}
	return null;
}

// Best-effort bash matcher: looks for `<reader> [flags...] <path>` where
// <reader> is a known content-dumping command and <path> matches a secret
// pattern. Quoted paths are unquoted before matching.
const READER_RE = /\b(cat|bat|batcat|less|more|head|tail|strings|xxd|od|hexdump)\b/;

function matchSecretInBash(command: string): Pattern | null {
	if (!READER_RE.test(command)) return null;
	// Tokenise on whitespace; strip surrounding quotes; ignore flag tokens
	// (start with `-`). This is intentionally simple — see file header.
	const tokens = command
		.split(/\s+/)
		.map((t) => t.replace(/^['"]|['"]$/g, ""))
		.filter((t) => t.length > 0 && !t.startsWith("-"));
	for (const tok of tokens) {
		const hit = matchSecretPath(tok);
		if (hit) return hit;
	}
	return null;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event: any, ctx: any) => {
		let matched: Pattern | null = null;
		let subject = "";

		if (event.toolName === "read") {
			const path = String(event.input?.path ?? "");
			matched = matchSecretPath(path);
			subject = path;
		} else if (event.toolName === "bash") {
			const command = String(event.input?.command ?? "");
			if (!command) return;
			matched = matchSecretInBash(command);
			subject = command;
		} else {
			return;
		}

		if (!matched) return;

		// Non-interactive escape hatch for subagent flows that legitimately
		// need to read a secret path (rare). Without this, `pi -p` hard-blocks.
		if (process.env.PI_ALLOW_SECRET_READ === "1") return;

		if (!ctx.hasUI) {
			return {
				block: true,
				reason:
					`Secret-path read blocked (no UI for confirmation): ${matched.id}\n\n` +
					`Target: ${subject}\n\n` +
					`If this read is genuinely required, re-run pi with PI_ALLOW_SECRET_READ=1 ` +
					`in the environment, or run pi interactively and approve at the prompt.`,
			};
		}

		const choice = await ctx.ui.select(
			`🔐  Secret-path read (${matched.id})\n\n  ${subject}\n\nAllow this read?`,
			["No", "Yes"],
		);

		if (choice !== "Yes") {
			return {
				block: true,
				reason:
					`User blocked secret-path read: ${matched.id}\n\n` +
					`Target: ${subject}\n\n` +
					`Stop and ask the user how to proceed. Refer to the secret by name, ` +
					`not by value.`,
			};
		}
		return; // allow
	});
}
