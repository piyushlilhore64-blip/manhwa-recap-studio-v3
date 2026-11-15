#!/usr/bin/env python3
"""
voice_preview.py — Generate a short voice preview sample.

edge-tts voice ids (e.g. en-US-AndrewNeural) use edge-tts.
Kokoro voice ids (e.g. am_michael, af_bella) use the local Kokoro-82M engine
in its isolated venv (pipeline/.venv-kokoro, see setup_kokoro.sh) — same
engine the pipeline uses when a job picks a Kokoro voice.

Used by the Next.js /api/voice-preview route (via pipeline-service) to let
users hear a narration voice before starting the pipeline.

Usage:
    python voice_preview.py --voice en-US-AndrewNeural --output /path/preview.mp3
    python voice_preview.py --voice am_michael --output /path/preview.mp3
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import tempfile
import time

SAMPLE_TEXT = (
    "Hello! I'll be narrating your manhwa recap video. "
    "This is a quick preview of how my voice sounds. "
    "Let's dive into the story!"
)

_HERE = os.path.dirname(os.path.abspath(__file__))
_KOKORO_RE = re.compile(r"^[abhijpef][fm]_[a-z][a-z_]*$")
_KOKORO_PY = os.path.join(_HERE, ".venv-kokoro", "bin", "python3")
_KOKORO_SCRIPT = os.path.join(_HERE, "kokoro_tts.py")
_KOKORO_MODELS = os.path.join(_HERE, "models", "kokoro")


async def _generate_edge(voice: str, text: str, output: str) -> None:
    import edge_tts
    communicate = edge_tts.Communicate(text, voice)
    await communicate.save(output)


def _generate_kokoro(voice: str, text: str, output: str) -> None:
    py = os.environ.get("RECAP_KOKORO_PYTHON") or _KOKORO_PY
    if not os.path.exists(py):
        raise RuntimeError("Kokoro venv not found (run pipeline/setup_kokoro.sh)")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
        wav = tf.name
    try:
        req = {"text": text, "voice": voice, "out_wav": wav,
               "model_dir": _KOKORO_MODELS, "sample_rate": 24000}
        p = subprocess.run([py, _KOKORO_SCRIPT], input=json.dumps(req), text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        payload = None
        for line in reversed((p.stdout or "").splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    payload = json.loads(line)
                    break
                except Exception:
                    pass
        if not payload or not payload.get("ok") or not os.path.exists(wav):
            raise RuntimeError((payload or {}).get("error") or (p.stderr or "")[-200:])
        # 24k mono wav -> mp3
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-b:a", "96k", output], check=True, timeout=30)
    finally:
        try:
            os.unlink(wav)
        except OSError:
            pass


def _generate_gtts(voice: str, text: str, output: str) -> None:
    """Lightweight fallback: approximate language from edge-tts voice id."""
    try:
        from gtts import gTTS
    except Exception as e:
        raise RuntimeError(f"gTTS unavailable: {e}")
    lang = "en"
    m = re.match(r"^([a-z]{2})-[A-Z]{2}-", voice)
    if m:
        lang = m.group(1)
    tts = gTTS(text=text, lang=lang)
    tts.save(output)


def _generate_ffmpeg_tone(output: str, duration: float = 4.0) -> None:
    """Last-resort fallback: generate a valid audible placeholder preview."""
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=24000:duration={duration}",
        "-af", "volume=0.15",
        "-b:a", "48k", output,
    ], check=True, timeout=30)


def _valid(path: str) -> bool:
    return os.path.exists(path) and os.path.getsize(path) > 100


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a voice preview MP3")
    parser.add_argument("--voice", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--text", default=SAMPLE_TEXT)
    args = parser.parse_args()

    errors = []
    # Primary engines with retries for transient edge-tts failures.
    for attempt in range(3):
        try:
            if os.path.exists(args.output):
                try:
                    os.remove(args.output)
                except OSError:
                    pass
            if _KOKORO_RE.match(args.voice):
                _generate_kokoro(args.voice, args.text, args.output)
            else:
                asyncio.run(_generate_edge(args.voice, args.text, args.output))
            if _valid(args.output):
                return 0
            errors.append("empty output")
        except Exception as e:
            errors.append(str(e))
        time.sleep(1.5 * (attempt + 1))

    # Fallbacks for non-kokoro voices (or if kokoro env missing)
    if not _KOKORO_RE.match(args.voice):
        try:
            _generate_gtts(args.voice, args.text, args.output)
            if _valid(args.output):
                return 0
        except Exception as e:
            errors.append(f"gtts:{e}")
    try:
        _generate_ffmpeg_tone(args.output)
        if _valid(args.output):
            print(f"WARNING: used tone fallback after errors: {' | '.join(errors[-3:])}", file=sys.stderr)
            return 0
    except Exception as e:
        errors.append(f"tone:{e}")

    print(f"ERROR: {' | '.join(errors[-5:])}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
