"""History window — WKWebView-based."""
from __future__ import annotations

import subprocess
import threading
import wave
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

from transcribeer.meta import get_display_name, read_meta, write_meta, set_notes
from transcribeer.webview_window import WebViewWindow

if TYPE_CHECKING:
    from transcribeer.config import Config


# ── Pure helpers (tested) ─────────────────────────────────────────────────────

def list_sessions(sessions_dir: Path) -> list[Path]:
    """Return session dirs sorted most-recent first."""
    d = Path(sessions_dir)
    if not d.exists():
        return []
    return sorted(
        (p for p in d.iterdir() if p.is_dir()),
        key=lambda p: p.stat().st_ctime,
        reverse=True,
    )


def _format_date(session_dir: Path) -> str:
    try:
        dt = datetime.fromtimestamp(session_dir.stat().st_ctime)
        return dt.strftime("%b %-d, %Y %H:%M")
    except Exception:
        return session_dir.name


def _audio_duration(session_dir: Path) -> str:
    p = Path(session_dir) / "audio.wav"
    if not p.exists():
        return "—"
    try:
        with wave.open(str(p), "rb") as wf:
            secs = int(wf.getnframes() / wf.getframerate())
            m, s = divmod(secs, 60)
            return f"{m}:{s:02d}"
    except Exception:
        return "—"


def _snippet(session_dir: Path) -> str:
    """Return first non-blank line of summary or transcript, or empty string."""
    for fname in ("summary.md", "transcript.txt"):
        p = session_dir / fname
        if p.exists():
            for line in p.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line:
                    return line[:120]
    return ""


def _session_row(session_dir: Path) -> dict:
    name = get_display_name(session_dir)
    raw_name = read_meta(session_dir).get("name", "")
    return {
        "path":     str(session_dir),
        "name":     name,
        "untitled": not raw_name,
        "date":     _format_date(session_dir),
        "duration": _audio_duration(session_dir),
        "snippet":  _snippet(session_dir),
    }


def _session_detail(session_dir: Path) -> dict:
    meta = read_meta(session_dir)
    tx_path = session_dir / "transcript.txt"
    sm_path = session_dir / "summary.md"
    return {
        "name":           meta.get("name", ""),
        "notes":          meta.get("notes", ""),
        "date":           _format_date(session_dir),
        "duration":       _audio_duration(session_dir),
        "transcript":     tx_path.read_text(encoding="utf-8") if tx_path.exists() else "",
        "summary":        sm_path.read_text(encoding="utf-8") if sm_path.exists() else "",
        "can_transcribe": (session_dir / "audio.wav").exists(),
        "can_summarize":  tx_path.exists(),
    }


# ── Window ────────────────────────────────────────────────────────────────────

class HistoryWindow(WebViewWindow):

    def __init__(self, cfg: "Config"):
        super().__init__(
            html_name="history",
            title="Recording History",
            width=900,
            height=600,
            resizable=True,
            min_size=(640, 400),
        )
        self._cfg = cfg
        self._sessions: list[Path] = []

    # ── WebViewWindow hooks ───────────────────────────────────────────────────

    def on_load(self):
        from transcribeer.prompts import list_profiles
        self._sessions = list_sessions(Path(self._cfg.sessions_dir))
        self.send("init", {
            "sessions": [_session_row(s) for s in self._sessions],
            "profiles": list_profiles(),
        })

    def handle_message(self, action: str, payload: dict):
        sess_str = payload.get("session")
        sess = Path(sess_str) if sess_str else None

        if action == "select" and sess:
            self.send("session_data", _session_detail(sess))

        elif action == "rename" and sess:
            data = read_meta(sess)
            data["name"] = payload.get("name", "").strip()
            write_meta(sess, data)
            self._sessions = list_sessions(Path(self._cfg.sessions_dir))
            query = payload.get("query", "").lower().strip()  # normalize
            rows = self._filtered_rows(query)
            self.send("sessions", {"sessions": rows})

        elif action == "save_notes" and sess:
            set_notes(sess, payload.get("notes", ""))

        elif action == "search":
            query = payload.get("query", "").lower().strip()
            rows = self._filtered_rows(query)
            self.send("sessions", {"sessions": rows})

        elif action == "open_dir" and sess:
            subprocess.run(["open", str(sess)], check=False)

        elif action == "transcribe" and sess:
            threading.Thread(
                target=self._run_transcribe, args=(sess,), daemon=True
            ).start()

        elif action == "summarize" and sess:
            profile = payload.get("profile") or None
            threading.Thread(
                target=self._run_summarize, args=(sess, profile), daemon=True
            ).start()

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _filtered_rows(self, query: str) -> list[dict]:
        rows = [_session_row(s) for s in self._sessions]
        if not query:
            return rows
        return [r for r in rows if query in r["name"].lower()]

    def _run_transcribe(self, sess: Path):
        from transcribeer import transcribe as tx

        def _prog(step, pct=None):
            self.send("progress", {"label": f"Transcribing: {step}", "pct": pct})

        try:
            tx.run(
                audio_path=sess / "audio.wav",
                language=self._cfg.language,
                diarize_backend=self._cfg.diarization,
                num_speakers=self._cfg.num_speakers,
                out_path=sess / "transcript.txt",
                on_progress=_prog,
            )
        except Exception as e:
            self.send("progress", {"label": f"Error: {e}", "pct": None})
            return
        self.send("done", {"step": "transcribe"})

    def _run_summarize(self, sess: Path, profile: str | None = None):
        from transcribeer import summarize as sm
        from transcribeer.prompts import load_prompt

        self.send("progress", {"label": "Summarizing…", "pct": None})
        try:
            transcript = (sess / "transcript.txt").read_text(encoding="utf-8")
            prompt = load_prompt(profile)
            summary = sm.run(
                transcript=transcript,
                backend=self._cfg.llm_backend,
                model=self._cfg.llm_model,
                ollama_host=self._cfg.ollama_host,
                prompt=prompt,
            )
            (sess / "summary.md").write_text(summary, encoding="utf-8")
        except Exception as e:
            self.send("progress", {"label": f"Error: {e}", "pct": None})
            return
        self.send("done", {"step": "summarize"})

    # ── Public ────────────────────────────────────────────────────────────────

    def show(self) -> None:
        already_built = self._window is not None
        super().show()
        # Refresh session list on re-open.
        # On first open, on_load() fires via _NavDelegate after HTML loads.
        if already_built and self._webview is not None:
            self.on_load()
