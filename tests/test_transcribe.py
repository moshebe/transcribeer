from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch, MagicMock
import shutil
import tempfile
import pytest


# 44-byte WAV header + 2 bytes of data so the empty-audio check passes
_MIN_WAV = (
    b"RIFF\x2e\x00\x00\x00WAVEfmt \x10\x00\x00\x00"
    b"\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00"
    b"\x02\x00\x10\x00data\x02\x00\x00\x00\x00\x00"
)


def _make_mock_model(text: str = "shalom", duration: float = 1.0):
    mock_seg = MagicMock()
    mock_seg.start = 0.0
    mock_seg.end = 1.0
    mock_seg.text = text
    mock_info = MagicMock()
    mock_info.duration = duration
    mock_model = MagicMock()
    mock_model.transcribe.return_value = ([mock_seg], mock_info)
    return mock_model


def test_assign_speakers_overlap():
    """Whisper segment overlapping a diarization segment gets that speaker."""
    from transcribeer.transcribe import assign_speakers
    whisper = [(0.0, 2.0, "hello world")]
    diarization = [(0.0, 3.0, "SPEAKER_00")]
    result = assign_speakers(whisper, diarization)
    assert result == [(0.0, 2.0, "SPEAKER_00", "hello world")]


def test_assign_speakers_no_diarization():
    """Empty diarization → all segments labeled UNKNOWN."""
    from transcribeer.transcribe import assign_speakers
    whisper = [(0.0, 2.0, "hello")]
    result = assign_speakers(whisper, [])
    assert result[0][2] == "UNKNOWN"


def test_assign_speakers_midpoint_fallback():
    """Uses midpoint when no overlap found."""
    from transcribeer.transcribe import assign_speakers
    whisper = [(0.0, 1.0, "hi")]
    diarization = [(0.4, 0.8, "SPEAKER_01")]
    result = assign_speakers(whisper, diarization)
    assert result[0][2] == "SPEAKER_01"


def test_format_output_merges_consecutive_same_speaker():
    """Consecutive segments from same speaker are merged."""
    from transcribeer.transcribe import format_output
    labeled = [
        (0.0, 1.0, "SPEAKER_00", "hello"),
        (1.0, 2.0, "SPEAKER_00", "world"),
        (2.0, 3.0, "SPEAKER_01", "hi"),
    ]
    output = format_output(labeled)
    lines = output.strip().split("\n")
    assert len(lines) == 2
    assert "Speaker 1" in lines[0]
    assert "hello world" in lines[0]
    assert "Speaker 2" in lines[1]


def test_format_output_empty():
    from transcribeer.transcribe import format_output
    assert format_output([]) == ""


def test_format_timestamp():
    from transcribeer.transcribe import format_timestamp
    assert format_timestamp(65.0) == "01:05"
    assert format_timestamp(0.0) == "00:00"


