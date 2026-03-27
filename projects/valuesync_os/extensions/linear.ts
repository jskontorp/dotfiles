/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Linear Extension — Read and write access to Linear issues from pi.
 *
 * Setup:
 *   1. Create a personal API key at https://linear.app/settings/api
 *   2. Set LINEAR_API_KEY in .env.local or export it in your shell
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent"
import { DEFAULT_MAX_LINES, formatSize, DEFAULT_MAX_BYTES } from "@mariozechner/pi-coding-agent"
import { Type } from "@sinclair/typebox"
import { StringEnum } from "@mariozechner/pi-ai"
import { Text } from "@mariozechner/pi-tui"
import {
  loadEnvKey,
  requireEnvKey,
  toolSuccess,
  validateRequired,
} from "./shared/env"

loadEnvKey("LINEAR_API_KEY")

// ── GraphQL client ────────────────────────────────────────────────────────

async function gql(query: string, variables: Record<string, any> = {}, signal?: AbortSignal | null) {
  const key = requireEnvKey("LINEAR_API_KEY", "Create one at https://linear.app/settings/api")
  for (let attempt = 0; ; attempt++) {
    const res = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      signal: signal ?? undefined,
      headers: { Authorization: key, "Content-Type": "application/json" },
      body: JSON.stringify({ query, variables }),
    })
    if (res.status === 429 && attempt < 2) {
      const sec = Number(res.headers.get("Retry-After")) || (attempt + 1)
      await new Promise(r => setTimeout(r, sec * 1000))
      continue
    }
    if (!res.ok) throw new Error(`Linear API ${res.status}: ${await res.text()}`)
    const json = await res.json()
    if (json.errors?.length) throw new Error(`Linear: ${json.errors.map((e: any) => e.message).join("; ")}`)
    return json.data
  }
}

// ── Fragments & queries ───────────────────────────────────────────────────

const ISSUE_FIELDS = `fragment F on Issue {
  id identifier title description url priorityLabel
  state { name } assignee { name } labels { nodes { name } }
  project { name } cycle { name number } createdAt updatedAt
}`

const SEARCH_FIELDS = `fragment SF on IssueSearchResult {
  id identifier title description url priorityLabel
  state { name } assignee { name } labels { nodes { name } }
  project { name } cycle { name number } createdAt updatedAt
}`

const SEARCH = `${SEARCH_FIELDS} query($q:String!){ searchIssues(term:$q,first:20){ totalCount nodes{...SF} } }`
const GET = `${ISSUE_FIELDS} query($id:String!){ issue(id:$id){...F comments(first:50){ nodes{ body user{name} createdAt } } } }`
const MY = `${ISSUE_FIELDS} query{ viewer{ assignedIssues(first:50,filter:{state:{type:{nin:["completed","cancelled"]}}},orderBy:updatedAt){ totalCount nodes{...F} } } }`
const TEAMS = `query{ teams{ nodes{ id name key issueCount } } }`

// ── Mutations ─────────────────────────────────────────────────────────────

const MUT_ISSUE = `{ id identifier title url state { name } assignee { name } priorityLabel labels { nodes { name } } }`

const CREATE_ISSUE = `mutation($input: IssueCreateInput!) {
  issueCreate(input: $input) { success issue ${MUT_ISSUE} }
}`

const UPDATE_ISSUE = `mutation($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) { success issue ${MUT_ISSUE} }
}`

const CREATE_COMMENT = `mutation($input: CommentCreateInput!) {
  commentCreate(input: $input) { success comment { id body createdAt user { name } } }
}`

// ── Resolvers (name → ID) ─────────────────────────────────────────────────

async function resolveTeam(key: string, signal?: AbortSignal | null): Promise<string> {
  const data = await gql(`query { teams { nodes { id key } } }`, {}, signal)
  const team = data.teams.nodes.find((t: any) => t.key.toLowerCase() === key.toLowerCase())
  if (!team) {
    const keys = data.teams.nodes.map((t: any) => t.key).join(", ")
    throw new Error(`Team "${key}" not found. Available: ${keys}`)
  }
  return team.id
}

