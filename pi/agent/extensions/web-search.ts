/**
 * Web Search Extension
 *
 * Provides two tools:
 * - web_search: Search the internet (Brave Search API if BRAVE_SEARCH_API_KEY is set, DuckDuckGo fallback)
 * - web_fetch: Fetch and extract text from a web page
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

interface SearchResult {
	title: string;
	url: string;
	snippet: string;
}

function decodeHtmlEntities(text: string): string {
	return text
		.replace(/&amp;/g, "&")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#x27;/g, "'")
		.replace(/&#39;/g, "'")
		.replace(/&nbsp;/g, " ")
		.replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n)))
		.replace(/&#x([0-9a-fA-F]+);/g, (_, n) => String.fromCharCode(parseInt(n, 16)));
}

function stripHtml(html: string): string {
	return decodeHtmlEntities(
		html
			.replace(/<[^>]*>/g, " ")
			.replace(/\s+/g, " "),
	).trim();
}

function htmlToText(html: string): string {
	let text = html
		.replace(/<script[\s\S]*?<\/script>/gi, "")
		.replace(/<style[\s\S]*?<\/style>/gi, "")
		.replace(/<nav[\s\S]*?<\/nav>/gi, "")
		.replace(/<header[\s\S]*?<\/header>/gi, "")
		.replace(/<footer[\s\S]*?<\/footer>/gi, "");

	text = text
		.replace(/<br\s*\/?>/gi, "\n")
		.replace(/<\/?(p|div|h[1-6]|li|tr|blockquote|pre|section|article)[^>]*>/gi, "\n")
		.replace(/<[^>]*>/g, " ")
		.replace(/[ \t]+/g, " ")
		.replace(/\n\s+/g, "\n")
		.replace(/\n{3,}/g, "\n\n");

	return decodeHtmlEntities(text).trim();
}

function formatResults(query: string, results: SearchResult[]) {
	if (results.length === 0) {
		return {
			content: [{ type: "text" as const, text: `No results found for: ${query}` }],
			details: { query, resultCount: 0, results: [] },
		};
	}

	const text = results
		.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.snippet}`)
		.join("\n\n");

	return {
		content: [{ type: "text" as const, text: `Search results for "${query}":\n\n${text}` }],
		details: { query, resultCount: results.length, results },
	};
}

async function braveSearch(query: string, count: number, apiKey: string, signal?: AbortSignal) {
	const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${count}`;
	const res = await fetch(url, {
		headers: {
			Accept: "application/json",
			"Accept-Encoding": "gzip",
			"X-Subscription-Token": apiKey,
		},
		signal,
	});

	if (!res.ok) {
		return {
			content: [{ type: "text" as const, text: `Brave Search error: ${res.status} ${res.statusText}` }],
			isError: true,
		};
	}

	const data = (await res.json()) as { web?: { results?: Array<{ title: string; url: string; description: string }> } };
	const results: SearchResult[] = (data.web?.results ?? []).map((r) => ({
		title: r.title,
		url: r.url,
		snippet: r.description,
	}));

	return formatResults(query, results);
}

async function duckduckgoSearch(query: string, maxResults: number, signal?: AbortSignal) {
	const res = await fetch("https://html.duckduckgo.com/html/", {
		method: "POST",
		headers: {
			"Content-Type": "application/x-www-form-urlencoded",
			"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
		},
		body: `q=${encodeURIComponent(query)}`,
		signal,
	});

	if (!res.ok) {
		return {
			content: [{ type: "text" as const, text: `DuckDuckGo search error: ${res.status} ${res.statusText}` }],
			isError: true,
		};
	}

	const html = await res.text();
	const results = parseDDGResults(html, maxResults);
	return formatResults(query, results);
}

function parseDDGResults(html: string, maxResults: number): SearchResult[] {
	const results: SearchResult[] = [];

	// Extract result links: <a class="result__a" href="...">Title</a>
	const titlePattern = /<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
	const snippetPattern = /<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g;

	const titles: { url: string; title: string }[] = [];
	let match;

	while ((match = titlePattern.exec(html)) !== null) {
		let url = match[1];
		const uddgMatch = url.match(/uddg=([^&]+)/);
		if (uddgMatch) {
			url = decodeURIComponent(uddgMatch[1]);
		}
		titles.push({ url, title: stripHtml(match[2]) });
	}

	const snippets: string[] = [];
	while ((match = snippetPattern.exec(html)) !== null) {
		snippets.push(stripHtml(match[1]));
	}

	for (let i = 0; i < Math.min(titles.length, maxResults); i++) {
		results.push({
			title: titles[i].title,
			url: titles[i].url,
			snippet: snippets[i] ?? "",
		});
	}

	return results;
}

async function fetchPage(url: string, maxLength: number, signal?: AbortSignal) {
	const res = await fetch(url, {
		headers: {
			"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
			Accept: "text/html,application/xhtml+xml,text/plain,application/json",
		},
		signal,
		redirect: "follow",
	});

	if (!res.ok) {
		return {
			content: [{ type: "text" as const, text: `Failed to fetch ${url}: ${res.status} ${res.statusText}` }],
			isError: true,
		};
	}

	const contentType = res.headers.get("content-type") ?? "";
	const body = await res.text();

	let text: string;
	if (contentType.includes("text/html") || contentType.includes("application/xhtml")) {
		text = htmlToText(body);
	} else {
		text = body;
	}

	if (text.length > maxLength) {
		text = text.substring(0, maxLength) + "\n\n[Truncated — use maxLength to get more]";
	}

	return {
		content: [{ type: "text" as const, text }],
		details: { url, contentType, length: text.length },
	};
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "web_search",
		label: "Web Search",
		description:
			"Search the internet for current information. Returns titles, URLs, and snippets. Uses Brave Search if BRAVE_SEARCH_API_KEY is set, otherwise DuckDuckGo.",
		promptSnippet: "Search the internet for current information",
		promptGuidelines: [
			"Use web_search when you need current information beyond your training data, such as recent events, latest research, or up-to-date documentation.",
			"Follow up with web_fetch to read full page content from promising search results.",
		],
		parameters: Type.Object({
			query: Type.String({ description: "Search query" }),
			maxResults: Type.Optional(Type.Number({ description: "Max results to return (default: 5)" })),
		}),
		async execute(_toolCallId, params, signal) {
			const maxResults = params.maxResults ?? 5;
			const braveKey = process.env.BRAVE_SEARCH_API_KEY;
			if (braveKey) {
				return braveSearch(params.query, maxResults, braveKey, signal);
			}
			return duckduckgoSearch(params.query, maxResults, signal);
		},
	});

	pi.registerTool({
		name: "web_fetch",
		label: "Web Fetch",
		description: "Fetch a web page and extract its text content. Use to read articles, documentation, or follow up on search results.",
		promptSnippet: "Fetch and read a web page's text content",
		parameters: Type.Object({
			url: Type.String({ description: "URL to fetch" }),
			maxLength: Type.Optional(Type.Number({ description: "Max text length in characters (default: 10000)" })),
		}),
		async execute(_toolCallId, params, signal) {
			return fetchPage(params.url, params.maxLength ?? 10000, signal);
		},
	});
}
