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
    """Muted, low door-close thud without a bright latch or ringing tail."""
    duration = 0.42
    n = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xD00D)
    samples: list[float] = []

    impact_low_pass_1 = 0.0
    impact_low_pass_2 = 0.0
    impact_floor = 0.0
    panel_low_pass_1 = 0.0
    panel_low_pass_2 = 0.0
    panel_floor = 0.0
    pressure_phase = 0.0
    modal_specs = [
        (94.0, 0.18, 19.0, 0.035),
        (137.0, 0.32, 20.0, 0.030),
        (191.0, 0.28, 23.0, 0.022),
        (268.0, 0.14, 31.0, 0.015),
        (382.0, 0.045, 44.0, 0.008),
    ]
    modal_phases = [
        random_source.uniform(-math.pi, math.pi)
        for _ in modal_specs
    ]
    impact_alpha = 1.0 - math.exp(-math.tau * 1500.0 / SAMPLE_RATE)
    impact_floor_alpha = 1.0 - math.exp(-math.tau * 210.0 / SAMPLE_RATE)
    panel_alpha = 1.0 - math.exp(-math.tau * 640.0 / SAMPLE_RATE)
    panel_floor_alpha = 1.0 - math.exp(-math.tau * 48.0 / SAMPLE_RATE)

    for i in range(n):
        t = i / SAMPLE_RATE
        white_noise = random_source.uniform(-1.0, 1.0)
        impact_low_pass_1 += impact_alpha * (
            white_noise - impact_low_pass_1
        )
        impact_low_pass_2 += impact_alpha * (
            impact_low_pass_1 - impact_low_pass_2
        )
        impact_floor += impact_floor_alpha * (
            white_noise - impact_floor
        )
        panel_low_pass_1 += panel_alpha * (
            white_noise - panel_low_pass_1
        )
        panel_low_pass_2 += panel_alpha * (
            panel_low_pass_1 - panel_low_pass_2
        )
        panel_floor += panel_floor_alpha * (white_noise - panel_floor)

        # Two cascaded low-pass stages keep the initial contact broad enough
        # to read as a physical door, but remove the bright "啪" of a latch.
        attack = _smoothstep(min(t / 0.0026, 1.0))
        impact_noise = impact_low_pass_2 - impact_floor
        impact = impact_noise * attack * math.exp(-72.0 * t) * 0.34
        panel_noise = panel_low_pass_2 - panel_floor
        panel = panel_noise * attack * math.exp(-20.0 * t) * 0.88

        frame_time = t - 0.012
        frame_contact = 0.0
        if frame_time >= 0.0:
            frame_attack = _smoothstep(min(frame_time / 0.002, 1.0))
            frame_contact = (
                impact_noise
                * frame_attack
                * math.exp(-110.0 * frame_time)
                * 0.12
            )

        pressure_frequency = 72.0 - 8.0 * _smoothstep(min(t / 0.09, 1.0))
        pressure_phase += math.tau * pressure_frequency / SAMPLE_RATE
        pressure = (
            math.sin(pressure_phase)
            * attack
            * math.exp(-31.0 * t)
            * 0.035
        )

        modes = 0.0
        for mode_index, (frequency, amplitude, decay, drop) in enumerate(modal_specs):
            modal_frequency = frequency * (
                1.0 - drop * _smoothstep(min(t / 0.19, 1.0))
            )
            modal_frequency += 0.35 * math.sin(
                math.tau * (9.0 + mode_index * 2.1) * t
                + mode_index * 0.71
            )
            modal_phases[mode_index] += math.tau * modal_frequency / SAMPLE_RATE
            mode_envelope = attack * math.exp(-decay * t)
            modes += (
                math.sin(modal_phases[mode_index])
                * amplitude
                * mode_envelope
            )
        modes *= 1.0 + panel_noise * 0.05

        # Avoid saturation because it introduces upper harmonics that turn a
        # low "咚" into "砰". The tiny second contact is the door settling
        # into its frame, not a separate bright latch click.
        samples.append(impact + panel + frame_contact + pressure + modes)

    dry_samples = samples.copy()
    for delay_seconds, gain in [(0.024, 0.035), (0.046, -0.018)]:
        delay_samples = round(delay_seconds * SAMPLE_RATE)
        for i in range(delay_samples, n):
            samples[i] += dry_samples[i - delay_samples] * gain

    release_start = duration - 0.05
    for i in range(n):
        t = i / SAMPLE_RATE
        if t > release_start:
            samples[i] *= _smoothstep((duration - t) / (duration - release_start))

    return samples


# ---------------------------------------------------------------------------
#  Output
# ---------------------------------------------------------------------------

def _write_sound(
    path: Path,
    samples: list[float],
    pcm_peak: int = 24000,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = max((abs(s) for s in samples), default=1.0)
    peak = max(peak, 1e-6)
    pcm = bytearray()
    for s in samples:
        clamped = max(-1.0, min(1.0, s / peak))
        pcm.extend(struct.pack("<h", round(clamped * pcm_peak)))

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
        pcm_peak=21500,
    )
    print(f"Generated wave and announcement UI audio in {output_directory}")


if __name__ == "__main__":
    main()
