---
name: research-wiki
description: Look up or ingest LLM/prompting research in the volve-research-wiki at ~/code/work/volve-research-wiki/. Use when the user explicitly says "check the research wiki", "look up research", "search the research wiki", "ingest research", "add to the research wiki", "wiki research", or similar verbatim phrases containing the word "research" alongside a wiki/lookup/ingest verb. The wiki holds literature notes (arXiv, Hugging Face Papers, blog clippings) on LLM techniques, prompting, agent memory, RAG, eval — anything literature-grounded rather than volve-ai-specific.
disable-model-invocation: true
---

# research-wiki

A user-private, LLM-maintained research wiki sibling to volve-ai. Pattern: Karpathy `llm-wiki` (April 2026). Location: `~/code/work/volve-research-wiki/`. The wiki has its own schema doc — `~/code/work/volve-research-wiki/AGENTS.md` — which is the source of truth for how to read from and write to it. **Read that file before doing any work against the wiki.** This skill is just the routing layer.

## When to use

Only when the user explicitly invokes it with a verbatim phrase containing "research" plus a verb (look up / check / search / ingest / add). Do not auto-fire on generic mentions of papers, prompting, or RAG.

## Two ops

### Lookup

User says something like *"check the research wiki on contradiction detection"*:

1. Read `~/code/work/volve-research-wiki/wiki/index.md` first — that's the catalog.
2. Drill into 1–3 candidate pages (`wiki/techniques/*.md` or `wiki/papers/*.md`).
3. Cite by relative path when answering. If you used a technique page, also surface the underlying paper IDs so the user can chase provenance.
4. If the wiki doesn't cover the question, say so plainly. Don't fabricate. The wiki's coverage is intentionally narrow.

### Ingest

User says something like *"ingest this paper into the research wiki"* with an arXiv ID, HF papers URL, or blog URL:

1. Read `~/code/work/volve-research-wiki/AGENTS.md` for the canonical ingest spec.
2. Follow that spec verbatim — including provenance tier, anti-smoothing rules, and log-entry format.
3. Update at most 3 technique pages per ingest; never more than 5 sources in a sitting (compilation-gap mitigation).

## Boundaries (load-bearing — do not violate)

- **No volve-ai operational content in the wiki.** Project-specific applications stay in `~/code/work/volve-ai/app/agents/<name>/CLAUDE.md` or equivalent. Cross-reference from the wiki *to* volve-ai, never the other way.
- **The wiki's `AGENTS.md` overrides this skill on any conflict.** This file routes; that file governs.
- **Markdown links, not wikilinks.** Filesystem-native — `[name](../techniques/name.md)`.
- **Provenance is mandatory** on every page (`read` / `abstract` / `secondary`).

## What this skill does not do

- Does not maintain its own state. The wiki is canonical.
- Does not summarize papers without ingesting them — if the user wants a summary, ingest creates the durable artifact; ad-hoc summarization without ingest defeats the compounding bet.
- Does not push the wiki repo. Commits are fine (single-user, private remote `github.com/jskontorp/volve-research-wiki`). Pushing requires user approval per the destructive-actions rules.
