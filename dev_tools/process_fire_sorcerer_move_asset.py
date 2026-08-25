#!/usr/bin/env python3
"""Validate and install the approved native-transparent Fire Sorcerer move row.

Historical opaque ImageGen sources remain in ``dev_assets`` for provenance,
but this tool no longer derives transparency from their RGB backgrounds. New
pose work must arrive with native alpha and be rebuilt into the canonical
160x40 strip before this installer runs.
"""

from __future__ import annotations

from PIL import Image

from process_fire_sorcerer_assets import (
    AssetContractError,
    CHARACTER_FOOT_BASELINE_Y,
    CHARACTER_MOVE_NATIVE_SOURCE,
    CHARACTER_OUTPUT,
    STATIC_CHARACTER_ROWS_RGBA_SHA256,
    _audit_character_move_strip,
    _decoded_rgba_sha256,
)


def _load_native_move_strip() -> Image.Image:
    if not CHARACTER_MOVE_NATIVE_SOURCE.is_file():
        raise FileNotFoundError(
            "Missing approved native-transparent move strip: "
            f"{CHARACTER_MOVE_NATIVE_SOURCE}"
        )
    move_strip = Image.open(CHARACTER_MOVE_NATIVE_SOURCE).convert("RGBA")
    alpha_min, alpha_max = move_strip.getchannel("A").getextrema()
    if alpha_max == 0 or alpha_min == 255:
        raise AssetContractError(
            "Fire Sorcerer move strip must contain both visible and transparent "
            f"pixels: {CHARACTER_MOVE_NATIVE_SOURCE}"
        )
    _audit_character_move_strip(move_strip)
    return move_strip


def _install_move_row(move_strip: Image.Image) -> None:
    if not CHARACTER_OUTPUT.is_file():
        raise FileNotFoundError(f"Missing character sheet: {CHARACTER_OUTPUT}")
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
    if character_sheet.crop((0, 40, 160, 160)).tobytes() != protected_payload:
        raise AssetContractError(
            "Move installation mutated windup/attack/death pixels"
        )
    character_sheet.save(CHARACTER_OUTPUT, optimize=True)


def main() -> None:
    move_strip = _load_native_move_strip()
    _install_move_row(move_strip)
    print(
        "FIRE_SORCERER_MOVE_ASSET_OK "
        f"native={CHARACTER_MOVE_NATIVE_SOURCE} "
        f"sheet={CHARACTER_OUTPUT} "
        f"baseline={CHARACTER_FOOT_BASELINE_Y} "
        f"static_rows_sha256={STATIC_CHARACTER_ROWS_RGBA_SHA256}"
    )


if __name__ == "__main__":
    main()
