---
name: notion-write
description: >-
  Draft and execute Notion page/database writes via the in-repo `notion`
  extension with a confirm-before-write loop. Use when the user says
  "create a notion page", "add to notion", "update the notion doc", "file
  a note in notion", or similar. The correct workspace (Volve vs.
  personal) is auto-selected from cwd by the extension — do not try to
  pass a workspace yourself. Writes are gated; reads are not.
claude-compatible: false
---

# Notion writes (draft → confirm → execute)

The `notion` tool is action-dispatched. A confirm gate wraps the write
actions `create_page`, `update_page`, and `append_blocks`. `create_comment`
skips the gate — comments are short and frequent. Reads (`search`,
`get_page`, `get_database`, `query_database`) pass through.

Your job: produce a clean draft on the first call. The user sees a
markdown preview and picks the action button (e.g. `create_page`) /
`revise` / `cancel`. On `revise`, the tool call is blocked with their
feedback as the reason — redraft from that feedback and call again.

## Before drafting a write

- **Fetch the parent first.** For `create_page` into a database, call
  `notion` with `action: "get_database"` and the database_id, read its
  property schema, then draft `properties` against it. Schema drift is the
  #1 cause of failed creates.
- **Don't invent ids.** If the user said "the ADR database", run
  `notion` with `action: "search"` first. Do not guess.
- **404 means "not shared".** If a read fails with 404, the page or
  database is most likely not connected to the integration. Tell the user
  to open it in Notion, click ··· → Connections, and add the integration
  for the current workspace.

## Property-shape rules (common LLM mistakes)

The extension auto-converts simple values to Notion property objects
based on the database schema:

- string → `title` / `rich_text` / `select` / `status` / `url` / `email` /
  `phone_number` / `date` / `multi_select` (single tag) / `relation`
  (single id) / `people` (single id)
- number → `number`
- boolean → `checkbox`
- array → `multi_select` (tag names) / `relation` (ids) / `people` (ids)

For any other property type, or for full control (e.g. a date range, a
specific colour on a select option), pass a literal Notion property
object, e.g. `{"Due": {"date": {"start": "2026-06-01", "end": "2026-06-30"}}}`.

Computed property types — `formula` and `rollup` — are rejected with a
clear error. Notion does not let the API set them; trying to write one
silently no-ops in v1, which is why we refuse upfront.

## Voice

Notion pages have a mixed audience — engineers, PMs, founders. Same rule
as the linear-issue skill:

- Gloss load-bearing jargon in the **title** and the **opening paragraph**
  so a non-engineer reader doesn't hit a wall. Weave the clarification
  into the same sentence.
- Do **not** gloss standard team vocabulary: API, PR, deploy, branch,
  merge, migration, rollback, commit, CI, staging, prod, etc.
- In deeper technical sections (code snippets, stack traces, config), use
  engineer-voice — terse, precise.
- No separate "simple version" section. Clarification is woven, not stacked.
- If the note is three lines, keep it three lines. Don't bloat.
- No filler. No "this doc is about…", no restating the title.

## Limitations to know

- **No surgical edit-in-place.** The previous feniix-based shape had
  `update_content` / `replace_content` (search-replace inside page body).
  This is gone. To change page content, either:
  1. **Additive only:** call `append_blocks` with the new markdown.
  2. **Full rewrite:** fetch existing content via `get_page`, recompose
     the body locally, and call `append_blocks` after archiving/clearing
     the page manually in Notion. There is no API-level page-body-replace
     primitive in v1.
- **No duplicate / move.** Out of scope until a real workflow needs them.
- **Comments**: use `create_comment` with `page_id` (new thread) or
  `discussion_id` (reply). Ungated.

## Handle the gate result

- **Action button picked** (e.g. `create_page`) → the write runs. Report
  the resulting page URL or id, nothing else.
- **`revise`** → the tool call is blocked with a reason starting with
  `User requested changes` and containing the user's feedback. Apply the
  feedback, call the same tool again. The gate will show the new preview.
- **`cancel`** → the tool call is blocked. Acknowledge briefly and stop.

## Do not

- Do not pass workspace, OAuth tokens, or integration tokens yourself.
  Routing is automatic from cwd.
- Do not call a write tool more than once without gate feedback in between.
- Do not pass a value for a `formula` or `rollup` property — the API
  doesn't accept it and the extension rejects it upfront.
