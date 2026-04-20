from __future__ import annotations

from pathlib import Path
from typing import Optional

import typer
from rich.console import Console

app = typer.Typer(
    name="transcribeer",
    help="Audio capture, transcription, and summarization.",
    add_completion=False,
)
console = Console()


def _cfg():
    from transcribeer.config import load
    return load()


@app.command()
def record(
    duration: Optional[int] = typer.Option(None, "--duration", "-d", help="Stop after N seconds. Omit for manual stop (Ctrl+C)."),
    out: Optional[Path] = typer.Option(None, "--out", "-o", help="Output WAV path. Defaults to new session dir."),
    pid_file: Optional[Path] = typer.Option(None, "--pid-file", help="Write PID here for external stop (e.g. GUI)."),
):
    """Capture system audio to a WAV file."""
    from transcribeer import capture, session
    cfg = _cfg()

    if out is None:
        sess = session.new_session(sessions_dir=cfg.sessions_dir)
        out = sess / "audio.wav"
    else:
        out = Path(out)

    console.print(f"[bold]Recording →[/bold] {out}")
    if duration:
        console.print(f"  Auto-stop after {duration}s. Press Ctrl+C to stop early.")
    else:
        console.print("  Press [bold]Ctrl+C[/bold] to stop.")

    try:
        capture.record(out_path=out, duration=duration, pid_file=pid_file, config=cfg)
    except KeyboardInterrupt:
        console.print("")  # newline after terminal's ^C
    except PermissionError as e:
        console.print(f"[red]Permission denied:[/red] {e}")
        raise typer.Exit(1)

    console.print(f"[green]Saved:[/green] {out}")


def _apply_perf_overrides(
    cfg_perf,
    *,
    threads: Optional[int],
    vad: Optional[bool],
    batched: Optional[bool],
    batch_size: Optional[int],
    beam_size: Optional[int],
    compute_type: Optional[str],
):
    """Return a PerformanceConfig with any non-None override applied over cfg_perf."""
    from dataclasses import replace
    updates: dict = {}
    if threads is not None:
        updates["cpu_threads"] = max(0, threads)
    if vad is not None:
        updates["vad_filter"] = vad
    if batched is not None:
        updates["batched"] = batched
    if batch_size is not None:
        updates["batch_size"] = max(1, batch_size)
    if beam_size is not None:
        updates["beam_size"] = max(1, beam_size)
    if compute_type is not None:
        from transcribeer.config import VALID_COMPUTE_TYPES
        if compute_type not in VALID_COMPUTE_TYPES:
            raise typer.BadParameter(
                f"Invalid --compute-type {compute_type!r}. "
                f"Choose from: {', '.join(VALID_COMPUTE_TYPES)}."
            )
        updates["compute_type"] = compute_type
    return replace(cfg_perf, **updates) if updates else cfg_perf


