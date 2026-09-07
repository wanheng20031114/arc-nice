"""Reproduce native threaded texture corruption without loading any game code.

Run with --renderer headless or gl_compatibility. Each fresh process loads the
same SpriteFrames resource with dependency workers disabled, then enabled.
An affected Godot Dummy renderer intentionally makes this diagnostic exit 1.
Generated fixtures and logs live under --output, outside the game resource set.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


PROBE_SCRIPT = '''extends SceneTree

var _sub_threads := false

func _initialize() -> void:
	_sub_threads = "--sub-threads" in OS.get_cmdline_user_args()
	_run.call_deferred()

func _run() -> void:
	var started := Time.get_ticks_msec()
	var error := ResourceLoader.load_threaded_request("res://frames.tres", "SpriteFrames", _sub_threads)
	if error != OK:
		quit(2)
		return
	while ResourceLoader.load_threaded_get_status("res://frames.tres") == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
	var loaded := ResourceLoader.load_threaded_get("res://frames.tres") as SpriteFrames
	if loaded == null:
		quit(3)
		return
	await process_frame
	await process_frame
	var valid := 0
	var count := loaded.get_frame_count(&"default")
	for index in count:
		var pixels := loaded.get_frame_texture(&"default", index).get_image()
		if pixels != null and pixels.get_size() == Vector2i(4, 4):
			valid += 1
	print("THREADED_TEXTURE_RESULT ", JSON.stringify({"sub_threads": _sub_threads,
		"expected": count, "valid": valid, "elapsed_ms": Time.get_ticks_msec() - started}))
	loaded = null
	await process_frame
	await process_frame
	quit(0 if valid == count else 1)
'''


def write_fixture(directory: Path, count: int) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Native threaded texture probe"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8"
    )
    (directory / "probe.gd").write_text(PROBE_SCRIPT, encoding="utf-8")
    pixels = ", ".join(map(str, [40, 80, 120, 255] * 16))
    texture = (
        '[gd_resource type="ImageTexture" load_steps=2 format=3]\n\n'
        '[sub_resource type="Image" id="Image_pixels"]\n'
        f'data = {{"data": PackedByteArray({pixels}), "format": "RGBA8", '
        '"height": 4, "mipmaps": false, "width": 4}\n\n'
        '[resource]\nimage = SubResource("Image_pixels")\n'
    )
    for index in range(count):
        (directory / f"texture_{index}.tres").write_text(texture, encoding="utf-8")
    external = "\n".join(
        f'[ext_resource type="Texture2D" path="res://texture_{i}.tres" id="{i + 1}"]'
        for i in range(count)
    )
    frames = ",\n".join(
        '{"duration": 1.0, "texture": ExtResource("%d")}' % (i + 1) for i in range(count)
    )
    (directory / "frames.tres").write_text(
        f'[gd_resource type="SpriteFrames" load_steps={count + 1} format=3]\n\n'
        f'{external}\n\n[resource]\nanimations = [{{"frames": [{frames}], '
        '"loop": true, "name": &"default", "speed": 5.0}]\n', encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=shutil.which("godot") or "godot")
    parser.add_argument("--renderer", choices=("headless", "gl_compatibility"), default="headless")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--textures", type=int, default=512)
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()
    if args.textures < 1 or args.repeat < 1:
        parser.error("--textures and --repeat must be positive")
    output = args.output.resolve()
    project = output / "native_project"
    write_fixture(project, args.textures)
    rows = []
    for iteration in range(args.repeat):
        for sub_threads in (False, True):
            command = [args.godot, "--path", str(project), "--script", "res://probe.gd"]
            if args.renderer == "headless":
                command += ["--headless"]
            else:
                command += ["--rendering-method", args.renderer, "--resolution", "64x64", "--position", "30000,30000"]
            if sub_threads:
                command += ["--", "--sub-threads"]
            log = output / f"{iteration}_sub_threads_{str(sub_threads).lower()}.log"
            started = time.monotonic()
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    command, stdout=stream, stderr=subprocess.STDOUT,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
                with (output / "pids.txt").open("a", encoding="utf-8") as pids:
                    pids.write(f"{process.pid}\n")
                try:
                    code = process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    code = 124
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
            native_results = [json.loads(line.removeprefix("THREADED_TEXTURE_RESULT "))
                              for line in lines if line.startswith("THREADED_TEXTURE_RESULT ")]
            row = {"renderer": args.renderer, "sub_threads": sub_threads, "pid": process.pid,
                   "exit_code": code, "wall_ms": round((time.monotonic() - started) * 1000),
                   "errors": sum(line.startswith("ERROR:") for line in lines),
                   "warnings": sum(line.startswith("WARNING:") for line in lines),
                   "native_results": native_results, "log": log.name}
            rows.append(row)
            print(json.dumps(row), flush=True)
    (output / "results.json").write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    return int(any(
        row["exit_code"] or row["errors"] or row["warnings"]
        or len(row["native_results"]) != 1
        or row["native_results"][0]["expected"] != args.textures
        or row["native_results"][0]["valid"] != args.textures
        for row in rows
    ))


if __name__ == "__main__":
    raise SystemExit(main())
