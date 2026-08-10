#!/usr/bin/env python3
"""Build the review-only fourth-gate elite ninja final candidate."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE = ROOT / "dev_assets/source_images/combat_robot_ninja_elite"
PREVIEW = ROOT / "dev_assets/generated_previews"
ORDINARY = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
ANCHOR = SOURCE / "combat_robot_ninja_elite_anchor_n1c_approved_native40.png"
ANCHOR_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_anchor_manifest.json")
ANIMATION_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_animation_manifest.json")
ANIMATION_REPORT = enemy_asset_report_path("combat_robot_ninja_elite_animation_preview_report.json")
AFTERIMAGE_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_afterimage_manifest.json")
AFTERIMAGE_REPORT = enemy_asset_report_path("combat_robot_ninja_elite_afterimage_preview_report.json")
REVIEW_SOURCE = SOURCE / "combat_robot_ninja_elite_afterimage_review_source.png"
FINAL_ATLAS = SOURCE / "combat_robot_ninja_elite_final_candidate_atlas.png"
FINAL_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_final_candidate_manifest.json")
FINAL_REPORT = enemy_asset_report_path("combat_robot_ninja_elite_final_candidate_report.json")

FRAME = 40
FRAMES = 8
ATLAS_SIZE = (320, 120)
BACKGROUND = (13, 19, 31, 255)
TRANSPARENT = (0, 0, 0, 0)
SELECTION = {"move": "m1", "boost": "s2", "death": "d1"}
FPS = {"move": 20, "boost": 24, "death": 12}
PREVIEW_DURATIONS_MS = {"move": 50, "boost": 40, "death": 80}
ROW_RGBA = {
    "move": "cfb00c5e0c1e330d41a0bfcee6827576b52f39e8a7ca3c6875fb3511eed921ba",
    "boost": "e44ebfa9e6ba7f4cba50a38acf3f114ae87829f8fc1e047b6610243f2936cb37",
    "death": "616bff1518b607e5f58e60e1375eeb0fc339f41ec92e4280062d739757357ed0",
}
NATIVE_LOCKS = {
    "move": (SOURCE / "combat_robot_ninja_elite_move_m1_candidate_native.png", "0d2abb9e49f38d1d9ff09a6e874485168e15798d78cd503a241fe601e1a5f3d9"),
    "boost": (SOURCE / "combat_robot_ninja_elite_boost_s2_candidate_native.png", "d227677c16a89685489649ddb56362c84356f81181792a920f1f0180638058b2"),
    "death": (SOURCE / "combat_robot_ninja_elite_death_d1_candidate_native.png", "e886670c43fece56df7462ce8fb8b8bacae69bd8ab0d7ff82fc1c431e4aa7ffe"),
}
FILE_LOCKS = {
    ORDINARY: "f34f15083e48af0179c1d2669a3d22bdfdb33de266d9373cbaa9defa2b434ceb",
    ANCHOR: "5aac848b278fe6f9f0d495649df4d64977856a92de875b7a3989515bcd6a1938",
    ANCHOR_MANIFEST: "11df368a76d4025aedc6c823bf3e4dfcfc06b59acc25a9427dff82b42b13162e",
    ANIMATION_MANIFEST: "a2589f42897f714ffbd99300b8136c6a9eac30ff5f1aaffb4e85941e7041be61",
    ANIMATION_REPORT: "f56de52b7793a318d66d64a61c7608b45d1b16e4563a2eec90ca80e5d7a61b18",
    AFTERIMAGE_MANIFEST: "ba3e9338e2515a1cad5d414639bacb9276a4b8019007ea47f893b95ea923e759",
    AFTERIMAGE_REPORT: "67ba9810e813836e6984b80744bd35bb173b71280db55572fa2c73e33c5c4c32",
    REVIEW_SOURCE: "6c0f50f2e02be51264ba92b269d26366653a0608cbed2b186e6c43c8ae2bd23b",
}
EXPECTED_ATLAS_RGBA = "5fc943f0369c1e6a6f26f374c5c07542e2d92dd780e9a8ea7157220dca7001d3"
OLD_ACCENTS = {(102, 25, 20, 255), (190, 48, 31, 255), (239, 92, 34, 255)}
ALLOWED_COLORS = {
    TRANSPARENT,
    (21, 22, 19, 255), (29, 28, 30, 255), (55, 59, 63, 255),
    (82, 88, 94, 255), (112, 121, 128, 255), (151, 159, 164, 255),
    (190, 196, 198, 255), (226, 229, 226, 255),
    (42, 21, 60, 255), (74, 36, 105, 255), (115, 84, 134, 255),
    (125, 54, 179, 255), (157, 78, 221, 255), (197, 138, 255, 255),
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def ensure_dev(path: Path) -> None:
    resolved = path.resolve()
    dev = (ROOT / "dev_assets").resolve()
    if resolved != dev and dev not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Refused non-dev output: {path}")


def write_json(path: Path, value: object) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=False, compress_level=9)


def record(path: Path, image: Image.Image | None = None) -> dict[str, object]:
    result: dict[str, object] = {"path": rel(path), "sha256": sha(path)}
    if image is not None:
        result.update({"size": list(image.size), "mode": image.mode, "rgba_sha256": rgba_sha(image)})
    return result


def verify_locks() -> tuple[dict[str, Image.Image], dict[str, object]]:
    for path, expected in FILE_LOCKS.items():
        if not path.is_file() or sha(path) != expected:
            raise AssertionError(f"Input lock drifted: {rel(path)}")
    anchor_manifest = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    animation_manifest = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    afterimage_manifest = json.loads(AFTERIMAGE_MANIFEST.read_text(encoding="utf-8"))
    afterimage_report = json.loads(AFTERIMAGE_REPORT.read_text(encoding="utf-8"))
    if anchor_manifest.get("stage") != "first_human_gate_approved" or anchor_manifest.get("approved_selection", "").lower() != "n1c":
        raise AssertionError("N1C gate certificate drifted")
    if animation_manifest.get("stage") != "second_human_gate_approved" or animation_manifest.get("approved_animation_selection") != SELECTION:
        raise AssertionError("M1/S2/D1 gate certificate drifted")
    if afterimage_manifest.get("stage") != "afterimage_third_human_gate_approved" or afterimage_manifest.get("third_human_approved") is not True:
        raise AssertionError("Afterimage gate certificate is not approved")
    if afterimage_manifest.get("report_sha256") != FILE_LOCKS[AFTERIMAGE_REPORT] or afterimage_report.get("third_human_approved") is not True:
        raise AssertionError("Afterimage report hash chain drifted")
    if any(value.get("runtime_written") is not False for value in (anchor_manifest, animation_manifest, afterimage_manifest, afterimage_report)):
        raise AssertionError("A preview certificate claims a runtime write")
    strips: dict[str, Image.Image] = {}
    for slot, (path, expected) in NATIVE_LOCKS.items():
        if sha(path) != expected:
            raise AssertionError(f"Approved {slot} strip drifted")
        with Image.open(path) as opened:
            image = opened.convert("RGBA")
        if image.size != (320, 40) or rgba_sha(image) != ROW_RGBA[slot]:
            raise AssertionError(f"Approved {slot} decoded pixels drifted")
        strips[slot] = image
    for key, output in afterimage_manifest["outputs"].items():
        output_path = ROOT / output["path"]
        if sha(output_path) != output["sha256"]:
            raise AssertionError(f"Afterimage output drifted: {key}")
    return strips, afterimage_manifest


def build_atlas(strips: dict[str, Image.Image]) -> Image.Image:
    atlas = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    for row, slot in enumerate(("move", "boost", "death")):
        atlas.alpha_composite(strips[slot], (0, row * FRAME))
    if rgba_sha(atlas) != EXPECTED_ATLAS_RGBA:
        raise AssertionError("Final atlas decoded RGBA drifted")
    with Image.open(REVIEW_SOURCE) as opened:
        review = opened.convert("RGBA")
    if atlas.tobytes() != review.tobytes():
        raise AssertionError("Final atlas differs from the approved afterimage review source")
    return atlas


def on_background(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, BACKGROUND)
    result.alpha_composite(image)
    return result.convert("RGB")


def nearest(image: Image.Image, scale: int = 16) -> Image.Image:
    return image.resize((image.width * scale, image.height * scale), Image.Resampling.NEAREST)


def components8(points: set[tuple[int, int]]) -> int:
    remaining = set(points)
    count = 0
    while remaining:
        count += 1
        stack = [remaining.pop()]
        while stack:
            x, y = stack.pop()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    point = (x + dx, y + dy)
                    if point in remaining:
                        remaining.remove(point)
                        stack.append(point)
    return count


def frame_audit(candidate: Image.Image, ordinary: Image.Image, row: str, index: int) -> dict[str, object]:
    points = {(x, y) for y in range(FRAME) for x in range(FRAME) if candidate.getpixel((x, y))[3]}
    if not points:
        raise AssertionError(f"Empty frame: {row}/{index}")
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    bbox = [min(xs), min(ys), max(xs) + 1, max(ys) + 1]
    component_count = components8(points)
    changed = added = removed = y11_added = 0
    for y in range(FRAME):
        for x in range(FRAME):
            before, after = ordinary.getpixel((x, y)), candidate.getpixel((x, y))
            if before != after:
                changed += 1
            if before[3] == 0 and after[3]:
                added += 1
                y11_added += int(y == 11)
            if before[3] and after[3] == 0:
                removed += 1
            if after[3] not in (0, 255) or (after[3] == 0 and after[:3] != (0, 0, 0)):
                raise AssertionError(f"Alpha/RGB hygiene failed: {row}/{index}")
    margins = [bbox[0], bbox[1], FRAME - bbox[2], FRAME - bbox[3]]
    colors = set(candidate.getdata())
    if not colors <= ALLOWED_COLORS:
        raise AssertionError(f"Fixed palette drifted: {row}/{index}: {colors - ALLOWED_COLORS}")
    if (
        bbox[2] - bbox[0] > 28
        or bbox[3] - bbox[1] > 28
        or bbox[3] != 32
        or min(margins) < 6
        or component_count != 1
        or removed
        or y11_added
    ):
        raise AssertionError(f"Frame geometry/connection contract failed: {row}/{index}")
    return {
        "frame": index, "rgba_sha256": rgba_sha(candidate), "bbox": bbox,
        "margins": margins,
        "visible_pixels": len(points), "component8_count": component_count,
        "blade_connected": True, "ordinary_changed_pixels": changed,
        "ordinary_added_pixels": added, "ordinary_removed_pixels": removed,
        "y11_added_pixels": y11_added,
    }


def diagnostic_images(atlas: Image.Image, ordinary: Image.Image) -> tuple[Image.Image, Image.Image]:
    delta = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    overlay = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    for y in range(ATLAS_SIZE[1]):
        for x in range(ATLAS_SIZE[0]):
            before, after = ordinary.getpixel((x, y)), atlas.getpixel((x, y))
            if before[3]:
                overlay.putpixel((x, y), (60, 210, 235, 88))
            if after[3]:
                overlay.alpha_composite(Image.new("RGBA", (1, 1), (*after[:3], 224)), (x, y))
            if before == after:
                continue
            color = (86, 224, 255, 255) if before[3] == 0 and after[3] else (197, 138, 255, 255) if before in OLD_ACCENTS else (255, 210, 80, 255)
            delta.putpixel((x, y), color)
    return delta, overlay


def paletted(frame: Image.Image, palette_colors: list[tuple[int, int, int]]) -> Image.Image:
    indices = {color: index for index, color in enumerate(palette_colors)}
    rgb = frame.convert("RGB")
    unknown = set(rgb.getdata()) - set(indices)
    if unknown:
        raise AssertionError(f"GIF palette missing {len(unknown)} colors")
    result = Image.new("P", rgb.size)
    result.putpalette([c for color in palette_colors for c in color] + [0] * (768 - len(palette_colors) * 3))
    result.putdata([indices[pixel] for pixel in rgb.getdata()])
    return result


def save_gif(frames: list[Image.Image], path: Path, durations: list[int]) -> dict[str, object]:
    expected = [nearest(on_background(frame)) for frame in frames]
    colors: list[tuple[int, int, int]] = []
    for image in expected:
        for color in image.getdata():
            if color not in colors:
                colors.append(color)
    if len(colors) > 256:
        raise AssertionError("GIF palette exceeds 256 exact colors")
    indexed = [paletted(frame, colors) for frame in expected]
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    indexed[0].save(path, save_all=True, append_images=indexed[1:], duration=durations, loop=0, optimize=False, disposal=2)
    decoded_durations: list[int] = []
    with Image.open(path) as decoded:
        if decoded.n_frames != len(expected):
            raise AssertionError(f"GIF frame count drifted: {path}")
        for index, wanted in enumerate(expected):
            decoded.seek(index)
            decoded_durations.append(int(decoded.info.get("duration", 0)))
            if decoded.convert("RGB").tobytes() != wanted.tobytes():
                raise AssertionError(f"GIF decode drifted: {path} frame {index}")
    if decoded_durations != durations:
        raise AssertionError(f"GIF durations drifted: {path}: {decoded_durations} != {durations}")
    return {**record(path), "frame_count": len(frames), "durations_ms": decoded_durations, "lossless_exact_decode": True}


def main() -> None:
    strips, afterimage_manifest = verify_locks()
    atlas_a, atlas_b = build_atlas(strips), build_atlas(strips)
    if atlas_a.tobytes() != atlas_b.tobytes():
        raise AssertionError("In-memory final atlas rebuild drifted")
    ensure_dev(FINAL_ATLAS)
    FINAL_ATLAS.parent.mkdir(parents=True, exist_ok=True)
    FINAL_ATLAS.write_bytes(REVIEW_SOURCE.read_bytes())
    if sha(FINAL_ATLAS) != FILE_LOCKS[REVIEW_SOURCE]:
        raise AssertionError("Final native atlas byte-copy drifted")
    with Image.open(ORDINARY) as opened:
        ordinary = opened.convert("RGBA")
    preview_path = PREVIEW / "combat_robot_ninja_elite_final_candidate_atlas_16x.png"
    delta_path = PREVIEW / "combat_robot_ninja_elite_final_candidate_ordinary_delta_16x.png"
    overlay_path = PREVIEW / "combat_robot_ninja_elite_final_candidate_ordinary_overlay_16x.png"
    save_png(nearest(on_background(atlas_a)), preview_path)
    delta, overlay = diagnostic_images(atlas_a, ordinary)
    save_png(nearest(on_background(delta)), delta_path)
    save_png(nearest(on_background(overlay)), overlay_path)

    rows = {slot: [strips[slot].crop((i * FRAME, 0, (i + 1) * FRAME, FRAME)) for i in range(FRAMES)] for slot in SELECTION}
    ordinary_rows = {slot: [ordinary.crop((i * FRAME, r * FRAME, (i + 1) * FRAME, (r + 1) * FRAME)) for i in range(FRAMES)] for r, slot in enumerate(("move", "boost", "death"))}
    animation_report = json.loads(ANIMATION_REPORT.read_text(encoding="utf-8"))
    for slot, key in SELECTION.items():
        actual_frame_hashes = [rgba_sha(frame) for frame in rows[slot]]
        expected_frame_hashes = animation_report["outputs"][key]["frame_rgba_sha256"]
        if actual_frame_hashes != expected_frame_hashes:
            raise AssertionError(f"Approved per-frame certificate drifted: {slot}")
    with Image.open(ANCHOR) as opened:
        anchor = opened.convert("RGBA")
    if rows["move"][0].tobytes() != anchor.tobytes():
        raise AssertionError("Move frame 0 differs from approved N1C anchor")
    audits = {slot: [frame_audit(frame, ordinary_rows[slot][i], slot, i) for i, frame in enumerate(rows[slot])] for slot in rows}
    if any(pixel in OLD_ACCENTS for pixel in atlas_a.getdata()):
        raise AssertionError("Old red/orange accents remain in final atlas")

    outputs: dict[str, object] = {
        "native_atlas": record(FINAL_ATLAS, atlas_a),
        "integer_16x": record(preview_path),
        "ordinary_delta_16x": record(delta_path),
        "ordinary_overlay_16x": record(overlay_path),
    }
    for slot in ("move", "boost", "death"):
        duration = [PREVIEW_DURATIONS_MS[slot]] * FRAMES
        outputs[f"{slot}_forward_gif"] = save_gif(rows[slot], PREVIEW / f"combat_robot_ninja_elite_final_candidate_{slot}.gif", duration)
        mirrored = [frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) for frame in rows[slot]]
        outputs[f"{slot}_mirrored_gif"] = save_gif(mirrored, PREVIEW / f"combat_robot_ninja_elite_final_candidate_{slot}_mirrored.gif", duration)
    transition_sequences = {
        "move_to_boost": ([*rows["move"][0:4], *rows["boost"][3:7]], [50] * 4 + [40] * 4),
        "boost_to_move": ([*rows["boost"][4:8], rows["move"][7], *rows["move"][0:3]], [40] * 4 + [50] * 4),
    }
    for name, (frames, durations) in transition_sequences.items():
        outputs[f"{name}_gif"] = save_gif(frames, PREVIEW / f"combat_robot_ninja_elite_final_candidate_{name}.gif", durations)

    afterimage_references = afterimage_manifest["outputs"]
    report = {
        "schema_version": 1, "asset": "combat_robot_ninja_elite_final_candidate",
        "stage": "final_candidate_pending_fourth_human_gate", "preview_only": True,
        "approved_anchor": "n1c", "approved_animation_selection": SELECTION,
        "first_human_approved": True, "second_human_approved": True, "third_human_approved": True,
        "final_human_approved": False, "runtime_written": False, "runtime_paths_written": [],
        "imagegen_pixels_imported": False,
        "builder": {"path": rel(SCRIPT), "sha256": sha(SCRIPT)},
        "input_locks": {rel(path): expected for path, expected in FILE_LOCKS.items()},
        "approved_native_locks": {slot: {"path": rel(path), "sha256": expected, "rgba_sha256": ROW_RGBA[slot]} for slot, (path, expected) in NATIVE_LOCKS.items()},
        "atlas": {"size": list(ATLAS_SIZE), "rgba_sha256": EXPECTED_ATLAS_RGBA, "row_order": ["move_m1", "boost_s2", "death_d1"], "row_rgba_sha256": ROW_RGBA},
        "animation_contract": {
            "move": {"frames": 8, "fps": 20, "runtime_loop": True},
            "boost": {"frames": 8, "fps": 24, "runtime_loop": True},
            "death": {"frames": 8, "fps": 12, "runtime_loop": False},
            "review_gifs_loop_for_human_inspection": True,
        },
        "frame_audit": audits,
        "ordinary_diff_whitelist": {"certificate": rel(ANIMATION_MANIFEST), "outside_approved_selected_frames_changed_pixels": 0, "y11_added_pixels": 0, "removed_pixels": 0},
        "phase_proof": {"move_to_boost_preserved_index": 3, "boost_to_move_preserved_index": 7, "playing_and_progress_preserved_by_gate3_godot_report": True},
        "afterimage_references": afterimage_references,
        "boost_to_death_cleanup": afterimage_references["boost_to_death_cleanup"],
        "outputs": outputs,
        "checks": {"direct_m1_s2_d1_concat": True, "atlas_matches_gate3_review_source_byte_for_byte": True, "twenty_four_frame_hashes_match_second_gate": True, "move_frame_zero_matches_approved_n1c": True, "binary_alpha": True, "transparent_rgb_zero": True, "fixed_steel_and_purple_palette": True, "maximum_visible_28x28": True, "baseline_bottom_32": True, "six_pixel_safety_margin": True, "component8_single_and_blades_connected": True, "no_y11_additions": True, "no_old_red_orange": True, "gif_lossless_exact_decode": True, "gif_durations_match_declared_preview_timing": True, "afterimage_gifs_reused_without_reencoding": True, "deterministic_in_memory_rebuild": True, "runtime_written": False},
    }
    write_json(FINAL_REPORT, report)
    manifest = {
        "schema_version": 1, "asset": "combat_robot_ninja_elite", "stage": "final_candidate_pending_fourth_human_gate",
        "preview_only": True,
        "approved_anchor": "n1c", "approved_animation_selection": SELECTION,
        "first_human_approved": True, "second_human_approved": True, "third_human_approved": True,
        "final_human_approved": False, "runtime_written": False, "runtime_paths_written": [],
        "imagegen_pixels_imported": False,
        "native_atlas": outputs["native_atlas"], "report": rel(FINAL_REPORT), "report_sha256": sha(FINAL_REPORT),
        "outputs": {key: {"path": value["path"], "sha256": value["sha256"]} for key, value in outputs.items()},
        "afterimage_references": afterimage_references,
        "gate3_certificate": {"manifest": rel(AFTERIMAGE_MANIFEST), "manifest_sha256": FILE_LOCKS[AFTERIMAGE_MANIFEST], "report": rel(AFTERIMAGE_REPORT), "report_sha256": FILE_LOCKS[AFTERIMAGE_REPORT]},
    }
    write_json(FINAL_MANIFEST, manifest)
    print("COMBAT_ROBOT_NINJA_ELITE_FINAL_PREVIEW_OK")
    print(f"atlas={rel(FINAL_ATLAS)}")
    print(f"report={rel(FINAL_REPORT)}")
    print(f"manifest={rel(FINAL_MANIFEST)}")


if __name__ == "__main__":
    main()
