"""Native macOS History window using AppKit (PyObjC)."""
from __future__ import annotations

import threading
import wave
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

import objc
from AppKit import (
    NSApp,
    NSBackingStoreBuffered,
    NSBorderlessWindowMask,
    NSButton,
    NSFont,
    NSLayoutConstraint,
    NSMakeRect,
    NSMakeSize,
    NSMinXEdge,
    NSObject,
    NSScrollView,
    NSSearchField,
    NSSegmentedControl,
    NSSegmentStyleTexturedRounded,
    NSStackView,
    NSStackViewGravityLeading,
    NSTableColumn,
    NSTableView,
    NSTextField,
    NSTextView,
    NSTitledWindowMask,
    NSResizableWindowMask,
    NSClosableWindowMask,
    NSMiniaturizableWindowMask,
    NSView,
    NSWindow,
    NSSplitView,
    NSColor,
    NSScrollElasticityNone,
    NSTokenField,
    NSUserInterfaceLayoutOrientationVertical,
    NSUserInterfaceLayoutOrientationHorizontal,
    NSBox,
    NSBoxSeparator,
    NSApplication,
)
from Foundation import NSIndexSet, NSMutableArray, NSObject as NSObjectF

if TYPE_CHECKING:
    from transcribee.config import Config

from transcribee.meta import read_meta, write_meta, get_display_name


# ── Helpers ───────────────────────────────────────────────────────────────────

def list_sessions(sessions_dir: Path) -> list[Path]:
    """Return session dirs sorted most-recent first (by name, then ctime fallback)."""
    sessions_dir = Path(sessions_dir)
    if not sessions_dir.exists():
        return []
    dirs = sorted(
        (d for d in sessions_dir.iterdir() if d.is_dir()),
        key=lambda d: (d.name, d.stat().st_ctime),
        reverse=True,
    )
    return dirs


def _format_date(session_dir: Path) -> str:
    try:
        dt = datetime.fromtimestamp(session_dir.stat().st_ctime)
        return dt.strftime("%b %-d, %Y %H:%M")
    except Exception:
        return session_dir.name


def _audio_duration(session_dir: Path) -> str:
    p = session_dir / "audio.wav"
    if not p.exists():
        return "—"
    try:
        with wave.open(str(p), "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            secs = int(frames / rate) if rate else 0
            m, s = divmod(secs, 60)
            return f"{m}:{s:02d}"
    except Exception:
        return "—"


def _run_on_main(fn):
    """Schedule fn() on the main thread via performSelectorOnMainThread."""
    _MainRunner.alloc().initWithFn_(fn).runOnMain()


class _MainRunner(NSObject):
    def initWithFn_(self, fn):
        self = objc.super(_MainRunner, self).init()
        self._fn = fn
        return self

    def runOnMain(self):
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            b"_exec", None, False
        )

    @objc.python_method
    def _exec_impl(self):
        self._fn()

    def _exec(self):
        self._fn()


# ── Table data source / delegate ──────────────────────────────────────────────

class _SessionTableDS(NSObject):
    def init(self):
        self = objc.super(_SessionTableDS, self).init()
        self._sessions: list[Path] = []
        self._filtered: list[Path] = []
        self._filter = ""
        return self

    @objc.python_method
    def set_sessions(self, sessions: list[Path]):
        self._sessions = sessions
        self._apply_filter()

    @objc.python_method
    def set_filter(self, text: str):
        self._filter = text.lower().strip()
        self._apply_filter()

    @objc.python_method
    def _apply_filter(self):
        if not self._filter:
            self._filtered = list(self._sessions)
        else:
            self._filtered = [
                s for s in self._sessions
                if self._filter in get_display_name(s).lower()
            ]

    @objc.python_method
    def session_at(self, idx: int) -> Path | None:
        if 0 <= idx < len(self._filtered):
            return self._filtered[idx]
        return None

    def numberOfRowsInTableView_(self, tv):
        return len(self._filtered)

    def tableView_objectValueForTableColumn_row_(self, tv, col, row):
        sess = self._filtered[row]
        name = get_display_name(sess)
        date = _format_date(sess)
        audio = "audio" if (sess / "audio.wav").exists() else "·audio"
        tx = "transcript" if (sess / "transcript.txt").exists() else "·transcript"
        sm = "summary" if (sess / "summary.md").exists() else "·summary"
        return f"{name}\n{date}\n{audio}  {tx}  {sm}"


