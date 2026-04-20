from __future__ import annotations

import os
import platform
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from transcribeer.config import PerformanceConfig


# Upper bound for auto-detected thread count. Above ~8 threads ctranslate2 sees
# diminishing returns and can even slow down due to sync overhead.
_AUTO_THREADS_CAP = 8


def ensure_wav(audio_path: Path) -> Path:
    """Convert audio to 16kHz mono WAV if not already WAV. Idempotent."""
    if str(audio_path).lower().endswith(".wav"):
        return audio_path
    wav_path = audio_path.with_suffix(".wav")
    if wav_path.exists():
        print(f"Using existing WAV: {wav_path}")
        return wav_path
    subprocess.run(
        ["ffmpeg", "-i", str(audio_path), "-ar", "16000", "-ac", "1",
         "-c:a", "pcm_s16le", str(wav_path), "-y"],
        check=True,
        capture_output=True,
    )
    return wav_path


def detect_cpu_threads(cap: int = _AUTO_THREADS_CAP) -> int:
    """Return optimal CPU thread count for Whisper inference on this machine.

    On Apple Silicon, uses only the *performance* cores (E-cores hurt ML
    throughput because of thread-sync overhead vs. their slower compute).
    On Intel/other, uses the physical core count when available, otherwise
    logical cores. Result is capped at `cap` (default 8) because ctranslate2
    sees diminishing returns above that.
    """
    # Apple Silicon: prefer performance-core count via sysctl.
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        try:
            res = subprocess.run(
                ["sysctl", "-n", "hw.perflevel0.physicalcpu"],
                capture_output=True, text=True, timeout=1, check=False,
            )
            if res.returncode == 0 and res.stdout.strip().isdigit():
                p_cores = int(res.stdout.strip())
                if p_cores > 0:
                    return min(p_cores, cap)
        except (OSError, subprocess.SubprocessError):
            pass

    # Intel / Linux: try sysctl on macOS, /proc/cpuinfo on Linux, then fall back.
    physical: int | None = None
    if platform.system() == "Darwin":
        try:
            res = subprocess.run(
                ["sysctl", "-n", "hw.physicalcpu"],
                capture_output=True, text=True, timeout=1, check=False,
            )
            if res.returncode == 0 and res.stdout.strip().isdigit():
                physical = int(res.stdout.strip())
        except (OSError, subprocess.SubprocessError):
            pass

    if physical is None:
        physical = os.cpu_count() or 4

    return max(1, min(physical, cap))


def _load_whisper_model(performance: "PerformanceConfig | None" = None):
    import faster_whisper
    from transcribeer.config import PerformanceConfig

    perf = performance or PerformanceConfig()
    threads = perf.cpu_threads or detect_cpu_threads()

    return faster_whisper.WhisperModel(
        "ivrit-ai/whisper-large-v3-turbo-ct2",
        device="cpu",
        compute_type=perf.compute_type,
        cpu_threads=threads,
    )


def assign_speakers(
    whisper_segments: list[tuple[float, float, str]],
    diarization_segments: list[tuple[float, float, str]],
) -> list[tuple[float, float, str, str]]:
    """Assign a speaker label to each whisper segment based on overlap."""
    labeled = []
    for ws_start, ws_end, text in whisper_segments:
        ws_mid = (ws_start + ws_end) / 2
        best_speaker = "UNKNOWN"
        best_overlap = 0.0

        for d_start, d_end, speaker in diarization_segments:
            overlap = max(0.0, min(ws_end, d_end) - max(ws_start, d_start))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker
            if best_overlap == 0.0 and d_start <= ws_mid <= d_end:
                best_speaker = speaker

        labeled.append((ws_start, ws_end, best_speaker, text))
    return labeled


