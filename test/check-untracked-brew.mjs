// Integration test for pi/agent/extensions/untracked-brew.ts. Runs the
// registered tool_call handler directly against a temp-DOTFILES fixture —
// no pi harness needed. Pattern sibling: test/check-destructive-gate.sh.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "untracked-brew-"));
mkdirSync(join(dir, "machine", "mac"), { recursive: true });
writeFileSync(
	join(dir, "machine", "mac", "Brewfile"),
	['brew "git"', 'cask "ghostty"', 'tap "electrikmilk/cherri"', 'brew "cherri"'].join("\n") + "\n",
);
process.env.DOTFILES = dir;

const mod = await import("../pi/agent/extensions/untracked-brew.ts");
let handler;
mod.default({ on: (ev, fn) => { handler = fn; } });
const noUI = { hasUI: false };
const blocked = (r) => r?.block === true;

const BLOCK = [
	["formula", "brew install mkcert"],
	["cask", "brew install --cask slack"],
	["tap", "brew tap foo/bar"],
	["tap-qualified", "brew install other/tool"],
	["upgrade", "brew upgrade mkcert"],
	["reinstall", "brew reinstall mkcert"],
	["multi", "brew install git mkcert"],
	["flag-skip", "brew install -v mkcert"],
	["value-flag then name", "brew install --cask --appdir=/tmp/x firefox"],
	["env-prefix", "HOMEBREW_NO_AUTO_UPDATE=1 brew install mkcert"],
	["compound", "cd /tmp && brew install mkcert && ls"],
];
test("untracked installs block headless, with the name in the reason", async () => {
	for (const [label, cmd] of BLOCK) {
		const r = await handler({ toolName: "bash", input: { command: cmd } }, noUI);
		assert.equal(r?.block, true, `${label}: ${cmd} should block`);
		assert.ok(r.reason.includes("machine/mac/Brewfile"), `${label} reason`);
	}
});

test("tracked names, flag-only verbs, non-brew commands allow", async () => {
	const ALLOW = [
		["tracked formula", "brew install git"],
		["short-flag tracked only", "brew install -v git"],
		["tracked cask", "brew install --cask ghostty"],
		["tracked tap", "brew tap electrikmilk/cherri"],
		["tap-qualified tracked", "brew install electrikmilk/cherri"],
		["upgrade tracked", "brew upgrade git"],
		["flag-only upgrade", "brew upgrade --dry-run"],
		["bare bundle", "brew bundle"],
		["bundle --file", "brew bundle --file=machine/mac/Brewfile"],
		["no brew verb", "brew list"],
		["non-brew", "git push origin main"],
		["empty args", "brew"],
		["verb only", "brew install"],
	];
	for (const [label, cmd] of ALLOW) {
		const r = await handler({ toolName: "bash", input: { command: cmd } }, noUI);
		assert.equal(r, undefined, `${label}: ${cmd} should allow`);
	}
});

test("acked names allow without prompt; ack file records approvals", async () => {
	const ackedPath = join(dir, "machine", "mac", "Brewfile-untracked.acked");
	let prompted = 0;
	const ui = { hasUI: true, ui: { select: async (t, opts) => { prompted++; return opts[1]; } } };
	// approve mkcert via interactive select
	const r1 = await handler({ toolName: "bash", input: { command: "brew install mkcert" } }, ui);
	assert.equal(r1, undefined, "approve -> allow");
	assert.equal(prompted, 1, "one prompt");
	assert.ok(readFileSync(ackedPath, "utf8").includes("mkcert"), "acked file records name");
	// second install of the acked name: allowed, and select must NOT fire
	const spy = { hasUI: true, ui: { select: async () => { throw new Error("prompted again"); } } };
	const r2 = await handler({ toolName: "bash", input: { command: "brew install mkcert" } }, spy);
	assert.equal(r2, undefined, "acked -> allow, no prompt");
	// mixed command where one name is tracked and the other acked
	const r3 = await handler({ toolName: "bash", input: { command: "brew install git mkcert" } }, spy);
	assert.equal(r3, undefined, "tracked + acked -> allow, no prompt");
});

test("Add-to-Brewfile-first choice blocks with guidance", async () => {
	const r = await handler(
		{ toolName: "bash", input: { command: "brew install wget2" } },
		{ hasUI: true, ui: { select: async (t, opts) => opts[0] } },
	);
	assert.equal(blocked(r), true, "safe default blocks");
	assert.ok(r.reason.includes("Add to"), "guidance present");
});

test("no Brewfile -> gate stands down", async () => {
	const backup = process.env.DOTFILES;
	process.env.DOTFILES = join(tmpdir(), "untracked-brew-nonexistent");
	const r = await handler({ toolName: "bash", input: { command: "brew install mkcert" } }, noUI);
	process.env.DOTFILES = backup;
	assert.equal(r, undefined, "no manifest -> allow");
});
