# Custom Prompt Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-defined summarization prompt profiles loaded from `~/.transcribeer/prompts/<name>.md`, selectable per-session in the menubar GUI, history window, and CLI.

**Architecture:** A new `prompts.py` module provides `list_profiles()` and `load_prompt()`. `summarize.run()` gains an optional `prompt` param (None = hardcoded default, no regression). The per-session profile is transient state on the app instance; it is picked at stop time or via a menu item, and passed through the pipeline to `sm.run()`.

**Tech Stack:** Python 3.11, pytest, rumps (macOS menubar), WKWebView (history/settings HTML), typer (CLI), existing `transcribeer` package conventions.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `transcribeer/prompts.py` | **Create** | `list_profiles()`, `load_prompt()` |
| `tests/test_prompts.py` | **Create** | Unit tests for prompts module |
| `transcribeer/summarize.py` | **Modify** | Add `prompt: str \| None` param to `run()` and helpers |
| `tests/test_summarize.py` | **Modify** | Tests for custom prompt being forwarded to LLM |
| `transcribeer/config.py` | **Modify** | Add `prompt_on_stop: bool` field, default True |
| `tests/test_config.py` | **Modify** | Tests for new field loading/saving |
| `transcribeer/settings_window.py` | **Modify** | Send/save `prompt_on_stop` |
| `transcribeer/ui/settings.html` | **Modify** | Toggle for `prompt_on_stop` in Summarization panel |
| `transcribeer/cli.py` | **Modify** | `--profile` / `--prompt-file` on `summarize`; `--profile` on `run` |
| `transcribeer/gui.py` | **Modify** | `_prompt_profile` state, menu item, on-stop picker, pass prompt to pipeline |
| `transcribeer/history_window.py` | **Modify** | Send profiles on load; accept profile in summarize action |
| `transcribeer/ui/history.html` | **Modify** | Profile `<select>` in bottom bar |

---

## Task 1: `prompts.py` — profile discovery and loading

**Files:**
- Create: `transcribeer/prompts.py`
- Create: `tests/test_prompts.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_prompts.py
from pathlib import Path
import pytest


def test_list_profiles_no_dir(monkeypatch, tmp_path):
    """No prompts dir → only 'default' returned."""
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts
    assert prompts.list_profiles() == ["default"]


def test_list_profiles_with_files(monkeypatch, tmp_path):
    """Prompt files appear sorted after 'default'."""
    d = tmp_path / ".transcribeer" / "prompts"
    d.mkdir(parents=True)
    (d / "standup.md").write_text("standup prompt")
    (d / "1on1.md").write_text("1on1 prompt")
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts
    result = prompts.list_profiles()
    assert result[0] == "default"
    assert result[1:] == ["1on1", "standup"]   # sorted


def test_list_profiles_default_md_not_duplicated(monkeypatch, tmp_path):
    """A default.md file does not add a second 'default' entry."""
    d = tmp_path / ".transcribeer" / "prompts"
    d.mkdir(parents=True)
    (d / "default.md").write_text("custom default")
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts
    assert prompts.list_profiles().count("default") == 1


def test_load_prompt_none_returns_system_prompt(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts, summarize
    assert prompts.load_prompt(None) == summarize.SYSTEM_PROMPT


def test_load_prompt_default_no_file_returns_system_prompt(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts, summarize
    assert prompts.load_prompt("default") == summarize.SYSTEM_PROMPT


def test_load_prompt_default_file_overrides_system_prompt(monkeypatch, tmp_path):
    d = tmp_path / ".transcribeer" / "prompts"
    d.mkdir(parents=True)
    (d / "default.md").write_text("Custom default prompt")
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts
    assert prompts.load_prompt("default") == "Custom default prompt"


def test_load_prompt_named_file(monkeypatch, tmp_path):
    d = tmp_path / ".transcribeer" / "prompts"
    d.mkdir(parents=True)
    (d / "1on1.md").write_text("1on1 system prompt")
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts
    assert prompts.load_prompt("1on1") == "1on1 system prompt"


def test_load_prompt_unknown_name_returns_system_prompt(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import prompts, summarize
    assert prompts.load_prompt("nonexistent") == summarize.SYSTEM_PROMPT
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
uv run pytest tests/test_prompts.py -v
```
Expected: `ModuleNotFoundError` or `ImportError` for `transcribeer.prompts`.

