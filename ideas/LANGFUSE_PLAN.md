# Langfuse + Claude Code Feedback Pipeline — Implementation Plan

Self-host Langfuse on a persistent Linux host, forward Claude Code transcripts via a Stop hook, and capture free-text per-turn feedback via a `UserPromptSubmit` hook. Feedback is logged verbatim (for LLM analysis) and paired with a coarse numeric score (for Langfuse UI filtering). Everything bootstrapped from this dotfiles repo.

---

## Decisions (confirmed 2026-04-23)

1. **Hosting target: existing Oracle VM (`ssh oracle`).** Ubuntu 22.04 aarch64, 24 GB RAM, 121 GB free disk, Docker 29 + Compose v5 already installed. Capacity concerns in P1.A do not apply — the instance is live and reclamation-proof (already non-idle). P1.B (Hetzner) and most of P1.C become irrelevant; keep for historical context only.
2. **Network: Cloudflare Tunnel + Cloudflare Access (email OTP).** No public IP, no inbound ports opened.
3. **Feedback marker: free-form `!<token>`.** Any line containing `!` followed by at least one non-whitespace character is a feedback marker. Everything from the `!` up to the next whitespace/newline is captured verbatim as the tag payload. No mandatory score, no schema. See P4.C for hook semantics — **Option A wins, not Option B.** Numeric score at capture time is dropped; optional LLM-inferred score can be layered in P5 if ever needed.
4. **Sanitization: none.** This is personal ad-hoc logging for retrospective analysis. Secrets you paste or that tools echo will appear verbatim in the Langfuse instance, which lives on your own VM behind Cloudflare Access. Do not use this setup for shared / production / customer-data flows. P6.A is skipped entirely.
5. **Retention: unlimited.** No TTL. ClickHouse disk is 121 GB; revisit only if disk pressure appears. P6.C reduces to "do nothing" — leave Langfuse project settings at default.

---

## P0 — Prerequisites

**Goal.** Accounts, keys, and local tooling present before touching dotfiles.

