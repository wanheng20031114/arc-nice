#!/usr/bin/env python3
"""Build the approved <=20x20-body Tiyi sheet from the hand-edited master.

The transform is structural pixel editing, not image scaling: X is untouched,
face rows are copied verbatim, and only four pairs of non-face Y rows are
collapsed. Every output RGB therefore comes from the approved source.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "dev_assets" / "source_images" / "player_tiyi" / "movement_logical_lossless.png"
OUTPUT_PATH = ROOT / "dev_assets" / "source_images" / "player_tiyi" / "movement_scale1_20px_candidate.png"
REPORT_PATH = ROOT / "dev_tools/output/player_tiyi/movement_scale1_20px_candidate.json"
COMPARISON_PATH = ROOT / "dev_assets" / "source_images" / "player_tiyi" / "movement_20px_comparison_4x.png"
FRAME_SIZE = 32
TARGET_TOP = 5

# 24 source rows (3..26) become 20 authored rows (5..24).  Face rows 9..14,
# horn/top rows 3..6 and foot rows 25..26 are all retained one-for-one.
ROW_GROUPS: tuple[tuple[int, ...], ...] = (
    (3,),
    (4,),
    (5,),
    (6,),
    (7, 8),
    (9,),
    (10,),
    (11,),
    (12,),
    (13,),
    (14,),
    (15, 16),
    (17,),
    (18,),
    (19, 20),
    (21,),
    (22,),
    (23, 24),
    (25,),
    (26,),
)

DIRECTION_RULES: tuple[dict[str, object], ...] = (
    {
        "name": "down",
        "body_x": (5, 25),
        "face_rect": (12, 9, 21, 16),
        "bob": (0, -1, 0, -1),
        "whole_body_bob": True,
        "lower_body_start": 22,
    },
    {
        "name": "up",
        "body_x": (7, 27),
        "face_rect": None,
        "bob": (0, -1, 0, -1),
        "whole_body_bob": True,
        "lower_body_start": 22,
    },
    {
        "name": "right",
        "body_x": (5, 25),
        "face_rect": (17, 9, 22, 16),
        "bob": (0, 0, 1, -1),
        "whole_body_bob": False,
        "lower_body_start": 22,
    },
    {
        "name": "left",
        "body_x": (7, 27),
        "face_rect": (10, 9, 15, 16),
        "bob": (0, 0, 1, -1),
        "whole_body_bob": False,
        "lower_body_start": 22,
    },
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _pixel_priority(pixel: np.ndarray) -> tuple[int, int, int, int]:
    """Prefer authored outlines/highlights when two structural rows collide."""
    red, green, blue, alpha = (int(value) for value in pixel)
    if alpha == 0:
        return (-1, 0, 0, 0)
    maximum = max(red, green, blue)
    minimum = min(red, green, blue)
    luminance = (red * 54 + green * 183 + blue * 19) // 256
    outline_or_highlight = int(luminance < 74 or luminance > 205)
    saturation = maximum - minimum
    return (outline_or_highlight, saturation, abs(luminance - 140), alpha)


def _merge_source_rows(frame: np.ndarray, rows: tuple[int, ...]) -> np.ndarray:
    if len(rows) == 1:
        return frame[rows[0]].copy()
    merged = np.zeros((FRAME_SIZE, 4), dtype=np.uint8)
    for x in range(FRAME_SIZE):
        candidates = [frame[source_y, x] for source_y in rows]
        merged[x] = max(candidates, key=_pixel_priority)
    return merged


def _paste_opaque(destination: np.ndarray, source_row: np.ndarray, target_y: int) -> None:
    if target_y < 0 or target_y >= FRAME_SIZE:
        return
    visible = source_row[:, 3] > 0
    destination[target_y, visible] = source_row[visible]


def _build_base_frame(frame: np.ndarray) -> tuple[np.ndarray, dict[int, int]]:
    base = np.zeros_like(frame)
    source_to_target_y: dict[int, int] = {}
    for group_index, source_rows in enumerate(ROW_GROUPS):
        target_y = TARGET_TOP + group_index
        base[target_y] = _merge_source_rows(frame, source_rows)
        for source_y in source_rows:
            source_to_target_y[source_y] = target_y
    return base, source_to_target_y


def _apply_bob(base: np.ndarray, rule: dict[str, object], frame_index: int) -> np.ndarray:
    bob_offset = int(rule["bob"][frame_index])
    if bob_offset == 0:
        return base.copy()
    result = np.zeros_like(base)
    if bool(rule["whole_body_bob"]):
        for source_y in range(FRAME_SIZE):
            _paste_opaque(result, base[source_y], source_y + bob_offset)
        return result

    lower_body_start = int(rule["lower_body_start"])
    for source_y in range(TARGET_TOP, lower_body_start):
        _paste_opaque(result, base[source_y], source_y + bob_offset)
    for source_y in range(lower_body_start, FRAME_SIZE):
        _paste_opaque(result, base[source_y], source_y)
    if bob_offset < 0:
        # Preserve one connector row while the rigid head/torso rises.
        _paste_opaque(result, base[lower_body_start - 1], lower_body_start - 1)
    return result


def _compress_frame(
    frame: np.ndarray,
    rule: dict[str, object],
    frame_index: int,
) -> tuple[np.ndarray, dict[str, object]]:
    base, source_to_target_y = _build_base_frame(frame)
    result = _apply_bob(base, rule, frame_index)
    bob_offset = int(rule["bob"][frame_index])

    face_rect = rule["face_rect"]
    face_target_rect: list[int] | None = None
    if face_rect is not None:
        left, top, right, bottom = (int(value) for value in face_rect)
        mapped_rows = [source_to_target_y[source_y] + bob_offset for source_y in range(top, bottom)]
        if mapped_rows != list(range(mapped_rows[0], mapped_rows[0] + bottom - top)):
            raise AssertionError(f"{rule['name']}: locked face rows are no longer contiguous")
        face_target_rect = [left, mapped_rows[0], right, mapped_rows[-1] + 1]
        # A merged structural row may cross the chin.  Restore the complete
        # seven-row face block after that merge, including transparent pixels,
        # so its RGBA is a literal translated copy of the supervised source.
        result[mapped_rows[0] : mapped_rows[-1] + 1, left:right] = frame[
            top:bottom, left:right
        ]
        if not np.array_equal(
            frame[top:bottom, left:right],
            result[mapped_rows[0] : mapped_rows[-1] + 1, left:right],
        ):
            raise AssertionError(f"{rule['name']} frame {frame_index}: locked face RGBA changed")

    body_left, body_right = (int(value) for value in rule["body_x"])
    body_alpha = result[:, body_left:body_right, 3] > 0
    body_y, body_x = np.where(body_alpha)
    if len(body_x) == 0:
        raise AssertionError(f"{rule['name']} frame {frame_index}: body became empty")
    body_bbox = [
        int(body_x.min() + body_left),
        int(body_y.min()),
        int(body_x.max() + body_left + 1),
        int(body_y.max() + 1),
    ]
    body_size = [body_bbox[2] - body_bbox[0], body_bbox[3] - body_bbox[1]]
    if body_size[0] > 20 or body_size[1] > 20:
        raise AssertionError(
            f"{rule['name']} frame {frame_index}: body {body_size} exceeds 20x20"
        )

    all_y, all_x = np.where(result[:, :, 3] > 0)
    body_centroid = [
        round(float(body_x.mean() + body_left), 3),
        round(float(body_y.mean()), 3),
    ]
    return result, {
        "frame": frame_index,
        "bob_offset": bob_offset,
        "body_bbox_excluding_rifle_extension": body_bbox,
        "body_size": body_size,
        "body_alpha_centroid": body_centroid,
        "face_target_rect": face_target_rect,
        "face_rgba_preserved_exactly": True,
        "foot_baseline": int(all_y.max()),
        "visible_pixels": int(len(all_x)),
    }


def main() -> None:
    if not SOURCE_PATH.is_file():
        raise FileNotFoundError(SOURCE_PATH)
    source = Image.open(SOURCE_PATH).convert("RGBA")
    if source.size != (128, 128):
        raise AssertionError(f"approved movement source must be 128x128, got {source.size}")
    source_rgba = np.array(source, dtype=np.uint8)
    output = np.zeros_like(source_rgba)
    direction_reports: list[dict[str, object]] = []

    for row, rule in enumerate(DIRECTION_RULES):
        frame_reports: list[dict[str, object]] = []
        for column in range(4):
            frame = source_rgba[
                row * FRAME_SIZE : (row + 1) * FRAME_SIZE,
                column * FRAME_SIZE : (column + 1) * FRAME_SIZE,
            ]
            reduced, frame_report = _compress_frame(frame, rule, column)
            output[
                row * FRAME_SIZE : (row + 1) * FRAME_SIZE,
                column * FRAME_SIZE : (column + 1) * FRAME_SIZE,
            ] = reduced
            frame_reports.append(frame_report)
        x_centroids = [float(frame["body_alpha_centroid"][0]) for frame in frame_reports]
        direction_reports.append(
            {
                "direction": rule["name"],
                "bob_rhythm": list(rule["bob"]),
                "body_x_roi": list(rule["body_x"]),
                "body_centroid_x_spread": round(max(x_centroids) - min(x_centroids), 3),
                "frames": frame_reports,
            }
        )

    visible = output[:, :, 3] == 255
    if np.any(output[:, :, 3][visible] != 255) or np.any(output[~visible] != 0):
        raise AssertionError("candidate must retain hard Alpha and zero transparent RGB")
    source_colors = {
        tuple(int(channel) for channel in pixel[:3])
        for pixel in source_rgba.reshape(-1, 4)
        if pixel[3] == 255
    }
    output_colors = {
        tuple(int(channel) for channel in pixel[:3])
        for pixel in output.reshape(-1, 4)
        if pixel[3] == 255
    }
    if not output_colors.issubset(source_colors):
        raise AssertionError("candidate introduced RGB colors absent from the approved source")

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(output).save(OUTPUT_PATH, optimize=True)
    comparison = Image.new("RGBA", (FRAME_SIZE * 8 + 16, FRAME_SIZE * 4), (24, 26, 31, 255))
    comparison.alpha_composite(source, (0, 0))
    comparison.alpha_composite(Image.fromarray(output), (FRAME_SIZE * 4 + 16, 0))
    comparison.resize(
        (comparison.width * 4, comparison.height * 4),
        Image.Resampling.NEAREST,
    ).save(COMPARISON_PATH, optimize=True)
    report = {
        "scope": "approved scale-1 movement source; runtime promotion is handled by process_tiyi_assets.py",
        "source": SOURCE_PATH.relative_to(ROOT).as_posix(),
        "source_sha256": _sha256(SOURCE_PATH),
        "output": OUTPUT_PATH.relative_to(ROOT).as_posix(),
        "output_sha256": _sha256(OUTPUT_PATH),
        "comparison": COMPARISON_PATH.relative_to(ROOT).as_posix(),
        "method": "x-preserving 24-to-20 structural row merge with locked face RGBA",
        "row_groups": [list(group) for group in ROW_GROUPS],
        "resize_used": False,
        "new_colors_introduced": False,
        "target_body_limit_excluding_rifle_extension": [20, 20],
        "directions": direction_reports,
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"Tiyi <=20px movement candidate written to {OUTPUT_PATH}")
    print(f"Candidate report written to {REPORT_PATH}")
    print(f"Nearest-neighbor comparison written to {COMPARISON_PATH}")


if __name__ == "__main__":
    main()
