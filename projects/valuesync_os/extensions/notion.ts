/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Notion extension — read and write access to the connected workspace.
 *
 * NOTION_API_KEY in .env.local or shell env. Share pages via ··· → Connections.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"
import { Type } from "@sinclair/typebox"
import { StringEnum } from "@mariozechner/pi-ai"
import { Text } from "@mariozechner/pi-tui"
import {
  loadEnvKey,
  requireEnvKey,
  toolSuccess,
  validateRequired,
} from "./shared/env"

loadEnvKey("NOTION_API_KEY")

const VER = "2022-06-28"
const DEPTH = 5
const RT_LIMIT = 2000

// ── HTTP ────────────────────────────────────────────────────────────────────

async function req(method: string, path: string, body?: unknown, signal?: AbortSignal | null) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(`https://api.notion.com/v1${path}`, {
      method,
      signal: signal ?? undefined,
      headers: {
        Authorization: `Bearer ${requireEnvKey("NOTION_API_KEY", "Set in .env.local")}`,
        "Notion-Version": VER,
        "Content-Type": "application/json",
      },
      ...(body != null ? { body: JSON.stringify(body) } : {}),
    })
    if (res.status === 429 && attempt < 2) {
      const sec = Number(res.headers.get("Retry-After")) || (attempt + 1)
      await new Promise(r => setTimeout(r, sec * 1000))
      continue
    }
    if (!res.ok) throw new Error(`Notion ${res.status}: ${await res.text()}`)
    return res.json()
  }
}

// ── Rich text / Markdown ────────────────────────────────────────────────────

function rt(arr: any[]): string {
  if (!arr) return ""
  return arr.map((t: any) => {
    let s = t.plain_text ?? t.text?.content ?? ""
    if (t.annotations?.bold) s = `**${s}**`
    if (t.annotations?.italic) s = `*${s}*`
    if (t.annotations?.strikethrough) s = `~~${s}~~`
    if (t.annotations?.code) s = `\`${s}\``
    if (t.href) s = `[${s}](${t.href})`
    return s
  }).join("")
}

function blockMd(b: any, indent = ""): string {
  const d = b[b.type]
  if (!d) return ""
  const text = d.rich_text ? rt(d.rich_text) : ""
  const m: Record<string, () => string> = {
    paragraph:          () => `${indent}${text}`,
    heading_1:          () => `${indent}# ${text}`,
    heading_2:          () => `${indent}## ${text}`,
    heading_3:          () => `${indent}### ${text}`,
    bulleted_list_item: () => `${indent}- ${text}`,
    numbered_list_item: () => `${indent}1. ${text}`,
    to_do:              () => `${indent}- [${d.checked ? "x" : " "}] ${text}`,
    toggle:             () => `${indent}<details><summary>${text}</summary>`,
    code:               () => `${indent}\`\`\`${d.language ?? ""}\n${(d.rich_text ?? []).map((r: any) => r?.plain_text ?? r?.text?.content ?? "").join("")}\n${indent}\`\`\``,
    quote:              () => text.split("\n").map((l: string) => `${indent}> ${l}`).join("\n"),
    callout:            () => `${indent}> ${d.icon?.emoji ?? "💡"} ${text}`,
    divider:            () => `${indent}---`,
    table:              () => "",
    table_row:          () => `${indent}| ${(d.cells ?? []).map((c: any[]) => rt(c)).join(" | ")} |`,
    image:              () => `${indent}![${rt(d.caption ?? [])}](${d.file?.url ?? d.external?.url ?? ""})`,
    bookmark:           () => `${indent}[${d.caption ? rt(d.caption) : d.url}](${d.url})`,
    link_preview:       () => `${indent}[${d.url}](${d.url})`,
    child_page:         () => `${indent}📄 **${d.title}**`,
    child_database:     () => `${indent}🗃️ **${d.title}**`,
    column_list:        () => "",
    column:             () => "",
    synced_block:       () => "",
  }
  return (m[b.type] ?? (() => `${indent}[${b.type}]`))()
}

