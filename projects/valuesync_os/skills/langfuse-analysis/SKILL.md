---
name: langfuse-analysis
description: Use when the user asks about Langfuse traces, AI observability data, token usage, tool call patterns, latency, errors, or wants to analyze production AI behavior. Also use when debugging AI chat issues or investigating why a specific query behaved unexpectedly.
---

# Langfuse Trace Analysis

Query and analyze Langfuse traces directly from the CLI using the Langfuse REST API.

## Authentication

Credentials are in the project `.env.local` (same keys the app uses for OTel export):

```bash
# MUST use set -a to export variables for node subprocesses
set -a && source .env.local && set +a
# Keys: LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL
```

All API calls use **Basic Auth**: `base64(LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY)`.

**IMPORTANT:** Do NOT use `source .env.local` alone — it doesn't export variables. Node.js subprocesses won't see them. Always use `set -a`.

## How to Query

**Always write a temp .mjs script** — never use `node -e` with inline code. Shell escaping of `!`, quotes, and `$` is fragile and breaks constantly.

Start every script with the helper pattern below, then write analysis logic.

### Reusable Helper Pattern

Every script should start with this. It handles auth, rate limiting, and retries:

```javascript
// /tmp/langfuse-query.mjs
const BASE = process.env.LANGFUSE_BASE_URL || 'https://cloud.langfuse.com'
const AUTH = 'Basic ' + Buffer.from(
  process.env.LANGFUSE_PUBLIC_KEY + ':' + process.env.LANGFUSE_SECRET_KEY
).toString('base64')

async function api(path, retries = 3) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    const res = await fetch(`${BASE}${path}`, {
      headers: { Authorization: AUTH, 'Content-Type': 'application/json' }
    })
    if (res.ok) return res.json()
    if (res.status === 429 && attempt < retries) {
      const wait = attempt * 3000
      console.error(`Rate limited, waiting ${wait / 1000}s...`)
      await new Promise(r => setTimeout(r, wait))
      continue
    }
    throw new Error(`API ${res.status}: ${await res.text().catch(() => 'no body')}`)
  }
}

async function fetchAllTraces(params = '') {
  const all = []
  let page = 1
  while (true) {
    const data = await api(`/api/public/traces?limit=100&page=${page}&orderBy=timestamp.desc${params}`)
    all.push(...(data.data || []))
    if ((data.data || []).length < 100) break
    page++
    await new Promise(r => setTimeout(r, 2000))
  }
  return all
}

async function fetchObservations(traceId) {
  await new Promise(r => setTimeout(r, 2000)) // rate limit between calls
  const data = await api(`/api/public/observations?traceId=${traceId}&limit=100`)
  return data.data || []
}
```

Run with: `set -a && source .env.local && set +a && node /tmp/langfuse-query.mjs`

## API Quick Reference

Base URL: `https://cloud.langfuse.com` (or `$LANGFUSE_BASE_URL`)

| Endpoint | Use for |
|---|---|
| `GET /api/public/traces` | List/filter traces (main entry point) |
| `GET /api/public/traces/:id` | Single trace with full detail |
| `GET /api/public/observations` | Observations for a trace (generations, tool calls, spans) |
| `GET /api/public/observations/:id` | Single observation detail |
| `GET /api/public/generations` | LLM generations (filter by model, prompt, etc.) |
| `GET /api/public/scores` | Evaluation scores attached to traces |
| `GET /api/public/sessions` | Session groupings (session IDs use `entity:uuid` format, e.g. `company:abc-123`) |

### Traces Query Parameters

| Param | Example | Notes |
|---|---|---|
| `limit` | `100` | Max per page (default 50) |
| `page` | `2` | Pagination |
| `orderBy` | `timestamp.desc` | Sort order |
| `fromTimestamp` | `2026-03-18T00:00:00Z` | ISO 8601, inclusive |
| `toTimestamp` | `2026-03-18T23:59:59Z` | ISO 8601, exclusive |
| `name` | `chat:message` | Exact trace name match |
| `tags` | `chat` | Filter by tag |
| `userId` | `user-uuid` | Filter by user |
| `sessionId` | `session-uuid` | Filter by session |

**Tip:** Use `&environment=production` to filter by environment server-side.

### Observations Query Parameters

