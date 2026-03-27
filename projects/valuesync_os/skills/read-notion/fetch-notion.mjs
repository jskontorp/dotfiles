/**
 * Fetch a Notion page (or specific section) and render it as Markdown.
 *
 * Usage:
 *   node --env-file=.env.local .pi/skills/read-notion/fetch-notion.mjs [pageId] [--section "heading text"]
 *
 * Env:
 *   NOTION_API_KEY — Notion internal integration token (set in .env.local)
 *
 * Defaults to the MVP Specification page if no pageId is provided.
 */

const NOTION_VERSION = "2022-06-28"
const MVP_PAGE_ID = "2fdeb2c4-0781-80cf-a584-c98a5837a19c"

const API_KEY = process.env.NOTION_API_KEY
if (!API_KEY) {
  console.error("Error: NOTION_API_KEY is not set in .env.local")
  process.exit(1)
}

// ---------------------------------------------------------------------------
// Notion API helpers
// ---------------------------------------------------------------------------

async function notionFetch(path) {
  const res = await fetch(`https://api.notion.com/v1${path}`, {
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      "Notion-Version": NOTION_VERSION,
    },
  })
  if (!res.ok) {
    const body = await res.text()
    throw new Error(`Notion API ${res.status}: ${body}`)
  }
  return res.json()
}

async function getBlockChildren(blockId) {
  const blocks = []
  let cursor
  do {
    const qs = cursor ? `?start_cursor=${cursor}&page_size=100` : "?page_size=100"
    const data = await notionFetch(`/blocks/${blockId}/children${qs}`)
    blocks.push(...data.results)
    cursor = data.has_more ? data.next_cursor : null
  } while (cursor)
  return blocks
}

async function getBlocksRecursive(blockId, depth = 0, maxDepth = 5) {
  const blocks = await getBlockChildren(blockId)
  const result = []
  for (const block of blocks) {
    result.push({ ...block, depth })
    if (block.has_children && depth < maxDepth) {
      const children = await getBlocksRecursive(block.id, depth + 1, maxDepth)
      result.push(...children)
    }
  }
  return result
}

// ---------------------------------------------------------------------------
// Rich text → plain text
// ---------------------------------------------------------------------------

function richTextToPlain(richTextArray) {
  if (!richTextArray) return ""
  return richTextArray
    .map((rt) => {
      let text = rt.plain_text || ""
      if (rt.annotations?.bold) text = `**${text}**`
      if (rt.annotations?.italic) text = `*${text}*`
      if (rt.annotations?.code) text = `\`${text}\``
      if (rt.annotations?.strikethrough) text = `~~${text}~~`
      if (rt.href) text = `[${text}](${rt.href})`
      return text
    })
    .join("")
}

// ---------------------------------------------------------------------------
// Block → Markdown
// ---------------------------------------------------------------------------

function blockToMarkdown(block, indent = "") {
  const type = block.type
  const data = block[type]

  switch (type) {
    case "heading_1":
      return `# ${richTextToPlain(data.rich_text)}`
    case "heading_2":
      return `## ${richTextToPlain(data.rich_text)}`
    case "heading_3":
      return `### ${richTextToPlain(data.rich_text)}`
    case "paragraph":
      return richTextToPlain(data.rich_text) || ""
    case "bulleted_list_item":
      return `${indent}- ${richTextToPlain(data.rich_text)}`
    case "numbered_list_item":
      return `${indent}1. ${richTextToPlain(data.rich_text)}`
    case "to_do":
      return `${indent}- [${data.checked ? "x" : " "}] ${richTextToPlain(data.rich_text)}`
    case "toggle":
      return `<details><summary>${richTextToPlain(data.rich_text)}</summary></details>`
    case "quote":
      return `> ${richTextToPlain(data.rich_text)}`
    case "callout":
      return `> ${data.icon?.emoji || "💡"} ${richTextToPlain(data.rich_text)}`
    case "code":
      return `\`\`\`${data.language || ""}\n${richTextToPlain(data.rich_text)}\n\`\`\``
    case "divider":
      return "---"
    case "table_row":
      return `| ${(data.cells || []).map((cell) => richTextToPlain(cell)).join(" | ")} |`
    case "table":
      return "" // table rows are children
    case "image":
      return `![image](${data.file?.url || data.external?.url || ""})`
    case "bookmark":
      return `[${data.url}](${data.url})`
    case "link_preview":
      return `[${data.url}](${data.url})`
    case "embed":
      return `[Embed: ${data.url}](${data.url})`
    case "child_page":
      return `📄 **${data.title}**`
    case "child_database":
      return `🗃️ **${data.title}**`
    case "table_of_contents":
      return `[table_of_contents]`
    case "column_list":
    case "column":
    case "synced_block":
      return "" // structural, children handle the content
    default:
      return `<!-- unsupported block type: ${type} -->`
  }
}