def test_language_auto_maps_to_none():
    """'auto' language → None passed to faster-whisper model.transcribe."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "audio.wav"
    wav.write_bytes(_MIN_WAV)

    mock_model = _make_mock_model()

    with patch("transcribeer.transcribe._load_whisper_model", return_value=mock_model), \
         patch("transcribeer.transcribe._has_audible_signal", return_value=True), \
         patch("transcribeer.diarize.run", return_value=[]), \
         patch("transcribeer.transcribe.ensure_wav", return_value=wav):

        from transcribeer.transcribe import run
        run(wav, language="auto", diarize_backend="none", num_speakers=None, out_path=tmp / "out.txt")

    call_kwargs = mock_model.transcribe.call_args
    # language=None should have been passed (not "auto")
    passed_lang = call_kwargs.kwargs.get("language") if call_kwargs.kwargs else call_kwargs[1].get("language")
    assert passed_lang is None

    shutil.rmtree(tmp)


# -----------------------------------------------------------------------------
# CPU thread detection
# -----------------------------------------------------------------------------


def test_detect_cpu_threads_apple_silicon():
    """On arm64 macOS, returns performance-core count from sysctl."""
    from transcribeer.transcribe import detect_cpu_threads

    def fake_run(cmd, *a, **kw):
        assert cmd[:3] == ["sysctl", "-n", "hw.perflevel0.physicalcpu"]
        return CompletedProcess(cmd, 0, stdout="8\n", stderr="")

    with patch("transcribeer.transcribe.platform.system", return_value="Darwin"), \
         patch("transcribeer.transcribe.platform.machine", return_value="arm64"), \
         patch("transcribeer.transcribe.subprocess.run", side_effect=fake_run):
        assert detect_cpu_threads() == 8


def test_detect_cpu_threads_capped():
    """Auto-detect is capped to avoid ctranslate2 diminishing returns."""
    from transcribeer.transcribe import detect_cpu_threads

    def fake_run(cmd, *a, **kw):
        return CompletedProcess(cmd, 0, stdout="24\n", stderr="")

    with patch("transcribeer.transcribe.platform.system", return_value="Darwin"), \
         patch("transcribeer.transcribe.platform.machine", return_value="arm64"), \
         patch("transcribeer.transcribe.subprocess.run", side_effect=fake_run):
        assert detect_cpu_threads(cap=8) == 8
        assert detect_cpu_threads(cap=12) == 12


def test_detect_cpu_threads_intel_mac():
    """Intel macOS uses hw.physicalcpu, not perflevel0."""
    from transcribeer.transcribe import detect_cpu_threads

    def fake_run(cmd, *a, **kw):
        assert cmd[:3] == ["sysctl", "-n", "hw.physicalcpu"]
        return CompletedProcess(cmd, 0, stdout="4\n", stderr="")

    with patch("transcribeer.transcribe.platform.system", return_value="Darwin"), \
         patch("transcribeer.transcribe.platform.machine", return_value="x86_64"), \
         patch("transcribeer.transcribe.subprocess.run", side_effect=fake_run):
        assert detect_cpu_threads() == 4


def test_detect_cpu_threads_linux_fallback():
    """Non-macOS: falls back to os.cpu_count()."""
    from transcribeer.transcribe import detect_cpu_threads

    with patch("transcribeer.transcribe.platform.system", return_value="Linux"), \
         patch("transcribeer.transcribe.platform.machine", return_value="x86_64"), \
         patch("transcribeer.transcribe.os.cpu_count", return_value=16):
        assert detect_cpu_threads(cap=8) == 8


def test_detect_cpu_threads_survives_sysctl_failure():
    """sysctl crashing / missing → still returns a sane value."""
    from transcribeer.transcribe import detect_cpu_threads

    def boom(*a, **kw):
        raise OSError("sysctl not found")

    with patch("transcribeer.transcribe.platform.system", return_value="Darwin"), \
         patch("transcribeer.transcribe.platform.machine", return_value="arm64"), \
         patch("transcribeer.transcribe.subprocess.run", side_effect=boom), \
         patch("transcribeer.transcribe.os.cpu_count", return_value=10):
        assert detect_cpu_threads(cap=8) == 8


# -----------------------------------------------------------------------------
# PerformanceConfig plumbing through run()
# -----------------------------------------------------------------------------


def test_run_applies_performance_defaults_vad_on():
    """Default PerformanceConfig has VAD on → kwargs include vad_filter=True."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "audio.wav"
    wav.write_bytes(_MIN_WAV)

    mock_model = _make_mock_model()

    with patch("transcribeer.transcribe._load_whisper_model", return_value=mock_model), \
         patch("transcribeer.transcribe._has_audible_signal", return_value=True), \
         patch("transcribeer.diarize.run", return_value=[]), \
         patch("transcribeer.transcribe.ensure_wav", return_value=wav):
        from transcribeer.transcribe import run
        run(wav, language="auto", diarize_backend="none",
            num_speakers=None, out_path=tmp / "out.txt")

    kwargs = mock_model.transcribe.call_args.kwargs
    assert kwargs["vad_filter"] is True
    assert "vad_parameters" in kwargs
    assert kwargs["beam_size"] == 5
    assert "batch_size" not in kwargs  # batched=False by default

    shutil.rmtree(tmp)


