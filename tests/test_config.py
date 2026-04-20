# tests/test_config.py
import os
import tempfile
from pathlib import Path
import pytest

def write_config(tmp_path: Path, content: str) -> Path:
    cfg = tmp_path / "config.toml"
    cfg.write_text(content)
    return cfg


def test_load_defaults(monkeypatch, tmp_path):
    """Missing config file → all defaults applied."""
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load, Config
    cfg = load()
    assert cfg.language == "auto"
    assert cfg.diarization == "resemblyzer"
    assert cfg.num_speakers is None  # 0 translated to None
    assert cfg.llm_backend == "ollama"
    assert cfg.llm_model == "llama3"
    assert cfg.ollama_host == "http://localhost:11434"


def test_load_custom_language(monkeypatch, tmp_path):
    """Explicit language value is loaded."""
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text('[transcription]\nlanguage = "he"\n')
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer import config as cfg_mod
    import importlib; importlib.reload(cfg_mod)
    from transcribeer.config import load
    cfg = load()
    assert cfg.language == "he"


def test_num_speakers_zero_becomes_none(monkeypatch, tmp_path):
    """num_speakers = 0 in TOML → None in Config."""
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text('[transcription]\nnum_speakers = 0\n')
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.num_speakers is None


def test_num_speakers_nonzero(monkeypatch, tmp_path):
    """num_speakers = 2 in TOML → 2 in Config."""
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text('[transcription]\nnum_speakers = 2\n')
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.num_speakers == 2


def test_paths_expanded(monkeypatch, tmp_path):
    """~ in path values is expanded."""
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert not str(cfg.sessions_dir).startswith("~")
    assert not str(cfg.capture_bin).startswith("~")


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
    from transcribeer.config import load, save, Config
    cfg = load()
    cfg_off = Config(
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


# -----------------------------------------------------------------------------
# PerformanceConfig
# -----------------------------------------------------------------------------


def test_performance_defaults(monkeypatch, tmp_path):
    """Missing [transcription.performance] section → safe defaults."""
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.performance.cpu_threads == 0  # 0 = auto
    assert cfg.performance.compute_type == "int8"
    assert cfg.performance.vad_filter is True
    assert cfg.performance.batched is False
    assert cfg.performance.batch_size == 8
    assert cfg.performance.beam_size == 5


def test_performance_loaded_from_toml(monkeypatch, tmp_path):
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text(
        "[transcription.performance]\n"
        "cpu_threads = 6\n"
        'compute_type = "int8_float32"\n'
        "vad_filter = false\n"
        "batched = true\n"
        "batch_size = 16\n"
        "beam_size = 1\n"
    )
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.performance.cpu_threads == 6
    assert cfg.performance.compute_type == "int8_float32"
    assert cfg.performance.vad_filter is False
    assert cfg.performance.batched is True
    assert cfg.performance.batch_size == 16
    assert cfg.performance.beam_size == 1


def test_performance_invalid_compute_type_falls_back(monkeypatch, tmp_path):
    """Unknown compute_type warns and falls back to int8."""
    import warnings
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text(
        '[transcription.performance]\ncompute_type = "nonsense"\n'
    )
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        cfg = load()
    assert cfg.performance.compute_type == "int8"
    assert any("compute_type" in str(w.message) for w in caught)


def test_performance_negative_values_clamped(monkeypatch, tmp_path):
    """Negative/zero batch/beam sizes are clamped to 1."""
    cfg_dir = tmp_path / ".transcribeer"
    cfg_dir.mkdir()
    (cfg_dir / "config.toml").write_text(
        "[transcription.performance]\n"
        "cpu_threads = -4\n"
        "batch_size = 0\n"
        "beam_size = -3\n"
    )
    monkeypatch.setenv("HOME", str(tmp_path))
    from transcribeer.config import load
    cfg = load()
    assert cfg.performance.cpu_threads == 0  # clamped to ≥ 0
    assert cfg.performance.batch_size == 1
    assert cfg.performance.beam_size == 1


def test_save_round_trips_performance(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    from dataclasses import replace
    from transcribeer.config import load, save, PerformanceConfig
    cfg = load()
    cfg2 = replace(
        cfg,
        performance=PerformanceConfig(
            cpu_threads=4,
            compute_type="float32",
            vad_filter=False,
            batched=True,
            batch_size=16,
            beam_size=2,
        ),
    )
    save(cfg2)
    reloaded = load()
    assert reloaded.performance.cpu_threads == 4
    assert reloaded.performance.compute_type == "float32"
    assert reloaded.performance.vad_filter is False
    assert reloaded.performance.batched is True
    assert reloaded.performance.batch_size == 16
    assert reloaded.performance.beam_size == 2
