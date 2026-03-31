from __future__ import annotations

from pathlib import Path


def _load_pyannote_pipeline():
    """Isolated import so the module loads without pyannote installed."""
    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained("ivrit-ai/pyannote-speaker-diarization-3.1")
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    return pipeline


def _run_pyannote(wav_path: Path, num_speakers: int | None) -> list[tuple[float, float, str]]:
    import torchaudio

    pipeline = _load_pyannote_pipeline()
    waveform, sample_rate = torchaudio.load(str(wav_path))
    kwargs = {}
    if num_speakers:
        kwargs["num_speakers"] = num_speakers

    result = pipeline({"waveform": waveform, "sample_rate": sample_rate}, **kwargs)

    # pyannote >= 3.3 wraps result in DiarizeOutput dataclass
    diarization = (
        result.speaker_diarization
        if hasattr(result, "speaker_diarization")
        else result
    )

    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append((float(turn.start), float(turn.end), speaker))
    return segments


def _run_resemblyzer(wav_path: Path, num_speakers: int | None) -> list[tuple[float, float, str]]:
    import numpy as np
    import resemblyzer
    from sklearn.cluster import AgglomerativeClustering

    wav = resemblyzer.preprocess_wav(str(wav_path))
    encoder = resemblyzer.VoiceEncoder()

    # Segment into 1.5s windows with 0.5s hop
    sr = 16000
    window = int(1.5 * sr)
    hop = int(0.5 * sr)

    embeddings = []
    timestamps = []
    for start_sample in range(0, len(wav) - window, hop):
        chunk = wav[start_sample : start_sample + window]
        emb = encoder.embed_utterance(chunk)
        embeddings.append(emb)
        timestamps.append(start_sample / sr)

    if not embeddings:
        import warnings
        warnings.warn(
            "Audio is shorter than the resemblyzer window (1.5s) — no speaker segments produced.",
            stacklevel=3,
        )
        return []

    if num_speakers is None:
        import warnings
        warnings.warn(
            "resemblyzer: num_speakers not set, defaulting to 2. "
            "Pass --num-speakers for accurate results with non-2-speaker recordings.",
            stacklevel=3,
        )
        n_clusters = 2
    else:
        n_clusters = num_speakers
    n_clusters = min(n_clusters, len(embeddings))

    labels = AgglomerativeClustering(n_clusters=n_clusters).fit_predict(embeddings)

    segments = []
    for i, (t_start, label) in enumerate(zip(timestamps, labels)):
        t_end = t_start + 1.5
        segments.append((float(t_start), float(t_end), f"SPEAKER_{int(label):02d}"))

    return segments


def run(
    wav_path: Path,
    backend: str,
    num_speakers: int | None = None,
) -> list[tuple[float, float, str]]:
    """
    Returns list of (start_sec, end_sec, speaker_label).

    backend: "pyannote" | "resemblyzer" | "none"
    "none" returns [] — caller treats all segments as UNKNOWN.
    """
    if backend == "none":
        return []
    if backend == "pyannote":
        return _run_pyannote(wav_path, num_speakers)
    if backend == "resemblyzer":
        return _run_resemblyzer(wav_path, num_speakers)
    raise ValueError(f"Unknown diarization backend: {backend!r}. Use 'pyannote', 'resemblyzer', or 'none'.")