| Param | Example | Notes |
|---|---|---|
| `traceId` | `abc123` | **Required** for per-trace drill-down |
| `type` | `GENERATION`, `TOOL`, `SPAN` | Filter by observation type |
| `name` | `ai.toolCall.search_deals` | Filter by observation name |
| `limit` | `100` | Max per page |

## What's on Traces vs Observations

**Traces are thin.** They have: `id`, `name`, `timestamp`, `tags`, `metadata`, `sessionId`, `userId`, `level`, `status`. They do NOT have: input/output content, token usage, tool calls, or model info.

**To see what a chat was about**, you MUST drill into observations:
- **User message:** Found in GENERATION observations' `input.messages` array — look for `role: 'user'` entries
- **Assistant response:** Found in GENERATION observations' `output` (tool_calls or text content)
- **Neither is on the trace itself** — `trace.input` and `trace.output` are typically empty/null

**For "what were users chatting about?" questions:** skip traces entirely — go straight to `/api/public/generations` with `&fromTimestamp=...` and extract user messages from `input.messages`. See the "Recent chat conversations" recipe below.

**Sessions endpoint is thin:** `/api/public/sessions/:id` returns only ID + timestamp. You always need traces → observations to get actual content.

## Observation Types (ValuesyncOS)

The app uses AI SDK + OTel. Traces contain these observation types:

| Type | What it captures | Key fields |
|---|---|---|
| `GENERATION` | LLM calls (streamText/generateText) | `output.tool_calls`, `usage.total/input/output`, `model` |
| `TOOL` | Tool executions | `name` (tool name), `input`, `output`, `startTime/endTime` |
| `SPAN` | Wrapper spans (e.g., `ai.streamText`, `ai.toolCall.*`) | `name`, `startTime/endTime` |

### The N+1 Problem

**Token usage and tool calls are only on GENERATION/TOOL observations, NOT on traces.** To analyze these, you must fetch observations per trace — that's N+1 API calls. Strategies:

- **For small datasets (<20 traces):** fetch observations per trace with 2s delay
- **For large datasets:** use `GET /api/public/generations` directly (supports `fromTimestamp`, avoids per-trace drill-down)
- **For tool call analysis:** use `GET /api/public/observations?type=TOOL` if you don't need trace grouping

### Extracting tool calls from observations

Tool calls appear in multiple places — check all:

1. **GENERATION output** — `obs.output.tool_calls[].function.name` (OpenAI format)
2. **GENERATION output array** — `obs.output[].type === 'tool-call'` (AI SDK format)
3. **TOOL observations** — `obs.name` is the tool name, `obs.input` has args
4. **SPAN observations** — `obs.name` like `ai.toolCall.search_deals`

### Extracting token usage

```javascript
for (const gen of observations.filter(o => o.type === 'GENERATION')) {
  const usage = gen.usage || {}
  const input = usage.input || usage.promptTokens || usage.inputTokens || 0
  const output = usage.output || usage.completionTokens || usage.outputTokens || 0
  const total = usage.total || usage.totalTokens || (input + output)
}
```

## Trace Names and Environments (ValuesyncOS)

### Environments

Filter with `&environment=production` (API query param, not client-side):
- `production` — live app (app.valuesync.ai)
- `preview` — Vercel preview deployments
- `development` — local dev
- `default` — fallback when env not set

### Trace Name Patterns

| Pattern | Category | Example |
|---|---|---|
| `chat:general` | User chat interactions | General AI chat messages |
| `company-insight/*` | AI workflow: company analysis | `company-insight/market-dynamics`, `company-insight/ownership-analysis`, `company-insight/market-landscape`, `company-insight/business-model-strategy`, `company-insight/regulatory`, `company-insight/management-board` |
| `enrichment/*` | AI workflow: data enrichment | `enrichment/industry-sector-tagging`, `enrichment/news-signal-scan`, `enrichment/markets-and-jurisdictions`, `enrichment/products-and-services` |
| `synthesis/*` | AI workflow: synthesis reports | `synthesis/business-overview` |

**Filtering by category:** Use `name` param for exact match, or fetch all and filter client-side with `t.name.startsWith('company-insight/')`.

### Session ID Format

Session IDs use `entity:uuid` pattern, e.g. `company:2fbf4417-61ca-49bf-866e-51780d2f17ee`. Always `encodeURIComponent()` when using in API URLs.

- Tags: `chat`, environment tags
- Metadata may include `tools` (JSON array of loaded tool names)

## Rate Limiting

