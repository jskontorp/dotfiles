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
//      picks the action label (e.g. `create`) / `revise` / `cancel`. On `revise`,
//      the tool call is blocked with user feedback so the LLM redrafts and
//      re-calls (re-gated).
//
// Keychain setup on macOS (one-time, per workspace):
//   security add-generic-password -a "$USER"                -s linear-personal -w
//   security add-generic-password -a "jorgen@volvetech.com" -s linear-volve    -w
//
// On Linux, the Keychain path is unavailable, so keys live in a mode-600 file
// at ~/.config/linear/keys.env with entries:
//   LINEAR_PERSONAL_API_KEY=lin_api_xxx
//   LINEAR_VOLVE_API_KEY=lin_api_yyy

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LINEAR_TOOLS = new Set([
	"linear_issue",
	"linear_project",
	"linear_project_update",
	"linear_milestone",
	"linear_team",
]);

// `start` is intentionally excluded: low-stakes branch/state flip, no
// teammate-visible content. `comment` is also excluded: short and frequent,
// the gate would be more friction than value.
const WRITE_ACTIONS = new Set([
	"create",
	"update",
	"delete",
	"archive",
	"unarchive",
]);

type WorkspaceId = "personal" | "volve";

type Workspace = {
	id: WorkspaceId;
	label: string;
	service: string;
	account: string;
	envVar: string;
};

const WORKSPACES: Record<WorkspaceId, Workspace> = {
	personal: {
		id: "personal",
		label: "Personal",
		service: "linear-personal",
		account: process.env.USER || "",
		envVar: "LINEAR_PERSONAL_API_KEY",
	},
	volve: {
		id: "volve",
		label: "Volve",
		service: "linear-volve",
		account: "jorgen@volvetech.com",
		envVar: "LINEAR_VOLVE_API_KEY",
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

// Cache keys per session to avoid re-fetching on every tool call.
const keyCache = new Map<string, string>();

const LINUX_KEYS_PATH = join(homedir(), ".config/linear/keys.env");

function fetchKeyFromKeychain(ws: Workspace): string {
	return execFileSync(
		"security",
		["find-generic-password", "-s", ws.service, "-a", ws.account, "-w"],
		{ encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
	).trim();
}

function stripMatchedQuotes(v: string): string {
	if (v.length >= 2) {
		const first = v[0];
		const last = v[v.length - 1];
		if ((first === '"' || first === "'") && first === last) {
			return v.slice(1, -1);
		}
	}
	return v;
}

function fetchKeyFromEnvFile(ws: Workspace): string {
	let contents: string;
	try {
		contents = readFileSync(LINUX_KEYS_PATH, "utf8");
	} catch (err) {
		throw new Error(
			`keys file not found at ${LINUX_KEYS_PATH} (${(err as Error).message}). ` +
				`Create it with mode 600 and entries LINEAR_PERSONAL_API_KEY and LINEAR_VOLVE_API_KEY.`,
		);
	}
	// Last-wins semantics, matching dotenv / shell `source`: a user rotating a
	// key by appending a new line at the bottom of the file takes effect.
	let found: string | undefined;
	for (const rawLine of contents.split("\n")) {
		const line = rawLine.trim();
		if (!line || line.startsWith("#")) continue;
		const eq = line.indexOf("=");
		if (eq < 0) continue;
		const k = line.slice(0, eq).trim();
		if (k !== ws.envVar) continue;
		found = stripMatchedQuotes(line.slice(eq + 1).trim());
	}
	if (found === undefined) {
		throw new Error(`${ws.envVar} not set in ${LINUX_KEYS_PATH}.`);
	}
	if (!found) {
		throw new Error(`${ws.envVar} is empty in ${LINUX_KEYS_PATH}.`);
	}
	return found;
}

function fetchKey(ws: Workspace): string {
	const cacheKey = ws.id;
	const cached = keyCache.get(cacheKey);
	if (cached) return cached;
	const key =
		process.platform === "darwin" ? fetchKeyFromKeychain(ws) : fetchKeyFromEnvFile(ws);
	if (!key) throw new Error(`empty key returned for workspace ${ws.id}`);
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
			if (v === "") {
				// On create, a blank field is "not set" — omit. On update/delete/etc.,
				// a blank field is an intentional clear — surface it.
				if (action === "create") continue;
				lines.push(`**${k}:** *(empty)*`);
				continue;
			}
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

		// Gate write actions with preview + confirm *before* touching the env.
		// This prevents a stale LINEAR_API_KEY lingering in process.env after a
		// cancel/revise, where a later non-Linear tool call might inherit it.
		const action = String(input.action ?? "");
		if (WRITE_ACTIONS.has(action)) {
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

			if (choice === "cancel" || choice === undefined) {
				return { block: true, reason: `User cancelled the Linear ${action}.` };
			}
			if (choice !== action) {
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
			}
			// choice === action — fall through to key fetch + allow.
		}

		// Route the API key. Clear first so a stale value from a prior workspace
		// doesn't leak into the block-return path on fetch failure.
		delete process.env.LINEAR_API_KEY;
		try {
			process.env.LINEAR_API_KEY = fetchKey(ws);
		} catch (err) {
			const hint =
				process.platform === "darwin"
					? `Run: security add-generic-password -a "${ws.account}" -s ${ws.service} -w`
					: `Edit ${LINUX_KEYS_PATH} and ensure ${ws.envVar} is set.`;
			return {
				block: true,
				reason:
					`Could not fetch Linear API key for ${ws.label} workspace: ${(err as Error).message} ` +
					hint,
			};
		}
		return; // allow
	});
}

