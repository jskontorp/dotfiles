// Write-action confirm gate, shared between linear.ts and notion.ts.
//
// Flow (mirrors the previous linear-routing.ts behaviour):
//   1. Render markdown preview via renderPreview().
//   2. ctx.ui.select with [<action label>, "revise", "cancel"].
//   3. action label → allow; revise → prompt for feedback, return block with
//      that feedback embedded in the reason; cancel → return block.
//   4. Headless (!ctx.hasUI) → return block immediately with a clear reason.

import { renderPreview } from "./preview";

type UiCtx = {
	hasUI: boolean;
	ui: {
		select: (title: string, items: string[]) => Promise<string | undefined>;
		input: (title: string, placeholder?: string) => Promise<string | undefined>;
	};
};

export type GateResult =
	| { allow: true }
	| { allow: false; reason: string };

export async function confirmWrite(
	ctx: UiCtx,
	toolName: string,
	action: string,
	input: Record<string, unknown>,
	workspaceLabel: string,
	skipFields: string[] = [],
): Promise<GateResult> {
	if (!ctx.hasUI) {
		return {
			allow: false,
			reason:
				`${toolName} ${action} requires interactive confirmation, but pi is running ` +
				`without a UI (print/RPC mode). Re-run in interactive mode to confirm.`,
		};
	}

	const preview = renderPreview(toolName, action, input, { workspaceLabel, skipFields });
	const choice = await ctx.ui.select(
		`${toolName} ${action} — review before executing\n\n${preview}`,
		[action, "revise", "cancel"],
	);

	if (choice === "cancel" || choice === undefined) {
		return { allow: false, reason: `User cancelled the ${toolName} ${action}.` };
	}
	if (choice !== action) {
		// revise
		const feedback = await ctx.ui.input(
			"What should change?",
			"e.g. 'shorter title, move details to description, lower priority'",
		);
		if (!feedback) {
			return {
				allow: false,
				reason:
					`User requested changes to the ${action} but did not provide feedback. ` +
					`Ask them what to change before retrying.`,
			};
		}
		return {
			allow: false,
			reason:
				`User requested changes before the ${action}: ${feedback}\n\n` +
				`Redraft the inputs and call the tool again — it will be re-gated for confirmation.`,
		};
	}
	return { allow: true };
}
