#!/usr/bin/env python3
"""Render the six eight-frame sorcerer walks with center/ground guides."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from process_frost_sorcerer_assets import (
    CHARACTER_FRAME_SIZE,
    MOVE_BODY_MARKER,
    MOVE_FRAME_COUNT,
    MOVE_GROUND_Y,
    _assert_move_strip_contract,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = (
    ROOT
    / "dev_assets/generated_previews/sorcerer_move_center_audit.png"
)
ANIMATION_OUTPUT = (
    ROOT
    / "dev_assets/generated_previews/sorcerer_move_cycle_preview.gif"
)
TRACKS = (
    ("FROST", ROOT / "resources/texture/enemy/sorcerer/frost_sorcerer_move.png"),
    (
        "FROST ELITE",
        ROOT / "resources/texture/enemy/sorcerer/frost_sorcerer_elite_move.png",
    ),
    ("FIRE", ROOT / "resources/texture/enemy/sorcerer/fire_sorcerer_move.png"),
    (
        "FIRE ELITE",
        ROOT / "resources/texture/enemy/sorcerer/fire_sorcerer_elite_move.png",
    ),
    (
        "LIGHTNING",
        ROOT / "resources/texture/enemy/sorcerer/lightning_sorcerer_move.png",
    ),
    (
        "LIGHTNING ELITE",
        ROOT / "resources/texture/enemy/sorcerer/lightning_sorcerer_elite_move.png",
    ),
)
PHASES = (
    "CONTACT R",
    "DOWN R",
    "PASS R",
    "UP R",
    "CONTACT L",
    "DOWN L",
    "PASS L",
    "UP L",
)

SCALE = 6
LEFT_MARGIN = 112
TOP_MARGIN = 50
ROW_GAP = 42
FRAME_LABEL_HEIGHT = 28
ROW_HEIGHT = CHARACTER_FRAME_SIZE * SCALE + FRAME_LABEL_HEIGHT


def _load_track(label: str, path: Path) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(path)
    strip = Image.open(path).convert("RGBA")
    _assert_move_strip_contract(strip, label.lower())
    return strip


def _draw_checker(
    draw: ImageDraw.ImageDraw,
    left: int,
    top: int,
) -> None:
    block = 5 * SCALE
    for y in range(0, CHARACTER_FRAME_SIZE * SCALE, block):
        for x in range(0, CHARACTER_FRAME_SIZE * SCALE, block):
            color = (55, 57, 67) if (x // block + y // block) % 2 == 0 else (69, 71, 82)
            draw.rectangle(
                (left + x, top + y, left + x + block - 1, top + y + block - 1),
                fill=color,
            )


def _centroid(frame: Image.Image) -> tuple[float, float]:
    alpha = np.asarray(frame.getchannel("A"), dtype=np.uint8)
    y_coordinates, x_coordinates = np.nonzero(alpha == 255)
    return float(np.mean(x_coordinates)), float(np.mean(y_coordinates))


def render() -> Image.Image:
    tracks = [(label, _load_track(label, path)) for label, path in TRACKS]
    width = LEFT_MARGIN + MOVE_FRAME_COUNT * CHARACTER_FRAME_SIZE * SCALE + 20
    height = TOP_MARGIN + len(tracks) * ROW_HEIGHT + (len(tracks) - 1) * ROW_GAP + 20
    canvas = Image.new("RGB", (width, height), (22, 23, 29))
    draw = ImageDraw.Draw(canvas)
    draw.text(
        (12, 12),
        "SORCERER MOVE CENTER AUDIT  red=(17,27)  green=ground y38  magenta=alpha centroid",
        fill=(235, 237, 244),
    )

    for row, (label, strip) in enumerate(tracks):
        row_top = TOP_MARGIN + row * (ROW_HEIGHT + ROW_GAP)
        draw.text((12, row_top + FRAME_LABEL_HEIGHT + 6), label, fill=(235, 237, 244))
        for index, phase in enumerate(PHASES):
            left = LEFT_MARGIN + index * CHARACTER_FRAME_SIZE * SCALE
            sprite_top = row_top + FRAME_LABEL_HEIGHT
            frame = strip.crop(
                (
                    index * CHARACTER_FRAME_SIZE,
                    0,
                    (index + 1) * CHARACTER_FRAME_SIZE,
                    CHARACTER_FRAME_SIZE,
                )
            )
            centroid_x, centroid_y = _centroid(frame)
            draw.text(
                (left + 3, row_top + 4),
                f"F{index} {phase} Cx={centroid_x:.2f}",
                fill=(225, 228, 235),
            )
            _draw_checker(draw, left, sprite_top)
            enlarged = frame.resize(
                (CHARACTER_FRAME_SIZE * SCALE, CHARACTER_FRAME_SIZE * SCALE),
                Image.Resampling.NEAREST,
            )
            canvas.paste(enlarged, (left, sprite_top), enlarged)

            marker_x = left + MOVE_BODY_MARKER[0] * SCALE
            marker_y = sprite_top + MOVE_BODY_MARKER[1] * SCALE
            ground_y = sprite_top + MOVE_GROUND_Y * SCALE
            draw.line(
                (marker_x, sprite_top, marker_x, sprite_top + CHARACTER_FRAME_SIZE * SCALE),
                fill=(61, 124, 218),
                width=1,
            )
            draw.line(
                (left, ground_y, left + CHARACTER_FRAME_SIZE * SCALE, ground_y),
                fill=(52, 205, 115),
                width=2,
            )
            draw.line(
                (marker_x - 6, marker_y, marker_x + 6, marker_y),
                fill=(255, 48, 72),
                width=2,
            )
            draw.line(
                (marker_x, marker_y - 6, marker_x, marker_y + 6),
                fill=(255, 48, 72),
                width=2,
            )
            dot_x = round(left + centroid_x * SCALE)
            dot_y = round(sprite_top + centroid_y * SCALE)
            draw.ellipse(
                (dot_x - 3, dot_y - 3, dot_x + 3, dot_y + 3),
                fill=(255, 30, 194),
            )
    return canvas


def render_animation() -> list[Image.Image]:
    tracks = [(label, _load_track(label, path)) for label, path in TRACKS]
    animation_scale = 8
    gap = 28
    label_height = 30
    cell_size = CHARACTER_FRAME_SIZE * animation_scale
    width = 20 + len(tracks) * cell_size + (len(tracks) - 1) * gap + 20
    height = 20 + label_height + cell_size + 20
    animation_frames: list[Image.Image] = []
    for frame_index, phase in enumerate(PHASES):
        canvas = Image.new("RGB", (width, height), (22, 23, 29))
        draw = ImageDraw.Draw(canvas)
        for track_index, (label, strip) in enumerate(tracks):
            left = 20 + track_index * (cell_size + gap)
            top = 20 + label_height
            draw.text(
                (left + 3, 8),
                f"{label}  F{frame_index} {phase}",
                fill=(235, 237, 244),
            )
            block = 5 * animation_scale
            for y in range(0, cell_size, block):
                for x in range(0, cell_size, block):
                    color = (
                        (55, 57, 67)
                        if (x // block + y // block) % 2 == 0
                        else (69, 71, 82)
                    )
                    draw.rectangle(
                        (left + x, top + y, left + x + block - 1, top + y + block - 1),
                        fill=color,
                    )
            frame = strip.crop(
                (
                    frame_index * CHARACTER_FRAME_SIZE,
                    0,
                    (frame_index + 1) * CHARACTER_FRAME_SIZE,
                    CHARACTER_FRAME_SIZE,
                )
            ).resize((cell_size, cell_size), Image.Resampling.NEAREST)
            canvas.paste(frame, (left, top), frame)
        animation_frames.append(canvas)
    return animation_frames


def main() -> None:
    preview = render()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    preview.save(OUTPUT, optimize=True)
    animation_frames = render_animation()
    animation_frames[0].save(
        ANIMATION_OUTPUT,
        save_all=True,
        append_images=animation_frames[1:],
        duration=(80, 80, 90, 80, 80, 80, 90, 90),
        loop=0,
        disposal=2,
        optimize=False,
    )
    print(f"WROTE {OUTPUT}")
    print(f"WROTE {ANIMATION_OUTPUT}")


if __name__ == "__main__":
    main()