- [ ] **Step 3: Implement `transcribeer/prompts.py`**

```python
from __future__ import annotations

from pathlib import Path

from transcribeer.summarize import SYSTEM_PROMPT


def _prompts_dir() -> Path:
    return Path.home() / ".transcribeer" / "prompts"


def list_profiles() -> list[str]:
    """Return available profile names. 'default' is always first."""
    d = _prompts_dir()
    profiles = ["default"]
    if d.exists():
        extras = sorted(
            p.stem for p in d.glob("*.md")
            if p.is_file() and p.stem != "default"
        )
        profiles.extend(extras)
    return profiles


def load_prompt(name: str | None) -> str:
    """Return prompt text for profile `name`. None/'default' with no file → SYSTEM_PROMPT."""
    if not name or name == "default":
        p = _prompts_dir() / "default.md"
        return p.read_text(encoding="utf-8") if p.exists() else SYSTEM_PROMPT
    p = _prompts_dir() / f"{name}.md"
    return p.read_text(encoding="utf-8") if p.exists() else SYSTEM_PROMPT
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
uv run pytest tests/test_prompts.py -v
```
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add transcribeer/prompts.py tests/test_prompts.py
git commit -m "feat: add prompts module with list_profiles and load_prompt"
```

---

## Task 2: `summarize.py` — add `prompt` parameter

**Files:**
- Modify: `transcribeer/summarize.py`
- Modify: `tests/test_summarize.py`

- [ ] **Step 1: Write the failing tests**

Add to the end of `tests/test_summarize.py`:

```python
def test_custom_prompt_sent_to_ollama():
    """Custom prompt is used as the system message, not SYSTEM_PROMPT."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": "ok"}}
    mock_resp.raise_for_status = MagicMock()

    from unittest.mock import patch
    with patch("requests.post", return_value=mock_resp) as mock_post:
        from transcribeer.summarize import run
        run("transcript text", backend="ollama", model="llama3",
            prompt="MY CUSTOM PROMPT")

    body = mock_post.call_args.kwargs["json"]
    system_msg = body["messages"][0]["content"]
    assert system_msg == "MY CUSTOM PROMPT"


def test_none_prompt_uses_system_prompt():
    """Passing prompt=None falls back to SYSTEM_PROMPT."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": "ok"}}
    mock_resp.raise_for_status = MagicMock()

    from unittest.mock import patch
    with patch("requests.post", return_value=mock_resp) as mock_post:
        from transcribeer.summarize import run, SYSTEM_PROMPT
        run("transcript text", backend="ollama", model="llama3", prompt=None)

    body = mock_post.call_args.kwargs["json"]
    system_msg = body["messages"][0]["content"]
    assert system_msg == SYSTEM_PROMPT
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
uv run pytest tests/test_summarize.py::test_custom_prompt_sent_to_ollama tests/test_summarize.py::test_none_prompt_uses_system_prompt -v
```
Expected: FAIL — `run()` doesn't accept `prompt` kwarg yet.

- [ ] **Step 3: Update `transcribeer/summarize.py`**

Replace the entire file with:

```python
from __future__ import annotations

import os

from transcribeer.keychain import get_api_key as _kc_get

SYSTEM_PROMPT = """You are a meeting summarizer. Given a meeting transcript with speaker labels and timestamps, produce a concise summary in the same language as the transcript. Include:
- 2-3 sentence overview
- Key decisions made
- Action items (who, what)
- Open questions

Respond in markdown."""


def run(
    transcript: str,
    backend: str,
    model: str,
    ollama_host: str = "http://localhost:11434",
    prompt: str | None = None,
) -> str:
    """
    Summarize a transcript using the configured LLM backend.

    prompt: custom system prompt; None uses the built-in SYSTEM_PROMPT.
    Reads OPENAI_API_KEY / ANTHROPIC_API_KEY from env as needed.
    Raises ValueError if a required env var is missing.
    Raises ValueError for unknown backend.
    """
    system = prompt if prompt is not None else SYSTEM_PROMPT
    if backend == "openai":
        return _run_openai(transcript, model, system)
    if backend == "anthropic":
        return _run_anthropic(transcript, model, system)
    if backend == "ollama":
        return _run_ollama(transcript, model, ollama_host, system)
    raise ValueError(f"Unknown summarization backend: {backend!r}. Use 'openai', 'anthropic', or 'ollama'.")


