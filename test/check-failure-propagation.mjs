import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = fileURLToPath(new URL("../", import.meta.url));

function fixture(t) {
	const dir = mkdtempSync(join(tmpdir(), "failure-propagation-"));
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	mkdirSync(join(dir, "bin"));
	return dir;
}

test("delegate preserves success, errors, truncation and timeout statuses with partial output", (t) => {
	const dir = fixture(t);
	mkdirSync(join(dir, "results"));
	writeFileSync(join(dir, "prompt.txt"), "fixture prompt");
	writeFileSync(join(dir, "bin/pi"), '#!/bin/bash\nprintf "partial answer\\n"\nprintf "fixture warning\\n" >&2\nexit "$FIXTURE_EXIT"\n', { mode: 0o755 });
	for (const status of [0, 1, 7, 124, 137]) {
		const task = `exit-${status}`;
		const result = spawnSync("bash", [join(repo, "pi/agent/skills/delegate/scripts/dispatch.sh"), task, dir, "0", join(dir, "prompt.txt"), join(dir, "results")], {
			env: { ...process.env, PATH: `${dir}/bin:${process.env.PATH}`, FIXTURE_EXIT: String(status), DELEGATE_ASSUME_TTY: "0" },
			encoding: "utf8", timeout: 10000,
		});
		assert.equal(result.status, status, `child=${status}: ${result.stdout}\n${result.stderr}`);
		assert.equal(readFileSync(join(dir, `results/${task}.exit`), "utf8").trim(), String(status));
		const output = readFileSync(join(dir, `results/${task}.md`), "utf8");
		assert.match(output, /partial answer/);
		assert.match(output, /fixture warning/);
	}
});

test("delegate test runner returns failure and still runs later files", (t) => {
	const dir = fixture(t);
	writeFileSync(join(dir, "run.sh"), readFileSync(join(repo, "pi/agent/skills/delegate/tests/run.sh")));
	writeFileSync(join(dir, "a.test.sh"), "#!/bin/bash\nexit 7\n", { mode: 0o755 });
	writeFileSync(join(dir, "b.test.sh"), '#!/bin/bash\nprintf "later file ran\\n"\n', { mode: 0o755 });
	const result = spawnSync("bash", [join(dir, "run.sh")], { encoding: "utf8" });
	assert.equal(result.status, 7, result.stdout + result.stderr);
	assert.match(result.stdout, /later file ran/);
	assert.match(result.stdout, /failed: a.test.sh/);
});

for (const failing of ["none", "tsc", "node"]) {
	test(`just check propagates ${failing} failure`, (t) => {
		const dir = fixture(t);
		mkdirSync(join(dir, "test"));
		mkdirSync(join(dir, "pi/agent/extensions"), { recursive: true });
		for (const name of readdirSync(join(repo, "test")).filter((name) => name.endsWith(".sh"))) {
			writeFileSync(join(dir, "test", name), "exit 0\n");
		}
		for (const name of ["tsc", "node", "brew"]) {
			writeFileSync(join(dir, "bin", name), `#!/bin/bash\nif [ "$FIXTURE_FAIL" = "${name}" ]; then echo "injected ${name} failure" >&2; exit 7; fi\nexit 0\n`, { mode: 0o755 });
		}
		const result = spawnSync("just", ["--justfile", join(repo, "justfile"), `DOTFILES=${dir}`, "check"], {
			env: { ...process.env, PATH: `${dir}/bin:${process.env.PATH}`, FIXTURE_FAIL: failing },
			encoding: "utf8", timeout: 15000,
		});
		assert.equal(result.status, failing === "none" ? 0 : 7, result.stdout + result.stderr);
		if (failing !== "none") {
			assert.match(result.stderr, new RegExp(`injected ${failing} failure`));
			assert.doesNotMatch(result.stdout, /untracked-brew gate:/, "check must stop at the failed stage");
		}
	});
}