def test_run_respects_vad_off():
    """performance.vad_filter=False → no vad kwargs passed."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "audio.wav"
    wav.write_bytes(_MIN_WAV)

    mock_model = _make_mock_model()

    from transcribeer.config import PerformanceConfig
    perf = PerformanceConfig(vad_filter=False, beam_size=1)

    with patch("transcribeer.transcribe._load_whisper_model", return_value=mock_model), \
         patch("transcribeer.transcribe._has_audible_signal", return_value=True), \
         patch("transcribeer.diarize.run", return_value=[]), \
         patch("transcribeer.transcribe.ensure_wav", return_value=wav):
        from transcribeer.transcribe import run
        run(wav, language="auto", diarize_backend="none",
            num_speakers=None, out_path=tmp / "out.txt",
            performance=perf)

    kwargs = mock_model.transcribe.call_args.kwargs
    assert "vad_filter" not in kwargs
    assert "vad_parameters" not in kwargs
    assert kwargs["beam_size"] == 1

    shutil.rmtree(tmp)


def test_run_batched_uses_pipeline_wrapper():
    """performance.batched=True → BatchedInferencePipeline wraps the model."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "audio.wav"
    wav.write_bytes(_MIN_WAV)

    mock_model = _make_mock_model()
    mock_pipeline = _make_mock_model()
    mock_pipeline_cls = MagicMock(return_value=mock_pipeline)

    from transcribeer.config import PerformanceConfig
    perf = PerformanceConfig(batched=True, batch_size=4, vad_filter=False)

    with patch("transcribeer.transcribe._load_whisper_model", return_value=mock_model), \
         patch("transcribeer.transcribe._has_audible_signal", return_value=True), \
         patch("faster_whisper.BatchedInferencePipeline", mock_pipeline_cls), \
         patch("transcribeer.diarize.run", return_value=[]), \
         patch("transcribeer.transcribe.ensure_wav", return_value=wav):
        from transcribeer.transcribe import run
        run(wav, language="auto", diarize_backend="none",
            num_speakers=None, out_path=tmp / "out.txt",
            performance=perf)

    mock_pipeline_cls.assert_called_once_with(model=mock_model)
    kwargs = mock_pipeline.transcribe.call_args.kwargs
    assert kwargs["batch_size"] == 4
    # Plain model must NOT be called directly when batched
    mock_model.transcribe.assert_not_called()

    shutil.rmtree(tmp)


def test_load_whisper_model_passes_threads_and_compute_type():
    """_load_whisper_model plumbs performance.cpu_threads + compute_type into ctor."""
    from transcribeer.config import PerformanceConfig

    fake_ctor = MagicMock(return_value="model-instance")
    fake_module = MagicMock(WhisperModel=fake_ctor)

    perf = PerformanceConfig(cpu_threads=6, compute_type="int8_float32")

    with patch.dict("sys.modules", {"faster_whisper": fake_module}):
        from transcribeer.transcribe import _load_whisper_model
        result = _load_whisper_model(perf)

    assert result == "model-instance"
    kwargs = fake_ctor.call_args.kwargs
    assert kwargs["cpu_threads"] == 6
    assert kwargs["compute_type"] == "int8_float32"
    assert kwargs["device"] == "cpu"


def test_load_whisper_model_auto_threads_uses_detector():
    """cpu_threads=0 in config → detect_cpu_threads() result is used."""
    from transcribeer.config import PerformanceConfig

    fake_ctor = MagicMock(return_value="m")
    fake_module = MagicMock(WhisperModel=fake_ctor)

    perf = PerformanceConfig(cpu_threads=0)

    with patch.dict("sys.modules", {"faster_whisper": fake_module}), \
         patch("transcribeer.transcribe.detect_cpu_threads", return_value=7):
        from transcribeer.transcribe import _load_whisper_model
        _load_whisper_model(perf)

    assert fake_ctor.call_args.kwargs["cpu_threads"] == 7