**Steps.**
- Create Cloudflare account if absent; verify one owned domain is on CF nameservers. Note the zone name (say `example.dev`) — subdomain plan: `langfuse.example.dev`.
- On host target (Hetzner/OCI/whatever was chosen): Ubuntu 24.04 LTS (or Oracle Linux 9) ARM or AMD; Docker + docker-compose-plugin installed; swap enabled (≥2 GB) if RAM ≤4 GB.
- Install `cloudflared` locally on the host: [install docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).
- Generate three secrets on the laptop, paste into password manager:
  - `NEXTAUTH_SECRET = $(openssl rand -base64 32)`
  - `SALT = $(openssl rand -base64 32)`
  - `ENCRYPTION_KEY = $(openssl rand -hex 32)`  *(must be 64 hex chars per [Langfuse config docs](https://langfuse.com/self-hosting/configuration))*
- Decide feedback marker (P4.C), confirm with yourself, log the choice in a comment at the top of `claude/hooks/outcome_tag.py`.

**Verify.** `docker compose version` ≥ v2 on host; `cloudflared --version` present; DNS for chosen hostname not yet pointed (tunnel will create the CNAME).

**Rollback.** None — no changes to dotfiles yet.

---

## P1 — Host selection and infrastructure

> **Confirmed: use existing `ssh oracle` instance** (24 GB RAM, 121 GB free, Docker + Compose installed, aarch64 Ubuntu 22.04). Skip this section in execution. The analysis below is retained as context for any future re-host decision.

### P1.A — Why not Oracle Cloud Free Tier (for this workload)

Ampere A1.Flex free allocation is **4 OCPU / 24 GB RAM / 200 GB block** (documented; Oracle's main FAQ page returned 403 to automated fetch, numbers are from prior research and widely reported). That easily fits Langfuse's stated minimum of "4 cores, 16 GiB" per [self-host docs](https://langfuse.com/self-hosting/docker-compose).

**But:**
- **Capacity is the problem, not spec.** A1 capacity in EU/US regions has been intermittently unavailable since 2022. Expect "Out of host capacity" errors; workaround is a loop script that retries `LaunchInstance` every few minutes. Basis: recurring community reports, well-documented on r/oraclecloud and Oracle forums. Not a blocker, but not 30-minute setup either.
- **Reclamation risk.** Always-Free instances that sit idle (low CPU/network) can be reclaimed. Langfuse's ClickHouse + web will keep it non-idle, but this is a live risk per Oracle's 2023 policy update.
- **Network cost.** Free egress is 10 TB/month — fine for this use case.

**Verdict.** If you already have an A1 running and happy, use it. If starting fresh, Hetzner CX22 at €4.51/mo is less total time cost than fighting A1 provisioning.

### P1.B — Recommended: Hetzner VM

- Shape: **CX22** (2 vCPU AMD, 4 GB RAM, 40 GB NVMe, 20 TB egress) — €4.51/mo.
- OS: Ubuntu 24.04 LTS.
- Region: closest to you (likely Nuremberg/Falkenstein or Helsinki).
- Add 2 GB swap (`fallocate /swapfile …`) — ClickHouse is memory-hungry, 4 GB base will be tight with Postgres + Redis + MinIO + web colocated.
- Open firewall: only port 22 (SSH from your IP); tunnel handles everything else.

**If 4 GB is too tight** (watch with `docker stats` after a week of real use): upgrade to CX32 (4 vCPU / 8 GB, €6.82/mo). No other changes needed.

### P1.C — Fallback options (ordered by realism)

| Option | Cost | Pros | Cons |
|---|---|---|---|
| Hetzner CX22 | €4.51/mo | Cheap, reliable, fast | Need new account |
| Oracle A1 free | €0 | Free, beefy spec | Capacity fight, idle-reclamation |
| Raspberry Pi 5 (8 GB) | €0 (if owned) | On-prem, ARM | Needs reliable power/net at home; ClickHouse on SD card is painful — use USB SSD |
| Docker Desktop on mac | €0 | Zero infra | Only traces while laptop is on and Docker is running — defeats "durable log" |
| Langfuse Cloud Hobby | €0 | Zero ops | Data leaves your network |

---

## P2 — Deploy Langfuse via docker-compose

**Goal.** Langfuse web reachable on `http://localhost:3000` of the host; data persists across restarts.

**Prerequisites.** P1 host provisioned, Docker installed, P0 secrets generated.

**Steps.**
1. On the host, clone the compose file from upstream reference rather than copying into dotfiles — upstream is the source of truth:
   ```
   git clone --depth 1 https://github.com/langfuse/langfuse /opt/langfuse
   cd /opt/langfuse
   ```
   File to use: `docker-compose.yml` at repo root. Services per [self-host docs](https://langfuse.com/self-hosting/docker-compose): `langfuse-web`, `langfuse-worker`, `postgres`, `clickhouse`, `redis`, `minio`.
2. Override **only** the secret env vars via a sibling `docker-compose.override.yml` tracked in dotfiles (see P3). Do not edit the upstream file; that makes `git pull` updates painful.
3. Persistent volumes — the upstream compose already names these. Confirm they're named volumes not anonymous:
   - `langfuse_postgres_data`
   - `langfuse_clickhouse_data`, `langfuse_clickhouse_logs`
   - `langfuse_minio_data`
4. Bring up: `docker compose up -d`. First start pulls ~2 GB of images and runs migrations; expect 2-3 min.
5. Watch: `docker compose logs -f langfuse-web` — wait for "Ready on port 3000".

**Verify.** `curl -sI http://localhost:3000 | head -1` returns `200`. Open the web UI via SSH port-forward (`ssh -L 3000:localhost:3000 host`) while tunnel is not yet set up. Create an admin user + project. Copy the project public key (`pk-lf-*`) and secret key (`sk-lf-*`) to password manager.

**Rollback.** `docker compose down -v` wipes all data. Host reimage is the next level up.

---

## P3 — Bootstrap via dotfiles

**Goal.** Langfuse override compose file and env template live in the repo; `just langfuse-up` / `just langfuse-down` work from any host with ssh config for the Langfuse VM.

**Decision: directory.** Create `services/langfuse/` at repo root. Rationale: not mac-specific, not vm-specific (VM dir is the host's own dotfiles, not remote services). Future "self-hosted X" adds `services/x/`.

**Files to create.**
- `services/langfuse/docker-compose.override.yml` — only the env overrides and any resource limits; does NOT duplicate upstream service definitions. ~30 lines.
- `services/langfuse/.env.example` — every env var needed, with placeholders. Committed.
- `services/langfuse/.env` — real secrets; gitignored. Symlinked/copied to the host out-of-band.
- `services/langfuse/README.md` — one-page setup notes (host target, how to ssh, how to update).

**Justfile additions.**
```
LANGFUSE_HOST := "langfuse-vm"  # ssh config alias
```
- `langfuse-up` — ssh to host, `cd /opt/langfuse && docker compose up -d`.
- `langfuse-down` — same, `down`.
- `langfuse-logs` — `docker compose logs -f --tail=100`.
- `langfuse-update` — ssh host, `cd /opt/langfuse && git pull && docker compose pull && docker compose up -d`.
- `langfuse-backup` — trigger the backup script described in P7.

**Env var convention.** Laptop-side (`~/.claude/settings.json`) needs `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `TRACE_TO_LANGFUSE`. Host-side (`/opt/langfuse/.env`) needs the full set from [Langfuse configuration docs](https://langfuse.com/self-hosting/configuration): `NEXTAUTH_SECRET`, `NEXTAUTH_URL` (the public tunnel URL), `SALT`, `ENCRYPTION_KEY`, `DATABASE_URL`, `CLICKHOUSE_URL`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `REDIS_CONNECTION_STRING`, S3/MinIO triplet for each of event-upload, batch-export, media-upload buckets.

**Verify.** From laptop: `just langfuse-logs` streams remote logs. `just langfuse-update` is a no-op on the second run.

**Rollback.** Delete `services/langfuse/`, revert justfile diff. Host state untouched.

---

## P4 — Claude Code hooks

### P4.A — Stop hook: `claude/hooks/langfuse_hook.py`

**Port from [`doneyli/claude-code-langfuse-template`](https://github.com/doneyli/claude-code-langfuse-template) (`hooks/langfuse_hook.py`).** Per the template overview: reads `~/.claude/projects/<project>/<session>.jsonl`, tracks last-seen offset in a state file, groups new messages into turns, pushes each turn as a Langfuse trace with nested spans for tool calls.

**Modifications to make:**
- State file path: `~/.claude/state/langfuse_cursor.json` (create `~/.claude/state/` if missing). Template uses a less predictable path — pin ours.
- Env var names: keep template's (`TRACE_TO_LANGFUSE`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `LANGFUSE_HOST`). These are standard Langfuse SDK vars.
- Add sanitization pass (P6) before sending any message content. Apply to `input`, `output`, and all tool-call args/results.
- Read optional `~/.claude/state/pending_outcome.json` (written by the `UserPromptSubmit` hook on the *next* turn — see P4.B). If present and its `session_id` matches the current session, attach its contents to the **previous** trace being flushed, then `os.unlink` it.
- Early-exit (silent, rc=0) if `TRACE_TO_LANGFUSE != "true"` — gate for disabling without editing settings.
- Early-exit if `LANGFUSE_HOST` unreachable (connect-timeout 2s). Never block the Claude main loop on a failed trace send.

**Dependency.** `langfuse` Python SDK. Install on mac via `uv tool install langfuse` or pin a venv at `~/.claude/hooks/.venv/`. Hook shebang points to that venv python.

### P4.B — UserPromptSubmit hook: `claude/hooks/outcome_tag.py`

**Why deferred.** The obvious design ("tag the current turn") is wrong — at `UserPromptSubmit` time the previous assistant turn hasn't fully landed in the transcript yet, and the Stop hook for that turn may have already fired. The feedback the user types now is feedback on the *previous* assistant turn.

**Flow.**
1. Read stdin (Claude passes the prompt payload as JSON). Extract `prompt` text.
2. Parse feedback marker (P4.C). If no marker present, rc=0 silently.
3. Write `~/.claude/state/pending_outcome.json`: `{session_id, previous_turn_id_hint, score, tags, comment, raw_marker, timestamp}`. `previous_turn_id_hint` is the best-effort identifier the Stop hook will use to match — session-id + sequence-number is sufficient given we always attach to "the most recent trace in this session".
4. **Strip the marker from the prompt before it reaches Claude.** Hook returns JSON on stdout with a modified `prompt` field — this is the documented `UserPromptSubmit` contract in Claude Code hooks. Verify the exact return shape by running `claude --help hooks` on the current Claude version before finalising.
5. Stop hook on the *next* assistant turn consumes the file and attaches score/tags/comment to the trace it's about to flush (or, if it flushes *before* the next user prompt — which is the normal order — attaches on the following run by reading `pending_outcome.json` with a `target_trace_id` that was recorded at Stop time).

**State file schema.**
```json
{
  "session_id": "abc123",
  "target_trace_id": "trace-xyz",
  "score": 4,
  "tags": ["too-verbose", "correct"],
  "comment": "correct answer but three paragraphs where one would do",
  "raw_marker": "!fb 4 too-verbose correct \"correct answer but three paragraphs where one would do\"",
  "created_at": "2026-04-23T10:00:00Z"
}
```

### P4.C — Feedback marker syntax (the interesting design decision)

**Requirement recap.**
- Free-text feedback, verbatim to Langfuse.
- Coarse numeric score for filtering.
- LLM-parseable later for pattern mining.
- Low ceremony — single-line typed at end of a prompt.

**Option A — Free-form, sentinel-prefixed.**
Syntax: `!! <anything>` at the start of any line.
Score: inferred post-hoc by an LLM pass (see P5) — not stored at capture time, or a zero-cost placeholder `score=0` is stored.
Pros: zero friction, user never thinks about schema, verbatim-by-construction.
Cons: no score at capture time means Langfuse UI sort-by-score is empty until the batch job runs. Makes "last week's worst turns" a two-step query. Also: LLM inference of score is cost + latency.

**Option B — Structured, positional.** *(recommended)*
Syntax: `!fb <1-5> [tag ...] "comment"` at the end of the prompt.
- `<1-5>` mandatory integer score.
- `[tag ...]` zero or more hyphenated tags (`too-verbose`, `off-topic`, `correct-but-slow`). Open vocabulary; a parser over time surfaces frequent tags (P5).
- `"comment"` optional free-text in double quotes.
Example: `!fb 2 too-verbose off-topic "lost the thread about hooks, drifted into skills"`.
Parser: ~15-line regex in Python. The whole marker line is also stored verbatim as `raw_marker` so future LLM passes have context even if the parser changes.
Pros: score available instantly; tags + comment both logged; verbatim preserved in `raw_marker`; parseable without LLM.
Cons: tiny schema to remember. Mitigation: `!fb` alone prints a help reminder to stderr via the hook (hook can print to transcript; visible to user).

**Decision: free-form, `!`-prefixed tokens.** Per user: *"anything starting with '!' that has no space/newline/etc directly after it"*. Regex: `!(\S+)`. Capture semantics:

- Every `!<non-whitespace-run>` in the prompt becomes a tag. Multiple markers per prompt are allowed — all are captured.
- The full verbatim prompt is stored in `raw_marker` (unchanged for analysis).
- No numeric score at capture time. If a `!fb<digit>` or `!<digit>-<digit>` convention emerges in practice, the P5 batch LLM pass can assign scores post-hoc.
- No stripping of the marker from the prompt — Claude sees the `!token` and it lands in the trace naturally. Simpler than rewriting the prompt payload.

**Langfuse SDK calls at Stop-hook flush time** (sketch):
- `trace.update(tags=[*markers, "has_feedback"])` — every `!token` becomes a Langfuse tag; `has_feedback` sentinel tag for easy filtering of "sessions where I said anything".
- `trace.update(metadata={"feedback_markers": markers, "feedback_prompt": raw_prompt})` — full prompt text queryable via SDK.
- No `create_score` call at capture time. Reserved for a later P5 enhancement if useful.

### P4.D — `claude/settings.json` stanzas

Two hooks + env gate. `SessionStart` is **not** needed — state initialization is lazy (hooks create state files if missing).

Fragment to add (schema per Claude Code docs current at time of writing — verify with `claude --help hooks`):
- `env.TRACE_TO_LANGFUSE`: `"true"` (toggle with env override).
- `env.LANGFUSE_HOST`: public tunnel URL.
- `env.LANGFUSE_PUBLIC_KEY` + `env.LANGFUSE_SECRET_KEY`: **do not commit**. Either (a) reference via `${env:VAR}` if Claude Code supports that syntax in settings.json, or (b) put them in `~/.claude/settings.local.json` (gitignored per-machine override).
- `hooks.Stop`: list with one entry, `command: "~/.claude/hooks/langfuse_hook.py"`.
- `hooks.UserPromptSubmit`: list with one entry, `command: "~/.claude/hooks/outcome_tag.py"`.

**Disable path.** Set `TRACE_TO_LANGFUSE=false` in env; both hooks early-exit. No settings.json edit needed to turn it off.

### P4.E — `install.sh` extension

Mirror-and-symlink hooks exactly like agents are mirrored (`install.sh:107-117`). Pattern:

- Create `claude/hooks/` directory in the repo.
- In `install.sh`, add a block right after the agents-mirror block:
  - `mkdir -p ~/.claude/hooks`
  - Prune broken symlinks: `find ~/.claude/hooks -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null`
  - Loop: `for hook in "$DOTFILES/claude/hooks"/*.py; do _link "$hook" ~/.claude/hooks/"$(basename "$hook")"; done`
  - Wrap in `[[ -d "$DOTFILES/claude/hooks" ]]` guard so old checkouts don't fail.
  - After symlink: `chmod +x ~/.claude/hooks/*.py` (the `_link` helper doesn't preserve exec bit assumptions — set explicitly; idempotent).

Validate by manifest: the existing `validate-manifest.sh` (referenced in install.sh:90 comment) should pick up the new symlinks automatically.

**Verify.** After `just link`, `ls -la ~/.claude/hooks/` shows executable symlinks into the repo. `echo '{}' | ~/.claude/hooks/outcome_tag.py` exits 0.

**Rollback.** Revert install.sh diff; `rm -rf ~/.claude/hooks/` on each host.

---

## P5 — Analysis-at-scale workflow

**Goal.** Periodic pass that reads recent traces, clusters feedback, surfaces patterns actionable in the dotfiles.

### P5.A — Data access

- Langfuse Python SDK: `langfuse.get_traces(filter={...}, limit=500)` returns trace objects with `metadata`, `tags`, `scores`.
- Useful filters: `from_timestamp` (last N days), `tags_contains=["too-verbose"]`, `score.user_feedback < 3`.
- Output of the pull: a JSONL dump at `~/.claude/analysis/traces-YYYYMMDD.jsonl` — each line a `{trace_id, timestamp, tags, score, comment, raw_marker, excerpt_of_io}`.

### P5.B — LLM clustering pass

- Script: `scripts/langfuse-analyze.py` (in dotfiles `services/langfuse/scripts/`).
- Invokes `claude -p` (headless) with a prompt that:
  - Receives the JSONL dump as input.
  - Produces a markdown report grouped by recurring theme: each theme has (a) theme name, (b) example trace IDs, (c) frequency count, (d) suggested dotfiles change.
- Output: `~/.claude/analysis/report-YYYYMMDD.md`.
- Cost control: the excerpt per trace is a 500-char head+tail of the output, not the full transcript.

### P5.C — Justfile recipe

- `just langfuse-analyze [days=7]` — runs pull + LLM pass, opens the report in `$EDITOR`.

### P5.D — Feedback loop into dotfiles

Patterns that surface should map to concrete edits:
- "Agent ignores CLAUDE.md hard rule X repeatedly" → add/update a hookify rule (user already has this skill — `feat: volve-ai/hookify`).
- "Agent drifts into premature abstraction" → CLAUDE.md edit (tighten the relevant paragraph).
- "A specific skill fires when it shouldn't" → add `disable-model-invocation: true` or sharpen the skill's description.
- "Common workflow keeps needing the same prompt" → new slash-command skill.

### P5.E — Cadence

- **On-demand initially** (weekly for first month, as you're dialling in the tag vocabulary).
- **Weekly scheduled** once signal:noise is good — cron or a `CronCreate` routine that runs `just langfuse-analyze` every Monday 09:00 local.
- **Per-N-sessions** (e.g. every 50 sessions) is spec'd but not recommended — fixed calendar cadence produces reviewable reports; event-driven produces noise.

---

## P6 — Privacy / data handling

> **Confirmed: no sanitization, no retention cap.** Personal ad-hoc logging, self-hosted, behind Cloudflare Access. P6.A and P6.C below are intentionally skipped. P6.B (what sanitization would NOT catch) is retained as context — if a shared use case ever appears, these are the gaps to fix first.

### P6.A — Minimum-viable sanitization (SKIPPED — confirmed no sanitization)

Apply in `langfuse_hook.py` before any content leaves the host. Regex denylist, line-by-line:

| Pattern | Replacement |
|---|---|
| `^[A-Z_][A-Z0-9_]*=.{8,}$` (env-var line, value ≥8 chars) | `<ENV_REDACTED>` |
| `sk-[a-zA-Z0-9_-]{20,}` (OpenAI-style) | `<SK_REDACTED>` |
| `sk-ant-[a-zA-Z0-9_-]{20,}` (Anthropic) | `<SK_ANT_REDACTED>` |
| `AKIA[0-9A-Z]{16}` (AWS access key) | `<AWS_KEY_REDACTED>` |
| `(?i)bearer\s+[a-z0-9._-]{20,}` | `<BEARER_REDACTED>` |
| `ghp_[a-zA-Z0-9]{36}` / `github_pat_[a-zA-Z0-9_]{80,}` | `<GH_TOKEN_REDACTED>` |
| `-----BEGIN [A-Z ]+PRIVATE KEY-----` through `-----END [A-Z ]+PRIVATE KEY-----` | `<PRIVATE_KEY_REDACTED>` |

Implementation: one `sanitize(s: str) -> str` function with the regex list. Unit-tested under `claude/hooks/tests/test_sanitize.py`. Applied to input, output, every tool-call arg, every tool-call result.

### P6.B — What this does NOT catch

- Secrets inside JSON structured data where the key name is non-obvious (e.g. `{"foo": "sk-real-key"}` — caught by the `sk-` prefix regex, **but** `{"foo": "plaintext-password-12345"}` is not).
- Customer/PII data in code comments or file contents that the agent reads/writes.
- Credentials constructed from multiple lines (e.g. username + password separated).
- Semantic secrets ("the API uses token `xyzzy42`").
- Anything in image/binary tool-call outputs (not forwarded to Langfuse anyway, but worth noting).

This is **detection of well-known patterns, not prevention**. The threat model is "don't accidentally log env-var pastes and CLI flags"; it is not "safe to forward arbitrary repo contents".

### P6.C — Retention (SKIPPED — confirmed unlimited)

- Langfuse UI: project settings → data retention → **90 days**.
- Rationale: long enough for quarterly pattern analysis; short enough that a breach of the VM doesn't expose a year of transcripts.
- ClickHouse disk: 90 days of traces at ~100 sessions/day ≈ ~5 GB ballpark. Fits easily on 40 GB NVMe.

### P6.D — Backups

Langfuse's durable state is Postgres (users, projects, keys) + ClickHouse (observation data) + MinIO (large blobs, mostly media). Priority: Postgres > MinIO > ClickHouse (ClickHouse is rebuildable from raw events in MinIO if events are still in retention).

- **`just langfuse-backup`** recipe: `ssh host 'cd /opt/langfuse && docker compose exec -T postgres pg_dump -U postgres langfuse | gzip > /backup/pg-$(date +%F).sql.gz'`.
- Backup destination: MinIO on the same host is pointless. Either (a) `rclone` to a second bucket at a different provider, or (b) a weekly `rsync` down to the mac and into Backblaze B2 / iCloud.
- Frequency: daily Postgres dump, weekly ClickHouse snapshot, weekly MinIO bucket sync. Retention on backups: keep last 4 weekly + last 7 daily.
- Test restore: once, now. `docker compose down -v && restore && docker compose up -d` on a scratch host. If it doesn't work, the backup is theatre.

---

## P7 — Network: expose Langfuse via Cloudflare Tunnel

**Goal.** `https://langfuse.example.dev` reaches the host's port 3000 over an authenticated tunnel. No inbound ports on the host firewall.

**Why CF Tunnel.** No public IP needed, no TLS cert management (CF terminates), Cloudflare Access adds SSO with email OTP for free on personal use. Simpler than Tailscale if you ever want to hit the UI from an untrusted device.

**Steps** (see [CF docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/) — the docs page returned only dashboard-flow details; CLI steps are well-established elsewhere):

1. Install `cloudflared` on the host (apt package for Ubuntu).
2. `cloudflared tunnel login` — opens a browser URL; paste into laptop, authorise the zone.
3. `cloudflared tunnel create langfuse` — creates tunnel, writes credentials to `~/.cloudflared/<uuid>.json`.
4. Create `/etc/cloudflared/config.yml`:
   ```
   tunnel: <uuid>
   credentials-file: /root/.cloudflared/<uuid>.json
   ingress:
     - hostname: langfuse.example.dev
       service: http://localhost:3000
     - service: http_status:404
   ```
5. `cloudflared tunnel route dns langfuse langfuse.example.dev` — creates the CNAME in Cloudflare.
6. `cloudflared service install` — installs systemd unit, auto-start.
7. Cloudflare Zero Trust dashboard → **Access → Applications → Self-hosted** → add `langfuse.example.dev`, policy: "emails in [your list]", identity: One-Time PIN.

**Verify.** `curl -sI https://langfuse.example.dev` returns CF's Access login page (HTML redirect). Hitting in browser triggers OTP email, then loads the Langfuse UI.

**`NEXTAUTH_URL`** must equal `https://langfuse.example.dev` — set in `/opt/langfuse/.env` and restart: `docker compose up -d`.

**Rollback.** `cloudflared service uninstall`, remove DNS record in CF dashboard, remove Access application.

---

## P8 — Verification end-to-end

**Goal.** One sentence: ran a real Claude Code turn, typed `!fb 3 too-chatty "the usual"`, opened Langfuse UI, saw the trace with score=3, tags=[too-chatty], comment set.

**Steps.**
1. `just link` — hooks symlinked.
2. `claude` — start a session, ask a trivial question.
3. Follow up with `!fb 4 helpful "clear answer"`. Marker should be stripped from the prompt shown to Claude (verify in transcript).
4. On session close (or after next assistant turn), check Langfuse UI → Traces → latest.
5. Trace should show: input/output, tool calls as spans, score `user_feedback=4`, tags `helpful`, metadata `feedback_comment="clear answer"` + `feedback_raw="!fb 4 helpful \"clear answer\""`.

**If missing.** Check `~/.claude/state/langfuse_cursor.json` (should have advanced), check `~/.claude/state/pending_outcome.json` (should be absent after Stop ran), check `docker compose logs langfuse-worker` on host.

---

## Risks & known gotchas

- **Langfuse SDK v3 vs v4.** Upstream moved API shape between v3 and v4. Docs at `langfuse.com/docs/sdk/python/sdk-v3` now redirect to v4. Pin the SDK version in the hook venv and note it in the hook header. Re-fetch [SDK overview](https://langfuse.com/docs/observability/get-started) before coding.
- **Claude Code hook JSON contract changes.** The `UserPromptSubmit` stdout contract for rewriting the prompt has changed between Claude Code versions. Run `claude --help hooks` or check current docs before finalising the rewrite step; fallback is: don't rewrite the prompt, just log feedback and let the marker through (Claude will see `!fb ...` and ignore it).
- **Transcript JSONL format changes.** Claude Code's `~/.claude/projects/*/session.jsonl` schema has evolved. The template hook may hardcode assumptions. Add a version check: log a warning if unknown message types appear, don't crash.
- **Stop hook can fire without a preceding UserPromptSubmit for the session's first turn.** `pending_outcome.json` won't exist — that's the normal case, just flush trace without feedback. Don't treat absence as an error.
- **ClickHouse on 4 GB RAM.** Langfuse worker + ClickHouse will be the hungry ones. If the host starts OOM-killing, upgrade to CX32 before trying to tune ClickHouse knobs.
- **Tunnel credential rotation.** `~/.cloudflared/<uuid>.json` is a long-lived secret. Back it up; if the host dies, re-creating the tunnel under the same hostname requires revoking the old one first or you get DNS CNAME conflicts.
- **Cloudflare Access "One-Time PIN" email can be spam-foldered.** Also whitelist your email in CF Access, test the flow before relying on it.
- **Secret leakage via `raw_marker`.** If you type `!fb 1 bad "sk-real-anthropic-key leaked"`, the sanitizer WILL redact `sk-real-*` inside the comment, but a clever naming scheme won't be caught. Consider `raw_marker` sanitised-by-default.
- **Laptop offline = traces buffer where?** The hook does not buffer locally if the tunnel URL is unreachable. Acceptable loss: traces during network outages. If this bites, add an offline queue at `~/.claude/state/queue/`.
- **Pattern analysis bias.** LLM clustering of your own feedback will reflect your framing. Re-read raw feedback monthly even after the report becomes useful — the report hides outliers.
- **Feedback-loop time.** Don't change hookify rules / CLAUDE.md based on fewer than ~10 instances of a pattern. Noise at the one-session scale is high.

---

## External references (verified this session)

- Langfuse self-hosting, docker-compose: https://langfuse.com/self-hosting/docker-compose
- Langfuse configuration env vars: https://langfuse.com/self-hosting/configuration
- Langfuse SDK (v4; v3 legacy link inside): https://langfuse.com/docs/sdk/python/sdk-v3 → redirects to current observability docs
- Cloudflare Tunnel remote tunnel guide: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/
- doneyli/claude-code-langfuse-template: https://github.com/doneyli/claude-code-langfuse-template
- Oracle Cloud Free Tier (FAQ page was 403 to fetch; numbers in P1.A are from prior research, confirm on https://www.oracle.com/cloud/free/ before committing)
