#!/usr/bin/env python3
"""Generate deterministic audio for the main battle robot.

The default path is review-only.  The explicit ``--publish-approved-v2`` path
may write only the twelve user-approved revision-two cues to ``resources/audio``;
it verifies their approval-time SHA-256 values before completing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import tempfile
import wave


SAMPLE_RATE = 44_100
PCM_PEAK = 23_000
TAU = math.tau
SYNTHESIS_REVISION = 2
APPROVED_V2_CUE_SHA256 = {
    "stomp_a": "1cda1849e86906e5276c1b289d95178bbccaa491bf62d549c036f66e04b0ec11",
    "stomp_b": "e919785b32576340116ffb140d823c330b95d2105aa0964bfffb85fe78c2420b",
    "hit_a": "9dee42ab9b7af9bb1a2f287a7af2cb0142c786d7fc9c698b51d09987890c28c2",
    "hit_b": "a348b5ee16ac72076dac37ff40f60274f7eabd6ea5667b9c3c833ecea85f8e83",
    "normal_windup": "dde352ccb6fcd3458ef7938fce47e20354ff58c6fce9fefcf54f4db148661e1b",
    "normal_double_slash": "cf800dd58bb0806a8d4ec6e36ed5763f4e854052882d72b0f443b6c6a85590f4",
    "skill1_charge": "ed8a079bd9fa0f3aa3d9d391fce595d78935a233f90ff70fb7fe486052a38ede",
    "skill1_dash": "cec92a32f4e9910234c804d4f87c3439b2f05267715b8519406bf9a34f44fb45",
    "skill1_circle_slash": "90c4f6e6c3ef37c036e19c8f04fddf892d14c81377173075f185b00fd339f4c5",
    "skill2_takeoff": "16597b772547cef433f8e8a77f2a6f2797dca7121011461c369cf19fea426dd7",
    "skill2_drop_bilateral_slash": "0f5a634fe0c97b2bf65c88118efe76c934f14201797301dae8934858cc932ce5",
    "death": "3aa9d086bb92dd1a2662942fe5e56e5d1d80189bfb98464d8ba699c1fb379a8d",
}


def _smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def _gate(time: float, start: float, end: float, attack: float, release: float) -> float:
    if time < start or time >= end:
        return 0.0
    return _smoothstep((time - start) / max(attack, 1e-6)) * _smoothstep(
        (end - time) / max(release, 1e-6)
    )


def _linear_chirp_phase(time: float, duration: float, start_hz: float, end_hz: float) -> float:
    clamped = max(0.0, min(duration, time))
    slope = (end_hz - start_hz) / max(duration, 1e-6)
    return TAU * (start_hz * clamped + 0.5 * slope * clamped * clamped)


def _event_decay(time: float, event_time: float, rate: float) -> float:
    elapsed = time - event_time
    return math.exp(-rate * elapsed) if elapsed >= 0.0 else 0.0


def _noise_pair(random_source: random.Random, low: float, alpha: float) -> tuple[float, float, float]:
    white = random_source.uniform(-1.0, 1.0)
    next_low = low + (white - low) * alpha
    return white, next_low, white - next_low


class _BandNoise:
    """Deterministic mid-band texture without a persistent white-noise floor."""

    def __init__(self, random_source: random.Random) -> None:
        self._random_source = random_source
        self._fast = 0.0
        self._slow = 0.0

    def sample(self, fast_alpha: float = 0.18, slow_alpha: float = 0.025) -> float:
        white = self._random_source.uniform(-1.0, 1.0)
        self._fast += (white - self._fast) * fast_alpha
        self._slow += (white - self._slow) * slow_alpha
        return self._fast - self._slow


def _sweep_event(
    time: float,
    start: float,
    duration: float,
    start_hz: float,
    end_hz: float,
    gain: float,
    harmonic_gain: float = 0.0,
) -> float:
    elapsed = time - start
    if elapsed < 0.0 or elapsed >= duration:
        return 0.0
    progress = elapsed / duration
    envelope = math.sin(math.pi * progress) ** 1.7
    phase = _linear_chirp_phase(elapsed, duration, start_hz, end_hz)
    return (
        math.sin(phase) + math.sin(phase * 1.501) * harmonic_gain
    ) * envelope * gain


def _finalize(raw_samples: list[float], fade_in_s: float = 0.004, fade_out_s: float = 0.018) -> list[int]:
    if not raw_samples:
        raise ValueError("Cannot finalize an empty waveform")

    mean = sum(raw_samples) / len(raw_samples)
    centered = [sample - mean for sample in raw_samples]
    fade_in_count = max(2, round(fade_in_s * SAMPLE_RATE))
    fade_out_count = max(2, round(fade_out_s * SAMPLE_RATE))
    last_index = len(centered) - 1
    fade_weights: list[float] = []
    for index in range(len(centered)):
        gain = 1.0
        if index < fade_in_count:
            gain *= math.sin((index / fade_in_count) * math.pi * 0.5) ** 2
        remaining = last_index - index
        if remaining < fade_out_count:
            gain *= math.sin((remaining / fade_out_count) * math.pi * 0.5) ** 2
        centered[index] *= gain
        fade_weights.append(gain)

    # The envelope can reintroduce a tiny DC bias after the first centering.
    # Remove it along the same zero-at-the-ends envelope so the correction does
    # not create endpoint steps or tail clicks.
    weighted_sum = sum(fade_weights)
    dc_correction = sum(centered) / max(weighted_sum, 1e-12)
    for index, weight in enumerate(fade_weights):
        centered[index] -= dc_correction * weight

    peak = max(max(abs(sample) for sample in centered), 1e-12)
    pcm = [round(max(-1.0, min(1.0, sample / peak)) * PCM_PEAK) for sample in centered]
    pcm[0] = 0
    pcm[-1] = 0
    return pcm


def _stomp(variant: int) -> list[int]:
    duration = 0.25
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0x51_0A + variant * 0x101)
    low_noise = 0.0
    phase = 0.0
    impact_time = 0.052 if variant == 0 else 0.047
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        servo_progress = min(time / 0.085, 1.0)
        servo_hz = (285.0 if variant == 0 else 255.0) - 175.0 * servo_progress
        phase += TAU * servo_hz / SAMPLE_RATE
        servo = (
            math.sin(phase) * 0.25
            + math.sin(phase * 2.01) * 0.075
        ) * _gate(time, 0.0, 0.105, 0.005, 0.025)

        elapsed = time - impact_time
        impact = 0.0
        metal = 0.0
        transient = 0.0
        white, low_noise, high_noise = _noise_pair(random_source, low_noise, 0.055)
        if elapsed >= 0.0:
            impact = (
                math.sin(TAU * (58.0 + variant * 5.0) * elapsed) * 0.64
                + math.sin(TAU * (91.0 + variant * 7.0) * elapsed) * 0.24
            ) * math.exp(-19.0 * elapsed)
            metal = (
                math.sin(TAU * (342.0 + variant * 31.0) * elapsed) * 0.16
                + math.sin(TAU * (611.0 + variant * 23.0) * elapsed) * 0.10
                + math.sin(TAU * (1030.0 - variant * 47.0) * elapsed) * 0.045
            ) * math.exp(-14.0 * elapsed)
            transient = (high_noise * 0.31 + white * 0.06) * math.exp(-72.0 * elapsed)
        raw.append(servo + impact + metal + transient)
    return _finalize(raw, 0.003, 0.026)


def _armor_hit(variant: int) -> list[int]:
    duration = 0.16 if variant == 0 else 0.18
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xA8_10 + variant * 0x31)
    low_noise = 0.0
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        white, low_noise, high_noise = _noise_pair(random_source, low_noise, 0.09)
        thud = (
            math.sin(TAU * (118.0 + variant * 13.0) * time) * 0.55
            + math.sin(TAU * (184.0 - variant * 11.0) * time) * 0.18
        ) * math.exp(-(28.0 - variant * 2.0) * time)
        ring = (
            math.sin(TAU * (624.0 + variant * 83.0) * time) * 0.23
            + math.sin(TAU * (1035.0 - variant * 59.0) * time) * 0.12
            + math.sin(TAU * (1740.0 + variant * 107.0) * time) * 0.055
        ) * math.exp(-(22.0 + variant * 2.0) * time)
        crack = (high_noise * 0.34 + white * 0.09) * math.exp(-85.0 * time)
        raw.append(thud + ring + crack)
    return _finalize(raw, 0.0015, 0.022)


def _normal_windup() -> list[int]:
    duration = 0.35
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xA771_CE)
    contact_texture = _BandNoise(random_source)
    motor_phase = 0.0
    sub_phase = 0.0
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        progress = index / max(count - 1, 1)
        eased = _smoothstep(progress)
        motor_hz = 92.0 + 178.0 * eased
        motor_phase += TAU * motor_hz / SAMPLE_RATE
        sub_phase += TAU * (motor_hz * 0.5) / SAMPLE_RATE
        pulse = 0.72 + 0.28 * (0.5 + 0.5 * math.sin(TAU * (4.5 + 5.5 * eased) * time))
        motor = (
            math.sin(motor_phase) * 0.29
            + math.sin(motor_phase * 1.99) * 0.08
            + math.sin(sub_phase) * 0.105
        ) * pulse * (0.35 + 0.65 * eased)

        # Three discrete arm-lock syllables make the preparation readable.
        ratchet = 0.0
        texture = contact_texture.sample(0.14, 0.018)
        for event, pitch in ((0.078, 520.0), (0.166, 665.0), (0.254, 810.0)):
            elapsed = time - event
            if 0.0 <= elapsed < 0.044:
                ratchet += (
                    math.sin(TAU * pitch * elapsed) * 0.13
                    + math.sin(TAU * pitch * 1.71 * elapsed) * 0.045
                    + texture * 0.035
                ) * math.exp(-54.0 * elapsed)

        latch_elapsed = time - 0.315
        latch = 0.0
        if latch_elapsed >= 0.0:
            latch = (
                math.sin(TAU * 384.0 * latch_elapsed) * 0.23
                + math.sin(TAU * 925.0 * latch_elapsed) * 0.065
                + texture * 0.05
            ) * math.exp(-68.0 * latch_elapsed)
        raw.append((motor + ratchet + latch) * _gate(time, 0.0, duration, 0.008, 0.025))
    return _finalize(raw, 0.005, 0.021)


def _normal_double_slash() -> list[int]:
    duration = 0.78
    accent_time = 0.54
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xD0_B1E5)
    contact_texture = _BandNoise(random_source)
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        texture = contact_texture.sample(0.22, 0.025)
        motion = (
            _sweep_event(time, 0.070, 0.205, 175.0, 940.0, 0.16, 0.22)
            + _sweep_event(time, 0.245, 0.205, 205.0, 1080.0, 0.18, 0.18)
        )

        accent_elapsed = time - accent_time
        accent = 0.0
        if accent_elapsed >= 0.0:
            accent = (
                math.sin(TAU * 61.0 * accent_elapsed) * 0.92
                + math.sin(TAU * 126.0 * accent_elapsed) * 0.31
                + math.sin(TAU * 472.0 * accent_elapsed) * 0.21
                + math.sin(TAU * 870.0 * accent_elapsed) * 0.09
                + texture * 0.16
            ) * math.exp(-18.5 * accent_elapsed)
        tail_elapsed = time - 0.565
        tail = 0.0
        if tail_elapsed >= 0.0:
            tail = (
                math.sin(TAU * 318.0 * tail_elapsed) * 0.10
                + math.sin(TAU * 577.0 * tail_elapsed) * 0.055
            ) * math.exp(-11.0 * tail_elapsed)
        raw.append(motion + accent + tail)
    return _finalize(raw, 0.004, 0.03)


def _skill1_charge() -> list[int]:
    duration = 0.56
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xC1A2_6E)
    contact_texture = _BandNoise(random_source)
    energy_phase = 0.0
    sub_phase = 0.0
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        progress = index / max(count - 1, 1)
        eased = _smoothstep(progress)
        frequency = 112.0 + 390.0 * eased
        energy_phase += TAU * frequency / SAMPLE_RATE
        sub_phase += TAU * (56.0 + 28.0 * progress) / SAMPLE_RATE
        pulse_rate = 4.0 + 9.0 * eased
        pulse = 0.68 + 0.32 * (0.5 + 0.5 * math.sin(TAU * pulse_rate * time))
        orange_energy = (
            math.sin(energy_phase) * 0.27
            + math.sin(energy_phase * 1.501) * 0.08
            + math.sin(sub_phase) * 0.15
        ) * pulse * (0.22 + 0.78 * eased)

        texture = contact_texture.sample(0.16, 0.02)
        charge_steps = 0.0
        for event, pitch in ((0.105, 390.0), (0.245, 570.0), (0.385, 760.0)):
            elapsed = time - event
            if 0.0 <= elapsed < 0.065:
                charge_steps += (
                    math.sin(TAU * pitch * elapsed) * 0.125
                    + math.sin(TAU * pitch * 1.5 * elapsed) * 0.040
                    + texture * 0.018
                ) * math.exp(-32.0 * elapsed)
        lock_elapsed = time - 0.515
        lock = 0.0
        if lock_elapsed >= 0.0:
            lock = (
                math.sin(TAU * 920.0 * lock_elapsed) * 0.27
                + math.sin(TAU * 1380.0 * lock_elapsed) * 0.10
                + math.sin(TAU * 230.0 * lock_elapsed) * 0.14
            ) * math.exp(-36.0 * lock_elapsed)
        raw.append((orange_energy + charge_steps + lock) * _gate(time, 0.0, duration, 0.012, 0.038))
    return _finalize(raw, 0.006, 0.032)


def _skill1_dash() -> list[int]:
    duration = 0.75
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xDA54_240)
    air_texture = _BandNoise(random_source)
    motor_phase = 0.0
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        progress = index / max(count - 1, 1)
        motor_hz = 76.0 + 31.0 * math.sin(math.pi * progress)
        motor_phase += TAU * motor_hz / SAMPLE_RATE
        texture = air_texture.sample(0.12, 0.018)
        launch = 0.0
        if time < 0.18:
            launch = (
                math.sin(TAU * 57.0 * time) * 0.68
                + math.sin(TAU * 168.0 * time) * 0.20
                + math.sin(TAU * 412.0 * time) * 0.07
            ) * math.exp(-19.0 * time)
        motor = (
            math.sin(motor_phase) * 0.20
            + math.sin(motor_phase * 2.02) * 0.055
            + math.sin(motor_phase * 3.01) * 0.018
        ) * (0.82 + 0.18 * math.sin(TAU * 8.0 * time) ** 2)

        traction = 0.0
        for event, pitch in ((0.270, 246.0), (0.395, 286.0), (0.520, 326.0)):
            elapsed = time - event
            if 0.0 <= elapsed < 0.075:
                traction += (
                    math.sin(TAU * pitch * elapsed) * 0.095
                    + math.sin(TAU * pitch * 2.0 * elapsed) * 0.03
                ) * math.exp(-31.0 * elapsed)

        # Air movement exists only at launch and braking, never as a noise floor.
        air = texture * 0.026 * (
            _gate(time, 0.035, 0.145, 0.012, 0.035)
            + _gate(time, 0.570, 0.640, 0.012, 0.025)
        )
        brake_elapsed = time - 0.565
        brake = 0.0
        if brake_elapsed >= 0.0:
            brake = (
                math.sin(TAU * 214.0 * brake_elapsed) * 0.17
                + math.sin(TAU * 508.0 * brake_elapsed) * 0.055
            ) * math.exp(-24.0 * brake_elapsed)
        raw.append((launch + motor + traction + air + brake) * _gate(time, 0.0, duration, 0.008, 0.07))
    return _finalize(raw, 0.004, 0.055)


def _skill1_circle_slash() -> list[int]:
    duration = 0.78
    count = round(duration * SAMPLE_RATE)
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        # Start impact, paired blade sweep, energy ring, then hydraulic lock.
        opening = (
            math.sin(TAU * 62.0 * time) * 0.86
            + math.sin(TAU * 151.0 * time) * 0.25
            + math.sin(TAU * 535.0 * time) * 0.11
        ) * math.exp(-25.0 * time)
        rotation = (
            _sweep_event(time, 0.028, 0.360, 170.0, 1120.0, 0.19, 0.22)
            + _sweep_event(time, 0.033, 0.360, 215.0, 1010.0, 0.18, 0.18)
            + _sweep_event(time, 0.420, 0.150, 760.0, 260.0, 0.11, 0.12)
        )
        ring = (
            math.sin(TAU * 386.0 * time) * 0.085
            + math.sin(TAU * 721.0 * time) * 0.040
        ) * _gate(time, 0.10, 0.69, 0.055, 0.12)
        settle_elapsed = time - 0.555
        settle = 0.0
        if settle_elapsed >= 0.0:
            settle = (
                math.sin(TAU * 278.0 * settle_elapsed) * 0.10
                + math.sin(TAU * 612.0 * settle_elapsed) * 0.045
            ) * math.exp(-24.0 * settle_elapsed)
        raw.append(opening + rotation + ring + settle)
    return _finalize(raw, 0.0015, 0.045)


def _skill2_takeoff() -> list[int]:
    duration = 0.46
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0x7A_0FF)
    release_texture = _BandNoise(random_source)
    lift_phase = 0.0
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        progress = index / max(count - 1, 1)
        lift_hz = 130.0 + 490.0 * _smoothstep(progress)
        lift_phase += TAU * lift_hz / SAMPLE_RATE
        texture = release_texture.sample(0.16, 0.02)
        preload = _sweep_event(time, 0.0, 0.108, 245.0, 112.0, 0.22, 0.18)
        ignition_elapsed = time - 0.108
        ignition = 0.0
        if ignition_elapsed >= 0.0:
            ignition = (
                math.sin(TAU * 56.0 * ignition_elapsed) * 0.72
                + math.sin(TAU * 174.0 * ignition_elapsed) * 0.20
            ) * math.exp(-22.0 * ignition_elapsed)
        lift = (
            math.sin(lift_phase) * 0.29
            + math.sin(lift_phase * 1.498) * 0.085
        ) * _gate(time, 0.105, 0.405, 0.025, 0.065)
        release = texture * 0.065 * _gate(time, 0.088, 0.145, 0.006, 0.020)
        latch_elapsed = time - 0.405
        latch = 0.0
        if latch_elapsed >= 0.0:
            latch = (
                math.sin(TAU * 410.0 * latch_elapsed) * 0.15
                + math.sin(TAU * 885.0 * latch_elapsed) * 0.05
            ) * math.exp(-42.0 * latch_elapsed)
        raw.append((preload + ignition + lift + release + latch) * _gate(time, 0.0, duration, 0.006, 0.055))
    return _finalize(raw, 0.004, 0.046)


def _skill2_drop_bilateral_slash() -> list[int]:
    duration = 0.76
    impact_time = 0.18
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xD20F_5A)
    contact_texture = _BandNoise(random_source)
    raw: list[float] = []
    for index in range(count):
        time = index / SAMPLE_RATE
        texture = contact_texture.sample(0.20, 0.025)
        fall = _sweep_event(time, 0.0, 0.165, 790.0, 145.0, 0.14, 0.16)

        elapsed = time - impact_time
        impact = 0.0
        if elapsed >= 0.0:
            impact = (
                math.sin(TAU * 48.0 * elapsed) * 0.94
                + math.sin(TAU * 92.0 * elapsed) * 0.34
                + math.sin(TAU * 312.0 * elapsed) * 0.19
                + math.sin(TAU * 684.0 * elapsed) * 0.075
                + texture * 0.18
            ) * math.exp(-17.5 * elapsed)
        slash = (
            _sweep_event(time, 0.184, 0.315, 175.0, 1120.0, 0.17, 0.20)
            + _sweep_event(time, 0.188, 0.315, 215.0, 1030.0, 0.17, 0.18)
        )
        tail_elapsed = time - 0.410
        energy_tail = 0.0
        if tail_elapsed >= 0.0:
            energy_tail = (
                math.sin(TAU * 286.0 * tail_elapsed) * 0.075
                + math.sin(TAU * 548.0 * tail_elapsed) * 0.035
            ) * math.exp(-8.5 * tail_elapsed)
        raw.append(fall + impact + slash + energy_tail)
    return _finalize(raw, 0.003, 0.05)


def _death() -> list[int]:
    duration = 1.20
    count = round(duration * SAMPLE_RATE)
    random_source = random.Random(0xDEAD_12)
    contact_texture = _BandNoise(random_source)
    core_phase = 0.0
    raw: list[float] = []
    collapse_events = (
        (0.37, 0.52, 78.0, 410.0),
        (0.61, 0.38, 66.0, 525.0),
        (0.83, 0.47, 54.0, 338.0),
        (0.99, 0.30, 43.0, 260.0),
    )
    for index in range(count):
        time = index / SAMPLE_RATE
        progress = index / max(count - 1, 1)
        core_hz = 430.0 * math.pow(0.19, min(progress / 0.68, 1.0)) + 24.0
        core_phase += TAU * core_hz / SAMPLE_RATE
        power = (
            math.sin(core_phase) * 0.28
            + math.sin(core_phase * 0.5) * 0.15
        ) * _gate(time, 0.0, 0.82, 0.012, 0.17)
        pulse = power * (0.66 + 0.34 * math.sin(TAU * (7.0 - 4.5 * progress) * time) ** 2)

        texture = contact_texture.sample(0.16, 0.02)
        collapse = 0.0
        for event_time, gain, bass_hz, ring_hz in collapse_events:
            elapsed = time - event_time
            if elapsed >= 0.0:
                collapse += (
                    math.sin(TAU * bass_hz * elapsed) * gain
                    + math.sin(TAU * ring_hz * elapsed) * gain * 0.26
                    + texture * gain * 0.12
                ) * math.exp(-20.0 * elapsed)
        final_elapsed = time - 0.94
        final_rumble = 0.0
        if final_elapsed >= 0.0:
            final_rumble = (
                math.sin(TAU * 39.0 * final_elapsed) * 0.50
                + math.sin(TAU * 73.0 * final_elapsed) * 0.16
            ) * math.exp(-10.5 * final_elapsed)
        raw.append(pulse + collapse + final_rumble)
    return _finalize(raw, 0.006, 0.085)


def _write_pcm_wav(path: Path, samples: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = struct.pack(f"<{len(samples)}h", *samples)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _analyse(samples: list[int]) -> dict[str, int | float]:
    peak = max(abs(sample) for sample in samples)
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    dc = sum(samples) / len(samples)
    edge_count = max(1, round(0.004 * SAMPLE_RATE))
    edge_peak = max(abs(sample) for sample in samples[:edge_count] + samples[-edge_count:])
    return {
        "sample_count": len(samples),
        "duration_s": round(len(samples) / SAMPLE_RATE, 6),
        "peak_sample": peak,
        "peak_dbfs": round(20.0 * math.log10(peak / 32767.0), 4),
        "rms_sample": round(rms, 4),
        "rms_dbfs": round(20.0 * math.log10(max(rms, 1e-12) / 32767.0), 4),
        "highpass_8khz_rms_dbfs": round(_highpass_rms_dbfs(samples, 8_000.0), 4),
        "dc_offset_normalized": round(dc / 32767.0, 8),
        "first_sample": samples[0],
        "last_sample": samples[-1],
        "edge_4ms_peak": edge_peak,
        "clipped_sample_count": sum(1 for sample in samples if abs(sample) >= 32767),
    }


def _highpass_rms_dbfs(samples: list[int], cutoff_hz: float, stages: int = 4) -> float:
    filtered = [float(sample) for sample in samples]
    delta_time = 1.0 / SAMPLE_RATE
    time_constant = 1.0 / (TAU * cutoff_hz)
    coefficient = time_constant / (time_constant + delta_time)
    for _stage in range(stages):
        output: list[float] = []
        previous_input = filtered[0]
        previous_output = 0.0
        for sample in filtered:
            current = coefficient * (previous_output + sample - previous_input)
            output.append(current)
            previous_input = sample
            previous_output = current
        filtered = output
    rms = math.sqrt(sum(sample * sample for sample in filtered) / len(filtered))
    return 20.0 * math.log10(max(rms, 1e-12) / 32767.0)


def _segment_rms_dbfs(samples: list[int], start_s: float, end_s: float) -> float:
    start = round(start_s * SAMPLE_RATE)
    end = round(end_s * SAMPLE_RATE)
    segment = samples[start:end]
    if not segment:
        raise ValueError("Semantic RMS segment cannot be empty")
    rms = math.sqrt(sum(sample * sample for sample in segment) / len(segment))
    return 20.0 * math.log10(max(rms, 1e-12) / 32767.0)


def _window_rms_peak_time(samples: list[int], window_s: float = 0.012) -> float:
    window = max(1, round(window_s * SAMPLE_RATE))
    squares = [sample * sample for sample in samples]
    running = sum(squares[:window])
    best = running
    best_start = 0
    for start in range(1, len(samples) - window + 1):
        running += squares[start + window - 1] - squares[start - 1]
        if running > best:
            best = running
            best_start = start
    return round((best_start + window * 0.5) / SAMPLE_RATE, 6)


def _render_review(events: list[tuple[float, str]], total_duration_s: float, cues: dict[str, list[int]]) -> list[int]:
    output = [0] * round(total_duration_s * SAMPLE_RATE)
    for start_s, cue_name in events:
        start = round(start_s * SAMPLE_RATE)
        cue = cues[cue_name]
        if start + len(cue) > len(output):
            raise ValueError(f"Review event {cue_name} exceeds the review duration")
        for offset, sample in enumerate(cue):
            mixed = output[start + offset] + sample
            output[start + offset] = max(-32767, min(32767, mixed))
    return output


def _validate_cue(name: str, samples: list[int], expected_duration_s: float) -> None:
    expected_count = round(expected_duration_s * SAMPLE_RATE)
    if len(samples) != expected_count:
        raise ValueError(f"{name}: expected {expected_count} samples, got {len(samples)}")
    metrics = _analyse(samples)
    if metrics["peak_sample"] != PCM_PEAK:
        raise ValueError(f"{name}: peak must be exactly {PCM_PEAK}")
    if metrics["clipped_sample_count"] != 0:
        raise ValueError(f"{name}: clipped samples detected")
    if metrics["first_sample"] != 0 or metrics["last_sample"] != 0:
        raise ValueError(f"{name}: endpoints must be zero")
    if abs(float(metrics["dc_offset_normalized"])) > 0.002:
        raise ValueError(f"{name}: DC offset exceeds 0.2%")


def _validate_semantic_intent(name: str, samples: list[int]) -> dict[str, object]:
    metrics: dict[str, object] = {
        "highpass_8khz_rms_dbfs": round(_highpass_rms_dbfs(samples, 8_000.0), 4)
    }
    revised_low_noise_cues = {
        "normal_windup",
        "normal_double_slash",
        "skill1_charge",
        "skill1_dash",
        "skill1_circle_slash",
        "skill2_takeoff",
        "skill2_drop_bilateral_slash",
        "death",
    }
    if name in revised_low_noise_cues and float(metrics["highpass_8khz_rms_dbfs"]) > -36.0:
        raise ValueError(f"{name}: persistent high-frequency floor exceeds -36 dBFS")

    segments: dict[str, float] = {}
    if name == "normal_windup":
        segments = {
            "opening_dbfs": _segment_rms_dbfs(samples, 0.0, 0.08),
            "ready_dbfs": _segment_rms_dbfs(samples, 0.27, 0.35),
        }
        if segments["ready_dbfs"] - segments["opening_dbfs"] < 4.0:
            raise ValueError("normal_windup: readiness must grow by at least 4 dB")
    elif name == "skill1_charge":
        quarters = [_segment_rms_dbfs(samples, index * 0.14, (index + 1) * 0.14) for index in range(4)]
        segments = {f"quarter_{index + 1}_dbfs": value for index, value in enumerate(quarters)}
        if any(quarters[index + 1] - quarters[index] < 1.25 for index in range(3)):
            raise ValueError("skill1_charge: every energy quarter must grow by at least 1.25 dB")
        if quarters[-1] - quarters[0] < 7.0:
            raise ValueError("skill1_charge: final quarter must exceed opening by at least 7 dB")
        completion_peak_s = _window_rms_peak_time(samples)
        metrics["completion_peak_s"] = completion_peak_s
        if not 0.505 <= completion_peak_s <= 0.535:
            raise ValueError("skill1_charge: strongest completion window must land near the 0.515 s lock")
    elif name == "skill1_dash":
        segments = {
            "launch_dbfs": _segment_rms_dbfs(samples, 0.0, 0.12),
            "cruise_dbfs": _segment_rms_dbfs(samples, 0.20, 0.55),
            "brake_tail_dbfs": _segment_rms_dbfs(samples, 0.62, 0.75),
        }
        if segments["launch_dbfs"] - segments["cruise_dbfs"] < 4.0:
            raise ValueError("skill1_dash: launch syllable must exceed cruise by at least 4 dB")
        if segments["cruise_dbfs"] - segments["brake_tail_dbfs"] < 1.5:
            raise ValueError("skill1_dash: braking tail must audibly decay")
    elif name == "skill1_circle_slash":
        segments = {
            "release_impact_dbfs": _segment_rms_dbfs(samples, 0.0, 0.05),
            "rotation_dbfs": _segment_rms_dbfs(samples, 0.08, 0.42),
            "lock_tail_dbfs": _segment_rms_dbfs(samples, 0.55, 0.78),
        }
        if segments["release_impact_dbfs"] - segments["rotation_dbfs"] < 6.0:
            raise ValueError("skill1_circle_slash: opening impact must dominate rotation")
        if segments["rotation_dbfs"] - segments["lock_tail_dbfs"] < 6.0:
            raise ValueError("skill1_circle_slash: lock tail must decay after rotation")
    elif name == "skill2_takeoff":
        segments = {
            "preload_dbfs": _segment_rms_dbfs(samples, 0.0, 0.10),
            "lift_dbfs": _segment_rms_dbfs(samples, 0.108, 0.30),
            "apex_tail_dbfs": _segment_rms_dbfs(samples, 0.405, 0.46),
        }
        if segments["lift_dbfs"] - segments["preload_dbfs"] < 6.0:
            raise ValueError("skill2_takeoff: lift must dominate hydraulic preload")
        if segments["lift_dbfs"] - segments["apex_tail_dbfs"] < 8.0:
            raise ValueError("skill2_takeoff: apex cutoff must end cleanly")
    elif name == "skill2_drop_bilateral_slash":
        segments = {
            "descent_dbfs": _segment_rms_dbfs(samples, 0.0, 0.165),
            "impact_dbfs": _segment_rms_dbfs(samples, 0.18, 0.25),
            "bilateral_slash_dbfs": _segment_rms_dbfs(samples, 0.25, 0.55),
            "tail_dbfs": _segment_rms_dbfs(samples, 0.62, 0.76),
        }
        if segments["impact_dbfs"] - segments["descent_dbfs"] < 8.0:
            raise ValueError("skill2_drop: impact must dominate descent by at least 8 dB")
        if segments["impact_dbfs"] - segments["bilateral_slash_dbfs"] < 6.0:
            raise ValueError("skill2_drop: impact must remain distinct from the blade release")
        if segments["tail_dbfs"] > -40.0:
            raise ValueError("skill2_drop: tail must fall below -40 dBFS")
    metrics["semantic_rms_segments_dbfs"] = {
        key: round(value, 4) for key, value in segments.items()
    }
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate phase-one main battle robot audio audition files."
    )
    parser.add_argument(
        "output_directory",
        help="Explicit development-preview destination; no runtime path is implied.",
    )
    parser.add_argument(
        "--publish-approved-v2",
        action="store_true",
        help="Write only the twelve SHA-locked approved V2 cues to resources/audio.",
    )
    args = parser.parse_args()
    output_directory = Path(args.output_directory).resolve()
    generator_path = Path(__file__).resolve()
    repository_root = generator_path.parent.parent
    preview_root = repository_root / "dev_assets" / "generated_previews"
    runtime_audio_root = repository_root / "resources" / "audio"
    inside_repository = output_directory == repository_root or repository_root in output_directory.parents
    inside_preview_root = output_directory == preview_root or preview_root in output_directory.parents
    if args.publish_approved_v2:
        if output_directory != runtime_audio_root or SYNTHESIS_REVISION != 2:
            parser.error(
                "Approved publishing is restricted to revision two and the exact "
                "resources/audio directory."
            )
    elif inside_repository and not inside_preview_root:
        parser.error(
            "This phase-one audition generator may only write inside "
            "dev_assets/generated_previews/ or an explicit directory outside the repository. "
            "Approve the cues before using the separate runtime integration flow."
        )
    publish_staging: tempfile.TemporaryDirectory[str] | None = None
    if args.publish_approved_v2:
        output_directory.mkdir(parents=True, exist_ok=True)
        publish_staging = tempfile.TemporaryDirectory(
            prefix=".combat_robot_main_battle_elite_publish_",
            dir=output_directory,
        )
        cue_directory = Path(publish_staging.name)
    else:
        cue_directory = output_directory / "cues"
    review_directory = output_directory / "reviews"

    cue_specs: dict[str, tuple[str, float, list[int], float | None]] = {
        "stomp_a": ("combat_robot_main_battle_elite_stomp_a.wav", 0.25, _stomp(0), None),
        "stomp_b": ("combat_robot_main_battle_elite_stomp_b.wav", 0.25, _stomp(1), None),
        "hit_a": ("combat_robot_main_battle_elite_hit_a.wav", 0.16, _armor_hit(0), None),
        "hit_b": ("combat_robot_main_battle_elite_hit_b.wav", 0.18, _armor_hit(1), None),
        "normal_windup": ("combat_robot_main_battle_elite_normal_windup.wav", 0.35, _normal_windup(), None),
        "normal_double_slash": (
            "combat_robot_main_battle_elite_normal_double_slash.wav",
            0.78,
            _normal_double_slash(),
            0.54,
        ),
        "skill1_charge": ("combat_robot_main_battle_elite_skill1_charge.wav", 0.56, _skill1_charge(), None),
        "skill1_dash": ("combat_robot_main_battle_elite_skill1_dash.wav", 0.75, _skill1_dash(), None),
        "skill1_circle_slash": (
            "combat_robot_main_battle_elite_skill1_circle_slash.wav",
            0.78,
            _skill1_circle_slash(),
            0.02,
        ),
        "skill2_takeoff": ("combat_robot_main_battle_elite_skill2_takeoff.wav", 0.46, _skill2_takeoff(), None),
        "skill2_drop_bilateral_slash": (
            "combat_robot_main_battle_elite_skill2_drop_bilateral_slash.wav",
            0.76,
            _skill2_drop_bilateral_slash(),
            0.18,
        ),
        "death": ("combat_robot_main_battle_elite_death.wav", 1.20, _death(), None),
    }
    cue_syllables: dict[str, list[dict[str, object]]] = {
        "stomp_a": [{"at_s": 0.0, "intent": "hydraulic_closure"}, {"at_s": 0.052, "intent": "left_heavy_footfall"}],
        "stomp_b": [{"at_s": 0.0, "intent": "hydraulic_closure"}, {"at_s": 0.047, "intent": "right_heavy_footfall"}],
        "hit_a": [{"at_s": 0.0, "intent": "armor_contact"}, {"at_s": 0.010, "intent": "short_metal_resonance_a"}],
        "hit_b": [{"at_s": 0.0, "intent": "armor_contact"}, {"at_s": 0.012, "intent": "short_metal_resonance_b"}],
        "normal_windup": [
            {"at_s": 0.078, "intent": "arm_lock_step_1"},
            {"at_s": 0.166, "intent": "arm_lock_step_2"},
            {"at_s": 0.254, "intent": "arm_lock_step_3"},
            {"at_s": 0.315, "intent": "attack_ready_latch"},
        ],
        "normal_double_slash": [
            {"at_s": 0.070, "intent": "blade_pass_left"},
            {"at_s": 0.245, "intent": "blade_pass_right"},
            {"at_s": 0.540, "intent": "shared_heavy_mechanical_stop"},
        ],
        "skill1_charge": [
            {"at_s": 0.105, "intent": "energy_step_1"},
            {"at_s": 0.245, "intent": "energy_step_2"},
            {"at_s": 0.385, "intent": "energy_step_3"},
            {"at_s": 0.515, "intent": "charge_lock"},
        ],
        "skill1_dash": [
            {"at_s": 0.0, "intent": "propulsion_release"},
            {"at_s": 0.270, "intent": "traction_pulse_1"},
            {"at_s": 0.395, "intent": "traction_pulse_2"},
            {"at_s": 0.520, "intent": "traction_pulse_3"},
            {"at_s": 0.565, "intent": "braking_lock"},
        ],
        "skill1_circle_slash": [
            {"at_s": 0.0, "intent": "circle_slash_release_impact"},
            {"at_s": 0.028, "intent": "paired_rotational_blades"},
            {"at_s": 0.420, "intent": "return_sweep"},
            {"at_s": 0.555, "intent": "hydraulic_lock"},
        ],
        "skill2_takeoff": [
            {"at_s": 0.0, "intent": "leg_hydraulic_preload"},
            {"at_s": 0.108, "intent": "takeoff_ignition"},
            {"at_s": 0.405, "intent": "apex_cutoff"},
        ],
        "skill2_drop_bilateral_slash": [
            {"at_s": 0.0, "intent": "descending_pitch"},
            {"at_s": 0.180, "intent": "ground_impact"},
            {"at_s": 0.184, "intent": "bilateral_outward_blade_release"},
            {"at_s": 0.410, "intent": "armor_energy_resonance"},
        ],
        "death": [
            {"at_s": 0.0, "intent": "core_power_failure"},
            {"at_s": 0.370, "intent": "armor_collapse_1"},
            {"at_s": 0.610, "intent": "armor_collapse_2"},
            {"at_s": 0.830, "intent": "armor_collapse_3"},
            {"at_s": 0.990, "intent": "final_collapse"},
        ],
    }

    cues: dict[str, list[int]] = {}
    cue_manifest: dict[str, dict[str, object]] = {}
    for cue_name, (file_name, duration, samples, intended_accent) in cue_specs.items():
        _validate_cue(cue_name, samples, duration)
        semantic_metrics = _validate_semantic_intent(cue_name, samples)
        path = cue_directory / file_name
        _write_pcm_wav(path, samples)
        cues[cue_name] = samples
        metrics = _analyse(samples)
        measured_accent = _window_rms_peak_time(samples)
        if intended_accent is not None:
            tolerance = 0.055 if cue_name != "skill1_circle_slash" else 0.065
            if abs(measured_accent - intended_accent) > tolerance:
                raise ValueError(
                    f"{cue_name}: measured accent {measured_accent:.3f}s is not near "
                    f"{intended_accent:.3f}s"
                )
        cue_manifest[cue_name] = {
            "path": path.relative_to(output_directory).as_posix(),
            "sha256": _sha256(path),
            "format": {"sample_rate_hz": SAMPLE_RATE, "channels": 1, "sample_width_bits": 16, "encoding": "PCM"},
            "metrics": metrics,
            "intended_primary_accent_s": intended_accent,
            "measured_12ms_rms_peak_s": measured_accent,
            "semantic_syllables": cue_syllables[cue_name],
            "semantic_metrics": semantic_metrics,
        }

    if args.publish_approved_v2:
        for cue_name, cue_record in cue_manifest.items():
            actual_sha256 = str(cue_record["sha256"])
            expected_sha256 = APPROVED_V2_CUE_SHA256.get(cue_name, "")
            if actual_sha256 != expected_sha256:
                raise ValueError(
                    f"{cue_name}: approved SHA-256 drift: "
                    f"expected {expected_sha256}, got {actual_sha256}"
                )
        if set(cue_manifest) != set(APPROVED_V2_CUE_SHA256):
            raise ValueError("Published cue set does not exactly match the approved V2 set")
        for cue_name, cue_record in cue_manifest.items():
            source = cue_directory / Path(str(cue_record["path"])).name
            destination = output_directory / source.name
            source.replace(destination)
            if _sha256(destination) != APPROVED_V2_CUE_SHA256[cue_name]:
                raise ValueError(f"{cue_name}: post-publish SHA-256 verification failed")
        if publish_staging is not None:
            publish_staging.cleanup()
        print(f"Published {len(cue_manifest)} approved V2 cues to {output_directory}")
        return

    review_specs: dict[str, tuple[str, float, list[tuple[float, str]], str]] = {
        "movement": (
            "combat_robot_main_battle_elite_review_movement.wav",
            2.30,
            [(0.20, "stomp_a"), (0.59, "stomp_b"), (1.24, "stomp_a"), (1.63, "stomp_b")],
            "Two 1.04 s move loops; footfalls align to frames 5 and 8, A/B alternating.",
        ),
        "normal_attack": (
            "combat_robot_main_battle_elite_review_normal_attack.wav",
            1.73,
            [(0.20, "normal_windup"), (0.55, "normal_double_slash")],
            "0.35 s windup followed by the 0.78 s double slash; slash accent is 0.54 s into its cue.",
        ),
        "skill1": (
            "combat_robot_main_battle_elite_review_skill1.wav",
            2.79,
            [(0.20, "skill1_charge"), (0.76, "skill1_dash"), (1.51, "skill1_circle_slash")],
            "Charge, dash, then immediate-accent circle slash without overlap.",
        ),
        "skill2": (
            "combat_robot_main_battle_elite_review_skill2.wav",
            4.92,
            [(0.20, "skill2_takeoff"), (3.66, "skill2_drop_bilateral_slash")],
            "Takeoff, exactly 3.00 s of silent tracking, then drop and bilateral slash.",
        ),
        "hit_and_death": (
            "combat_robot_main_battle_elite_review_hit_and_death.wav",
            2.95,
            [(0.20, "hit_a"), (0.66, "hit_b"), (1.25, "death")],
            "Hit A, Hit B, then the dedicated core-failure and staged-collapse death cue.",
        ),
    }

    review_manifest: dict[str, dict[str, object]] = {}
    for review_name, (file_name, duration, events, note) in review_specs.items():
        samples = _render_review(events, duration, cues)
        path = review_directory / file_name
        _write_pcm_wav(path, samples)
        review_manifest[review_name] = {
            "path": path.relative_to(output_directory).as_posix(),
            "sha256": _sha256(path),
            "format": {"sample_rate_hz": SAMPLE_RATE, "channels": 1, "sample_width_bits": 16, "encoding": "PCM"},
            "duration_s": duration,
            "events": [{"start_s": start, "cue": cue} for start, cue in events],
            "note": note,
        }

    try:
        generator_display_path = generator_path.relative_to(repository_root).as_posix()
    except ValueError:
        generator_display_path = generator_path.as_posix()
    manifest = {
        "schema_version": 2,
        "synthesis_revision": SYNTHESIS_REVISION,
        "supersedes_synthesis_revision": 1,
        "revision_goal": "low_noise_discrete_semantic_syllables",
        "user_feedback_addressed": [
            "remove_persistent_broadband_noise_from_action_cues",
            "make_each_mechanical_and_energy_syllable_intent_explicit",
        ],
        "stage": "phase_one_audio_audition_pending_human_approval",
        "runtime_written": False,
        "generator": {"path": generator_display_path, "sha256": _sha256(generator_path)},
        "determinism": {"fixed_seed_per_cue": True, "timestamp_free": True},
        "approval_required_before_runtime_integration": True,
        "audio_contract": {
            "sample_rate_hz": SAMPLE_RATE,
            "channels": 1,
            "sample_width_bits": 16,
            "encoding": "PCM",
            "target_peak_sample": PCM_PEAK,
            "target_peak_dbfs": round(20.0 * math.log10(PCM_PEAK / 32767.0), 4),
            "language_or_voice": False,
            "skill2_tracking_silence_s": 3.0,
        },
        "cues": cue_manifest,
        "reviews": review_manifest,
    }
    manifest_path = output_directory / "combat_robot_main_battle_elite_audio_audition_manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {len(cue_manifest)} cues and {len(review_manifest)} reviews in {output_directory}")
    print(f"Manifest: {manifest_path}")


if __name__ == "__main__":
    main()
