// Linear routing + confirm gate for @fink-andreas/pi-linear-tools.
//
// Responsibilities:
//   1. Resolve which Linear workspace to use from ctx.cwd (Volve vs. personal,
//      with an explicit prompt when cwd is ambiguous).
//   2. Fetch the API key for that workspace from the macOS Keychain.
//   3. Set process.env.LINEAR_API_KEY before each linear_* tool runs.
//      (Verified in pi-linear-tools 0.5.1 — getLinearAuth() at
//       extensions/pi-linear-tools.js:83–107 reads process.env.LINEAR_API_KEY
//       on every call and short-circuits above the settings-file cache.)
//
// Known limitation: process.env is process-global. Pi preflights tool_call
// handlers sequentially but may execute sibling tools concurrently. If the
// LLM emits two linear_* calls in one assistant message that resolve to
// different workspaces, they would race on LINEAR_API_KEY. Writes are safe
// because the confirm gate serialises them; parallel *read* tool calls
// resolving to different workspaces in one turn would be misrouted. Not
// defended against — cwd is the only routing signal and doesn't change
// within a turn, so cross-workspace reads in one turn are not expected.
//   4. For write actions, show a markdown preview and block until the user
//      picks "go" / "revise" / "cancel". On "revise", the tool call is blocked
//      with user feedback so the LLM redrafts and re-calls (re-gated).
//
// Keychain setup (one-time, per workspace):
//   security add-generic-password -a "$USER"                -s linear-personal -w
//   security add-generic-password -a "jorgen@volvetech.com" -s linear-volve    -w

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execFileSync } from "node:child_process";

const LINEAR_TOOLS = new Set([
	"linear_issue",
	"linear_project",
	"linear_project_update",
	"linear_milestone",
	"linear_team",
]);

// `start` is intentionally excluded: it just creates a branch and sets state to
// "In Progress" — low-stakes, no teammate-visible content, not worth a prompt.
const WRITE_ACTIONS = new Set([
	"create",
	"update",
	"delete",
	"archive",
	"unarchive",
	"comment",
]);

type WorkspaceId = "personal" | "volve";

type Workspace = {
	id: WorkspaceId;
	label: string;
	service: string;
	account: string;
};

const WORKSPACES: Record<WorkspaceId, Workspace> = {
	personal: {
		id: "personal",
		label: "Personal",
		service: "linear-personal",
		account: process.env.USER || "",
	},
	volve: {
		id: "volve",
		label: "Volve",
		service: "linear-volve",
		account: "jorgen@volvetech.com",
	},
};

// Path-segment match: only matches "volve" as its own segment (optionally
// suffixed/prefixed with - or _), so "evolve", "revolver", etc. do not trigger.
const VOLVE_SEGMENT = /(^|[/_-])volve([/_-]|$)/i;
// Any cwd under ~/code/personal/ is unambiguously personal.
const PERSONAL_ROOT = /\/code\/personal(\/|$)/i;

function inferWorkspace(cwd: string): WorkspaceId | null {
	// Check PERSONAL_ROOT first so a personal tree containing "volve" in a
	// subdirectory (e.g. ~/code/personal/volve-notes) does not misroute.
	if (PERSONAL_ROOT.test(cwd)) return "personal";
	if (VOLVE_SEGMENT.test(cwd)) return "volve";
	return null;
}

// Remember the user's per-cwd workspace choice for the session so we don't
// prompt on every tool call from an ambiguous cwd.
const cwdChoiceCache = new Map<string, WorkspaceId>();

type ResolveResult =
	| { workspace: Workspace }
	| { workspace: null; reason: string };

async function resolveWorkspace(
	cwd: string,
	ctx: { hasUI: boolean; ui: { select: (title: string, items: string[]) => Promise<string | undefined> } },
): Promise<ResolveResult> {
	const inferred = inferWorkspace(cwd);
	if (inferred) return { workspace: WORKSPACES[inferred] };

	const remembered = cwdChoiceCache.get(cwd);
	if (remembered) return { workspace: WORKSPACES[remembered] };

	if (!ctx.hasUI) {
			return {
				workspace: null,
				reason:
					`Ambiguous cwd for Linear workspace routing (${cwd}) and no UI available to disambiguate. ` +
					`Run from a path matching /volve/ or /code/personal/, or set LINEAR_API_KEY manually.`,
			};
		}

	const labelToId: Record<string, WorkspaceId> = {
		[WORKSPACES.personal.label]: "personal",
		[WORKSPACES.volve.label]: "volve",
	};
	const choice = await ctx.ui.select(
		`Linear workspace is ambiguous for this cwd:\n  ${cwd}\n\nWhich workspace should I use?`,
		[WORKSPACES.personal.label, WORKSPACES.volve.label],
	);
	const id = choice ? labelToId[choice] : undefined;
	if (id) {
		cwdChoiceCache.set(cwd, id);
		return { workspace: WORKSPACES[id] };
	}
	return { workspace: null, reason: "User cancelled workspace selection." };
}