def _run_openai(transcript: str, model: str, system: str) -> str:
    api_key = _kc_get("openai") or os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise ValueError("No OpenAI API key found (Keychain or OPENAI_API_KEY env var).")
    from openai import OpenAI
    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": transcript},
        ],
    )
    return response.choices[0].message.content


def _run_anthropic(transcript: str, model: str, system: str) -> str:
    api_key = _kc_get("anthropic") or os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise ValueError("No Anthropic API key found (Keychain or ANTHROPIC_API_KEY env var).")
    from anthropic import Anthropic
    client = Anthropic(api_key=api_key)
    response = client.messages.create(
        model=model,
        max_tokens=1024,
        system=system,
        messages=[
            {"role": "user", "content": transcript},
        ],
    )
    return response.content[0].text


def _run_ollama(transcript: str, model: str, ollama_host: str, system: str) -> str:
    import requests
    response = requests.post(
        f"{ollama_host}/api/chat",
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": transcript},
            ],
            "stream": False,
        },
    )
    response.raise_for_status()
    return response.json()["message"]["content"]
```

- [ ] **Step 4: Run full summarize test suite**

```bash
uv run pytest tests/test_summarize.py -v
```
Expected: all 10 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add transcribeer/summarize.py tests/test_summarize.py
git commit -m "feat: add optional prompt param to summarize.run()"
```

---

## Task 3: `config.py` — add `prompt_on_stop`

**Files:**
- Modify: `transcribeer/config.py`
- Modify: `tests/test_config.py`

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_config.py`:

```python
def test_prompt_on_stop_default_true(monkeypatch, tmp_path):
    """Missing config → prompt_on_stop defaults to True."""
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.prompt_on_stop is True


def test_prompt_on_stop_false_from_toml(monkeypatch, tmp_path):
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text("[summarization]\nprompt_on_stop = false\n")
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.prompt_on_stop is False


