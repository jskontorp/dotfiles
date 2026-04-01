# Claude Code Wishlist for Pi

What Claude Code does that pi should learn from — organized by effort,
all high impact. Based on deep reading of Claude Code source (`~/Downloads/src`),
snainm competition post-mortems, and pi session failure analysis.

---

## Tier 1: Prompt-Only (zero code, immediate)

These are system prompt or AGENTS.md additions. No pi source changes.

### 1.1 Output length anchors

Claude Code uses numeric anchors instead of qualitative "be concise":

> "Keep text between tool calls to ≤25 words. Keep final responses to
> ≤100 words unless the task requires more detail."

Their measurement: ~1.2% output token reduction vs. qualitative.
Numeric targets give the model a concrete stopping point.

**Status:** Added to AGENTS.md *(partially — no numeric anchors yet,
just behavioral rules)*

### 1.2 Risky action gate

Claude Code's `getActionsSection()` has a detailed blast-radius framework:

> "Carefully consider the reversibility and blast radius of actions.
> Generally you can freely take local, reversible actions like editing
> files or running tests. But for actions that are hard to reverse,
> affect shared systems beyond your local environment, or could
> otherwise be risky or destructive, check with the user before
> proceeding."

With explicit examples: force-push, reset --hard, deleting branches,
pushing code, commenting on PRs. The principle: **authorization is
scoped, not blanket** — approving `git push` once doesn't mean always.

Pi has no equivalent. The model pushes, amends, and force-pushes
without a structural check.

### 1.3 Compaction scratchpad technique

Claude Code's compaction prompt uses `<analysis>` tags as a
chain-of-thought scratchpad, then **strips them** from the final
summary via `formatCompactSummary()`. The model reasons before
summarizing, but only the summary enters context.

Pi's compaction prompt asks directly for the summary. Adding the
analysis-then-strip pattern would improve summary quality with
zero code change (just prompt text in the compaction module).

### 1.4 Compaction structure

Claude Code's compaction prompt has 9 explicit sections:

1. Primary Request and Intent
2. Key Technical Concepts
3. Files and Code Sections (with snippets)
4. Errors and fixes
5. Problem Solving
6. **All user messages** (critical — preserves intent drift)
7. Pending Tasks
8. Current Work (most recent messages emphasized)
9. Optional Next Step (with verbatim quotes to prevent drift)

Pi's compaction uses Goal / Constraints / Progress / Key Decisions /
Next Steps / Critical Context. Missing: explicit user message
preservation, error tracking, and the current-work emphasis that
prevents post-compaction drift.

### 1.5 File read dedup stub

Claude Code returns a stub for re-reads of unchanged files:

> "File unchanged since last read. The content from the earlier Read
> tool_result in this conversation is still current — refer to that
> instead of re-reading."

Checked via mtime comparison. Saves tokens when the model re-reads
files it already has in context. Could be added as a prompt instruction
(weaker than code enforcement but still effective):

> "Before re-reading a file you already read in this conversation,
> consider whether the file has changed. If you wrote to it, re-read.
> If not, refer to the earlier read result."

---

## Tier 2: Small Code Changes (~50-200 lines in pi source)

These require changes to pi's tool implementations or compaction logic.

### 2.1 Read-before-edit gate ⭐ (highest single-item impact)

Claude Code tracks a `readFileState` map: when each file was last read,
its content, and mtime. The edit tool **rejects edits** to files that
haven't been read:

> "File has not been read yet. Read it first before writing to it."

Also rejects if the file was modified since last read:

> "File has been modified since read, either by the user or by a linter.
> Read it again before attempting to write it."

**Session evidence:** Edit failures ("Could not find the exact text")
appear across projects — valuesync, snainm, dotfiles, superconductors.
These are often caused by the model guessing at file content instead of
reading first.

**Implementation:** ~30 lines. A `Map<string, {content, timestamp}>` set
by the read tool, checked by the edit tool's validation. The edit tool
already reads the file for matching — this just gates the attempt.

Pi's edit tool already has uniqueness validation (rejects ambiguous
matches) and fuzzy matching. The read-before-edit gate is the missing
piece that prevents the model from even attempting blind edits.

### 2.2 File read dedup (code-level)

Beyond the prompt hint (1.5), implement actual mtime-based dedup in
the read tool. If same path + same offset/limit was already read and
`fs.statSync(path).mtimeMs` hasn't changed, return the stub message
instead of re-reading. ~20 lines.

