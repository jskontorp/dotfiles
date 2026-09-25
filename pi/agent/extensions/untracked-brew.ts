// Untracked-brew gate for pi. Same parity layer as destructive-gate.ts
// (which blocks destructive bash verbs); this one guards Homebrew verbs
// that can ADD machine state: install/reinstall/upgrade (named args) and
// tap. `brew install <x>` silently diverges the Mac from dotfiles —
// machine/mac/Brewfile is the only brew manifest (applied via `just update`,
// audited by `just status`). Keep wording aligned with `brew-untracked`.
//
// Cheap implementation: parse machine/mac/Brewfile (a ~50-line static file)
// on every matched tool_call; no caches, no watchers.
//
// On match: interactive -> confirm with "Add to Brewfile first" as the safe
// default. Approving anyway appends a shorthand line to
// machine/mac/Brewfile-untracked.acked (human-readable audit trail; the
// just recipe separates acked strays from unknown ones). Headless -> hard
// block with the reason; the agent surfaces it and stops.
//
// Name matching is strict: flags (--*, *=), quoted values, and flag-style
// tokens are never treated as package names; tap-qualified names classify
// on both the full path and the bare tail.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { withPromptLock } from "./shared/gate.ts";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Kind = "formula" | "tap";

// Brewfile entry regex: brew/cask/mas entries with quoted ("x" | 'x') or
// bare names. `tap "user/repo"` handled separately by TAP_TAIL below.
// The capture is exactly the display name (bare or unquoted).
const ENTRY_RE =
	/^(?:brew|cask|mas)\s+"((?:[^"\\]|\\.)*)"|^(?:brew|cask|mas)\s+'([^']+)'|^(?:brew|cask|mas)\s+([^\s#]+)/;
const TAP_TAIL = /^tap\s+(?:"([^"]+)"|'([^']+)'|(\S+))/;

// Brew-verb regexes. Leading flags/env tolerated; verbs are word-boundary
// matched. Group 1 is the flag-laden argument tail.
const INSTALL_RE = /\bbrew(?:\s+-{1,2}\S+)*\s+(?:install|reinstall|upgrade)\s+((?:--?[\w-]+(?:=[^\s&|;]+)?\s+)*(?:[^\s&|;&]+)(?:\s+(?:--?[\w-]+(?:=[^\s&|;]+)?\s+)*(?:[^\s&|;&]+))*)/g;
const TAP_RE = /\bbrew(?:\s+-{1,2}\S+)*\s+tap\s+([^\s&|;&]+)/g;

// Read the Brewfile; return {names, taps}. Returns null for absent file so
// callers can distinguish "empty list" from "no manifest".
function parseBrewfile(path: string): { names: Set<string>; taps: Set<string> } | null {
	if (!existsSync(path)) return null;
	const names = new Set<string>();
	const taps = new Set<string>();
	for (const raw of readFileSync(path, "utf8").split("\n")) {
		const line = raw.trim();
		if (line === "" || line.startsWith("#")) continue;
		const tapM = TAP_TAIL.exec(line);
		if (tapM) {
			const t = tapM[1] ?? tapM[2] ?? tapM[3];
			if (t) taps.add(t.replace(/\.git$/, ""));
			continue;
		}
		const m = ENTRY_RE.exec(line);
		if (m) {
			const name = m[1] ?? m[2] ?? m[3];
			if (name) names.add(name);
		}
	}
	return { names, taps };
}

// Extract candidate names from a verb's argument tail. Flag tokens (any
// leading -, single or double dash) are skipped; `--` ends the run (its
// positionals belong to flags); --dry-run ends it too, because a dry run
// changes no machine state — allowing is correct whatever follows. A
// value-taking flag (--appdir=/path) is skipped, not a terminator, so a
// name after it is still classified.
function tailNames(tail: string): string[] {
	const names: string[] = [];
	for (const tok of tail.trim().split(/\s+/)) {
		if (tok === "") continue;
		if (tok === "--") break;
		if (tok.startsWith("-")) {
			if (tok === "--dry-run") break;
			continue;
		}
		names.push(tok);
	}
	return names;
}

// Classify one candidate name against the Brewfile state. Tap-qualified
// names classify on the full path first, then on the bare tail. Returns a
// gateable kind, or null when the name is clearly tracked.
function classify(
	name: string,
	state: { names: Set<string>; taps: Set<string> },
): Kind | null {
	const kind: Kind = name.includes("/") ? "tap" : "formula";
	if (state.names.has(name)) return null;
	if (name.includes("/")) {
		const tail = name.slice(name.lastIndexOf("/") + 1);
		if (state.names.has(tail)) return null;
		const slash = state.taps.has(name) || state.taps.has(tail);
		return slash ? null : "tap";
	}
	return kind;
}

