/**
 * Langfuse Observability Extension
 *
 * Provides tools for querying Langfuse traces, observations, and scores
 * via the REST API. Requires LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY,
 * and LANGFUSE_HOST (or LANGFUSE_BASE_URL) in environment or .env/.env.local.
 *
 * Tools:
 *   langfuse_traces       - List/search traces with filtering
 *   langfuse_trace        - Get a single trace with its full observation tree
 *   langfuse_generations  - List LLM generation observations (prompts, completions, token usage)
 *   langfuse_scores       - List scores attached to traces
 *   langfuse_sessions     - List sessions
 *
 * Place in ~/.pi/agent/extensions/langfuse/ for global availability.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import {
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  formatSize,
  truncateHead,
} from "@mariozechner/pi-coding-agent";
import { StringEnum } from "@mariozechner/pi-ai";
import { Text } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";
import { readFileSync } from "node:fs";
import { resolve, join } from "node:path";

// ── Config ────────────────────────────────────────────────────────────

interface LangfuseConfig {
  host: string;
  publicKey: string;
  secretKey: string;
}

function loadDotenv(filePath: string): Record<string, string> {
  const vars: Record<string, string> = {};
  try {
    const content = readFileSync(filePath, "utf-8");
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      let val = trimmed.slice(eq + 1).trim();
      // Strip surrounding quotes
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      vars[key] = val;
    }
  } catch {
    // File doesn't exist — fine
  }
  return vars;
}

function getConfig(cwd: string): LangfuseConfig | null {
  // Layer: process.env < .env < .env.local (last wins)
  const envFile = loadDotenv(resolve(cwd, ".env"));
  const envLocal = loadDotenv(resolve(cwd, ".env.local"));
  const merged = { ...envFile, ...envLocal };

  // Also check home directory
  const homeEnv = loadDotenv(join(process.env.HOME ?? "", ".env"));

  const all = { ...homeEnv, ...merged };

  // Process env vars override file-based ones
  for (const key of ["LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST", "LANGFUSE_BASE_URL"]) {
    if (process.env[key]) all[key] = process.env[key]!;
  }

  const host = all["LANGFUSE_HOST"] || all["LANGFUSE_BASE_URL"] || "https://cloud.langfuse.com";
  const publicKey = all["LANGFUSE_PUBLIC_KEY"];
  const secretKey = all["LANGFUSE_SECRET_KEY"];

  if (!publicKey || !secretKey) return null;

  return { host: host.replace(/\/$/, ""), publicKey, secretKey };
}

// ── API Client ────────────────────────────────────────────────────────

async function langfuseGet(
  config: LangfuseConfig,
  path: string,
  params?: Record<string, string | number | undefined>,
  signal?: AbortSignal,
): Promise<any> {
  const url = new URL(`${config.host}/api/public${path}`);
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined && v !== "") url.searchParams.set(k, String(v));
    }
  }

  const auth = Buffer.from(`${config.publicKey}:${config.secretKey}`).toString("base64");

  const res = await fetch(url.toString(), {
    headers: { Authorization: `Basic ${auth}` },
    signal,
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`Langfuse API ${res.status}: ${body.slice(0, 500)}`);
  }

  return res.json();
}

// ── Formatters ────────────────────────────────────────────────────────

function fmtTimestamp(ts: string): string {
  return ts?.slice(0, 19).replace("T", " ") ?? "?";
}

function fmtDuration(ms: number | null | undefined): string {
  if (ms == null) return "?";
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function fmtTokens(usage: any): string {
  if (!usage) return "";
  const parts: string[] = [];
  if (usage.input != null) parts.push(`in:${usage.input}`);
  if (usage.output != null) parts.push(`out:${usage.output}`);
  if (usage.total != null) parts.push(`total:${usage.total}`);
  return parts.length ? `[${parts.join(" ")}]` : "";
}

function fmtCost(cost: number | null | undefined): string {
  if (cost == null) return "";
  return `$${cost.toFixed(4)}`;
}

function truncateStr(s: string | null | undefined, max: number): string {
  if (!s) return "";
  if (s.length <= max) return s;
  return s.slice(0, max) + "…";
}

// ── Trace formatting ──────────────────────────────────────────────────

function formatTraceShort(t: any, index: number): string {
  const lines: string[] = [];
  const tags = t.tags?.length ? ` [${t.tags.join(", ")}]` : "";
  const session = t.sessionId ? ` session=${t.sessionId}` : "";
  const meta = [
    t.observations ? `${t.observations} obs` : null,
    fmtDuration(t.latency),
    fmtCost(t.totalCost),
  ].filter(Boolean).join(", ");

  lines.push(`[${index + 1}] ${t.id}  ${fmtTimestamp(t.timestamp)}${tags}${session}`);
  lines.push(`    ${truncateStr(t.name || t.input?.slice?.(0, 120) || "(unnamed)", 120)}`);
  if (meta) lines.push(`    ${meta}`);
  return lines.join("\n");
}

function formatObservation(obs: any, indent: number = 0): string {
  const pad = "  ".repeat(indent);
  const lines: string[] = [];

  const type = (obs.type || "SPAN").toUpperCase();
  const name = obs.name || "(unnamed)";
  const status = obs.statusMessage ? ` [${obs.statusMessage}]` : "";
  const level = obs.level && obs.level !== "DEFAULT" ? ` level=${obs.level}` : "";
  const model = obs.model ? ` model=${obs.model}` : "";
  const tokens = fmtTokens(obs.usage);
  const cost = fmtCost(obs.calculatedTotalCost);
  const duration = fmtDuration(obs.latency ?? (obs.endTime && obs.startTime
    ? new Date(obs.endTime).getTime() - new Date(obs.startTime).getTime()
    : null));

  lines.push(`${pad}┣ ${type}: ${name}${model}${level}${status} (${duration}) ${tokens} ${cost}`.trimEnd());

  // Show input/output for generations
  if (type === "GENERATION") {
    if (obs.input) {
      const inputStr = typeof obs.input === "string" ? obs.input : JSON.stringify(obs.input);
      const truncated = truncateStr(inputStr, 2000);
      lines.push(`${pad}  INPUT: ${truncated}`);
    }
    if (obs.output) {
      const outputStr = typeof obs.output === "string" ? obs.output : JSON.stringify(obs.output);
      const truncated = truncateStr(outputStr, 2000);
      lines.push(`${pad}  OUTPUT: ${truncated}`);
    }
    if (obs.metadata) {
      lines.push(`${pad}  META: ${truncateStr(JSON.stringify(obs.metadata), 500)}`);
    }
  }

  // Show input/output for spans too, but shorter
  if (type === "SPAN") {
    if (obs.input) {
      const inputStr = typeof obs.input === "string" ? obs.input : JSON.stringify(obs.input);
      lines.push(`${pad}  input: ${truncateStr(inputStr, 500)}`);
    }
    if (obs.output) {
      const outputStr = typeof obs.output === "string" ? obs.output : JSON.stringify(obs.output);
      lines.push(`${pad}  output: ${truncateStr(outputStr, 500)}`);
    }
  }

  return lines.join("\n");
}

function buildObservationTree(observations: any[]): string {
  // Sort by startTime, then nest by parentObservationId
  const sorted = [...observations].sort(
    (a, b) => new Date(a.startTime).getTime() - new Date(b.startTime).getTime(),
  );

  const childrenOf = new Map<string | null, any[]>();
  for (const obs of sorted) {
    const parent = obs.parentObservationId ?? null;
    if (!childrenOf.has(parent)) childrenOf.set(parent, []);
    childrenOf.get(parent)!.push(obs);
  }

  const lines: string[] = [];

  function walk(parentId: string | null, depth: number) {
    const children = childrenOf.get(parentId) ?? [];
    for (const child of children) {
      lines.push(formatObservation(child, depth));
      walk(child.id, depth + 1);
    }
  }

  walk(null, 0);
  return lines.join("\n");
}

// ── Extension ─────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {

  // ── langfuse_traces ─────────────────────────────────────────────────

  pi.registerTool({
    name: "langfuse_traces",
    label: "Langfuse Traces",
    description: `List traces from Langfuse with optional filtering. Returns trace IDs, names, timestamps, tags, latency, and cost.

Filter by:
  name     - trace name (exact match)
  tags     - comma-separated tags (e.g. "strategy:main,production")
  session  - session ID
  user     - user ID
  limit    - max results (default 20, max 100)
  page     - page number (default 1)
  from/to  - ISO timestamps for time range

Use langfuse_trace to get full details of a specific trace.`,
    parameters: Type.Object({
      name: Type.Optional(Type.String({ description: "Filter by trace name" })),
      tags: Type.Optional(Type.String({ description: "Comma-separated tags to filter by" })),
      session: Type.Optional(Type.String({ description: "Filter by session ID" })),
      user: Type.Optional(Type.String({ description: "Filter by user ID" })),
      from: Type.Optional(Type.String({ description: "Start time (ISO 8601)" })),
      to: Type.Optional(Type.String({ description: "End time (ISO 8601)" })),
      limit: Type.Optional(Type.Number({ description: "Max results (default 20, max 100)", minimum: 1, maximum: 100 })),
      page: Type.Optional(Type.Number({ description: "Page number (default 1)", minimum: 1 })),
      order_by: Type.Optional(StringEnum(["timestamp", "latency", "totalCost"] as const, { description: "Sort field (default: timestamp)" })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const config = getConfig(ctx.cwd);
      if (!config) {
        return {
          content: [{ type: "text", text: "Langfuse not configured. Set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, and LANGFUSE_HOST in .env or .env.local." }],
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Fetching traces from Langfuse..." }] });

      const limit = Math.min(params.limit ?? 20, 100);

      const apiParams: Record<string, string | number | undefined> = {
        page: params.page ?? 1,
        limit,
        orderBy: params.order_by ?? "timestamp",
      };
      if (params.name) apiParams.name = params.name;
      if (params.session) apiParams.sessionId = params.session;
      if (params.user) apiParams.userId = params.user;
      if (params.from) apiParams.fromTimestamp = params.from;
      if (params.to) apiParams.toTimestamp = params.to;
      // Tags need special handling — Langfuse API expects repeated tag= params
      // We'll add them to the URL manually

      let tagsQuery = "";
      if (params.tags) {
        const tagList = params.tags.split(",").map((t: string) => t.trim()).filter(Boolean);
        tagsQuery = tagList.map((t: string) => `&tags=${encodeURIComponent(t)}`).join("");
      }

      // Build URL manually to handle tags
      const url = new URL(`${config.host}/api/public/traces`);
      for (const [k, v] of Object.entries(apiParams)) {
        if (v !== undefined) url.searchParams.set(k, String(v));
      }

      const auth = Buffer.from(`${config.publicKey}:${config.secretKey}`).toString("base64");
      const finalUrl = url.toString() + tagsQuery;

      const res = await fetch(finalUrl, {
        headers: { Authorization: `Basic ${auth}` },
        signal,
      });

      if (!res.ok) {
        const body = await res.text().catch(() => "");
        return {
          content: [{ type: "text", text: `Langfuse API error ${res.status}: ${body.slice(0, 500)}` }],
        };
      }

      const data = await res.json();
      const traces = data.data ?? [];
      const meta = data.meta ?? {};

      if (traces.length === 0) {
        return {
          content: [{ type: "text", text: "No traces found matching the filters." }],
          details: { totalCount: meta.totalItems ?? 0, page: meta.page ?? 1, traces: [] },
        };
      }

      const header = `Found ${meta.totalItems ?? "?"} traces (page ${meta.page ?? 1}, showing ${traces.length}):`;
      const body = traces.map((t: any, i: number) => formatTraceShort(t, i)).join("\n\n");
      let output = header + "\n\n" + body;

      if ((meta.totalItems ?? 0) > (meta.page ?? 1) * limit) {
        output += `\n\nMore results available. Use page=${(meta.page ?? 1) + 1} to see the next page.`;
      }

      const truncation = truncateHead(output, { maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES });
      let resultText = truncation.content;
      if (truncation.truncated) {
        resultText += `\n\n[Output truncated: ${truncation.outputLines} of ${truncation.totalLines} lines shown.]`;
      }

      return {
        content: [{ type: "text", text: resultText }],
        details: { totalCount: meta.totalItems ?? 0, page: meta.page ?? 1, traces },
      };
    },

    renderCall(args: any, theme: any) {
      let text = theme.fg("toolTitle", theme.bold("langfuse_traces "));
      const filters: string[] = [];
      if (args.name) filters.push(`name=${args.name}`);
      if (args.tags) filters.push(`tags=${args.tags}`);
      if (args.session) filters.push(`session=${args.session}`);
      if (args.from) filters.push(`from=${args.from.slice(0, 10)}`);
      text += theme.fg("accent", filters.join(" ") || "(all)");
      return new Text(text, 0, 0);
    },

    renderResult(result: any, { expanded, isPartial }: any, theme: any) {
      if (isPartial) return new Text(theme.fg("warning", "Fetching traces..."), 0, 0);
      const details = result.details as any;
      if (!details?.traces?.length) return new Text(theme.fg("dim", "No traces found"), 0, 0);

      let text = theme.fg("success", `${details.traces.length} traces`);
      text += theme.fg("dim", ` (of ${details.totalCount} total, page ${details.page})`);

      if (expanded) {
        for (const t of details.traces.slice(0, 10)) {
          const tags = t.tags?.length ? ` [${t.tags.join(", ")}]` : "";
          text += `\n  ${theme.fg("accent", t.id.slice(0, 12))} ${theme.fg("dim", fmtTimestamp(t.timestamp))}${tags}`;
          text += `\n    ${t.name || "(unnamed)"}`;
        }
        if (details.traces.length > 10) {
          text += `\n  ${theme.fg("dim", `... and ${details.traces.length - 10} more`)}`;
        }
      }
      return new Text(text, 0, 0);
    },
  });

  // ── langfuse_trace ──────────────────────────────────────────────────

  pi.registerTool({
    name: "langfuse_trace",
    label: "Langfuse Trace",
    description: `Get full details of a single Langfuse trace by ID. Returns the trace metadata plus all nested observations (spans and generations) in a tree view.

Shows:
  - Trace metadata (name, tags, session, timestamps)
  - Full observation tree with timing and token usage
  - LLM generation inputs/outputs (the actual prompts and completions)
  - Span inputs/outputs (API call details)
  - Scores attached to the trace

This is where you see the LLM's reasoning — what it said between tool calls, why it chose certain actions.`,
    parameters: Type.Object({
      id: Type.String({ description: "Trace ID (from langfuse_traces)" }),
      observation_limit: Type.Optional(Type.Number({ description: "Max observations to fetch (default 100)", minimum: 1, maximum: 500 })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const config = getConfig(ctx.cwd);
      if (!config) {
        return {
          content: [{ type: "text", text: "Langfuse not configured. Set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, and LANGFUSE_HOST in .env or .env.local." }],
        };
      }

      onUpdate?.({ content: [{ type: "text", text: `Fetching trace ${params.id}...` }] });

      // Fetch trace
      const trace = await langfuseGet(config, `/traces/${params.id}`, undefined, signal);

      // Fetch observations for this trace
      const obsLimit = params.observation_limit ?? 100;
      const obsData = await langfuseGet(config, "/observations", {
        traceId: params.id,
        limit: obsLimit,
        page: 1,
      }, signal);

      const observations = obsData.data ?? [];

      // Fetch scores for this trace
      let scores: any[] = [];
      try {
        const scoreData = await langfuseGet(config, "/scores", {
          traceId: params.id,
          limit: 50,
        }, signal);
        scores = scoreData.data ?? [];
      } catch {
        // Scores endpoint might not exist in all versions
      }

      // Build output
      const lines: string[] = [];
      lines.push(`Trace: ${trace.id}`);
      lines.push(`Name: ${trace.name || "(unnamed)"}`);
      lines.push(`Time: ${fmtTimestamp(trace.timestamp)}`);
      if (trace.tags?.length) lines.push(`Tags: ${trace.tags.join(", ")}`);
      if (trace.sessionId) lines.push(`Session: ${trace.sessionId}`);
      if (trace.userId) lines.push(`User: ${trace.userId}`);
      if (trace.release) lines.push(`Release: ${trace.release}`);
      if (trace.version) lines.push(`Version: ${trace.version}`);
      lines.push(`Latency: ${fmtDuration(trace.latency)}`);
      if (trace.totalCost != null) lines.push(`Cost: ${fmtCost(trace.totalCost)}`);

      // Input/output
      if (trace.input) {
        const inputStr = typeof trace.input === "string" ? trace.input : JSON.stringify(trace.input, null, 2);
        lines.push(`\nInput:\n${truncateStr(inputStr, 3000)}`);
      }
      if (trace.output) {
        const outputStr = typeof trace.output === "string" ? trace.output : JSON.stringify(trace.output, null, 2);
        lines.push(`\nOutput:\n${truncateStr(outputStr, 3000)}`);
      }

      // Metadata
      if (trace.metadata && Object.keys(trace.metadata).length) {
        lines.push(`\nMetadata: ${JSON.stringify(trace.metadata, null, 2)}`);
      }

      // Observations tree
      if (observations.length > 0) {
        lines.push(`\n── Observations (${observations.length}) ──────────────────────`);
        lines.push(buildObservationTree(observations));

        if ((obsData.meta?.totalItems ?? 0) > observations.length) {
          lines.push(`\n[${obsData.meta.totalItems - observations.length} more observations not shown. Use observation_limit to increase.]`);
        }
      }

      // Scores
      if (scores.length > 0) {
        lines.push(`\n── Scores (${scores.length}) ──────────────────────`);
        for (const s of scores) {
          lines.push(`  ${s.name}: ${s.value}${s.comment ? ` — ${s.comment}` : ""}`);
        }
      }

      const output = lines.join("\n");
      const truncation = truncateHead(output, { maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES });
      let resultText = truncation.content;
      if (truncation.truncated) {
        resultText += `\n\n[Output truncated. Use observation_limit to reduce scope, or request specific observations.]`;
      }

      return {
        content: [{ type: "text", text: resultText }],
        details: { trace, observationCount: observations.length, scoreCount: scores.length },
      };
    },

    renderCall(args: any, theme: any) {
      let text = theme.fg("toolTitle", theme.bold("langfuse_trace "));
      text += theme.fg("accent", args.id);
      return new Text(text, 0, 0);
    },

    renderResult(result: any, { expanded, isPartial }: any, theme: any) {
      if (isPartial) return new Text(theme.fg("warning", "Fetching trace..."), 0, 0);
      const d = result.details as any;
      if (!d?.trace) return new Text(theme.fg("error", "Trace not found"), 0, 0);

      const t = d.trace;
      let text = theme.fg("accent", t.id.slice(0, 12)) + " " + theme.fg("dim", fmtTimestamp(t.timestamp));
      text += "\n" + theme.bold(t.name || "(unnamed)");
      text += theme.fg("dim", ` — ${d.observationCount} observations, ${d.scoreCount} scores`);

      if (expanded && t.tags?.length) {
        text += `\n${theme.fg("muted", `Tags: ${t.tags.join(", ")}`)}`;
      }
      return new Text(text, 0, 0);
    },
  });

  // ── langfuse_generations ────────────────────────────────────────────

  pi.registerTool({
    name: "langfuse_generations",
    label: "Langfuse Generations",
    description: `List LLM generation observations from Langfuse. Shows the actual prompts sent to and completions received from LLMs, with token usage and costs.

This is the key tool for understanding LLM reasoning — what the model was asked and what it responded.

Filter by:
  trace_id  - specific trace
  name      - generation name (e.g. "solve", "gemini_extract")
  model     - model name
  from/to   - time range
  limit     - max results (default 20)`,
    parameters: Type.Object({
      trace_id: Type.Optional(Type.String({ description: "Filter by trace ID" })),
      name: Type.Optional(Type.String({ description: "Filter by observation name" })),
      model: Type.Optional(Type.String({ description: "Filter by model name" })),
      from: Type.Optional(Type.String({ description: "Start time (ISO 8601)" })),
      to: Type.Optional(Type.String({ description: "End time (ISO 8601)" })),
      limit: Type.Optional(Type.Number({ description: "Max results (default 20, max 100)", minimum: 1, maximum: 100 })),
      page: Type.Optional(Type.Number({ description: "Page number (default 1)", minimum: 1 })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const config = getConfig(ctx.cwd);
      if (!config) {
        return {
          content: [{ type: "text", text: "Langfuse not configured. Set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, and LANGFUSE_HOST in .env or .env.local." }],
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Fetching generations..." }] });

      const limit = Math.min(params.limit ?? 20, 100);
      const apiParams: Record<string, string | number | undefined> = {
        type: "GENERATION",
        page: params.page ?? 1,
        limit,
      };
      if (params.trace_id) apiParams.traceId = params.trace_id;
      if (params.name) apiParams.name = params.name;
      if (params.model) apiParams.model = params.model;
      if (params.from) apiParams.fromStartTime = params.from;
      if (params.to) apiParams.toStartTime = params.to;

      const data = await langfuseGet(config, "/observations", apiParams, signal);
      const gens = data.data ?? [];
      const meta = data.meta ?? {};

      if (gens.length === 0) {
        return {
          content: [{ type: "text", text: "No generations found matching the filters." }],
          details: { totalCount: 0, generations: [] },
        };
      }

      const lines: string[] = [];
      lines.push(`Found ${meta.totalItems ?? "?"} generations (page ${meta.page ?? 1}, showing ${gens.length}):`);

      for (let i = 0; i < gens.length; i++) {
        const g = gens[i];
        lines.push("");
        lines.push(`[${i + 1}] ${g.id}`);
        lines.push(`    name=${g.name || "?"} model=${g.model || "?"} trace=${g.traceId}`);
        lines.push(`    time=${fmtTimestamp(g.startTime)} duration=${fmtDuration(g.latency)} ${fmtTokens(g.usage)} ${fmtCost(g.calculatedTotalCost)}`);

        if (g.input) {
          const inputStr = typeof g.input === "string" ? g.input : JSON.stringify(g.input);
          lines.push(`    INPUT: ${truncateStr(inputStr, 1500)}`);
        }
        if (g.output) {
          const outputStr = typeof g.output === "string" ? g.output : JSON.stringify(g.output);
          lines.push(`    OUTPUT: ${truncateStr(outputStr, 1500)}`);
        }
      }

      if ((meta.totalItems ?? 0) > (meta.page ?? 1) * limit) {
        lines.push(`\nMore results available. Use page=${(meta.page ?? 1) + 1}.`);
      }

      const output = lines.join("\n");
      const truncation = truncateHead(output, { maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES });
      let resultText = truncation.content;
      if (truncation.truncated) {
        resultText += `\n\n[Output truncated.]`;
      }

      return {
        content: [{ type: "text", text: resultText }],
        details: { totalCount: meta.totalItems ?? 0, page: meta.page ?? 1, generations: gens },
      };
    },

    renderCall(args: any, theme: any) {
      let text = theme.fg("toolTitle", theme.bold("langfuse_generations "));
      const filters: string[] = [];
      if (args.trace_id) filters.push(`trace=${args.trace_id.slice(0, 12)}`);
      if (args.name) filters.push(`name=${args.name}`);
      if (args.model) filters.push(`model=${args.model}`);
      text += theme.fg("accent", filters.join(" ") || "(all)");
      return new Text(text, 0, 0);
    },

    renderResult(result: any, { expanded, isPartial }: any, theme: any) {
      if (isPartial) return new Text(theme.fg("warning", "Fetching generations..."), 0, 0);
      const d = result.details as any;
      if (!d?.generations?.length) return new Text(theme.fg("dim", "No generations found"), 0, 0);

      let text = theme.fg("success", `${d.generations.length} generations`);
      text += theme.fg("dim", ` (of ${d.totalCount} total)`);

      if (expanded) {
        for (const g of d.generations.slice(0, 5)) {
          text += `\n  ${theme.fg("accent", g.id.slice(0, 12))} ${g.model || "?"} ${fmtTokens(g.usage)} ${fmtCost(g.calculatedTotalCost)}`;
        }
      }
      return new Text(text, 0, 0);
    },
  });

  // ── langfuse_scores ─────────────────────────────────────────────────

  pi.registerTool({
    name: "langfuse_scores",
    label: "Langfuse Scores",
    description: `List scores from Langfuse. Scores are evaluations attached to traces or observations — e.g. LLM-as-judge results, user feedback, or competition scores.

Filter by:
  trace_id  - scores for a specific trace
  name      - score name
  source    - score source (e.g. "API", "EVAL")
  from/to   - time range`,
    parameters: Type.Object({
      trace_id: Type.Optional(Type.String({ description: "Filter by trace ID" })),
      name: Type.Optional(Type.String({ description: "Filter by score name" })),
      source: Type.Optional(Type.String({ description: "Filter by source" })),
      from: Type.Optional(Type.String({ description: "Start time (ISO 8601)" })),
      to: Type.Optional(Type.String({ description: "End time (ISO 8601)" })),
      limit: Type.Optional(Type.Number({ description: "Max results (default 50, max 100)", minimum: 1, maximum: 100 })),
      page: Type.Optional(Type.Number({ description: "Page number (default 1)", minimum: 1 })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const config = getConfig(ctx.cwd);
      if (!config) {
        return {
          content: [{ type: "text", text: "Langfuse not configured. Set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, and LANGFUSE_HOST in .env or .env.local." }],
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Fetching scores..." }] });

      const limit = Math.min(params.limit ?? 50, 100);
      const apiParams: Record<string, string | number | undefined> = {
        page: params.page ?? 1,
        limit,
      };
      if (params.trace_id) apiParams.traceId = params.trace_id;
      if (params.name) apiParams.name = params.name;
      if (params.source) apiParams.source = params.source;
      if (params.from) apiParams.fromTimestamp = params.from;
      if (params.to) apiParams.toTimestamp = params.to;

      const data = await langfuseGet(config, "/scores", apiParams, signal);
      const scores = data.data ?? [];
      const meta = data.meta ?? {};

      if (scores.length === 0) {
        return {
          content: [{ type: "text", text: "No scores found." }],
          details: { totalCount: 0, scores: [] },
        };
      }

      const lines: string[] = [];
      lines.push(`Found ${meta.totalItems ?? "?"} scores (page ${meta.page ?? 1}, showing ${scores.length}):`);

      for (const s of scores) {
        const trace = s.traceId ? ` trace=${s.traceId}` : "";
        const obs = s.observationId ? ` obs=${s.observationId}` : "";
        const comment = s.comment ? ` — ${truncateStr(s.comment, 200)}` : "";
        lines.push(`  ${s.name}: ${s.value} (${s.source || "?"})${trace}${obs}${comment}`);
      }

      const output = lines.join("\n");

      return {
        content: [{ type: "text", text: output }],
        details: { totalCount: meta.totalItems ?? 0, page: meta.page ?? 1, scores },
      };
    },

    renderCall(args: any, theme: any) {
      let text = theme.fg("toolTitle", theme.bold("langfuse_scores "));
      if (args.trace_id) text += theme.fg("accent", `trace=${args.trace_id.slice(0, 12)}`);
      else if (args.name) text += theme.fg("accent", `name=${args.name}`);
      else text += theme.fg("accent", "(all)");
      return new Text(text, 0, 0);
    },

    renderResult(result: any, _opts: any, theme: any) {
      const d = result.details as any;
      if (!d?.scores?.length) return new Text(theme.fg("dim", "No scores"), 0, 0);
      return new Text(theme.fg("success", `${d.scores.length} scores`) + theme.fg("dim", ` (of ${d.totalCount})`), 0, 0);
    },
  });

  // ── langfuse_sessions ───────────────────────────────────────────────

  pi.registerTool({
    name: "langfuse_sessions",
    label: "Langfuse Sessions",
    description: `List sessions from Langfuse. Sessions group related traces together (e.g. all traces from one solver strategy or one competition run).

Filter by:
  from/to  - time range
  limit    - max results`,
    parameters: Type.Object({
      from: Type.Optional(Type.String({ description: "Start time (ISO 8601)" })),
      to: Type.Optional(Type.String({ description: "End time (ISO 8601)" })),
      limit: Type.Optional(Type.Number({ description: "Max results (default 20, max 100)", minimum: 1, maximum: 100 })),
      page: Type.Optional(Type.Number({ description: "Page number (default 1)", minimum: 1 })),
    }),

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const config = getConfig(ctx.cwd);
      if (!config) {
        return {
          content: [{ type: "text", text: "Langfuse not configured. Set LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, and LANGFUSE_HOST in .env or .env.local." }],
        };
      }

      onUpdate?.({ content: [{ type: "text", text: "Fetching sessions..." }] });

      const limit = Math.min(params.limit ?? 20, 100);
      const apiParams: Record<string, string | number | undefined> = {
        page: params.page ?? 1,
        limit,
      };
      if (params.from) apiParams.fromTimestamp = params.from;
      if (params.to) apiParams.toTimestamp = params.to;

      const data = await langfuseGet(config, "/sessions", apiParams, signal);
      const sessions = data.data ?? [];
      const meta = data.meta ?? {};

      if (sessions.length === 0) {
        return {
          content: [{ type: "text", text: "No sessions found." }],
          details: { totalCount: 0, sessions: [] },
        };
      }

      const lines: string[] = [];
      lines.push(`Found ${meta.totalItems ?? "?"} sessions (page ${meta.page ?? 1}, showing ${sessions.length}):`);

      for (const s of sessions) {
        const traces = s.traces?.length ?? s.countTraces ?? "?";
        lines.push(`  ${s.id}  ${fmtTimestamp(s.createdAt)}  traces=${traces}`);
      }

      return {
        content: [{ type: "text", text: lines.join("\n") }],
        details: { totalCount: meta.totalItems ?? 0, sessions },
      };
    },

    renderCall(_args: any, theme: any) {
      return new Text(theme.fg("toolTitle", theme.bold("langfuse_sessions")), 0, 0);
    },

    renderResult(result: any, _opts: any, theme: any) {
      const d = result.details as any;
      if (!d?.sessions?.length) return new Text(theme.fg("dim", "No sessions"), 0, 0);
      return new Text(theme.fg("success", `${d.sessions.length} sessions`) + theme.fg("dim", ` (of ${d.totalCount})`), 0, 0);
    },
  });
}
