from __future__ import annotations

import subprocess
from pathlib import Path

from transcribee.config import Config


def record(
    out_path: Path,
    duration: int | None,
    pid_file: Path | None,
    config: Config | None = None,
) -> Path:
    """
    Shell out to capture-bin using positional args: capture-bin <out_path> [duration].
    Blocks until recording ends (SIGINT or duration elapsed).
    Returns out_path.

    capture-bin CLI contract:
        capture-bin <output.wav> [duration_seconds]
    Exit codes:
        0 = success
        1 = error (distinguish permission denial by stderr text)

    Raises:
        PermissionError: exit 1 with 'Screen & System Audio Recording' in stderr
        FileNotFoundError: capture-bin not found
        RuntimeError: any other non-zero exit
    """
    if config is None:
        from transcribee.config import load
        config = load()

    cmd = [str(config.capture_bin), str(out_path)]
    if duration is not None:
        cmd.append(str(duration))

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise FileNotFoundError(
            f"capture-bin not found at {config.capture_bin}. Re-run install.sh."
        )

    if pid_file is not None:
        Path(pid_file).write_text(str(proc.pid))

    try:
        _, stderr = proc.communicate()
    except KeyboardInterrupt:
        proc.wait()
        raise

    if proc.returncode != 0:
        stderr_text = stderr.decode("utf-8", errors="replace")
        if "Screen & System Audio Recording" in stderr_text:
            raise PermissionError(
                'Grant "Screen & System Audio Recording" permission in '
                "System Settings → Privacy & Security, then re-run."
            )
        raise RuntimeError(
            f"capture-bin exited {proc.returncode}: {stderr_text}"
        )

    return out_path
