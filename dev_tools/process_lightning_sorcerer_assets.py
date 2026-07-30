#!/usr/bin/env python3
"""Build the Lightning Sorcerer atlas and center-registered walk strip."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

from process_frost_sorcerer_assets import (
    CHARACTER_FRAME_SIZE,
    CHARACTER_PALETTE_COLORS,
    GRID_SIZE,
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
OUTPUT = ROOT / "resources/texture/lightning_sorcerer.png"
MOVE_OUTPUT = ROOT / "resources/texture/lightning_sorcerer_move.png"
MOVE_SOURCE = SOURCE_DIR / "lightning_sorcerer_move_8pose_v1_alpha.png"
ROW_SOURCES = (
    SOURCE_DIR / "lightning_sorcerer_move_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_windup_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_attack_alpha.png",
    SOURCE_DIR / "lightning_sorcerer_death_alpha.png",
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
        horizontal_nudges=(0, 0, -1, 0, 0, 0, 0, 0),
    )
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
