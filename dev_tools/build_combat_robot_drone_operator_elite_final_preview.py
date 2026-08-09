#!/usr/bin/env python3
"""Assemble the fourth-gate final candidate for the elite drone operator.

This script only composes already approved native strips.  It never samples
ImageGen pixels and refuses to write outside ``dev_assets``.  Runtime assets,
scenes, configs, codex data, networking, and pools remain untouched until the
fourth human gate is approved.
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageSequence


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "combat_robot_drone_operator_elite"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"

ANIMATION_SELECTION = SOURCE_DIR / "combat_robot_drone_operator_elite_animation_selection.json"
EFFECT_MANIFEST = SOURCE_DIR / "combat_robot_drone_operator_elite_effect_manifest.json"
EFFECT_REPORT = PREVIEW_DIR / "combat_robot_drone_operator_elite_effect_preview_report.json"
EFFECT_STABILITY = PREVIEW_DIR / "combat_robot_drone_operator_elite_effect_stability_report.json"

EXPECTED_CERTIFICATE_SHA = {
    ANIMATION_SELECTION: "bb4930ffa196f5adc9327a79d1e9516c5957901d2ae549aaa73de4a07eed146b",
    EFFECT_MANIFEST: "a0960eb688b1a351c7f21ff611ee54f0bd95a994c48046c08d4c4de44e991acc",
    EFFECT_REPORT: "b1896e341ba8f53969019539a0029d60d1bb59e8a5da1b72173c743ba6cdc366",
    EFFECT_STABILITY: "7c136883d4a50be7d215b47831125af903f3e704d9012627557322a542b45baf",
}

SELECTED_INPUTS = {
    "M1": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_m1_candidate_native_strip.png",
        "sha256": "baa1e2dbd34a74dd91c1bd2a885640804d0d251fbeec29603e0a975fa163cb03",
        "rgba_sha256": "6038dff07b83674bf2488b42afb06fc5cc86f9f321341eab3adbf1f4777e0b83",
        "size": (256, 32),
    },
    "P1": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_p1_candidate_native_strip.png",
        "sha256": "5ba012793ee2389ced8bb6d1e39eb7e3231fc44b94de1c0115e36013fb468272",
        "rgba_sha256": "92e070440c613473c0b29d9bf4312e91fb3a4f3253d9d01c0b330a82ebee4c50",
        "size": (96, 32),
    },
    "K2": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_k2_candidate_native_strip.png",
        "sha256": "b0e6ac9606e0806aff0b5b5782cb0060b80ce63c5915e035611b3c8022a7998f",
        "rgba_sha256": "376841f107b75da78691c883b607b7296d0862495fd9db15e5eb245fa825c0e6",
        "size": (256, 32),
    },
    "V1": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_v1_candidate_native_strip.png",
        "sha256": "6e3190f928bc5d49fa654bba1f9edd2ee6e071e4d9d21420a8b8a7256fb94c0d",
        "rgba_sha256": "95bf4f654b11db71bce990a853947e49a259e6c2736165fe87e81c30c29706f6",
        "size": (64, 16),
    },
    "T1": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_t1_candidate_native_strip.png",
        "sha256": "8be355f9b24d7920b5cb350addd9af289b698e7c672f39ff7db5e77f19d6d747",
        "rgba_sha256": "3fd46a897ff64acf125ed0f36266e0a6f2a5d83eda6454f28bf25d079e2b5682",
        "size": (64, 16),
    },
    "X1": {
        "path": SOURCE_DIR / "combat_robot_drone_operator_elite_x1_candidate_native_strip.png",
        "sha256": "c3e2ba275b9151a897b8f0411c59dd7acd9ebc0e37e26bc242e960a13ea571b1",
        "rgba_sha256": "c5245eb05a81ebca68fa46129f07d0cb0793bb95eccca37c104fce79a4427965",
        "size": (512, 64),
    },
}

ORDINARY = {
    "operator": ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_drone_operator.png",
    "drone": ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_suicide_drone.png",
    "target": ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_drone_target_marker.png",
    "explosion": ROOT / "resources" / "texture" / "enemy" / "mechanical_life" / "combat_robot_mechanical_explosion.png",
}
EXPECTED_ORDINARY_SHA = {
    "operator": "9f987244da55ed3d89bae38a3eda40998518dcd3935f2bb7a1551eb94cd15395",
    "drone": "21fe9ddf09a72b080a06d346cb47ab4f3572852d9f0dae3242bc4476a7b1e06b",
    "target": "a2694c49e2dc04a5a7a46ebc7be5fb4078ea78c1dc4282e68ad4f6557b501436",
    "explosion": "6edc04d40612bb626b9d0880c250f869cd7f7bdd892296887dd0b57dd058e589",
}

FINAL_SELECTION = SOURCE_DIR / "combat_robot_drone_operator_elite_final_selection.json"
BODY_CANDIDATE = SOURCE_DIR / "combat_robot_drone_operator_elite_final_candidate.png"
DRONE_CANDIDATE = SOURCE_DIR / "combat_robot_suicide_drone_elite_final_candidate.png"
TARGET_CANDIDATE = SOURCE_DIR / "combat_robot_drone_target_marker_elite_final_candidate.png"
EXPLOSION_CANDIDATE = SOURCE_DIR / "combat_robot_mechanical_explosion_elite_final_candidate.png"
FINAL_MANIFEST = SOURCE_DIR / "combat_robot_drone_operator_elite_final_candidate_manifest.json"
FINAL_REPORT = PREVIEW_DIR / "combat_robot_drone_operator_elite_final_preview_report.json"
FINAL_COMPARISON = PREVIEW_DIR / "combat_robot_drone_operator_elite_final_comparison.png"
SEQUENCE_GIF = PREVIEW_DIR / "combat_robot_drone_operator_elite_deploy_flight_explosion.gif"
SEQUENCE_CONTACT = PREVIEW_DIR / "combat_robot_drone_operator_elite_deploy_flight_explosion_contact.png"

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BG = (13, 19, 31, 255)
REVIEW_PANEL = (20, 29, 43, 255)
REVIEW_TEXT = (226, 229, 226, 255)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_dev_output(path: Path) -> None:
    resolved = path.resolve()
    dev_root = (ROOT / "dev_assets").resolve()
    if resolved != dev_root and dev_root not in resolved.parents:
        raise AssertionError(f"final preview builder refused output {path}")


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def save_json(payload: dict, path: Path) -> None:
    assert_dev_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_rgba(path: Path, size: tuple[int, int] | None = None) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if size is not None and image.size != size:
        raise AssertionError(f"{path.name} size {image.size} != {size}")
    if not {pixel[3] for pixel in image.getdata()} <= {0, 255}:
        raise AssertionError(f"{path.name} alpha is not binary")
    if any(pixel[:3] != (0, 0, 0) for pixel in image.getdata() if pixel[3] == 0):
        raise AssertionError(f"{path.name} has dirty transparent RGB")
    return image


def split_frames(sheet: Image.Image, cell: int, count: int, row: int = 0) -> list[Image.Image]:
    return [sheet.crop((index * cell, row * cell, (index + 1) * cell, (row + 1) * cell)) for index in range(count)]


def build_strip(frames: list[Image.Image], cell: int) -> Image.Image:
    result = Image.new("RGBA", (cell * len(frames), cell), TRANSPARENT)
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * cell, 0))
    return result


def validate_inputs() -> dict[str, Image.Image]:
    for path, expected in EXPECTED_CERTIFICATE_SHA.items():
        if sha256(path) != expected:
            raise AssertionError(f"certificate drifted: {path.name}")
    animation = json.loads(ANIMATION_SELECTION.read_text(encoding="utf-8"))
    selected_animation = animation.get("approved_selection") or {}
    if {key: selected_animation[key]["selection"] for key in ("move", "deploy", "death")} != {"move": "M1", "deploy": "P1", "death": "K2"}:
        raise AssertionError("animation certificate is not M1/P1/K2")
    effects = json.loads(EFFECT_MANIFEST.read_text(encoding="utf-8"))
    if effects.get("approved_selection") is not None or effects.get("runtime_written") is not False:
        raise AssertionError("third-gate evidence was mutated before final selection")
    loaded = {}
    for key, payload in SELECTED_INPUTS.items():
        path = payload["path"]
        if sha256(path) != payload["sha256"]:
            raise AssertionError(f"selected strip PNG drifted: {key}")
        image = load_rgba(path, payload["size"])
        if rgba_sha(image) != payload["rgba_sha256"]:
            raise AssertionError(f"selected strip RGBA drifted: {key}")
        loaded[key] = image
    for key, path in ORDINARY.items():
        if sha256(path) != EXPECTED_ORDINARY_SHA[key]:
            raise AssertionError(f"ordinary runtime source drifted: {key}")
    return loaded


def assemble_candidates(selected: dict[str, Image.Image]) -> dict[str, Image.Image]:
    body = Image.new("RGBA", (256, 96), TRANSPARENT)
    body.alpha_composite(selected["M1"], (0, 0))
    body.alpha_composite(selected["P1"], (0, 32))
    body.alpha_composite(selected["K2"], (0, 64))
    return {
        "operator": body,
        "drone": selected["V1"].copy(),
        "target": selected["T1"].copy(),
        "explosion": selected["X1"].copy(),
    }


def assert_exact_regions(selected: dict[str, Image.Image], candidates: dict[str, Image.Image]) -> None:
    body = candidates["operator"]
    if body.crop((0, 0, 256, 32)).tobytes() != selected["M1"].tobytes():
        raise AssertionError("final move row is not exact M1")
    if body.crop((0, 32, 96, 64)).tobytes() != selected["P1"].tobytes():
        raise AssertionError("final deploy cells are not exact P1")
    if any(pixel != TRANSPARENT for pixel in body.crop((96, 32, 256, 64)).getdata()):
        raise AssertionError("unused deploy cells are not all-zero transparent")
    if body.crop((0, 64, 256, 96)).tobytes() != selected["K2"].tobytes():
        raise AssertionError("final death row is not exact K2")
    for group, key in (("drone", "V1"), ("target", "T1"), ("explosion", "X1")):
        if candidates[group].tobytes() != selected[key].tobytes():
            raise AssertionError(f"final {group} is not exact {key}")


def candidate_metrics(candidates: dict[str, Image.Image]) -> dict:
    body = candidates["operator"]
    body_rows = {"move": split_frames(body, 32, 8, 0), "deploy": split_frames(body, 32, 3, 1), "death": split_frames(body, 32, 8, 2)}
    metrics = {"operator": {}}
    for animation, frames in body_rows.items():
        entries = []
        for index, frame in enumerate(frames):
            bbox = frame.getchannel("A").getbbox()
            if bbox is None or bbox[2] - bbox[0] > 28 or bbox[3] - bbox[1] > 28 or bbox[3] != 28:
                raise AssertionError(f"final {animation}[{index}] registration contract failed: {bbox}")
            entries.append({"index": index, "bbox": list(bbox), "rgba_sha256": rgba_sha(frame)})
        metrics["operator"][animation] = entries
    effects = {"drone": (16, 4), "target": (16, 4), "explosion": (64, 8)}
    for group, (cell, count) in effects.items():
        entries = []
        for index, frame in enumerate(split_frames(candidates[group], cell, count)):
            bbox = frame.getchannel("A").getbbox()
            entries.append({"index": index, "bbox": list(bbox), "opaque_pixels": sum(pixel[3] == 255 for pixel in frame.getdata()), "alpha_sha256": hashlib.sha256(frame.getchannel("A").tobytes()).hexdigest(), "rgba_sha256": rgba_sha(frame)})
        metrics[group] = entries
    if any(entry["bbox"] != [2, 3, 14, 12] or entry["opaque_pixels"] != 71 for entry in metrics["drone"]):
        raise AssertionError("final drone 12x9 contract failed")
    if metrics["explosion"][4]["bbox"] != [4, 4, 60, 60]:
        raise AssertionError("final explosion 56px peak contract failed")
    return metrics


def compose_scaled(frame: Image.Image, scale: int, mirrored: bool = False) -> Image.Image:
    source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
    canvas = Image.new("RGBA", source.size, REVIEW_BG)
    canvas.alpha_composite(source)
    return canvas.convert("RGB").resize((source.width * scale, source.height * scale), Image.Resampling.NEAREST)


def fixed_palette(images: list[Image.Image]) -> tuple[list[tuple[int, int, int]], dict[tuple[int, int, int], int]]:
    colors = [REVIEW_BG[:3]]
    for image in images:
        for color in image.convert("RGB").getdata():
            if color not in colors:
                colors.append(color)
    if len(colors) > 256:
        raise AssertionError(f"GIF needs {len(colors)} colors")
    return colors, {color: index for index, color in enumerate(colors)}


def to_paletted(image: Image.Image, colors: list[tuple[int, int, int]], indices: dict[tuple[int, int, int], int]) -> Image.Image:
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    result.putpalette(palette)
    result.putdata([indices[color] for color in rgb.getdata()])
    return result


def save_exact_gif(
    frames: list[Image.Image],
    path: Path,
    fps: int,
    scale: int,
    mirrored: bool = False,
    durations_ms: list[int] | None = None,
) -> dict:
    assert_dev_output(path)
    expected = [compose_scaled(frame, scale, mirrored) for frame in frames]
    colors, indices = fixed_palette(expected)
    paletted = [to_paletted(frame, colors, indices) for frame in expected]
    duration = max(10, round(1000 / fps / 10) * 10)
    durations = durations_ms or [duration] * len(frames)
    if len(durations) != len(frames) or any(value <= 0 or value % 10 for value in durations):
        raise AssertionError(f"invalid GIF duration schedule for {path.name}")
    path.parent.mkdir(parents=True, exist_ok=True)
    paletted[0].save(path, save_all=True, append_images=paletted[1:], duration=durations, loop=0, optimize=False, disposal=2)
    expected_ticks = []
    for frame, frame_duration in zip(expected, durations, strict=True):
        expected_ticks.extend([frame] * (frame_duration // 10))
    decoded_ticks = []
    opened = Image.open(path)
    for frame in ImageSequence.Iterator(opened):
        rgb = frame.convert("RGB").copy()
        repeats = max(1, int(frame.info.get("duration", duration)) // 10)
        decoded_ticks.extend([rgb] * repeats)
    if len(decoded_ticks) != len(expected_ticks) or any(left.tobytes() != right.tobytes() for left, right in zip(decoded_ticks, expected_ticks, strict=True)):
        raise AssertionError(f"GIF exact decode failed: {path.name}")
    return {
        "path": rel(path),
        "sha256": sha256(path),
        "logical_frames": len(frames),
        "decoded_10ms_ticks": len(decoded_ticks),
        "fps_contract": fps,
        "duration_pattern_ms": durations[: min(3, len(durations))],
        "total_duration_ms": sum(durations),
        "mirrored": mirrored,
    }


def save_review_png(image: Image.Image, path: Path, scale: int) -> dict:
    upscaled = image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)
    save_png(upscaled, path)
    return {"path": rel(path), "sha256": sha256(path), "size": list(upscaled.size), "scale": scale}


def paste_center(canvas: Image.Image, sprite: Image.Image, center: tuple[float, float]) -> None:
    x = round(center[0] - sprite.width / 2)
    y = round(center[1] - sprite.height / 2)
    canvas.alpha_composite(sprite, (x, y))


def build_sequence(candidates: dict[str, Image.Image]) -> tuple[list[Image.Image], dict]:
    operator = candidates["operator"]
    move = split_frames(operator, 32, 8, 0)
    deploy = split_frames(operator, 32, 3, 1)
    drone = split_frames(candidates["drone"], 16, 4)
    target = split_frames(candidates["target"], 16, 4)
    explosion = split_frames(candidates["explosion"], 64, 8)

    review_fps = 30
    deploy_duration = 0.10
    distance = 80.0
    speed = 90.0
    flight_duration = distance / speed
    explosion_duration = 8.0 / 14.0
    arrival = deploy_duration + flight_duration
    total = arrival + explosion_duration
    frame_count = math.ceil(total * review_fps)
    start = (16.0, 32.0)
    destination = (96.0, 32.0)
    frames = []
    for index in range(frame_count):
        time = index / review_fps
        canvas = Image.new("RGBA", (144, 64), REVIEW_BG)
        if time < deploy_duration:
            operator_frame = deploy[min(2, int(time * 30.0))]
        else:
            operator_frame = move[int((time - deploy_duration) * 14.0) % 8]
        paste_center(canvas, operator_frame, start)

        if time < arrival:
            marker = target[int(time * 12.0) % 4]
            paste_center(canvas, marker, destination)
        if deploy_duration <= time < arrival:
            elapsed = time - deploy_duration
            progress = min(1.0, elapsed / flight_duration)
            center = (start[0] + (destination[0] - start[0]) * progress, start[1])
            drone_frame = drone[int(elapsed * 12.0) % 4]
            paste_center(canvas, drone_frame, center)
        elif time >= arrival:
            phase = min(7, int((time - arrival) * 14.0))
            paste_center(canvas, explosion[phase], destination)
        frames.append(canvas)
    return frames, {
        "review_fps": review_fps,
        "frame_count": frame_count,
        "deploy_duration": deploy_duration,
        "distance": distance,
        "drone_speed": speed,
        "flight_duration": flight_duration,
        "explosion_duration": explosion_duration,
        "total_duration": total,
        "start": list(start),
        "destination": list(destination),
        "target_marker_fixed_until_arrival": True,
        "absolute_linear_interpolation": True,
        "gameplay_physics_queries_added": 0,
    }


def build_comparison(candidates: dict[str, Image.Image]) -> Image.Image:
    ordinary = {key: load_rgba(path) for key, path in ORDINARY.items()}
    canvas = Image.new("RGBA", (1500, 1500), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    draw.text((20, 18), "Elite drone operator - final candidate (awaiting fourth human gate)", fill=REVIEW_TEXT, font=font)
    draw.text((20, 40), "O3 + M1/P1/K2 + V1/T1/X1 | runtime_written=false", fill=(151, 159, 164, 255), font=font)
    rows = (
        ("operator", 4, 90),
        ("drone", 12, 880),
        ("target", 12, 1090),
        ("explosion", 2, 1290),
    )
    for key, scale, top in rows:
        draw.text((20, top - 22), f"{key}: ordinary / elite", fill=REVIEW_TEXT, font=font)
        left = ordinary[key].resize((ordinary[key].width * scale, ordinary[key].height * scale), Image.Resampling.NEAREST)
        right = candidates[key].resize((candidates[key].width * scale, candidates[key].height * scale), Image.Resampling.NEAREST)
        canvas.alpha_composite(left, (20, top))
        x = min(760, 40 + left.width)
        canvas.alpha_composite(right, (x, top))
    return canvas


def build_sequence_contact(frames: list[Image.Image]) -> Image.Image:
    sample_indices = (0, 1, 2, 3, 10, 18, 26, 29, 30, 33, 37, 41, len(frames) - 1)
    scale = 2
    cell_width = 144 * scale
    cell_height = 64 * scale + 18
    columns = 5
    rows = math.ceil(len(sample_indices) / columns)
    canvas = Image.new("RGBA", (columns * cell_width, rows * cell_height), REVIEW_BG)
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    for slot, frame_index in enumerate(sample_indices):
        frame = frames[frame_index]
        column = slot % columns
        row = slot // columns
        x = column * cell_width
        y = row * cell_height
        scaled = frame.resize((144 * scale, 64 * scale), Image.Resampling.NEAREST)
        canvas.alpha_composite(scaled, (x, y))
        draw.text((x + 4, y + 64 * scale + 2), f"frame {frame_index}", fill=REVIEW_TEXT, font=font)
    return canvas


def main() -> None:
    selected = validate_inputs()
    candidates = assemble_candidates(selected)
    second = assemble_candidates(selected)
    if any(candidates[key].tobytes() != second[key].tobytes() for key in candidates):
        raise AssertionError("final in-memory rebuild drifted")
    assert_exact_regions(selected, candidates)
    metrics = candidate_metrics(candidates)

    selection_payload = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_final_selection",
        "stage": "final_selection_locked_pending_fourth_human_gate",
        "approved_anchor": "O3",
        "approved_animation_selection": {"move": "M1", "deploy": "P1", "death": "K2"},
        "approved_effect_selection": {"drone": "V1", "target": "T1", "explosion": "X1"},
        "selection_interpretation": "User entered V1 T1 T1; the third slot was interpreted as X1 because that slot accepts X1/X2 and the prior recommendation was X1.",
        "input_certificates": {rel(path): expected for path, expected in EXPECTED_CERTIFICATE_SHA.items()},
        "selected_native_inputs": {key: {"path": rel(payload["path"]), "sha256": payload["sha256"], "rgba_sha256": payload["rgba_sha256"]} for key, payload in SELECTED_INPUTS.items()},
        "final_human_approved": False,
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(selection_payload, FINAL_SELECTION)

    paths = {"operator": BODY_CANDIDATE, "drone": DRONE_CANDIDATE, "target": TARGET_CANDIDATE, "explosion": EXPLOSION_CANDIDATE}
    atlas_outputs = {}
    scales = {"operator": 8, "drone": 16, "target": 16, "explosion": 4}
    for key, image in candidates.items():
        save_png(image, paths[key])
        preview = PREVIEW_DIR / f"combat_robot_drone_operator_elite_final_{key}_{scales[key]}x.png"
        atlas_outputs[key] = {
            "native": {"path": rel(paths[key]), "sha256": sha256(paths[key]), "rgba_sha256": rgba_sha(image), "size": list(image.size)},
            "preview": save_review_png(image, preview, scales[key]),
        }

    animation_jobs = {
        "move": (split_frames(candidates["operator"], 32, 8, 0), 14, 16, True),
        "deploy": (split_frames(candidates["operator"], 32, 3, 1), 30, 16, False),
        "death": (split_frames(candidates["operator"], 32, 8, 2), 12, 16, False),
        "drone": (split_frames(candidates["drone"], 16, 4), 12, 16, True),
        "target": (split_frames(candidates["target"], 16, 4), 12, 16, True),
        "explosion": (split_frames(candidates["explosion"], 64, 8), 14, 4, False),
    }
    gif_outputs = {}
    for name, (frames, fps, scale, runtime_loop) in animation_jobs.items():
        path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_final_{name}.gif"
        mirror_path = PREVIEW_DIR / f"combat_robot_drone_operator_elite_final_{name}_mirrored.gif"
        gif_outputs[name] = {
            "gif": save_exact_gif(frames, path, fps, scale),
            "mirrored_gif": save_exact_gif(frames, mirror_path, fps, scale, True),
            "runtime_loop": runtime_loop,
        }

    sequence_frames, sequence_contract = build_sequence(candidates)
    sequence_durations = [(30, 30, 40)[index % 3] for index in range(len(sequence_frames))]
    sequence_contract["gif_duration_pattern_ms"] = [30, 30, 40]
    sequence_contract["gif_total_duration_ms"] = sum(sequence_durations)
    sequence_output = save_exact_gif(
        sequence_frames,
        SEQUENCE_GIF,
        sequence_contract["review_fps"],
        6,
        durations_ms=sequence_durations,
    )
    sequence_contact = build_sequence_contact(sequence_frames)
    save_png(sequence_contact, SEQUENCE_CONTACT)
    comparison = build_comparison(candidates)
    save_png(comparison, FINAL_COMPARISON)

    report = {
        "asset": "combat_robot_drone_operator_elite_final_candidate",
        "stage": "final_candidate_pending_fourth_human_gate",
        "selection_certificate": {"path": rel(FINAL_SELECTION), "sha256": sha256(FINAL_SELECTION)},
        "atlases": atlas_outputs,
        "metrics": metrics,
        "gifs": gif_outputs,
        "sequence": {"gif": sequence_output, "contact_sheet": {"path": rel(SEQUENCE_CONTACT), "sha256": sha256(SEQUENCE_CONTACT), "size": list(sequence_contact.size)}, "contract": sequence_contract},
        "comparison": {"path": rel(FINAL_COMPARISON), "sha256": sha256(FINAL_COMPARISON), "size": list(comparison.size)},
        "construction": "byte-exact composition of selected native strips; no resampling or recoloring",
        "script": {"path": rel(SCRIPT_PATH), "sha256": sha256(SCRIPT_PATH)},
        "deterministic_in_memory_rebuild": True,
        "fixed_gif_palette_exact_decode": True,
        "final_human_approved": False,
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(report, FINAL_REPORT)
    manifest = {
        "version": 1,
        "asset": "combat_robot_drone_operator_elite_final_candidate",
        "stage": "final_candidate_pending_fourth_human_gate",
        "approved_anchor": "O3",
        "approved_animation_selection": {"move": "M1", "deploy": "P1", "death": "K2"},
        "approved_effect_selection": {"drone": "V1", "target": "T1", "explosion": "X1"},
        "selection_certificate": {"path": rel(FINAL_SELECTION), "sha256": sha256(FINAL_SELECTION)},
        "preview_report": {"path": rel(FINAL_REPORT), "sha256": sha256(FINAL_REPORT)},
        "candidate_atlases": {key: payload["native"] for key, payload in atlas_outputs.items()},
        "sequence_gif": sequence_output,
        "final_human_approved": False,
        "imagegen_pixels_imported": False,
        "runtime_written": False,
    }
    save_json(manifest, FINAL_MANIFEST)

    for key, path in ORDINARY.items():
        if sha256(path) != EXPECTED_ORDINARY_SHA[key]:
            raise AssertionError(f"ordinary runtime {key} changed during final preview build")
    print(json.dumps({"ok": True, "stage": manifest["stage"], "selection": "O3/M1/P1/K2/V1/T1/X1", "sequence": rel(SEQUENCE_GIF), "runtime_written": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