async function fetchBlocks(
  id: string, sig?: AbortSignal | null,
  depth = 0, indent = "", tableHeader = false,
): Promise<string[]> {
  const lines: string[] = []
  let cursor: string | undefined
  let hdrDone = false

  do {
    const qs = cursor ? `?start_cursor=${cursor}` : ""
    const res = await req("GET", `/blocks/${id}/children${qs}`, undefined, sig)

    for (const b of res.results) {
      const md = blockMd(b, indent)

      if (b.type === "table_row" && tableHeader && !hdrDone) {
        hdrDone = true
        if (md) lines.push(md)
        lines.push(`${indent}| ${Array.from({ length: (b.table_row?.cells ?? []).length }, () => "---").join(" | ")} |`)
        continue
      }

      if (md) lines.push(md)

      if (b.has_children && depth < DEPTH) {
        const ci = ["bulleted_list_item", "numbered_list_item", "to_do"].includes(b.type)
          ? indent + "  " : indent
        lines.push(...await fetchBlocks(
          b.id, sig, depth + 1, ci,
          b.type === "table" ? (b.table?.has_column_header ?? false) : false,
        ))
        if (b.type === "toggle") lines.push(`${indent}</details>`)
      }
    }

    cursor = res.has_more ? res.next_cursor : undefined
  } while (cursor)

  return lines
}

// ── Markdown → Notion Blocks ────────────────────────────────────────────────

function plainRt(content: string): any {
  return { type: "text", text: { content } }
}

function parseInline(text: string): any[] {
  if (!text) return [plainRt("")]
  const result: any[] = []
  const re = /\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`|~~(.+?)~~|\[([^\]]*)\]\(([^)]*)\)/g
  let last = 0
  let m: RegExpExecArray | null
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) result.push(plainRt(text.slice(last, m.index)))
    if (m[1] != null) result.push({ type: "text", text: { content: m[1] }, annotations: { bold: true } })
    else if (m[2] != null) result.push({ type: "text", text: { content: m[2] }, annotations: { italic: true } })
    else if (m[3] != null) result.push({ type: "text", text: { content: m[3] }, annotations: { code: true } })
    else if (m[4] != null) result.push({ type: "text", text: { content: m[4] }, annotations: { strikethrough: true } })
    else if (m[5] != null) result.push({ type: "text", text: { content: m[5], link: { url: m[6] } } })
    last = m.index + m[0].length
  }
  if (last < text.length) result.push(plainRt(text.slice(last)))
  return result.length ? result : [plainRt(text)]
}

function chunkRt(items: any[]): any[] {
  const out: any[] = []
  for (const item of items) {
    const content = item.text?.content ?? ""
    if (content.length <= RT_LIMIT) { out.push(item); continue }
    for (let i = 0; i < content.length; i += RT_LIMIT) {
      out.push({ ...item, text: { ...item.text, content: content.slice(i, i + RT_LIMIT) } })
    }
  }
  return out
}

function richBlock(type: string, text: string): any {
  return { type, [type]: { rich_text: chunkRt(parseInline(text)) } }
}

function isTableSep(line: string): boolean {
  return /^\|[\s\-:|]+\|$/.test(line.trim())
}

function parseTableCells(line: string): string[] {
  return line.trim().replace(/^\||\|$/g, "").split("|").map(c => c.trim())
}

function listInfo(line: string): { type: string, text: string, indent: number, checked?: boolean } | null {
  const indent = line.search(/\S/)
  if (indent < 0) return null
  const t = line.trim()
  const td = t.match(/^- \[([ x])\] (.*)$/)
  if (td) return { type: "to_do", text: td[2], indent, checked: td[1] === "x" }
  if (/^[-*] /.test(t)) return { type: "bulleted_list_item", text: t.replace(/^[-*] /, ""), indent }
  if (/^[-*]$/.test(t)) return { type: "bulleted_list_item", text: "", indent }
  if (/^\d+\. /.test(t)) return { type: "numbered_list_item", text: t.replace(/^\d+\. /, ""), indent }
  return null
}

function isCodeFenceClose(line: string): boolean {
  return /^`{3,}\s*$/.test(line.trim())
}

