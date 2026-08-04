#!/usr/bin/env python3
"""Generate the deterministic rogue combat victory fanfare."""

from __future__ import annotations

import math
from pathlib import Path
import struct
import wave


SAMPLE_RATE = 44_100
DURATION_SECONDS = 1.65
PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = PROJECT_ROOT / "resources/audio/ui/rogue_combat_victory.wav"


def _smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def _tone(time: float, start: float, frequency: float, duration: float) -> float:
    local_time = time - start
    if local_time < 0.0 or local_time >= duration:
        return 0.0
    attack = _smoothstep(local_time / 0.018)
    release = math.exp(-4.8 * local_time / duration)
    phase = math.tau * frequency * local_time
    body = (
        math.sin(phase)
        + 0.38 * math.sin(phase * 2.0)
        + 0.16 * math.sin(phase * 3.0)
    )
    return body * attack * release


def _drum(time: float) -> float:
    if time >= 0.38:
        return 0.0
    progress = time / 0.38
    frequency = 76.0 * math.pow(0.48, progress)
    phase = math.tau * frequency * time
    body = math.sin(phase) + 0.34 * math.sin(phase * 0.5)
    impact = math.exp(-8.5 * time)
    return body * impact


def _final_chord(time: float) -> float:
    start = 0.78
    local_time = time - start
    if local_time < 0.0:
        return 0.0
    duration = DURATION_SECONDS - start
    attack = _smoothstep(local_time / 0.045)
    release = _smoothstep((duration - local_time) / 0.34)
    if release <= 0.0:
        return 0.0
    frequencies = (261.6256, 329.6276, 391.9954, 523.2511)
    chord = 0.0
    for index, frequency in enumerate(frequencies):
        phase = math.tau * frequency * local_time
        weight = (0.42, 0.32, 0.28, 0.16)[index]
        chord += weight * (
            math.sin(phase) + 0.12 * math.sin(phase * 2.0)
        )
    return chord * attack * release


def _build_samples() -> list[float]:
    note_starts = (0.08, 0.20, 0.32, 0.44)
    note_frequencies = (261.6256, 329.6276, 391.9954, 523.2511)
    sample_count = round(DURATION_SECONDS * SAMPLE_RATE)
    samples: list[float] = []
    for index in range(sample_count):
        time = index / SAMPLE_RATE
        sample = 0.34 * _drum(time)
        for start, frequency in zip(note_starts, note_frequencies, strict=True):
            sample += 0.18 * _tone(time, start, frequency, 0.46)
        sample += 0.28 * _final_chord(time)
        samples.append(sample)
    return samples


def _write_wav(path: Path, samples: list[float]) -> None:
    peak = max(max(abs(sample) for sample in samples), 1e-9)
    target_peak = 0.82
    pcm = bytearray()
    for sample in samples:
        normalized = max(-1.0, min(1.0, sample / peak * target_peak))
        pcm.extend(struct.pack("<h", round(normalized * 32_767)))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def main() -> None:
    _write_wav(OUTPUT_PATH, _build_samples())
    relative_path = OUTPUT_PATH.relative_to(PROJECT_ROOT)
    print(f"Generated {relative_path} ({DURATION_SECONDS:.2f}s mono PCM16).")


if __name__ == "__main__":
    main()