async function resolveIssue(identifier: string, signal?: AbortSignal | null): Promise<{ id: string, teamId: string }> {
  const data = await gql(
    `query($id: String!) { issue(id: $id) { id team { id } } }`,
    { id: identifier }, signal,
  )
  if (!data.issue) throw new Error(`Issue "${identifier}" not found.`)
  return { id: data.issue.id, teamId: data.issue.team.id }
}

async function resolveState(teamId: string, name: string, signal?: AbortSignal | null): Promise<string> {
  const data = await gql(
    `query($teamId: String!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name } } }`,
    { teamId }, signal,
  )
  const lower = name.toLowerCase()
  const state = data.workflowStates.nodes.find((s: any) => s.name.toLowerCase() === lower)
  if (!state) {
    const names = data.workflowStates.nodes.map((s: any) => s.name).join(", ")
    throw new Error(`State "${name}" not found. Available: ${names}`)
  }
  return state.id
}

async function resolveAssignee(name: string, signal?: AbortSignal | null): Promise<string> {
  const data = await gql(`query { users { nodes { id name displayName email } } }`, {}, signal)
  const lower = name.toLowerCase()
  const user = data.users.nodes.find((u: any) =>
    u.name?.toLowerCase() === lower ||
    u.displayName?.toLowerCase() === lower ||
    u.email?.toLowerCase() === lower
  )
  if (!user) {
    const names = data.users.nodes.map((u: any) => u.name || u.displayName).filter(Boolean).join(", ")
    throw new Error(`User "${name}" not found. Available: ${names}`)
  }
  return user.id
}

async function resolveLabels(teamId: string, names: string[], signal?: AbortSignal | null): Promise<string[]> {
  const data = await gql(
    `query($teamId: String!) { team(id: $teamId) { labels { nodes { id name } } } }`,
    { teamId }, signal,
  )
  const available = data.team.labels.nodes
  const ids: string[] = []
  for (const name of names) {
    const lower = name.trim().toLowerCase()
    const label = available.find((l: any) => l.name.toLowerCase() === lower)
    if (!label) {
      const all = available.map((l: any) => l.name).join(", ")
      throw new Error(`Label "${name}" not found. Available: ${all}`)
    }
    ids.push(label.id)
  }
  return ids
}

function parseLabels(csv: string): string[] {
  return csv.split(",").map((s: string) => s.trim()).filter(Boolean)
}

// ── Formatting ────────────────────────────────────────────────────────────

function fmt(issue: any, verbose = false): string {
  const parts = [`**${issue.identifier}** ${issue.title}`]
  const meta = [
    `State: ${issue.state?.name ?? "Unknown"}`,
    `Assignee: ${issue.assignee?.name ?? "Unassigned"}`,
    issue.priorityLabel && `Priority: ${issue.priorityLabel}`,
    issue.labels?.nodes?.length && `Labels: ${issue.labels.nodes.map((l: any) => l.name).join(", ")}`,
  ].filter(Boolean)
  parts.push(`  ${meta.join(" · ")}`)
  if (issue.url) parts.push(`  ${issue.url}`)
  if (verbose && issue.description) parts.push("", issue.description)
  return parts.join("\n")
}

function fmtList(issues: any[], total?: number): string {
  if (!issues.length) return "No issues found."
  let out = issues.map((i) => fmt(i)).join("\n\n")
  if (total != null && total > issues.length) {
    out += `\n\n(showing ${issues.length} of ${total} results)`
  }
  return out
}

function fmtMutation(issue: any): string {
  const meta = [
    `State: ${issue.state?.name ?? "Unknown"}`,
    `Assignee: ${issue.assignee?.name ?? "Unassigned"}`,
    issue.priorityLabel && `Priority: ${issue.priorityLabel}`,
    issue.labels?.nodes?.length && `Labels: ${issue.labels.nodes.map((l: any) => l.name).join(", ")}`,
  ].filter(Boolean)
  return [`**${issue.identifier}** ${issue.title}`, `  ${meta.join(" · ")}`, `  ${issue.url}`].join("\n")
}

// ── Action handlers ───────────────────────────────────────────────────────

type Sig = AbortSignal | null | undefined

