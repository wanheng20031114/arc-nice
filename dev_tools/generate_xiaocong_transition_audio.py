#!/usr/bin/env python3
"""Generate the paired Xiaocong fate-room cover and reveal sounds."""

from __future__ import annotations

import math
from pathlib import Path
import random
import struct
import wave


SAMPLE_RATE = 44_100
OUTPUT_DIRECTORY = Path("resources/audio/ui")


def _smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def _write_wav(path: Path, samples: list[float]) -> None:
    peak = max(max(abs(sample) for sample in samples), 1e-6)
    pcm = bytearray()
    for sample in samples:
        normalized = max(-1.0, min(1.0, sample / peak))
        pcm.extend(struct.pack("<h", round(normalized * 23_000)))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def _filtered_noise(
    random_source: random.Random,
    duration: float,
    rising: bool,
) -> list[float]:
    sample_count = round(duration * SAMPLE_RATE)
    previous = 0.0
    result: list[float] = []
    for index in range(sample_count):
        progress = index / max(sample_count - 1, 1)
        sweep = progress if rising else 1.0 - progress
        smoothing = 0.025 + 0.16 * sweep
        white = random_source.uniform(-1.0, 1.0)
        previous += (white - previous) * smoothing
        result.append(previous)
    return result


def _cover_sound() -> list[float]:
    duration = 0.36
    noise = _filtered_noise(random.Random(0xC0A7), duration, False)
    samples: list[float] = []
    for index, air in enumerate(noise):
        time = index / SAMPLE_RATE
        progress = time / duration
        attack = _smoothstep(progress / 0.12)
        release = _smoothstep((1.0 - progress) / 0.28)
        envelope = attack * release
        frequency = 250.0 * math.pow(0.42, progress)
        phase = math.tau * frequency * time
        tone = math.sin(phase) * 0.34 + math.sin(phase * 0.5) * 0.16
        samples.append((tone + air * 0.72) * envelope)
    return samples


def _reveal_sound() -> list[float]:
    duration = 0.44
    noise = _filtered_noise(random.Random(0x51A0), duration, True)
    samples: list[float] = []
    phase = 0.0
    for index, air in enumerate(noise):
        time = index / SAMPLE_RATE
        progress = time / duration
        frequency = 145.0 + 430.0 * progress * progress
        phase += math.tau * frequency / SAMPLE_RATE
        sweep_envelope = (
            _smoothstep(progress / 0.09)
            * _smoothstep((1.0 - progress) / 0.22)
        )
        sweep = (math.sin(phase) * 0.30 + air * 0.62) * sweep_envelope

        chime_time = time - 0.13
        chime = 0.0
        if chime_time >= 0.0:
            chime_envelope = math.exp(-8.5 * chime_time)
            chime = (
                math.sin(math.tau * 740.0 * chime_time) * 0.24
                + math.sin(math.tau * 1110.0 * chime_time) * 0.10
            ) * chime_envelope
        samples.append(sweep + chime)
    return samples


def main() -> None:
    _write_wav(
        OUTPUT_DIRECTORY / "xiaocong_transition_cover.wav",
        _cover_sound(),
    )
    _write_wav(
        OUTPUT_DIRECTORY / "xiaocong_transition_reveal.wav",
        _reveal_sound(),
    )
    print("Generated Xiaocong fate-room transition audio.")


if __name__ == "__main__":
    main()