function mdToBlocks(markdown: string): any[] {
  const lines = markdown.split("\n")
  const blocks: any[] = []
  let i = 0

  while (i < lines.length) {
    const trimmed = lines[i].trim()

    if (!trimmed) { i++; continue }

    // Divider
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      blocks.push({ type: "divider", divider: {} })
      i++; continue
    }

    // Headings (h1-h3; h4+ degrade to h3 since Notion has no h4)
    const hm = trimmed.match(/^(#{1,6}) (.+)$/)
    if (hm) {
      const lvl = Math.min(hm[1].length, 3) as 1 | 2 | 3
      blocks.push(richBlock(`heading_${lvl}`, hm[2]))
      i++; continue
    }

    // Code block — closing fence must be standalone backticks only
    if (trimmed.startsWith("```")) {
      const lang = trimmed.slice(3).trim()
      const codeLines: string[] = []
      i++
      while (i < lines.length && !isCodeFenceClose(lines[i])) {
        codeLines.push(lines[i])
        i++
      }
      i++ // skip closing ```
      blocks.push({
        type: "code",
        code: { rich_text: chunkRt([plainRt(codeLines.join("\n"))]), language: lang || "plain text" },
      })
      continue
    }

    // Quote (consecutive > lines)
    if (trimmed.startsWith("> ")) {
      const quoteLines: string[] = []
      while (i < lines.length && lines[i].trim().startsWith("> ")) {
        quoteLines.push(lines[i].trim().slice(2))
        i++
      }
      blocks.push(richBlock("quote", quoteLines.join("\n")))
      continue
    }

    // List items (to-do, bulleted, numbered) with one level of nesting
    const li = listInfo(lines[i])
    if (li) {
      const baseIndent = li.indent
      const block = li.type === "to_do"
        ? { type: "to_do", to_do: { rich_text: chunkRt(parseInline(li.text)), checked: li.checked ?? false } }
        : richBlock(li.type, li.text)
      const children: any[] = []
      let j = i + 1
      while (j < lines.length) {
        const child = listInfo(lines[j])
        if (!child || child.indent <= baseIndent) break
        children.push(child.type === "to_do"
          ? { type: "to_do", to_do: { rich_text: chunkRt(parseInline(child.text)), checked: child.checked ?? false } }
          : richBlock(child.type, child.text))
        j++
      }
      if (children.length) block[block.type].children = children
      blocks.push(block)
      i = j; continue
    }

    // Table (collect all | rows)
    if (trimmed.startsWith("|")) {
      const tableLines: string[] = []
      while (i < lines.length && lines[i].trim().startsWith("|")) {
        tableLines.push(lines[i])
        i++
      }
      let hasHeader = false
      const dataRows: string[][] = []
      for (const tl of tableLines) {
        if (isTableSep(tl)) { hasHeader = true; continue }
        dataRows.push(parseTableCells(tl))
      }
      if (!dataRows.length) { i++; continue }
      const width = Math.max(...dataRows.map(r => r.length))
      blocks.push({
        type: "table",
        table: {
          table_width: width,
          has_column_header: hasHeader,
          children: dataRows.map(cells => ({
            type: "table_row",
            table_row: {
              cells: Array.from({ length: width }, (_, ci) => parseInline(cells[ci] ?? "")),
            },
          })),
        },
      })
      continue
    }

    // Image
    const imgMatch = trimmed.match(/^!\[([^\]]*)\]\(([^)]+)\)$/)
    if (imgMatch) {
      blocks.push({
        type: "image",
        image: {
          type: "external",
          external: { url: imgMatch[2] },
          caption: imgMatch[1] ? [plainRt(imgMatch[1])] : [],
        },
      })
      i++; continue
    }

    // Default: paragraph
    blocks.push(richBlock("paragraph", trimmed))
    i++
  }

  return blocks
}

// ── Properties ──────────────────────────────────────────────────────────────

function propText(p: any): string {
  const h: Record<string, () => string> = {
    title:            () => rt(p.title),
    rich_text:        () => rt(p.rich_text),
    number:           () => p.number != null ? String(p.number) : "",
    select:           () => p.select?.name ?? "",
    multi_select:     () => (p.multi_select ?? []).map((s: any) => s.name).join(", "),
    status:           () => p.status?.name ?? "",
    date:             () => !p.date ? "" : p.date.end ? `${p.date.start} → ${p.date.end}` : p.date.start,
    checkbox:         () => p.checkbox ? "☑" : "☐",
    url:              () => p.url ?? "",
    email:            () => p.email ?? "",
    phone_number:     () => p.phone_number ?? "",
    people:           () => (p.people ?? []).map((u: any) => u.name ?? u.id).join(", "),
    relation:         () => (p.relation ?? []).map((r: any) => r.id).join(", "),
    formula:          () => p.formula?.[p.formula.type] != null ? String(p.formula[p.formula.type]) : "",
    rollup:           () => p.rollup?.[p.rollup.type] != null ? JSON.stringify(p.rollup[p.rollup.type]) : "",
    created_time:     () => p.created_time ?? "",
    last_edited_time: () => p.last_edited_time ?? "",
    created_by:       () => p.created_by?.name ?? p.created_by?.id ?? "",
    last_edited_by:   () => p.last_edited_by?.name ?? p.last_edited_by?.id ?? "",
    files:            () => (p.files ?? []).map((f: any) => f.name ?? f.file?.url ?? f.external?.url).join(", "),
    unique_id:        () => p.unique_id ? `${p.unique_id.prefix ?? ""}${p.unique_id.number}` : "",
  }
  return (h[p.type] ?? (() => JSON.stringify(p[p.type] ?? "")))()
}