# ── Detail panel controller ───────────────────────────────────────────────────

class _DetailPanel(NSObject):
    def initWithCfg_(self, cfg):
        self = objc.super(_DetailPanel, self).init()
        self._cfg = cfg
        self._session: Path | None = None
        self._tab = 0  # 0=transcript 1=summary
        self._build()
        return self

    @objc.python_method
    def _build(self):
        self.view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 600, 600))
        self.view.setWantsLayer_(True)

        # Name field (editable)
        self._name_field = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 0, 200, 24))
        self._name_field.setFont_(NSFont.boldSystemFontOfSize_(15))
        self._name_field.setBezeled_(False)
        self._name_field.setDrawsBackground_(False)
        self._name_field.setDelegate_(self)
        self._name_field.setPlaceholderString_("Session name")

        # Date label
        self._date_label = NSTextField.labelWithString_("—")
        self._date_label.setFont_(NSFont.systemFontOfSize_(12))
        self._date_label.setTextColor_(NSColor.secondaryLabelColor())

        # Duration label
        self._dur_label = NSTextField.labelWithString_("—")
        self._dur_label.setFont_(NSFont.systemFontOfSize_(12))
        self._dur_label.setTextColor_(NSColor.secondaryLabelColor())

        # Tags field
        self._tags_field = NSTokenField.alloc().initWithFrame_(NSMakeRect(0, 0, 400, 24))
        self._tags_field.setPlaceholderString_("Add tags…")
        self._tags_field.setDelegate_(self)
        self._tags_field.setBezeled_(True)

        # Segmented control
        self._seg = NSSegmentedControl.segmentedControlWithLabels_trackingMode_target_action_(
            ["Transcript", "Summary"], 1, self, b"_onSegment:"
        )
        self._seg.setSelectedSegment_(0)

        # Text views
        self._tx_scroll, self._tx_view = _make_text_scroll(monospace=True)
        self._sm_scroll, self._sm_view = _make_text_scroll(monospace=False)

        # Status label
        self._status_label = NSTextField.labelWithString_("")
        self._status_label.setFont_(NSFont.systemFontOfSize_(11))
        self._status_label.setTextColor_(NSColor.secondaryLabelColor())

        # Action buttons
        self._tx_btn = NSButton.buttonWithTitle_target_action_(
            "Transcribe now", self, b"_onTranscribe:"
        )
        self._sm_btn = NSButton.buttonWithTitle_target_action_(
            "Summarize now", self, b"_onSummarize:"
        )

        # Layout via autoresizing — keep it simple
        self._layout()

    @objc.python_method
    def _layout(self):
        v = self.view
        PAD = 16

        # Position is set in _resize; just add subviews
        for sub in [
            self._name_field, self._date_label, self._dur_label,
            self._tags_field, self._seg, self._tx_scroll, self._sm_scroll,
            self._status_label, self._tx_btn, self._sm_btn,
        ]:
            v.addSubview_(sub)

    @objc.python_method
    def _resize_to(self, w: float, h: float):
        PAD = 16
        y = h - PAD

        # Name
        y -= 28
        self._name_field.setFrame_(NSMakeRect(PAD, y, w - PAD * 2, 24))

        # Date + duration on same line
        y -= 20
        self._date_label.setFrame_(NSMakeRect(PAD, y, 300, 16))
        self._dur_label.setFrame_(NSMakeRect(PAD + 310, y, 120, 16))

        # Tags
        y -= 32
        self._tags_field.setFrame_(NSMakeRect(PAD, y, w - PAD * 2, 24))

        # Separator gap
        y -= 12

        # Segmented control
        seg_w = 200.0
        self._seg.setFrame_(NSMakeRect(PAD, y - 24, seg_w, 24))
        y -= 32

        # Buttons + status at bottom
        btn_h = 28
        btn_y = PAD
        self._sm_btn.setFrame_(NSMakeRect(w - PAD - 120, btn_y, 120, btn_h))
        self._tx_btn.setFrame_(NSMakeRect(w - PAD - 250, btn_y, 120, btn_h))
        self._status_label.setFrame_(NSMakeRect(PAD, btn_y, w - PAD * 2 - 260, btn_h))

        # Text area fills remaining
        text_h = y - btn_y - btn_h - PAD
        self._tx_scroll.setFrame_(NSMakeRect(PAD, btn_y + btn_h + PAD, w - PAD * 2, text_h))
        self._sm_scroll.setFrame_(NSMakeRect(PAD, btn_y + btn_h + PAD, w - PAD * 2, text_h))

    @objc.python_method
    def load_session(self, session_dir: Path | None):
        self._session = session_dir
        if session_dir is None:
            self._name_field.setStringValue_("")
            self._date_label.setStringValue_("")
            self._dur_label.setStringValue_("")
            self._tags_field.setObjectValue_(NSMutableArray.array())
            self._set_text(self._tx_view, "")
            self._set_text(self._sm_view, "")
            self._tx_btn.setEnabled_(False)
            self._sm_btn.setEnabled_(False)
            return

        meta = read_meta(session_dir)
        self._name_field.setStringValue_(meta.get("name", ""))
        self._date_label.setStringValue_(_format_date(session_dir))
        self._dur_label.setStringValue_(_audio_duration(session_dir))

        tags = meta.get("tags", [])
        arr = NSMutableArray.arrayWithArray_(tags)
        self._tags_field.setObjectValue_(arr)

        self._reload_transcript()
        self._reload_summary()

        self._tx_btn.setEnabled_((session_dir / "audio.wav").exists())
        self._sm_btn.setEnabled_((session_dir / "transcript.txt").exists())
        self._status_label.setStringValue_("")

        # show correct tab
        self._show_tab(self._tab)

    @objc.python_method
    def _reload_transcript(self):
        p = self._session and (self._session / "transcript.txt")
        if p and p.exists():
            self._set_text(self._tx_view, p.read_text(encoding="utf-8"))
        else:
            self._set_text(self._tx_view, "No transcript yet.")

    @objc.python_method
    def _reload_summary(self):
        p = self._session and (self._session / "summary.md")
        if p and p.exists():
            self._set_text(self._sm_view, p.read_text(encoding="utf-8"))
        else:
            self._set_text(self._sm_view, "No summary yet.")

    @objc.python_method
    def _set_text(self, tv, text: str):
        tv.setString_(text)

    @objc.python_method
    def _show_tab(self, idx: int):
        self._tab = idx
        self._tx_scroll.setHidden_(idx != 0)
        self._sm_scroll.setHidden_(idx != 1)

    @objc.python_method
    def _save_name(self):
        if self._session is None:
            return
        name = str(self._name_field.stringValue()).strip()
        data = read_meta(self._session)
        data["name"] = name
        write_meta(self._session, data)

    @objc.python_method
    def _save_tags(self):
        if self._session is None:
            return
        raw = self._tags_field.objectValue()
        tags = [str(t) for t in raw] if raw else []
        data = read_meta(self._session)
        data["tags"] = tags
        write_meta(self._session, data)

    # ── ObjC selectors ────────────────────────────────────────────────────────

    def _onSegment_(self, sender):
        self._show_tab(sender.selectedSegment())

    def _onTranscribe_(self, sender):
        if self._session is None:
            return
        sess = self._session
        cfg = self._cfg
        self._tx_btn.setEnabled_(False)
        self._status_label.setStringValue_("Transcribing…")

        def _run():
            from transcribee import transcribe as tx

            def _prog(step, pct=None):
                label = f"Transcribing: {step}" + (f" {int(pct * 100)}%" if pct is not None else "")
                _run_on_main(lambda: self._status_label.setStringValue_(label))

            try:
                tx.run(
                    audio_path=sess / "audio.wav",
                    language=cfg.language,
                    diarize_backend=cfg.diarization,
                    num_speakers=cfg.num_speakers,
                    out_path=sess / "transcript.txt",
                    on_progress=_prog,
                )
            except Exception as e:
                _run_on_main(lambda: self._status_label.setStringValue_(f"Error: {e}"))
                _run_on_main(lambda: self._tx_btn.setEnabled_(True))
                return

            def _done():
                self._reload_transcript()
                self._sm_btn.setEnabled_((sess / "transcript.txt").exists())
                self._tx_btn.setEnabled_(True)
                self._status_label.setStringValue_("Transcription done.")

            _run_on_main(_done)

        threading.Thread(target=_run, daemon=True).start()

    def _onSummarize_(self, sender):
        if self._session is None:
            return
        sess = self._session
        cfg = self._cfg
        self._sm_btn.setEnabled_(False)
        self._status_label.setStringValue_("Summarizing…")

        def _run():
            from transcribee import summarize as sm

            try:
                transcript = (sess / "transcript.txt").read_text(encoding="utf-8")
                summary = sm.run(
                    transcript=transcript,
                    backend=cfg.llm_backend,
                    model=cfg.llm_model,
                    ollama_host=cfg.ollama_host,
                )
                (sess / "summary.md").write_text(summary, encoding="utf-8")
            except Exception as e:
                _run_on_main(lambda: self._status_label.setStringValue_(f"Error: {e}"))
                _run_on_main(lambda: self._sm_btn.setEnabled_(True))
                return

            def _done():
                self._reload_summary()
                self._sm_btn.setEnabled_(True)
                self._status_label.setStringValue_("Summary done.")

            _run_on_main(_done)

        threading.Thread(target=_run, daemon=True).start()

    # NSTextFieldDelegate — save name on end editing
    def controlTextDidEndEditing_(self, notif):
        obj = notif.object()
        if obj is self._name_field:
            self._save_name()
        elif obj is self._tags_field:
            self._save_tags()