const ACKED_HEADER = "## Untracked brew installs (brew-untracked gate approvals)\n";

// Silences that message: prompt-managed ack file, created on first approve.
// Format: one bare name per line, else `name: reason`.
function appendAck(dotfiles: string, name: string, reason: string): void {
	const path = `${dotfiles}/machine/mac/Brewfile-untracked.acked`;
	try {
		if (!existsSync(path)) {
			writeFileSync(path, `${ACKED_HEADER}\n${name}${reason ? `: ${reason}` : ""}\n`);
		} else {
			const has = readFileSync(path, "utf8")
				.split("\n")
				.some((l) => l.split(":")[0]?.trim() === name);
			if (!has) {
				writeFileSync(path, `\
${readFileSync(path, "utf8").trimEnd()}
${name}${reason ? `: ${reason}` : ""}

`);
			}
		}
	} catch {
		// ack file is best-effort: gate still ran on provided names
	}
}

// Block reason shown in chat when the agent (or the user) declines the
// install. Wording is the contract with `just brew-untracked`'s output.
const gateReason = (items: { name: string; kind: Kind }[]): string =>
	`Untracked Homebrew package(s) — not in machine/mac/Brewfile:\n` +
	items.map((it) => `- ${it.name} (${it.kind})`).join("\n") +
	`\n\nPreferred: add to dotfiles machine/mac/Brewfile (with a comment naming the project) and commit before installing.\n` +
	`Approving installs the package anyway and appends it to machine/mac/Brewfile-untracked.acked (audit trail read by \`just brew-untracked\`).`;

// Route a bash command to candidate names. Names come only from
// install-family and tap verbs. The bare `brew bundle` shape (no explicit
// names on the line) is handled by the caller: the Brewfile is its manifest.
function extractNames(command: string): string[] {
	const names: string[] = [];
	for (const m of command.matchAll(INSTALL_RE)) {
		names.push(...tailNames(m[1] ?? ""));
	}
	for (const m of command.matchAll(TAP_RE)) {
		names.push(...tailNames(m[1] ?? ""));
	}
	return [...new Set(names)];
}

// Acked names from machine/mac/Brewfile-untracked.acked: bare lines and
// "name: reason" lines, comments (#…) skipped. Null when file absent.
function parseAcked(path: string): string[] | null {
	if (!existsSync(path)) return null;
	const out: string[] = [];
	for (const raw of readFileSync(path, "utf8").split("\n")) {
		const line = raw.trim();
		if (line === "" || line.startsWith("#")) continue;
		const name = line.split(":")[0].trim();
		if (name) out.push(name);
	}
	return out;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event: any, ctx: any) => {
		if (event.toolName !== "bash") return;
		const command = String(event.input?.command ?? "");
		if (!/\bbrew\b/.test(command)) return;

		const dotfiles = process.env["DOTFILES"] ?? `${homedir()}/code/personal/dotfiles`;
		const state = parseBrewfile(`${dotfiles}/machine/mac/Brewfile`);
		if (!state) return; // no Brewfile -> gate cannot know tracked; let it pass

		const names = extractNames(command);
		const acked = parseAcked(`${dotfiles}/machine/mac/Brewfile-untracked.acked`);
		const gate = names
			.map((n) => ({ name: n, kind: classify(n, state) }))
			.filter(
				(it): it is { name: string; kind: Kind } =>
					it.kind !== null && !(acked ?? []).includes(it.name),
			);
		if (gate.length === 0) return; // all tracked / no names / bundle-only

		// Interactive: confirm with the safe default. Headless: block. The
		// select runs under the shared prompt-lock mutex — pi has a single
		// modal slot, so concurrent gated tool calls (this gate, linear/notion
		// confirmWrite) queue in dispatch order instead of dropping (JSK-57).
		if (!ctx.hasUI) {
			return {
				block: true,
				reason: gateReason(gate),
			};
		}
		const choice = await withPromptLock(() =>
			ctx.ui.select(
				`⚠️  Untracked brew package(s)\n\n  ${command}\n\n${gateReason(gate)}`,
				["Add to Brewfile first", "Install anyway (record in acked file)"],
			),
		);
		if (choice !== "Install anyway (record in acked file)") {
			return {
				block: true,
				reason: gateReason(gate) +
					`\n\nUser chose "${choice}". Stop and add the package(s) to dotfiles machine/mac/Brewfile (with a comment naming the project) before retrying.`,
			};
		}
		for (const it of gate) appendAck(dotfiles, it.name, "");
	});
}
