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
    "transcription.performance": {
        "cpu_threads": 0,
        "compute_type": "int8",
        "vad_filter": True,
        "batched": False,
        "batch_size": 8,
        "beam_size": 5,
    },
    "summarization": {
        "backend": "ollama",
        "model": "llama3",
        "ollama_host": "http://localhost:11434",
        "prompt_on_stop": True,
    },
    "paths": {
        "sessions_dir": "~/.transcribeer/sessions",
        "capture_bin": "~/.transcribeer/bin/capture-bin",
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

VALID_COMPUTE_TYPES = ("int8", "int8_float32", "float32")


@dataclass
class PerformanceConfig:
    """Whisper inference tuning. Defaults chosen for speed on mainstream hardware.

    - cpu_threads: 0 = auto-detect at runtime (uses performance cores on Apple
      Silicon, physical cores on Intel/Linux, capped at 8). Set a specific
      value to pin thread count.
    - compute_type: "int8" (default, fastest on CPU, small quality loss),
      "int8_float32" (int8 weights, float32 ops — slightly better quality,
      slightly slower), or "float32" (unquantized, slowest on CPU).
    - vad_filter: skip silent sections — typically 1.5-3x speedup on
      conversational audio with pauses. Rarely affects transcript quality.
    - batched: use BatchedInferencePipeline for 2-4x speedup. Experimental —
      progress reporting is less granular and peak memory is higher.
    - batch_size: batches processed at once when batched=True.
    - beam_size: beam search width. Lower = faster but less accurate.
      faster-whisper default is 5; use 1 for maximum speed.
    """
    cpu_threads: int = 0
    compute_type: str = "int8"
    vad_filter: bool = True
    batched: bool = False
    batch_size: int = 8
    beam_size: int = 5


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
    performance: PerformanceConfig = field(default_factory=PerformanceConfig)


def _lookup(data: dict, section: str, key: str):
    """Read section.key from nested TOML dict, falling back to _DEFAULTS.

    `section` may be dotted (e.g. "transcription.performance") to reach a
    nested TOML table like `[transcription.performance]`.
    """
    node: object = data
    for part in section.split("."):
        if not isinstance(node, dict):
            node = {}
            break
        node = node.get(part, {})
    if isinstance(node, dict) and key in node:
        return node[key]
    return _DEFAULTS[section][key]


def load() -> Config:
    """Load ~/.transcribeer/config.toml. Missing keys use defaults. Never raises."""
    data: dict = {}
    cfg_path = _config_path()
    if cfg_path.exists():
        with open(cfg_path, "rb") as f:
            data = tomllib.load(f)

    def get(section: str, key: str):
        return _lookup(data, section, key)

    raw_speakers = get("transcription", "num_speakers")
    num_speakers = None if raw_speakers == 0 else int(raw_speakers)

    compute_type = str(get("transcription.performance", "compute_type"))
    if compute_type not in VALID_COMPUTE_TYPES:
        import warnings
        warnings.warn(
            f"Unknown compute_type {compute_type!r}; falling back to 'int8'. "
            f"Valid values: {VALID_COMPUTE_TYPES}.",
            stacklevel=2,
        )
        compute_type = "int8"

    performance = PerformanceConfig(
        cpu_threads=max(0, int(get("transcription.performance", "cpu_threads"))),
        compute_type=compute_type,
        vad_filter=bool(get("transcription.performance", "vad_filter")),
        batched=bool(get("transcription.performance", "batched")),
        batch_size=max(1, int(get("transcription.performance", "batch_size"))),
        beam_size=max(1, int(get("transcription.performance", "beam_size"))),
    )

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
        performance=performance,
    )


def save(cfg: Config) -> None:
    """Write cfg back to ~/.transcribeer/config.toml (creates dirs as needed)."""
    cfg_path = _config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    raw_speakers = 0 if cfg.num_speakers is None else cfg.num_speakers
    perf = cfg.performance

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
        "[transcription.performance]",
        f"cpu_threads = {perf.cpu_threads}",
        f'compute_type = "{perf.compute_type}"',
        f"vad_filter = {'true' if perf.vad_filter else 'false'}",
        f"batched = {'true' if perf.batched else 'false'}",
        f"batch_size = {perf.batch_size}",
        f"beam_size = {perf.beam_size}",
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
