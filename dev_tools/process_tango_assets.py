#!/usr/bin/env python3
"""Build Tango's native-resolution pixel sheets from the approved imagegen boards.

The imagegen inputs are deliberately kept as source material.  This script performs
only deterministic operations.  Character animation boards are reduced and palette
snapped; the casting unit is a direct 8x8-grid transcription of its imagegen design,
so it is never damaged by another downscale pass.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image

from pixel_crop_tool import normalize_transparency
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "tango"
TEXTURE_DIR = ROOT / "resources" / "texture" / "player" / "tango"
PREVIEW_DIR = ROOT / "dev_assets" / "generated_previews"

USER_FRONT_FIX_PATH = SOURCE_DIR / "tango_front_user_fix_v3.png"
REFERENCE_PATH = SOURCE_DIR / "tango_idle_front_32_v3.png"
DIRECTION_REFERENCE_PATHS = (
    REFERENCE_PATH,
    SOURCE_DIR / "tango_move_up_frame0_user_fix_v3.png",
    SOURCE_DIR / "tango_move_right_frame0_user_fix_v3.png",
    SOURCE_DIR / "tango_move_left_frame0_user_fix_v3.png",
)
MOVE_BOARD_PATH = SOURCE_DIR / "tango_move_board_v1_imagegen.png"
DEATH_BOARD_PATH = SOURCE_DIR / "tango_death_board_v1_imagegen.png"
UNIT_IMAGEGEN_DESIGN_PATH = (
    SOURCE_DIR / "tango_cast_unit_native_8x8_v2_imagegen.png"
)
UNIT_NATIVE_SOURCE_PATH = SOURCE_DIR / "tango_cast_unit_native_8x8_v2.png"

MOVE_OUTPUT_PATH = TEXTURE_DIR / "tango_move.png"
DEATH_OUTPUT_PATH = TEXTURE_DIR / "tango_death.png"
UNIT_OUTPUT_PATH = TEXTURE_DIR / "tango_cast_unit.png"
IDLE_OUTPUT_PATH = TEXTURE_DIR / "tango_idle_front_32.png"
PORTRAIT_OUTPUT_PATH = TEXTURE_DIR / "portrait.png"

MOVE_PREVIEW_PATH = PREVIEW_DIR / "tango_move_v5_weighted_gait_preview.png"
MOVE_ANIMATED_PREVIEW_PATH = PREVIEW_DIR / "tango_move_v5_weighted_gait_preview.gif"
DOWN_MOVE_PREVIEW_PATH = PREVIEW_DIR / "tango_move_down_v5_weighted_gait_preview.png"
DOWN_MOVE_ANIMATED_PREVIEW_PATH = (
    PREVIEW_DIR / "tango_move_down_v5_weighted_gait_preview.gif"
)
DEATH_PREVIEW_PATH = PREVIEW_DIR / "tango_death_v1_preview.png"
UNIT_PREVIEW_PATH = PREVIEW_DIR / "tango_cast_unit_v2_preview.png"
OVERVIEW_PREVIEW_PATH = PREVIEW_DIR / "tango_animation_overview_v5.png"

FRAME_SIZE = 32
UNIT_FRAME_SIZE = 8
MOVE_BASELINE = 28
DEATH_BASELINE = 28
EYE_CYAN = (56, 236, 243, 255)
EYE_COORDINATES = ((15, 11), (15, 12), (18, 11), (18, 12))
USER_EYE_COORDINATES = ((8, 6), (8, 7), (11, 6), (11, 7))
MOVE_STABLE_BODY_BOTTOM = 23
# Two low poses per four-frame step create a restrained one-pixel body bob. The
# body is translated as one rigid bitmap; its internal pixels are never redrawn.
MOVE_BOB_OFFSETS = (0, 1, 1, 0, 0, 1, 1, 0)
# During each single-support half-cycle the unchanged torso shifts one pixel over
# the planted leg. This is a deliberate weight transfer, not regenerated noise.
DOWN_BODY_X_OFFSETS = (0, -1, -1, -1, 0, 1, 1, 1)

# The repaired frame remains the first/contact frame. The other seven lower-body
# patches are authored on Tango's final one-pixel grid. Unlike the former rigid
# leg-block offsets, every support phase changes the knee, ankle, and footprint:
# contact -> load/compress -> heel roll/passing -> toe push-off, then swaps sides.
DOWN_GAIT_PATCH_ORIGIN = (8, 23)
DOWN_GAIT_PATCH_SIZE = (16, 5)
DOWN_GAIT_PHASES = (
    "contact_left",
    "load_left",
    "pass_left",
    "push_left",
    "contact_right",
    "load_right",
    "pass_right",
    "push_right",
)
DOWN_GAIT_PATCH_ROWS = (
    None,  # Frame zero is the user's exact repaired 32x32 frame.
    (
        "................",
        "...#SmS#..#gG#..",
        "..#mdsd#.#mG#...",
        "..#mSSm##GG#....",
        "..#@@@#..#......",
    ),
    (
        "................",
        "...#SmS#..#gG#..",
        "...#mdsd##mGG#..",
        "...#mSSm##GGG#..",
        "...#@@@#........",
    ),
    (
        "...#SmS#.#####..",
        "...#mds#..#gG#..",
        "....#mSS##mGG#..",
        "....######GGG#..",
        "......##....##..",
    ),
    (
        "...#SmS#.#####..",
        "....#mds#.#gGG#.",
        ".....#mS#.#mGG#.",
        ".....###..#####.",
        "......##..#####.",
    ),
    (
        "................",
        "...#SmS#..#gG#..",
        "....#mds#.#mGG#.",
        ".....####.#GGG#.",
        ".......#..#####.",
    ),
    (
        "................",
        "...#SmS#..#gG#..",
        "...#mds#.#mGGG#.",
        "...#mSS#.#GGGG#.",
        ".........#####..",
    ),
    (
        "...#SmS#.#####..",
        "..#mds#...#gG#..",
        "...#mSS#.#mGG#..",
        "...#####.#GG#...",
        "...##....##.....",
    ),
)

# Compact palette derived from the approved 32x32 Tango.  All runtime sprites use
# this exact palette so imagegen frame-to-frame color drift cannot shimmer in game.
PALETTE = (
    (21, 22, 19, 255),       # outline
    (29, 28, 30, 255),       # deepest plate shadow
    (67, 70, 72, 255),       # joint shadow
    (97, 100, 103, 255),     # dark steel
    (100, 104, 107, 255),    # approved dark steel variation
    (124, 130, 130, 255),    # middle steel
    (66, 62, 63, 255),       # approved joint metal
    (170, 169, 166, 255),    # plate gray
    (173, 172, 168, 255),    # approved plate gray variation
    (211, 209, 207, 255),    # approved plate highlight variation
    (217, 215, 213, 255),    # plate highlight
    (241, 240, 234, 255),    # chipped edge highlight
    (43, 110, 116, 255),     # unlit cyan glass
    EYE_CYAN,                 # active cyan
)

DOWN_GAIT_COLORS = {
    "#": PALETTE[0],
    "@": PALETTE[1],
    "d": PALETTE[2],
    "s": PALETTE[3],
    "S": PALETTE[4],
    "m": PALETTE[5],
    "j": PALETTE[6],
    "g": PALETTE[7],
    "G": PALETTE[8],
    "h": PALETTE[9],
    "H": PALETTE[10],
    "W": PALETTE[11],
}

# This compact silhouette is transcribed from UNIT_IMAGEGEN_DESIGN_PATH directly
# onto the final logical grid.  Static chassis pixels never change between states;
# only the four energy channels (K/P/E/T) animate, which prevents silhouette boil.
UNIT_TEMPLATE = (
    "..OOOO..",
    ".OLKKLO.",
    "OOLLLLOO",
    "OPOOOOPO",
    "OLOEEOLO",
    ".OLLLLO.",
    "..ODDO..",
    "...TT...",
)
UNIT_OUTLINE = PALETTE[0]
UNIT_DARK_STEEL = PALETTE[2]
UNIT_POD_STEEL = PALETTE[5]
UNIT_PLATE = PALETTE[8]
UNIT_HIGHLIGHT = PALETTE[10]
UNIT_HOT = PALETTE[11]
UNIT_DIM_CYAN = PALETTE[12]

# Rows remain orbit / charge / fire, four frames each.  The imagegen design supplies
# the shape; these native-cell energy changes make it usable for a 2.4-second charge
# and a sustained 2-to-5-second barrage loop without introducing subpixel details.
UNIT_FRAME_SPECS = (
    # orbit: calm core and a restrained alternating thruster pulse
    (UNIT_HIGHLIGHT, UNIT_POD_STEEL, EYE_CYAN, UNIT_DIM_CYAN),
    (UNIT_HIGHLIGHT, UNIT_POD_STEEL, EYE_CYAN, EYE_CYAN),
    (UNIT_HIGHLIGHT, UNIT_POD_STEEL, UNIT_DIM_CYAN, EYE_CYAN),
    (UNIT_HIGHLIGHT, UNIT_POD_STEEL, EYE_CYAN, UNIT_DIM_CYAN),
    # charge: energy spreads from the core into both side stabilizers and cap
    (UNIT_HIGHLIGHT, UNIT_POD_STEEL, UNIT_DIM_CYAN, UNIT_DIM_CYAN),
    (UNIT_HIGHLIGHT, UNIT_DIM_CYAN, EYE_CYAN, EYE_CYAN),
    (UNIT_HIGHLIGHT, EYE_CYAN, EYE_CYAN, EYE_CYAN),
    (EYE_CYAN, EYE_CYAN, EYE_CYAN, EYE_CYAN),
    # fire: the chassis stays fixed while cyan/white-hot channels pulse
    (EYE_CYAN, UNIT_DIM_CYAN, EYE_CYAN, EYE_CYAN),
    (EYE_CYAN, EYE_CYAN, UNIT_HOT, EYE_CYAN),
    (EYE_CYAN, UNIT_HOT, EYE_CYAN, EYE_CYAN),
    (EYE_CYAN, EYE_CYAN, UNIT_HOT, UNIT_HOT),
)


@dataclass(frozen=True)
class ExtractedFrame:
    image: Image.Image
    source_bbox: tuple[int, int, int, int]


def _is_chroma(red: int, green: int, blue: int) -> bool:
    """Classify magenta and its antialiased spill without eating gray/cyan art."""
    return min(red, blue) - green >= 16


def _remove_chroma(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, _alpha = pixels[x, y]
            if _is_chroma(red, green, blue):
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (red, green, blue, 255)
    return normalize_transparency(rgba)


def _runs(values: Iterable[bool]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    start: int | None = None
    for index, value in enumerate([*values, False]):
        if value and start is None:
            start = index
        elif not value and start is not None:
            result.append((start, index))
            start = None
    return result


def _extract_board(
    board_path: Path,
    *,
    columns: int,
    rows: int,
) -> list[list[ExtractedFrame]]:
    keyed = _remove_chroma(Image.open(board_path))
    alpha = keyed.getchannel("A")
    alpha_pixels = alpha.load()
    extracted: list[list[ExtractedFrame]] = []

    for row in range(rows):
        top = round(row * keyed.height / rows)
        bottom = round((row + 1) * keyed.height / rows)
        foreground_counts = [
            sum(alpha_pixels[x, y] > 0 for y in range(top, bottom))
            for x in range(keyed.width)
        ]
        column_runs = _runs(count >= 3 for count in foreground_counts)
        if len(column_runs) != columns:
            raise ValueError(
                f"{board_path.name} row {row}: expected {columns} subjects, "
                f"found {len(column_runs)} ({column_runs})"
            )

        row_frames: list[ExtractedFrame] = []
        for left, right in column_runs:
            slot = keyed.crop((left, top, right, bottom))
            bbox = slot.getchannel("A").getbbox()
            if bbox is None:
                raise ValueError(f"{board_path.name} row {row}: empty subject")
            cropped = slot.crop(bbox)
            source_bbox = (
                left + bbox[0],
                top + bbox[1],
                left + bbox[2],
                top + bbox[3],
            )
            row_frames.append(ExtractedFrame(cropped, source_bbox))
        extracted.append(row_frames)

    return extracted


def _distance_squared(left: tuple[int, ...], right: tuple[int, ...]) -> int:
    # Green contributes slightly more to perceived brightness; this keeps adjacent
    # steel tones stable while preserving the cyan accent.
    return (
        2 * (left[0] - right[0]) ** 2
        + 3 * (left[1] - right[1]) ** 2
        + 2 * (left[2] - right[2]) ** 2
    )


def _snap_palette(image: Image.Image) -> Image.Image:
    rgba = normalize_transparency(image)
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                pixels[x, y] = (0, 0, 0, 0)
                continue
            if green >= 135 and blue >= 145 and red <= 120:
                pixels[x, y] = EYE_CYAN
                continue
            pixels[x, y] = min(
                PALETTE,
                key=lambda color: _distance_squared((red, green, blue), color),
            )
    return rgba


def _resize_native(
    image: Image.Image,
    *,
    max_width: int,
    max_height: int,
    scale: float | None = None,
) -> Image.Image:
    if scale is None:
        scale = min(max_width / image.width, max_height / image.height)
    target_width = max(1, min(max_width, round(image.width * scale)))
    target_height = max(1, min(max_height, round(image.height * scale)))
    resized = image.resize(
        (target_width, target_height),
        Image.Resampling.NEAREST,
    )
    return _snap_palette(resized)


def _place_on_frame(
    subject: Image.Image,
    *,
    frame_size: int,
    baseline: int | None = None,
) -> Image.Image:
    frame = Image.new("RGBA", (frame_size, frame_size), (0, 0, 0, 0))
    x = (frame_size - subject.width) // 2
    y = (
        (frame_size - subject.height) // 2
        if baseline is None
        else baseline - subject.height
    )
    frame.alpha_composite(subject, (x, y))
    return normalize_transparency(frame)


def _build_reference_from_user_fix() -> Image.Image:
    """Place the approved 18x23 front frame without scaling it.

    The supplied repair uses pure black for nine outline cells.  They represent
    the existing outline ramp rather than a new material color, so normalize
    only those cells and preserve every other RGBA value.
    """
    source = Image.open(USER_FRONT_FIX_PATH).convert("RGBA")
    if source.size != (18, 23):
        raise AssertionError(
            f"approved front fix must be 18x23, got {source.size}"
        )
    if source.getchannel("A").getbbox() != (0, 0, 18, 23):
        raise AssertionError("approved front fix bounds changed")
    for coordinate in USER_EYE_COORDINATES:
        if source.getpixel(coordinate) != EYE_CYAN:
            raise AssertionError(
                f"approved front eye {coordinate} is not one-pixel bright cyan"
            )

    normalized = source.copy()
    pixels = normalized.load()
    for y in range(normalized.height):
        for x in range(normalized.width):
            if pixels[x, y] == (0, 0, 0, 255):
                pixels[x, y] = PALETTE[0]
    normalized = normalize_transparency(normalized)
    reference = _place_on_frame(
        normalized,
        frame_size=FRAME_SIZE,
        baseline=MOVE_BASELINE,
    )
    if reference.getchannel("A").getbbox() != (7, 5, 25, 28):
        raise AssertionError("approved front fix placement drifted")
    for coordinate in EYE_COORDINATES:
        if reference.getpixel(coordinate) != EYE_CYAN:
            raise AssertionError(f"runtime front eye {coordinate} drifted")
    REFERENCE_PATH.parent.mkdir(parents=True, exist_ok=True)
    reference.save(REFERENCE_PATH, optimize=True)
    return reference


def _frame_from_sheet(sheet: Image.Image, row: int, column: int) -> Image.Image:
    return sheet.crop(
        (
            column * FRAME_SIZE,
            row * FRAME_SIZE,
            (column + 1) * FRAME_SIZE,
            (row + 1) * FRAME_SIZE,
        )
    )


def _load_direction_references(front_reference: Image.Image) -> list[Image.Image]:
    references = [front_reference]
    for path in DIRECTION_REFERENCE_PATHS[1:]:
        reference = normalize_transparency(Image.open(path).convert("RGBA"))
        if reference.size != (FRAME_SIZE, FRAME_SIZE):
            raise AssertionError(
                f"direction reference {path.name} must be 32x32, got {reference.size}"
            )
        bbox = reference.getchannel("A").getbbox()
        if bbox is None or bbox[3] != MOVE_BASELINE or bbox[3] - bbox[1] > 24:
            raise AssertionError(
                f"direction reference {path.name} violates geometry: {bbox}"
            )
        unexpected = {
            pixel for pixel in reference.getdata()
            if pixel[3] > 0 and pixel not in PALETTE
        }
        if unexpected:
            raise AssertionError(
                f"direction reference {path.name} has unexpected colors: "
                f"{sorted(unexpected)}"
            )
        references.append(reference)
    return references


def _render_down_gait_patch(column: int) -> Image.Image:
    rows = DOWN_GAIT_PATCH_ROWS[column]
    if rows is None:
        raise AssertionError("the repaired contact frame has no generated patch")
    if len(rows) != DOWN_GAIT_PATCH_SIZE[1]:
        raise AssertionError(
            f"down gait frame {column} has {len(rows)} patch rows"
        )
    patch = Image.new("RGBA", DOWN_GAIT_PATCH_SIZE, (0, 0, 0, 0))
    for y, row in enumerate(rows):
        if len(row) != DOWN_GAIT_PATCH_SIZE[0]:
            raise AssertionError(
                f"down gait frame {column} row {y} has width {len(row)}"
            )
        for x, token in enumerate(row):
            if token == ".":
                continue
            color = DOWN_GAIT_COLORS.get(token)
            if color is None:
                raise AssertionError(
                    f"down gait frame {column} uses unknown token {token!r}"
                )
            patch.putpixel((x, y), color)
    return normalize_transparency(patch)


def _build_weighted_down_gait(
    sheet: Image.Image,
    front_reference: Image.Image,
) -> Image.Image:
    """Author a real contact/load/pass/push cycle below the fixed torso.

    Frame zero remains exactly the user's repair. Each later frame starts from a
    clean canvas, draws a native-resolution lower-body patch, then places the
    unchanged torso over the hip seam. This prevents both generated texture boil
    and stale leg pixels while allowing the planted leg itself to compress, roll,
    and push off instead of acting as an immobile prop.
    """
    if len(DOWN_GAIT_PHASES) != 8 or len(DOWN_GAIT_PATCH_ROWS) != 8:
        raise AssertionError("the down gait must contain exactly eight phases")

    weighted = sheet.copy()
    canonical_upper = front_reference.crop(
        (0, 0, FRAME_SIZE, MOVE_STABLE_BODY_BOTTOM)
    )
    for column, (body_x, bob_offset) in enumerate(
        zip(DOWN_BODY_X_OFFSETS, MOVE_BOB_OFFSETS, strict=True)
    ):
        if column == 0:
            frame = front_reference.copy()
        else:
            frame = Image.new(
                "RGBA",
                (FRAME_SIZE, FRAME_SIZE),
                (0, 0, 0, 0),
            )
            frame.alpha_composite(
                _render_down_gait_patch(column),
                DOWN_GAIT_PATCH_ORIGIN,
            )
            # The torso owns the hip seam, so any leg pixel under it is hidden in
            # the same deterministic order in every frame.
            frame.alpha_composite(canonical_upper, (body_x, bob_offset))
        weighted.paste(frame, (column * FRAME_SIZE, 0))
    return normalize_transparency(weighted)


def _stabilize_move_sheet(
    sheet: Image.Image,
    direction_references: list[Image.Image],
) -> Image.Image:
    """Transplant one rigid, one-pixel-bobbing body per direction.

    The lower rows retain the generated gait. Head shell, face, eyes, torso,
    highlights and arms come from the user's repaired first frame for each
    direction. The complete body moves down by at most one pixel, eliminating
    texture boil without flattening the walk cycle's vertical weight shift.
    """
    stabilized = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
    for row, canonical in enumerate(direction_references):
        fixed_upper = canonical.crop(
            (0, 0, FRAME_SIZE, MOVE_STABLE_BODY_BOTTOM)
        )
        for column, bob_offset in enumerate(MOVE_BOB_OFFSETS):
            frame = _frame_from_sheet(sheet, row, column)
            original_lower = frame.crop(
                (0, MOVE_STABLE_BODY_BOTTOM + 1, FRAME_SIZE, FRAME_SIZE)
            ).tobytes()
            frame.paste(
                (0, 0, 0, 0),
                (0, 0, FRAME_SIZE, MOVE_STABLE_BODY_BOTTOM),
            )
            frame.alpha_composite(fixed_upper, (0, bob_offset))
            if column == 0:
                # Preserve every user's repaired first frame in full, including
                # its authored legs, as the idle/contact pose for that direction.
                frame = canonical.copy()
            elif frame.crop(
                (0, MOVE_STABLE_BODY_BOTTOM + 1, FRAME_SIZE, FRAME_SIZE)
            ).tobytes() != original_lower:
                raise AssertionError(
                    f"move row {row} frame {column} changed the core gait rows"
                )
            stabilized.alpha_composite(
                normalize_transparency(frame),
                (column * FRAME_SIZE, row * FRAME_SIZE),
            )
    return normalize_transparency(stabilized)


def _assert_stable_move_contract(
    sheet: Image.Image,
    direction_references: list[Image.Image],
) -> None:
    for row in range(4):
        frames = [_frame_from_sheet(sheet, row, column) for column in range(8)]
        canonical = direction_references[row]
        expected_upper = canonical.crop(
            (0, 0, FRAME_SIZE, MOVE_STABLE_BODY_BOTTOM)
        )
        if frames[0].tobytes() != canonical.tobytes():
            raise AssertionError(
                f"move row {row} frame 0 must match its repaired reference"
            )
        for column, (frame, bob_offset) in enumerate(
            zip(frames, MOVE_BOB_OFFSETS, strict=True)
        ):
            body_x = DOWN_BODY_X_OFFSETS[column] if row == 0 else 0
            bbox = frame.getchannel("A").getbbox()
            if bbox is None or bbox[3] != MOVE_BASELINE:
                raise AssertionError(
                    f"move row {row} frame {column} baseline drift: {bbox}"
                )
            if bbox[3] - bbox[1] > 24:
                raise AssertionError(
                    f"move row {row} frame {column} exceeds 24px: {bbox}"
                )
            expected_body = Image.new(
                "RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0)
            )
            expected_body.alpha_composite(
                expected_upper,
                (body_x, bob_offset),
            )
            for y in range(MOVE_STABLE_BODY_BOTTOM + bob_offset):
                for x in range(FRAME_SIZE):
                    expected_pixel = expected_body.getpixel((x, y))
                    actual_pixel = frame.getpixel((x, y))
                    if expected_pixel[3] > 0 and actual_pixel != expected_pixel:
                        raise AssertionError(
                            f"move row {row} frame {column} body changed at "
                            f"{(x, y)} with offset={(body_x, bob_offset)}"
                        )
                    if (
                        expected_pixel[3] == 0
                        and y < MOVE_STABLE_BODY_BOTTOM
                        and actual_pixel[3] != 0
                    ):
                        raise AssertionError(
                            f"move row {row} frame {column} left a body remnant at "
                            f"{(x, y)}"
                        )
            for y in range(bob_offset):
                if frame.crop((0, y, FRAME_SIZE, y + 1)).getchannel("A").getbbox():
                    raise AssertionError(
                        f"move row {row} frame {column} did not vacate bob row {y}"
                    )
        lower_hashes = {
            frame.crop(
                (0, MOVE_STABLE_BODY_BOTTOM + 1, FRAME_SIZE, FRAME_SIZE)
            ).tobytes()
            for frame in frames
        }
        if len(lower_hashes) < 4:
            raise AssertionError(
                f"move row {row} lost its gait variation: {len(lower_hashes)}"
            )

    for column, bob_offset in enumerate(MOVE_BOB_OFFSETS):
        down_frame = _frame_from_sheet(sheet, 0, column)
        for base_y in (11, 12):
            eye_y = base_y + bob_offset
            bright_x = [
                x for x in range(FRAME_SIZE)
                if down_frame.getpixel((x, eye_y)) == EYE_CYAN
            ]
            expected_eye_x = [
                15 + DOWN_BODY_X_OFFSETS[column],
                18 + DOWN_BODY_X_OFFSETS[column],
            ]
            if bright_x != expected_eye_x:
                raise AssertionError(
                    f"front frame {column} eyes must each be one pixel wide: "
                    f"y={eye_y}, x={bright_x}"
                )


def _build_move_sheet(
    direction_references: list[Image.Image],
) -> tuple[Image.Image, list[dict]]:
    source_rows = _extract_board(MOVE_BOARD_PATH, columns=8, rows=4)
    # Imagegen board rows are down, left, right, up. Runtime contract is
    # down, up, right, left.
    source_row_order = (0, 3, 2, 1)
    sheet = Image.new("RGBA", (FRAME_SIZE * 8, FRAME_SIZE * 4), (0, 0, 0, 0))
    report: list[dict] = []

    for output_row, source_row in enumerate(source_row_order):
        row_frames = source_rows[source_row]
        row_scale = 24.0 / max(frame.image.height for frame in row_frames)
        for column, extracted in enumerate(row_frames):
            native = _resize_native(
                extracted.image,
                max_width=30,
                max_height=24,
                scale=row_scale,
            )
            frame = _place_on_frame(
                native,
                frame_size=FRAME_SIZE,
                baseline=MOVE_BASELINE,
            )
            sheet.alpha_composite(frame, (column * FRAME_SIZE, output_row * FRAME_SIZE))
            bbox = frame.getchannel("A").getbbox()
            report.append(
                {
                    "row": output_row,
                    "column": column,
                    "bbox": bbox,
                    "source_bbox": extracted.source_bbox,
                }
            )
    sheet = _stabilize_move_sheet(
        normalize_transparency(sheet),
        direction_references,
    )
    sheet = _build_weighted_down_gait(
        sheet,
        direction_references[0],
    )
    _assert_stable_move_contract(sheet, direction_references)
    for item in report:
        item["bbox"] = _frame_from_sheet(
            sheet,
            int(item["row"]),
            int(item["column"]),
        ).getchannel("A").getbbox()
    return sheet, report


def _build_death_sheet() -> tuple[Image.Image, list[dict]]:
    source_rows = _extract_board(DEATH_BOARD_PATH, columns=4, rows=2)
    source_frames = [frame for row in source_rows for frame in row]
    sheet = Image.new("RGBA", (FRAME_SIZE * 8, FRAME_SIZE), (0, 0, 0, 0))
    report: list[dict] = []
    for column, extracted in enumerate(source_frames):
        native = _resize_native(
            extracted.image,
            max_width=30,
            max_height=24,
        )
        frame = _place_on_frame(
            native,
            frame_size=FRAME_SIZE,
            baseline=DEATH_BASELINE,
        )
        sheet.alpha_composite(frame, (column * FRAME_SIZE, 0))
        report.append(
            {
                "column": column,
                "bbox": frame.getchannel("A").getbbox(),
                "source_bbox": extracted.source_bbox,
            }
        )
    return normalize_transparency(sheet), report


def _render_native_unit_frame(
    spec: tuple[
        tuple[int, int, int, int],
        tuple[int, int, int, int],
        tuple[int, int, int, int],
        tuple[int, int, int, int],
    ],
) -> Image.Image:
    cap, pods, core, thruster = spec
    colors = {
        "O": UNIT_OUTLINE,
        "D": UNIT_DARK_STEEL,
        "L": UNIT_PLATE,
        "K": cap,
        "P": pods,
        "E": core,
        "T": thruster,
    }
    frame = Image.new(
        "RGBA",
        (UNIT_FRAME_SIZE, UNIT_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    for y, row in enumerate(UNIT_TEMPLATE):
        if len(row) != UNIT_FRAME_SIZE:
            raise AssertionError(f"invalid unit row width at y={y}: {row!r}")
        for x, token in enumerate(row):
            if token == ".":
                continue
            frame.putpixel((x, y), colors[token])
    return normalize_transparency(frame)


def _build_unit_sheet() -> tuple[Image.Image, list[dict], Image.Image]:
    if not UNIT_IMAGEGEN_DESIGN_PATH.exists():
        raise FileNotFoundError(UNIT_IMAGEGEN_DESIGN_PATH)
    sheet = Image.new(
        "RGBA",
        (UNIT_FRAME_SIZE * 4, UNIT_FRAME_SIZE * 3),
        (0, 0, 0, 0),
    )
    report: list[dict] = []
    native_frames = [_render_native_unit_frame(spec) for spec in UNIT_FRAME_SPECS]
    for index, frame in enumerate(native_frames):
        row, column = divmod(index, 4)
        sheet.alpha_composite(
            frame,
            (column * UNIT_FRAME_SIZE, row * UNIT_FRAME_SIZE),
        )
        report.append(
            {
                "row": row,
                "column": column,
                "bbox": frame.getchannel("A").getbbox(),
                "source": UNIT_IMAGEGEN_DESIGN_PATH.name,
            }
        )
    return normalize_transparency(sheet), report, native_frames[0]


def _preview(image: Image.Image, scale: int, background=(20, 28, 44, 255)) -> Image.Image:
    backdrop = Image.new("RGBA", image.size, background)
    backdrop.alpha_composite(image)
    return backdrop.resize(
        (image.width * scale, image.height * scale),
        Image.Resampling.NEAREST,
    )


def _save_outputs(
    reference: Image.Image,
    move: Image.Image,
    death: Image.Image,
    unit: Image.Image,
    unit_native: Image.Image,
) -> None:
    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    move.save(MOVE_OUTPUT_PATH, optimize=True)
    death.save(DEATH_OUTPUT_PATH, optimize=True)
    unit.save(UNIT_OUTPUT_PATH, optimize=True)
    unit_native.save(UNIT_NATIVE_SOURCE_PATH, optimize=True)
    reference.save(IDLE_OUTPUT_PATH, optimize=True)
    portrait = reference.resize((160, 160), Image.Resampling.NEAREST)
    portrait.save(PORTRAIT_OUTPUT_PATH, optimize=True)

    move_preview = _preview(move, 4)
    down_move = move.crop((0, 0, FRAME_SIZE * 8, FRAME_SIZE))
    down_move_preview = _preview(down_move, 8)
    death_preview = _preview(death, 4)
    unit_preview = _preview(unit, 12)
    move_preview.save(MOVE_PREVIEW_PATH, optimize=True)
    down_move_preview.save(DOWN_MOVE_PREVIEW_PATH, optimize=True)
    death_preview.save(DEATH_PREVIEW_PATH, optimize=True)
    unit_preview.save(UNIT_PREVIEW_PATH, optimize=True)

    animated_frames: list[Image.Image] = []
    for column in range(8):
        strip = Image.new("RGBA", (FRAME_SIZE * 4, FRAME_SIZE), (20, 28, 44, 255))
        for row in range(4):
            strip.alpha_composite(
                _frame_from_sheet(move, row, column),
                (row * FRAME_SIZE, 0),
            )
        animated_frames.append(
            strip.resize((FRAME_SIZE * 16, FRAME_SIZE * 4), Image.Resampling.NEAREST)
        )
    animated_frames[0].save(
        MOVE_ANIMATED_PREVIEW_PATH,
        save_all=True,
        append_images=animated_frames[1:],
        duration=71,
        loop=0,
        disposal=2,
    )

    down_animated_frames = [
        _preview(_frame_from_sheet(move, 0, column), 8)
        for column in range(8)
    ]
    down_animated_frames[0].save(
        DOWN_MOVE_ANIMATED_PREVIEW_PATH,
        save_all=True,
        append_images=down_animated_frames[1:],
        duration=71,
        loop=0,
        disposal=2,
    )

    gap = 24
    overview_width = max(move_preview.width, death_preview.width, unit_preview.width)
    overview_height = (
        move_preview.height + death_preview.height + unit_preview.height + gap * 2
    )
    overview = Image.new("RGBA", (overview_width, overview_height), (13, 19, 31, 255))
    cursor_y = 0
    for preview in (move_preview, death_preview, unit_preview):
        overview.alpha_composite(preview, ((overview_width - preview.width) // 2, cursor_y))
        cursor_y += preview.height + gap
    overview.save(OVERVIEW_PREVIEW_PATH, optimize=True)


def main() -> None:
    reference = _build_reference_from_user_fix()
    direction_references = _load_direction_references(reference)
    move, move_report = _build_move_sheet(direction_references)
    death, death_report = _build_death_sheet()
    unit, unit_report, unit_native = _build_unit_sheet()
    _save_outputs(reference, move, death, unit, unit_native)

    reference_analysis = analyze_image(reference)
    print(
        "reference:",
        f"{reference.size[0]}x{reference.size[1]}",
        f"bbox={reference.getchannel('A').getbbox()}",
        f"grid_mode={reference_analysis['detection_mode']}",
    )
    print(f"move:     {move.size[0]}x{move.size[1]} -> {MOVE_OUTPUT_PATH}")
    print(f"death:    {death.size[0]}x{death.size[1]} -> {DEATH_OUTPUT_PATH}")
    print(f"units:    {unit.size[0]}x{unit.size[1]} -> {UNIT_OUTPUT_PATH}")
    print(f"unit src: {unit_native.size[0]}x{unit_native.size[1]} -> {UNIT_NATIVE_SOURCE_PATH}")
    print(f"idle:     {reference.size[0]}x{reference.size[1]} -> {IDLE_OUTPUT_PATH}")
    print(f"portrait: 160x160 -> {PORTRAIT_OUTPUT_PATH}")
    print("move frame bboxes:", [item["bbox"] for item in move_report])
    print("death frame bboxes:", [item["bbox"] for item in death_report])
    print("unit frame bboxes:", [item["bbox"] for item in unit_report])
    print(f"preview:  {OVERVIEW_PREVIEW_PATH}")


if __name__ == "__main__":
    main()
