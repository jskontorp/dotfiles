---
name: linear-issue
description: >-
  Draft and create a Linear issue via @fink-andreas/pi-linear-tools with a
  confirm-before-create loop. Use when the user says "create a linear issue",
  "file a ticket", "add to linear", or similar. The correct workspace (Volve
  vs. personal) is auto-selected from cwd by the linear-routing extension —
  do not try to pass an API key or workspace yourself.
claude-compatible: false
---

# Linear issue (draft → confirm → create)

A confirm gate wraps write actions on the `linear_*` tools (create, update,
delete, archive, unarchive). `comment` and `start` skip the gate — comments
are short and frequent, `start` just moves state to In Progress. Produce a
clean draft on the first call; the user sees a preview and picks the action
button (e.g. `create`) / `revise` / `cancel`. If they pick `revise`, the tool
call is blocked with their feedback as the reason — redraft from that
feedback and call again.

## Draft

Infer these fields from the conversation. Do not ask for things you can
reasonably pick yourself.

- **title** — one clear line, imperative mood, no ticket prefixes.
- **description** — see *Voice* below.
- **team** — suggest one based on the repo / topic. If you truly don't know,
  call `linear_team` with `action: "list"` once, then decide.
- **priority** — suggest one: `1` Urgent, `2` High, `3` Medium, `4` Low, `0` No priority.
  Default bias: `3` Medium for bugs, `4` Low for chores. Suggest `2` High only
  when the user's wording signals urgency.

Do **not** set a workflow state. Leave it unset so the issue lands in Triage
(the default). An LLM-drafted issue should not jump the queue.

## Voice

Linear issues are read by a mixed audience — engineers, PMs, founders. Aim
the draft so anyone on the team can follow, without stripping technical
precision. The rule is **calibrated**, not all-or-nothing:

- In the **title** and the **opening line** of the description, gloss any
  domain-specific term or non-obvious acronym a non-engineer would stumble on
  (e.g. *"the OIDC handshake — the sign-in round-trip with the identity
  provider"*). Weave the clarification into the same sentence; never a separate
  "simple version" section.
- **Do not** gloss standard team vocabulary: API, PR, deploy, branch, merge,
  migration, rollback, commit, CI, staging, prod, etc. Readers know these.
- In deeper **technical sections** (repro steps, stack traces, code snippets,
  diffs), write engineer-voice — terse, precise, no padding.
- Keep it short. If the issue is three lines, it stays three lines. Don't
  bloat a bug ticket with glossing.

Other drafting rules:

- No filler. No "this ticket is about…", no restating the title in the body.
- Bullet points welcome when they aid scanning.
- Stick to what the user said or what is directly inferable — don't invent
  context, acceptance criteria, or stakeholders.

## Call the tool

Call `linear_issue` with `action: "create"` and the fields you inferred. The
extension renders a markdown preview and prompts the user.

## Handle the result

- **Action button (e.g. `create`)** → issue is created. Report the issue key + URL, nothing else.
- **`revise`** → the tool call is blocked with a reason starting with
  `User requested changes` and containing the user's feedback. Apply the
  feedback, call `linear_issue create` again. The gate will show the new
  preview.
- **`cancel`** → the tool call is blocked. Acknowledge briefly and stop.
