---
name: read-notion
description: >-
  Fetch Notion pages as Markdown. Use when the user references Notion content —
  specs, docs, requirements, or any page by ID or keyword.
compatibility: Requires Node.js and NOTION_API_KEY in .env.local
---

# Read Notion

Fetch Notion pages and render them as Markdown using the bundled `fetch-notion.mjs` script.

Prefer this over the built-in Notion tool when you need section-level filtering,
deeper nesting (5 levels), or richer Markdown output.

## Usage

All commands use this base:

```bash
node --env-file=.env.local .pi/skills/read-notion/fetch-notion.mjs [pageId] [flags]
```

| Goal | Command |
|------|---------|
| Fetch a page | `... <pageId>` |
| Fetch a section | `... <pageId> --section "Heading Text"` |
| Search by keyword | `... --search "query"` |

`--search` and `--section` are mutually exclusive.

If `--section` finds no match, available headings are printed to stderr — retry with one of those.

## Notes

- Markdown to stdout, progress/errors to stderr
- Recursion depth: 5 levels