/** Convert a simple value to Notion property format given the schema type. */
function toNotion(type: string, v: any): any {
  const txt = (k: string) => ({ [k]: chunkRt([{ type: "text", text: { content: v } }]) })
  if (typeof v === "string") {
    if (type === "title") return txt("title")
    if (type === "rich_text") return txt("rich_text")
    if (type === "select") return { select: { name: v } }
    if (type === "status") return { status: { name: v } }
    if (type === "url") return { url: v }
    if (type === "email") return { email: v }
    if (type === "phone_number") return { phone_number: v }
    if (type === "date") {
      const parts = v.split(/\s*→\s*/)
      return parts.length === 2 ? { date: { start: parts[0], end: parts[1] } } : { date: { start: v } }
    }
    if (type === "multi_select") return { multi_select: [{ name: v }] }
    if (type === "relation") return { relation: [{ id: v }] }
    if (type === "people") return { people: [{ id: v }] }
  }
  if (typeof v === "number" && type === "number") return { number: v }
  if (typeof v === "boolean" && type === "checkbox") return { checkbox: v }
  if (Array.isArray(v)) {
    if (type === "multi_select") return { multi_select: v.map((n: string) => ({ name: n })) }
    if (type === "relation") return { relation: v.map((id: string) => ({ id })) }
    if (type === "people") return { people: v.map((id: string) => ({ id })) }
  }
  return v // passthrough for native Notion format
}

/** Look up the database schema, then convert simple {name: value} to Notion properties. */
async function convertProps(dbId: string, input: Record<string, any>, sig?: AbortSignal | null) {
  const db = await req("GET", `/databases/${dbId}`, undefined, sig)
  const schema: Record<string, string> = {}
  for (const [k, v] of Object.entries(db.properties ?? {}) as [string, any][]) schema[k] = v.type

  const out: Record<string, any> = {}
  for (const [k, v] of Object.entries(input)) {
    if (!schema[k]) throw new Error(`Unknown property "${k}". Available: ${Object.keys(schema).join(", ")}`)
    out[k] = toNotion(schema[k], v)
  }
  return out
}

// ── Actions ─────────────────────────────────────────────────────────────────

type Sig = AbortSignal | null | undefined