def test_save_round_trips_prompt_on_stop(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load, save
    cfg = load()
    cfg_off = cfg.__class__(
        language=cfg.language,
        diarization=cfg.diarization,
        num_speakers=cfg.num_speakers,
        llm_backend=cfg.llm_backend,
        llm_model=cfg.llm_model,
        ollama_host=cfg.ollama_host,
        sessions_dir=cfg.sessions_dir,
        capture_bin=cfg.capture_bin,
        pipeline_mode=cfg.pipeline_mode,
        prompt_on_stop=False,
    )
    save(cfg_off)
    reloaded = load()
    assert reloaded.prompt_on_stop is False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
uv run pytest tests/test_config.py::test_prompt_on_stop_default_true tests/test_config.py::test_prompt_on_stop_false_from_toml tests/test_config.py::test_save_round_trips_prompt_on_stop -v
```
Expected: FAIL — `Config` has no `prompt_on_stop` field.

- [ ] **Step 3: Update `transcribeer/config.py`**

Replace the entire file with:

```python
from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path


def _config_path() -> Path:
    return Path.home() / ".transcribeer" / "config.toml"

_DEFAULTS = {
    "transcription": {
        "language": "auto",
        "diarization": "resemblyzer",
        "num_speakers": 0,
    },
    "summarization": {
        "backend": "ollama",
        "model": "llama3",
        "ollama_host": "http://localhost:11434",
        "prompt_on_stop": True,
    },
    "paths": {
        "sessions_dir": "~/.transcribeer/sessions",
    },
    "pipeline": {
        "mode": "record+transcribe+summarize",
    },
}

PIPELINE_MODES = [
    "record-only",
    "record+transcribe",
    "record+transcribe+summarize",
]


@dataclass
class Config:
    language: str
    diarization: str
    num_speakers: int | None
    llm_backend: str
    llm_model: str
    ollama_host: str
    sessions_dir: Path
    capture_bin: Path
    pipeline_mode: str = "record+transcribe+summarize"
    prompt_on_stop: bool = True


def load() -> Config:
    """Load ~/.transcribeer/config.toml. Missing keys use defaults. Never raises."""
    data: dict = {}
    cfg_path = _config_path()
    if cfg_path.exists():
        with open(cfg_path, "rb") as f:
            data = tomllib.load(f)

    def get(section: str, key: str):
        return data.get(section, {}).get(key, _DEFAULTS[section][key])

    raw_speakers = get("transcription", "num_speakers")
    num_speakers = None if raw_speakers == 0 else int(raw_speakers)

    return Config(
        language=get("transcription", "language"),
        diarization=get("transcription", "diarization"),
        num_speakers=num_speakers,
        llm_backend=get("summarization", "backend"),
        llm_model=get("summarization", "model"),
        ollama_host=get("summarization", "ollama_host"),
        sessions_dir=Path(get("paths", "sessions_dir")).expanduser(),
        capture_bin=Path(get("paths", "capture_bin")).expanduser(),
        pipeline_mode=get("pipeline", "mode"),
        prompt_on_stop=bool(get("summarization", "prompt_on_stop")),
    )


def save(cfg: Config) -> None:
    """Write cfg back to ~/.transcribeer/config.toml (creates dirs as needed)."""
    cfg_path = _config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    raw_speakers = 0 if cfg.num_speakers is None else cfg.num_speakers

    lines: list[str] = []

    lines += [
        "[pipeline]",
        f'mode = "{cfg.pipeline_mode}"',
        "",
        "[transcription]",
        f'language = "{cfg.language}"',
        f'diarization = "{cfg.diarization}"',
        f"num_speakers = {raw_speakers}",
        "",
        "[summarization]",
        f'backend = "{cfg.llm_backend}"',
        f'model = "{cfg.llm_model}"',
        f'ollama_host = "{cfg.ollama_host}"',
        f"prompt_on_stop = {'true' if cfg.prompt_on_stop else 'false'}",
        "",
        "[paths]",
        f'sessions_dir = "{cfg.sessions_dir}"',
        f'capture_bin = "{cfg.capture_bin}"',
        "",
    ]

    cfg_path.write_text("\n".join(lines), encoding="utf-8")
```

- [ ] **Step 4: Run the full config test suite**

```bash
uv run pytest tests/test_config.py -v
```
Expected: all tests PASS (including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add transcribeer/config.py tests/test_config.py
git commit -m "feat: add prompt_on_stop config field"
```

---

## Task 4: Settings — expose `prompt_on_stop` toggle

**Files:**
- Modify: `transcribeer/settings_window.py`
- Modify: `transcribeer/ui/settings.html`

- [ ] **Step 1: Update `settings_window.py`**

In `on_load`, add `"prompt_on_stop": cfg.prompt_on_stop` to the sent dict:

```python
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
```

In `_save_field`, add `prompt_on_stop` to kwargs and handle its boolean conversion. Replace the method body:

```python
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
```

- [ ] **Step 2: Update `transcribeer/ui/settings.html`**

In the Summarization panel (`<div id="panel-summarization" ...>`), add the toggle after the API key row and before the closing `</div>`:

```html
  <label class="toggle-row" onclick="onPromptOnStopChange()">
    <div class="label-group">
      <div class="title">Ask for prompt on stop</div>
      <div class="subtitle">Show profile picker when you stop a recording</div>
    </div>
    <div class="toggle"><input id="chk-prompt-on-stop" type="checkbox"><span class="toggle-track"></span></div>
  </label>
```

In the `window.receive` `init` handler, add after `updateBackendUI()`:

```js
document.getElementById("chk-prompt-on-stop").checked = !!c.prompt_on_stop;
```

Add the JS handler function (before the closing `</script>`):

```js
function onPromptOnStopChange() {
  setTimeout(() => {
    const checked = document.getElementById("chk-prompt-on-stop").checked;
    save("prompt_on_stop", checked ? "true" : "false");
  }, 0);
}
```

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
uv run pytest -v
```
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add transcribeer/settings_window.py transcribeer/ui/settings.html
git commit -m "feat: add prompt_on_stop toggle to settings window"
```

---

## Task 5: CLI — `--profile` and `--prompt-file` flags

**Files:**
- Modify: `transcribeer/cli.py`

- [ ] **Step 1: Update the `summarize` command**

Replace the `summarize` function signature and body:

```python
@app.command()
def summarize(
    transcript: Path = typer.Argument(..., help="Transcript .txt file."),
    out: Optional[Path] = typer.Option(None, "--out", "-o", help="Output .md path."),
    backend: Optional[str] = typer.Option(None, "--backend", help="LLM backend: openai, anthropic, ollama."),
    profile: Optional[str] = typer.Option(None, "--profile", help="Named prompt profile from ~/.transcribeer/prompts/."),
    prompt_file: Optional[Path] = typer.Option(None, "--prompt-file", help="One-off prompt file (overrides --profile)."),
):
    """Summarize a transcript using an LLM."""
    from transcribeer import summarize as sm
    from transcribeer.prompts import load_prompt
    cfg = _cfg()

    llm_backend = backend or cfg.llm_backend
    out_path = out or transcript.with_suffix(".summary.md")

    if prompt_file:
        prompt = prompt_file.read_text(encoding="utf-8")
    else:
        prompt = load_prompt(profile)

    console.print(f"[bold]Summarizing:[/bold] {transcript}")
    console.print(f"  Backend: {llm_backend} / {cfg.llm_model}")
    if profile or prompt_file:
        label = prompt_file or profile
        console.print(f"  Prompt: {label}")

    text = transcript.read_text(encoding="utf-8")
    try:
        with console.status("[cyan]Summarizing...[/cyan]"):
            summary = sm.run(
                transcript=text,
                backend=llm_backend,
                model=cfg.llm_model,
                ollama_host=cfg.ollama_host,
                prompt=prompt,
            )
    except ValueError as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1)

    out_path.write_text(summary, encoding="utf-8")
    console.print(f"[green]Summary:[/green] {out_path}")
```

- [ ] **Step 2: Update the `run` command**

Add `profile` parameter and pass it through to summarization. Replace the `run` function signature:

```python
@app.command()
def run(
    duration: Optional[int] = typer.Option(None, "--duration", "-d", help="Recording duration in seconds."),
    lang: Optional[str] = typer.Option(None, "--lang"),
    no_diarize: bool = typer.Option(False, "--no-diarize"),
    no_summarize: bool = typer.Option(False, "--no-summarize"),
    profile: Optional[str] = typer.Option(None, "--profile", help="Named prompt profile from ~/.transcribeer/prompts/."),
):
    """Record → transcribe → summarize in one shot."""
    from transcribeer import capture, transcribe as tx, summarize as sm, session
    from transcribeer.prompts import load_prompt
    cfg = _cfg()
```

In the same function, replace the `sm.run(...)` call in Step 3 with:

```python
    # 3. Summarize
    console.print("\n[bold cyan]Step 3/3 — Summarizing[/bold cyan]")
    text = transcript_path.read_text(encoding="utf-8")
    prompt = load_prompt(profile)
    try:
        with console.status("[cyan]Summarizing...[/cyan]"):
            summary = sm.run(
                transcript=text,
                backend=cfg.llm_backend,
                model=cfg.llm_model,
                ollama_host=cfg.ollama_host,
                prompt=prompt,
            )
    except ValueError as e:
        console.print(f"[yellow]Summarization skipped:[/yellow] {e}")
    else:
        summary_path.write_text(summary, encoding="utf-8")
        console.print(f"  [green]Summary:[/green] {summary_path}")
```

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
uv run pytest -v
```
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add transcribeer/cli.py
git commit -m "feat: add --profile and --prompt-file flags to CLI"
```

---

## Task 6: GUI — per-session profile state and menu item

**Files:**
- Modify: `transcribeer/gui.py`

- [ ] **Step 1: Add `_prompt_profile` state and menu item to `__init__`**

In `TranscribeerApp.__init__`, after `self._history_window = None`:

```python
        self._prompt_profile: str | None = None  # None = default
```

After `self._rename_item = ...`:

```python
        self._prompt_item = rumps.MenuItem("Prompt: Default", callback=self._on_set_prompt)
```

In `self.menu = [...]`, add `self._prompt_item` after `self._rename_item`:

```python
        self.menu = [
            self._status_item,
            self._open_item,
            self._rename_item,
            self._prompt_item,
            self._stop_item,
            None,
            self._start_item,
            None,
            self._history_item,
            self._settings_item,
        ]
```

- [ ] **Step 2: Add `_on_set_prompt` and `_pick_profile` methods**

Add after `_on_rename`:

```python
    def _on_set_prompt(self, _=None):
        from transcribeer.prompts import list_profiles
        self._pick_profile(list_profiles())

    def _pick_profile(self, profiles: list[str]) -> None:
        names = ", ".join(profiles)
        current = self._prompt_profile or "default"
        win = rumps.Window(
            message=f"Available profiles: {names}",
            title="Summarization Profile",
            default_text=current,
            ok="Use",
            cancel="Default",
            dimensions=(280, 24),
        )
        resp = win.run()
        if resp.clicked and resp.text.strip() in profiles:
            chosen = resp.text.strip()
            self._prompt_profile = None if chosen == "default" else chosen
        else:
            self._prompt_profile = None
        self._update_prompt_label()

    def _update_prompt_label(self) -> None:
        label = self._prompt_profile or "Default"
        self._prompt_item.title = f"Prompt: {label}"
```

- [ ] **Step 3: Reset profile on new session and show/hide the menu item**

In `_on_start`, reset the profile before starting the thread:

```python
    def _on_start(self, _=None):
        from transcribeer import session
        _cancel_zoom_notification()
        self._prompt_profile = None          # reset per-session
        self._stop_event.clear()
        sess = session.new_session(self.cfg.sessions_dir)
        self._sess = sess
        self._thread = threading.Thread(target=self._run, args=(sess,), daemon=True)
        self._thread.start()
```

Update `_set_recording` to show the prompt item:

```python
    def _set_recording(self):
        self._record_start = time.time()
        self.title = "⏺"
        self._status_item.title = "⏺ Recording  00:00"
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._rename_item.title = "✏️ Rename Session…"
        self._rename_item.hidden = False
        self._prompt_item.title = "Prompt: Default"
        self._prompt_item.hidden = False
        self._stop_item.hidden = False
        self._stop_item.set_callback(self._on_stop)
        self._start_item.hidden = True
```

Update `_set_status` to keep prompt item visible during transcription/summarization:

```python
    def _set_status(self, label: str):
        self.title = label.split()[0]
        self._status_item.title = label
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._rename_item.hidden = True
        self._prompt_item.hidden = False
        self._stop_item.hidden = True
        self._start_item.hidden = True
```

Update `_set_idle` to hide the prompt item:

```python
    def _set_idle(self):
        self.title = "🎙"
        self._status_item.hidden = True
        self._open_item.hidden = True
        self._rename_item.hidden = True
        self._prompt_item.hidden = True
        self._stop_item.hidden = True
        self._start_item.hidden = False
```

Update `_set_done` to hide the prompt item:

```python
    def _set_done(self, summary_err: str | None = None, warn: str | None = None):
        from transcribeer.meta import get_display_name
        self.title = "✓"
        display = get_display_name(self._sess) if self._sess else ""
        self._prompt_item.hidden = True
        if summary_err:
            self._status_item.title = "✓ Done  (summary failed)"
            rumps.notification(
                "Transcribee", f"Done — {display}", summary_err, sound=False
            )
        elif warn:
            self._status_item.title = "✓ Done  (warning)"
            rumps.notification("Transcribee", f"Done — {display}", warn, sound=False)
        else:
            self._status_item.title = "✓ Done"
            rumps.notification("Transcribee", "Done", display, sound=False)
        self._status_item.hidden = False
        self._open_item.hidden = False
        self._stop_item.hidden = True
        self._start_item.hidden = False
```

Update `_set_error` to hide the prompt item:

```python
    def _set_error(self, msg: str):
        self.title = "⚠"
        self._status_item.title = "⚠ Error"
        self._status_item.hidden = False
        self._open_item.hidden = self._sess is None
        self._rename_item.hidden = True
        self._prompt_item.hidden = True
        self._stop_item.hidden = True
        self._start_item.hidden = False
        AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(
            lambda: rumps.alert(title="Transcribeer Error", message=msg)
        )
```

- [ ] **Step 4: Show picker on stop if `prompt_on_stop` is set**

Update `_on_stop` to show the picker after signaling the capture process:

```python
    def _on_stop(self, _=None):
        self._stop_event.set()
        proc = self._capture_proc
        if proc:
            proc.send_signal(signal.SIGINT)
        self._stop_item.set_callback(None)
        if self.cfg.prompt_on_stop:
            from transcribeer.prompts import list_profiles
            profiles = list_profiles()
            if len(profiles) > 1:   # custom profiles exist beyond "default"
                self._pick_profile(profiles)
```

- [ ] **Step 5: Pass profile into the summarization step in `_run`**

In `_run`, replace the `sm.run(...)` call in the summarize section:

```python
        # 3. Summarize
        self._set_status("🤔 Summarizing…")
        log(f"summarization started backend={cfg.llm_backend} model={cfg.llm_model} profile={self._prompt_profile!r}")
        from transcribeer.prompts import load_prompt
        prompt = load_prompt(self._prompt_profile)
        summary_err: str | None = None
        try:
            summary = sm.run(
                transcript=transcript_path.read_text(encoding="utf-8"),
                backend=cfg.llm_backend,
                model=cfg.llm_model,
                ollama_host=cfg.ollama_host,
                prompt=prompt,
            )
            summary_path.write_text(summary, encoding="utf-8")
            log("summarization done")
        except Exception as e:
            summary_err = str(e)
            log(f"summarization failed: {e}")
```

- [ ] **Step 6: Run the full test suite to confirm no regressions**

```bash
uv run pytest -v
```
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add transcribeer/gui.py
git commit -m "feat: add per-session prompt profile to menubar GUI"
```

---

## Task 7: History window — profile selector

**Files:**
- Modify: `transcribeer/history_window.py`
- Modify: `transcribeer/ui/history.html`

- [ ] **Step 1: Update `history_window.py`**

In `on_load`, include profiles in the `init` message:

```python
    def on_load(self):
        from transcribeer.prompts import list_profiles
        self._sessions = list_sessions(Path(self._cfg.sessions_dir))
        self.send("init", {
            "sessions": [_session_row(s) for s in self._sessions],
            "profiles": list_profiles(),
        })
```

In `handle_message`, update the `"summarize"` branch to pass the profile:

```python
        elif action == "summarize" and sess:
            profile = payload.get("profile") or None
            threading.Thread(
                target=self._run_summarize, args=(sess, profile), daemon=True
            ).start()
```

Update `_run_summarize` to accept and use the profile:

```python
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
```

- [ ] **Step 2: Update `transcribeer/ui/history.html`**

Replace the `.bottom-bar` div with one that includes a profile select:

```html
    <div class="bottom-bar">
      <span id="status-label" class="status-label"></span>
      <button class="btn" onclick="onOpenDir()">Open in Finder</button>
      <button id="btn-transcribe" class="btn" onclick="onTranscribe()">Re-transcribe</button>
      <select id="sel-profile" class="btn" style="padding:3px 6px;font-size:11px;"></select>
      <button id="btn-summarize" class="btn" onclick="onSummarize()">Re-summarize</button>
    </div>
```

Replace the `onSummarize` function to include the selected profile:

```js
function onSummarize() {
  if (!_selected) return;
  document.getElementById("btn-summarize").disabled = true;
  document.getElementById("status-label").textContent = "Summarizing…";
  const profile = document.getElementById("sel-profile").value;
  bridge("summarize", {session: _selected, profile});
}
```

Add a `populateProfiles` function after `renderDetail`:

```js
function populateProfiles(profiles) {
  const sel = document.getElementById("sel-profile");
  sel.innerHTML = (profiles || ["default"])
    .map(p => `<option value="${escHtml(p)}">${escHtml(p)}</option>`)
    .join("");
}
```

Update the `window.receive` `init` handler to call `populateProfiles`:

```js
  if (action === "init") {
    populateProfiles(payload.profiles || ["default"]);
    renderList(payload.sessions || []);
    if (payload.sessions && payload.sessions.length) {
      const first = payload.sessions[0];
      _selected = first.path;
      renderList(payload.sessions);
      bridge("select", {session: first.path});
    }
  }
```

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
uv run pytest -v
```
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add transcribeer/history_window.py transcribeer/ui/history.html
git commit -m "feat: add profile selector to history window re-summarize"
```

---

## Self-Review Checklist

- [x] **spec: `prompts.py`** → Task 1
- [x] **spec: `summarize.run()` prompt param** → Task 2
- [x] **spec: `config.prompt_on_stop`** → Task 3
- [x] **spec: settings toggle** → Task 4
- [x] **spec: CLI `--profile` / `--prompt-file`** → Task 5
- [x] **spec: GUI menu item + on-stop picker + `_prompt_profile` state** → Task 6
- [x] **spec: history window profile select** → Task 7
- [x] No TBDs or placeholder steps
- [x] Type/method names are consistent across tasks (`load_prompt`, `list_profiles`, `prompt`, `_prompt_profile`, `_pick_profile`, `_update_prompt_label`)
- [x] All `sm.run()` call sites updated: `gui.py` Task 6 step 5, `history_window.py` Task 7 step 1, `cli.py` Task 5