@app.command()
def transcribe(
    audio: Path = typer.Argument(..., help="WAV (or any audio) file to transcribe."),
    lang: Optional[str] = typer.Option(None, "--lang", help="Language: he, en, auto. Overrides config."),
    no_diarize: bool = typer.Option(False, "--no-diarize", help="Skip speaker diarization."),
    out: Optional[Path] = typer.Option(None, "--out", "-o", help="Output .txt path."),
    threads: Optional[int] = typer.Option(None, "--threads", min=0, help="CPU threads (0 = auto-detect)."),
    vad: Optional[bool] = typer.Option(None, "--vad/--no-vad", help="Skip silence for faster processing."),
    batched: Optional[bool] = typer.Option(None, "--batched/--no-batched", help="Use BatchedInferencePipeline (experimental, 2-4x faster)."),
    batch_size: Optional[int] = typer.Option(None, "--batch-size", min=1, help="Batch size when --batched."),
    beam_size: Optional[int] = typer.Option(None, "--beam-size", min=1, help="Beam search width (1 = fastest)."),
    compute_type: Optional[str] = typer.Option(None, "--compute-type", help="int8, int8_float32, or float32."),
):
    """Transcribe an audio file with speaker diarization."""
    from transcribeer import transcribe as tx
    cfg = _cfg()

    language = lang or cfg.language
    diarize_backend = "none" if no_diarize else cfg.diarization
    out_path = out or audio.with_suffix(".diarized.txt")
    perf = _apply_perf_overrides(
        cfg.performance,
        threads=threads, vad=vad, batched=batched,
        batch_size=batch_size, beam_size=beam_size, compute_type=compute_type,
    )

    console.print(f"[bold]Transcribing:[/bold] {audio}")
    console.print(f"  Language: {language}  |  Diarization: {diarize_backend}")
    _threads_label = perf.cpu_threads or f"auto ({tx.detect_cpu_threads()})"
    console.print(
        f"  Threads: {_threads_label}  |  Compute: {perf.compute_type}  |  "
        f"VAD: {'on' if perf.vad_filter else 'off'}  |  "
        f"Batched: {'on' if perf.batched else 'off'}  |  Beam: {perf.beam_size}"
    )

    with console.status("[cyan]Preparing...[/cyan]") as status:
        def _prog(step: str, pct: float | None = None) -> None:
            msgs = {"diarizing": "Diarizing speakers...", "loading": "Loading model..."}
            if step == "transcribing":
                pct_str = f" {pct:.0%}" if pct is not None else ""
                status.update(f"[cyan]Transcribing...{pct_str}[/cyan]")
            elif step in msgs:
                status.update(f"[cyan]{msgs[step]}[/cyan]")

        tx.run(
            audio_path=audio,
            language=language,
            diarize_backend=diarize_backend,
            num_speakers=cfg.num_speakers,
            out_path=out_path,
            on_progress=_prog,
            performance=perf,
        )
    console.print(f"[green]Transcript:[/green] {out_path}")


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
        label = str(prompt_file) if prompt_file else profile
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

    sess = session.new_session(sessions_dir=cfg.sessions_dir)
    audio_path = sess / "audio.wav"
    transcript_path = sess / "transcript.txt"
    summary_path = sess / "summary.md"

    console.print(f"[bold]Session:[/bold] {sess}")

    # 1. Record
    console.print("\n[bold cyan]Step 1/3 — Recording[/bold cyan]")
    if duration:
        console.print(f"  Auto-stop after {duration}s.")
    else:
        console.print("  Press [bold]Ctrl+C[/bold] to stop.")

    try:
        capture.record(out_path=audio_path, duration=duration, pid_file=None, config=cfg)
    except KeyboardInterrupt:
        console.print("")  # newline after terminal's ^C
        console.print("  [dim]Recording stopped.[/dim]")
    except PermissionError as e:
        console.print(f"[red]Permission denied:[/red] {e}")
        raise typer.Exit(1)

    # 2. Transcribe
    console.print("\n[bold cyan]Step 2/3 — Transcribing[/bold cyan]")
    language = lang or cfg.language
    diarize_backend = "none" if no_diarize else cfg.diarization
    with console.status("[cyan]Preparing...[/cyan]") as status:
        def _prog(step: str, pct: float | None = None) -> None:
            msgs = {"diarizing": "Diarizing speakers...", "loading": "Loading model..."}
            if step == "transcribing":
                pct_str = f" {pct:.0%}" if pct is not None else ""
                status.update(f"[cyan]Transcribing...{pct_str}[/cyan]")
            elif step in msgs:
                status.update(f"[cyan]{msgs[step]}[/cyan]")

        try:
            tx.run(
                audio_path=audio_path,
                language=language,
                diarize_backend=diarize_backend,
                num_speakers=cfg.num_speakers,
                out_path=transcript_path,
                on_progress=_prog,
                performance=cfg.performance,
            )
        except ValueError as e:
            console.print(f"[red]Transcription failed:[/red] {e}")
            raise typer.Exit(1)
    console.print(f"  [green]Transcript:[/green] {transcript_path}")

    if no_summarize:
        console.print(f"\n[bold green]Done.[/bold green] Session: {sess}")
        return

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

    console.print(f"\n[bold green]Done.[/bold green] Session: {sess}")


if __name__ == "__main__":
    app()
