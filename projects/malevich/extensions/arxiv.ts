/**
 * arXiv Research Extension
 *
 * Provides tools for searching and reading papers from arXiv via its public API.
 * https://info.arxiv.org/help/api/basics.html
 *
 * Tools:
 *   arxiv_search  - Search papers by query (supports field prefixes and boolean operators)
 *   arxiv_paper   - Fetch full details of a specific paper by arXiv ID
 *
 * Usage:
 *   Place in .pi/extensions/ (project) or ~/.pi/agent/extensions/ (global)
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import {
	DEFAULT_MAX_BYTES,
	DEFAULT_MAX_LINES,
	formatSize,
	truncateHead,
} from "@mariozechner/pi-coding-agent";
import { StringEnum } from "@mariozechner/pi-ai";
import { Text } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";

// --- Types ---

interface ArxivEntry {
	id: string;
	title: string;
	summary: string;
	authors: string[];
	published: string;
	updated: string;
	categories: string[];
	primaryCategory: string;
	links: { href: string; type?: string; title?: string }[];
	comment?: string;
	journalRef?: string;
	doi?: string;
}

interface SearchDetails {
	query: string;
	totalResults: number;
	startIndex: number;
	itemsPerPage: number;
	papers: ArxivEntry[];
	truncated?: boolean;
}

interface PaperDetails {
	paper: ArxivEntry | null;
	error?: string;
}

// --- XML Parsing ---

/** Extract text content of a tag. Returns empty string if not found. */
function xmlText(xml: string, tag: string): string {
	const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, "i");
	const m = xml.match(re);
	return m ? m[1].trim() : "";
}

/** Extract an attribute value from a tag. */
function xmlAttr(xml: string, tag: string, attr: string): string {
	const re = new RegExp(`<${tag}[^>]*?${attr}="([^"]*)"`, "i");
	const m = xml.match(re);
	return m ? m[1] : "";
}

/** Extract all occurrences of a tag's outer XML. */
function xmlAll(xml: string, tag: string): string[] {
	const re = new RegExp(`<${tag}[\\s>][\\s\\S]*?(?:</${tag}>|/>)`, "gi");
	return xml.match(re) ?? [];
}

/** Parse a single <entry> block into an ArxivEntry. */
function parseEntry(entryXml: string): ArxivEntry {
	const id = xmlText(entryXml, "id").replace(/^https?:\/\/arxiv\.org\/abs\//, "");
	const title = xmlText(entryXml, "title").replace(/\s+/g, " ");
	const summary = xmlText(entryXml, "summary").replace(/\s+/g, " ");
	const published = xmlText(entryXml, "published");
	const updated = xmlText(entryXml, "updated");
	const comment = xmlText(entryXml, "arxiv:comment") || undefined;
	const journalRef = xmlText(entryXml, "arxiv:journal_ref") || undefined;
	const doi = xmlText(entryXml, "arxiv:doi") || undefined;

	const authors = xmlAll(entryXml, "author").map((a) => xmlText(a, "name"));

	const primaryCategory = xmlAttr(entryXml, "arxiv:primary_category", "term");

	const categories = xmlAll(entryXml, "category").map((c) => {
		const m = c.match(/term="([^"]*)"/);
		return m ? m[1] : "";
	}).filter(Boolean);

	const links = xmlAll(entryXml, "link").map((l) => ({
		href: l.match(/href="([^"]*)"/)?.[1] ?? "",
		type: l.match(/type="([^"]*)"/)?.[1],
		title: l.match(/title="([^"]*)"/)?.[1],
	})).filter((l) => l.href);

	return { id, title, summary, authors, published, updated, categories, primaryCategory, links, comment, journalRef, doi };
}

