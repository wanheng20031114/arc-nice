#!/usr/bin/env python3
"""Generate wave and announcement UI sounds."""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import random
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
    """Short indoor door-slam impact, not a pitched bell or gong."""
    duration = 0.48
    n = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xD00D)
    samples: list[float] = []

    impact_low_pass = 0.0
    panel_low_pass = 0.0
    panel_floor = 0.0
    edge_low_pass = 0.0
    edge_floor = 0.0
    pressure_phase = 0.0
    modal_specs = [
        (86.0, 0.12, 10.0, 0.045),
        (123.0, 0.22, 11.0, 0.034),
        (176.0, 0.40, 13.0, 0.026),
        (247.0, 0.36, 16.5, 0.019),
        (356.0, 0.25, 22.0, 0.013),
        (512.0, 0.17, 29.0, 0.009),
        (742.0, 0.08, 38.0, 0.006),
    ]
    modal_phases = [
        random_source.uniform(-math.pi, math.pi)
        for _ in modal_specs
    ]
    impact_alpha = 1.0 - math.exp(-math.tau * 4200.0 / SAMPLE_RATE)
    panel_alpha = 1.0 - math.exp(-math.tau * 1250.0 / SAMPLE_RATE)
    panel_floor_alpha = 1.0 - math.exp(-math.tau * 96.0 / SAMPLE_RATE)
    edge_alpha = 1.0 - math.exp(-math.tau * 3500.0 / SAMPLE_RATE)
    edge_floor_alpha = 1.0 - math.exp(-math.tau * 610.0 / SAMPLE_RATE)

    for i in range(n):
        t = i / SAMPLE_RATE
        white_noise = random_source.uniform(-1.0, 1.0)
        impact_low_pass += impact_alpha * (white_noise - impact_low_pass)
        panel_low_pass += panel_alpha * (white_noise - panel_low_pass)
        panel_floor += panel_floor_alpha * (white_noise - panel_floor)
        edge_low_pass += edge_alpha * (white_noise - edge_low_pass)
        edge_floor += edge_floor_alpha * (white_noise - edge_floor)

        attack = _smoothstep(min(t / 0.0014, 1.0))
        impact = impact_low_pass * attack * math.exp(-70.0 * t) * 1.30
        panel_noise = panel_low_pass - panel_floor
        panel = panel_noise * attack * math.exp(-15.0 * t) * 1.02

        # A door first hits its frame, then the latch/panel follows a few
        # milliseconds later. This second irregular contact removes the
        # synthetic single-note character of the previous cue.
        frame_time = t - 0.012
        frame_contact = 0.0
        if frame_time >= 0.0:
            frame_attack = _smoothstep(min(frame_time / 0.001, 1.0))
            frame_band = edge_low_pass - edge_floor
            frame_contact = (
                frame_band
                * frame_attack
                * math.exp(-82.0 * frame_time)
                * 0.86
            )

        pressure_frequency = 69.0 - 14.0 * _smoothstep(min(t / 0.12, 1.0))
        pressure_phase += math.tau * pressure_frequency / SAMPLE_RATE
        pressure = (
            math.sin(pressure_phase)
            * attack
            * math.exp(-18.0 * t)
            * 0.10
        )

        modes = 0.0
        for mode_index, (frequency, amplitude, decay, drop) in enumerate(modal_specs):
            modal_frequency = frequency * (
                1.0 - drop * _smoothstep(min(t / 0.19, 1.0))
            )
            modal_frequency += 0.9 * math.sin(
                math.tau * (11.0 + mode_index * 2.7) * t
                + mode_index * 0.71
            )
            modal_phases[mode_index] += math.tau * modal_frequency / SAMPLE_RATE
            mode_envelope = attack * math.exp(-decay * t)
            modes += (
                math.sin(modal_phases[mode_index])
                * amplitude
                * mode_envelope
            )
        modes *= 1.0 + panel_noise * 0.10

        dry = impact + panel + frame_contact + pressure + modes
        samples.append(math.tanh(dry * 1.65) / math.tanh(1.65))

    # Sparse, low-level indoor reflections make the hit read as a door in a
    # room while keeping the cue short and avoiding a reverberant gong tail.
    dry_samples = samples.copy()
    for delay_seconds, gain in [(0.027, 0.11), (0.049, -0.075), (0.083, 0.045)]:
        delay_samples = round(delay_seconds * SAMPLE_RATE)
        for i in range(delay_samples, n):
            samples[i] += dry_samples[i - delay_samples] * gain

    release_start = duration - 0.055
    for i in range(n):
        t = i / SAMPLE_RATE
        if t > release_start:
            samples[i] *= _smoothstep((duration - t) / (duration - release_start))

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
