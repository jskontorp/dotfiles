---
name: notion-write
description: >-
  Draft and execute Notion page/database writes via @feniix/pi-notion with a
  confirm-before-write loop. Use when the user says "create a notion page",
  "add to notion", "update the notion doc", "file a note in notion", or
  similar. The correct workspace (Volve vs. personal) is auto-selected from
  cwd by the shell wrapper in pi-notion-routing.zsh — do not try to pass a
  workspace yourself. Writes are gated; reads are not.
claude-compatible: false
---

# Notion writes (draft → confirm → execute)

The `notion-routing.ts` extension wraps every Notion write (`notion-create-*`,
`notion-update-*`, `notion-move-*`, `notion-duplicate-*`) with a preview +
confirm gate, except `notion-create-comment` and `notion-duplicate-page`,
which are deliberately ungated (short/frequent and sibling-only-trivial-to-
trash, respectively). Reads (`notion-search`, `notion-fetch`, `notion-query-*`,
`notion-get-comments`) pass through.

Your job: produce a clean draft on the first call. The user sees a markdown
preview and picks the action button (e.g. `create pages`) / `revise` /
`cancel`. On `revise`, the tool call is blocked with their feedback as the
reason — redraft from that feedback and call again.

## Before drafting a write

- **Fetch the parent first.** For `notion-create-pages` into a database, call
  `notion-fetch` on the database or data-source id and read its schema before
  drafting `properties`. Schema drift is the #1 cause of failed creates.
- **Don't invent database ids.** If the user said "the ADR database", run
  `notion-search` first. Do not guess.
- **For `notion-update-page update_content`**, call `notion-fetch` on the
  target page and copy the literal `old_str` exactly. Do not paraphrase —
  search-replace must match byte-for-byte.

## Shape rules (common LLM mistakes)

- **Title lives inside `properties`**, not as a sibling `title` field. For a
  page whose database has a `Name` title property:
  `properties: { Name: { title: [{ text: { content: "…" } }] } }`.
- **H1 is stripped from `content`** on page creation. Do not echo the page
  title as an H1 in the body. Lead with H2 if you need a heading.
- **`replace_content` is destructive.** It overwrites the entire page body.
  Use it only when the user explicitly asked to overwrite. For surgical
  edits, use `update_content` (search-replace pairs). For field tweaks, use
  `update_properties`.
- **Blocks vs. markdown.** `content` accepts markdown-like input that
  @feniix converts to Notion blocks. Prefer standard markdown (headings,
  bullets, checklists, callouts, toggles) over exotic constructs — they
  won't round-trip.

## Voice

Notion pages have a mixed audience — engineers, PMs, founders. Same rule as
the linear-issue skill:

- Gloss load-bearing jargon in the **title** and the **opening paragraph** so
  a non-engineer reader doesn't hit a wall. Weave the clarification into the
  same sentence.
- Do **not** gloss standard team vocabulary: API, PR, deploy, branch, merge,
  migration, rollback, commit, CI, staging, prod, etc.
- In deeper technical sections (code snippets, stack traces, config), use
  engineer-voice — terse, precise.
- No separate "simple version" section. Clarification is woven, not stacked.
- If the note is three lines, keep it three lines. Don't bloat.
- No filler. No "this doc is about…", no restating the title.

## Handle the gate result

- **Action button picked** (e.g. `create pages`) → the write runs. Report
  the resulting page URL or id, nothing else.
- **`revise`** → the tool call is blocked with a reason starting with
  `User requested changes` and containing the user's feedback. Apply the
  feedback, call the same tool again. The gate will show the new preview.
- **`cancel`** → the tool call is blocked. Acknowledge briefly and stop.

## Do not

- Do not pass workspace, OAuth tokens, or `NOTION_MCP_AUTH_FILE` yourself.
  Routing is automatic via the shell wrapper.
- Do not call a write tool more than once without gate feedback in between.
- Do not combine `replace_content` with `update_content` in one call plan —
  replace wins and makes the update moot.
