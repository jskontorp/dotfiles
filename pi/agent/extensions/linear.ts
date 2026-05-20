/**
 * Linear extension — read/write Linear via GraphQL, per-workspace auth.
 *
 * One tool (`linear`) with action-dispatched verbs. The cwd selects the
 * workspace (personal vs. volve); each workspace owns its own API key
 * stored either in the macOS Keychain (`linear-personal`, `linear-volve`)
 * or in `~/.config/linear/keys.env` (Linux/VM, mode 600). See
 * shared/workspace.ts for the routing and key-fetch contract.
 *
 * Hardening on top of the previous in-tree linear.ts shape:
 *   - 10s request timeout (was: hang forever).
 *   - 429 backoff honours Retry-After (kept from previous shape).
 *   - 401 triggers a single key-cache eviction + retry, so an in-session
 *     key rotation does not require restarting pi.
 *   - update_issue {state}: explicit error message listing available state
 *     names on zero/multiple matches.
 *   - Writes (create_issue, update_issue, create_project_update) are gated
 *     by a preview+confirm UI; add_comment is intentionally ungated
 *     (parallels the previous routing-extension exemption).
 *
 * One-time setup per machine (per workspace):
 *   - Mac:   security add-generic-password -a "$USER" -s linear-personal -w
 *            security add-generic-password -a "jorgen@volvetech.com" -s linear-volve -w
 *            (interactive; runs on a TTY. The keychain will prompt for
 *            access the first time pi reads each entry.)
 *   - Linux: ~/.config/linear/keys.env (mode 600), one var per workspace
 *            (LINEAR_PERSONAL_API_KEY, LINEAR_VOLVE_API_KEY).
 *
 * Get an API key at https://linear.app/settings/api (one per workspace).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { DEFAULT_MAX_LINES, formatSize, DEFAULT_MAX_BYTES } from "@earendil-works/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import { Text } from "@earendil-works/pi-tui";
import {
	getKey,
	evictKey,
	resolveWorkspace,
	setupHint,
	type Workspace,
} from "./shared/workspace";
import { confirmWrite } from "./shared/gate";
import { toolSuccess, validateRequired } from "./shared/tool";

const REQUEST_TIMEOUT_MS = 10_000;

// ── HTTP / GraphQL ─────────────────────────────────────────────────────────

type Sig = AbortSignal | null | undefined;

async function gql(
	ws: Workspace,
	query: string,
	variables: Record<string, any> = {},
	signal?: Sig,
): Promise<any> {
	// Attempt budget: up to two 429 backoffs + one 401 cache-evict retry.
	let triedReauth = false;
	for (let attempt = 0; ; attempt++) {
		const key = getKey("linear", ws.id);
		const ctrl = new AbortController();
		const timeout = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS);
		const composed = signal
			? AbortSignal.any
				? AbortSignal.any([signal, ctrl.signal])
				: ctrl.signal // fallback if AbortSignal.any unavailable; user signal lost but timeout still works
			: ctrl.signal;
		let res: any;
		try {
			res = await fetch("https://api.linear.app/graphql", {
				method: "POST",
				signal: composed,
				headers: { Authorization: key, "Content-Type": "application/json" },
				body: JSON.stringify({ query, variables }),
			});
		} finally {
			clearTimeout(timeout);
		}
		if (res.status === 429 && attempt < 2) {
			const sec = Number(res.headers.get("Retry-After")) || attempt + 1;
			await new Promise((r) => setTimeout(r, sec * 1000));
			continue;
		}
		if (res.status === 401 && !triedReauth) {
			triedReauth = true;
			evictKey("linear", ws.id);
			continue;
		}
		if (!res.ok) {
			const body = await res.text();
			if (res.status === 401) {
				throw new Error(
					`Linear 401 (Unauthorized) for ${ws.label} workspace after re-fetching key. ` +
						`The key may be invalid or revoked. ${setupHint("linear", ws.id)}`,
				);
			}
			throw new Error(`Linear API ${res.status}: ${body}`);
		}
		const json = await res.json();
		if (json.errors?.length) {
			throw new Error(`Linear: ${json.errors.map((e: any) => e.message).join("; ")}`);
		}
		return json.data;
	}
}

// ── Fragments & queries ────────────────────────────────────────────────────

const ISSUE_FIELDS = `fragment F on Issue {
  id identifier title description url priorityLabel
  state { name } assignee { name } labels { nodes { name } }
  project { name id } cycle { name number } createdAt updatedAt
}`;

const SEARCH_FIELDS = `fragment SF on IssueSearchResult {
  id identifier title description url priorityLabel
  state { name } assignee { name } labels { nodes { name } }
  project { name id } cycle { name number } createdAt updatedAt
}`;

const SEARCH = `${SEARCH_FIELDS} query($q:String!){ searchIssues(term:$q,first:20){ totalCount nodes{...SF} } }`;
const GET = `${ISSUE_FIELDS} query($id:String!){ issue(id:$id){...F comments(first:50){ nodes{ body user{name} createdAt } } } }`;
const MY = `${ISSUE_FIELDS} query{ viewer{ assignedIssues(first:50,filter:{state:{type:{nin:["completed","cancelled"]}}},orderBy:updatedAt){ totalCount nodes{...F} } } }`;
const TEAMS = `query{ teams{ nodes{ id name key issueCount } } }`;
const TEAM_STATES = `query($key:String!){ teams(filter:{key:{eq:$key}}){ nodes{ id key states{ nodes{ id name type } } } } }`;
const PROJECTS = `query{ projects(first:50,orderBy:updatedAt){ nodes{ id name state startDate targetDate url description } } }`;
const PROJECT = `query($id:String!){ project(id:$id){ id name state startDate targetDate url description content lead { name } teams { nodes { key } } } }`;

const MUT_ISSUE = `{ id identifier title url state { name } assignee { name } priorityLabel labels { nodes { name } } project { name } }`;

const CREATE_ISSUE = `mutation($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue ${MUT_ISSUE} }
}`;

const UPDATE_ISSUE = `mutation($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success issue ${MUT_ISSUE} }
}`;

const CREATE_COMMENT = `mutation($input: CommentCreateInput!) {
  commentCreate(input: $input) { success comment { id body createdAt user { name } } }
}`;

const CREATE_PROJECT_UPDATE = `mutation($input: ProjectUpdateCreateInput!) {
  projectUpdateCreate(input: $input) { success projectUpdate { id url body health user { name } project { name } createdAt } }
}`;

// ── Resolvers (name → ID) ──────────────────────────────────────────────────

async function resolveTeam(ws: Workspace, key: string, signal?: Sig): Promise<string> {
	const data = await gql(ws, `query { teams { nodes { id key } } }`, {}, signal);
	const team = data.teams.nodes.find((t: any) => t.key.toLowerCase() === key.toLowerCase());
	if (!team) {
		const keys = data.teams.nodes.map((t: any) => t.key).join(", ");
		throw new Error(`Team "${key}" not found in ${ws.label} workspace. Available: ${keys}`);
	}
	return team.id;
}

async function resolveIssue(
	ws: Workspace,
	identifier: string,
	signal?: Sig,
): Promise<{ id: string; teamId: string }> {
	const data = await gql(
		ws,
		`query($id: String!) { issue(id: $id) { id team { id } } }`,
		{ id: identifier },
		signal,
	);
	if (!data.issue) throw new Error(`Issue "${identifier}" not found in ${ws.label} workspace.`);
	return { id: data.issue.id, teamId: data.issue.team.id };
}

async function resolveState(
	ws: Workspace,
	teamId: string,
	name: string,
	signal?: Sig,
): Promise<string> {
	const data = await gql(
		ws,
		`query($teamId: String!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name } } }`,
		{ teamId },
		signal,
	);
	const lower = name.toLowerCase();
	const matches = data.workflowStates.nodes.filter((s: any) => s.name.toLowerCase() === lower);
	if (matches.length === 0) {
		const names = data.workflowStates.nodes.map((s: any) => s.name).join(", ");
		throw new Error(`State "${name}" not found. Available: ${names}`);
	}
	if (matches.length > 1) {
		throw new Error(
			`State "${name}" is ambiguous — ${matches.length} states match (case-insensitive). ` +
				`Linear allows duplicate state names; rename one in Linear or contact an admin.`,
		);
	}
	return matches[0].id;
}

async function resolveAssignee(ws: Workspace, name: string, signal?: Sig): Promise<string> {
	const data = await gql(ws, `query { users { nodes { id name displayName email } } }`, {}, signal);
	const lower = name.toLowerCase();
	const user = data.users.nodes.find(
		(u: any) =>
			u.name?.toLowerCase() === lower ||
			u.displayName?.toLowerCase() === lower ||
			u.email?.toLowerCase() === lower,
	);
	if (!user) {
		const names = data.users.nodes
			.map((u: any) => u.name || u.displayName)
			.filter(Boolean)
			.join(", ");
		throw new Error(`User "${name}" not found. Available: ${names}`);
	}
	return user.id;
}

async function resolveLabels(
	ws: Workspace,
	teamId: string,
	names: string[],
	signal?: Sig,
): Promise<string[]> {
	const data = await gql(
		ws,
		`query($teamId: String!) { team(id: $teamId) { labels { nodes { id name } } } }`,
		{ teamId },
		signal,
	);
	const available = data.team.labels.nodes;
	const ids: string[] = [];
	for (const name of names) {
		const lower = name.trim().toLowerCase();
		const label = available.find((l: any) => l.name.toLowerCase() === lower);
		if (!label) {
			const all = available.map((l: any) => l.name).join(", ");
			throw new Error(`Label "${name}" not found. Available: ${all}`);
		}
		ids.push(label.id);
	}
	return ids;
}

function parseLabels(csv: string): string[] {
	return csv
		.split(",")
		.map((s: string) => s.trim())
		.filter(Boolean);
}

// ── Formatting ─────────────────────────────────────────────────────────────

function fmt(issue: any, verbose = false): string {
	const parts = [`**${issue.identifier}** ${issue.title}`];
	const meta = [
		`State: ${issue.state?.name ?? "Unknown"}`,
		`Assignee: ${issue.assignee?.name ?? "Unassigned"}`,
		issue.priorityLabel && `Priority: ${issue.priorityLabel}`,
		issue.labels?.nodes?.length && `Labels: ${issue.labels.nodes.map((l: any) => l.name).join(", ")}`,
		issue.project?.name && `Project: ${issue.project.name}`,
	].filter(Boolean);
	parts.push(`  ${meta.join(" · ")}`);
	if (issue.url) parts.push(`  ${issue.url}`);
	if (verbose && issue.description) parts.push("", issue.description);
	return parts.join("\n");
}

function fmtList(issues: any[], total?: number): string {
	if (!issues.length) return "No issues found.";
	let out = issues.map((i) => fmt(i)).join("\n\n");
	if (total != null && total > issues.length) {
		out += `\n\n(showing ${issues.length} of ${total} results)`;
	}
	return out;
}

function fmtMutation(issue: any): string {
	const meta = [
		`State: ${issue.state?.name ?? "Unknown"}`,
		`Assignee: ${issue.assignee?.name ?? "Unassigned"}`,
		issue.priorityLabel && `Priority: ${issue.priorityLabel}`,
		issue.labels?.nodes?.length && `Labels: ${issue.labels.nodes.map((l: any) => l.name).join(", ")}`,
		issue.project?.name && `Project: ${issue.project.name}`,
	].filter(Boolean);
	return [`**${issue.identifier}** ${issue.title}`, `  ${meta.join(" · ")}`, `  ${issue.url}`].join("\n");
}

function fmtProject(p: any, verbose = false): string {
	const meta = [
		`State: ${p.state ?? "?"}`,
		p.lead?.name && `Lead: ${p.lead.name}`,
		p.startDate && `Start: ${p.startDate}`,
		p.targetDate && `Target: ${p.targetDate}`,
		p.teams?.nodes?.length && `Teams: ${p.teams.nodes.map((t: any) => t.key).join(", ")}`,
	].filter(Boolean);
	const parts = [`**${p.name}**`, `  ${meta.join(" · ")}`];
	if (p.url) parts.push(`  ${p.url}`);
	if (verbose && (p.description || p.content)) {
		parts.push("", p.description || p.content);
	}
	return parts.join("\n");
}

// ── Action handlers ────────────────────────────────────────────────────────

const actions: Record<string, (ws: Workspace, p: any, signal: Sig) => Promise<string>> = {
	async search(ws, p, signal) {
		const data = await gql(ws, SEARCH, { q: p.query }, signal);
		const { nodes, totalCount } = data.searchIssues;
		return fmtList(nodes, totalCount);
	},

	async get_issue(ws, p, signal) {
		const data = await gql(ws, GET, { id: p.issue_id }, signal);
		const issue = data.issue;
		if (!issue) throw new Error(`Issue ${p.issue_id} not found in ${ws.label} workspace.`);
		let out = fmt(issue, true);
		const comments = issue.comments?.nodes ?? [];
		if (comments.length) {
			out += "\n\n### Comments\n";
			for (const c of comments) {
				out += `\n**${c.user?.name ?? "Unknown"}** (${c.createdAt?.slice(0, 10) ?? ""}):\n${c.body}\n`;
			}
		}
		return out;
	},

	async my_issues(ws, _p, signal) {
		const data = await gql(ws, MY, {}, signal);
		const { nodes: issues, totalCount } = data.viewer.assignedIssues;
		if (!issues.length) return "No active issues assigned to you.";
		return `**Your active issues (${totalCount}):**\n\n` + fmtList(issues, totalCount);
	},

	async list_teams(ws, _p, signal) {
		const data = await gql(ws, TEAMS, {}, signal);
		const teams = data.teams.nodes;
		return teams.length
			? teams.map((t: any) => `- **${t.name}** (key: ${t.key}, ${t.issueCount} issues)`).join("\n")
			: "No teams found.";
	},

	async get_team_states(ws, p, signal) {
		const data = await gql(ws, TEAM_STATES, { key: p.team_key }, signal);
		const team = data.teams.nodes[0];
		if (!team) throw new Error(`Team "${p.team_key}" not found in ${ws.label} workspace.`);
		const states = team.states.nodes;
		if (!states.length) return `Team ${team.key}: no workflow states defined.`;
		return (
			`**${team.key} workflow states:**\n\n` +
			states.map((s: any) => `- **${s.name}** (type: ${s.type})`).join("\n")
		);
	},

	async list_projects(ws, _p, signal) {
		const data = await gql(ws, PROJECTS, {}, signal);
		const projects = data.projects.nodes;
		if (!projects.length) return "No projects found.";
		return projects.map((p: any) => fmtProject(p)).join("\n\n");
	},

	async get_project(ws, p, signal) {
		const data = await gql(ws, PROJECT, { id: p.project_id }, signal);
		if (!data.project) throw new Error(`Project "${p.project_id}" not found in ${ws.label} workspace.`);
		return fmtProject(data.project, true);
	},

	async create_issue(ws, p, signal) {
		const teamId = await resolveTeam(ws, p.team_key, signal);
		const input: any = { teamId, title: p.title };
		if (p.description) input.description = p.description;
		if (p.priority != null) input.priority = Number(p.priority);

		const [stateId, assigneeId, labelIds] = await Promise.all([
			p.state ? resolveState(ws, teamId, p.state, signal) : undefined,
			p.assignee ? resolveAssignee(ws, p.assignee, signal) : undefined,
			p.labels ? resolveLabels(ws, teamId, parseLabels(p.labels), signal) : undefined,
		]);
		if (stateId) input.stateId = stateId;
		if (assigneeId) input.assigneeId = assigneeId;
		if (labelIds?.length) input.labelIds = labelIds;

		const data = await gql(ws, CREATE_ISSUE, { input }, signal);
		if (!data.issueCreate.success) throw new Error("Failed to create issue.");
		return `Created in ${ws.label}:\n${fmtMutation(data.issueCreate.issue)}`;
	},

	async update_issue(ws, p, signal) {
		const { id, teamId } = await resolveIssue(ws, p.issue_id, signal);
		const input: any = {};
		if (p.title) input.title = p.title;
		if (p.description) input.description = p.description;
		if (p.priority != null) input.priority = Number(p.priority);

		const [stateId, assigneeId, labelIds] = await Promise.all([
			p.state ? resolveState(ws, teamId, p.state, signal) : undefined,
			p.assignee ? resolveAssignee(ws, p.assignee, signal) : undefined,
			p.labels ? resolveLabels(ws, teamId, parseLabels(p.labels), signal) : undefined,
		]);
		if (stateId) input.stateId = stateId;
		if (assigneeId) input.assigneeId = assigneeId;
		if (labelIds?.length) input.labelIds = labelIds;

		if (!Object.keys(input).length) {
			throw new Error(
				"No fields to update. Provide title, description, state, assignee, priority, or labels.",
			);
		}
		const data = await gql(ws, UPDATE_ISSUE, { id, input }, signal);
		if (!data.issueUpdate.success) throw new Error("Failed to update issue.");
		return `Updated in ${ws.label}:\n${fmtMutation(data.issueUpdate.issue)}`;
	},

	async add_comment(ws, p, signal) {
		const { id: issueId } = await resolveIssue(ws, p.issue_id, signal);
		const data = await gql(ws, CREATE_COMMENT, { input: { issueId, body: p.body } }, signal);
		if (!data.commentCreate.success) throw new Error("Failed to add comment.");
		const c = data.commentCreate.comment;
		return `Comment added by ${c.user?.name ?? "you"} (${c.createdAt?.slice(0, 10) ?? "now"}):\n${c.body}`;
	},

	async create_project_update(ws, p, signal) {
		const input: any = { projectId: p.project_id, body: p.body };
		if (p.health) input.health = p.health;
		const data = await gql(ws, CREATE_PROJECT_UPDATE, { input }, signal);
		if (!data.projectUpdateCreate.success) throw new Error("Failed to create project update.");
		const u = data.projectUpdateCreate.projectUpdate;
		return (
			`Project update on ${u.project?.name ?? "?"} (${u.health ?? "no health"}):\n` +
			`  by ${u.user?.name ?? "you"} (${u.createdAt?.slice(0, 10) ?? "now"})\n` +
			`  ${u.url ?? ""}\n\n${u.body ?? ""}`
		);
	},
};

const required: Record<string, string[]> = {
	search: ["query"],
	get_issue: ["issue_id"],
	get_team_states: ["team_key"],
	get_project: ["project_id"],
	create_issue: ["team_key", "title"],
	update_issue: ["issue_id"],
	add_comment: ["issue_id", "body"],
	create_project_update: ["project_id", "body"],
};

const READ_ACTIONS = new Set([
	"search",
	"get_issue",
	"my_issues",
	"list_teams",
	"get_team_states",
	"list_projects",
	"get_project",
]);

// add_comment is intentionally NOT gated — short, frequent, low blast radius.
const GATED_WRITE_ACTIONS = new Set(["create_issue", "update_issue", "create_project_update"]);

const ALL_ACTIONS = [
	"search",
	"get_issue",
	"my_issues",
	"list_teams",
	"get_team_states",
	"list_projects",
	"get_project",
	"create_issue",
	"update_issue",
	"add_comment",
	"create_project_update",
] as const;

const Params = Type.Object({
	action: StringEnum(ALL_ACTIONS, {
		description:
			'"search" — full-text issue search; ' +
			'"get_issue" — fetch issue with comments by identifier (e.g. JSK-123); ' +
			'"my_issues" — your active assigned issues; ' +
			'"list_teams" — teams + keys; ' +
			'"get_team_states" — workflow states for a team; ' +
			'"list_projects" — recent projects; ' +
			'"get_project" — single project detail; ' +
			'"create_issue" — new issue (gated); ' +
			'"update_issue" — update fields (gated); ' +
			'"add_comment" — add comment (ungated); ' +
			'"create_project_update" — post a project update with health (gated).',
	}),
	query: Type.Optional(Type.String({ description: 'Search text (required for "search").' })),
	issue_id: Type.Optional(
		Type.String({
			description: 'Issue identifier like "JSK-123" (required for get_issue, update_issue, add_comment).',
		}),
	),
	team_key: Type.Optional(
		Type.String({
			description: 'Team key like "JSK" (required for create_issue, get_team_states). Use list_teams to discover.',
		}),
	),
	project_id: Type.Optional(
		Type.String({ description: "Project UUID (required for get_project, create_project_update)." }),
	),
	title: Type.Optional(Type.String({ description: "Issue title (required for create_issue)." })),
	description: Type.Optional(Type.String({ description: "Issue description in markdown." })),
	state: Type.Optional(
		Type.String({
			description:
				'Workflow state name, e.g. "In Progress", "Done". Resolved by case-insensitive name; error lists alternatives.',
		}),
	),
	assignee: Type.Optional(Type.String({ description: "Assignee display name or email." })),
	priority: Type.Optional(
		Type.Number({ description: "Priority: 0 = none, 1 = urgent, 2 = high, 3 = medium, 4 = low." }),
	),
	labels: Type.Optional(Type.String({ description: 'Comma-separated label names, e.g. "Bug, Frontend".' })),
	body: Type.Optional(
		Type.String({
			description: 'Markdown body — comment text for add_comment; project-update body for create_project_update.',
		}),
	),
	health: Type.Optional(
		StringEnum(["onTrack", "atRisk", "offTrack"] as const, {
			description: "Project-update health (optional, only for create_project_update).",
		}),
	),
});

// ── Extension ──────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "linear",
		label: "Linear",
		description:
			"Read and write Linear. Workspace (personal/volve) auto-routed by cwd. " +
			"Actions: search, get_issue, my_issues, list_teams, get_team_states, list_projects, get_project, " +
			"create_issue, update_issue, add_comment, create_project_update. " +
			`Output truncated to ${DEFAULT_MAX_LINES} lines or ${formatSize(DEFAULT_MAX_BYTES)}.`,
		promptGuidelines: [
			"Use list_teams to discover team keys before create_issue.",
			"Use search to check for existing issues before creating duplicates.",
			"State, assignee, and label names are resolved by case-insensitive exact match. Errors list available options.",
			"To set an issue to In Progress, call update_issue with state: 'In Progress'.",
			"On a git branch matching [A-Z]+-\\d+ (e.g. jsk-36-silencing-hook), the identifier likely refers to a Linear issue.",
			"Workspace routing is automatic from cwd — do not pass an API key.",
		],
		parameters: Params,

		async execute(_id: any, params: any, signal: Sig, ctx: any) {
			try {
				validateRequired(params.action, params, required[params.action] ?? []);
				const handler = actions[params.action];
				if (!handler) throw new Error(`Unknown action: ${params.action}`);

				const resolved = await resolveWorkspace(ctx.cwd, ctx);
				if (!resolved.workspace) {
					return {
						content: [{ type: "text" as const, text: resolved.reason }],
						isError: true,
						details: { action: params.action },
					};
				}
				const ws = resolved.workspace;

				if (GATED_WRITE_ACTIONS.has(params.action)) {
					const gate = await confirmWrite(
						ctx,
						"linear",
						params.action,
						params,
						ws.label,
					);
					if (!gate.allow) {
						return {
							content: [{ type: "text" as const, text: gate.reason }],
							isError: true,
							details: { action: params.action, gated: true },
						};
					}
				}

				ctx.ui?.notify?.(`Linear: ${ws.label} workspace`, "info");
				try {
					return toolSuccess(params.action, await handler(ws, params, signal));
				} catch (err: any) {
					// Surface keychain / env-file errors with the right setup hint.
					if (
						err?.message?.includes("find-generic-password") ||
						err?.message?.includes("keys file not found") ||
						err?.message?.match(/LINEAR_(PERSONAL|VOLVE)_API_KEY/)
					) {
						throw new Error(
							`Could not load Linear API key for ${ws.label}: ${err.message} ${setupHint("linear", ws.id)}`,
						);
					}
					throw err;
				}
			} catch (err: any) {
				if (err?.name === "AbortError") throw new Error("Cancelled");
				throw err;
			}
		},

		renderCall(args: any, theme: any) {
			let text = theme.fg("toolTitle", theme.bold("linear "));
			text += theme.fg("accent", args.action);
			if (args.query) text += " " + theme.fg("dim", `"${args.query}"`);
			if (args.issue_id) text += " " + theme.fg("muted", args.issue_id);
			if (args.team_key) text += " " + theme.fg("muted", args.team_key);
			if (args.project_id) text += " " + theme.fg("muted", args.project_id.slice(0, 8));
			if (args.title) text += " " + theme.fg("dim", `"${args.title}"`);
			if (args.body) text += " " + theme.fg("dim", `${args.body.length} chars`);
			return new Text(text, 0, 0);
		},

		renderResult(result: any, info: any, theme: any) {
			const { expanded, isPartial } = info;
			if (isPartial) return new Text(theme.fg("warning", "Fetching from Linear…"), 0, 0);

			if (result.isError) {
				const msg = result.content[0]?.type === "text" ? result.content[0].text : "Error";
				return new Text(theme.fg("error", msg), 0, 0);
			}

			const details = result.details as { action: string; truncated?: boolean } | undefined;
			let text = theme.fg("success", `✓ ${details?.action ?? "done"}`);
			if (details?.truncated) text += theme.fg("warning", " (truncated)");

			if (expanded) {
				const content = result.content[0];
				if (content?.type === "text") {
					const lines = content.text.split("\n").slice(0, 50);
					for (const line of lines) text += `\n${theme.fg("dim", line)}`;
					if (content.text.split("\n").length > 50)
						text += `\n${theme.fg("muted", "… (expand to see more)")}`;
				}
			}

			return new Text(text, 0, 0);
		},
	});
}

// READ_ACTIONS is currently informational (the gate uses GATED_WRITE_ACTIONS
// directly) — exported for future use / debugging.
export { READ_ACTIONS };
