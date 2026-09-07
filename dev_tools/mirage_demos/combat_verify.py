"""Verify the two actual gameplay recordings and combine their measured results."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "reports/mirage_demos/2026-09-07"


def mp4_atoms(path: Path) -> list[str]:
    result = []
    with path.open("rb") as source:
        while data := source.read(8):
            if len(data) != 8:
                break
            length, name = struct.unpack(">I4s", data)
            header_size = 8
            if length == 1:
                length = struct.unpack(">Q", source.read(8))[0]
                header_size = 16
            result.append(name.decode("ascii"))
            if length == 0:
                break
            source.seek(length - header_size, 1)
    return result


def verify(case: str, stem: str) -> dict:
    result = json.loads((OUTPUT / f"combat-{case}-result.json").read_text("utf-8"))
    assert not result["failures"], result["failures"]
    movie = OUTPUT / f"{stem}.mp4"
    poster = OUTPUT / f"{stem}-poster.png"
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(movie)
    ], text=True, encoding="utf-8"))
    video = next(stream for stream in probe["streams"] if stream["codec_type"] == "video")
    audio = next(stream for stream in probe["streams"] if stream["codec_type"] == "audio")
    assert video["codec_name"] == "h264"
    assert video["pix_fmt"] == "yuv420p"
    assert video["r_frame_rate"] == "30/1"
    duration = float(probe["format"]["duration"])
    assert 20.0 <= duration <= 35.0
    atoms = mp4_atoms(movie)
    assert atoms.index("moov") < atoms.index("mdat"), "MP4 must support faststart"
    assert poster.exists()
    if case == "weapons":
        inventory = result["final_inventory"]
        assert inventory["current_weapon"] == "ak"
        assert (inventory["ammo"], inventory["reserve"], inventory["money"]) == (30, 87, 1300)
        assert {row["action"] for row in result["actions"]} >= {
            "open_buy", "buy_ak", "drop", "pickup", "slot1", "slot2", "reload"
        }
    else:
        assert [(row["weapon"], row["headshot"], row["health_before"], row["health_after"])
                for row in result["observed_damage"]] == [
                    ("deagle", False, 100, 75), ("deagle", True, 100, 0),
                    ("ak", False, 100, 80), ("ak", True, 100, 0)]
    return {
        "file": movie.name,
        "poster": poster.name,
        "sha256": hashlib.sha256(movie.read_bytes()).hexdigest(),
        "bytes": movie.stat().st_size,
        "video": {key: video[key] for key in ("codec_name", "width", "height", "pix_fmt", "r_frame_rate")},
        "audio": {key: audio[key] for key in ("codec_name", "sample_rate", "channels")},
        "duration_seconds": duration,
        "faststart_verified": True,
        "mp4_atom_order": atoms,
        "production_results": result,
    }


if __name__ == "__main__":
    summary = {
        "title": "Mirage PVP 实机演示：枪械操作与身体 / 爆头伤害",
        "recording_date": "2026-09-07",
        "engine": "Godot 4.6.3 MovieMaker, fixed 30 fps",
        "source_scene": "res://scene/pvp/mirage_pvp.tscn",
        "director_scene": "res://dev_tools/mirage_demos/combat_demo.tscn",
        "recording_command": "Godot.exe --path <project> --resolution 1280x720 --fixed-fps 30 --write-movie <clip>.avi res://dev_tools/mirage_demos/combat_demo.tscn -- --case=weapons|damage --result=<json>",
        "encoding": "libx264, CRF 18, limited-range yuv420p, AAC 160 kbps, +faststart; full-to-limited range conversion only, no resizing",
        "resolution_note": "MovieMaker initializes at the user's 1152x648 window before the director sets its logical viewport to 1280x720. Encoded width/height below are ffprobe measurements; videos are not upscaled.",
        "fixture_disclosure": "本地双角色演练，不声称在线对战录像。录像脚本输入 B/G/F/R/1/2 和点击实际购买按钮；伤害段将现有角色摆到中路固定靶场，重置靶子 / 开始回合。所有扣款、库存、射击、物理命中、扣血和换弹均由原有玩法代码执行，未直接修改目标血量来制造命中。",
        "action_sampling_note": "输入事件记录在排队后立即采样，此时下一个主机物理 tick 可能尚未消费该事件；后续断言和最终库存验证实际结果。observed_damage 则在实际生命值下降后记录。",
        "clips": [verify("weapons", "03-weapons"), verify("damage", "04-damage")],
    }
    destination = OUTPUT / "demo-combat.json"
    destination.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(destination), "clips": [{"file": clip["file"], "duration": clip["duration_seconds"], "width": clip["video"]["width"], "height": clip["video"]["height"], "failures": clip["production_results"]["failures"]} for clip in summary["clips"]]}, ensure_ascii=False))
