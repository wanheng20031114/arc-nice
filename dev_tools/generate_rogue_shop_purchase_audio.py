#!/usr/bin/env python3
"""Generate the deterministic underground-shop purchase confirmation sound."""

from __future__ import annotations

import math
from pathlib import Path
import random
import struct
import wave


SAMPLE_RATE = 44_100
DURATION_SECONDS = 0.29
TARGET_PEAK_DBFS = -3.5
PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = (
    PROJECT_ROOT / "resources/audio/ui/rogue_shop_purchase_success.wav"
)


def _smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def _confirmation_note(
    time: float,
    start: float,
    frequency: float,
    duration: float,
) -> float:
    """A short, warm triangle-like bell without a long fantasy chime tail."""
    local_time = time - start
    if local_time < 0.0 or local_time >= duration:
        return 0.0
    attack = _smoothstep(local_time / 0.0035)
    release = _smoothstep((duration - local_time) / 0.035)
    decay = math.exp(-45.0 * local_time)
    phase = math.tau * frequency * local_time
    body = (
        math.sin(phase)
        + 0.13 * math.sin(phase * 3.0)
        + 0.035 * math.sin(phase * 5.0)
    )
    return body * attack * release * decay


def _build_samples() -> list[float]:
    """Build a quiet coin touch followed by an ascending G5-B5 confirmation."""
    sample_count = round(DURATION_SECONDS * SAMPLE_RATE)
    random_source = random.Random(0x5A0C0A6)
    samples: list[float] = []

    # Two one-pole filters form a narrow, deterministic high-frequency
    # contact texture. It reads as a small coin touching a counter rather
    # than a cash-register slam or a slot-machine payout.
    contact_high = 0.0
    contact_low = 0.0
    high_alpha = 1.0 - math.exp(-math.tau * 5_200.0 / SAMPLE_RATE)
    low_alpha = 1.0 - math.exp(-math.tau * 1_350.0 / SAMPLE_RATE)

    for index in range(sample_count):
        time = index / SAMPLE_RATE
        noise = random_source.uniform(-1.0, 1.0)
        contact_high += high_alpha * (noise - contact_high)
        contact_low += low_alpha * (noise - contact_low)
        contact_band = contact_high - contact_low

        contact_time = time - 0.031
        contact = 0.0
        if 0.0 <= contact_time < 0.085:
            contact_attack = _smoothstep(contact_time / 0.0015)
            contact_envelope = contact_attack * math.exp(-72.0 * contact_time)
            metallic = (
                math.sin(math.tau * 2_180.0 * contact_time)
                + 0.42 * math.sin(math.tau * 3_370.0 * contact_time + 0.4)
            )
            contact = (0.24 * contact_band + 0.12 * metallic) * contact_envelope

        first_note = _confirmation_note(time, 0.052, 783.9909, 0.110)
        second_note = _confirmation_note(time, 0.108, 987.7666, 0.110)

        # A very short low body gives the confirmation a physical counter
        # presence while staying far below the two readable notes.
        body_time = time - 0.040
        counter_body = 0.0
        if 0.0 <= body_time < 0.090:
            body_attack = _smoothstep(body_time / 0.004)
            counter_body = (
                math.sin(math.tau * 392.0 * body_time)
                * body_attack
                * math.exp(-31.0 * body_time)
            )

        samples.append(
            contact
            + 0.34 * first_note
            + 0.31 * second_note
            + 0.055 * counter_body
        )

    return samples


def _write_wav(path: Path, samples: list[float]) -> tuple[float, float]:
    source_peak = max(max(abs(sample) for sample in samples), 1e-9)
    target_peak = math.pow(10.0, TARGET_PEAK_DBFS / 20.0)
    scale = target_peak / source_peak
    scaled_samples = [
        max(-1.0, min(1.0, sample * scale))
        for sample in samples
    ]
    pcm = bytearray()
    for sample in scaled_samples:
        pcm.extend(struct.pack("<h", round(sample * 32_767)))

    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)

    peak = max(abs(sample) for sample in scaled_samples)
    rms = math.sqrt(
        sum(sample * sample for sample in scaled_samples)
        / max(len(scaled_samples), 1)
    )
    return 20.0 * math.log10(peak), 20.0 * math.log10(max(rms, 1e-12))


def main() -> None:
    peak_dbfs, rms_dbfs = _write_wav(OUTPUT_PATH, _build_samples())
    relative_path = OUTPUT_PATH.relative_to(PROJECT_ROOT)
    print(
        f"Generated {relative_path} "
        f"({DURATION_SECONDS:.2f}s, {SAMPLE_RATE} Hz, mono PCM16, "
        f"peak {peak_dbfs:.1f} dBFS, RMS {rms_dbfs:.1f} dBFS)."
    )


if __name__ == "__main__":
    main()
