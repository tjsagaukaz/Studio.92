#!/usr/bin/env python3
"""Build a dense live Apple API context pack for the Dark Factory."""

from __future__ import annotations

import json
import html
import os
import re
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

try:
    from duckduckgo_search import DDGS
except Exception:  # pragma: no cover - graceful fallback when dependency is absent
    DDGS = None  # type: ignore[assignment]


MODEL = "gpt-5.4-mini"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
_OUTPUT_DIR = Path(os.environ.get("RESEARCHER_OUTPUT_DIR", "") or Path.home() / ".darkfactory")
CONTEXT_PATH = _OUTPUT_DIR / "context_pack.txt"
RESULTS_PATH = _OUTPUT_DIR / "context_pack_results.json"
QUERY_TIMEOUT_SECONDS = 30
SUMMARY_TIMEOUT_SECONDS = 45
MAX_RESULTS_PER_QUERY = 3
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/135.0.0.0 Safari/537.36"
)


def main() -> int:
    goal = " ".join(sys.argv[1:]).strip()
    ensure_context_parent()
    write_context("")
    write_results([])

    if not goal:
        print("[Researcher] Context pack built.")
        return 0

    try:
        log("[web-search] Fetching Latest Apple Docs")
        queries = extract_queries(goal)
        if not queries:
            log("[web-search] No search queries could be generated.")
            print("[Researcher] No usable web search queries were generated.")
            return 0

        search_results = collect_search_results(queries)
        if not search_results:
            log("[web-search] No usable web results were found.")
            print("[Researcher] No usable web search results were found.")
            return 0

        write_results(search_results)
        reference_sheet = synthesize_reference_sheet(goal, queries, search_results)
        write_context(reference_sheet)
        log(f"[web-search] Collected {len(search_results)} results.")
    except Exception as error:  # pragma: no cover - safety net for pipeline continuity
        log(f"[web-search] Fallback to empty context pack: {error}")
        log(traceback.format_exc().strip())
        write_context("")
        write_results([])

    print("[Researcher] Context pack built.")
    return 0


def ensure_context_parent() -> None:
    CONTEXT_PATH.parent.mkdir(parents=True, exist_ok=True)


def write_context(contents: str) -> None:
    CONTEXT_PATH.write_text(contents, encoding="utf-8")