// Cache keys per session to avoid hitting Keychain on every tool call.
const keyCache = new Map<string, string>();

function fetchKey(ws: Workspace): string {
	const cacheKey = `${ws.service}:${ws.account}`;
	const cached = keyCache.get(cacheKey);
	if (cached) return cached;
	const key = execFileSync(
		"security",
		["find-generic-password", "-s", ws.service, "-a", ws.account, "-w"],
		{ encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
	).trim();
	if (!key) throw new Error("empty key returned from Keychain");
	keyCache.set(cacheKey, key);
	return key;
}

function renderPreview(
	ws: Workspace,
	toolName: string,
	input: Record<string, unknown>,
): string {
	const action = String(input.action ?? "?");
	const lines: string[] = [];
	lines.push(`**Workspace:** ${ws.label}   **Tool:** \`${toolName}\`   **Action:** \`${action}\``);
	lines.push("");
	for (const [k, v] of Object.entries(input)) {
		if (k === "action") continue;
		if (v === undefined || v === null) continue;
		if (typeof v === "string") {
			if (v === "") continue; // skip empty strings on create-style actions
			if (v.includes("\n") || v.length > 80) {
				lines.push(`**${k}:**`);
				lines.push("");
				lines.push(v);
				lines.push("");
			} else {
				lines.push(`**${k}:** ${v}`);
			}
		} else {
			// Non-string values (arrays, objects, numbers, booleans) — render as JSON
			// in a fenced code block so markdown doesn't mangle them.
			lines.push(`**${k}:**`);
			lines.push("");
			lines.push("```json");
			lines.push(JSON.stringify(v, null, 2));
			lines.push("```");
			lines.push("");
		}
	}
	return lines.join("\n");
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (!LINEAR_TOOLS.has(event.toolName)) return;

		const input = (event.input ?? {}) as Record<string, unknown>;
		const resolved = await resolveWorkspace(ctx.cwd, ctx);
		if (!resolved.workspace) {
			return { block: true, reason: resolved.reason };
		}
		const ws = resolved.workspace;
		ctx.ui.notify(`Linear: routed to ${ws.label} workspace`, "info");

		// 1. Route the API key by cwd. Clear the env var first so a stale value
		//    from a prior workspace doesn't leak into the block-return path.
		delete process.env.LINEAR_API_KEY;
		try {
			process.env.LINEAR_API_KEY = fetchKey(ws);
		} catch (err) {
			return {
				block: true,
				reason:
					`Could not fetch Linear API key for ${ws.label} workspace from Keychain ` +
					`(service=${ws.service}, account=${ws.account}): ${(err as Error).message}. ` +
					`Run: security add-generic-password -a "${ws.account}" -s ${ws.service} -w`,
			};
		}

		// 2. Gate write actions with preview + confirm.
		const action = String(input.action ?? "");
		if (!WRITE_ACTIONS.has(action)) return;

		if (!ctx.hasUI) {
			return {
				block: true,
				reason:
					`Linear ${action} on ${event.toolName} requires interactive confirmation, ` +
					`but pi is running without a UI (print/RPC mode). Re-run in interactive mode to confirm.`,
			};
		}

		const preview = renderPreview(ws, event.toolName, input);
		const choice = await ctx.ui.select(
			`Linear ${action} — review before executing\n\n${preview}`,
			[action, "revise", "cancel"],
		);

		if (choice === action) return; // allow
		if (choice === "cancel" || choice === undefined) {
			return { block: true, reason: `User cancelled the Linear ${action}.` };
		}

		// revise
		const feedback = await ctx.ui.input(
			"What should change?",
			"e.g. 'shorter title, move details to description, lower priority'",
		);
		if (!feedback) {
			return {
				block: true,
				reason:
					`User requested changes to the ${action} but did not provide feedback. ` +
					`Ask them what to change before retrying.`,
			};
		}
		return {
			block: true,
			reason:
				`User requested changes before the ${action}: ${feedback}\n\n` +
				`Redraft the inputs and call the tool again — it will be re-gated for confirmation.`,
		};
	});
}
