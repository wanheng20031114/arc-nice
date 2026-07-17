#!/usr/bin/env python3
"""Build the elite stone-golem sheet from explicit native-pixel details.

The user's current stone-golem runtime sheet is the only geometry source.
Every transparent pixel, outer-contour pixel, pose, and anchor is copied
verbatim.  The elite identity comes from existing moss texture remapped into
ruby mineral veins, one hand-authored chest crystal, and one short shoulder
vein per frame.  No normalized region or whole stone face is recolored.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


GRID_COLUMNS = 4
GRID_ROWS = 4
FRAME_SIZE = 64
DARK_OUTLINE_LUMA = 72

RUBY_DARK = (82, 29, 32)
RUBY_MID = (122, 35, 38)
RUBY_MAIN = (174, 46, 45)
RUBY_BRIGHT = (224, 72, 60)
RUBY_HIGHLIGHT = (245, 153, 118)
RUBY_PALETTE = {
    RUBY_DARK,
    RUBY_MID,
    RUBY_MAIN,
    RUBY_BRIGHT,
    RUBY_HIGHLIGHT,
}

# The base sheet already carries hand-authored moss texture across the same
# stones from frame to frame.  Turning only that texture into ruby mineral is
# naturally animation-stable and avoids the old "painted red armor plate"
# appearance.
MOSS_TO_RUBY = {
    (55, 69, 51): RUBY_DARK,
    (89, 96, 47): RUBY_MID,
    (121, 135, 38): RUBY_MAIN,
    (134, 142, 45): RUBY_BRIGHT,
}

# Five isolated moss pixels on the first movement pose read as flickering red
# noise rather than a coherent mineral mark.  Keep the nearby authored clusters
# but omit these detached limb specks so the move loop starts at the same detail
# density as its second frame.
MOSS_DETAIL_EXCLUSIONS: dict[int, set[tuple[int, int]]] = {
    0: {
        (21, 47),
        (23, 52),
        (28, 53),
        (29, 49),
        (46, 50),
    },
}

# Frame-local coordinates, ordered row-major.  These were authored against the
# current sixteen native 64 px frames.  The crystal remains on the torso stone
# through movement and attack, then breaks into progressively smaller fragments
# during death.
CHEST_CRYSTAL_POINTS: tuple[tuple[tuple[int, int], ...], ...] = (
    ((33, 32), (32, 33), (33, 33), (34, 33), (32, 34), (33, 34), (34, 34), (33, 35)),
    ((33, 32), (32, 33), (33, 33), (34, 33), (32, 34), (33, 34), (34, 34), (33, 35)),
    ((34, 32), (33, 33), (34, 33), (35, 33), (33, 34), (34, 34), (35, 34), (34, 35)),
    ((33, 33), (32, 34), (33, 34), (34, 34), (32, 35), (33, 35), (34, 35), (33, 36)),
    ((32, 32), (31, 33), (32, 33), (33, 33), (31, 34), (32, 34), (33, 34), (32, 35)),
    ((30, 32), (29, 33), (30, 33), (31, 33), (29, 34), (30, 34), (31, 34), (30, 35)),
    ((30, 35), (29, 36), (30, 36), (31, 36), (29, 37), (30, 37), (31, 37), (30, 38)),
    ((31, 39), (30, 40), (31, 40), (32, 40), (30, 41), (31, 41), (32, 41), (31, 42)),
    ((32, 39), (31, 40), (32, 40), (33, 40), (31, 41), (32, 41), (33, 41), (32, 42)),
    ((32, 40), (31, 41), (32, 41), (33, 41), (31, 42), (32, 42), (33, 42), (32, 43)),
    ((33, 40), (32, 41), (33, 41), (34, 41), (32, 42), (33, 42), (34, 42), (33, 43)),
    ((32, 35), (31, 36), (32, 36), (33, 36), (31, 37), (32, 37), (33, 37), (32, 38)),
    ((31, 38), (30, 39), (31, 39), (32, 39), (30, 40), (31, 40), (31, 41)),
    ((30, 44), (31, 44), (30, 45), (31, 45), (32, 45), (32, 46)),
    ((30, 42), (31, 42), (31, 43), (32, 43)),
    ((32, 47), (32, 48), (33, 48)),
)

# A single angular vein follows the screen-left shoulder / upper-arm stone.
# Its coordinates are explicit per pose, rather than inferred from a frame
# bounding box, so it remains attached to the intended stone.
SHOULDER_VEIN_POINTS: tuple[tuple[tuple[int, int], ...], ...] = (
    ((20, 28), (21, 29), (22, 30), (23, 30), (24, 31)),
    ((21, 28), (22, 29), (23, 30), (24, 31)),
    ((21, 28), (22, 29), (23, 30), (24, 31)),
    ((21, 28), (22, 29), (23, 30), (24, 31)),
    ((21, 27), (22, 28), (23, 29), (24, 30)),
    ((20, 23), (21, 24), (22, 25), (22, 26)),
    ((21, 22), (21, 23), (22, 24), (23, 25)),
    ((21, 31), (22, 32), (23, 33), (24, 34)),
    ((23, 36), (24, 37), (25, 38), (26, 39)),
    ((25, 34), (26, 35), (27, 36), (28, 37)),
    ((23, 34), (24, 35), (25, 36), (26, 37)),
    ((21, 31), (22, 32), (23, 33), (24, 34)),
    ((21, 34), (22, 35), (23, 36), (24, 37)),
    ((22, 37), (23, 38), (24, 39), (25, 40)),
    ((23, 43), (24, 44), (25, 45), (25, 46)),
    ((21, 49), (22, 50), (23, 50), (24, 50), (25, 49)),
)

FULL_CRYSTAL_COLORS = (
    RUBY_BRIGHT,
    RUBY_HIGHLIGHT,
    RUBY_BRIGHT,
    RUBY_MAIN,
    RUBY_MAIN,
    RUBY_MAIN,
    RUBY_MID,
    RUBY_DARK,
)
DEATH_CRYSTAL_COLORS: tuple[tuple[tuple[int, int, int], ...], ...] = (
    (
        RUBY_BRIGHT,
        RUBY_HIGHLIGHT,
        RUBY_BRIGHT,
        RUBY_MAIN,
        RUBY_MAIN,
        RUBY_MID,
        RUBY_DARK,
    ),
    (
        RUBY_HIGHLIGHT,
        RUBY_BRIGHT,
        RUBY_MAIN,
        RUBY_MAIN,
        RUBY_MID,
        RUBY_DARK,
    ),
    (RUBY_HIGHLIGHT, RUBY_BRIGHT, RUBY_MAIN, RUBY_DARK),
    (RUBY_BRIGHT, RUBY_MAIN, RUBY_DARK),
)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create an exact-contour elite stone-golem sheet."
    )
    parser.add_argument("input_path", type=Path)
    parser.add_argument("output_path", type=Path)
    parser.add_argument(
        "--overlay-output",
        type=Path,
        help="Optional transparent PNG containing only the ruby detail pixels.",
    )
    return parser.parse_args()


def _luma(color: tuple[int, int, int]) -> float:
    red, green, blue = color
    return red * 0.2126 + green * 0.7152 + blue * 0.0722


def _frame_alpha(
    source: Image.Image,
    column: int,
    row: int,
) -> list[list[int]]:
    origin_x = column * FRAME_SIZE
    origin_y = row * FRAME_SIZE
    return [
        [
            source.getpixel((origin_x + x, origin_y + y))[3]
            for x in range(FRAME_SIZE)
        ]
        for y in range(FRAME_SIZE)
    ]


def _is_outer_boundary(
    alpha: list[list[int]],
    x: int,
    y: int,
) -> bool:
    if alpha[y][x] <= 0:
        return False
    for offset_y in (-1, 0, 1):
        for offset_x in (-1, 0, 1):
            if offset_x == 0 and offset_y == 0:
                continue
            neighbor_x = x + offset_x
            neighbor_y = y + offset_y
            if (
                neighbor_x < 0
                or neighbor_y < 0
                or neighbor_x >= FRAME_SIZE
                or neighbor_y >= FRAME_SIZE
                or alpha[neighbor_y][neighbor_x] <= 0
            ):
                return True
    return False


def _crystal_colors(frame_index: int) -> tuple[tuple[int, int, int], ...]:
    if frame_index < 12:
        return FULL_CRYSTAL_COLORS
    return DEATH_CRYSTAL_COLORS[frame_index - 12]


def _vein_colors(point_count: int) -> tuple[tuple[int, int, int], ...]:
    if point_count == 5:
        return (
            RUBY_DARK,
            RUBY_MID,
            RUBY_MAIN,
            RUBY_MID,
            RUBY_DARK,
        )
    if point_count == 4:
        return RUBY_DARK, RUBY_MID, RUBY_MAIN, RUBY_DARK
    raise ValueError(f"Unsupported shoulder vein length: {point_count}")


def _set_detail(
    details: dict[tuple[int, int], tuple[int, int, int, int]],
    position: tuple[int, int],
    color: tuple[int, int, int],
) -> None:
    details[position] = (*color, 255)


def _build_details(
    source: Image.Image,
) -> tuple[
    dict[tuple[int, int], tuple[int, int, int, int]],
    list[int],
]:
    details: dict[tuple[int, int], tuple[int, int, int, int]] = {}
    per_frame_counts: list[int] = []

    for row in range(GRID_ROWS):
        for column in range(GRID_COLUMNS):
            frame_index = row * GRID_COLUMNS + column
            origin_x = column * FRAME_SIZE
            origin_y = row * FRAME_SIZE
            alpha = _frame_alpha(source, column, row)
            frame_positions: set[tuple[int, int]] = set()
            frame_exclusions = MOSS_DETAIL_EXCLUSIONS.get(
                frame_index,
                set(),
            )

            # Reuse the base animation's already coherent moss marks as the
            # first ruby-mineral texture layer.  Boundary pixels remain exact.
            for local_y in range(FRAME_SIZE):
                for local_x in range(FRAME_SIZE):
                    global_position = (
                        origin_x + local_x,
                        origin_y + local_y,
                    )
                    source_pixel = source.getpixel(global_position)
                    mapped_color = MOSS_TO_RUBY.get(source_pixel[:3])
                    if (
                        mapped_color is None
                        or (local_x, local_y)
                        in frame_exclusions
                        or _is_outer_boundary(alpha, local_x, local_y)
                    ):
                        continue
                    _set_detail(details, global_position, mapped_color)
                    frame_positions.add(global_position)

            crystal_points = CHEST_CRYSTAL_POINTS[frame_index]
            crystal_colors = _crystal_colors(frame_index)
            if len(crystal_points) != len(crystal_colors):
                raise ValueError(
                    f"Crystal point/color mismatch in frame {frame_index}"
                )
            for local_position, color in zip(
                crystal_points,
                crystal_colors,
                strict=True,
            ):
                global_position = (
                    origin_x + local_position[0],
                    origin_y + local_position[1],
                )
                _set_detail(details, global_position, color)
                frame_positions.add(global_position)

            vein_points = SHOULDER_VEIN_POINTS[frame_index]
            for local_position, color in zip(
                vein_points,
                _vein_colors(len(vein_points)),
                strict=True,
            ):
                global_position = (
                    origin_x + local_position[0],
                    origin_y + local_position[1],
                )
                _set_detail(details, global_position, color)
                frame_positions.add(global_position)

            per_frame_counts.append(len(frame_positions))

    return details, per_frame_counts


def _verify_authored_points(
    source: Image.Image,
    details: dict[tuple[int, int], tuple[int, int, int, int]],
) -> None:
    for row in range(GRID_ROWS):
        for column in range(GRID_COLUMNS):
            alpha = _frame_alpha(source, column, row)
            origin_x = column * FRAME_SIZE
            origin_y = row * FRAME_SIZE
            frame_index = row * GRID_COLUMNS + column
            explicit_points = (
                CHEST_CRYSTAL_POINTS[frame_index]
                + SHOULDER_VEIN_POINTS[frame_index]
            )
            for local_x, local_y in explicit_points:
                source_pixel = source.getpixel(
                    (origin_x + local_x, origin_y + local_y)
                )
                if source_pixel[3] <= 0:
                    raise ValueError(
                        f"Detail left alpha in frame {frame_index}: "
                        f"{local_x},{local_y}"
                    )
                if _is_outer_boundary(alpha, local_x, local_y):
                    raise ValueError(
                        f"Detail touched contour in frame {frame_index}: "
                        f"{local_x},{local_y}"
                    )
                if _luma(source_pixel[:3]) <= DARK_OUTLINE_LUMA:
                    raise ValueError(
                        f"Detail covered dark outline in frame {frame_index}: "
                        f"{local_x},{local_y}"
                    )
                if (origin_x + local_x, origin_y + local_y) not in details:
                    raise ValueError(
                        f"Authored detail missing in frame {frame_index}: "
                        f"{local_x},{local_y}"
                    )


def _build_sheet(
    source: Image.Image,
) -> tuple[Image.Image, Image.Image, list[int]]:
    if source.mode != "RGBA":
        source = source.convert("RGBA")
    expected_size = (
        GRID_COLUMNS * FRAME_SIZE,
        GRID_ROWS * FRAME_SIZE,
    )
    if source.size != expected_size:
        raise ValueError(
            f"Expected {expected_size[0]}x{expected_size[1]} sheet, "
            f"got {source.width}x{source.height}"
        )
    if {pixel[3] for pixel in source.getdata()} != {0, 255}:
        raise ValueError("Source alpha must be binary 0/255")

    details, per_frame_counts = _build_details(source)
    _verify_authored_points(source, details)
    result = source.copy()
    overlay = Image.new("RGBA", source.size, (0, 0, 0, 0))
    for position, color in details.items():
        result.putpixel(position, color)
        overlay.putpixel(position, color)
    return result, overlay, per_frame_counts


def _verify_result(
    source: Image.Image,
    result: Image.Image,
    overlay: Image.Image,
    per_frame_counts: list[int],
) -> None:
    changed_positions: set[tuple[int, int]] = set()
    overlay_positions: set[tuple[int, int]] = set()
    opaque_pixels = 0

    for y in range(source.height):
        for x in range(source.width):
            source_pixel = source.getpixel((x, y))
            result_pixel = result.getpixel((x, y))
            overlay_pixel = overlay.getpixel((x, y))
            if source_pixel[3] > 0:
                opaque_pixels += 1
            if source_pixel[3] != result_pixel[3]:
                raise ValueError(f"Alpha changed at {x},{y}")
            if result_pixel != source_pixel:
                changed_positions.add((x, y))
                if result_pixel[:3] not in RUBY_PALETTE:
                    raise ValueError(f"Non-ruby detail color at {x},{y}")
            if overlay_pixel[3] > 0:
                overlay_positions.add((x, y))
                if overlay_pixel != result_pixel:
                    raise ValueError(f"Overlay/result mismatch at {x},{y}")

    if changed_positions != overlay_positions:
        raise ValueError("Changed pixels must exactly equal the overlay mask")
    changed_count = len(changed_positions)
    if not 220 <= changed_count <= 520:
        raise ValueError(
            f"Ruby detail density out of range: {changed_count} pixels"
        )
    for frame_index, frame_count in enumerate(per_frame_counts):
        minimum = 8 if frame_index == 15 else 12
        if not minimum <= frame_count <= 45:
            raise ValueError(
                f"Frame {frame_index} detail count out of range: "
                f"{frame_count}"
            )

    print(
        "STONE_GOLEM_ELITE_SHEET_OK "
        f"size={result.width}x{result.height} "
        f"details={changed_count} "
        f"opaque={opaque_pixels} "
        f"ratio={changed_count / max(opaque_pixels, 1):.4f} "
        f"per_frame={per_frame_counts}"
    )


def main() -> None:
    args = _parse_args()
    resolved_input = args.input_path.resolve()
    resolved_output = args.output_path.resolve()
    if resolved_input == resolved_output:
        raise ValueError("Input and output must be different files")
    if (
        args.overlay_output is not None
        and args.overlay_output.resolve() in {resolved_input, resolved_output}
    ):
        raise ValueError("Overlay output must use a third, distinct file")

    source = Image.open(args.input_path).convert("RGBA")
    result, overlay, per_frame_counts = _build_sheet(source)
    _verify_result(source, result, overlay, per_frame_counts)

    args.output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(args.output_path, optimize=True)
    if args.overlay_output is not None:
        args.overlay_output.parent.mkdir(parents=True, exist_ok=True)
        overlay.save(args.overlay_output, optimize=True)


if __name__ == "__main__":
    main()
