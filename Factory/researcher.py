#!/usr/bin/env python3
"""Build a dense live Apple API context pack for the Dark Factory."""

from __future__ import annotations

import json
import os
import sys
import traceback
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

try:
    from duckduckgo_search import DDGS
except Exception:  # pragma: no cover - graceful fallback when dependency is absent
    DDGS = None  # type: ignore[assignment]


MODEL = "gpt-4o-mini"
OPENAI_URL = "https://api.openai.com/v1/chat/completions"
CONTEXT_PATH = Path.home() / ".darkfactory" / "context_pack.txt"
RESULTS_PATH = Path.home() / ".darkfactory" / "context_pack_results.json"
QUERY_TIMEOUT_SECONDS = 30
SUMMARY_TIMEOUT_SECONDS = 45
MAX_RESULTS_PER_QUERY = 3


def main() -> int:
    goal = " ".join(sys.argv[1:]).strip()
    ensure_context_parent()

    if not goal:
        write_context("")
        write_results([])
        print("[Researcher] Context pack built.")
        return 0

    try:
        log("[web-search] Fetching Latest Apple Docs")
        queries = extract_queries(goal)
        if not queries:
            write_context("")
            write_results([])
            print("[Researcher] Context pack built.")
            return 0

        search_results = collect_search_results(queries)
        if not search_results:
            write_context("")
            write_results([])
            print("[Researcher] Context pack built.")
            return 0

        write_results(search_results)
        reference_sheet = synthesize_reference_sheet(goal, queries, search_results)
        write_context(reference_sheet)
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
        return []

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
        "max_tokens": 220,
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
    return cleaned[:3]


def collect_search_results(queries: list[str]) -> list[dict[str, Any]]:
    if DDGS is None:
        return []

    ddgs = DDGS()
    collected: list[dict[str, Any]] = []

    for query in queries:
        log(f"[web-search] Searching: {query}")
        try:
            raw_results = ddgs.text(query, max_results=MAX_RESULTS_PER_QUERY)
            results = list(raw_results or [])[:MAX_RESULTS_PER_QUERY]
        except Exception as error:
            log(f"[web-search] Search warning: {query} ({error})")
            continue

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


def synthesize_reference_sheet(
    goal: str,
    queries: list[str],
    search_results: list[dict[str, Any]],
) -> str:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        return ""

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
        "max_tokens": 1400,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }

    return post_openai_json(payload, api_key, timeout=SUMMARY_TIMEOUT_SECONDS).strip()


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