const actions: Record<string, (p: any, signal: Sig) => Promise<string>> = {
  // ── Read ──────────────────────────────────────────────────────────────

  async search(p, signal) {
    const data = await gql(SEARCH, { q: p.query }, signal)
    const { nodes, totalCount } = data.searchIssues
    return fmtList(nodes, totalCount)
  },

  async get_issue(p, signal) {
    const data = await gql(GET, { id: p.issue_id }, signal)
    const issue = data.issue
    if (!issue) throw new Error(`Issue ${p.issue_id} not found.`)

    let out = fmt(issue, true)
    const comments = issue.comments?.nodes ?? []
    if (comments.length) {
      out += "\n\n### Comments\n"
      for (const c of comments)
        out += `\n**${c.user?.name ?? "Unknown"}** (${c.createdAt?.slice(0, 10) ?? ""}):\n${c.body}\n`
    }
    return out
  },

  async my_issues(_p, signal) {
    const data = await gql(MY, {}, signal)
    const { nodes: issues, totalCount } = data.viewer.assignedIssues
    if (!issues.length) return "No active issues assigned to you."
    let out = `**Your active issues (${totalCount}):**\n\n`
    out += fmtList(issues, totalCount)
    return out
  },

  async list_teams(_p, signal) {
    const data = await gql(TEAMS, {}, signal)
    const teams = data.teams.nodes
    return teams.length
      ? teams.map((t: any) => `- **${t.name}** (key: ${t.key}, ${t.issueCount} issues)`).join("\n")
      : "No teams found."
  },

  // ── Write ─────────────────────────────────────────────────────────────

  async create_issue(p, signal) {
    const teamId = await resolveTeam(p.team_key, signal)
    const input: any = { teamId, title: p.title }
    if (p.description) input.description = p.description
    if (p.priority != null) input.priority = Number(p.priority)

    // Resolve human-readable names → IDs in parallel
    const [stateId, assigneeId, labelIds] = await Promise.all([
      p.state ? resolveState(teamId, p.state, signal) : undefined,
      p.assignee ? resolveAssignee(p.assignee, signal) : undefined,
      p.labels ? resolveLabels(teamId, parseLabels(p.labels), signal) : undefined,
    ])
    if (stateId) input.stateId = stateId
    if (assigneeId) input.assigneeId = assigneeId
    if (labelIds?.length) input.labelIds = labelIds

    const data = await gql(CREATE_ISSUE, { input }, signal)
    if (!data.issueCreate.success) throw new Error("Failed to create issue.")
    return `Created:\n${fmtMutation(data.issueCreate.issue)}`
  },

  async update_issue(p, signal) {
    const { id, teamId } = await resolveIssue(p.issue_id, signal)
    const input: any = {}
    if (p.title) input.title = p.title
    if (p.description) input.description = p.description
    if (p.priority != null) input.priority = Number(p.priority)

    // Resolve human-readable names → IDs in parallel
    const [stateId, assigneeId, labelIds] = await Promise.all([
      p.state ? resolveState(teamId, p.state, signal) : undefined,
      p.assignee ? resolveAssignee(p.assignee, signal) : undefined,
      p.labels ? resolveLabels(teamId, parseLabels(p.labels), signal) : undefined,
    ])
    if (stateId) input.stateId = stateId
    if (assigneeId) input.assigneeId = assigneeId
    if (labelIds?.length) input.labelIds = labelIds

    if (!Object.keys(input).length)
      throw new Error("No fields to update. Provide title, description, state, assignee, priority, or labels.")

    const data = await gql(UPDATE_ISSUE, { id, input }, signal)
    if (!data.issueUpdate.success) throw new Error("Failed to update issue.")
    return `Updated:\n${fmtMutation(data.issueUpdate.issue)}`
  },

  async add_comment(p, signal) {
    const { id: issueId } = await resolveIssue(p.issue_id, signal)
    const data = await gql(CREATE_COMMENT, { input: { issueId, body: p.body } }, signal)
    if (!data.commentCreate.success) throw new Error("Failed to add comment.")
    const c = data.commentCreate.comment
    return `Comment added by ${c.user?.name ?? "you"} (${c.createdAt?.slice(0, 10) ?? "now"}):\n${c.body}`
  },
}

// ── Required params per action ────────────────────────────────────────────

const required: Record<string, string[]> = {
  search: ["query"],
  get_issue: ["issue_id"],
  create_issue: ["team_key", "title"],
  update_issue: ["issue_id"],
  add_comment: ["issue_id", "body"],
}