/** Parse the full Atom feed from the arXiv API. */
function parseFeed(xml: string): { totalResults: number; startIndex: number; itemsPerPage: number; entries: ArxivEntry[] } {
	const totalResults = parseInt(xmlText(xml, "opensearch:totalResults") || "0", 10);
	const startIndex = parseInt(xmlText(xml, "opensearch:startIndex") || "0", 10);
	const itemsPerPage = parseInt(xmlText(xml, "opensearch:itemsPerPage") || "0", 10);
	const entries = xmlAll(xml, "entry").map(parseEntry);
	return { totalResults, startIndex, itemsPerPage, entries };
}

// --- API ---

const API_BASE = "https://export.arxiv.org/api/query";

async function searchArxiv(query: string, start: number, maxResults: number, sortBy: string, sortOrder: string, signal?: AbortSignal): Promise<string> {
	const params = new URLSearchParams({
		search_query: query,
		start: String(start),
		max_results: String(maxResults),
		sortBy,
		sortOrder,
	});
	const res = await fetch(`${API_BASE}?${params}`, { signal });
	if (!res.ok) throw new Error(`arXiv API error: ${res.status} ${res.statusText}`);
	return res.text();
}

async function fetchById(idList: string, signal?: AbortSignal): Promise<string> {
	const params = new URLSearchParams({ id_list: idList });
	const res = await fetch(`${API_BASE}?${params}`, { signal });
	if (!res.ok) throw new Error(`arXiv API error: ${res.status} ${res.statusText}`);
	return res.text();
}

// --- Formatting ---

function formatPaperShort(paper: ArxivEntry, index?: number): string {
	const prefix = index !== undefined ? `[${index + 1}] ` : "";
	const date = paper.published.slice(0, 10);
	const authors = paper.authors.length <= 3
		? paper.authors.join(", ")
		: `${paper.authors.slice(0, 3).join(", ")} et al.`;
	return `${prefix}${paper.id}  ${date}  [${paper.primaryCategory}]\n    ${paper.title}\n    ${authors}`;
}

function formatPaperFull(paper: ArxivEntry): string {
	const lines: string[] = [];
	lines.push(`arXiv ID:    ${paper.id}`);
	lines.push(`Title:       ${paper.title}`);
	lines.push(`Authors:     ${paper.authors.join(", ")}`);
	lines.push(`Published:   ${paper.published.slice(0, 10)}`);
	if (paper.updated !== paper.published) {
		lines.push(`Updated:     ${paper.updated.slice(0, 10)}`);
	}
	lines.push(`Categories:  ${paper.categories.join(", ")}`);
	if (paper.doi) lines.push(`DOI:         ${paper.doi}`);
	if (paper.journalRef) lines.push(`Journal:     ${paper.journalRef}`);
	if (paper.comment) lines.push(`Comment:     ${paper.comment}`);

	const pdfLink = paper.links.find((l) => l.title === "pdf");
	const absLink = paper.links.find((l) => l.type === "text/html") ?? paper.links[0];
	if (absLink) lines.push(`Abstract URL: ${absLink.href}`);
	if (pdfLink) lines.push(`PDF URL:      ${pdfLink.href}`);

	lines.push("");
	lines.push("Abstract:");
	lines.push(paper.summary);

	return lines.join("\n");
}

// --- Extension ---

