#!/usr/bin/env python3
"""Generate Tango's deterministic electro-mechanical combat sound set."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import random
import struct
import wave


SAMPLE_RATE = 44_100
PCM_PEAK = 23_000


def _smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def _envelope(time: float, duration: float, attack: float, release: float) -> float:
    return _smoothstep(time / attack) * _smoothstep((duration - time) / release)


def _write_wav(path: Path, samples: list[float]) -> None:
    peak = max(max((abs(sample) for sample in samples), default=0.0), 1e-6)
    pcm = bytearray()
    for sample in samples:
        normalized = max(-1.0, min(1.0, sample / peak))
        pcm.extend(struct.pack("<h", round(normalized * PCM_PEAK)))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def _charge_sound() -> list[float]:
    """A 2.4-second hum whose pitch and pulse density follow charge progress."""
    duration = 2.4
    sample_count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0x7A460)
    carrier_phase = 0.0
    sub_phase = 0.0
    filtered_noise = 0.0
    samples: list[float] = []
    for index in range(sample_count):
        time = index / SAMPLE_RATE
        progress = index / max(sample_count - 1, 1)
        eased_progress = progress * progress * (3.0 - 2.0 * progress)
        frequency = 96.0 + 330.0 * eased_progress
        carrier_phase += math.tau * frequency / SAMPLE_RATE
        sub_phase += math.tau * (frequency * 0.5) / SAMPLE_RATE

        pulse_rate = 4.0 + 12.0 * eased_progress
        pulse = 0.72 + 0.28 * (
            math.sin(math.tau * pulse_rate * time) * 0.5 + 0.5
        )
        carrier = (
            math.sin(carrier_phase) * 0.38
            + math.sin(carrier_phase * 2.01) * 0.12
            + math.sin(sub_phase) * 0.10
        ) * pulse

        white = random_source.uniform(-1.0, 1.0)
        filtered_noise += (white - filtered_noise) * (0.04 + progress * 0.08)
        electric_texture = (white - filtered_noise) * (0.015 + progress * 0.045)

        completion_time = time - 2.24
        completion_chime = 0.0
        if completion_time >= 0.0:
            completion_chime = (
                math.sin(math.tau * 920.0 * completion_time) * 0.16
                + math.sin(math.tau * 1380.0 * completion_time) * 0.07
            ) * math.exp(-18.0 * completion_time)

        envelope = _envelope(time, duration, 0.035, 0.06)
        samples.append(
            (carrier + electric_texture + completion_chime) * envelope
        )
    return samples


def _laser_fire_sound() -> list[float]:
    """One restrained electrical snap for a complete three-cannon volley."""
    duration = 0.18
    sample_count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0x1A53)
    phase = 0.0
    samples: list[float] = []
    for index in range(sample_count):
        time = index / SAMPLE_RATE
        progress = index / max(sample_count - 1, 1)
        frequency = 360.0 + 1280.0 * math.pow(1.0 - progress, 2.2)
        phase += math.tau * frequency / SAMPLE_RATE
        decay = math.exp(-15.0 * time)
        body = (
            math.sin(phase) * 0.52
            + math.sin(phase * 1.52) * 0.16
            + math.sin(phase * 0.5) * 0.10
        ) * decay
        click = random_source.uniform(-1.0, 1.0) * math.exp(-65.0 * time) * 0.28
        envelope = _envelope(time, duration, 0.0018, 0.022)
        samples.append((body + click) * envelope)
    return samples


def _unit_motion_sound(rising: bool) -> list[float]:
    """Short mirrored chirps for cannon convergence and return."""
    duration = 0.14 if rising else 0.18
    sample_count = round(duration * SAMPLE_RATE)
    phase = 0.0
    samples: list[float] = []
    for index in range(sample_count):
        time = index / SAMPLE_RATE
        progress = index / max(sample_count - 1, 1)
        sweep = progress if rising else 1.0 - progress
        frequency = 220.0 * math.pow(4.0, sweep)
        phase += math.tau * frequency / SAMPLE_RATE
        metallic = (
            math.sin(phase) * 0.48
            + math.sin(phase * 1.995) * 0.16
            + math.sin(phase * 3.01) * 0.05
        )
        envelope = _envelope(
            time,
            duration,
            0.006,
            0.026 if rising else 0.04,
        )
        samples.append(metallic * envelope)
    return samples


def _electric_surge_cast_sound() -> list[float]:
    """A compact bass pulse with a bright expanding electrical crown."""
    duration = 0.58
    sample_count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xE1EC7)
    low_phase = 0.0
    high_phase = 0.0
    filtered_noise = 0.0
    samples: list[float] = []
    for index in range(sample_count):
        time = index / SAMPLE_RATE
        progress = index / max(sample_count - 1, 1)
        low_frequency = 78.0 + 82.0 * _smoothstep(progress)
        high_frequency = 310.0 + 540.0 * _smoothstep(progress)
        low_phase += math.tau * low_frequency / SAMPLE_RATE
        high_phase += math.tau * high_frequency / SAMPLE_RATE

        impact = math.sin(low_phase) * math.exp(-8.0 * time) * 0.58
        crown_envelope = (
            _smoothstep(progress / 0.18)
            * _smoothstep((1.0 - progress) / 0.30)
        )
        crown = (
            math.sin(high_phase) * 0.28
            + math.sin(high_phase * 1.5) * 0.10
        ) * crown_envelope

        white = random_source.uniform(-1.0, 1.0)
        filtered_noise += (white - filtered_noise) * (0.03 + progress * 0.12)
        arc_noise = (white - filtered_noise) * crown_envelope * 0.16
        envelope = _envelope(time, duration, 0.004, 0.07)
        samples.append((impact + crown + arc_noise) * envelope)
    return samples


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "output_directory",
        nargs="?",
        default="resources/audio",
    )
    args = parser.parse_args()
    output_directory = Path(args.output_directory)

    sounds = {
        "tango_charge.wav": _charge_sound(),
        "tango_laser_fire.wav": _laser_fire_sound(),
        "tango_unit_converge.wav": _unit_motion_sound(True),
        "tango_unit_return.wav": _unit_motion_sound(False),
        "tango_electric_surge_cast.wav": _electric_surge_cast_sound(),
    }
    for file_name, samples in sounds.items():
        _write_wav(output_directory / file_name, samples)
    print(f"Generated {len(sounds)} Tango sounds in {output_directory}")


if __name__ == "__main__":
    main()