def write_results(results: list[dict[str, Any]]) -> None:
    RESULTS_PATH.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def extract_queries(goal: str) -> list[str]:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        log("[web-search] OPENAI_API_KEY unavailable. Falling back to heuristic query generation.")
        return fallback_queries(goal)

    system_prompt = (
        "You generate live Apple-platform research queries for an autonomous SwiftUI iOS coder. "
        "Return only JSON with a `queries` array containing 2 or 3 highly specific technical "
        "search queries. Focus on current SwiftUI, SwiftData, iOS, macOS, Xcode, and Apple "
        "documentation/tutorial phrasing. Prefer queries that are likely to surface official "
        "Apple docs and recent implementation guidance."
    )
    user_prompt = f"Goal:\n{goal}\n\nReturn 2 or 3 search queries."

    payload = {
        "model": MODEL,
        "temperature": 0.1,
        "max_completion_tokens": 220,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

    response_text = post_openai_json(payload, api_key, timeout=QUERY_TIMEOUT_SECONDS)
    try:
        parsed = json.loads(response_text)
    except json.JSONDecodeError:
        return []

    queries = parsed.get("queries") or []
    cleaned = [str(query).strip() for query in queries if str(query).strip()]
    if cleaned:
        return cleaned[:3]

    log("[web-search] Query model returned no usable queries. Falling back to heuristic query generation.")
    return fallback_queries(goal)


def fallback_queries(goal: str) -> list[str]:
    normalized_goal = " ".join(goal.split())
    if not normalized_goal:
        return []

    queries: list[str] = [normalized_goal]
    lower_goal = normalized_goal.lower()
    developer_keywords = (
        "swift",
        "swiftui",
        "swiftdata",
        "ipados",
        "macos",
        "watchos",
        "visionos",
        "xcode",
        "sdk",
        "api",
        "framework",
        "uikit",
        "appkit",
        "storekit",
        "modelcontext",
        "testflight",
        "privacy manifest",
        "entitlement",
        "review guideline",
        "developer.apple.com",
    )
    needs_apple_docs = any(keyword in lower_goal for keyword in developer_keywords)

    if needs_apple_docs:
        queries.append(f"site:developer.apple.com {normalized_goal}")

    if "developer.apple.com" not in lower_goal and needs_apple_docs:
        queries.append(f"site:developer.apple.com {normalized_goal} latest")
    elif not re.search(r"\b20\d{2}\b", normalized_goal):
        queries.append(f"{normalized_goal} latest")

    deduplicated: list[str] = []
    seen: set[str] = set()
    for query in queries:
        cleaned = " ".join(query.split()).strip()
        lowered = cleaned.lower()
        if not cleaned or lowered in seen:
            continue
        seen.add(lowered)
        deduplicated.append(cleaned)

    return deduplicated[:3]


def collect_search_results(queries: list[str]) -> list[dict[str, Any]]:
    collected: list[dict[str, Any]] = []

    for query in queries:
        log(f"[web-search] Searching: {query}")
        query_results = search_query(query)
        if not query_results:
            log(f"[web-search] Search warning: {query} (no backend returned usable results)")
            continue
        collected.extend(query_results)
        deduplicated = deduplicate_results(collected)
        if len(deduplicated) >= max(MAX_RESULTS_PER_QUERY, 5):
            return deduplicated

    return deduplicate_results(collected)


def search_query(query: str) -> list[dict[str, Any]]:
    backends = [collect_ddgs_results, collect_brave_results, collect_yahoo_results, collect_bing_rss_results]

    for backend in backends:
        try:
            results = backend(query)
        except Exception as error:
            log(f"[web-search] Backend {backend.__name__} failed for {query}: {error}")
            continue
        if results:
            log(f"[web-search] Backend {backend.__name__} returned {len(results)} results.")
            return results

    return []


def collect_ddgs_results(query: str) -> list[dict[str, Any]]:
    if DDGS is None:
        raise RuntimeError("duckduckgo_search is not installed")

    ddgs = DDGS()
    raw_results = ddgs.text(query, max_results=MAX_RESULTS_PER_QUERY)
    results = list(raw_results or [])[:MAX_RESULTS_PER_QUERY]
    collected: list[dict[str, Any]] = []
    for result in results:
        title = str(result.get("title") or "").strip()
        href = str(result.get("href") or result.get("url") or "").strip()
        body = str(result.get("body") or result.get("snippet") or "").strip()
        if not any([title, href, body]):
            continue
        collected.append(
            {
                "query": query,
                "title": title,
                "url": href,
                "snippet": body,
            }
        )
    return collected


def collect_brave_results(query: str) -> list[dict[str, Any]]:
    encoded_query = urllib.parse.quote(query)
    url = f"https://search.brave.com/search?q={encoded_query}&source=web"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=QUERY_TIMEOUT_SECONDS) as response:
        body = response.read().decode("utf-8", errors="replace")

    pattern = re.compile(
        r'<a href="(?P<url>https?://[^"]+)"[^>]*class="[^"]* l1">'
        r'.*?<div class="title [^"]*"[^>]*title="(?P<title_attr>[^"]+)">(?P<title>.*?)</div>'
        r'.*?<div class="content [^"]*">(?P<snippet>.*?)</div>',
        re.S,
    )
    collected: list[dict[str, Any]] = []

    for match in pattern.finditer(body):
        href = html.unescape(match.group("url")).strip()
        title = clean_html_fragment(match.group("title_attr") or match.group("title"))
        snippet = clean_html_fragment(match.group("snippet"))
        if not any([title, href, snippet]):
            continue
        collected.append(
            {
                "query": query,
                "title": title,
                "url": href,
                "snippet": snippet,
            }
        )
        if len(collected) >= MAX_RESULTS_PER_QUERY:
            break

    return collected


def collect_yahoo_results(query: str) -> list[dict[str, Any]]:
    encoded_query = urllib.parse.quote(query)
    url = f"https://au.search.yahoo.com/search?p={encoded_query}&nojs=1"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=QUERY_TIMEOUT_SECONDS) as response:
        body = response.read().decode("utf-8", errors="replace")

    anchor_pattern = re.compile(
        r'href="(?P<href>https://r\.search\.yahoo\.com/[^"]+)"[^>]+aria-label="(?P<title>[^"]+)"',
        re.S,
    )
    collected: list[dict[str, Any]] = []

    for match in anchor_pattern.finditer(body):
        href = html.unescape(match.group("href")).strip()
        target_url = decode_yahoo_target(href)
        title = clean_html_fragment(match.group("title")).replace("\u200e", "").strip()
        snippet_window = body[match.end():match.end() + 1600]
        snippet_match = re.search(r'<span class="fc-falcon">(.*?)</span>', snippet_window, re.S)
        snippet = clean_html_fragment(snippet_match.group(1)) if snippet_match else ""
        if not any([title, target_url, snippet]):
            continue
        collected.append(
            {
                "query": query,
                "title": title,
                "url": target_url,
                "snippet": snippet,
            }
        )
        if len(collected) >= MAX_RESULTS_PER_QUERY:
            break

    return collected