// ---------------------------------------------------------------------------
// Render full page
// ---------------------------------------------------------------------------

function renderBlocks(blocks) {
  const lines = []
  let prevType = null
  let tableHeaderRendered = false
  let tableHasHeader = false

  for (const block of blocks) {
    const indent = "  ".repeat(block.depth || 0)
    const type = block.type

    // Track table context for header separator
    if (type === "table") {
      const data = block[type]
      tableHasHeader = data?.has_column_header ?? false
      tableHeaderRendered = false
    }

    const md = blockToMarkdown(block, indent)

    // Add spacing between different block types
    if (
      prevType &&
      prevType !== type &&
      !["table_row", "column", "column_list", "synced_block"].includes(type)
    ) {
      lines.push("")
    }

    if (md !== "") {
      lines.push(md)

      // Insert separator after the first table_row if the table has a header
      if (type === "table_row" && tableHasHeader && !tableHeaderRendered) {
        const data = block[type]
        const colCount = (data.cells || []).length
        lines.push(`| ${Array(colCount).fill("---").join(" | ")} |`)
        tableHeaderRendered = true
      }
    }
    prevType = type
  }

  return lines.join("\n")
}

// ---------------------------------------------------------------------------
// Section filtering
// ---------------------------------------------------------------------------

function extractSection(blocks, sectionHeading) {
  const lower = sectionHeading.toLowerCase()
  let capturing = false
  let captureLevel = null
  const result = []

  for (const block of blocks) {
    const type = block.type
    if (["heading_1", "heading_2", "heading_3"].includes(type)) {
      const headingLevel = parseInt(type.split("_")[1])
      const text = richTextToPlain(block[type].rich_text).toLowerCase()

      if (!capturing && text.includes(lower)) {
        capturing = true
        captureLevel = headingLevel
        result.push(block)
        continue
      }

      if (capturing && headingLevel <= captureLevel) {
        break // reached next section at same or higher level
      }
    }

    if (capturing) {
      result.push(block)
    }
  }

  return result
}

// ---------------------------------------------------------------------------
// Search pages
// ---------------------------------------------------------------------------

async function searchPages(query) {
  const res = await fetch("https://api.notion.com/v1/search", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      "Notion-Version": NOTION_VERSION,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      query,
      filter: { value: "page", property: "object" },
      page_size: 10,
    }),
  })
  const data = await res.json()
  return (data.results || []).map((p) => ({
    id: p.id,
    title: p.properties?.title?.title?.map((t) => t.plain_text).join("") || "(untitled)",
    url: p.url,
    lastEdited: p.last_edited_time,
  }))
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const args = process.argv.slice(2)

const hasSearch = args.includes("--search")
const sectionIdx = args.indexOf("--section")
const hasSection = sectionIdx !== -1

if (hasSearch && hasSection) {
  console.error("Error: --search and --section cannot be used together")
  process.exit(1)
}

// Collect positional args (everything that isn't a flag or its trailing values)
const positionalArgs = []
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--search" || args[i] === "--section") {
    // Both flags consume all remaining args as their value
    break
  }
  positionalArgs.push(args[i])
}

if (hasSearch) {
  // Everything after --search is the query
  const searchIdx = args.indexOf("--search")
  const query = args.slice(searchIdx + 1).join(" ")

  // Error if a page ID was also provided
  if (positionalArgs.length > 0) {
    console.error("Error: --search cannot be combined with a page ID")
    process.exit(1)
  }

  const results = await searchPages(query)
  console.log("Search results:\n")
  for (const r of results) {
    console.log(`  ${r.title}`)
    console.log(`    ID: ${r.id}`)
    console.log(`    URL: ${r.url}`)
    console.log(`    Last edited: ${r.lastEdited}`)
    console.log()
  }
  process.exit(0)
}

let sectionHeading = null
if (hasSection && args[sectionIdx + 1]) {
  sectionHeading = args.slice(sectionIdx + 1).join(" ")
}

// pageId is the first positional arg (not a flag)
const pageId = positionalArgs[0] || MVP_PAGE_ID

console.error(`Fetching page ${pageId}...`)
const allBlocks = await getBlocksRecursive(pageId)
console.error(`Fetched ${allBlocks.length} blocks`)

let blocks = allBlocks
if (sectionHeading) {
  blocks = extractSection(allBlocks, sectionHeading)
  if (blocks.length === 0) {
    console.error(`No section found matching "${sectionHeading}"`)
    console.error("Available headings:")
    for (const b of allBlocks) {
      if (["heading_1", "heading_2", "heading_3"].includes(b.type)) {
        const level = b.type.split("_")[1]
        const text = richTextToPlain(b[b.type].rich_text)
        console.error(`  ${"#".repeat(parseInt(level))} ${text}`)
      }
    }
    process.exit(1)
  }
  console.error(`Filtered to ${blocks.length} blocks in section "${sectionHeading}"`)
}

console.log(renderBlocks(blocks))