def format_timestamp(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    return f"{m:02d}:{s:02d}"


def format_output(labeled_segments: list[tuple[float, float, str, str]]) -> str:
    """Format labeled segments, merging consecutive same-speaker lines."""
    if not labeled_segments:
        return ""

    speaker_map: dict[str, str] = {}
    counter = 1
    for _, _, speaker, _ in labeled_segments:
        if speaker not in speaker_map and speaker != "UNKNOWN":
            speaker_map[speaker] = f"Speaker {counter}"
            counter += 1
    speaker_map["UNKNOWN"] = "???"

    merged: list[tuple[float, float, str, str]] = []
    for start, end, speaker, text in labeled_segments:
        friendly = speaker_map.get(speaker, speaker)
        if merged and merged[-1][2] == friendly:
            prev_start, _, prev_speaker, prev_text = merged[-1]
            merged[-1] = (prev_start, end, prev_speaker, prev_text + " " + text)
        else:
            merged.append((start, end, friendly, text))

    lines = []
    for start, end, speaker, text in merged:
        ts = f"[{format_timestamp(start)} -> {format_timestamp(end)}]"
        lines.append(f"{ts} {speaker}: {text}")
    return "\n".join(lines)


def run(
    audio_path: Path,
    language: str,
    diarize_backend: str,
    num_speakers: int | None,
    out_path: Path,
    on_progress: Callable[[str, float | None], None] | None = None,
    performance: "PerformanceConfig | None" = None,
) -> Path:
    """
    Full pipeline: ensure_wav → diarize → whisper → merge → write .txt.

    language: "he" | "en" | "auto"  ("auto" → None for faster-whisper auto-detect)
    on_progress: optional callback(step, fraction) where step is one of
        "diarizing" | "loading" | "transcribing" | "done" and fraction is
        0.0–1.0 during transcription, None otherwise.
    performance: optional PerformanceConfig to tune Whisper inference. When
        omitted, uses library defaults (auto-detected CPU threads, int8, VAD on,
        non-batched, beam_size=5). See config.PerformanceConfig for details.
    """
    from transcribeer import diarize
    from transcribeer.config import PerformanceConfig

    perf = performance or PerformanceConfig()

    def _prog(step: str, pct: float | None = None) -> None:
        if on_progress:
            on_progress(step, pct)

    wav_path = ensure_wav(audio_path)

    # WAV header alone is 44 bytes — anything smaller means no audio was captured.
    if wav_path.stat().st_size <= 44:
        raise ValueError(
            f"Recording produced no audio ({wav_path.stat().st_size} bytes). "
            "Check that 'Screen & System Audio Recording' is enabled in "
            "System Settings → Privacy & Security and that system audio is playing."
        )

    _prog("diarizing")
    diar_segments = diarize.run(wav_path, backend=diarize_backend, num_speakers=num_speakers)
    if not diar_segments and diarize_backend != "none":
        _prog("diarization_empty")

    _prog("loading")
    model = _load_whisper_model(perf)

    # Batched pipeline is ~2-4x faster but emits progress in coarser chunks.
    if perf.batched:
        from faster_whisper import BatchedInferencePipeline
        inference = BatchedInferencePipeline(model=model)
    else:
        inference = model

    transcribe_kwargs: dict = {
        "language": None if language == "auto" else language,
        "word_timestamps": True,
        "beam_size": perf.beam_size,
    }
    if perf.vad_filter:
        transcribe_kwargs["vad_filter"] = True
        transcribe_kwargs["vad_parameters"] = {"min_silence_duration_ms": 500}
    if perf.batched:
        transcribe_kwargs["batch_size"] = perf.batch_size

    segments_iter, info = inference.transcribe(str(audio_path), **transcribe_kwargs)

    _prog("transcribing", 0.0)
    whisper_segments = []
    for seg in segments_iter:
        whisper_segments.append((seg.start, seg.end, seg.text.strip()))
        if info.duration:
            _prog("transcribing", min(seg.end / info.duration, 1.0))

    labeled = assign_speakers(whisper_segments, diar_segments)
    output = format_output(labeled)

    out_path.write_text(output, encoding="utf-8")
    _prog("done")
    return out_path
