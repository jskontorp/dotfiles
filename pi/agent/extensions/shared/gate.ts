// Pi has one modal slot. Keep its queue process-wide: jiti's moduleCache:false
// can load separate copies of this helper for different extensions (JSK-57).
import { renderPreview } from "./preview.ts";

declare global {
	var __dotfilesPiPromptMutex: Promise<void> | undefined;
}

export async function withPromptLock<T>(fn: () => Promise<T>): Promise<T> {
	let release!: () => void;
	const next = new Promise<void>((resolve) => {
		release = resolve;
	});
	const previous = globalThis.__dotfilesPiPromptMutex ?? Promise.resolve();
	globalThis.__dotfilesPiPromptMutex = previous.then(() => next);
	await previous;
	try {
		return await fn();
	} finally {
		release();
	}
}

export function __resetPromptMutexForTest(): void {
	globalThis.__dotfilesPiPromptMutex = Promise.resolve();
}

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

	return withPromptLock<GateResult>(async () => {
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
	});
}
