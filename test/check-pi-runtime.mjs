// Run with `just test-pi`. Uses the installed SDK, scripted model responses,
// in-memory credentials, fake effectful tools, and disposable session files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = fileURLToPath(new URL("../", import.meta.url));
let packageDir = process.env.PI_TEST_PACKAGE_DIR;
if (!packageDir) {
	const paths = execFileSync("pnpm", ["list", "-g", "--parseable"], { encoding: "utf8" });
	packageDir = paths.trim().split("\n").find((path) => path.endsWith("/node_modules/@earendil-works/pi-coding-agent"));
}
assert.ok(packageDir, "Installed Pi package not found; set PI_TEST_PACKAGE_DIR to its package directory");
const version = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8")).version;

// Failure here must not be converted into a skipped compatibility check.
test(`installed Pi ${version}: extensions, gates and lifecycle`, { timeout: 60000 }, async (t) => {
	const dir = mkdtempSync(join(tmpdir(), "pi-runtime-"));
	const cwd = join(dir, "code/personal/fixture");
	const agentDir = join(dir, "agent");
	mkdirSync(cwd, { recursive: true });
	mkdirSync(agentDir);
	mkdirSync(join(dir, "machine/mac"), { recursive: true });
	writeFileSync(join(dir, "machine/mac/Brewfile"), 'brew "git"\n');
	mkdirSync(join(dir, "bin"));
	const keychainLog = join(dir, "keychain-attempts");
	writeFileSync(join(dir, "bin/security"), '#!/bin/sh\nprintf "attempt\\n" >> "$PI_TEST_KEYCHAIN_LOG"\nexit 1\n', { mode: 0o755 });
	const envKeys = ["HOME", "PATH", "PI_OFFLINE", "PI_CODING_AGENT_DIR", "DOTFILES", "PI_ALLOW_SECRET_READ", "PI_TEST_KEYCHAIN_LOG"];
	const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
	process.env.HOME = dir;
	process.env.PATH = `${dir}/bin:${process.env.PATH}`;
	process.env.PI_TEST_KEYCHAIN_LOG = keychainLog;
	process.env.PI_OFFLINE = "1";
	process.env.PI_CODING_AGENT_DIR = agentDir;
	process.env.DOTFILES = dir;
	delete process.env.PI_ALLOW_SECRET_READ;
	let networkAttempts = 0;
	const originalFetch = globalThis.fetch;
	globalThis.fetch = async () => { networkAttempts++; throw new Error("Network is forbidden in runtime tests"); };
	const sessions = [];
	t.after(() => {
		for (const session of sessions) session.dispose();
		globalThis.fetch = originalFetch;
		for (const [key, value] of Object.entries(originalEnv)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		rmSync(dir, { recursive: true, force: true });
	});

	const sdk = await import(pathToFileURL(join(packageDir, "dist/index.js")));
	const runtime = await sdk.ModelRuntime.create({
		credentials: { read: async () => undefined, list: async () => [] },
		modelsPath: null, modelsStorePath: join(dir, "catalog.json"),
		allowModelNetwork: false, refreshOnCreate: false,
	});
	runtime.registerProvider("pi-fixture", {
		baseUrl: "http://127.0.0.1:1", api: "openai-completions", apiKey: "fixture-not-a-credential",
		models: ["one", "two"].map((id) => ({ id, name: id, reasoning: false, input: ["text"], contextWindow: 100000, maxTokens: 1000,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } })),
	});
	const model = runtime.getModel("pi-fixture", "one");
	assert.ok(model);
	const settings = sdk.SettingsManager.inMemory({
		defaultTools: ["+codemode"], cacheWarming: "off", retry: { enabled: false },
		compaction: { enabled: false, keepRecentTokens: 0, reserveTokens: 1000 },
	});
	const paths = readdirSync(join(repo, "pi/agent/extensions"))
		.filter((name) => name.endsWith(".ts") && !name.endsWith(".d.ts"))
		.map((name) => join(repo, "pi/agent/extensions", name));
	assert.equal(paths.length, 7);
	let effects = [];
	const customTools = ["bash", "read"].map((name) => ({
		name, label: name, description: `Records ${name}; never executes shell commands or reads files`,
		parameters: { type: "object", properties: { [name === "bash" ? "command" : "path"]: { type: "string" } }, required: [name === "bash" ? "command" : "path"] },
		async execute(_id, params, _signal, _onUpdate, ctx) {
			effects.push({ name, params, cwd: ctx.cwd });
			return { content: [{ type: "text", text: "fixture effect" }], details: {} };
		},
	}));
	const errors = [];
	async function open(manager) {
		const loader = new sdk.DefaultResourceLoader({
			cwd, agentDir, settingsManager: settings,
			noExtensions: true, additionalExtensionPaths: paths,
			noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
			extensionFactories: [sdk.createCodemodeExtension({ models: false }), (pi) => {
				pi.on("session_before_compact", (event) => ({ compaction: {
					summary: "Offline fixture summary", firstKeptEntryId: event.preparation.firstKeptEntryId,
					tokensBefore: event.preparation.tokensBefore,
				} }));
			}],
		});
		await loader.reload();
		assert.deepEqual(loader.getExtensions().errors, [], "all extension factories must load");
		const loaded = loader.getExtensions().extensions.map((extension) => extension.path);
		for (const path of paths) assert.ok(loaded.includes(path), `factory loaded: ${path}`);
		const { session } = await sdk.createAgentSession({ cwd, agentDir, modelRuntime: runtime, model, thinkingLevel: "off",
			settingsManager: settings, resourceLoader: loader, sessionManager: manager, customTools });
		sessions.push(session);
		await session.bindExtensions({ mode: "print", onError: (error) => errors.push(error) });
		return session;
	}
	let session = await open(sdk.SessionManager.create(cwd, join(dir, "sessions")));
	let counter = 0;
	async function run(calls) {
		effects = [];
		const messages = [calls, null];
		session.agent.streamFunction = () => {
			assert.ok(messages.length > 0, "unexpected model request");
			const next = messages.shift();
			const message = {
				role: "assistant", api: "openai-completions", provider: "pi-fixture", model: session.model.id,
				content: next ? next.map(([name, args]) => ({ type: "toolCall", id: `fixture-${++counter}`, name, arguments: args })) : [{ type: "text", text: "done" }],
				stopReason: next ? "toolUse" : "stop", timestamp: Date.now(),
				usage: { input: 10, output: 10, cacheRead: 0, cacheWrite: 0, totalTokens: 20,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			};
			return { async *[Symbol.asyncIterator]() { yield { type: "done", reason: message.stopReason, message }; }, result: async () => message };
		};
		const before = session.messages.length;
		await session.prompt("Execute the scripted fixture calls", { expandPromptTemplates: false });
		assert.equal(messages.length, 0);
		return session.messages.slice(before).filter((message) => message.role === "toolResult");
	}
	const blocked = [
		["bash", { command: "git push --force origin main" }],
		["read", { path: "/fixture/.env" }],
		["linear", { action: "create_issue", team_key: "JSK", title: "fixture" }],
		["notion", { action: "update_page", page_id: "fixture", properties: "{}" }],
	];
	async function assertGates() {
		const results = await run(blocked);
		assert.equal(results.length, blocked.length);
		for (const result of results) {
			assert.equal(result.isError, true, `${result.toolName}: ${JSON.stringify(result.content)}`);
			assert.match(JSON.stringify(result.content), /no UI|without a UI/i);
			assert.doesNotMatch(JSON.stringify(result.content), /Ambiguous cwd|API key|Unknown action/);
		}
		assert.deepEqual(effects, [], "blocked tools must never execute");
	}
	await t.test("headless direct calls block before effects or credentials; fifth callback argument routes personal", assertGates);
	await t.test("allowed call executes through the pipeline with the correct cwd", async () => {
		const results = await run([["read", { path: "/fixture/README.md" }]]);
		assert.equal(results[0].isError, false);
		assert.deepEqual(effects, [{ name: "read", params: { path: "/fixture/README.md" }, cwd }]);
	});
	const withBrew = [...blocked, ["bash", { command: "brew install pi-runtime-untracked-fixture" }]];
	await t.test("untracked brew blocks headless before shell execution", async () => {
		const [result] = await run([withBrew.at(-1)]);
		assert.equal(result.isError, true);
		assert.match(JSON.stringify(result.content), /Untracked Homebrew/);
		assert.deepEqual(effects, []);
	});
	await t.test("codemode nested calls reach every gate and record nested calls", async () => {
		const code = `return await Promise.allSettled(${JSON.stringify(withBrew)}.map(([name, args]) => tools[name](args)));`;
		const [result] = await run([["codemode", { code }]]);
		const output = JSON.stringify(result.content);
		assert.match(output, /Script completed/);
		assert.equal((output.match(/rejected/g) ?? []).length, withBrew.length, output);
		assert.deepEqual(effects, []);
		assert.equal(result.nestedCalls.calls.length, withBrew.length);
	});
	await t.test("mixed interactive cancellations serialize and never execute", async (st) => {
		let active = 0;
		let maximum = 0;
		let prompts = 0;
		const timeline = [];
		const headless = session;
		session = await open(sdk.SessionManager.inMemory(cwd));
		const interactive = session;
		st.after(() => {
			interactive.dispose();
			session = headless;
		});
		await session.bindExtensions({ mode: "tui", onError: (error) => errors.push(error), uiContext: {
			async select(title) {
				prompts++; active++; maximum = Math.max(maximum, active);
				timeline.push(`enter: ${title.split("\n")[0]}`);
				await new Promise((resolve) => setTimeout(resolve, 10));
				timeline.push(`exit: ${title.split("\n")[0]}`);
				active--; return undefined;
			}, notify() {},
		} });
		const results = await run(withBrew);
		assert.equal(results.length, withBrew.length);
		assert.ok(results.every((result) => result.isError));
		assert.equal(prompts, withBrew.length);
		assert.equal(maximum, 1, `Pi has one modal slot, including different gates: ${timeline.join("; ")}`);
		assert.deepEqual(effects, []);
	});
	await t.test("gates survive reload, model change, compaction and persisted resume", async () => {
		await session.reload();
		await assertGates();
		await session.setModel(runtime.getModel("pi-fixture", "two"));
		await assertGates();
		const result = await session.compact();
		assert.equal(result.summary, "Offline fixture summary");
		await assertGates();
		const file = session.sessionManager.getSessionFile();
		assert.ok(file);
		session.dispose();
		session = await open(sdk.SessionManager.open(file));
		await assertGates();
	});
	assert.deepEqual(errors, [], "extension errors must not silently disable gates");
	assert.equal(networkAttempts, 0, "no test should attempt outbound requests");
	assert.equal(existsSync(keychainLog), false, "gated tools must not even attempt credential lookup");
});
