"""Settings window — WKWebView-based."""
from __future__ import annotations

from transcribeer import config as cfg_mod
from transcribeer.keychain import get_api_key, set_api_key
from transcribeer.webview_window import WebViewWindow

_W, _H = 480, 520


class SettingsWindowController(WebViewWindow):
    """Drop-in replacement for the old AppKit settings window."""

    def __init__(self, app):
        super().__init__(
            html_name="settings",
            title="Transcribeer Settings",
            width=_W,
            height=_H,
            resizable=False,
        )
        self._app = app

    # ── WebViewWindow hooks ───────────────────────────────────────────────────

    def on_load(self):
        cfg = self._app.cfg
        api_key = get_api_key(cfg.llm_backend) or ""
        self.send("init", {
            "pipeline_mode":  cfg.pipeline_mode,
            "diarization":    cfg.diarization,
            "llm_backend":    cfg.llm_backend,
            "llm_model":      cfg.llm_model,
            "ollama_host":    cfg.ollama_host,
            "api_key":        api_key,
            "prompt_on_stop": cfg.prompt_on_stop,
        })

    def handle_message(self, action: str, payload: dict):
        if action == "save":
            self._save_field(payload.get("key", ""), payload.get("value", ""))

    # ── Internal ──────────────────────────────────────────────────────────────

    def _save_field(self, key: str, value: str) -> None:
        old = self._app.cfg
        kwargs = {
            "language":       old.language,
            "diarization":    old.diarization,
            "num_speakers":   old.num_speakers,
            "llm_backend":    old.llm_backend,
            "llm_model":      old.llm_model,
            "ollama_host":    old.ollama_host,
            "sessions_dir":   old.sessions_dir,
            "capture_bin":    old.capture_bin,
            "pipeline_mode":  old.pipeline_mode,
            "prompt_on_stop": old.prompt_on_stop,
        }
        if key == "api_key":
            if value.strip():
                try:
                    set_api_key(old.llm_backend, value.strip())
                except Exception:
                    pass
            return
        if key == "prompt_on_stop":
            kwargs["prompt_on_stop"] = value.strip() == "true"
        elif key in kwargs and value.strip():
            kwargs[key] = value.strip()
        cfg_mod.save(cfg_mod.Config(**kwargs))
        self._app.cfg = cfg_mod.load()

    # ── Public (keeps same interface as old controller) ───────────────────────

    def show(self) -> None:
        already_built = self._window is not None
        super().show()
        # Re-send init so fields reflect latest config on re-open.
        # On first open, on_load() fires via _NavDelegate after HTML loads.
        if already_built and self._webview is not None:
            self.on_load()

    # ── Old AppKit factory shim (gui.py calls alloc().initWithApp_()) ─────────

    @classmethod
    def alloc(cls):
        return cls.__new__(cls)

    def initWithApp_(self, app):
        self.__init__(app)
        return self