# ── Split-view delegate (stores divider position) ─────────────────────────────

class _SplitDelegate(NSObject):
    def splitView_constrainMinCoordinate_ofSubviewAt_(self, sv, proposed, idx):
        return 180.0 if idx == 0 else proposed

    def splitView_constrainMaxCoordinate_ofSubviewAt_(self, sv, proposed, idx):
        return 380.0 if idx == 0 else proposed


# ── Window controller ─────────────────────────────────────────────────────────

class _WindowDelegate(NSObject):
    def windowWillClose_(self, notif):
        pass  # keep window object alive; just hide later if needed


class HistoryWindow:
    def __init__(self, cfg: "Config"):
        self._cfg = cfg
        self._window: NSWindow | None = None
        self._ds: _SessionTableDS | None = None
        self._detail: _DetailPanel | None = None
        self._table: NSTableView | None = None
        self._split_delegate: _SplitDelegate | None = None

    def _build(self):
        cfg = self._cfg

        # Window
        style = (
            NSTitledWindowMask
            | NSClosableWindowMask
            | NSMiniaturizableWindowMask
            | NSResizableWindowMask
        )
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(200, 200, 900, 600),
            style,
            NSBackingStoreBuffered,
            False,
        )
        win.setTitle_("Recording History")
        win.setMinSize_(NSMakeSize(640, 400))
        delegate = _WindowDelegate.alloc().init()
        win.setDelegate_(delegate)
        self._win_delegate = delegate  # keep alive

        content = win.contentView()

        # ── Split view ────────────────────────────────────────────────────────
        split = NSSplitView.alloc().initWithFrame_(content.bounds())
        split.setDividerStyle_(2)  # NSSplitViewDividerStyleThin
        split.setVertical_(True)
        split.setAutoresizingMask_(18)  # width+height flexible
        split_del = _SplitDelegate.alloc().init()
        split.setDelegate_(split_del)
        self._split_delegate = split_del
        content.addSubview_(split)

        # ── Left panel ────────────────────────────────────────────────────────
        left = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 280, 600))
        left.setAutoresizingMask_(18)

        # Search field
        search = NSSearchField.alloc().initWithFrame_(NSMakeRect(8, 568, 264, 24))
        search.setAutoresizingMask_(2)  # flexible width
        search.setPlaceholderString_("Search sessions…")

        # Table
        table = NSTableView.alloc().initWithFrame_(NSMakeRect(0, 0, 280, 560))
        col = NSTableColumn.alloc().initWithIdentifier_("session")
        col.setWidth_(280)
        col.headerCell().setStringValue_("Sessions")
        table.addTableColumn_(col)
        table.setHeaderView_(None)
        table.setRowHeight_(52)

        ds = _SessionTableDS.alloc().init()
        table.setDataSource_(ds)
        table.setDelegate_(self)
        self._ds = ds
        self._table = table

        table_scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, 280, 560))
        table_scroll.setDocumentView_(table)
        table_scroll.setHasVerticalScroller_(True)
        table_scroll.setAutoresizingMask_(18)

        left.addSubview_(search)
        left.addSubview_(table_scroll)

        # Search field action
        search.setTarget_(self)
        search.setAction_(b"_onSearch:")
        self._search = search

        # Position scroll below search
        sw = left.bounds().size.width
        sh = left.bounds().size.height
        table_scroll.setFrame_(NSMakeRect(0, 0, sw, sh - 34))
        search.setFrame_(NSMakeRect(8, sh - 30, sw - 16, 22))

        # ── Right panel ───────────────────────────────────────────────────────
        right = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, 620, 600))
        right.setAutoresizingMask_(18)

        detail = _DetailPanel.alloc().initWithCfg_(cfg)
        detail.view.setFrame_(right.bounds())
        detail.view.setAutoresizingMask_(18)
        right.addSubview_(detail.view)
        self._detail = detail

        split.addSubview_(left)
        split.addSubview_(right)
        split.setPosition_ofDividerAtIndex_(280, 0)

        # Load sessions
        self._refresh_sessions()

        self._window = win
        self._left = left
        self._right = right

    @objc.python_method
    def _refresh_sessions(self):
        sessions = list_sessions(Path(self._cfg.sessions_dir))
        self._ds.set_sessions(sessions)
        self._table.reloadData()
        # Select first row if any
        if sessions:
            self._table.selectRowIndexes_byExtendingSelection_(
                NSIndexSet.indexSetWithIndex_(0), False
            )
            self._detail.load_session(self._ds.session_at(0))

    def _onSearch_(self, sender):
        text = str(sender.stringValue())
        self._ds.set_filter(text)
        self._table.reloadData()
        # re-select first visible
        if len(self._ds._filtered) > 0:
            self._table.selectRowIndexes_byExtendingSelection_(
                NSIndexSet.indexSetWithIndex_(0), False
            )
            self._detail.load_session(self._ds.session_at(0))
        else:
            self._detail.load_session(None)

    # NSTableViewDelegate
    def tableViewSelectionDidChange_(self, notif):
        idx = self._table.selectedRow()
        sess = self._ds.session_at(idx)
        self._detail.load_session(sess)
        # Resize detail panel to current size
        sz = self._right.bounds().size if self._right else None
        if sz:
            self._detail._resize_to(sz.width, sz.height)

    def tableView_objectValueForTableColumn_row_(self, tv, col, row):
        return self._ds.tableView_objectValueForTableColumn_row_(tv, col, row)

    def numberOfRowsInTableView_(self, tv):
        return self._ds.numberOfRowsInTableView_(tv)

    def show(self):
        if self._window is None:
            self._build()
        self._refresh_sessions()
        # Trigger initial detail resize
        if self._detail and self._right:
            sz = self._right.bounds().size
            self._detail._resize_to(sz.width, sz.height)
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)


# ── Utility ───────────────────────────────────────────────────────────────────

def _make_text_scroll(monospace: bool) -> tuple:
    scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, 400, 300))
    scroll.setHasVerticalScroller_(True)
    scroll.setHasHorizontalScroller_(False)
    scroll.setAutoresizingMask_(18)

    tv = NSTextView.alloc().initWithFrame_(scroll.contentView().bounds())
    tv.setEditable_(False)
    tv.setSelectable_(True)
    tv.setAutoresizingMask_(2)  # flexible width
    if monospace:
        tv.setFont_(NSFont.fontWithName_size_("Menlo", 12))
    else:
        tv.setFont_(NSFont.systemFontOfSize_(13))
    scroll.setDocumentView_(tv)
    return scroll, tv
