import sys
import pytest
from unittest.mock import MagicMock


def test_openai_backend_returns_string(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    mock_response = MagicMock()
    mock_response.choices[0].message.content = "## Summary\nTest summary."
    mock_client = MagicMock()
    mock_client.chat.completions.create.return_value = mock_response

    mock_openai = MagicMock()
    mock_openai.OpenAI.return_value = mock_client
    monkeypatch.setitem(sys.modules, "openai", mock_openai)

    from transcribee.summarize import run
    result = run("Speaker 1: hello", backend="openai", model="gpt-4o-mini")

    assert "Summary" in result
    mock_client.chat.completions.create.assert_called_once()


def test_anthropic_backend_returns_string(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    mock_response = MagicMock()
    mock_response.content[0].text = "## Summary\nTest."
    mock_client = MagicMock()
    mock_client.messages.create.return_value = mock_response

    mock_anthropic = MagicMock()
    mock_anthropic.Anthropic.return_value = mock_client
    monkeypatch.setitem(sys.modules, "anthropic", mock_anthropic)

    from transcribee.summarize import run
    result = run("Speaker 1: hello", backend="anthropic", model="claude-3-5-haiku-20241022")

    assert isinstance(result, str)
    assert len(result) > 0


def test_ollama_backend_returns_string():
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": "## Summary\nOllama result."}}
    mock_resp.raise_for_status = MagicMock()

    from unittest.mock import patch
    with patch("requests.post", return_value=mock_resp):
        from transcribee.summarize import run
        result = run(
            "Speaker 1: hello",
            backend="ollama",
            model="llama3",
            ollama_host="http://localhost:11434",
        )

    assert "Summary" in result


def test_openai_missing_key_raises(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    from transcribee.summarize import run
    with pytest.raises(ValueError, match="OPENAI_API_KEY"):
        run("transcript", backend="openai", model="gpt-4o-mini")


def test_anthropic_missing_key_raises(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    from transcribee.summarize import run
    with pytest.raises(ValueError, match="ANTHROPIC_API_KEY"):
        run("transcript", backend="anthropic", model="claude-3-5-haiku-20241022")


def test_unknown_backend_raises():
    from transcribee.summarize import run
    with pytest.raises(ValueError, match="Unknown summarization backend"):
        run("transcript", backend="magic", model="x")


def test_prompt_contains_transcript():
    """The transcript text is passed to the LLM."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": "ok"}}
    mock_resp.raise_for_status = MagicMock()
    transcript = "Speaker 1: unique_marker_xyz"

    from unittest.mock import patch
    with patch("requests.post", return_value=mock_resp) as mock_post:
        from transcribee.summarize import run
        run(transcript, backend="ollama", model="llama3")

    call_body = mock_post.call_args.kwargs["json"]
    messages_str = str(call_body["messages"])
    assert "unique_marker_xyz" in messages_str
