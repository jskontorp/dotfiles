// Markdown preview for write-action confirm gates. Shared between linear.ts
// and notion.ts so both gate previews look identical.
//
// Lifted from the previous linear-routing.ts:renderPreview, generalised to
// accept any (workspaceLabel, toolName, action, input) and to skip a
// caller-provided list of fields that should not appear (e.g. fields already
// surfaced in the header).

export type PreviewOptions = {
	workspaceLabel?: string;
	skipFields?: string[];
};

function isLongString(v: string): boolean {
	return v.includes("\n") || v.length > 80;
}

function renderStringField(k: string, v: string, action: string, lines: string[]): void {
	if (v === "") {
		// Blank string on create = "unset", omit. On update/delete = intentional
		// clear, surface so the user can see it.
		if (action.startsWith("create")) return;
		lines.push(`**${k}:** *(empty)*`);
		return;
	}
	if (isLongString(v)) {
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

export function renderPreview(
	toolName: string,
	action: string,
	input: Record<string, unknown>,
	opts: PreviewOptions = {},
): string {
	const skip = new Set(opts.skipFields ?? []);
	const lines: string[] = [];
	const header: string[] = [];
	if (opts.workspaceLabel) header.push(`**Workspace:** ${opts.workspaceLabel}`);
	header.push(`**Tool:** \`${toolName}\``);
	header.push(`**Action:** \`${action}\``);
	lines.push(header.join("   "));
	lines.push("");
	for (const [k, v] of Object.entries(input)) {
		if (k === "action") continue;
		if (skip.has(k)) continue;
		if (v === undefined || v === null) continue;
		if (typeof v === "string") {
			renderStringField(k, v, action, lines);
		} else {
			renderObjectField(k, v, lines);
		}
	}
	return lines.join("\n");
}
