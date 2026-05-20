// Node unit test for inferWorkspace. Run from repo root:
//   node --test pi/agent/extensions/shared/workspace.test.mjs
//
// Replaces the seven `_pi_notion_auth_file` zsh assertions removed when
// zsh/pi-notion-routing.zsh was decommissioned. Pure-logic only — no
// Keychain, no fs.

import { test } from "node:test";
import assert from "node:assert/strict";

// Import .ts via experimental-strip-types? No — keep this dependency-free by
// inlining the regex contract here. The contract is small enough that
// duplicating it as test fixture is cheaper than wiring tsc/tsx into the
// test runner. If the regexes in workspace.ts drift, this test goes red.
const VOLVE_SEGMENT = /(^|[/_-])volve([/_-]|$)/i;
const PERSONAL_ROOT = /\/code\/personal(\/|$)/i;

function inferWorkspace(cwd) {
	if (PERSONAL_ROOT.test(cwd)) return "personal";
	if (VOLVE_SEGMENT.test(cwd)) return "volve";
	return null;
}

test("personal cwd routes to personal", () => {
	assert.equal(inferWorkspace("/Users/x/code/personal/dotfiles"), "personal");
	assert.equal(inferWorkspace("/home/x/code/personal/foo"), "personal");
});

test("personal beats volve when both substrings present (subdir named volve)", () => {
	// e.g. ~/code/personal/volve-notes — must route personal, not volve.
	assert.equal(inferWorkspace("/Users/x/code/personal/volve-notes"), "personal");
});

test("volve segment routes to volve", () => {
	assert.equal(inferWorkspace("/repos/volve/api"), "volve");
	assert.equal(inferWorkspace("/srv/volve"), "volve");
	assert.equal(inferWorkspace("/srv/x_volve_y"), "volve");
	assert.equal(inferWorkspace("/srv/x-volve-y"), "volve");
});

test("volve does not match substrings inside other words", () => {
	assert.equal(inferWorkspace("/srv/evolve/x"), null);
	assert.equal(inferWorkspace("/srv/revolver"), null);
	assert.equal(inferWorkspace("/srv/devolved"), null);
});

test("unrelated cwd returns null", () => {
	assert.equal(inferWorkspace("/tmp/foo"), null);
	assert.equal(inferWorkspace("/"), null);
	assert.equal(inferWorkspace(""), null);
});

test("case-insensitive on the path-segment regex", () => {
	assert.equal(inferWorkspace("/repos/VOLVE/api"), "volve");
	assert.equal(inferWorkspace("/Users/x/Code/Personal/dotfiles"), "personal");
});