Claude Code's implementation: check `readFileState` for matching range,
stat the file, compare mtime, return `FILE_UNCHANGED_STUB` if identical.

### 2.3 Staleness detection on edit

Beyond read-before-edit (2.1), check if the file was modified between
the last read and the edit attempt. This catches cases where a linter,
formatter, or the user modified the file after the model read it but
before the model edited it.

Claude Code's implementation: compare `getFileModificationTime()` to the
stored `readTimestamp.timestamp`. If mtime is newer, reject with a
message to re-read.

### 2.4 Partial read tracking

Claude Code distinguishes between full reads and partial reads
(`isPartialView`). A partial read (with offset/limit) doesn't satisfy
the read-before-edit requirement — you can't edit a file you've only
seen a slice of.

### 2.5 Microcompact / function result clearing

Claude Code has a `microCompact` system that clears old tool results
from context to free space, keeping only the N most recent. This is
separate from full compaction — it's a lighter-weight context
management that removes stale read/bash/grep results while preserving
the conversation flow.

Pi's compaction is all-or-nothing. A microcompact layer would extend
session length by clearing tool results that are no longer relevant
(e.g., file reads from 20 turns ago).

---

## Tier 3: Medium Code Changes (~200-500 lines)

### 3.1 Structured tool result summarization

Claude Code's system prompt includes:

> "When working with tool results, write down any important information
> you might need later in your response, as the original tool result
> may be cleared later."

Combined with microcompact (2.5), this creates a pattern where the
model extracts and preserves key information from tool results before
they're garbage-collected. The model learns to be a better note-taker.

Implementation: add a `summarize_tool_results` system prompt section +
the microcompact infrastructure to actually clear old results.

### 3.2 Partial compaction (keep recent messages intact)

Claude Code supports partial compaction: summarize only the older
portion of the conversation while keeping recent messages verbatim.
Three variants:

- `from`: summarize recent messages, keep old context
- `up_to`: summarize old messages, keep recent context
- Full: summarize everything

Pi's compaction always summarizes everything before the cut point.
Partial compaction would preserve the most relevant recent context
while freeing space from older turns.

### 3.3 Iterative compaction summaries

Claude Code's compaction checks for a previous summary and uses an
`UPDATE_SUMMARIZATION_PROMPT` that merges new information into the
existing summary rather than re-summarizing from scratch.

Pi already does this (`previousSummary` parameter in `generateSummary`).
But the update prompt could be improved to match Claude Code's
structure (the 9-section format from 1.4).

### 3.4 Task/todo tracking

Claude Code has a `TodoWriteTool` that maintains a session-level task
checklist. The model creates tasks, marks them complete, and the system
tracks progress. When all tasks are marked done, the list clears.

Pi has no built-in task tracking. The `delegate` skill handles multi-
agent coordination, but there's no per-session "what am I working on"
list that survives across turns and compactions.

This addresses a failure pattern from snainm: losing track of what's
done and what's pending across long sessions, especially after
compaction.

---

## Tier 4: Large Architectural Changes (~500+ lines)

### 4.1 Sub-agent / fork system

Claude Code's `AgentTool` supports:

- **Typed sub-agents:** predefined agent types (explore, verify, plan)
  with specific tool restrictions and system prompts
- **Forks:** clones of the current agent with full context, running in
  the background. The fork inherits the prompt cache (cheap to spawn).
- **Background execution:** agents run in the background with completion
  notifications, so the main agent can continue working.
- **Worktree isolation:** agents can run in git worktrees for safe
  parallel code changes.

Pi has the `delegate` skill (tmux-based parallel sub-agents) which
covers some of this, but it's a skill (natural language instructions)
rather than a native tool (structured API). The fork pattern
specifically — inheriting context and sharing the prompt cache — is
architecturally different.

**Snainm lesson:** The winning team ran 5-9 parallel Claude instances
coordinated through shared files. Pi's delegate skill approaches this
but lacks the native fork semantics and background notification system.

### 4.2 LSP integration for edit validation

Claude Code integrates with LSP servers:

- Notifies LSP of file changes (`didChange`, `didSave`)
- Receives diagnostics (type errors, lint warnings)
- Clears stale diagnostics after edits
- Tracks diagnostics per file

This means Claude Code can catch type errors and lint violations
immediately after an edit, without running a separate build step.

Pi relies on the model running `tsc --noEmit` or similar via bash.
Native LSP integration would surface errors faster and more reliably.

### 4.3 Conversation logging for debugging (snainm lesson)