# -----------------------------------------------------------------------------
# Silent-audio detection
# -----------------------------------------------------------------------------


def _write_wav(path: Path, samples, sample_rate: int = 16000) -> None:
    """Write a mono float32 numpy array as 16-bit PCM WAV."""
    import soundfile as sf
    sf.write(str(path), samples, sample_rate, subtype="PCM_16")


def test_has_audible_signal_detects_silent_file(tmp_path):
    """All-zero samples → False (silent)."""
    import numpy as np
    wav = tmp_path / "silent.wav"
    _write_wav(wav, np.zeros(16000 * 5, dtype="float32"))  # 5s of silence

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is False


def test_has_audible_signal_detects_real_audio(tmp_path):
    """Non-trivial amplitude → True."""
    import numpy as np
    wav = tmp_path / "speech.wav"
    # Sine wave at -10 dBFS — well above any silence threshold
    t = np.linspace(0, 5, 16000 * 5, endpoint=False, dtype="float32")
    samples = (0.3 * np.sin(2 * np.pi * 440 * t)).astype("float32")
    _write_wav(wav, samples)

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is True


def test_has_audible_signal_tolerates_quiet_speech(tmp_path):
    """Quiet-but-audible speech (~-40 dBFS) still returns True."""
    import numpy as np
    wav = tmp_path / "quiet.wav"
    t = np.linspace(0, 5, 16000 * 5, endpoint=False, dtype="float32")
    # 0.01 ≈ -40 dBFS — quieter than normal speech but clearly signal
    samples = (0.01 * np.sin(2 * np.pi * 220 * t)).astype("float32")
    _write_wav(wav, samples)

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is True


def test_has_audible_signal_accepts_whispered_speech(tmp_path):
    """Whispered speech (~-54 dBFS, peak 0.002) must pass the default threshold.

    This is the case the original 0.005 threshold false-positive-rejected.
    After lowering to 0.001, legitimate quiet audio survives while pure
    silence is still caught.
    """
    import numpy as np
    wav = tmp_path / "whisper.wav"
    t = np.linspace(0, 5, 16000 * 5, endpoint=False, dtype="float32")
    samples = (0.002 * np.sin(2 * np.pi * 220 * t)).astype("float32")
    _write_wav(wav, samples)

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is True


def test_has_audible_signal_rejects_dither_noise(tmp_path):
    """Dither-level noise (below 0.001 threshold) is still considered silent.

    PCM_16 quantisation dither sits around 1/32767 ≈ 3e-5 — well below 0.001.
    An all-quiet file at that level shouldn't pass as ``audible``.
    """
    import numpy as np
    wav = tmp_path / "dither.wav"
    # Deterministic peak = 5e-4 — well below the 1e-3 threshold
    t = np.linspace(0, 5, 16000 * 5, endpoint=False, dtype="float32")
    samples = (5e-4 * np.sin(2 * np.pi * 220 * t)).astype("float32")
    _write_wav(wav, samples)

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is False


def test_has_audible_signal_handles_empty_wav(tmp_path):
    """Zero-frame WAV returns False without raising."""
    import numpy as np
    wav = tmp_path / "empty.wav"
    _write_wav(wav, np.zeros(0, dtype="float32"))

    from transcribeer.transcribe import _has_audible_signal
    assert _has_audible_signal(wav) is False


def test_run_raises_on_silent_recording(tmp_path):
    """run() bails early with an actionable error on a silent WAV."""
    import numpy as np
    wav = tmp_path / "silent.wav"
    _write_wav(wav, np.zeros(16000 * 5, dtype="float32"))

    with patch("transcribeer.diarize.run", return_value=[]), \
         patch("transcribeer.transcribe.ensure_wav", return_value=wav):
        from transcribeer.transcribe import run
        with pytest.raises(ValueError, match="silent"):
            run(wav, language="auto", diarize_backend="none",
                num_speakers=None, out_path=tmp_path / "out.txt")
