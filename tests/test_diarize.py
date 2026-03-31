import sys
from pathlib import Path
from unittest.mock import MagicMock
import pytest


def test_none_backend_returns_empty_list(tmp_path):
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")
    from transcribee.diarize import run
    result = run(wav, backend="none")
    assert result == []


def test_unknown_backend_raises(tmp_path):
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")
    from transcribee.diarize import run
    with pytest.raises(ValueError, match="Unknown diarization backend"):
        run(wav, backend="invalid_backend")


def test_pyannote_backend_returns_tuples(tmp_path):
    """pyannote backend returns list of (float, float, str) tuples."""
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")

    mock_turn = MagicMock()
    mock_turn.start = 0.0
    mock_turn.end = 2.5

    mock_diarization = MagicMock()
    mock_diarization.itertracks.return_value = [(mock_turn, None, "SPEAKER_00")]

    mock_result = MagicMock()
    mock_result.speaker_diarization = mock_diarization

    mock_pipeline = MagicMock(return_value=mock_result)

    mock_waveform = MagicMock()
    mock_sample_rate = 16000

    from unittest.mock import patch
    with patch("transcribee.diarize._load_pyannote_pipeline", return_value=mock_pipeline), \
         patch("torchaudio.load", return_value=(mock_waveform, mock_sample_rate)):
        from transcribee.diarize import run
        result = run(wav, backend="pyannote")

    assert len(result) == 1
    start, end, speaker = result[0]
    assert start == 0.0
    assert end == 2.5
    assert isinstance(speaker, str)


def test_resemblyzer_backend_returns_tuples(tmp_path, monkeypatch):
    """resemblyzer backend returns list of (float, float, str) tuples."""
    import numpy as np

    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")

    mock_preprocessed = np.zeros(48000, dtype=np.float32)  # 3s at 16kHz — fits 1.5s windows
    mock_encoder = MagicMock()
    mock_encoder.embed_utterance.return_value = np.random.rand(256)
    mock_labels = np.array([0, 0, 1, 1])

    mock_resemblyzer = MagicMock()
    mock_resemblyzer.preprocess_wav.return_value = mock_preprocessed
    mock_resemblyzer.VoiceEncoder.return_value = mock_encoder

    mock_cluster = MagicMock()
    mock_cluster.fit_predict.return_value = mock_labels
    mock_sklearn_cluster = MagicMock()
    mock_sklearn_cluster.AgglomerativeClustering.return_value = mock_cluster

    monkeypatch.setitem(sys.modules, "resemblyzer", mock_resemblyzer)
    monkeypatch.setitem(sys.modules, "sklearn", MagicMock())
    monkeypatch.setitem(sys.modules, "sklearn.cluster", mock_sklearn_cluster)

    from transcribee.diarize import run
    result = run(wav, backend="resemblyzer", num_speakers=2)

    assert len(result) > 0
    for start, end, speaker in result:
        assert isinstance(start, float)
        assert isinstance(end, float)
        assert isinstance(speaker, str)
        assert speaker.startswith("SPEAKER_")