export default function (pi: ExtensionAPI) {

	// --- arxiv_search ---

	pi.registerTool({
		name: "arxiv_search",
		label: "arXiv Search",
		description: `Search arXiv for academic papers. Returns titles, authors, IDs, and categories.

Query syntax (field prefixes):
  ti:term     — title
  au:term     — author
  abs:term    — abstract
  cat:term    — category (e.g. cs.AI, math.CO, quant-ph)
  all:term    — all fields

Boolean operators: AND, OR, ANDNOT. Group with parentheses.

Examples:
  "transformer attention mechanism"           — free text across all fields
  "au:bengio AND ti:deep learning"            — author + title
  "cat:cs.CL AND abs:large language model"    — category + abstract keyword
  "au:hinton ANDNOT ti:dropout"               — exclusion

Output is truncated to ${DEFAULT_MAX_LINES} lines / ${formatSize(DEFAULT_MAX_BYTES)}. Use arxiv_paper to get full details of a specific paper.`,
		parameters: Type.Object({
			query: Type.String({ description: "Search query (supports field prefixes and boolean operators)" }),
			max_results: Type.Optional(Type.Number({ description: "Max results to return (default 10, max 50)", minimum: 1, maximum: 50 })),
			start: Type.Optional(Type.Number({ description: "Result offset for pagination (default 0)", minimum: 0 })),
			sort_by: Type.Optional(StringEnum(["relevance", "lastUpdatedDate", "submittedDate"] as const, { description: "Sort field (default: relevance)" })),
			sort_order: Type.Optional(StringEnum(["descending", "ascending"] as const, { description: "Sort order (default: descending)" })),
		}),

		async execute(_toolCallId, params, signal, onUpdate, _ctx) {
			const query = params.query;
			const maxResults = Math.min(params.max_results ?? 10, 50);
			const start = params.start ?? 0;
			const sortBy = params.sort_by ?? "relevance";
			const sortOrder = params.sort_order ?? "descending";

			onUpdate?.({ content: [{ type: "text", text: `Searching arXiv: "${query}"...` }] });

			const xml = await searchArxiv(query, start, maxResults, sortBy, sortOrder, signal);
			const feed = parseFeed(xml);

			if (feed.entries.length === 0) {
				return {
					content: [{ type: "text", text: `No results found for: ${query}` }],
					details: { query, totalResults: 0, startIndex: start, itemsPerPage: 0, papers: [] } as SearchDetails,
				};
			}

			const header = `Found ${feed.totalResults} results (showing ${feed.startIndex + 1}–${feed.startIndex + feed.entries.length}):\n`;
			const body = feed.entries.map((e, i) => formatPaperShort(e, i + start)).join("\n\n");
			let output = header + "\n" + body;

			if (feed.totalResults > start + feed.entries.length) {
				output += `\n\nMore results available. Use start=${start + feed.entries.length} to see the next page.`;
			}

			const truncation = truncateHead(output, { maxLines: DEFAULT_MAX_LINES, maxBytes: DEFAULT_MAX_BYTES });
			let resultText = truncation.content;
			let truncated = false;

			if (truncation.truncated) {
				truncated = true;
				resultText += `\n\n[Output truncated: ${truncation.outputLines} of ${truncation.totalLines} lines shown. Narrow your query or use pagination.]`;
			}

			return {
				content: [{ type: "text", text: resultText }],
				details: {
					query,
					totalResults: feed.totalResults,
					startIndex: feed.startIndex,
					itemsPerPage: feed.itemsPerPage,
					papers: feed.entries,
					truncated,
				} as SearchDetails,
			};
		},

		renderCall(args, theme) {
			let text = theme.fg("toolTitle", theme.bold("arxiv_search "));
			text += theme.fg("accent", `"${args.query}"`);
			if (args.max_results) text += theme.fg("dim", ` max=${args.max_results}`);
			if (args.start) text += theme.fg("dim", ` start=${args.start}`);
			if (args.sort_by && args.sort_by !== "relevance") text += theme.fg("dim", ` sort=${args.sort_by}`);
			return new Text(text, 0, 0);
		},

		renderResult(result, { expanded, isPartial }, theme) {
			if (isPartial) {
				return new Text(theme.fg("warning", "Searching arXiv..."), 0, 0);
			}

			const details = result.details as SearchDetails | undefined;
			if (!details || details.totalResults === 0) {
				return new Text(theme.fg("dim", "No results found"), 0, 0);
			}

			let text = theme.fg("success", `${details.papers.length} papers`);
			text += theme.fg("dim", ` (of ${details.totalResults} total)`);
			if (details.truncated) text += theme.fg("warning", " [truncated]");

			if (expanded) {
				for (const paper of details.papers) {
					const date = paper.published.slice(0, 10);
					const authors = paper.authors.length <= 2
						? paper.authors.join(", ")
						: `${paper.authors[0]} et al.`;
					text += `\n  ${theme.fg("accent", paper.id)} ${theme.fg("dim", date)} ${theme.fg("muted", `[${paper.primaryCategory}]`)}`;
					text += `\n    ${paper.title}`;
					text += `\n    ${theme.fg("dim", authors)}`;
				}
			}

			return new Text(text, 0, 0);
		},
	});

	// --- arxiv_paper ---

	pi.registerTool({
		name: "arxiv_paper",
		label: "arXiv Paper",
		description: `Fetch full details of an arXiv paper by its ID. Returns title, authors, abstract, categories, links, and metadata.

Accepts arXiv IDs in any common format:
  "2301.01234"
  "2301.01234v2"
  "arxiv:2301.01234"
  "https://arxiv.org/abs/2301.01234"

Use this after arxiv_search to read a paper's abstract and metadata.`,
		parameters: Type.Object({
			id: Type.String({ description: 'arXiv paper ID (e.g. "2301.01234", "2301.01234v2")' }),
		}),

		async execute(_toolCallId, params, signal, onUpdate, _ctx) {
			let paperId = params.id.trim();

			// Normalize various ID formats
			paperId = paperId
				.replace(/^@/, "")                                    // LLM quirk
				.replace(/^https?:\/\/arxiv\.org\/abs\//, "")         // full URL
				.replace(/^https?:\/\/arxiv\.org\/pdf\//, "")         // PDF URL
				.replace(/^arxiv:/i, "");                             // arxiv: prefix

			onUpdate?.({ content: [{ type: "text", text: `Fetching arXiv:${paperId}...` }] });

			const xml = await fetchById(paperId, signal);
			const feed = parseFeed(xml);

			if (feed.entries.length === 0) {
				return {
					content: [{ type: "text", text: `No paper found with ID: ${paperId}` }],
					details: { paper: null, error: "not_found" } as PaperDetails,
				};
			}

			const paper = feed.entries[0];

			// Check for the arXiv API error entry (returned when ID is invalid)
			if (paper.title === "Error" || paper.id === "") {
				const errorMsg = paper.summary || "Invalid arXiv ID";
				return {
					content: [{ type: "text", text: `arXiv error: ${errorMsg}` }],
					details: { paper: null, error: errorMsg } as PaperDetails,
				};
			}

			const output = formatPaperFull(paper);

			return {
				content: [{ type: "text", text: output }],
				details: { paper } as PaperDetails,
			};
		},

		renderCall(args, theme) {
			let text = theme.fg("toolTitle", theme.bold("arxiv_paper "));
			text += theme.fg("accent", args.id);
			return new Text(text, 0, 0);
		},

		renderResult(result, { expanded, isPartial }, theme) {
			if (isPartial) {
				return new Text(theme.fg("warning", "Fetching paper..."), 0, 0);
			}

			const details = result.details as PaperDetails | undefined;
			if (!details?.paper) {
				const err = details?.error ?? "Unknown error";
				return new Text(theme.fg("error", `Error: ${err}`), 0, 0);
			}

			const p = details.paper;
			const date = p.published.slice(0, 10);
			let text = theme.fg("accent", p.id) + " " + theme.fg("dim", date) + " " + theme.fg("muted", `[${p.primaryCategory}]`);
			text += "\n" + theme.bold(p.title);

			if (expanded) {
				const authors = p.authors.join(", ");
				text += `\n${theme.fg("dim", authors)}`;
				text += `\n\n${p.summary}`;
				if (p.doi) text += `\n${theme.fg("dim", `DOI: ${p.doi}`)}`;
				if (p.journalRef) text += `\n${theme.fg("dim", `Journal: ${p.journalRef}`)}`;
			}

			return new Text(text, 0, 0);
		},
	});
}
