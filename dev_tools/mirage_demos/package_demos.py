"""Package the six actual Godot recordings, preserving frame timing and chapters."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "reports/mirage_demos/2026-09-07"
CLIPS = [
    ("01-lobby-teams.mp4", "房间选队与开局"),
    ("02-map-tour.mp4", "全图与区域漫游"),
    ("03-weapons.mp4", "买枪、丢枪与换弹"),
    ("04-damage.mp4", "身体命中与爆头"),
    ("05-visibility.mp4", "掩体与视野遮挡"),
    ("06-map-issues.mp4", "当前地图问题复现"),
]


def probe(path: Path) -> dict:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        check=True, capture_output=True, encoding="utf-8",
    )
    return json.loads(result.stdout)


def main() -> None:
    inputs: list[str] = []
    filters: list[str] = []
    metadata = [";FFMETADATA1", "title=Mirage 2D PVP 实机演示", "comment=实际 Godot 场景；自动操作与固定靶演练"]
    records = []
    frame_cursor = 0
    for index, (filename, title) in enumerate(CLIPS):
        path = OUT / filename
        info = probe(path)
        video = next(s for s in info["streams"] if s["codec_type"] == "video")
        audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
        assert (video["width"], video["height"], video["r_frame_rate"]) == (1152, 648, "30/1")
        assert (audio["sample_rate"], audio["channels"]) == ("48000", 2)
        frames = int(video["nb_frames"])
        duration = frames / 30
        input_range = "full" if video["color_range"] == "pc" else "limited"
        inputs += ["-i", str(path)]
        filters += [
            f"[{index}:v]scale=in_range={input_range}:out_range=limited,format=yuv420p,setsar=1,setpts=PTS-STARTPTS[v{index}]",
            f"[{index}:a]apad=whole_dur={duration:.9f},atrim=duration={duration:.9f},asetpts=PTS-STARTPTS[a{index}]",
        ]
        metadata += ["[CHAPTER]", "TIMEBASE=1/30", f"START={frame_cursor}", f"END={frame_cursor + frames}", f"title={index + 1:02d} / {title}"]
        records.append({
            "file": filename, "title": title, "frames": frames,
            "duration_seconds": duration, "starts_at_seconds": frame_cursor / 30,
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
        frame_cursor += frames
    filters.append("".join(f"[v{i}][a{i}]" for i in range(len(CLIPS))) + f"concat=n={len(CLIPS)}:v=1:a=1[v][a]")
    metadata_path = OUT / "chapters.ffmetadata"
    metadata_path.write_text("\n".join(metadata) + "\n", encoding="utf-8")
    combined = OUT / "00-full-demo.mp4"
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "warning", *inputs,
        "-i", str(metadata_path), "-filter_complex", ";".join(filters),
        "-map", "[v]", "-map", "[a]", "-map_metadata", "6", "-map_chapters", "6",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p", "-color_range", "tv",
        "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(combined),
    ]
    with (OUT / "compilation-encode.log").open("w", encoding="utf-8") as log:
        subprocess.run(command, check=True, stdout=log, stderr=log)
    output_info = probe(combined)
    combined_video = next(s for s in output_info["streams"] if s["codec_type"] == "video")
    assert int(combined_video["nb_frames"]) == frame_cursor
    assert combined_video["pix_fmt"] == "yuv420p"
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(combined), "-f", "null", "-"], check=True)
    report = {
        "recording_date": "2026-09-07", "engine": "Godot 4.6.3 MovieMaker",
        "resolution": [1152, 648], "fps": 30,
        "disclosure": "片段 01 为双进程 LAN；其余使用实际地图与玩法的自动镜头或脚本输入。固定靶与起点由演示脚本布置。MovieMaker 离线录制帧率不代表运行性能。",
        "clips": records,
        "compilation": {"file": combined.name, "frames": frame_cursor, "duration_seconds": frame_cursor / 30,
                        "bytes": combined.stat().st_size, "sha256": hashlib.sha256(combined.read_bytes()).hexdigest(),
                        "full_decode_passed": True},
    }
    (OUT / "demo-index.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
