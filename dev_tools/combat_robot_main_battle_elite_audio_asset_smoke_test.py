#!/usr/bin/env python3
"""Fail-closed audit for the main battle robot's approved runtime WAV set."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import wave


EXPECTED_DURATIONS = {
    "combat_robot_main_battle_elite_stomp_a.wav": 0.25,
    "combat_robot_main_battle_elite_stomp_b.wav": 0.25,
    "combat_robot_main_battle_elite_hit_a.wav": 0.16,
    "combat_robot_main_battle_elite_hit_b.wav": 0.18,
    "combat_robot_main_battle_elite_normal_windup.wav": 0.35,
    "combat_robot_main_battle_elite_normal_double_slash.wav": 0.78,
    "combat_robot_main_battle_elite_skill1_charge.wav": 0.56,
    "combat_robot_main_battle_elite_skill1_dash.wav": 0.75,
    "combat_robot_main_battle_elite_skill1_circle_slash.wav": 0.78,
    "combat_robot_main_battle_elite_skill2_takeoff.wav": 0.46,
    "combat_robot_main_battle_elite_skill2_drop_bilateral_slash.wav": 0.76,
    "combat_robot_main_battle_elite_death.wav": 1.20,
}
EXPECTED_SHA256 = {
    "combat_robot_main_battle_elite_stomp_a.wav": "1cda1849e86906e5276c1b289d95178bbccaa491bf62d549c036f66e04b0ec11",
    "combat_robot_main_battle_elite_stomp_b.wav": "e919785b32576340116ffb140d823c330b95d2105aa0964bfffb85fe78c2420b",
    "combat_robot_main_battle_elite_hit_a.wav": "9dee42ab9b7af9bb1a2f287a7af2cb0142c786d7fc9c698b51d09987890c28c2",
    "combat_robot_main_battle_elite_hit_b.wav": "a348b5ee16ac72076dac37ff40f60274f7eabd6ea5667b9c3c833ecea85f8e83",
    "combat_robot_main_battle_elite_normal_windup.wav": "dde352ccb6fcd3458ef7938fce47e20354ff58c6fce9fefcf54f4db148661e1b",
    "combat_robot_main_battle_elite_normal_double_slash.wav": "cf800dd58bb0806a8d4ec6e36ed5763f4e854052882d72b0f443b6c6a85590f4",
    "combat_robot_main_battle_elite_skill1_charge.wav": "ed8a079bd9fa0f3aa3d9d391fce595d78935a233f90ff70fb7fe486052a38ede",
    "combat_robot_main_battle_elite_skill1_dash.wav": "cec92a32f4e9910234c804d4f87c3439b2f05267715b8519406bf9a34f44fb45",
    "combat_robot_main_battle_elite_skill1_circle_slash.wav": "90c4f6e6c3ef37c036e19c8f04fddf892d14c81377173075f185b00fd339f4c5",
    "combat_robot_main_battle_elite_skill2_takeoff.wav": "16597b772547cef433f8e8a77f2a6f2797dca7121011461c369cf19fea426dd7",
    "combat_robot_main_battle_elite_skill2_drop_bilateral_slash.wav": "0f5a634fe0c97b2bf65c88118efe76c934f14201797301dae8934858cc932ce5",
    "combat_robot_main_battle_elite_death.wav": "3aa9d086bb92dd1a2662942fe5e56e5d1d80189bfb98464d8ba699c1fb379a8d",
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _audit_wav(path: Path, duration: float) -> None:
    with wave.open(str(path), "rb") as source:
        assert source.getframerate() == 44_100
        assert source.getnchannels() == 1
        assert source.getsampwidth() == 2
        assert source.getcomptype() == "NONE"
        assert source.getnframes() == round(duration * 44_100)
        samples = struct.unpack(f"<{source.getnframes()}h", source.readframes(source.getnframes()))
    peak = max(abs(sample) for sample in samples)
    dc = sum(samples) / len(samples) / 32767.0
    assert peak == 23_000
    assert all(sample not in (-32768, 32767) for sample in samples)
    assert abs(dc) < 0.000002
    assert samples[0] == 0 and samples[-1] == 0
    assert math.isfinite(math.sqrt(sum(sample * sample for sample in samples) / len(samples)))


def main() -> None:
    repository_root = Path(__file__).resolve().parent.parent
    generator = repository_root / "dev_tools" / "generate_combat_robot_main_battle_elite_audio.py"
    runtime_audio = repository_root / "resources" / "audio"
    with tempfile.TemporaryDirectory(prefix="main_battle_audio_a_") as first_temp, tempfile.TemporaryDirectory(
        prefix="main_battle_audio_b_"
    ) as second_temp:
        first = Path(first_temp)
        second = Path(second_temp)
        subprocess.run([sys.executable, str(generator), str(first)], check=True)
        subprocess.run([sys.executable, str(generator), str(second)], check=True)
        first_files = {path.relative_to(first).as_posix(): _sha256(path) for path in first.rglob("*") if path.is_file()}
        second_files = {path.relative_to(second).as_posix(): _sha256(path) for path in second.rglob("*") if path.is_file()}
        assert len(first_files) == 18
        assert first_files == second_files
        manifest = json.loads((first / "combat_robot_main_battle_elite_audio_audition_manifest.json").read_text(encoding="utf-8"))
        assert manifest["synthesis_revision"] == 2
        assert manifest["runtime_written"] is False
        assert manifest["approval_required_before_runtime_integration"] is True
        for cue_record in manifest["cues"].values():
            cue_name = Path(cue_record["path"]).name
            assert _sha256(runtime_audio / cue_name) == cue_record["sha256"]

    assert {path.name for path in runtime_audio.glob("combat_robot_main_battle_elite_*.wav")} == set(EXPECTED_DURATIONS)
    for file_name, duration in EXPECTED_DURATIONS.items():
        path = runtime_audio / file_name
        assert _sha256(path) == EXPECTED_SHA256[file_name]
        _audit_wav(path, duration)
        import_text = (runtime_audio / f"{file_name}.import").read_text(encoding="utf-8")
        assert 'importer="wav"' in import_text
        assert "edit/loop_mode=0" in import_text
        assert "edit/normalize=false" in import_text
        assert "compress/mode=0" in import_text
    print("COMBAT_ROBOT_MAIN_BATTLE_ELITE_AUDIO_ASSET_SMOKE_TEST_OK")


if __name__ == "__main__":
    main()