def collect_bing_rss_results(query: str) -> list[dict[str, Any]]:
    encoded_query = urllib.parse.quote(query)
    url = f"https://www.bing.com/search?format=rss&q={encoded_query}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=QUERY_TIMEOUT_SECONDS) as response:
        body = response.read()

    root = ET.fromstring(body)
    collected: list[dict[str, Any]] = []
    for item in root.findall("./channel/item"):
        title = clean_html_fragment(item.findtext("title", default=""))
        href = (item.findtext("link", default="") or "").strip()
        snippet = clean_html_fragment(item.findtext("description", default=""))
        if not any([title, href, snippet]):
            continue
        collected.append(
            {
                "query": query,
                "title": title,
                "url": href,
                "snippet": snippet,
            }
        )
        if len(collected) >= MAX_RESULTS_PER_QUERY:
            break

    return collected


def decode_yahoo_target(url: str) -> str:
    match = re.search(r"/RU=([^/]+)/RK=", url)
    if not match:
        return url
    return urllib.parse.unquote(match.group(1)).strip()


def deduplicate_results(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduplicated: list[dict[str, Any]] = []
    seen: set[str] = set()

    for result in results:
        url = str(result.get("url") or "").strip()
        title = str(result.get("title") or "").strip()
        snippet = str(result.get("snippet") or "").strip()
        key = url or f"{title}|{snippet}"
        if not key or key in seen:
            continue
        seen.add(key)
        deduplicated.append(
            {
                "query": str(result.get("query") or "").strip(),
                "title": title,
                "url": url,
                "snippet": snippet,
            }
        )

    return deduplicated


def clean_html_fragment(value: str) -> str:
    text = re.sub(r"<[^>]+>", " ", html.unescape(value))
    return " ".join(text.split())


def synthesize_reference_sheet(
    goal: str,
    queries: list[str],
    search_results: list[dict[str, Any]],
) -> str:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        log("[web-search] OPENAI_API_KEY unavailable. Building deterministic reference sheet from search snippets.")
        return synthesize_fallback_reference_sheet(goal, queries, search_results)

    system_prompt = (
        "You are a precision Apple API researcher. Extract only actionable, current Swift, "
        "SwiftUI, SwiftData, and Apple-platform syntax/rules from the supplied live web results. "
        "Write a dense technical reference sheet for an AI coder. Be strict, concise, and factual. "
        "If sources conflict, prefer official Apple documentation and clearly note any uncertainty. "
        "Do not add speculative APIs."
    )
    user_prompt = (
        "Goal:\n"
        f"{goal}\n\n"
        "Queries used:\n"
        f"{json.dumps(queries, indent=2)}\n\n"
        "Web results:\n"
        f"{json.dumps(search_results, indent=2)}\n\n"
        "Extract the precise Swift/SwiftUI syntax and rules from these web results. "
        "Format as a strict, dense technical reference sheet for an AI Coder."
    )

    payload = {
        "model": MODEL,
        "temperature": 0.0,
        "max_completion_tokens": 1400,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

    try:
        summary = post_openai_json(payload, api_key, timeout=SUMMARY_TIMEOUT_SECONDS).strip()
    except Exception as error:
        log(f"[web-search] Summary synthesis failed: {error}")
        return synthesize_fallback_reference_sheet(goal, queries, search_results)

    if summary:
        return summary

    log("[web-search] Summary synthesis returned an empty response. Using fallback reference sheet.")
    return synthesize_fallback_reference_sheet(goal, queries, search_results)


def synthesize_fallback_reference_sheet(
    goal: str,
    queries: list[str],
    search_results: list[dict[str, Any]],
) -> str:
    lines = [
        f"Goal: {goal}",
        "",
        "Queries used:",
    ]
    lines.extend(f"- {query}" for query in queries)
    lines.extend(["", "Grounded web results:"])

    for index, result in enumerate(search_results[:10], start=1):
        title = str(result.get("title") or "Untitled result").strip()
        url = str(result.get("url") or "").strip()
        snippet = str(result.get("snippet") or "").strip()
        lines.append(f"{index}. {title}")
        if url:
            lines.append(f"URL: {url}")
        if snippet:
            lines.append(f"Snippet: {snippet}")
        lines.append("")

    return "\n".join(lines).strip()


def post_openai_json(payload: dict[str, Any], api_key: str, timeout: int) -> str:
    request = urllib.request.Request(
        OPENAI_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(error.read().decode("utf-8", errors="replace")) from error
    except urllib.error.URLError as error:
        raise RuntimeError(str(error)) from error

    payload = json.loads(body.decode("utf-8"))
    choices = payload.get("choices") or []
    if not choices:
        raise RuntimeError("OpenAI response contained no choices.")

    message = choices[0].get("message") or {}
    content = message.get("content", "")

    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text") or ""))
        return "\n".join(parts).strip()

    return str(content).strip()


if __name__ == "__main__":
    raise SystemExit(main())
