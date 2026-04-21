// Notion write-gate for @feniix/pi-notion.
//
// Upstream architecture (verified against @feniix/pi-notion@2.2.0):
//   - FileTokenStorage captures NOTION_MCP_AUTH_FILE once in its constructor
//     (mcp-client.ts:594–597). mcpClient is a module-scoped singleton.
//     Therefore: per-call workspace routing via env mutation is NOT possible
//     the way LINEAR_API_KEY works. Auth routing must happen BEFORE pi starts.
//     That's handled by ~/.config/zsh/pi-notion-routing.zsh — it sets
//     NOTION_MCP_AUTH_FILE based on $PWD when you invoke `pi`.
//   - Notion MCP tools are discovered dynamically after OAuth connect. Names
//     follow the convention `notion-<verb>-<noun>` (hyphenated). The gate
//     matches by name prefix + an explicit read allowlist; unknown names
//     fail-open with a one-time notify (blocking reads on an incomplete
//     allowlist is worse than a missed gate).
//
// What this extension does:
//   For each Notion write tool call, render a markdown preview and block
//   until the user picks the action label / revise / cancel. Reads and the
//   notion_mcp_* management tools pass through untouched.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

const READ_TOOLS = new Set([
	"notion-search",
	"notion-fetch",
	"notion-get-comments",
	"notion-query-meeting-notes",
	"notion-query-database-view",
]);

// Explicitly exempt from the gate:
//   notion-create-comment  — short, frequent, low blast radius (parallels Linear's `comment` exemption).
//   notion-duplicate-page  — sibling-only, trivial to trash manually if wrong.
const SKIP_TOOLS = new Set(["notion-create-comment", "notion-duplicate-page"]);

// Prefix-based so future write tools auto-gate.
const WRITE_PREFIXES = ["notion-create-", "notion-update-", "notion-move-", "notion-duplicate-"];

function isGatedWrite(toolName: string): boolean {
	if (READ_TOOLS.has(toolName)) return false;
	if (SKIP_TOOLS.has(toolName)) return false;
	return WRITE_PREFIXES.some((p) => toolName.startsWith(p));
}

// Tools that match the `notion-` umbrella but neither READ_TOOLS nor a
// WRITE_PREFIX. We pass them through (fail-open) but notify once so a missing
// allowlist entry is visible.
const warnedUnknown = new Set<string>();

function niceAction(toolName: string): string {
	return toolName.replace(/^notion-/, "").replace(/-/g, " ");
}

// Surface the target id in the header — this is the single most important
// thing the user wants to eyeball before approving a write.
const TARGET_ID_FIELDS = [
	"parent",
	"page_id",
	"data_source_id",
	"database_id",
	"page_or_database_ids",
	"new_parent",
];

function extractTargetLine(input: Record<string, unknown>): string | null {
	for (const k of TARGET_ID_FIELDS) {
		const v = input[k];
		if (v === undefined || v === null || v === "") continue;
		const val = typeof v === "string" ? v : JSON.stringify(v);
		return `**Target:** \`${k}\` = ${val}`;
	}
	return null;
}

function renderStringField(k: string, v: string, action: string, lines: string[]): void {
	if (v === "") {
		if (action.startsWith("create")) return; // unset on create — omit
		lines.push(`**${k}:** *(empty)*`);
		return;
	}
	if (v.includes("\n") || v.length > 80) {
		lines.push(`**${k}:**`);
		lines.push("");
		lines.push(v);
		lines.push("");
	} else {
		lines.push(`**${k}:** ${v}`);
	}
}

function renderObjectField(k: string, v: unknown, lines: string[]): void {
	lines.push(`**${k}:**`);
	lines.push("");
	lines.push("```json");
	lines.push(JSON.stringify(v, null, 2));
	lines.push("```");
	lines.push("");
}

// Tool-aware highlight for content_updates (search-replace pairs on
// notion-update-page update_content). This is the class of call most likely
// to be wrong; worth a dedicated block.
function renderContentUpdates(updates: unknown[], lines: string[]): void {
	lines.push(`**content_updates** (${updates.length}):`);
	lines.push("");
	for (const [i, u] of updates.entries()) {
		if (!u || typeof u !== "object") {
			lines.push(`${i + 1}. (non-object)`);
			continue;
		}
		const { old_str, new_str } = u as Record<string, unknown>;
		lines.push(`${i + 1}. \`old_str\` → \`new_str\``);
		lines.push("```");
		lines.push(`- ${String(old_str ?? "")}`);
		lines.push(`+ ${String(new_str ?? "")}`);
		lines.push("```");
	}
}

function renderPreview(toolName: string, input: Record<string, unknown>): string {
	const action = niceAction(toolName);
	const lines: string[] = [];
	lines.push(`**Tool:** \`${toolName}\`   **Action:** \`${action}\``);
	const target = extractTargetLine(input);
	if (target) lines.push(target);
	lines.push("");
	for (const [k, v] of Object.entries(input)) {
		if (TARGET_ID_FIELDS.includes(k)) continue; // already in header
		if (v === undefined || v === null) continue;
		if (k === "content_updates" && Array.isArray(v)) {
			renderContentUpdates(v, lines);
			continue;
		}
		if (typeof v === "string") {
			renderStringField(k, v, action, lines);
		} else {
			renderObjectField(k, v, lines);
		}
	}
	return lines.join("\n");
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		const name = event.toolName;

		// Ignore everything non-Notion, including the upstream management tools.
		if (!name.startsWith("notion-") && !name.startsWith("notion_")) return;
		if (name.startsWith("notion_mcp_")) return;

		const input = (event.input ?? {}) as Record<string, unknown>;

		if (!isGatedWrite(name)) {
			// Reads / skipped writes pass through. Warn once on names that
			// look Notion-ish but don't match any allowlist or prefix, so a
			// missed gate becomes visible rather than silent.
			if (name.startsWith("notion-") && !READ_TOOLS.has(name) && !SKIP_TOOLS.has(name)) {
				if (!warnedUnknown.has(name)) {
					warnedUnknown.add(name);
					ctx.ui.notify(
						`notion-routing: tool '${name}' not recognised as read or write — passing through. ` +
							`Add to READ_TOOLS, SKIP_TOOLS, or WRITE_PREFIXES in notion-routing.ts if this should change.`,
						"warning",
					);
				}
			}
			return;
		}

		const action = niceAction(name);

		if (!ctx.hasUI) {
			return {
				block: true,
				reason:
					`Notion ${action} on ${name} requires interactive confirmation, ` +
					`but pi is running without a UI (print/RPC mode). Re-run in interactive mode to confirm.`,
			};
		}

		const preview = renderPreview(name, input);
		const choice = await ctx.ui.select(
			`Notion ${action} — review before executing\n\n${preview}`,
			[action, "revise", "cancel"],
		);

		if (choice === "cancel" || choice === undefined) {
			return { block: true, reason: `User cancelled the Notion ${action}.` };
		}
		if (choice !== action) {
			// revise
			const feedback = await ctx.ui.input(
				"What should change?",
				"e.g. 'different parent page, shorter title, append instead of replace'",
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
		return; // allow
	});
}
