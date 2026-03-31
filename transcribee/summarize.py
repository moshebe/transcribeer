from __future__ import annotations

import os

SYSTEM_PROMPT = """You are a meeting summarizer. Given a meeting transcript with speaker labels and timestamps, produce a concise summary in the same language as the transcript. Include:
- 2-3 sentence overview
- Key decisions made
- Action items (who, what)
- Open questions

Respond in markdown."""


def run(
    transcript: str,
    backend: str,
    model: str,
    ollama_host: str = "http://localhost:11434",
) -> str:
    """
    Summarize a transcript using the configured LLM backend.

    Reads OPENAI_API_KEY / ANTHROPIC_API_KEY from env as needed.
    Raises ValueError if a required env var is missing.
    Raises ValueError for unknown backend.
    """
    if backend == "openai":
        return _run_openai(transcript, model)
    if backend == "anthropic":
        return _run_anthropic(transcript, model)
    if backend == "ollama":
        return _run_ollama(transcript, model, ollama_host)
    raise ValueError(f"Unknown summarization backend: {backend!r}. Use 'openai', 'anthropic', or 'ollama'.")


def _run_openai(transcript: str, model: str) -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise ValueError("OPENAI_API_KEY environment variable is not set.")
    from openai import OpenAI
    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": transcript},
        ],
    )
    return response.choices[0].message.content


def _run_anthropic(transcript: str, model: str) -> str:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY environment variable is not set.")
    from anthropic import Anthropic
    client = Anthropic(api_key=api_key)
    response = client.messages.create(
        model=model,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[
            {"role": "user", "content": transcript},
        ],
    )
    return response.content[0].text


def _run_ollama(transcript: str, model: str, ollama_host: str) -> str:
    import requests
    response = requests.post(
        f"{ollama_host}/api/chat",
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": transcript},
            ],
            "stream": False,
        },
    )
    response.raise_for_status()
    return response.json()["message"]["content"]
