#!/usr/bin/env python3
"""Generate wave and announcement UI sounds."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import struct
import wave


SAMPLE_RATE = 44100


def _sine(freq: float, t: float) -> float:
    return math.sin(math.tau * freq * t)


def _smoothstep(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


# ---------------------------------------------------------------------------
#  登  –  deep, punchy racing-light activation tone
# ---------------------------------------------------------------------------

def _deng_tick() -> list[float]:
    """Low, authoritative 'DONG' – like a racing countdown light turning on."""
    duration = 0.22
    n = round(duration * SAMPLE_RATE)
    samples: list[float] = []

    for i in range(n):
        t = i / SAMPLE_RATE
        p = t / duration

        # Snappy attack, smooth exponential decay
        if t < 0.005:
            env = _smoothstep(t / 0.005)
        else:
            env = math.exp(-6.5 * (t - 0.005))
        # Final release
        if t > duration - 0.03:
            env *= _smoothstep((duration - t) / 0.03)

        # Fundamental: ~330 Hz (E4) – deep but clear
        f0 = 330.0
        # Slight pitch drop for weight
        f = f0 * (1.0 - 0.015 * p)

        tone = (
            _sine(f, t) * 0.60          # warm fundamental
            + _sine(f * 2.0, t) * 0.18  # octave body
            + _sine(f * 3.0, t) * 0.06  # soft 3rd harmonic
        )

        # Sub-bass impact at 110 Hz
        sub_env = math.exp(-14.0 * t)
        sub = _sine(110.0, t) * 0.28 * sub_env

        samples.append((tone + sub) * env)

    return samples


# ---------------------------------------------------------------------------
#  滴！ –  bright, high-pitched "GO!" chirp
# ---------------------------------------------------------------------------

def _di_go() -> list[float]:
    """High, bright chirp – the 'GO!' signal."""
    duration = 0.28
    n = round(duration * SAMPLE_RATE)
    samples: list[float] = []

    for i in range(n):
        t = i / SAMPLE_RATE

        # Quick attack, moderate sustain, smooth release
        if t < 0.004:
            env = _smoothstep(t / 0.004)
        else:
            env = math.exp(-4.0 * (t - 0.004))
        if t > duration - 0.04:
            env *= _smoothstep((duration - t) / 0.04)

        # Fundamental: ~880 Hz (A5) – bright and energetic
        f0 = 880.0
        # Tiny pitch rise for excitement
        f = f0 * (1.0 + 0.008 * (t / duration))

        tone = (
            _sine(f, t) * 0.50           # clear fundamental
            + _sine(f * 2.0, t) * 0.22   # strong octave shimmer
            + _sine(f * 3.0, t) * 0.08   # sparkle
        )

        # Sub presence at one octave below
        sub_env = math.exp(-10.0 * t)
        sub = _sine(f0 * 0.5, t) * 0.15 * sub_env

        samples.append((tone + sub) * env)

    return samples


# ---------------------------------------------------------------------------
#  咚  –  low, weighty day/phase announcement impact
# ---------------------------------------------------------------------------

def _announcement_dong() -> list[float]:
    """Centered low-mid impact with a short resonant tail."""
    duration = 0.62
    n = round(duration * SAMPLE_RATE)
    samples: list[float] = []

    for i in range(n):
        t = i / SAMPLE_RATE

        if t < 0.004:
            env = _smoothstep(t / 0.004)
        else:
            env = math.exp(-4.2 * (t - 0.004))
        if t > duration - 0.09:
            env *= _smoothstep((duration - t) / 0.09)

        # The small pitch fall adds weight without turning the cue into an
        # explosion. Its octave keeps the sound present on small speakers.
        f = 210.0 * (1.0 - 0.075 * _smoothstep(min(t / 0.24, 1.0)))
        body = (
            _sine(f, t) * 0.62
            + _sine(f * 2.0, t) * 0.20 * math.exp(-2.0 * t)
            + _sine(f * 3.03, t) * 0.07 * math.exp(-4.0 * t)
        )
        sub = _sine(98.0, t) * 0.32 * math.exp(-8.0 * t)
        strike = (
            _sine(620.0, t) + _sine(910.0, t) * 0.45
        ) * 0.09 * math.exp(-55.0 * t)
        samples.append((body + sub) * env + strike)

    return samples


# ---------------------------------------------------------------------------
#  Output
# ---------------------------------------------------------------------------

def _write_sound(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = max((abs(s) for s in samples), default=1.0)
    peak = max(peak, 1e-6)
    pcm = bytearray()
    for s in samples:
        clamped = max(-1.0, min(1.0, s / peak))
        pcm.extend(struct.pack("<h", round(clamped * 24000)))

    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(pcm)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory")
    args = parser.parse_args()

    output_directory = Path(args.output_directory)
    _write_sound(output_directory / "countdown_tick.wav", _deng_tick())
    _write_sound(output_directory / "wave_start.wav", _di_go())
    _write_sound(
        output_directory / "day_phase_announcement_dong.wav",
        _announcement_dong(),
    )
    print(f"Generated wave and announcement UI audio in {output_directory}")


if __name__ == "__main__":
    main()
