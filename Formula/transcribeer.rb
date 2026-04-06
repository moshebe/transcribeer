class Transcribeer < Formula
  desc "Local-first meeting transcription and summarization for macOS"
  homepage "https://github.com/moshebe/transcribeer"
  url "https://github.com/moshebe/transcribeer/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "a92258f5eb1dec3cf3fe2588f7d41378d1bdf69090065556f94c6b45006c72c0"
  license "MIT"

  depends_on "ffmpeg"
  depends_on macos: :ventura
  depends_on "python@3.11"

  def install
    python = Formula["python@3.11"].opt_bin/"python3.11"
    venv = libexec/"venv"

    # Create a virtualenv inside the Homebrew prefix (nothing goes in $HOME)
    system python, "-m", "venv", venv

    venv_pip = venv/"bin/pip"

    # Install the package with all runtime extras into the venv
    system venv_pip, "install", "--no-cache-dir",
      ".[gui,resemblyzer,openai,anthropic]"

    # Install capture-bin (pre-built arm64 Swift binary) into libexec
    (libexec/"bin").mkpath
    cp "capture-bin", libexec/"bin/capture-bin"
    chmod 0755, libexec/"bin/capture-bin"

    # Codesign so macOS allows execution without Gatekeeper prompts
    entitlements = buildpath/"capture/capture.entitlements.plist"
    if entitlements.exist?
      system "codesign", "--force", "--sign", "-",
             "--entitlements", entitlements,
             libexec/"bin/capture-bin"
    else
      system "codesign", "--force", "--sign", "-", libexec/"bin/capture-bin"
    end

    # Write wrapper scripts into bin/ so Homebrew tracks them and they appear on PATH
    capture_bin_path = libexec/"bin/capture-bin"

    (bin/"transcribeer").write <<~SH
      #!/bin/bash
      # Bootstrap config with Homebrew capture-bin path on first run
      CONFIG="$HOME/.transcribeer/config.toml"
      if [[ ! -f "$CONFIG" ]]; then
        mkdir -p "$HOME/.transcribeer/sessions"
        cat > "$CONFIG" <<TOML
      [transcription]
      language = "auto"
      diarization = "resemblyzer"
      num_speakers = 0

      [summarization]
      backend = "ollama"
      model = "llama3"
      ollama_host = "http://localhost:11434"

      [paths]
      sessions_dir = "~/.transcribeer/sessions"
      capture_bin = "#{capture_bin_path}"
      TOML
      fi
      exec "#{venv}/bin/transcribeer" "$@"
    SH

    (bin/"transcribeer-gui").write <<~SH
      #!/bin/bash
      exec "#{venv}/bin/transcribeer-gui" "$@"
    SH

    chmod 0755, bin/"transcribeer"
    chmod 0755, bin/"transcribeer-gui"
  end

  def caveats
    capture_bin_path = opt_libexec/"bin/capture-bin"
    <<~EOS
      Transcribeer has been installed.

      First run:
        transcribeer-gui       # launch the menubar app
        transcribeer --help    # CLI usage

      A default config will be created at ~/.transcribeer/config.toml on first run,
      pointing capture-bin to:
        #{capture_bin_path}

      To change LLM backend (Ollama/OpenAI/Anthropic) or diarization, edit:
        ~/.transcribeer/config.toml

      Note: The first transcription will download the Whisper model (~1.5 GB).
      This happens automatically on first use.

      To use as a launch-at-login service:
        brew services start moshebe/transcribeer/transcribeer

      Recording consent: You are responsible for complying with all applicable
      laws regarding recording of conversations in your jurisdiction.
    EOS
  end

  test do
    system bin/"transcribeer", "--help"
  end
end
