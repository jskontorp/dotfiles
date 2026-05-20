// Per-workspace auth + cwd→workspace routing, shared between linear.ts and
// notion.ts.
//
// Two workspaces — `personal` and `volve`. Each owns its own credential per
// service ("service" = "linear" | "notion"), stored in:
//   - Mac:     macOS Keychain entries `<service>-<workspace>`
//   - Linux:   `~/.config/<service>/keys.env` (mode 600), one var per workspace
//
// Routing precedence (matches the previous linear-routing.ts behaviour):
//   1. cwd under `/code/personal/` → personal (wins first so personal trees
//      containing the substring "volve" don't misroute)
//   2. cwd contains a "volve" path segment (delimited by /, _, -) → volve
//   3. ambiguous — prompt via ctx.ui.select if a UI is available, otherwise
//      return null with a reason
//
// Per-process cache: workspaceId+service → key, evictable via `evictKey()` so
// a 401 can force a re-fetch (handles in-session key rotation).
//
// Process.env is not touched. Each extension passes the fetched key directly
// into its HTTP client. No cross-extension env race.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type WorkspaceId = "personal" | "volve";
export type ServiceId = "linear" | "notion";

export type Workspace = {
	id: WorkspaceId;
	label: string;
};

export const WORKSPACES: Record<WorkspaceId, Workspace> = {
	personal: { id: "personal", label: "Personal" },
	volve: { id: "volve", label: "Volve" },
};

// Path-segment match: only matches "volve" as its own segment (delimited or
// terminal), so "evolve", "revolver", etc. do not trigger.
const VOLVE_SEGMENT = /(^|[/_-])volve([/_-]|$)/i;
// Any cwd under ~/code/personal/ is unambiguously personal.
const PERSONAL_ROOT = /\/code\/personal(\/|$)/i;

/**
 * Pure cwd → workspace inference. Exported so it can be unit-tested without
 * touching the Keychain or pi runtime. PERSONAL_ROOT is checked first so a
 * personal tree containing "volve" in a subdirectory does not misroute.
 */
export function inferWorkspace(cwd: string): WorkspaceId | null {
	if (PERSONAL_ROOT.test(cwd)) return "personal";
	if (VOLVE_SEGMENT.test(cwd)) return "volve";
	return null;
}

// Mac account + env-var name are derived from (service, workspace) — keep the
// shapes uniform so adding a new service doesn't need a new config table.
function keychainAccount(ws: WorkspaceId): string {
	if (ws === "volve") return "jorgen@volvetech.com";
	return process.env.USER || "";
}

function envVarName(service: ServiceId, ws: WorkspaceId): string {
	return `${service.toUpperCase()}_${ws.toUpperCase()}_API_KEY`;
}

function envFilePath(service: ServiceId): string {
	return join(homedir(), ".config", service, "keys.env");
}

// Remember the user's per-cwd workspace choice for the session so we don't
// prompt on every tool call from an ambiguous cwd.
const cwdChoiceCache = new Map<string, WorkspaceId>();

type ResolveResult =
	| { workspace: Workspace }
	| { workspace: null; reason: string };

type UiCtx = {
	hasUI: boolean;
	ui: { select: (title: string, items: string[]) => Promise<string | undefined> };
};

export async function resolveWorkspace(cwd: string, ctx: UiCtx): Promise<ResolveResult> {
	const inferred = inferWorkspace(cwd);
	if (inferred) return { workspace: WORKSPACES[inferred] };

	const remembered = cwdChoiceCache.get(cwd);
	if (remembered) return { workspace: WORKSPACES[remembered] };

	if (!ctx.hasUI) {
		return {
			workspace: null,
			reason:
				`Ambiguous cwd for workspace routing (${cwd}) and no UI available to disambiguate. ` +
				`Run from a path matching /volve/ or /code/personal/.`,
		};
	}

	const labelToId: Record<string, WorkspaceId> = {
		[WORKSPACES.personal.label]: "personal",
		[WORKSPACES.volve.label]: "volve",
	};
	const choice = await ctx.ui.select(
		`Workspace is ambiguous for this cwd:\n  ${cwd}\n\nWhich workspace should I use?`,
		[WORKSPACES.personal.label, WORKSPACES.volve.label],
	);
	const id = choice ? labelToId[choice] : undefined;
	if (id) {
		cwdChoiceCache.set(cwd, id);
		return { workspace: WORKSPACES[id] };
	}
	return { workspace: null, reason: "User cancelled workspace selection." };
}

// keyCache: `${service}:${workspaceId}` → key. Evictable.
const keyCache = new Map<string, string>();
const cacheKey = (service: ServiceId, ws: WorkspaceId) => `${service}:${ws}`;

function fetchKeyFromKeychain(service: ServiceId, ws: WorkspaceId): string {
	return execFileSync(
		"security",
		["find-generic-password", "-s", `${service}-${ws}`, "-a", keychainAccount(ws), "-w"],
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

function fetchKeyFromEnvFile(service: ServiceId, ws: WorkspaceId): string {
	const path = envFilePath(service);
	const varName = envVarName(service, ws);
	let contents: string;
	try {
		contents = readFileSync(path, "utf8");
	} catch (err) {
		throw new Error(
			`keys file not found at ${path} (${(err as Error).message}). ` +
				`Create it with mode 600 and entries ${envVarName(service, "personal")} ` +
				`and ${envVarName(service, "volve")}.`,
		);
	}
	// Last-wins semantics, matching dotenv / shell `source`.
	let found: string | undefined;
	for (const rawLine of contents.split("\n")) {
		const line = rawLine.trim();
		if (!line || line.startsWith("#")) continue;
		const eq = line.indexOf("=");
		if (eq < 0) continue;
		const k = line.slice(0, eq).trim();
		if (k !== varName) continue;
		found = stripMatchedQuotes(line.slice(eq + 1).trim());
	}
	if (found === undefined) throw new Error(`${varName} not set in ${path}.`);
	if (!found) throw new Error(`${varName} is empty in ${path}.`);
	return found;
}

export function getKey(service: ServiceId, ws: WorkspaceId): string {
	const k = cacheKey(service, ws);
	const cached = keyCache.get(k);
	if (cached) return cached;
	const key =
		process.platform === "darwin"
			? fetchKeyFromKeychain(service, ws)
			: fetchKeyFromEnvFile(service, ws);
	if (!key) throw new Error(`empty key returned for ${service}/${ws}`);
	keyCache.set(k, key);
	return key;
}

/** Evict the cached key (call on 401 so the next request re-fetches). */
export function evictKey(service: ServiceId, ws: WorkspaceId): void {
	keyCache.delete(cacheKey(service, ws));
}

/** Setup hint for a missing key — service-specific paths and account. */
export function setupHint(service: ServiceId, ws: WorkspaceId): string {
	if (process.platform === "darwin") {
		return `Run: security add-generic-password -a "${keychainAccount(ws)}" -s ${service}-${ws} -w`;
	}
	return `Edit ${envFilePath(service)} and ensure ${envVarName(service, ws)} is set (mode 600).`;
}
