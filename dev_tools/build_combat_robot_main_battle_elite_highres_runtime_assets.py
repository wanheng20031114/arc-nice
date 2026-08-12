#!/usr/bin/env python3
"""Build the approved high-resolution main-battle robot runtime assets.

This is intentionally not a native-64 builder.  The approved source pixels are
hard-keyed by the already-audited review extractor, copied into one shared
virtual frame with integer translations, and tightly packed with AtlasTexture
margins.  No source pixel is resized, resampled, voted, recolored, or dropped.
The Godot scene applies the user-approved uniform display scale and linear
texture filtering at runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

import build_combat_robot_main_battle_elite_anchor_only_review_gifs as review


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_OUTPUT = (
    ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_main_battle_elite.png"
)
ANIMATION_OUTPUT = (
    ROOT / "resources" / "animation" / "combat_robot_main_battle_elite.tres"
)
REPORT_OUTPUT = (
    ROOT
    / "dev_tools"
    / "output"
    / "asset_reports"
    / "combat_robot_main_battle_elite_highres_runtime_build_report.json"
)
RESOURCE_TEXTURE_PATH = (
    "res://resources/texture/enemy/mechanical_life/"
    "combat_robot_main_battle_elite.png"
)

REVIEW_BUILDER_SHA256 = (
    "ca05223ff6905d15d017604508d3ef8c1e25873d55a0dd0de3f24a76232c55c3"
)
VIRTUAL_FRAME_SIZE = (512, 688)
VIRTUAL_GROUND_Y = 624
TRANSPARENT_GUARD = 16
PACK_GAP = 8
RUNTIME_SCALE = 0.125
RUNTIME_TEXTURE_FILTER = "linear"
TRANSPARENT = (0, 0, 0, 0)
APPROVAL_PATH = (
    ROOT
    / "dev_assets/source_images/combat_robot_main_battle_elite"
    / "combat_robot_main_battle_elite_animation_selection.json"
)
APPROVAL_STAGE = "high_resolution_runtime_released_native64_ineligible"
RELEASE_FLAG = "--release-approved-highres-runtime"


@dataclass(frozen=True)
class AnimationSpec:
    name: str
    frame_source: str
    source_slice: tuple[int, int]
    source_canvas: tuple[int, int]
    virtual_offset: tuple[int, int]
    durations: tuple[float, ...]
    expected_alpha_pixels: tuple[int, ...]
    loop: bool = False


ANIMATION_SPECS = (
    AnimationSpec(
        "move",
        "m1",
        (0, 8),
        (381, 317),
        (65, 315),
        (1.3,) * 8,
        (57746, 55119, 53121, 55025, 57405, 54656, 54748, 54923),
        True,
    ),
    AnimationSpec(
        "attack",
        "n2",
        (0, 8),
        (376, 473),
        (68, 193),
        (1.4, 1.4, 1.8, 0.8, 0.8, 1.0, 1.2, 2.6),
        (47644, 48059, 39497, 37777, 34929, 33655, 43553, 42880),
    ),
    AnimationSpec(
        "skill1_windup",
        "c2",
        (0, 4),
        (480, 400),
        (16, 256),
        (1.4,) * 4,
        (62661, 61544, 60933, 59616),
    ),
    AnimationSpec(
        "skill1_dash",
        "c2",
        (4, 8),
        (480, 400),
        (16, 256),
        (0.6,) * 4,
        (51777, 50015, 49155, 47471),
        True,
    ),
    AnimationSpec(
        "skill1_circle_slash",
        "c2",
        (8, 16),
        (480, 400),
        (16, 256),
        (0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 2.2),
        (40514, 40990, 40596, 41953, 41933, 42281, 39029, 43952),
    ),
    AnimationSpec(
        "skill2_takeoff",
        "j1",
        (0, 5),
        (480, 640),
        (16, 16),
        (1.2, 1.0, 0.8, 0.7, 0.9),
        (39557, 34063, 31772, 31337, 32230),
    ),
    AnimationSpec(
        "skill2_drop_slash",
        "j1",
        (5, 13),
        (480, 640),
        (16, 16),
        (0.6, 0.6, 0.6, 0.9, 0.9, 0.9, 0.9, 2.2),
        (32670, 32692, 32934, 33715, 34165, 32573, 31856, 31754),
    ),
    AnimationSpec(
        "death",
        "d1",
        (0, 8),
        (416, 352),
        (48, 284),
        (1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 1.2, 3.6),
        (71367, 61470, 53702, 47540, 52427, 52496, 48297, 35468),
    ),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assert_explicit_approval() -> dict[str, object]:
    if not APPROVAL_PATH.is_file():
        raise AssertionError("canonical animation approval is missing")
    approval = json.loads(APPROVAL_PATH.read_text(encoding="utf-8"))
    runtime_release = approval.get("runtime_release", {})
    native_eligibility = approval.get("native_eligibility", {})
    if (
        approval.get("human_approved") is not True
        or approval.get("stage") != APPROVAL_STAGE
        or runtime_release.get("strategy")
        != "high_resolution_source_preserved_linear_display"
        or native_eligibility.get("eligible") is not False
        or approval.get("runtime_written") is not True
    ):
        raise AssertionError("canonical high-resolution runtime approval mismatch")
    return approval


def decoded_rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def load_source_frames() -> dict[str, list[Image.Image]]:
    review_path = Path(review.__file__).resolve()
    if sha256(review_path) != REVIEW_BUILDER_SHA256:
        raise AssertionError("approved lossless review extractor changed")
    for key, path in review.SOURCES.items():
        if not path.is_file() or sha256(path) != review.SOURCE_SHA256[key]:
            raise AssertionError(f"approved source missing or drifted: {key}")
    return {
        "m1": review.m1_frames(),
        "n2": review.n2_frames(),
        "c2": review.c2_frames(),
        "j1": review.j1_frames(),
        "d1": review.d1_frames(),
    }


def remove_residual_chroma(frame: Image.Image) -> tuple[Image.Image, int]:
    """Remove green-dominant matte residue without spatial resampling.

    The approved review extractor deliberately preserved source RGB verbatim,
    including a dark green antialias/matte fringe that falls below some source
    key thresholds.  The robot palette has no green functional color, so the
    release contract removes every still-opaque pixel whose green channel leads
    red and blue by at least eight.  This is a color predicate only: surviving
    pixels are copied byte-for-byte and no alpha is softened.
    """

    rgba = np.array(frame.convert("RGBA"), copy=True)
    visible = rgba[..., 3] == 255
    r = rgba[..., 0].astype(np.int16)
    g = rgba[..., 1].astype(np.int16)
    b = rgba[..., 2].astype(np.int16)
    residual = visible & (g >= r + 8) & (g >= b + 8)
    removed = int(np.count_nonzero(residual))
    rgba[residual] = 0
    return Image.fromarray(rgba, mode="RGBA"), removed


def assert_rgba_frame(frame: Image.Image, spec: AnimationSpec, index: int) -> None:
    if frame.mode != "RGBA" or frame.size != spec.source_canvas:
        raise AssertionError(
            f"{spec.name}[{index}] canvas {frame.size}/{frame.mode} drifted"
        )
    rgba = np.asarray(frame)
    alpha = rgba[..., 3]
    unique_alpha = set(np.unique(alpha).tolist())
    if not unique_alpha <= {0, 255}:
        raise AssertionError(f"{spec.name}[{index}] alpha is not binary")
    visible = alpha == 255
    if int(np.count_nonzero(visible)) <= 0:
        raise AssertionError(f"{spec.name}[{index}] foreground count drifted")
    if np.any(rgba[~visible, :3] != 0):
        raise AssertionError(f"{spec.name}[{index}] transparent RGB is not zero")
    # This predicate is independent from each source-sheet extractor and guards
    # against low-luminance green matte residue surviving into runtime.
    r = rgba[..., 0].astype(np.int16)
    g = rgba[..., 1].astype(np.int16)
    b = rgba[..., 2].astype(np.int16)
    chroma = visible & (g >= r + 8) & (g >= b + 8)
    if np.any(chroma):
        raise AssertionError(f"{spec.name}[{index}] retains opaque chroma green")
    # A second, ratio-based audit catches near-threshold green residue without
    # sharing the release key itself. Isolated low-saturation steel variation is
    # allowed; saturated green pixels are not.
    independent_chroma = visible & (g >= 20) & (g >= r * 2) & (g >= b * 2)
    if np.any(independent_chroma):
        raise AssertionError(f"{spec.name}[{index}] fails independent chroma audit")


def virtualize(frame: Image.Image, offset: tuple[int, int]) -> Image.Image:
    virtual = Image.new("RGBA", VIRTUAL_FRAME_SIZE, TRANSPARENT)
    x, y = offset
    if (
        x < 0
        or y < 0
        or x + frame.width > virtual.width
        or y + frame.height > virtual.height
    ):
        raise AssertionError(f"source frame does not fit virtual canvas: {frame.size}")
    virtual.alpha_composite(frame, offset)
    if np.count_nonzero(np.asarray(frame)[..., 3]) != np.count_nonzero(
        np.asarray(virtual)[..., 3]
    ):
        raise AssertionError("integer translation lost or duplicated foreground")
    return virtual


def guarded_region(virtual: Image.Image) -> tuple[tuple[int, int, int, int], Image.Image]:
    bbox = virtual.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("empty virtual frame")
    x0 = bbox[0] - TRANSPARENT_GUARD
    y0 = bbox[1] - TRANSPARENT_GUARD
    x1 = bbox[2] + TRANSPARENT_GUARD
    y1 = bbox[3] + TRANSPARENT_GUARD
    if x0 < 0 or y0 < 0 or x1 > virtual.width or y1 > virtual.height:
        raise AssertionError(f"transparent guard does not fit: {bbox}")
    region = virtual.crop((x0, y0, x1, y1))
    if np.count_nonzero(np.asarray(region)[..., 3]) != np.count_nonzero(
        np.asarray(virtual)[..., 3]
    ):
        raise AssertionError("guarded crop lost foreground")
    return (x0, y0, x1, y1), region


def sprite_frames_text(records: dict[str, list[dict[str, object]]]) -> str:
    lines = [
        '[gd_resource type="SpriteFrames" format=3]',
        "",
        (
            '[ext_resource type="Texture2D" '
            f'path="{RESOURCE_TEXTURE_PATH}" id="1_texture"]'
        ),
        "",
    ]
    for spec in ANIMATION_SPECS:
        for index, record in enumerate(records[spec.name]):
            region = record["atlas_region"]
            margin = record["virtual_margin"]
            lines.extend(
                [
                    (
                        '[sub_resource type="AtlasTexture" '
                        f'id="AtlasTexture_{spec.name}_{index}"]'
                    ),
                    'atlas = ExtResource("1_texture")',
                    (
                        "region = Rect2("
                        f"{region[0]}, {region[1]}, {region[2]}, {region[3]})"
                    ),
                    (
                        "margin = Rect2("
                        f"{margin[0]}, {margin[1]}, {margin[2]}, {margin[3]})"
                    ),
                    "filter_clip = true",
                    "",
                ]
            )
    lines.extend(["[resource]", "animations = ["])
    blocks: list[str] = []
    for spec in ANIMATION_SPECS:
        frame_blocks = []
        for index, duration in enumerate(spec.durations):
            frame_blocks.append(
                "{\n"
                + f'"duration": {duration:.6g},\n'
                + f'"texture": SubResource("AtlasTexture_{spec.name}_{index}")\n'
                + "}"
            )
        blocks.append(
            "{\n"
            + '"frames": ['
            + ", ".join(frame_blocks)
            + "],\n"
            + f'"loop": {str(spec.loop).lower()},\n'
            + f'"name": &"{spec.name}",\n'
            + '"speed": 10.0\n'
            + "}"
        )
    lines.append(", ".join(blocks))
    lines.extend(["]", ""])
    return "\n".join(lines)


def build() -> dict[str, object]:
    approval = assert_explicit_approval()
    source_frames = load_source_frames()
    virtual_rows: dict[
        str,
        list[tuple[Image.Image, tuple[int, int, int, int], Image.Image, int]],
    ] = {}
    for spec in ANIMATION_SPECS:
        selected = source_frames[spec.frame_source][
            spec.source_slice[0] : spec.source_slice[1]
        ]
        if len(selected) != len(spec.durations):
            raise AssertionError(f"{spec.name} frame/duration count mismatch")
        row = []
        for index, frame in enumerate(selected):
            release_frame, removed_residual_chroma = remove_residual_chroma(frame)
            assert_rgba_frame(release_frame, spec, index)
            virtual = virtualize(release_frame, spec.virtual_offset)
            virtual_bbox, region = guarded_region(virtual)
            row.append((virtual, virtual_bbox, region, removed_residual_chroma))
        virtual_rows[spec.name] = row

    row_widths = {
        spec.name: sum(item[2].width for item in virtual_rows[spec.name])
        + PACK_GAP * (len(virtual_rows[spec.name]) - 1)
        for spec in ANIMATION_SPECS
    }
    row_heights = {
        spec.name: max(item[2].height for item in virtual_rows[spec.name])
        for spec in ANIMATION_SPECS
    }
    atlas_size = (
        max(row_widths.values()),
        sum(row_heights.values()) + PACK_GAP * (len(ANIMATION_SPECS) - 1),
    )
    if atlas_size[0] > 4096 or atlas_size[1] > 4096:
        raise AssertionError(f"packed atlas exceeds 4096px: {atlas_size}")
    atlas = Image.new("RGBA", atlas_size, TRANSPARENT)
    records: dict[str, list[dict[str, object]]] = {}
    pack_y = 0
    for spec in ANIMATION_SPECS:
        pack_x = 0
        records[spec.name] = []
        for index, (virtual, virtual_bbox, region_image, removed_residual_chroma) in enumerate(
            virtual_rows[spec.name]
        ):
            atlas.alpha_composite(region_image, (pack_x, pack_y))
            x0, y0, x1, y1 = virtual_bbox
            region_width, region_height = region_image.size
            margin = (
                x0,
                y0,
                VIRTUAL_FRAME_SIZE[0] - region_width,
                VIRTUAL_FRAME_SIZE[1] - region_height,
            )
            records[spec.name].append(
                {
                    "frame_index": index,
                    "source_canvas": list(spec.source_canvas),
                    "virtual_canvas": list(VIRTUAL_FRAME_SIZE),
                    "virtual_ground_y": VIRTUAL_GROUND_Y,
                    "integer_translation": list(spec.virtual_offset),
                    "virtual_region": [x0, y0, x1 - x0, y1 - y0],
                    "atlas_region": [pack_x, pack_y, region_width, region_height],
                    "virtual_margin": list(margin),
                    "extracted_alpha_pixels": spec.expected_alpha_pixels[index],
                    "removed_residual_chroma_pixels": removed_residual_chroma,
                    "runtime_alpha_pixels": int(
                        np.count_nonzero(np.asarray(region_image)[..., 3])
                    ),
                    "extracted_rgba_sha256": decoded_rgba_sha(
                        source_frames[spec.frame_source][
                            spec.source_slice[0] + index
                        ]
                    ),
                    "virtual_rgba_sha256": decoded_rgba_sha(virtual),
                    "duration_weight": spec.durations[index],
                }
            )
            pack_x += region_width + PACK_GAP
        pack_y += row_heights[spec.name] + PACK_GAP

    atlas_rgba = np.asarray(atlas)
    if not set(np.unique(atlas_rgba[..., 3]).tolist()) <= {0, 255}:
        raise AssertionError("runtime atlas alpha is not binary")
    if np.any(atlas_rgba[atlas_rgba[..., 3] == 0, :3] != 0):
        raise AssertionError("runtime atlas transparent RGB is not zero")
    extracted_total = sum(sum(spec.expected_alpha_pixels) for spec in ANIMATION_SPECS)
    removed_residual_chroma_total = sum(
        int(record["removed_residual_chroma_pixels"])
        for animation_records in records.values()
        for record in animation_records
    )
    expected_total = extracted_total - removed_residual_chroma_total
    actual_total = int(np.count_nonzero(atlas_rgba[..., 3]))
    if actual_total != expected_total:
        raise AssertionError(
            f"atlas foreground conservation failed: {actual_total} != {expected_total}"
        )

    TEXTURE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    ANIMATION_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    REPORT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(TEXTURE_OUTPUT, format="PNG", optimize=False, compress_level=9)
    ANIMATION_OUTPUT.write_text(sprite_frames_text(records), encoding="utf-8")

    report: dict[str, object] = {
        "stage": "high_resolution_source_preserved_runtime_assets_built",
        "runtime_strategy": "high_resolution_source_preserved_linear_display",
        "native64_eligible": False,
        "native64_claimed": False,
        "runtime_written": True,
        "canonical_approval": {
            "path": APPROVAL_PATH.relative_to(ROOT).as_posix(),
            "stage": approval["stage"],
        },
        "runtime_scale": [RUNTIME_SCALE, RUNTIME_SCALE],
        "runtime_texture_filter": RUNTIME_TEXTURE_FILTER,
        "virtual_frame_size": list(VIRTUAL_FRAME_SIZE),
        "virtual_ground_y": VIRTUAL_GROUND_Y,
        "atlas_size": list(atlas_size),
        "source_pixel_scale": [1, 1],
        "spatial_operations": [
            "hard_chroma_key",
            "hard_residual_chroma_key",
            "audited_source_crop_or_component_extraction",
            "integer_translation",
            "transparent_padding",
            "tight_atlas_packing_with_atlastexture_margin",
        ],
        "forbidden_spatial_operations_absent": [
            "resize",
            "downsample",
            "resample",
            "rotation",
            "block_vote",
            "per_frame_scale",
            "semantic_redraw",
        ],
        "runtime_builder": {
            "path": Path(__file__).resolve().relative_to(ROOT).as_posix(),
            "sha256": sha256(Path(__file__).resolve()),
        },
        "source_builder": {
            "path": review_path_string(),
            "sha256": REVIEW_BUILDER_SHA256,
        },
        "sources": {
            key: {
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": review.SOURCE_SHA256[key],
            }
            for key, path in review.SOURCES.items()
        },
        "animation_contract": {
            spec.name: {
                "frame_count": len(spec.durations),
                "speed": 10.0,
                "duration_weights": list(spec.durations),
                "duration_seconds": sum(spec.durations) / 10.0,
                "loop": spec.loop,
            }
            for spec in ANIMATION_SPECS
        },
        "foreground_conservation": {
            "source_extracted_total": extracted_total,
            "removed_residual_chroma_total": removed_residual_chroma_total,
            "accepted_source_total": expected_total,
            "runtime_total": actual_total,
            "lost": 0,
            "duplicated": 0,
        },
        "artifacts": {
            "texture": {
                "path": TEXTURE_OUTPUT.relative_to(ROOT).as_posix(),
                "sha256": sha256(TEXTURE_OUTPUT),
                "decoded_rgba_sha256": decoded_rgba_sha(atlas),
                "size": list(atlas_size),
            },
            "animation": {
                "path": ANIMATION_OUTPUT.relative_to(ROOT).as_posix(),
                "sha256": sha256(ANIMATION_OUTPUT),
            },
        },
        "frames": records,
    }
    REPORT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def review_path_string() -> str:
    return Path(review.__file__).resolve().relative_to(ROOT).as_posix()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        RELEASE_FLAG,
        action="store_true",
        help="write the explicitly approved high-resolution runtime assets",
    )
    args = parser.parse_args()
    if not getattr(args, RELEASE_FLAG.removeprefix("--").replace("-", "_")):
        parser.error(f"explicit {RELEASE_FLAG} is required; no files were written")
    report_1 = build()
    snapshot_1 = {
        role: artifact["sha256"]
        for role, artifact in report_1["artifacts"].items()
    }
    report_2 = build()
    snapshot_2 = {
        role: artifact["sha256"]
        for role, artifact in report_2["artifacts"].items()
    }
    if report_1 != report_2 or snapshot_1 != snapshot_2:
        raise AssertionError("two-pass runtime asset build drift")
    report = report_2
    report["determinism"] = {
        "passes": 2,
        "drift_count": 0,
        "snapshot_1": snapshot_1,
        "snapshot_2": snapshot_2,
        "build_payload_sha256": hashlib.sha256(
            (json.dumps(report_1, ensure_ascii=False, sort_keys=True) + "\n").encode(
                "utf-8"
            )
        ).hexdigest(),
    }
    REPORT_OUTPUT.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "COMBAT_ROBOT_MAIN_BATTLE_ELITE_HIGHRES_RUNTIME_ASSETS_OK "
        f"atlas={report['atlas_size']} "
        f"texture_sha256={report['artifacts']['texture']['sha256']} "
        f"animation_sha256={report['artifacts']['animation']['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
