"""macOS Keychain helpers for storing/retrieving API keys via `security` CLI."""
from __future__ import annotations

import subprocess

_SERVICE_PREFIX = "transcribee"


def _service(backend: str) -> str:
    return f"{_SERVICE_PREFIX}/{backend}"


def get_api_key(backend: str) -> str | None:
    """Return the stored API key for *backend*, or None if not found."""
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s", _service(backend),
            "-a", "apikey",
            "-w",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return result.stdout.strip() or None
    return None


def set_api_key(backend: str, key: str) -> None:
    """Store *key* in Keychain for *backend*, overwriting any existing entry."""
    # Delete first (ignore errors if it doesn't exist yet)
    subprocess.run(
        [
            "security",
            "delete-generic-password",
            "-s", _service(backend),
            "-a", "apikey",
        ],
        capture_output=True,
    )
    result = subprocess.run(
        [
            "security",
            "add-generic-password",
            "-s", _service(backend),
            "-a", "apikey",
            "-w", key,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Keychain write failed: {result.stderr.strip()}")


def delete_api_key(backend: str) -> None:
    """Remove the stored API key for *backend* (no-op if not present)."""
    subprocess.run(
        [
            "security",
            "delete-generic-password",
            "-s", _service(backend),
            "-a", "apikey",
        ],
        capture_output=True,
    )
