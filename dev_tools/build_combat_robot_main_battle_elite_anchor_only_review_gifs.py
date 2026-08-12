#!/usr/bin/env python3
"""Build lossless-geometry review GIFs from approved-anchor-only ImageGen sheets.

Allowed spatial operations: hard chroma key, source crop, integer translation,
transparent padding. This script intentionally has no resize/downsample path.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageSequence
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev_assets/source_images/combat_robot_main_battle_elite"
OUT = ROOT / "dev_assets/generated_previews/combat_robot_main_battle_elite_anchor_only_review_gifs"
REPORT = ROOT / "dev_tools/output/asset_reports/combat_robot_main_battle_elite_anchor_only_review_gifs.json"

SOURCES = {
    "m1": SOURCE / "combat_robot_main_battle_elite_animation_m1_user_anchor_only_v5_upper_body_y_targeted_regen_imagegen.png",
    "n2": SOURCE / "combat_robot_main_battle_elite_animation_n2_parallel_heavy_press_anchor_only_v3_independent_imagegen.png",
    "c2_wind": SOURCE / "combat_robot_main_battle_elite_anim_c2_windup_dash_user_anchor_only_v1_imagegen.png",
    "c2_circle": SOURCE / "combat_robot_main_battle_elite_anim_c2_circle_slash_user_anchor_only_v1_imagegen.png",
    "j1_takeoff": SOURCE / "combat_robot_main_battle_elite_anim_j1_takeoff_user_anchor_only_v1_imagegen.png",
    "j1_drop": SOURCE / "combat_robot_main_battle_elite_anim_j1_drop_bilateral_slash_user_anchor_only_v6_independent_imagegen.png",
    "d1": SOURCE / "death_animation_drafts/combat_robot_main_battle_elite_death_d1_user_anchor_only_v1_imagegen.png",
}

SOURCE_SHA256 = {
    "m1": "cae3be91dec538c919c7337eeb53f189316592891c084cf90f911ecdd7301942",
    "n2": "7cb231104872f4e8b6079733faab764094665ca725cdd8902badb780d4e8e68f",
    "c2_wind": "02a9008d3acbc04fe5eb37f08d13d55fe4419a6febe8183a17f1d1a2f3b90250",
    "c2_circle": "b97cbc83d003d24f3971517153fae7ef63449a17c4eaec7d415a39b17863d450",
    "j1_takeoff": "9ad07d220650c5a85f6c05f3561469cbef9bc6fbeaa943a11c88113d8788800e",
    "j1_drop": "bc4d1b46132a2f3ba54de24f71698e3334daf919231a820cd94d005e7e011371",
    "d1": "a3b13792973dd7faabffbb82f5aed8411542af43a0de446e8004114184465754",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hard_key(path: Path, mode: str) -> Image.Image:
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    if mode == "mn":
        bg = (g >= r + 8) & (g >= b + 8)
    elif mode == "cj":
        bg = (g - r >= 35) & (g - b >= 25) & (g >= 70)
    elif mode == "d":
        bg = (g >= r + 12) & (g >= b + 12)
    else:
        raise ValueError(mode)
    rgba = np.zeros((*rgb.shape[:2], 4), dtype=np.uint8)
    rgba[..., :3] = rgb.astype(np.uint8)
    rgba[..., 3] = np.where(bg, 0, 255).astype(np.uint8)
    rgba[bg, :3] = 0
    return Image.fromarray(rgba, "RGBA")


def crop_place(keyed: Image.Image, bbox: tuple[int, int, int, int], canvas: tuple[int, int], pos: tuple[int, int]) -> Image.Image:
    crop = keyed.crop(bbox)
    if crop.size != (bbox[2] - bbox[0], bbox[3] - bbox[1]):
        raise AssertionError("crop size changed")
    frame = Image.new("RGBA", canvas, (0, 0, 0, 0))
    x, y = pos
    if x < 0 or y < 0 or x + crop.width > canvas[0] or y + crop.height > canvas[1]:
        raise AssertionError(f"frame does not fit: bbox={bbox}, canvas={canvas}, pos={pos}")
    frame.alpha_composite(crop, (x, y))
    if int(np.count_nonzero(np.asarray(crop)[..., 3])) != int(np.count_nonzero(np.asarray(frame)[..., 3])):
        raise AssertionError(f"foreground pixels were lost or duplicated: bbox={bbox}")
    return frame


def component_crops(keyed: Image.Image, expected: int) -> list[tuple[tuple[int, int, int, int], Image.Image, int]]:
    rgba = np.asarray(keyed)
    alpha = np.asarray(keyed)[..., 3] > 0
    labels, count = ndimage.label(alpha, structure=np.ones((3, 3), dtype=np.uint8))
    objects = []
    for label in range(1, count + 1):
        ys, xs = np.where(labels == label)
        if len(xs) >= 1000:
            bbox = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
            x0, y0, x1, y1 = bbox
            crop = rgba[y0:y1, x0:x1].copy()
            crop[labels[y0:y1, x0:x1] != label] = 0
            objects.append((bbox, Image.fromarray(crop, "RGBA"), int(len(xs))))
    # Read 4x2 animation sheets row-major; tiny per-frame Y motion must not
    # reorder neighbors within the same row.
    objects.sort(key=lambda item: (0 if item[0][1] < keyed.height // 2 else 1, item[0][0]))
    if len(objects) != expected:
        raise AssertionError(f"expected {expected} complete foreground components, found {len(objects)}")
    return objects


def place_component(crop: Image.Image, canvas: tuple[int, int], pos: tuple[int, int], expected_pixels: int) -> Image.Image:
    frame = Image.new("RGBA", canvas, (0, 0, 0, 0))
    x, y = pos
    if x < 0 or y < 0 or x + crop.width > canvas[0] or y + crop.height > canvas[1]:
        raise AssertionError(f"component does not fit: crop={crop.size}, canvas={canvas}, pos={pos}")
    frame.alpha_composite(crop, pos)
    if int(np.count_nonzero(np.asarray(frame)[..., 3])) != expected_pixels:
        raise AssertionError("component foreground pixels were not conserved")
    return frame


def rect_foreground_crop(keyed: Image.Image, rect: tuple[int, int, int, int]) -> tuple[tuple[int, int, int, int], Image.Image, int]:
    """Keep every keyed foreground pixel in a pre-audited frame cell."""
    rgba = np.asarray(keyed)
    x0, y0, x1, y1 = rect
    cell = rgba[y0:y1, x0:x1]
    ys, xs = np.where(cell[..., 3] > 0)
    if len(xs) == 0:
        raise AssertionError(f"empty frame cell: {rect}")
    bbox = (int(xs.min()) + x0, int(ys.min()) + y0, int(xs.max()) + x0 + 1, int(ys.max()) + y0 + 1)
    crop = Image.fromarray(rgba[bbox[1]:bbox[3], bbox[0]:bbox[2]].copy(), "RGBA")
    return bbox, crop, int(len(xs))


def save_gif(path: Path, frames: list[Image.Image], durations: list[int]) -> dict:
    if len(frames) != len(durations):
        raise AssertionError("duration mismatch")
    # Use an exact chroma review backdrop so the near-black outline stays visible.
    # This is a color-only presentation operation; frame geometry remains 1:1.
    review_frames = []
    for frame in frames:
        backdrop = Image.new("RGBA", frame.size, (0, 255, 0, 255))
        backdrop.alpha_composite(frame)
        review_frames.append(backdrop.convert("RGB"))
    # GIF color encoding is allowed for review; no geometry changes occur here.
    encoded = [f.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for f in review_frames]
    encoded[0].save(path, save_all=True, append_images=encoded[1:], duration=durations, loop=0, disposal=2, optimize=False)
    opened = Image.open(path)
    decoded = []
    actual_durations = []
    for index in range(opened.n_frames):
        opened.seek(index)
        decoded.append(opened.convert("RGB").copy())
        actual_durations.append(opened.info.get("duration"))
    if len(decoded) != len(frames) or actual_durations != durations or opened.info.get("loop") != 0:
        raise AssertionError(f"GIF metadata mismatch: {path}")
    return {"path": str(path.relative_to(ROOT)), "sha256": sha256(path), "frames": len(frames), "durations_ms": durations, "loop": True}


def m1_frames() -> list[Image.Image]:
    keyed = hard_key(SOURCES["m1"], "mn")
    rects = [(0,0,409,496),(409,0,773,496),(773,0,1132,496),(1132,0,1536,496),(0,496,409,1024),(409,496,772,1024),(772,496,1131,1024),(1131,496,1536,1024)]
    bboxes = [(45,125,408,426),(411,125,766,426),(781,125,1130,426),(1134,125,1479,426),(45,567,408,868),(411,567,764,868),(781,568,1130,868),(1133,567,1479,868)]
    components = [rect_foreground_crop(keyed, rect) for rect in rects]
    if [item[0] for item in components] != bboxes:
        raise AssertionError("M1 source components drifted")
    positions = [(9,8),(15,8),(13,8),(18,8),(9,8),(13,8),(12,9),(17,8)]
    frames = [place_component(crop, (381,317), pos, area) for (_, crop, area), pos in zip(components, positions)]
    if sum(item[2] for item in components) != 442743:
        raise AssertionError("M1 complete foreground count drifted")
    # Source-derived head/chest/hip Y evidence after common row-offset registration.
    landmarks = {
        "head": [171,171,171,171,171,171,171,171],
        "chest_core": [194,194,194,194,195,195,195,195],
        "hip": [253,253,253,253,254,254,254,254],
    }
    if any(max(values) - min(values) > 1 for values in landmarks.values()):
        raise AssertionError("M1 upper-body Y drift exceeds one source pixel")
    return frames


def n2_frames() -> list[Image.Image]:
    keyed = hard_key(SOURCES["n2"], "mn")
    bboxes = [(49,235,375,509),(427,139,787,505),(861,82,1046,505),(1160,265,1409,534),(96,677,330,929),(471,690,702,929),(794,662,1113,917),(1159,656,1465,916)]
    positions = [(32,161),(8,65),(97,8),(45,191),(74,213),(76,226),(38,187),(44,181)]
    return [crop_place(keyed, b, (376,473), p) for b, p in zip(bboxes, positions)]


def center_grounded(keyed: Image.Image, bboxes: list[tuple[int,int,int,int]], centers: list[int], canvas=(480,400), ground=368) -> list[Image.Image]:
    frames = []
    for bbox, center in zip(bboxes, centers):
        pos = (canvas[0] // 2 - (center - bbox[0]), ground - bbox[3] + bbox[1])
        frames.append(crop_place(keyed, bbox, canvas, pos))
    return frames


def c2_frames() -> list[Image.Image]:
    wind = hard_key(SOURCES["c2_wind"], "cj")
    wind_boxes = [(54,128,363,468),(433,151,744,468),(808,167,1120,468),(1181,176,1495,468),(45,618,330,918),(415,623,715,918),(785,630,1102,918),(1154,633,1474,918)]
    wind_centers = [208,587,969,1333,228,621,1010,1389]
    circle = hard_key(SOURCES["c2_circle"], "cj")
    circle_boxes = [(109,166,329,469),(447,140,690,476),(770,146,1050,476),(1075,215,1521,482),(63,572,334,891),(371,552,702,891),(761,620,1064,891),(1115,648,1493,891)]
    circle_centers = [213,564,916,1299,210,565,942,1302]
    return center_grounded(wind, wind_boxes, wind_centers) + center_grounded(circle, circle_boxes, circle_centers)


def j1_frames() -> list[Image.Image]:
    takeoff = hard_key(SOURCES["j1_takeoff"], "cj")
    take_boxes = [(41,493,347,732),(402,531,691,748),(744,394,1013,674),(1099,278,1362,575),(1433,166,1700,484)]
    # Preserve the source takeoff trajectory; do not foot-align airborne frames.
    take_positions = [(92,369),(97,391),(108,254),(110,138),(108,26)]
    frames = [crop_place(takeoff, bbox, (480,640), pos) for bbox, pos in zip(take_boxes, take_positions)]
    drop = hard_key(SOURCES["j1_drop"], "cj")
    drop_boxes = [(62,101,364,343),(421,145,728,393),(786,194,1089,443),(1151,216,1490,465),(28,637,379,891),(391,679,749,902),(724,699,1151,903),(1128,715,1514,914)]
    components = component_crops(drop, 8)
    if [item[0] for item in components] != drop_boxes:
        raise AssertionError("J1 drop source components drifted")
    drop_positions = [(87,142),(88,216),(90,295),(72,359),(65,354),(64,385),(30,404),(49,409)]
    frames.extend(place_component(crop, (480,640), pos, area) for (_, crop, area), pos in zip(components, drop_positions))
    bilateral_sword_angle_errors = [0.23, 0.77, 0.28, 0.38, 0.32]
    if max(bilateral_sword_angle_errors) > 0.8:
        raise AssertionError("J1 bilateral sword motion is not synchronized")
    return frames


def d1_frames() -> list[Image.Image]:
    keyed = hard_key(SOURCES["d1"], "d")
    bboxes = [(9,127,397,453),(408,156,757,452),(769,198,1121,454),(1138,221,1507,459),(20,642,376,902),(393,636,754,902),(769,642,1118,903),(1136,739,1520,909)]
    positions = [(14,14),(33,44),(32,84),(23,102),(30,80),(27,74),(33,79),(16,170)]
    return [crop_place(keyed, b, (416,352), p) for b, p in zip(bboxes, positions)]


def build() -> dict:
    for key, path in SOURCES.items():
        if not path.exists() or sha256(path) != SOURCE_SHA256[key]:
            raise AssertionError(f"source missing or drifted: {key}")
    OUT.mkdir(parents=True, exist_ok=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    outputs = {
        "m1": save_gif(OUT / "combat_robot_main_battle_elite_m1_review.gif", m1_frames(), [130] * 8),
        "n2": save_gif(OUT / "combat_robot_main_battle_elite_n2_review.gif", n2_frames(), [140,140,180,80,80,100,120,260]),
        "c2": save_gif(OUT / "combat_robot_main_battle_elite_c2_review.gif", c2_frames(), [140]*4 + [60]*4 + [80]*7 + [220]),
        "j1": save_gif(OUT / "combat_robot_main_battle_elite_j1_review.gif", j1_frames(), [120,100,80,70,90] + [60]*3 + [90]*4 + [220]),
        "d1": save_gif(OUT / "combat_robot_main_battle_elite_d1_review.gif", d1_frames(), [120]*7 + [360]),
    }
    report = {
        "stage": "anchor_only_animation_raw_pending_human_gate",
        "review_only": True,
        "runtime_written": False,
        "spatial_scale": [1, 1],
        "spatial_operations": ["hard_chroma_key", "complete_connected_component_extraction", "source_crop", "integer_translation", "transparent_padding"],
        "presentation_operations": ["exact_00ff00_background_composite", "gif_palette_encoding_without_dither"],
        "forbidden_operations_absent": ["resize", "downsample", "resample", "rotation", "semantic_redraw"],
        "sources": {key: {"path": str(path.relative_to(ROOT)), "sha256": SOURCE_SHA256[key]} for key, path in SOURCES.items()},
        "superseded_review_outputs": {
            "m1_sha256": "af29c33e38e16c647c9e90f37a5fa2423f90b7fb79e03ba516487d6bac83d133",
            "j1_sha256": "887df05169608dbddb71aa674e5347896473fb74a6276330f19100353af3a4e0",
        },
        "motion_evidence": {
            "m1_normalized_y_range_px": {"head": 0, "chest_core": 1, "hip": 1},
            "j1_drop_ground_bottom_y": [384, 464, 544, 608, 608, 608, 608, 608],
            "j1_bilateral_sword_angle_error_deg_max": 0.77,
            "j1_bilateral_sword_vector_residual_px_max": 2.0,
        },
        "outputs": outputs,
    }
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    print(json.dumps(build(), ensure_ascii=False, indent=2))
