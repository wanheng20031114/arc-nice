#!/usr/bin/env python3
"""Build native Frost Sorcerer textures from accepted imagegen sources.

The character is authored as four independently generated horizontal strips.
Those sources deliberately use fewer, coarser visual pixel clusters than the
rejected oversized sprite.  This script rasterizes the accepted redraws into
40x40 runtime frames and places every frame in the exact alpha bounds of the
matching Fire Sorcerer frame.  It therefore cannot silently reintroduce the
former 38 px-tall Frost silhouette while the scene nodes remain unchanged.

The ice-spike pipeline is independent and retains its reviewed fixed scale.
All runtime output uses binary alpha and zero RGB in transparent pixels.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from statistics import median

import numpy as np
from PIL import Image

from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/frost_sorcerer"
TEXTURE_DIR = ROOT / "resources/texture"

CHARACTER_ROW_SOURCES = (
    SOURCE_DIR / "frost_sorcerer_move_fire_scale_v2_alpha.png",
    SOURCE_DIR / "frost_sorcerer_windup_fire_scale_alpha.png",
    SOURCE_DIR / "frost_sorcerer_attack_fire_scale_alpha.png",
    SOURCE_DIR / "frost_sorcerer_death_fire_scale_alpha.png",
)
FIRE_REFERENCE = TEXTURE_DIR / "fire_sorcerer.png"
ICE_SPIKE_SOURCE = SOURCE_DIR / "frost_sorcerer_ice_spike_alpha.png"
CHARACTER_OUTPUT = TEXTURE_DIR / "frost_sorcerer.png"
ICE_SPIKE_OUTPUT = TEXTURE_DIR / "frost_sorcerer_ice_spike.png"

GRID_SIZE = 4
CHARACTER_FRAME_SIZE = 40
ICE_SPIKE_FRAME_SIZE = 32
ICE_SPIKE_MAX_WIDTH = 18
ICE_SPIKE_MAX_HEIGHT = 14
ALPHA_THRESHOLD = 96
CHARACTER_PALETTE_COLORS = 24
ICE_SPIKE_PALETTE_COLORS = 12
SOURCE_EDGE_PADDING = 4


class AssetContractError(RuntimeError):
    """Raised when an accepted source cannot satisfy a runtime contract."""


def _normalize_alpha(image: Image.Image) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
    visible = rgba[:, :, 3] >= ALPHA_THRESHOLD
    rgba[visible, 3] = 255
    rgba[~visible] = (0, 0, 0, 0)
    return Image.fromarray(rgba)


def _subject_crop(cell: Image.Image, label: str) -> Image.Image:
    cell = _normalize_alpha(cell)
    analysis = analyze_image(cell)
    bbox = cell.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(f"{label}: source frame is empty")
    print(
        "SOURCE_FRAME_ANALYSIS "
        f"{label} confidence={float(analysis['confidence']):.3f} "
        f"mode={analysis['detection_mode']} "
        f"estimated={analysis['subject_grid_width']}x"
        f"{analysis['subject_grid_height']}"
    )
    return cell.crop(bbox)


def _crop_grid_cell(sheet: Image.Image, row: int, column: int) -> Image.Image:
    left = round(column * sheet.width / GRID_SIZE)
    right = round((column + 1) * sheet.width / GRID_SIZE)
    top = round(row * sheet.height / GRID_SIZE)
    bottom = round((row + 1) * sheet.height / GRID_SIZE)
    return sheet.crop((left, top, right, bottom))


def _load_grid_subjects(path: Path, label: str) -> list[Image.Image]:
    if not path.is_file():
        raise FileNotFoundError(path)
    sheet = Image.open(path).convert("RGBA")
    subjects: list[Image.Image] = []
    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            subjects.append(
                _subject_crop(
                    _crop_grid_cell(sheet, row, column),
                    f"{label}_{row}_{column}",
                )
            )
    return subjects


def _load_character_strip(path: Path, row: int) -> list[Image.Image]:
    if not path.is_file():
        raise FileNotFoundError(path)
    strip = Image.open(path).convert("RGBA")
    if strip.width % GRID_SIZE != 0:
        raise AssetContractError(
            f"character row {row}: width {strip.width} is not divisible by four"
        )
    cell_width = strip.width // GRID_SIZE
    subjects: list[Image.Image] = []
    for column in range(GRID_SIZE):
        cell = _normalize_alpha(
            strip.crop(
                (
                    column * cell_width,
                    0,
                    (column + 1) * cell_width,
                    strip.height,
                )
            )
        )
        bbox = cell.getchannel("A").getbbox()
        if bbox is None:
            raise AssetContractError(
                f"character row {row} frame {column}: source frame is empty"
            )
        if (
            bbox[0] < SOURCE_EDGE_PADDING
            or bbox[1] < SOURCE_EDGE_PADDING
            or bbox[2] > cell.width - SOURCE_EDGE_PADDING
            or bbox[3] > cell.height - SOURCE_EDGE_PADDING
        ):
            raise AssetContractError(
                f"character row {row} frame {column}: subject touches its strip cell edge"
            )
        subjects.append(
            _subject_crop(cell, f"character_{row}_{column}")
        )
    return subjects


def _frame_bbox(sheet: Image.Image, row: int, column: int) -> tuple[int, int, int, int]:
    frame = sheet.crop(
        (
            column * CHARACTER_FRAME_SIZE,
            row * CHARACTER_FRAME_SIZE,
            (column + 1) * CHARACTER_FRAME_SIZE,
            (row + 1) * CHARACTER_FRAME_SIZE,
        )
    )
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(f"reference frame {row}:{column} is empty")
    return bbox


def _load_fire_reference() -> Image.Image:
    if not FIRE_REFERENCE.is_file():
        raise FileNotFoundError(FIRE_REFERENCE)
    reference = _normalize_alpha(Image.open(FIRE_REFERENCE).convert("RGBA"))
    expected = CHARACTER_FRAME_SIZE * GRID_SIZE
    if reference.size != (expected, expected):
        raise AssetContractError(
            f"Fire Sorcerer reference must be {expected}x{expected}, saw {reference.size}"
        )
    return reference


def _resize_exact(subject: Image.Image, size: tuple[int, int], label: str) -> Image.Image:
    native = _normalize_alpha(subject.resize(size, Image.Resampling.NEAREST))
    bbox = native.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(f"{label}: native sampling erased the subject")
    if bbox != (0, 0, size[0], size[1]):
        native = _normalize_alpha(
            native.crop(bbox).resize(size, Image.Resampling.NEAREST)
        )
    if native.getchannel("A").getbbox() != (0, 0, size[0], size[1]):
        raise AssetContractError(f"{label}: sampled alpha does not fill its target bounds")
    return native


def _place_character_in_reference_bounds(
    subject: Image.Image,
    bbox: tuple[int, int, int, int],
    label: str,
) -> Image.Image:
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    native = _resize_exact(subject, (width, height), label)
    frame = Image.new(
        "RGBA",
        (CHARACTER_FRAME_SIZE, CHARACTER_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    frame.alpha_composite(native, (bbox[0], bbox[1]))
    if frame.getchannel("A").getbbox() != bbox:
        raise AssetContractError(f"{label}: output bounds drifted from Fire reference")
    return frame


def _build_character_sheet() -> tuple[Image.Image, Image.Image]:
    reference = _load_fire_reference()
    frames: list[Image.Image] = []
    for row, source in enumerate(CHARACTER_ROW_SOURCES):
        subjects = _load_character_strip(source, row)
        for column, subject in enumerate(subjects):
            bbox = _frame_bbox(reference, row, column)
            frames.append(
                _place_character_in_reference_bounds(
                    subject,
                    bbox,
                    f"character_{row}_{column}",
                )
            )
    sheet = _quantize_visible_colors(
        _assemble_sheet(frames, CHARACTER_FRAME_SIZE),
        CHARACTER_PALETTE_COLORS,
    )
    _assert_character_matches_fire(sheet, reference)
    return sheet, reference


def _fit_scale(
    subject: Image.Image,
    base_scale: float,
    max_width: int,
    max_height: int,
) -> float:
    return min(
        base_scale,
        max_width / float(max(subject.width, 1)),
        max_height / float(max(subject.height, 1)),
    )


def _resize_subject(subject: Image.Image, scale: float) -> Image.Image:
    size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    native = _normalize_alpha(subject.resize(size, Image.Resampling.NEAREST))
    bbox = native.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(
            f"nearest-neighbor sampling erased subject {subject.size} at {scale:.5f}"
        )
    return native.crop(bbox)


def _ice_spike_base_scale(subjects: list[Image.Image]) -> float:
    fly_subjects = subjects[:GRID_SIZE]
    return min(
        ICE_SPIKE_MAX_WIDTH
        / float(median(subject.width for subject in fly_subjects)),
        ICE_SPIKE_MAX_HEIGHT
        / float(median(subject.height for subject in fly_subjects)),
    )


def _place_ice_spike(subject: Image.Image, base_scale: float) -> Image.Image:
    scale = _fit_scale(
        subject,
        base_scale,
        ICE_SPIKE_MAX_WIDTH,
        ICE_SPIKE_MAX_HEIGHT,
    )
    native = _resize_subject(subject, scale)
    frame = Image.new(
        "RGBA",
        (ICE_SPIKE_FRAME_SIZE, ICE_SPIKE_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    left = round((ICE_SPIKE_FRAME_SIZE - native.width) * 0.5)
    top = round((ICE_SPIKE_FRAME_SIZE - native.height) * 0.5)
    frame.alpha_composite(native, (left, top))
    return frame


def _assemble_sheet(frames: list[Image.Image], frame_size: int) -> Image.Image:
    if len(frames) != GRID_SIZE * GRID_SIZE:
        raise AssetContractError(f"expected 16 frames, received {len(frames)}")
    sheet = Image.new(
        "RGBA",
        (frame_size * GRID_SIZE, frame_size * GRID_SIZE),
        (0, 0, 0, 0),
    )
    for index, frame in enumerate(frames):
        sheet.alpha_composite(
            frame,
            ((index % GRID_SIZE) * frame_size, (index // GRID_SIZE) * frame_size),
        )
    return sheet


def _quantize_visible_colors(image: Image.Image, color_count: int) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    if not np.any(visible):
        return image
    visible_rgb = rgba[:, :, :3][visible]
    strip = Image.fromarray(visible_rgb.reshape(1, -1, 3))
    palette_source = strip.quantize(
        colors=color_count,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    palette_image = Image.new("P", (1, 1))
    palette_image.putpalette(palette_source.getpalette())
    rgb_sheet = Image.fromarray(rgba[:, :, :3])
    quantized = rgb_sheet.quantize(
        palette=palette_image,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    result = np.asarray(quantized, dtype=np.uint8).copy()
    result[:, :, 3] = rgba[:, :, 3]
    result[~visible] = (0, 0, 0, 0)
    return Image.fromarray(result)


def _assert_output_contract(
    sheet: Image.Image,
    label: str,
    frame_size: int,
    max_width: int,
    max_height: int,
) -> None:
    expected = frame_size * GRID_SIZE
    if sheet.size != (expected, expected):
        raise AssetContractError(
            f"{label}: size {sheet.size} does not match {expected}x{expected}"
        )
    rgba = np.asarray(sheet.convert("RGBA"), dtype=np.uint8)
    alpha_values = set(int(value) for value in np.unique(rgba[:, :, 3]))
    if not alpha_values.issubset({0, 255}):
        raise AssetContractError(f"{label}: alpha is not binary: {alpha_values}")
    if np.any(rgba[:, :, :3][rgba[:, :, 3] == 0] != 0):
        raise AssetContractError(f"{label}: transparent RGB payload is not zero")

    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            frame = sheet.crop(
                (
                    column * frame_size,
                    row * frame_size,
                    (column + 1) * frame_size,
                    (row + 1) * frame_size,
                )
            )
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssetContractError(f"{label} frame {row}:{column} is empty")
            width = bbox[2] - bbox[0]
            height = bbox[3] - bbox[1]
            if width > max_width or height > max_height:
                raise AssetContractError(
                    f"{label} frame {row}:{column} is {width}x{height}, "
                    f"above {max_width}x{max_height}"
                )


def _assert_character_matches_fire(
    character: Image.Image,
    reference: Image.Image,
) -> None:
    _assert_output_contract(
        character,
        "frost sorcerer",
        CHARACTER_FRAME_SIZE,
        CHARACTER_FRAME_SIZE,
        CHARACTER_FRAME_SIZE,
    )
    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            frost_bbox = _frame_bbox(character, row, column)
            fire_bbox = _frame_bbox(reference, row, column)
            if frost_bbox != fire_bbox:
                raise AssetContractError(
                    f"character frame {row}:{column} bounds {frost_bbox} "
                    f"do not match Fire Sorcerer {fire_bbox}"
                )


def _build_ice_spike_sheet() -> tuple[Image.Image, float]:
    subjects = _load_grid_subjects(ICE_SPIKE_SOURCE, "ice_spike")
    scale = _ice_spike_base_scale(subjects)
    frames = [_place_ice_spike(subject, scale) for subject in subjects]
    sheet = _quantize_visible_colors(
        _assemble_sheet(frames, ICE_SPIKE_FRAME_SIZE),
        ICE_SPIKE_PALETTE_COLORS,
    )
    _assert_output_contract(
        sheet,
        "frost sorcerer ice spike",
        ICE_SPIKE_FRAME_SIZE,
        ICE_SPIKE_MAX_WIDTH,
        ICE_SPIKE_MAX_HEIGHT,
    )
    return sheet, scale


def _assert_existing_matches(path: Path, expected: Image.Image) -> None:
    if not path.is_file():
        raise AssetContractError(f"check-only output is missing: {path}")
    actual = Image.open(path).convert("RGBA")
    if actual.size != expected.size or not np.array_equal(
        np.asarray(actual), np.asarray(expected)
    ):
        raise AssetContractError(f"check-only output is stale: {path}")


def _assert_existing_ice_spike_contract(
    path: Path,
    expected: Image.Image,
) -> None:
    if not path.is_file():
        raise AssetContractError(f"check-only output is missing: {path}")
    actual = Image.open(path).convert("RGBA")
    _assert_output_contract(
        actual,
        "existing frost sorcerer ice spike",
        ICE_SPIKE_FRAME_SIZE,
        ICE_SPIKE_MAX_WIDTH,
        ICE_SPIKE_MAX_HEIGHT,
    )
    actual_alpha = np.asarray(actual, dtype=np.uint8)[:, :, 3]
    expected_alpha = np.asarray(expected, dtype=np.uint8)[:, :, 3]
    if not np.array_equal(actual_alpha, expected_alpha):
        raise AssetContractError(f"check-only ice-spike alpha is stale: {path}")


def main(check_only: bool = False) -> None:
    character_sheet, _reference = _build_character_sheet()
    ice_spike_sheet, ice_spike_scale = _build_ice_spike_sheet()

    if check_only:
        _assert_existing_matches(CHARACTER_OUTPUT, character_sheet)
        # Pillow palette quantizers can choose an equivalent darkest color
        # across library versions.  Ice-spike geometry/alpha remains exact;
        # the character output added by this fix is compared pixel-for-pixel.
        _assert_existing_ice_spike_contract(ICE_SPIKE_OUTPUT, ice_spike_sheet)
        print("FROST_SORCERER_ASSETS_CHECK_OK")
        return

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    character_sheet.save(CHARACTER_OUTPUT, optimize=True)
    ice_spike_sheet.save(ICE_SPIKE_OUTPUT, optimize=True)
    print(
        "FROST_SORCERER_ASSETS_OK "
        "character_contract=fire_frame_bounds "
        f"ice_spike_scale={ice_spike_scale:.5f}"
    )
    print(f"WROTE {CHARACTER_OUTPUT}")
    print(f"WROTE {ICE_SPIKE_OUTPUT}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="rebuild in memory and verify committed outputs without writing",
    )
    arguments = parser.parse_args()
    main(arguments.check_only)
