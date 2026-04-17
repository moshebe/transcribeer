#!/usr/bin/env python3
"""Generate the Transcribeer app logo via OpenRouter.

Usage:
    OPENROUTER_API_KEY=... python3 scripts/generate_logo.py
    OPENROUTER_API_KEY=... python3 scripts/generate_logo.py --output /tmp/icon.png
    OPENROUTER_API_KEY=... python3 scripts/generate_logo.py --model google/gemini-3.1-flash-image-preview
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
from urllib import error, request

DEFAULT_MODEL = "google/gemini-2.5-flash-image"
DEFAULT_OUTPUT = Path("assets/logo.png")
DEFAULT_PROMPT = (
    "Design a glossy macOS app icon for an app named Transcribeer. "
    "Main motif: a single centered golden beer mug with creamy foam and a microphone integrated into the composition so both are clearly visible even at tiny sizes. "
    "The microphone should feel like part of the icon, not a background prop: either attached to the mug handle area or overlapping the mug in a balanced way. "
    "Style: premium macOS app icon, polished 3D illustration, rounded-square icon tile, bold silhouette, high contrast, simple centered composition, subtle gloss, soft shadow, warm amber highlights. "
    "Background: deep teal to midnight blue gradient tile for contrast. "
    "Important: no text, no letters, no extra objects, no busy scene, no watermark, no border clutter. "
    "The icon must remain instantly recognizable in an app list at small sizes."
)


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output image path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"OpenRouter model ID (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--image-size",
        default="2K",
        choices=["0.5K", "1K", "2K", "4K"],
        help="Requested image resolution (default: 2K)",
    )
    parser.add_argument(
        "--prompt",
        default=DEFAULT_PROMPT,
        help="Prompt override for experimentation",
    )
    parser.add_argument(
        "--raw-response",
        type=Path,
        default=Path("/tmp/transcribeer-logo-openrouter-response.json"),
        help="Where to save the raw OpenRouter JSON response",
    )
    return parser.parse_args()


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    """Build the OpenRouter API payload."""
    return {
        "model": args.model,
        "messages": [
            {
                "role": "user",
                "content": args.prompt,
            }
        ],
        "modalities": ["image", "text"],
        "image_config": {
            "aspect_ratio": "1:1",
            "image_size": args.image_size,
        },
    }


def send_request(payload: dict[str, Any], api_key: str) -> dict[str, Any]:
    """Send the image generation request to OpenRouter."""
    req = request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        method="POST",
    )
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("HTTP-Referer", "https://github.com/moshebe/transcribeer")
    req.add_header("X-Title", "Transcribeer logo generation")

    data = json.dumps(payload).encode("utf-8")

    try:
        with request.urlopen(req, data=data, timeout=180) as response:
            return json.loads(response.read())
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenRouter HTTP {exc.code}: {body}") from exc
    except error.URLError as exc:
        raise RuntimeError(f"OpenRouter request failed: {exc.reason}") from exc


def extract_image_bytes(result: dict[str, Any]) -> tuple[bytes, str, str]:
    """Extract the first generated image from the API response."""
    choices = result.get("choices") or []
    if not choices:
        raise RuntimeError("OpenRouter response did not include any choices")

    message = choices[0].get("message") or {}
    images = message.get("images") or []
    if not images:
        content = message.get("content", "")
        raise RuntimeError(f"OpenRouter response did not include any images. Content: {content}")

    image_url = ((images[0].get("image_url") or {}).get("url"))
    if not image_url:
        raise RuntimeError("OpenRouter image entry did not include a data URL")

    match = re.match(r"data:(image/[^;]+);base64,(.*)", image_url, re.DOTALL)
    if not match:
        raise RuntimeError("OpenRouter image URL was not a base64 data URL")

    mime_type, encoded = match.groups()
    return base64.b64decode(encoded), mime_type, str(message.get("content", ""))


def main() -> int:
    """Generate the image and write it to disk."""
    args = parse_args()
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        print("OPENROUTER_API_KEY is required", file=sys.stderr)
        return 1

    payload = build_payload(args)
    result = send_request(payload, api_key)

    args.raw_response.parent.mkdir(parents=True, exist_ok=True)
    args.raw_response.write_text(json.dumps(result, indent=2), encoding="utf-8")

    image_bytes, mime_type, message = extract_image_bytes(result)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image_bytes)

    print(f"Wrote {args.output} ({mime_type})")
    if message:
        print(message)
    print(f"Saved raw response to {args.raw_response}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
