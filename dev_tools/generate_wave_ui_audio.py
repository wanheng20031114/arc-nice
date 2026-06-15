#!/usr/bin/env python3
"""Generate deterministic retro UI sounds for wave countdowns."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import struct
import wave


SAMPLE_RATE = 44100


def _square_wave(frequency: float, time_seconds: float) -> float:
    return 1.0 if math.sin(math.tau * frequency * time_seconds) >= 0.0 else -1.0


def _write_sound(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = max(max(abs(sample) for sample in samples), 1.0)
    pcm = bytearray()
    for sample in samples:
        normalized = max(-1.0, min(1.0, sample / peak))
        pcm.extend(struct.pack("<h", round(normalized * 22000)))

    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def _tone(frequency: float, duration: float, volume: float = 1.0) -> list[float]:
    sample_count = round(duration * SAMPLE_RATE)
    samples: list[float] = []
    for sample_index in range(sample_count):
        time_seconds = sample_index / SAMPLE_RATE
        envelope = max(0.0, 1.0 - time_seconds / duration)
        samples.append(_square_wave(frequency, time_seconds) * envelope * volume)
    return samples


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory")
    args = parser.parse_args()

    output_directory = Path(args.output_directory)
    tick = _tone(880.0, 0.085)
    wave_start = (
        _tone(660.0, 0.075, 0.82)
        + [0.0] * round(0.018 * SAMPLE_RATE)
        + _tone(990.0, 0.13)
    )

    _write_sound(output_directory / "countdown_tick.wav", tick)
    _write_sound(output_directory / "wave_start.wav", wave_start)
    print(f"Generated wave UI audio in {output_directory}")


if __name__ == "__main__":
    main()