The snainm analysis identified that the winning team saved full
`conversation.json` per run — the complete LLM message history
including reasoning between tool calls. This was their primary
debugging artifact.

Pi sessions already store full message history in JSONL. But the
gap is in **tying external outcomes (scores, test results, deploy
status) back to specific session states**. Claude Code doesn't do
this either — it was a competition-specific innovation.

A pi extension or skill that:
1. Snapshots the current session state on command
2. Tags it with an outcome (score, pass/fail, etc.)
3. Makes tagged snapshots queryable for the agent

...would close this gap. The `solve-ticket` skill partially addresses
this with its verification step, but lacks the persistent
outcome-tracking loop.

### 4.4 Context-aware system prompt (progressive disclosure)

Claude Code has a static/dynamic split in its system prompt:

- **Static prefix** (cacheable across users): identity, coding
  discipline, tool usage rules, tone/style
- **Dynamic suffix** (per-session): environment info, MCP
  instructions, language preference, output style

Separated by `SYSTEM_PROMPT_DYNAMIC_BOUNDARY`. Everything before the
boundary uses `scope: 'global'` cache. Everything after is
session-specific.

The snainm winning team took this further: ~800 tokens of system prompt
with on-demand skill loading. At any point, context contained only the
relevant skill, not the full API reference.

Pi's system prompt is monolithic. Progressive disclosure — loading
relevant instructions on demand rather than stuffing everything into
the system prompt — would reduce per-turn token waste. Skills are the
pi mechanism for this, but they're user-invoked, not auto-surfaced.

Claude Code has a `DiscoverSkillsTool` and auto-surfacing system that
presents relevant skills per turn based on the current task. Pi could
benefit from similar auto-surfacing of relevant context.

---

## Failure Patterns from Pi Sessions (evidence base)

From session analysis across projects:

| Pattern | Frequency | Root Cause | Mitigation |
|---------|-----------|------------|------------|
| Edit fails ("Could not find exact text") | Common | Model guesses file content without reading | 2.1 (read-before-edit gate) |
| Bash exits with code 1 (535 occurrences) | Very common | Commands fail silently, model doesn't diagnose | 1.2 (diagnose before retry — in AGENTS.md) |
| Python not found (36) | Moderate | Wrong python path in venvs | Environment detection |
| Command timeouts (10) | Moderate | Long-running commands without background | Bash background guidance |
| File not found on edit (4× ENOENT) | Low | Model references non-existent files | 2.1 + similar file suggestion |
| Vim launched in bash (5) | Low | Model runs interactive commands | Bash tool should block `-i` flags |
| Working directory doesn't exist (6) | Low | Session in deleted worktree | Session cleanup |

## Snainm-Specific Lessons Applied to Pi

| Lesson | Claude Code Equivalent | Pi Gap |
|--------|----------------------|--------|
| "Analysis before architecture" | System prompt: "enumerate what the solution must do" | Added to AGENTS.md ✅ |
| "Don't let agent rewrite architecture" | No equivalent (this is human discipline) | Added to AGENTS.md: "Don't add features beyond what was asked" ✅ |
| "Per-task iteration, not general fixes" | TodoWriteTool tracks per-task progress | No built-in task tracking (3.4) |
| "Save LLM reasoning, not just results" | Full session in JSONL | Session data exists but no outcome-tagging (4.3) |
| "Parallel agents, file-based coordination" | AgentTool with forks + SendMessage | Delegate skill covers basic case (4.1) |
| "Search before create" | Not in Claude Code (domain-specific) | Domain-specific; would go in project AGENTS.md |
| "Score tied to specific run" | Not in Claude Code | Extension opportunity (4.3) |
| "Instrument per-phase, not totals" | Analytics per tool, per span | Langfuse extension needed |
| "Question the frame" | No built-in equivalent | step-back skill exists ✅ |

---

## Priority Recommendation

If picking 3 things to implement next:

1. **2.1 Read-before-edit gate** — highest single-item impact, ~30 lines,
   eliminates an entire class of failures visible across all projects.
   Requires pi source change.

2. **1.3 + 1.4 Compaction improvements** — prompt-only changes to
   compaction quality. Add `<analysis>` scratchpad technique + the
   9-section structure with user message preservation. Improves long
   session quality.

3. **2.5 Microcompact** — clear old tool results while preserving
   conversation flow. Extends effective session length without full
   compaction. ~100-150 lines.

All three address the most common failure mode in long agentic sessions:
context degradation leading to the model losing track of what it knows,
what it's done, and what the user asked for.
