/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Shared utilities for pi extensions that talk to external APIs.
 */

import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import {
  truncateHead,
  DEFAULT_MAX_BYTES,
  DEFAULT_MAX_LINES,
  formatSize,
} from "@mariozechner/pi-coding-agent"

// ── Env loading ───────────────────────────────────────────────────────────

/** Load a single key from .env.local / .env if not already in process.env. */
export function loadEnvKey(key: string): void {
  if (process.env[key]) return
  for (const file of [".env.local", ".env"]) {
    try {
      const contents = readFileSync(resolve(process.cwd(), file), "utf-8")
      for (const line of contents.split("\n")) {
        const trimmed = line.trim()
        if (!trimmed || trimmed.startsWith("#")) continue
        const eq = trimmed.indexOf("=")
        if (eq === -1) continue
        if (trimmed.slice(0, eq).trim() !== key) continue
        let value = trimmed.slice(eq + 1).trim()
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1)
        }
        process.env[key] = value
        return
      }
    } catch { /* file doesn't exist — try next */ }
  }
}

/** Get a required env key or throw with a setup hint. */
export function requireEnvKey(key: string, setupHint: string): string {
  const value = process.env[key]
  if (!value) throw new Error(`${key} is not set. ${setupHint}`)
  return value
}

// ── Tool execution helpers ────────────────────────────────────────────────

/** Standard success result with truncation. */
export function toolSuccess(action: string, output: string) {
  const truncation = truncateHead(output, {
    maxLines: DEFAULT_MAX_LINES,
    maxBytes: DEFAULT_MAX_BYTES,
  })

  let result = truncation.content
  if (truncation.truncated) {
    result +=
      `\n\n[Output truncated: ${truncation.outputLines} of ${truncation.totalLines} lines ` +
      `(${formatSize(truncation.outputBytes)} of ${formatSize(truncation.totalBytes)})]`
  }

  return {
    content: [{ type: "text" as const, text: result }],
    details: { action, truncated: truncation.truncated },
  }
}

/**
 * Validate required params — throws on missing.
 * Uses == null so falsy-but-valid values (0, false) pass through.
 * Empty/whitespace-only strings are treated as missing.
 */
export function validateRequired(
  action: string,
  params: Record<string, any>,
  required: string[],
) {
  for (const key of required) {
    const v = params[key]
    if (v == null || (typeof v === "string" && !v.trim())) {
      throw new Error(`"${key}" is required for ${action}.`)
    }
  }
}

// ── Truncation re-exports ─────────────────────────────────────────────────

export { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES, formatSize }
