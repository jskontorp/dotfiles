// Tool-execution helpers shared between linear.ts and notion.ts.
//
// No env-loading. Per-workspace auth lives in shared/workspace.ts; each
// extension fetches its key directly via getKey() and passes it into fetch().

import {
	truncateHead,
	DEFAULT_MAX_BYTES,
	DEFAULT_MAX_LINES,
	formatSize,
} from "@earendil-works/pi-coding-agent";

/** Standard success result with head-truncation to pi's default limits. */
export function toolSuccess(action: string, output: string) {
	const truncation = truncateHead(output, {
		maxLines: DEFAULT_MAX_LINES,
		maxBytes: DEFAULT_MAX_BYTES,
	});

	let result = truncation.content;
	if (truncation.truncated) {
		result +=
			`\n\n[Output truncated: ${truncation.outputLines} of ${truncation.totalLines} lines ` +
			`(${formatSize(truncation.outputBytes)} of ${formatSize(truncation.totalBytes)})]`;
	}

	return {
		content: [{ type: "text" as const, text: result }],
		details: { action, truncated: truncation.truncated },
	};
}

/**
 * Validate required params — throws on missing. Uses `== null` so falsy-but-
 * valid values (0, false) pass through. Empty/whitespace-only strings are
 * treated as missing.
 */
export function validateRequired(
	action: string,
	params: Record<string, any>,
	required: string[],
) {
	for (const key of required) {
		const v = params[key];
		if (v == null || (typeof v === "string" && !v.trim())) {
			throw new Error(`"${key}" is required for ${action}.`);
		}
	}
}

export { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, formatSize };
