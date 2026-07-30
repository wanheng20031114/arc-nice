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

REFERENCE_PATH = SOURCE_DIR / "tango_idle_front_32_v2.png"
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

MOVE_PREVIEW_PATH = PREVIEW_DIR / "tango_move_v1_preview.png"
DEATH_PREVIEW_PATH = PREVIEW_DIR / "tango_death_v1_preview.png"
UNIT_PREVIEW_PATH = PREVIEW_DIR / "tango_cast_unit_v2_preview.png"
OVERVIEW_PREVIEW_PATH = PREVIEW_DIR / "tango_animation_overview_v1.png"

FRAME_SIZE = 32
UNIT_FRAME_SIZE = 8
MOVE_BASELINE = 28
DEATH_BASELINE = 28
EYE_CYAN = (56, 236, 243, 255)
EYE_COORDINATES = ((18, 9), (18, 10))

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
# the shape; these native-cell energy changes make it usable for a 2.5-second charge
# and a one-second firing loop without introducing subpixel details.
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


def _correct_reference_eye() -> Image.Image:
    before = Image.open(REFERENCE_PATH).convert("RGBA")
    after = before.copy()
    for coordinate in EYE_COORDINATES:
        after.putpixel(coordinate, EYE_CYAN)

    for y in range(before.height):
        for x in range(before.width):
            if (x, y) not in EYE_COORDINATES and before.getpixel((x, y)) != after.getpixel((x, y)):
                raise AssertionError(f"unexpected reference edit at {(x, y)}")

    after = normalize_transparency(after)
    after.save(REFERENCE_PATH, optimize=True)
    return after


def _build_move_sheet(reference: Image.Image) -> tuple[Image.Image, list[dict]]:
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
            if output_row == 0 and column == 0:
                # The approved front pose is the canonical idle/down contact frame.
                frame = reference.copy()
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
    return normalize_transparency(sheet), report


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
    death_preview = _preview(death, 4)
    unit_preview = _preview(unit, 12)
    move_preview.save(MOVE_PREVIEW_PATH, optimize=True)
    death_preview.save(DEATH_PREVIEW_PATH, optimize=True)
    unit_preview.save(UNIT_PREVIEW_PATH, optimize=True)

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
    reference = _correct_reference_eye()
    move, move_report = _build_move_sheet(reference)
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
