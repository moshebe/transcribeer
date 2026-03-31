from __future__ import annotations

from datetime import datetime
from pathlib import Path


def new_session(sessions_dir: Path | None = None) -> Path:
    """
    Create a new session directory named YYYY-MM-DD-HHMM.
    Returns the created path.
    """
    if sessions_dir is None:
        from transcribee.config import load
        sessions_dir = load().sessions_dir

    sessions_dir = Path(sessions_dir)
    sessions_dir.mkdir(parents=True, exist_ok=True)

    name = datetime.now().strftime("%Y-%m-%d-%H%M")
    path = sessions_dir / name
    suffix = 0
    while path.exists():
        suffix += 1
        path = sessions_dir / f"{name}-{suffix}"

    path.mkdir()
    return path


def latest_session(sessions_dir: Path | None = None) -> Path | None:
    """Return the most recently created session dir, or None."""
    if sessions_dir is None:
        from transcribee.config import load
        sessions_dir = load().sessions_dir

    sessions_dir = Path(sessions_dir)
    if not sessions_dir.exists():
        return None

    dirs = sorted(
        (d for d in sessions_dir.iterdir() if d.is_dir()),
        key=lambda d: d.stat().st_ctime,  # st_ctime = creation time on macOS
        reverse=True,
    )
    return dirs[0] if dirs else None
