"""Native macOS Settings window for Transcribee (AppKit / PyObjC)."""
from __future__ import annotations

import AppKit
import objc

from transcribee import config as cfg_mod
from transcribee.config import Config
from transcribee.keychain import get_api_key, set_api_key

# ── Layout constants ──────────────────────────────────────────────────────────

_W, _H     = 460, 510
_M         = 20          # outer margin
_LBL_W     = 120         # label column width
_CTRL_X    = _M + _LBL_W + 10   # control column x
_CTRL_W    = _W - _CTRL_X - _M  # control column width
_ROW_H     = 28
_SMALL_H   = 18          # caption/help text line height

DIARIZATION_OPTIONS = ["resemblyzer", "none"]
DIARIZATION_DESCS   = {
    "resemblyzer": "Detects and labels multiple speakers in the transcript.",
    "none":        "Disabled — transcript will have a single unlabelled speaker.",
}
BACKEND_OPTIONS = ["ollama", "openai", "anthropic"]
BACKEND_ENV     = {
    "openai":    "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
}


# ── Low-level view helpers ────────────────────────────────────────────────────

def _r(x: float, y: float, w: float, h: float) -> AppKit.NSRect:
    return AppKit.NSMakeRect(x, y, w, h)


def _label(text: str, x: float, y: float, w: float, h: float = 20,
           bold: bool = False, small: bool = False,
           align=AppKit.NSTextAlignmentRight) -> AppKit.NSTextField:
    tf = AppKit.NSTextField.alloc().initWithFrame_(_r(x, y, w, h))
    tf.setStringValue_(text)
    tf.setBezeled_(False)
    tf.setDrawsBackground_(False)
    tf.setEditable_(False)
    tf.setSelectable_(False)
    tf.setAlignment_(align)
    if bold:
        tf.setFont_(AppKit.NSFont.boldSystemFontOfSize_(12))
    elif small:
        tf.setFont_(AppKit.NSFont.systemFontOfSize_(11))
        tf.setTextColor_(AppKit.NSColor.secondaryLabelColor())
    return tf


def _section_header(text: str, y: float, cv: AppKit.NSView) -> float:
    """Adds bold section label + hairline separator. Returns y after header."""
    sep = AppKit.NSBox.alloc().initWithFrame_(_r(_M, y + 6, _W - _M * 2, 1))
    sep.setBoxType_(AppKit.NSBoxSeparator)
    cv.addSubview_(sep)
    lbl = _label(text, _M, y - 18, _W - _M * 2, 18,
                 bold=True, align=AppKit.NSTextAlignmentLeft)
    cv.addSubview_(lbl)
    return y - 26  # cursor after header


def _row_label(text: str, row_y: float, cv: AppKit.NSView) -> None:
    """Right-aligned label vertically centred in a _ROW_H slot."""
    lbl = _label(text, _M, row_y + 4, _LBL_W, 20)
    cv.addSubview_(lbl)


def _checkbox(title: str, x: float, y: float,
              w: float = 260) -> AppKit.NSButton:
    cb = AppKit.NSButton.alloc().initWithFrame_(_r(x, y, w, 20))
    cb.setButtonType_(AppKit.NSButtonTypeSwitch)
    cb.setTitle_(title)
    cb.setFont_(AppKit.NSFont.systemFontOfSize_(13))
    return cb


def _popup(x: float, y: float, w: float,
           items: list[str]) -> AppKit.NSPopUpButton:
    pb = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(_r(x, y, w, 26), False)
    pb.addItemsWithTitles_(items)
    return pb


def _field(x: float, y: float, w: float,
           placeholder: str = "") -> AppKit.NSTextField:
    tf = AppKit.NSTextField.alloc().initWithFrame_(_r(x, y, w, 22))
    tf.setPlaceholderString_(placeholder)
    return tf


def _secure_field(x: float, y: float, w: float,
                  placeholder: str = "") -> AppKit.NSSecureTextField:
    sf = AppKit.NSSecureTextField.alloc().initWithFrame_(_r(x, y, w, 22))
    sf.setPlaceholderString_(placeholder)
    return sf


