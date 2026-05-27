// Node unit test for confirmWrite() concurrency serialization. JSK-57.
// Run from repo root: node --test pi/agent/extensions/shared/gate.test.mjs
//
// Reproduces the "10 concurrent gated calls, only the last one's prompt
// surfaces" failure mode at the shared/gate.ts layer by mocking ctx.ui.
// Node 26+ resolves .ts imports natively, so we exercise the real gate.

import { test } from "node:test";
import assert from "node:assert/strict";
import { confirmWrite, __resetPromptMutexForTest } from "./gate.ts";

// Drive ctx.ui.select with a controlled async delay and record entry/exit
// timestamps so we can assert non-overlap.
function makeCtx({ selectAnswer, selectDelayMs = 10, recorder }) {
	let inFlight = 0;
	return {
		hasUI: true,
		ui: {
			async select(_title, _items) {
				inFlight++;
				if (inFlight > 1) recorder.overlap = true;
				recorder.events.push({ kind: "enter", t: Date.now() });
				await new Promise((r) => setTimeout(r, selectDelayMs));
				recorder.events.push({ kind: "exit", t: Date.now() });
				inFlight--;
				return selectAnswer;
			},
			async input() {
				return undefined; // unused in these cases
			},
		},
	};
}

test("concurrent confirmWrite calls run strictly serially", async () => {
	__resetPromptMutexForTest();
	const recorder = { events: [], overlap: false };
	const ctx = makeCtx({ selectAnswer: "create_issue", selectDelayMs: 20, recorder });

	const N = 10;
	const results = await Promise.all(
		Array.from({ length: N }, (_, i) =>
			confirmWrite(ctx, "linear", "create_issue", { title: `t${i}` }, "Personal"),
		),
	);

	// All resolved with allow: true (the user picked the action label).
	assert.equal(results.length, N);
	for (const r of results) assert.deepEqual(r, { allow: true });

	// No two prompts overlapped — the heart of the JSK-57 fix.
	assert.equal(recorder.overlap, false, "ctx.ui.select calls overlapped");

	// Stronger check: events alternate enter/exit, no two enters back-to-back.
	for (let i = 0; i < recorder.events.length; i++) {
		const expected = i % 2 === 0 ? "enter" : "exit";
		assert.equal(recorder.events[i].kind, expected, `event ${i} order`);
	}
});

test("cancellation in one call does not stall the queue", async () => {
	__resetPromptMutexForTest();
	const recorder = { events: [], overlap: false };
	// First call cancels (returns undefined), subsequent calls must still proceed.
	const ctx = {
		hasUI: true,
		ui: {
			callCount: 0,
			async select(_title, _items) {
				this.callCount++;
				recorder.events.push({ kind: "enter", n: this.callCount });
				await new Promise((r) => setTimeout(r, 5));
				recorder.events.push({ kind: "exit", n: this.callCount });
				return this.callCount === 1 ? undefined : "create_issue";
			},
			async input() {
				return undefined;
			},
		},
	};

	const [r1, r2, r3] = await Promise.all([
		confirmWrite(ctx, "linear", "create_issue", {}, "Personal"),
		confirmWrite(ctx, "linear", "create_issue", {}, "Personal"),
		confirmWrite(ctx, "linear", "create_issue", {}, "Personal"),
	]);

	assert.equal(r1.allow, false);
	assert.match(r1.reason, /cancelled/i);
	assert.equal(r2.allow, true);
	assert.equal(r3.allow, true);

	// Three prompts ran; no overlap.
	const enters = recorder.events.filter((e) => e.kind === "enter").length;
	assert.equal(enters, 3);
});

test("a throwing prompt releases the lock for subsequent calls", async () => {
	__resetPromptMutexForTest();
	let calls = 0;
	const ctx = {
		hasUI: true,
		ui: {
			async select() {
				calls++;
				if (calls === 1) throw new Error("boom");
				return "create_issue";
			},
			async input() {
				return undefined;
			},
		},
	};

	const results = await Promise.allSettled([
		confirmWrite(ctx, "linear", "create_issue", {}, "Personal"),
		confirmWrite(ctx, "linear", "create_issue", {}, "Personal"),
	]);

	assert.equal(results[0].status, "rejected");
	assert.equal(results[1].status, "fulfilled");
	assert.deepEqual(results[1].value, { allow: true });
});

test("headless ctx (!hasUI) does not acquire the lock", async () => {
	__resetPromptMutexForTest();
	// Stage 1: a slow gated call holding the lock.
	const recorder = { events: [], overlap: false };
	const slowCtx = makeCtx({ selectAnswer: "create_issue", selectDelayMs: 50, recorder });
	const slowPromise = confirmWrite(slowCtx, "linear", "create_issue", {}, "Personal");

	// Stage 2: a headless call issued concurrently — should resolve immediately
	// without waiting for the slow one.
	const headlessCtx = { hasUI: false, ui: { select: async () => {}, input: async () => {} } };
	const t0 = Date.now();
	const headless = await confirmWrite(
		headlessCtx,
		"linear",
		"create_issue",
		{},
		"Personal",
	);
	const dtHeadless = Date.now() - t0;

	assert.equal(headless.allow, false);
	assert.match(headless.reason, /interactive confirmation/);
	assert.ok(dtHeadless < 25, `headless should not block on lock (took ${dtHeadless}ms)`);

	// Cleanup: let the slow call finish.
	await slowPromise;
});
