#!/usr/bin/env python3
"""Compare a Hebrew ASR hypothesis against a reference using Claude.

Reads $ANTHROPIC_API_KEY. Sends both transcripts to claude-sonnet-4-5 and
asks for a structured quality report: WER estimate, semantic accuracy, a
verdict (pass/warn/fail), and a short diff of notable errors.

Usage:
    compare.py <reference.txt> <hypothesis.txt>
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

MODEL = os.environ.get("TRANSCRIBEER_JUDGE_MODEL", "claude-sonnet-4-5")
API_URL = "https://api.anthropic.com/v1/messages"

SYSTEM = (
    "You are an expert Hebrew linguist evaluating an automatic speech "
    "recognition (ASR) system. You receive a REFERENCE transcript and a "
    "HYPOTHESIS transcript (both Hebrew). Compare them carefully and return "
    "ONLY a JSON object — no prose, no markdown fences — with this schema:\n"
    "{\n"
    '  "wer_estimate": number 0..1,\n'
    '  "semantic_accuracy": number 0..1,  // how well the meaning is preserved\n'
    '  "verdict": "pass" | "warn" | "fail",\n'
    '  "summary": string,  // 1-2 sentences in English\n'
    '  "notable_errors": [ { "reference": string, "hypothesis": string, "note": string } ]\n'
    "}\n"
    "Guidelines: ignore punctuation and whitespace differences; treat niqqud as "
    "optional; a hypothesis that captures the meaning with a few word-level "
    "errors is still 'pass'. A hypothesis with major hallucinations or wrong "
    "topics is 'fail'. Be strict about factual distortions."
)

USER_TEMPLATE = (
    "REFERENCE:\n<<<\n{ref}\n>>>\n\nHYPOTHESIS:\n<<<\n{hyp}\n>>>\n\n"
    "Return the JSON object only."
)


def call_claude(ref: str, hyp: str) -> dict:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(3)

    payload = {
        "model": MODEL,
        "max_tokens": 2048,
        "system": SYSTEM,
        "messages": [
            {"role": "user", "content": USER_TEMPLATE.format(ref=ref, hyp=hyp)}
        ],
    }
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"Anthropic API error {exc.code}: {exc.read().decode()}", file=sys.stderr)
        sys.exit(4)

    chunks = body.get("content", [])
    text = "".join(c.get("text", "") for c in chunks if c.get("type") == "text").strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:]
        text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        print("Judge returned non-JSON:", file=sys.stderr)
        print(text, file=sys.stderr)
        sys.exit(5)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    ref = Path(argv[1]).read_text(encoding="utf-8").strip()
    hyp = Path(argv[2]).read_text(encoding="utf-8").strip()

    print("── Reference ──")
    print(ref)
    print()
    print("── Hypothesis ──")
    print(hyp)
    print()
    print(f"── Judging with {MODEL} ──", flush=True)

    report = call_claude(ref, hyp)

    wer = report.get("wer_estimate")
    sem = report.get("semantic_accuracy")
    verdict = report.get("verdict", "?")
    summary = report.get("summary", "")
    errs = report.get("notable_errors", []) or []

    print(f"verdict            : {verdict}")
    if isinstance(wer, (int, float)):
        print(f"wer_estimate       : {wer:.2f}")
    if isinstance(sem, (int, float)):
        print(f"semantic_accuracy  : {sem:.2f}")
    print(f"summary            : {summary}")
    if errs:
        print("notable_errors     :")
        for e in errs:
            print(f"  - ref: {e.get('reference', '')!r}")
            print(f"    hyp: {e.get('hypothesis', '')!r}")
            note = e.get("note")
            if note:
                print(f"    note: {note}")

    # Exit 0 on pass, 1 on warn, 2 on fail — lets CI / shell gate on it.
    return {"pass": 0, "warn": 1, "fail": 2}.get(verdict, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
