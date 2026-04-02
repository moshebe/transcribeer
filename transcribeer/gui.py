"""macOS menubar GUI using rumps."""
from __future__ import annotations

import signal
import subprocess
import threading
import time
from pathlib import Path

import AppKit
import UserNotifications as UN
import objc
import rumps

from transcribeer.config import load
from transcribeer.settings_window import SettingsWindowController


def _load_shell_env() -> None:
    """
    When launched as a menubar app (not from a terminal) macOS gives the process
    a minimal env — API keys set in ~/.zshrc / ~/.zprofile are missing.
    Spawn a login shell to collect env vars and merge them into os.environ.
    """
    import os
    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        result = subprocess.run(
            [shell, "-l", "-c", "env"],
            capture_output=True, text=True, timeout=5,
        )
        for line in result.stdout.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                if k not in os.environ:  # don't overwrite existing values
                    os.environ[k] = v
    except Exception:
        pass  # best-effort; the app still works without it


# us.zoom.caphost only runs when a Zoom meeting is active (not just Zoom idle)
_ZOOM_MEETING_BUNDLE = "us.zoom.caphost"
_NOTIF_CATEGORY = "ZOOM_MEETING"
_ACTION_RECORD = "record"
_TICK_INTERVAL = 1      # seconds
_ZOOM_POLL_EVERY = 5    # ticks


# ── Notification delegate ─────────────────────────────────────────────────────

class _NotifDelegate(AppKit.NSObject):
    """Routes UNUserNotification action taps back to the app."""

    def init(self):
        self = objc.super(_NotifDelegate, self).init()
        self._on_record = None
        return self

    def userNotificationCenter_didReceiveNotificationResponse_withCompletionHandler_(
        self, center, response, completionHandler
    ):
        identifier = str(response.actionIdentifier())
        # Both explicit "record" action and clicking the banner body trigger recording
        if identifier in (_ACTION_RECORD, "com.apple.UNNotificationDefaultActionIdentifier"):
            if self._on_record:
                self._on_record()
        completionHandler()

    def userNotificationCenter_willPresentNotification_withCompletionHandler_(
        self, center, notification, completionHandler
    ):
        # Show banner even while the app is frontmost
        completionHandler(UN.UNNotificationPresentationOptionBanner)


def _setup_notifications(delegate: _NotifDelegate) -> None:
    """Register notification category + actions and request permission."""
    record_action = UN.UNNotificationAction.actionWithIdentifier_title_options_(
        _ACTION_RECORD, "⏺ Start Recording", UN.UNNotificationActionOptionForeground
    )
    dismiss_action = UN.UNNotificationAction.actionWithIdentifier_title_options_(
        "dismiss", "Dismiss", UN.UNNotificationActionOptions(0)
    )
    category = UN.UNNotificationCategory.categoryWithIdentifier_actions_intentIdentifiers_options_(
        _NOTIF_CATEGORY, [record_action, dismiss_action], [],
        UN.UNNotificationCategoryOptions(0),
    )
    center = UN.UNUserNotificationCenter.currentNotificationCenter()
    center.setDelegate_(delegate)
    center.setNotificationCategories_(AppKit.NSSet.setWithObject_(category))
    center.requestAuthorizationWithOptions_completionHandler_(
        UN.UNAuthorizationOptionAlert | UN.UNAuthorizationOptionSound,
        None,
    )


def _send_zoom_notification() -> None:
    content = UN.UNMutableNotificationContent.alloc().init()
    content.setTitle_("Zoom meeting in progress")
    content.setBody_("No recording active — want to record this meeting?")
    content.setCategoryIdentifier_(_NOTIF_CATEGORY)

    request = UN.UNNotificationRequest.requestWithIdentifier_content_trigger_(
        "zoom_meeting", content, None  # None = deliver immediately
    )
    UN.UNUserNotificationCenter.currentNotificationCenter() \
        .addNotificationRequest_withCompletionHandler_(request, None)


def _cancel_zoom_notification() -> None:
    UN.UNUserNotificationCenter.currentNotificationCenter() \
        .removePendingNotificationRequestsWithIdentifiers_(["zoom_meeting"])
    UN.UNUserNotificationCenter.currentNotificationCenter() \
        .removeDeliveredNotificationsWithIdentifiers_(["zoom_meeting"])


# ── App ───────────────────────────────────────────────────────────────────────

