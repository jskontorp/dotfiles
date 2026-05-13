---
name: compose-shortcut
description: Author an Apple iOS Shortcut by writing a Cherri (.cherri) source file, then compile and deliver it to the user's iPhone via iCloud Drive. Use when the user says "make/build/create a shortcut" (referring to iOS Shortcuts, not keyboard shortcuts), "automate X on my iphone", "I want my phone to <do something>", "shortcut to <verb>", "ship this shortcut", or asks to edit/iterate on an existing .cherri or .shortcut file in this repo. Only active inside ~/code/personal/iphone-shortcuts.
allowed-tools: Read, Write, Edit, Bash(just dev:*), Bash(just action:*), Bash(just doctor:*), Bash(just edit:*), Bash(just list:*), Bash(just clean:*), Bash(cherri --action=*), Bash(ls:*), Bash(cat:*)
claude-compatible: true
---

# compose-shortcut

Help the user create or edit iPhone Shortcuts by writing Cherri (`.cherri`) source
files and delivering compiled `.shortcut` artifacts to their iPhone.

## When this fires

- "make/build/create a shortcut that …" (iOS Shortcuts, not keyboard shortcuts)
- "automate <X> on my iphone/phone"
- "I want my phone to <do something>"
- "shortcut to <verb>"
- "edit the <name> shortcut"
- "ship this shortcut" / "send to my phone"

Disambiguate: if the user means keyboard shortcuts, application hotkeys, or
URL shortcuts, **don't fire** — those are different domains.

## Required reading before drafting code

Paths below are relative to the repo root (`~/code/personal/iphone-shortcuts`),
which is also cwd when this skill is active.

1. `reference/cherri-llm-guide.md` — the canonical Cherri syntax guide. Read it
   in full before drafting code. Do not invent action names; if you're unsure an
   action exists, say so and point the user at `https://cherrilang.org` or the
   Cherri GitHub repo.
2. `examples/*.cherri` (if any exist) — match the user's existing patterns.
3. `AGENTS.md` — repo-local rules, including the dependency note and the
   network call warning for `just ship`.

## Workflow

### New shortcut

1. Read `reference/cherri-llm-guide.md`.
2. Ask the user one clarifying question only if the request is ambiguous in a
   way the wrong interpretation would waste work (e.g. "should this trigger
   from the share sheet, or be standalone?"). Otherwise proceed.
3. Pick a kebab-case slug. Write `examples/<slug>.cherri`. Always include the
   `#define name "<Title Case>"`, `#define color <name>`, `#define glyph <name>`
   header — keeps shortcuts visually distinguishable on the phone.
4. Show the source to the user inline in your reply. Brief.
5. Run `just dev examples/<slug>.cherri` to compile unsigned (fast feedback).
6. **If compile fails**: surface the full stderr verbatim. Do not paper over
   errors. Suggest a fix based on the guide, but let the user decide whether to
   apply it — they may want to change the spec instead. v0 has no automated
   retry loop; the iteration is in-conversation.
7. **If compile succeeds**: ask whether the user wants to `just ship` (signed,
   delivered to iCloud Drive Inbox). Do **not** run `just ship` without explicit
   confirmation — it's a network call to Apple servers and produces a delivered
   artifact.

### Editing an existing shortcut

1. If editing the source: read `examples/<slug>.cherri`, propose edits, write,
   `just dev` to verify, then offer `just ship`.
2. If the user only has a `.shortcut` artifact (e.g. one they made on phone and
   AirDropped back): suggest `just edit <path>` to decompile to source first.
   Then proceed as above.

## Hard rules

- **Never edit `.shortcut` files directly.** They're generated. Source of truth
  is `.cherri`.
- **Never `just ship` without explicit user confirmation.** Apple signing is a
  network call tied to the user's iCloud identity. Always ask.
- **Never trust the vendored LLM_GUIDE blindly.** Several action names in it are
  stale relative to Cherri 2.2.0 (e.g. `askText` doesn't exist; the real name
  is `prompt`). Before using any action you haven't personally verified in this
  session, run `just action <name>` (which calls `cherri --action=<name>`).
  Cherri itself is the source of truth.
- **Never invent Cherri action names.** If `just action <name>` returns
  "does not exist", look at the "closest actions" suggestions, pick one, and
  verify *that*. If still no match, surface the gap to the user and let them
  decide (manually check Cherri's repo, or declare a custom one via
  `#define action 'IntentIdentifier' name(…)`).
- **Never auto-commit.** The user controls their git history.
- **Filename collisions matter on iPhone.** `just ship` appends a timestamp
  suffix to the delivered file specifically to avoid this — don't try to
  override it without a reason.

## What to show in your reply

When you draft a shortcut:
1. A one-line summary of what it does
2. The `.cherri` source as a code block
3. The command you'll run (`just dev examples/<slug>.cherri`)

Then run the command. Show the output. Ask: ship to phone, or iterate?

Keep replies short. The user is in a tight authoring loop.
