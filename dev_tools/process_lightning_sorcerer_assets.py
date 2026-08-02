#!/usr/bin/env python3
"""Build the Lightning Sorcerer atlas and center-registered walk strip."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from process_frost_sorcerer_assets import (
    AssetContractError,
    CHARACTER_FRAME_SIZE,
    CHARACTER_PALETTE_COLORS,
    GRID_SIZE,
    MOVE_FRAME_COUNT,
    MOVE_GROUND_Y,
    _assemble_sheet,
    _assert_existing_matches,
    _assert_output_contract,
    _build_move_strip,
    _frame_bbox,
    _load_character_strip,
    _load_fire_reference,
    _place_character_in_reference_bounds,
    _quantize_visible_colors,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/lightning_sorcerer"
OUTPUT = ROOT / "resources/texture/enemy/sorcerer/lightning_sorcerer.png"
MOVE_OUTPUT = ROOT / "resources/texture/enemy/sorcerer/lightning_sorcerer_move.png"
MOVE_SOURCE = SOURCE_DIR / "lightning_sorcerer_move_8pose_v5_alpha.png"
ROW_SOURCES = (
    SOURCE_DIR / "lightning_sorcerer_move_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_windup_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_attack_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_death_alpha.png",
)


def _ground_contact_segments(mask: np.ndarray) -> tuple[tuple[int, int], ...]:
    """Return inclusive x ranges touching the authored move ground line."""
    contact_x = np.flatnonzero(mask[MOVE_GROUND_Y])
    if contact_x.size == 0:
        return ()
    segments: list[tuple[int, int]] = []
    start = previous = int(contact_x[0])
    for value in contact_x[1:]:
        x = int(value)
        if x != previous + 1:
            segments.append((start, previous))
            start = x
        previous = x
    segments.append((start, previous))
    return tuple(segments)


def _assert_lightning_gait_contract(strip: Image.Image) -> None:
    """Lock the two weight-transfer poses that the earlier cycle omitted."""
    masks = [
        np.asarray(
            strip.crop(
                (
                    index * CHARACTER_FRAME_SIZE,
                    0,
                    (index + 1) * CHARACTER_FRAME_SIZE,
                    CHARACTER_FRAME_SIZE,
                )
            ).getchannel("A"),
            dtype=np.uint8,
        )
        == 255
        for index in range(MOVE_FRAME_COUNT)
    ]
    contacts = [_ground_contact_segments(mask) for mask in masks]
    for pass_index in (2, 6):
        if len(contacts[pass_index]) != 1:
            raise AssetContractError(
                "lightning sorcerer move: passing pose "
                f"F{pass_index} must have exactly one planted sole; "
                f"saw {contacts[pass_index]}"
            )

    down_left = contacts[5]
    if len(down_left) != 2:
        raise AssetContractError(
            "lightning sorcerer move: F5 must show a planted left sole "
            f"and a separate right toe; saw {down_left}"
        )
    left_width = down_left[0][1] - down_left[0][0] + 1
    right_width = down_left[1][1] - down_left[1][0] + 1
    if left_width < 5 or right_width > 3:
        raise AssetContractError(
            "lightning sorcerer move: F5 must transfer weight left "
            f"(left>=5px, right<=3px); saw {left_width}px/{right_width}px"
        )

    first_lower = masks[0][30:, :]
    passing_lower = masks[2][30:, :]
    intersection = int(np.logical_and(first_lower, passing_lower).sum())
    union = int(np.logical_or(first_lower, passing_lower).sum())
    lower_iou = intersection / float(union)
    if lower_iou >= 0.80:
        raise AssetContractError(
            "lightning sorcerer move: F2 regressed toward the two-foot "
            f"F0 stance; lower-body IoU={lower_iou:.3f}"
        )
    print(
        "LIGHTNING_GAIT_ANALYSIS "
        f"f2_contacts={contacts[2]} f5_contacts={down_left} "
        f"f6_contacts={contacts[6]} f0_f2_lower_iou={lower_iou:.3f}"
    )


def _build_sheet() -> Image.Image:
    reference = _load_fire_reference()
    frames: list[Image.Image] = []
    for row, source in enumerate(ROW_SOURCES):
        subjects = _load_character_strip(source, row)
        for column, subject in enumerate(subjects):
            bbox = _frame_bbox(reference, row, column)
            frames.append(
                _place_character_in_reference_bounds(
                    subject,
                    bbox,
                    f"lightning_character_{row}_{column}",
                )
            )
    sheet = _quantize_visible_colors(
        _assemble_sheet(frames, CHARACTER_FRAME_SIZE),
        CHARACTER_PALETTE_COLORS,
    )
    _assert_output_contract(
        sheet,
        "lightning sorcerer",
        CHARACTER_FRAME_SIZE,
        CHARACTER_FRAME_SIZE,
        CHARACTER_FRAME_SIZE,
    )
    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            if _frame_bbox(sheet, row, column) != _frame_bbox(reference, row, column):
                raise RuntimeError(
                    f"lightning frame {row}:{column} drifted from sorcerer bounds"
                )
    return sheet


def main(check_only: bool = False) -> None:
    sheet = _build_sheet()
    move_strip = _build_move_strip(
        MOVE_SOURCE,
        sheet,
        "lightning sorcerer move",
        horizontal_nudges=(0,) * MOVE_FRAME_COUNT,
    )
    _assert_lightning_gait_contract(move_strip)
    if check_only:
        _assert_existing_matches(OUTPUT, sheet)
        _assert_existing_matches(MOVE_OUTPUT, move_strip)
        print("LIGHTNING_SORCERER_ASSETS_CHECK_OK")
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUTPUT, optimize=True)
    move_strip.save(MOVE_OUTPUT, optimize=True)
    print(
        "LIGHTNING_SORCERER_ASSETS_OK "
        "move_contract=8_frames_center_registered "
        "other_character_actions=fire_frame_bounds"
    )
    print(f"WROTE {OUTPUT}")
    print(f"WROTE {MOVE_OUTPUT}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    main(args.check_only)