# ── Controller ────────────────────────────────────────────────────────────────

class SettingsWindowController(AppKit.NSObject):
    """Owns the settings NSWindow. Call show() to open / bring to front."""

    def initWithApp_(self, app) -> "SettingsWindowController":  # noqa: ANN001
        self = objc.super(SettingsWindowController, self).init()
        if self is None:
            return None
        self._app = app
        self._window: AppKit.NSWindow | None = None
        self._build()
        return self

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self) -> None:
        cfg = self._app.cfg

        win = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            _r(0, 0, _W, _H),
            (AppKit.NSWindowStyleMaskTitled
             | AppKit.NSWindowStyleMaskClosable
             | AppKit.NSWindowStyleMaskMiniaturizable),
            AppKit.NSBackingStoreBuffered,
            False,
        )
        win.setTitle_("Transcribee Settings")
        win.setReleasedWhenClosed_(False)
        win.center()
        cv = win.contentView()

        # y cursor starts just above the Save button area and moves upward.
        # AppKit origin = bottom-left, so higher y = higher on screen.
        save_btn = AppKit.NSButton.alloc().initWithFrame_(
            _r(_W - 100 - _M, _M, 100, 32)
        )
        save_btn.setTitle_("Save")
        save_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
        save_btn.setKeyEquivalent_("\r")
        save_btn.setTarget_(self)
        save_btn.setAction_(objc.selector(self._onSave_, signature=b"v@:@"))
        cv.addSubview_(save_btn)

        cancel_btn = AppKit.NSButton.alloc().initWithFrame_(
            _r(_W - 100 - _M - 90, _M, 80, 32)
        )
        cancel_btn.setTitle_("Cancel")
        cancel_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
        cancel_btn.setKeyEquivalent_("\x1b")
        cancel_btn.setTarget_(self)
        cancel_btn.setAction_(objc.selector(self._onCancel_, signature=b"v@:@"))
        cv.addSubview_(cancel_btn)

        y = _M + 32 + 20  # start above button row

        # ── Summarization section ─────────────────────────────────────────────
        y = _section_header("Summarization", y + 40, cv)
        y -= 4

        # API key help text (two lines)
        self._api_help_lbl2 = _label(
            "will be used if this field is left blank.",
            _CTRL_X, y, _CTRL_W, _SMALL_H, small=True,
            align=AppKit.NSTextAlignmentLeft,
        )
        cv.addSubview_(self._api_help_lbl2)
        y += _SMALL_H

        self._api_help_lbl1 = _label(
            "",  # filled dynamically
            _CTRL_X, y, _CTRL_W, _SMALL_H, small=True,
            align=AppKit.NSTextAlignmentLeft,
        )
        cv.addSubview_(self._api_help_lbl1)
        y += _SMALL_H + 4

        # API key field
        _row_label("API key:", y, cv)
        self._api_key_field = _secure_field(
            _CTRL_X, y + 1, _CTRL_W,
            "Optional — overrides the environment variable",
        )
        cv.addSubview_(self._api_key_field)
        existing_key = get_api_key(cfg.llm_backend)
        if existing_key:
            self._api_key_field.setStringValue_(existing_key)
        # Group: api_key_field + both help labels
        self._api_key_views = [
            self._api_key_field,
            self._api_help_lbl1,
            self._api_help_lbl2,
        ]
        y += _ROW_H

        # Ollama host
        _row_label("Ollama host:", y, cv)
        self._ollama_host_field = _field(
            _CTRL_X, y + 1, _CTRL_W, "http://localhost:11434"
        )
        self._ollama_host_field.setStringValue_(cfg.ollama_host)
        cv.addSubview_(self._ollama_host_field)
        self._ollama_host_lbl = _label(
            "Ollama host:", _M, y + 4, _LBL_W
        )
        cv.addSubview_(self._ollama_host_lbl)
        y += _ROW_H

        # Model
        _row_label("Model:", y, cv)
        self._model_field = _field(_CTRL_X, y + 1, _CTRL_W, "llama3")
        self._model_field.setStringValue_(cfg.llm_model)
        cv.addSubview_(self._model_field)
        y += _ROW_H

        # Backend
        _row_label("Backend:", y, cv)
        self._backend_popup = _popup(_CTRL_X, y, _CTRL_W, BACKEND_OPTIONS)
        be_idx = BACKEND_OPTIONS.index(cfg.llm_backend) if cfg.llm_backend in BACKEND_OPTIONS else 0
        self._backend_popup.selectItemAtIndex_(be_idx)
        self._backend_popup.setTarget_(self)
        self._backend_popup.setAction_(
            objc.selector(self._onBackendChange_, signature=b"v@:@")
        )
        cv.addSubview_(self._backend_popup)
        y += _ROW_H + 6

        # ── Transcription section ─────────────────────────────────────────────
        y = _section_header("Transcription", y + 16, cv)
        y -= 4

        # Diarization description (dynamic)
        self._diar_desc = _label(
            DIARIZATION_DESCS.get(cfg.diarization, ""),
            _CTRL_X, y, _CTRL_W, _SMALL_H * 2, small=True,
            align=AppKit.NSTextAlignmentLeft,
        )
        self._diar_desc.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
        cv.addSubview_(self._diar_desc)
        y += _SMALL_H * 2 + 4

        # Diarization popup
        _row_label("Speaker detection:", y, cv)
        self._diar_popup = _popup(_CTRL_X, y, 200, DIARIZATION_OPTIONS)
        diar_idx = (
            DIARIZATION_OPTIONS.index(cfg.diarization)
            if cfg.diarization in DIARIZATION_OPTIONS else 0
        )
        self._diar_popup.selectItemAtIndex_(diar_idx)
        self._diar_popup.setTarget_(self)
        self._diar_popup.setAction_(
            objc.selector(self._onDiarChange_, signature=b"v@:@")
        )
        cv.addSubview_(self._diar_popup)
        y += _ROW_H + 6

        # ── Pipeline section ──────────────────────────────────────────────────
        y = _section_header("Pipeline", y + 16, cv)
        y -= 4

        # Summarize checkbox
        self._summarize_cb = _checkbox(
            "Summarize  (generate a summary after transcription)",
            _M + 20, y,
        )
        self._summarize_cb.setTarget_(self)
        self._summarize_cb.setAction_(
            objc.selector(self._onPipelineChange_, signature=b"v@:@")
        )
        cv.addSubview_(self._summarize_cb)
        y += 28

        # Transcribe checkbox
        self._transcribe_cb = _checkbox(
            "Transcribe  (convert audio to text after recording)",
            _M + 20, y,
        )
        self._transcribe_cb.setTarget_(self)
        self._transcribe_cb.setAction_(
            objc.selector(self._onPipelineChange_, signature=b"v@:@")
        )
        cv.addSubview_(self._transcribe_cb)
        y += 28

        # Record checkbox (always on, readonly)
        self._record_cb = _checkbox("Record  (always enabled)", _M + 20, y)
        self._record_cb.setState_(AppKit.NSControlStateValueOn)
        self._record_cb.setEnabled_(False)
        cv.addSubview_(self._record_cb)

        # ── Load initial pipeline state ───────────────────────────────────────
        self._load_pipeline(cfg.pipeline_mode)

        self._window = win
        self._update_backend_visibility()

    # ── Helpers ───────────────────────────────────────────────────────────────

    @objc.python_method
    def _load_pipeline(self, mode: str) -> None:
        do_tx = mode in ("record+transcribe", "record+transcribe+summarize")
        do_sm = mode == "record+transcribe+summarize"
        state = lambda b: AppKit.NSControlStateValueOn if b else AppKit.NSControlStateValueOff
        self._transcribe_cb.setState_(state(do_tx))
        self._summarize_cb.setState_(state(do_sm))
        self._summarize_cb.setEnabled_(do_tx)

    @objc.python_method
    def _pipeline_mode(self) -> str:
        do_tx = self._transcribe_cb.state() == AppKit.NSControlStateValueOn
        do_sm = do_tx and self._summarize_cb.state() == AppKit.NSControlStateValueOn
        if do_tx and do_sm:
            return "record+transcribe+summarize"
        if do_tx:
            return "record+transcribe"
        return "record-only"

    @objc.python_method
    def _update_backend_visibility(self) -> None:
        backend = str(self._backend_popup.titleOfSelectedItem())
        is_ollama = backend == "ollama"
        self._ollama_host_field.setHidden_(not is_ollama)
        self._ollama_host_lbl.setHidden_(not is_ollama)
        for v in self._api_key_views:
            v.setHidden_(is_ollama)
        if not is_ollama:
            env_var = BACKEND_ENV.get(backend, f"{backend.upper()}_API_KEY")
            self._api_help_lbl1.setStringValue_(
                f"Optional. The {env_var} environment variable"
            )

    # ── Actions ───────────────────────────────────────────────────────────────

    @objc.python_method
    def _onBackendChange_(self, sender) -> None:
        self._update_backend_visibility()

    @objc.python_method
    def _onDiarChange_(self, sender) -> None:
        diar = str(self._diar_popup.titleOfSelectedItem())
        self._diar_desc.setStringValue_(DIARIZATION_DESCS.get(diar, ""))

    @objc.python_method
    def _onPipelineChange_(self, sender) -> None:
        do_tx = self._transcribe_cb.state() == AppKit.NSControlStateValueOn
        self._summarize_cb.setEnabled_(do_tx)
        if not do_tx:
            self._summarize_cb.setState_(AppKit.NSControlStateValueOff)

    @objc.python_method
    def _onSave_(self, sender) -> None:
        old = self._app.cfg
        backend = str(self._backend_popup.titleOfSelectedItem())
        model = str(self._model_field.stringValue()).strip() or old.llm_model
        ollama_host = str(self._ollama_host_field.stringValue()).strip() or old.ollama_host

        new_cfg = Config(
            language=old.language,
            diarization=str(self._diar_popup.titleOfSelectedItem()),
            num_speakers=old.num_speakers,
            llm_backend=backend,
            llm_model=model,
            ollama_host=ollama_host,
            sessions_dir=old.sessions_dir,
            capture_bin=old.capture_bin,
            pipeline_mode=self._pipeline_mode(),
        )
        cfg_mod.save(new_cfg)

        if backend != "ollama":
            api_key = str(self._api_key_field.stringValue()).strip()
            if api_key:
                try:
                    set_api_key(backend, api_key)
                except Exception:
                    pass

        self._app.cfg = cfg_mod.load()
        self._window.orderOut_(None)

    @objc.python_method
    def _onCancel_(self, sender) -> None:
        self._window.orderOut_(None)

    # ── Public ────────────────────────────────────────────────────────────────

    def show(self) -> None:
        """Refresh values from current cfg and bring window to front."""
        cfg = self._app.cfg

        self._load_pipeline(cfg.pipeline_mode)

        diar_idx = (
            DIARIZATION_OPTIONS.index(cfg.diarization)
            if cfg.diarization in DIARIZATION_OPTIONS else 0
        )
        self._diar_popup.selectItemAtIndex_(diar_idx)
        self._diar_desc.setStringValue_(
            DIARIZATION_DESCS.get(cfg.diarization, "")
        )

        be_idx = (
            BACKEND_OPTIONS.index(cfg.llm_backend)
            if cfg.llm_backend in BACKEND_OPTIONS else 0
        )
        self._backend_popup.selectItemAtIndex_(be_idx)
        self._model_field.setStringValue_(cfg.llm_model)
        self._ollama_host_field.setStringValue_(cfg.ollama_host)

        existing_key = get_api_key(cfg.llm_backend)
        self._api_key_field.setStringValue_(existing_key or "")

        self._update_backend_visibility()

        self._window.makeKeyAndOrderFront_(None)
        AppKit.NSApp.activateIgnoringOtherApps_(True)