// ── Tool schema ───────────────────────────────────────────────────────────

const ALL_ACTIONS = [
  "search", "get_issue", "my_issues", "list_teams",
  "create_issue", "update_issue", "add_comment",
] as const

const Params = Type.Object({
  action: StringEnum(ALL_ACTIONS, {
    description:
      '"search" — full-text search across issues; ' +
      '"get_issue" — fetch a single issue with comments by identifier (e.g. TECH-123); ' +
      '"my_issues" — list your active assigned issues; ' +
      '"list_teams" — list available teams and their keys; ' +
      '"create_issue" — create a new issue in a team; ' +
      '"update_issue" — update an existing issue\'s fields; ' +
      '"add_comment" — add a comment to an issue.',
  }),
  query: Type.Optional(Type.String({ description: 'Search query text (required for "search").' })),
  issue_id: Type.Optional(Type.String({ description: 'Issue identifier like "TECH-123" (required for "get_issue", "update_issue", "add_comment").' })),
  team_key: Type.Optional(Type.String({ description: 'Team key like "TECH" (required for "create_issue"). Use "list_teams" to discover keys.' })),
  title: Type.Optional(Type.String({ description: 'Issue title (required for "create_issue", optional for "update_issue").' })),
  description: Type.Optional(Type.String({ description: "Issue description in markdown." })),
  state: Type.Optional(Type.String({ description: 'Workflow state name, e.g. "In Progress", "Done". Resolved by name.' })),
  assignee: Type.Optional(Type.String({ description: "Assignee display name or email. Resolved by name." })),
  priority: Type.Optional(Type.Number({ description: "Priority: 0 = none, 1 = urgent, 2 = high, 3 = medium, 4 = low." })),
  labels: Type.Optional(Type.String({ description: 'Comma-separated label names, e.g. "Bug, Frontend". Resolved by name.' })),
  body: Type.Optional(Type.String({ description: 'Comment body in markdown (required for "add_comment").' })),
})

// ── Extension ─────────────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "linear",
    label: "Linear",
    description:
      "Read and write Linear project management. " +
      "Actions: search, get_issue, my_issues, list_teams, create_issue, update_issue, add_comment. " +
      `Output truncated to ${DEFAULT_MAX_LINES} lines or ${formatSize(DEFAULT_MAX_BYTES)}.`,
    promptGuidelines: [
      "Use list_teams to discover team keys before create_issue.",
      "Use search to check for existing issues before creating duplicates.",
      "State, assignee, and label names are resolved by exact name (case-insensitive). If resolution fails, the error lists available options.",
      "When on a git branch matching [A-Z]+-\\d+ (e.g. feat/TECH-123-fix-bug), the identifier likely refers to a Linear issue.",
    ],
    parameters: Params,

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
      let text = theme.fg("toolTitle", theme.bold("linear "))
      text += theme.fg("accent", args.action)
      if (args.query) text += " " + theme.fg("dim", `"${args.query}"`)
      if (args.issue_id) text += " " + theme.fg("muted", args.issue_id)
      if (args.team_key) text += " " + theme.fg("muted", args.team_key)
      if (args.title) text += " " + theme.fg("dim", `"${args.title}"`)
      if (args.body) text += " " + theme.fg("dim", `${args.body.length} chars`)
      return new Text(text, 0, 0)
    },

    renderResult(result, { expanded, isPartial }, theme) {
      if (isPartial) return new Text(theme.fg("warning", "Fetching from Linear…"), 0, 0)

      if (result.isError) {
        const msg = result.content[0]?.type === "text" ? result.content[0].text : "Error"
        return new Text(theme.fg("error", msg), 0, 0)
      }

      const details = result.details as { action: string; truncated?: boolean } | undefined
      let text = theme.fg("success", `✓ ${details?.action ?? "done"}`)
      if (details?.truncated) text += theme.fg("warning", " (truncated)")

      if (expanded) {
        const content = result.content[0]
        if (content?.type === "text") {
          const lines = content.text.split("\n").slice(0, 50)
          for (const line of lines) text += `\n${theme.fg("dim", line)}`
          if (content.text.split("\n").length > 50) text += `\n${theme.fg("muted", "… (expand to see more)")}`
        }
      }

      return new Text(text, 0, 0)
    },
  })
}
