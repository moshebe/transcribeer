"""Session metadata: read/write meta.json inside a session directory."""
from __future__ import annotations

import json
from pathlib import Path


def read_meta(session_dir: Path) -> dict:
    """Return parsed meta.json, or {} if missing/invalid."""
    p = Path(session_dir) / "meta.json"
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_meta(session_dir: Path, data: dict) -> None:
    """Atomically write data to meta.json."""
    p = Path(session_dir) / "meta.json"
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


def get_display_name(session_dir: Path) -> str:
    """Return meta['name'] if set, else directory basename."""
    session_dir = Path(session_dir)
    name = read_meta(session_dir).get("name", "")
    return name if name else session_dir.name


def set_name(session_dir: Path, name: str) -> None:
    """Set the name field, preserving other fields."""
    data = read_meta(session_dir)
    data["name"] = name
    write_meta(session_dir, data)


def set_tags(session_dir: Path, tags: list[str]) -> None:
    """Set the tags field, preserving other fields."""
    data = read_meta(session_dir)
    data["tags"] = tags
    write_meta(session_dir, data)
