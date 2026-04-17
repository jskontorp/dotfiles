/**
 * query-image extension
 *
 * Adds a `query_image` tool that routes image files through a vision-capable
 * model on GitHub Copilot and returns a text description. This works around
 * Anthropic-vision being blocked on the org's Copilot proxy
 * (error: "vision is not enabled for this organization") while Codex/GPT
 * vision remains enabled.
 *
 * The tool is installed to steer the main (usually Anthropic) agent away from
 * attempting to `read` image files directly, which would fail.
 *
 * To change the describer model, edit the constants below.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { completeSimple, type Context, type UserMessage } from "@mariozechner/pi-ai";
import { Type } from "@sinclair/typebox";
import { readFile, stat } from "node:fs/promises";
import { extname, isAbsolute, resolve } from "node:path";

// --- Configuration ---------------------------------------------------------

const DESCRIBER_PROVIDER = "github-copilot";
// Default describer model. Must exist in pi's model registry for github-copilot
// AND be enabled on the user's Copilot org (failure modes differ: client-side
// "not found" vs server-side "not supported"). Swap for another Copilot
// vision-capable id (e.g. "gpt-5.4", "gemini-3-pro-preview") if preferred.
const DESCRIBER_MODEL = "gpt-5.3-codex";

const IMAGE_EXTS: Record<string, string> = {
	".png": "image/png",
	".jpg": "image/jpeg",
	".jpeg": "image/jpeg",
	".gif": "image/gif",
	".webp": "image/webp",
	".bmp": "image/bmp",
};

// Max image size we'll try to send (Copilot proxy rejects huge payloads).
const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

// --- Extension -------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "query_image",
		label: "Query image",
		description:
			"Answer a question about an image file (or describe it exhaustively if no question is given) using a vision-capable model. " +
			"REQUIRED for any image file path the user references (pi-clipboard-*.png, " +
			"Screenshot*.png, or any .png/.jpg/.jpeg/.gif/.webp/.bmp). " +
			"Use this instead of the `read` tool for images: when the current agent " +
			"is Claude on GitHub Copilot, `read` on images fails with 'vision is not " +
			"enabled for this organization'. This tool routes the image through a " +
			`different model (${DESCRIBER_PROVIDER}/${DESCRIBER_MODEL}) and returns a text answer.`,
		promptSnippet:
			"Query image files (screenshots, clipboard paste-ins) by routing them through a vision model. Use this instead of `read` for images.",
		promptGuidelines: [
			"Whenever the user's message contains a path to an image file (e.g. /var/folders/.../pi-clipboard-*.png, /var/folders/.../Screenshot*.png, or any .png/.jpg/.jpeg/.gif/.webp/.bmp), call `query_image` with that path. Do NOT call `read` on image files — it will fail.",
			"Pass `question` when the user has a specific intent (e.g. 'what error is shown?'). Omit `question` for a full description.",
		],
		parameters: Type.Object({
			path: Type.String({ description: "Path to the image file (absolute or relative to cwd)." }),
			question: Type.Optional(
				Type.String({
					description:
						"Optional focused question about the image. Omit for a general exhaustive description.",
				}),
			),
		}),
		// NOTE on error handling: pi's agent loop derives `isError` from whether
		// execute() throws, not from a returned `isError` field. Throw on failure
		// so the main agent sees a proper error signal.
		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			// Normalize path (strip leading @, resolve against cwd)
			const inputPath = params.path.startsWith("@") ? params.path.slice(1) : params.path;
			const absPath = isAbsolute(inputPath) ? inputPath : resolve(ctx.cwd, inputPath);

			const ext = extname(absPath).toLowerCase();
			const mediaType = IMAGE_EXTS[ext];
			if (!mediaType) {
				throw new Error(
					`Not a supported image file: ${absPath} (extension: ${ext || "none"}). Supported: ${Object.keys(IMAGE_EXTS).join(", ")}.`,
				);
			}

			let info: Awaited<ReturnType<typeof stat>>;
			try {
				info = await stat(absPath);
			} catch (err) {
				throw new Error(`Cannot stat image: ${absPath} (${(err as Error).message})`);
			}
			if (info.size > MAX_IMAGE_BYTES) {
				throw new Error(
					`Image too large (${info.size} bytes; max ${MAX_IMAGE_BYTES}). Resize before querying.`,
				);
			}

			// Resolve the describer model
			const model = ctx.modelRegistry.find(DESCRIBER_PROVIDER, DESCRIBER_MODEL);
			if (!model) {
				throw new Error(
					`Describer model not found: ${DESCRIBER_PROVIDER}/${DESCRIBER_MODEL}. Edit the extension to pick another vision-capable model.`,
				);
			}

			const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
			if (!auth.ok) {
				throw new Error(
					`No auth for ${DESCRIBER_PROVIDER}/${DESCRIBER_MODEL}: ${auth.error}. Run /login ${DESCRIBER_PROVIDER}.`,
				);
			}

			let data: Buffer;
			try {
				data = await readFile(absPath);
			} catch (err) {
				throw new Error(`Cannot read image: ${absPath} (${(err as Error).message})`);
			}
			const base64 = data.toString("base64");

			const instruction = params.question
				? `The user has a specific question about the attached image. Answer it precisely, then add any surrounding context from the image that helps the main agent act on the answer.\n\nQuestion: ${params.question}`
				: "Describe the attached image so another agent can act on it without seeing it. Transcribe any visible text verbatim (code, error messages, UI labels, terminal output, etc.). Describe layout, colors, and non-text content (diagrams, charts, icons). Be exhaustive but concise. No preamble.";

			const userMessage: UserMessage = {
				role: "user",
				timestamp: Date.now(),
				content: [
					{ type: "text", text: instruction },
					{ type: "image", data: base64, mimeType: mediaType },
				],
			};

			const context: Context = {
				systemPrompt:
					"You are an image-to-text transcriber and describer. Return only the description/transcription. Do not ask clarifying questions.",
				messages: [userMessage],
			};

			onUpdate?.({
				content: [{ type: "text", text: `Querying image via ${DESCRIBER_PROVIDER}/${DESCRIBER_MODEL}…` }],
			});

			let response;
			try {
				response = await completeSimple(model, context, {
					apiKey: auth.apiKey,
					headers: auth.headers,
					signal,
				});
			} catch (err) {
				throw new Error(`Describer call failed: ${(err as Error).message}`);
			}

			if (response.stopReason === "error" || response.stopReason === "aborted") {
				throw new Error(
					`Describer returned ${response.stopReason}: ${response.errorMessage ?? "(no message)"}`,
				);
			}

			const text = response.content
				.filter((c): c is { type: "text"; text: string } => c.type === "text")
				.map((c) => c.text)
				.join("\n")
				.trim();

			if (!text) {
				throw new Error("Describer returned no text");
			}

			return {
				content: [{ type: "text", text }],
				details: {
					path: absPath,
					describer: `${DESCRIBER_PROVIDER}/${DESCRIBER_MODEL}`,
					question: params.question,
					usage: response.usage,
				},
			};
		},
	});

	// Safety net: block `read` on image files and redirect to query_image.
	// Applied unconditionally — the main agent should never try to read images
	// directly in this setup.
	pi.on("tool_call", (event) => {
		if (event.toolName !== "read") return;
		const input = event.input as { path?: string } | undefined;
		const path = input?.path;
		if (!path) return;
		const normalized = path.startsWith("@") ? path.slice(1) : path;
		const ext = extname(normalized).toLowerCase();
		if (ext in IMAGE_EXTS) {
			return {
				block: true,
				reason: `read does not work for image files in this session. Use query_image with path="${path}" instead.`,
			};
		}
	});
}
