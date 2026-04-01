"""Prompt for a session name before recording starts."""
from __future__ import annotations

import rumps


def ask_session_name(default: str = "") -> str | None:
    """
    Show a dialog asking for an optional session name.

    Returns:
        str  — name entered (may be empty = unnamed)
        None — user cancelled
    """
    win = rumps.Window(
        message="Enter an optional name for this session:",
        title="Name this session",
        default_text=default,
        ok="Start Recording",
        cancel="Cancel",
        dimensions=(240, 24),
    )
    response = win.run()
    if response.clicked == 0:  # Cancel or closed
        return None
    return response.text.strip()