class TranscribeerApp(rumps.App):
    def __init__(self):
        _icon_path = Path(__file__).parent.parent / "assets" / "logo.png"
        _icon = str(_icon_path) if _icon_path.exists() else None
        super().__init__("🍺", quit_button="Quit", icon=_icon, template=False)
        self.cfg = load()
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._capture_proc: subprocess.Popen | None = None
        self._sess: Path | None = None
        self._record_start: float | None = None
        self._zoom_in_meeting = False
        self._tick_count = 0

        # Notification delegate (must stay alive for the app lifetime)
        self._notif_delegate = _NotifDelegate.alloc().init()
        self._notif_delegate._on_record = self._on_start
        _setup_notifications(self._notif_delegate)

        # Settings window controller (lazy — built on first open)
        self._settings_ctrl: SettingsWindowController | None = None
        self._history_window = None  # lazy-init on first click

        # Menu items
        self._status_item = rumps.MenuItem("", callback=None)
        self._open_item = rumps.MenuItem("📁 Open Session Dir", callback=self._on_open)
        self._rename_item = rumps.MenuItem("✏️ Rename Session…", callback=self._on_rename)
        self._stop_item = rumps.MenuItem("⏹ Stop Recording", callback=self._on_stop)
        self._start_item = rumps.MenuItem("Start Recording", callback=self._on_start)
        self._history_item = rumps.MenuItem("History…", callback=self._on_history)
        self._settings_item = rumps.MenuItem("Settings…", callback=self._on_settings)

        self.menu = [
            self._status_item,
            self._open_item,
            self._rename_item,
            self._stop_item,
            None,
            self._start_item,
            None,
            self._history_item,
            self._settings_item,
        ]

        self._timer = rumps.Timer(self._tick, _TICK_INTERVAL)
        self._timer.start()

        self._set_idle()
        self._check_zoom()  # handle meeting already running at launch

    # ── Timer ─────────────────────────────────────────────────────────────────

    def _tick(self, _timer):
        self._tick_count += 1

        if self._record_start is not None and self._capture_proc is not None:
            elapsed = int(time.time() - self._record_start)
            m, s = divmod(elapsed, 60)
            self._status_item.title = f"⏺ Recording  {m:02d}:{s:02d}"

        if self._tick_count % _ZOOM_POLL_EVERY == 0:
            self._check_zoom()

    def _check_zoom(self):
        workspace = AppKit.NSWorkspace.sharedWorkspace()
        now_in_meeting = any(
            app.bundleIdentifier() == _ZOOM_MEETING_BUNDLE
            for app in workspace.runningApplications()
        )
        if now_in_meeting == self._zoom_in_meeting:
            return

        self._zoom_in_meeting = now_in_meeting
        recording_active = self._thread is not None and self._thread.is_alive()

        if now_in_meeting and not recording_active:
            _send_zoom_notification()
        else:
            _cancel_zoom_notification()

    # ── Menu callbacks ────────────────────────────────────────────────────────

    def _on_settings(self, _=None):
        if self._settings_ctrl is None:
            self._settings_ctrl = SettingsWindowController.alloc().initWithApp_(self)
        self._settings_ctrl.show()

    def _on_history(self, _=None):
        from transcribeer.history_window import HistoryWindow
        if self._history_window is None:
            self._history_window = HistoryWindow(self.cfg)
        self._history_window.show()

    def _on_start(self, _=None):
        from transcribeer import session
        _cancel_zoom_notification()
        self._stop_event.clear()
        sess = session.new_session(self.cfg.sessions_dir)
        self._sess = sess
        self._thread = threading.Thread(target=self._run, args=(sess,), daemon=True)
        self._thread.start()

    def _on_rename(self, _=None):
        if self._sess is None:
            return
        from transcribeer.meta import read_meta, set_name
        current = read_meta(self._sess).get("name", "")
        win = rumps.Window(
            message="Supports any language, including Hebrew (עברית) and special characters:",
            title="Name this session",
            default_text=current,
            ok="Save",
            cancel="Cancel",
            dimensions=(300, 24),
        )
        response = win.run()
        if response.clicked and response.text.strip():
            set_name(self._sess, response.text.strip())
        self._update_rename_label()

    def _update_rename_label(self) -> None:
        """Refresh the rename menu item to show the current session name."""
        if self._sess is None:
            self._rename_item.title = "✏️ Rename Session…"
            return
        from transcribeer.meta import read_meta
        name = read_meta(self._sess).get("name", "")
        self._rename_item.title = f"✏️ {name}" if name else "✏️ Rename Session…"

    def _on_stop(self, _=None):
        self._stop_event.set()
        proc = self._capture_proc
        if proc:
            proc.send_signal(signal.SIGINT)
        self._stop_item.set_callback(None)

    def _on_open(self, _=None):
        if self._sess:
            subprocess.run(["open", str(self._sess)])

    # ── Pipeline (background thread) ─────────────────────────────────────────

    def _run(self, sess: Path):
        from transcribeer import transcribe as tx, summarize as sm

        cfg = self.cfg
        audio_path = sess / "audio.wav"
        transcript_path = sess / "transcript.txt"
        summary_path = sess / "summary.md"

        # 1. Record
        self._set_recording()
        try:
            self._capture_proc = subprocess.Popen(
                [str(cfg.capture_bin), str(audio_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            _, stderr = self._capture_proc.communicate()
            rc = self._capture_proc.returncode
            self._capture_proc = None
            self._record_start = None

            if rc != 0 and not self._stop_event.is_set():
                err = stderr.decode("utf-8", errors="replace")
                if "Screen & System Audio Recording" in err:
                    return self._set_error("Grant Screen Recording in System Settings → Privacy")
                return self._set_error(f"capture-bin exited {rc}")

            if not audio_path.exists() or audio_path.stat().st_size == 0:
                return self._set_idle()
        except Exception as e:
            self._capture_proc = None
            self._record_start = None
            return self._set_error(str(e))

        mode = cfg.pipeline_mode  # "record-only" | "record+transcribe" | "record+transcribe+summarize"

        if mode == "record-only":
            return self._set_done()

        # 2. Transcribe
        self._set_status("📝 Transcribing…")
        try:
            tx.run(
                audio_path=audio_path,
                language=cfg.language,
                diarize_backend=cfg.diarization,
                num_speakers=cfg.num_speakers,
                out_path=transcript_path,
            )
        except Exception as e:
            return self._set_error(f"Transcription failed: {e}")

        if mode == "record+transcribe":
            return self._set_done()

        # 3. Summarize
        self._set_status("🤔 Summarizing…")
        summary_err: str | None = None
        try:
            summary = sm.run(
                transcript=transcript_path.read_text(encoding="utf-8"),
                backend=cfg.llm_backend,
                model=cfg.llm_model,
                ollama_host=cfg.ollama_host,
            )
            summary_path.write_text(summary, encoding="utf-8")
        except Exception as e:
            summary_err = str(e)

        self._set_done(summary_err)

    # ── State helpers ─────────────────────────────────────────────────────────

    def _set_idle(self):
        self.title = "🎙"
        self._status_item.hidden = True
        self._open_item.hidden = True
        self._rename_item.hidden = True
        self._stop_item.hidden = True
        self._start_item.hidden = False

    def _set_recording(self):
        self._record_start = time.time()
        self.title = "⏺"
        self._status_item.title = "⏺ Recording  00:00"
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._rename_item.title = "✏️ Rename Session…"
        self._rename_item.hidden = False
        self._stop_item.hidden = False
        self._stop_item.set_callback(self._on_stop)
        self._start_item.hidden = True

    def _set_status(self, label: str):
        self.title = label.split()[0]
        self._status_item.title = label
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._rename_item.hidden = True
        self._stop_item.hidden = True
        self._start_item.hidden = True

    def _set_done(self, summary_err: str | None = None):
        from transcribeer.meta import get_display_name
        self.title = "✓"
        display = get_display_name(self._sess) if self._sess else ""
        if summary_err:
            self._status_item.title = "✓ Done  (summary failed)"
            rumps.notification(
                "Transcribee", f"Done — {display}", summary_err, sound=False
            )
        else:
            self._status_item.title = "✓ Done"
            rumps.notification("Transcribee", "Done", display, sound=False)
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._stop_item.hidden = True
        self._start_item.hidden = False

    def _set_error(self, msg: str):
        self.title = "⚠"
        self._status_item.title = "⚠ Error"
        self._status_item.hidden = False
        self._open_item.hidden = self._sess is None
        self._rename_item.hidden = True
        self._stop_item.hidden = True
        self._start_item.hidden = False
        rumps.alert(title="Transcribeer Error", message=msg)


def main():
    _load_shell_env()
    TranscribeerApp().run()


if __name__ == "__main__":
    main()
