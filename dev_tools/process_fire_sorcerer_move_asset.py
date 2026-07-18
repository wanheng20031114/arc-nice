#!/usr/bin/env python3
"""Prepare and install the visually approved Fire Sorcerer move row.

The imagegen source is retained verbatim for provenance.  Its approximate
pixel grid is deliberately not passed through the generic unsafe compressor:
this source-specific pipeline locks the raw fingerprint and cell geometry,
samples two reviewed 29px-tall poses with nearest-neighbor resampling, and
constructs their opposite leg phases by mirroring only the lower body.

The resulting 160x40 native strip is audited before it replaces row zero of
``resources/texture/fire_sorcerer.png``.  Rows one through three are protected
by a decoded-RGBA fingerprint and remain pixel-identical.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image

from pixel_grid_analyzer import analyze_image
from process_fire_sorcerer_assets import (
    AssetContractError,
    CHARACTER_FOOT_BASELINE_Y,
    CHARACTER_FRAME_SIZE,
    CHARACTER_MOVE_NATIVE_SOURCE,
    CHARACTER_OUTPUT,
    STATIC_CHARACTER_ROWS_RGBA_SHA256,
    _audit_character_move_strip,
    _decoded_rgba_sha256,
    _despill_logical_pixels,
    _place_character_subject,
    _remove_green_screen,
)


ROOT = Path(__file__).resolve().parents[1]
RAW_SOURCE = (
    ROOT
    / "dev_assets/source_images/fire_sorcerer"
    / "fire_sorcerer_move_generated_v1.png"
)
EXPECTED_RAW_SIZE = (1983, 793)
EXPECTED_RAW_SHA256 = (
    "1d0cd4b33eb6bbf7a792fec2db03386fda0e402a8d550164d2b55a7d848e3a08"
)
EXPECTED_CELL_BBOXES = (
    (103, 186, 457, 555),
    (95, 186, 439, 555),
    (58, 186, 413, 555),
    (54, 186, 399, 555),
)
SOURCE_FRAME_SIZES = (
    (28, 29),
    (27, 29),
)
LOWER_BODY_START_Y = 23
LOWER_BODY_MIRROR_SUM = 34


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _crop_horizontal_cell(
    strip: Image.Image,
    column: int,
) -> Image.Image:
    left = round(column * strip.width / 4.0)
    right = round((column + 1) * strip.width / 4.0)
    return strip.crop((left, 0, right, strip.height))


def _load_and_validate_raw_source() -> Image.Image:
    if not RAW_SOURCE.is_file():
        raise FileNotFoundError(f"Missing move imagegen source: {RAW_SOURCE}")
    source_sha256 = _file_sha256(RAW_SOURCE)
    if source_sha256 != EXPECTED_RAW_SHA256:
        raise AssetContractError(
            "Move imagegen source fingerprint changed: "
            f"{source_sha256}"
        )
    raw = Image.open(RAW_SOURCE).convert("RGBA")
    if raw.size != EXPECTED_RAW_SIZE:
        raise AssetContractError(
            f"Move imagegen source is {raw.size}, expected {EXPECTED_RAW_SIZE}"
        )
    source, key = _remove_green_screen(raw)
    if key[1] <= key[0] + 80 or key[1] <= key[2] + 80:
        raise AssetContractError(
            f"Move source border is not a dominant green key: {key}"
        )
    for column in range(4):
        cell = _crop_horizontal_cell(source, column)
        bbox = cell.getchannel("A").getbbox()
        if bbox != EXPECTED_CELL_BBOXES[column]:
            raise AssetContractError(
                f"Move source cell {column} bbox {bbox} changed from "
                f"{EXPECTED_CELL_BBOXES[column]}"
            )
        if (
            bbox[0] < 16
            or bbox[1] < 16
            or bbox[2] > cell.width - 16
            or bbox[3] > cell.height - 16
        ):
            raise AssetContractError(
                f"Move source cell {column} touches its safety margin"
            )
        analysis = analyze_image(cell)
        print(
            f"MOVE_SOURCE_CELL column={column} "
            f"confidence={analysis['confidence']:.3f} "
            f"mode={analysis['detection_mode']} "
            f"bbox={bbox}"
        )
    print(
        "MOVE_SOURCE_OK "
        f"size={raw.width}x{raw.height} "
        f"key=#{key[0]:02x}{key[1]:02x}{key[2]:02x} "
        f"sha256={source_sha256}"
    )
    return source


def _sample_reviewed_frame(
    cell: Image.Image,
    logical_size: tuple[int, int],
) -> Image.Image:
    bbox = cell.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError("Reviewed move source frame is empty")
    subject = cell.crop(bbox).resize(
        logical_size,
        Image.Resampling.NEAREST,
    )
    return _place_character_subject(_despill_logical_pixels(subject))


def _mirror_lower_body(frame: Image.Image) -> Image.Image:
    source = frame.convert("RGBA")
    result = source.copy()
    source_pixels = source.load()
    result_pixels = result.load()
    for y in range(LOWER_BODY_START_Y, CHARACTER_FRAME_SIZE):
        for x in range(CHARACTER_FRAME_SIZE):
            result_pixels[x, y] = (0, 0, 0, 0)
        for x in range(CHARACTER_FRAME_SIZE):
            mirrored_x = LOWER_BODY_MIRROR_SUM - x
            if (
                0 <= mirrored_x < CHARACTER_FRAME_SIZE
                and source_pixels[x, y][3] > 0
            ):
                result_pixels[mirrored_x, y] = source_pixels[x, y]
    return result


def _build_native_move_strip(source: Image.Image) -> Image.Image:
    contact_a = _sample_reviewed_frame(
        _crop_horizontal_cell(source, 0),
        SOURCE_FRAME_SIZES[0],
    )
    passing_a = _sample_reviewed_frame(
        _crop_horizontal_cell(source, 1),
        SOURCE_FRAME_SIZES[1],
    )
    frames = (
        contact_a,
        passing_a,
        _mirror_lower_body(contact_a),
        _mirror_lower_body(passing_a),
    )
    strip = Image.new(
        "RGBA",
        (CHARACTER_FRAME_SIZE * 4, CHARACTER_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    for frame_index, frame in enumerate(frames):
        strip.paste(
            frame,
            (frame_index * CHARACTER_FRAME_SIZE, 0),
        )
    _audit_character_move_strip(strip)
    return strip


def _install_move_row(move_strip: Image.Image) -> None:
    if not CHARACTER_OUTPUT.is_file():
        raise FileNotFoundError(
            f"Missing character sheet: {CHARACTER_OUTPUT}"
        )
    character_sheet = Image.open(CHARACTER_OUTPUT).convert("RGBA")
    if character_sheet.size != (160, 160):
        raise AssetContractError(
            f"Character sheet is {character_sheet.size}, expected 160x160"
        )
    static_rows = character_sheet.crop((0, 40, 160, 160))
    static_rows_sha256 = _decoded_rgba_sha256(static_rows)
    if static_rows_sha256 != STATIC_CHARACTER_ROWS_RGBA_SHA256:
        raise AssetContractError(
            "Refusing to replace move row because a protected animation row "
            f"changed: {static_rows_sha256}"
        )
    protected_payload = static_rows.tobytes()
    character_sheet.paste(move_strip, (0, 0))
    if (
        character_sheet.crop((0, 40, 160, 160)).tobytes()
        != protected_payload
    ):
        raise AssetContractError(
            "Move installation mutated windup/attack/death pixels"
        )
    character_sheet.save(CHARACTER_OUTPUT, optimize=True)


def main() -> None:
    source = _load_and_validate_raw_source()
    move_strip = _build_native_move_strip(source)
    CHARACTER_MOVE_NATIVE_SOURCE.parent.mkdir(
        parents=True,
        exist_ok=True,
    )
    move_strip.save(CHARACTER_MOVE_NATIVE_SOURCE, optimize=True)
    reloaded_move = Image.open(
        CHARACTER_MOVE_NATIVE_SOURCE
    ).convert("RGBA")
    _audit_character_move_strip(reloaded_move)
    _install_move_row(reloaded_move)
    print(
        "FIRE_SORCERER_MOVE_ASSET_OK "
        f"native={CHARACTER_MOVE_NATIVE_SOURCE} "
        f"sheet={CHARACTER_OUTPUT} "
        f"baseline={CHARACTER_FOOT_BASELINE_Y} "
        f"static_rows_sha256={STATIC_CHARACTER_ROWS_RGBA_SHA256}"
    )


if __name__ == "__main__":
    main()