const actions: Record<string, (p: any, sig: Sig) => Promise<string>> = {
  async search(p, sig) {
    const body: any = { query: p.query, page_size: 20 }
    if (p.filter_type) body.filter = { value: p.filter_type, property: "object" }
    const res = await req("POST", "/search", body, sig)
    if (!res.results.length) return "No results found."

    return res.results.map((r: any) => {
      let title = ""
      if (r.object === "database") title = rt(r.title ?? [])
      else for (const v of Object.values(r.properties ?? {}) as any[]) {
        if (v.type === "title") { title = rt(v.title); break }
      }
      return `- **${title || "Untitled"}** (${r.object}) — id: \`${r.id}\`  ${r.url}`
    }).join("\n")
  },

  async get_page(p, sig) {
    const page = await req("GET", `/pages/${p.page_id}`, undefined, sig)
    let title = ""
    for (const v of Object.values(page.properties ?? {}) as any[]) {
      if (v.type === "title") { title = rt(v.title); break }
    }
    const lines = await fetchBlocks(p.page_id, sig)
    return `# ${title}\n\n${lines.join("\n\n")}\n\n---\nSource: ${page.url}`
  },

  async get_database(p, sig) {
    const db = await req("GET", `/databases/${p.database_id}`, undefined, sig)
    const title = rt(db.title ?? []) || "Untitled"
    const props = db.properties ?? {}
    const lines = [`# ${title}\n`]

    lines.push("| Property | Type | Details |")
    lines.push("| --- | --- | --- |")
    for (const [name, prop] of Object.entries(props) as [string, any][]) {
      let details = ""
      if (prop.type === "select" || prop.type === "status") {
        const options = prop[prop.type]?.options ?? []
        details = options.map((o: any) => o.name).join(", ")
      } else if (prop.type === "multi_select") {
        const options = prop.multi_select?.options ?? []
        details = options.map((o: any) => o.name).join(", ")
      } else if (prop.type === "relation") {
        details = `→ ${prop.relation?.database_id ?? "unknown"}`
      } else if (prop.type === "formula") {
        details = prop.formula?.expression ?? ""
      } else if (prop.type === "rollup") {
        details = `${prop.rollup?.function ?? ""} on ${prop.rollup?.relation_property_name ?? "?"}.${prop.rollup?.rollup_property_name ?? "?"}`
      }
      lines.push(`| ${name.replace(/\|/g, "\\|")} | ${prop.type} | ${details.replace(/\|/g, "\\|")} |`)
    }

    lines.push(`\n---\nDatabase ID: \`${db.id}\`\nSource: ${db.url}`)
    return lines.join("\n")
  },

  async query_database(p, sig) {
    const rows: any[] = []
    let cursor: string | undefined
    let filter: any
    let sorts: any
    if (p.filter) {
      try { filter = JSON.parse(p.filter) } catch { throw new Error("Invalid JSON in filter.") }
    }
    if (p.sorts) {
      try { sorts = JSON.parse(p.sorts) } catch { throw new Error("Invalid JSON in sorts.") }
    }

    do {
      const body: any = { page_size: Math.min(100 - rows.length, 100) }
      if (filter) body.filter = filter
      if (sorts) body.sorts = sorts
      if (cursor) body.start_cursor = cursor
      const res = await req("POST", `/databases/${p.database_id}/query`, body, sig)
      rows.push(...res.results)
      cursor = res.has_more && rows.length < 100 ? res.next_cursor : undefined
    } while (cursor)

    if (!rows.length) return "No results."

    const cols: string[] = []
    const seen = new Set<string>()
    for (const r of rows) for (const k of Object.keys(r.properties ?? {})) {
      if (!seen.has(k)) { seen.add(k); cols.push(k) }
    }

    return [
      `| _id | ${cols.join(" | ")} |`,
      `| --- | ${cols.map(() => "---").join(" | ")} |`,
      ...rows.map((r: any) =>
        `| ${r.id} | ${cols.map(c => (r.properties[c] ? propText(r.properties[c]).replace(/[|\n]/g, " ") : "")).join(" | ")} |`
      ),
    ].join("\n")
  },

  async update_page(p, sig) {
    let input: Record<string, any>
    try { input = JSON.parse(p.properties) } catch { throw new Error("Invalid JSON in properties") }

    const page = await req("GET", `/pages/${p.page_id}`, undefined, sig)
    const dbId = page.parent?.database_id

    let props: Record<string, any>
    if (dbId) {
      props = await convertProps(dbId, input, sig)
    } else {
      // Standalone page — convert using existing property types
      props = {}
      const schema = page.properties ?? {}
      for (const [k, v] of Object.entries(input)) {
        const existing = (schema as any)[k]
        if (existing?.type) {
          props[k] = toNotion(existing.type, v)
        } else {
          props[k] = typeof v === "string"
            ? { rich_text: chunkRt([{ type: "text", text: { content: v } }]) }
            : v
        }
      }
    }

    const updated = await req("PATCH", `/pages/${p.page_id}`, { properties: props }, sig)

    return Object.keys(input)
      .map(k => `${k}: ${propText(updated.properties?.[k] ?? {})}`)
      .join("\n")
  },

  async create_page(p, sig) {
    let input: Record<string, any>
    try { input = JSON.parse(p.properties) } catch { throw new Error("Invalid JSON in properties") }

    const props = await convertProps(p.database_id, input, sig)
    const created = await req("POST", "/pages", {
      parent: { database_id: p.database_id },
      properties: props,
    }, sig)

    let title = ""
    for (const v of Object.values(created.properties ?? {}) as any[]) {
      if (v.type === "title") { title = rt(v.title); break }
    }
    return `Created: ${title || "Untitled"} — id: \`${created.id}\`\n${created.url}`
  },

  async append_blocks(p, sig) {
    const blocks = mdToBlocks(p.content)
    if (!blocks.length) return "No content to append."
    const CHUNK = 100
    let appended = 0
    for (let i = 0; i < blocks.length; i += CHUNK) {
      const chunk = blocks.slice(i, i + CHUNK)
      await req("PATCH", `/blocks/${p.page_id}/children`, { children: chunk }, sig)
      appended += chunk.length
    }
    return `Appended ${appended} block${appended === 1 ? "" : "s"} to page.`
  },
}

const required: Record<string, string[]> = {
  search: ["query"],
  get_page: ["page_id"],
  get_database: ["database_id"],
  query_database: ["database_id"],
  update_page: ["page_id", "properties"],
  create_page: ["database_id", "properties"],
  append_blocks: ["page_id", "content"],
}