Langfuse API rate limits are strict. These timings are tested:

- **Between observation fetches:** 2000ms minimum (500ms will get you 429s)
- **Between paginated trace fetches:** 2000ms
- **On 429 response:** retry with exponential backoff (3s, 6s, 9s)
- **Batch planning:** 50 traces with observation drill-down = ~2 minutes

## Common Recipes

### Daily summary (trace-level only, no drill-down)

```javascript
const since = new Date(Date.now() - 24 * 3600000).toISOString()
const traces = await fetchAllTraces(`&fromTimestamp=${since}`)
const byName = {}
for (const t of traces) byName[t.name] = (byName[t.name] || 0) + 1
console.table(Object.entries(byName).sort(([,a],[,b]) => b - a))
```

### Cost by model (uses generations endpoint directly — avoids N+1)

```javascript
const since = new Date(Date.now() - 7 * 24 * 3600000).toISOString()
let page = 1, gens = []
while (true) {
  const data = await api(`/api/public/generations?limit=100&page=${page}&fromTimestamp=${since}`)
  gens.push(...(data.data || []))
  if ((data.data || []).length < 100) break
  page++; await new Promise(r => setTimeout(r, 2000))
}
const byModel = {}
for (const g of gens) {
  const model = g.model || 'unknown'
  if (!byModel[model]) byModel[model] = { calls: 0, inputTokens: 0, outputTokens: 0 }
  byModel[model].calls++
  byModel[model].inputTokens += g.usage?.input || g.usage?.promptTokens || 0
  byModel[model].outputTokens += g.usage?.output || g.usage?.completionTokens || 0
}
console.table(byModel)
```

### Session detail

```javascript
// Session IDs in ValuesyncOS use entity:uuid format
const data = await api(`/api/public/sessions/${encodeURIComponent(sessionId)}`)
console.log(data)
// Then fetch traces for this session
const traces = await fetchAllTraces(`&sessionId=${encodeURIComponent(sessionId)}`)
```

### Recent chat conversations (most common query — avoids N+1)

```javascript
// Go straight to generations, skip traces entirely
const since = new Date(Date.now() - 24 * 3600000).toISOString()
let page = 1, gens = []
while (true) {
  const data = await api(`/api/public/generations?limit=100&page=${page}&fromTimestamp=${since}`)
  gens.push(...(data.data || []))
  if ((data.data || []).length < 100) break
  page++; await new Promise(r => setTimeout(r, 2000))
}
// Group by trace, extract user messages from first generation per trace
const byTrace = {}
for (const g of gens) {
  if (!byTrace[g.traceId]) byTrace[g.traceId] = []
  byTrace[g.traceId].push(g)
}
for (const [traceId, traceGens] of Object.entries(byTrace)) {
  const first = traceGens[0]
  const userMsgs = (first.input?.messages || [])
    .filter(m => m.role === 'user')
    .map(m => typeof m.content === 'string' ? m.content : JSON.stringify(m.content))
  if (userMsgs.length > 0) {
    console.log(`${first.startTime?.slice(0, 16)} | ${userMsgs[0].slice(0, 120)}`)
  }
}
```

### Recent enrichments (what companies were processed)

```javascript
const since = new Date(Date.now() - 24 * 3600000).toISOString()
const traces = await fetchAllTraces(`&fromTimestamp=${since}`)
const enrichments = traces.filter(t => t.name?.startsWith('enrichment/') || t.name?.startsWith('company-insight/'))
const byName = {}
for (const t of enrichments) byName[t.name] = (byName[t.name] || 0) + 1
console.table(Object.entries(byName).sort(([,a],[,b]) => b - a))
console.log(`\nTotal: ${enrichments.length} enrichment traces`)
```

### Error scan

```javascript
const since = new Date(Date.now() - 24 * 3600000).toISOString()
const traces = await fetchAllTraces(`&fromTimestamp=${since}`)
const errors = traces.filter(t => t.level === 'ERROR' || t.status === 'ERROR')
for (const t of errors) {
  console.log(`${t.timestamp} | ${t.name} | ${t.statusMessage || 'no message'}`)
  const obs = await fetchObservations(t.id)
  const errorObs = obs.filter(o => o.level === 'ERROR' || o.statusMessage)
  for (const o of errorObs) console.log(`  ${o.type}: ${o.name} — ${o.statusMessage}`)
}
```