// ── Tool ────────────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "notion",
    label: "Notion",
    description:
      "Read and write Notion content. " +
      "Actions: search (find pages/databases), get_page (Markdown, 5 levels deep), " +
      "get_database (schema with property names, types, and options), " +
      "query_database (table with _id column, 100 rows max), " +
      "update_page (set properties on a database row), create_page (new row in a database), " +
      "append_blocks (write Markdown content as blocks to a page). " +
      "For update/create: properties is a JSON object of {name: value}. " +
      "Strings auto-convert to the correct type (text, select, status, url, etc). " +
      "Numbers → number, booleans → checkbox, arrays → multi_select.",
    promptGuidelines: [
      "Use search to find page and database IDs before other actions.",
      "Use get_database to discover property names, types, and valid options before create_page or update_page.",
      "Property names in create_page/update_page must match the database schema exactly (case-sensitive).",
    ],
    parameters: Type.Object({
      action: StringEnum(
        ["search", "get_page", "get_database", "query_database", "update_page", "create_page", "append_blocks"] as const,
        {
          description:
            '"search" — find pages/databases; "get_page" — page as Markdown; ' +
            '"get_database" — schema with property names, types, and options; ' +
            '"query_database" — list rows; "update_page" — set properties; ' +
            '"create_page" — new database row; "append_blocks" — write Markdown content to a page.',
        },
      ),
      query: Type.Optional(Type.String({ description: "Search text (required for search)." })),
      page_id: Type.Optional(Type.String({ description: "Page ID (required for get_page, update_page)." })),
      database_id: Type.Optional(Type.String({ description: "Database ID (required for get_database, query_database, create_page)." })),
      filter: Type.Optional(Type.String({ description: "JSON filter for query_database." })),
      filter_type: Type.Optional(StringEnum(["page", "database"] as const, { description: "Limit search to page or database." })),
      sorts: Type.Optional(Type.String({
        description:
          'JSON sorts array for query_database. ' +
          'Example: [{"property": "Created", "direction": "descending"}]',
      })),
      properties: Type.Optional(Type.String({
        description:
          'JSON {name: value} for update_page/create_page. ' +
          'Example: {"Description": "text here", "Status": "Done"}',
      })),
      content: Type.Optional(Type.String({
        description:
          "Markdown content to append as blocks (required for append_blocks). " +
          "Supports headings, paragraphs, lists, code blocks, tables, quotes, dividers, " +
          "and inline formatting (bold, italic, code, links).",
      })),
    }),

    async execute(_id, params, signal) {
      try {
        validateRequired(params.action, params, required[params.action] ?? [])
        const handler = actions[params.action]
        if (!handler) throw new Error(`Unknown action: ${params.action}`)
        return toolSuccess(params.action, await handler(params, signal))
      } catch (err: any) {
        if (err.name === "AbortError") throw new Error("Cancelled")
        throw err
      }
    },

    renderCall(args, theme) {
      let t = theme.fg("toolTitle", theme.bold("notion "))
      t += theme.fg("accent", args.action)
      if (args.query) t += " " + theme.fg("dim", `"${args.query}"`)
      if (args.page_id) t += " " + theme.fg("muted", args.page_id.slice(0, 12) + "…")
      if (args.database_id) t += " " + theme.fg("muted", args.database_id.slice(0, 12) + "…")
      if (args.content) t += " " + theme.fg("dim", `${args.content.length} chars`)
      return new Text(t, 0, 0)
    },

    renderResult(result, { expanded, isPartial }, theme) {
      if (isPartial) return new Text(theme.fg("warning", "Fetching…"), 0, 0)

      if (result.isError) {
        const msg = result.content[0]?.type === "text" ? result.content[0].text : "Error"
        return new Text(theme.fg("error", msg), 0, 0)
      }

      const d = result.details as { action: string; truncated?: boolean } | undefined
      let t = theme.fg("success", `✓ ${d?.action ?? "done"}`)
      if (d?.truncated) t += theme.fg("warning", " (truncated)")

      if (expanded) {
        const c = result.content[0]
        if (c?.type === "text") {
          const lines = c.text.split("\n").slice(0, 40)
          for (const l of lines) t += `\n${theme.fg("dim", l)}`
          if (c.text.split("\n").length > 40) t += `\n${theme.fg("muted", "…")}`
        }
      }

      return new Text(t, 0, 0)
    },
  })
}
