#!/usr/bin/env python3
"""Build the Life Tower bobbing review GIF from its two formal layers.

The 64x64 source layers are never resampled or rewritten.  Each layer is
nearest-neighbour enlarged to the 512x512 review canvas once, then the enlarged
heart is translated by whole preview pixels along a sampled sine wave.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import GifImagePlugin, Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FORMAL_TEXTURE_ROOT = (
    PROJECT_ROOT / "resources/texture/plant_defense/life_tower"
)
DEFAULT_LOWER_PATH = FORMAL_TEXTURE_ROOT / "layers/lower_body.png"
DEFAULT_HEART_PATH = FORMAL_TEXTURE_ROOT / "layers/heart_foreground.png"
DEFAULT_OUTPUT_PATH = (
    PROJECT_ROOT
    / "dev_assets/source_images/plant_defense/life_tower/final"
    / "life_tower_bob_preview.gif"
)

SOURCE_SIZE = 64
PREVIEW_SCALE = 8
PREVIEW_SIZE = SOURCE_SIZE * PREVIEW_SCALE
FRAME_COUNT = 40
FRAME_DURATION_MS = 50
PERIOD_SECONDS = 2.0
FPS = 20
AMPLITUDE_SOURCE_PIXELS = 2.0
AMPLITUDE_PREVIEW_PIXELS = round(
    AMPLITUDE_SOURCE_PIXELS * PREVIEW_SCALE
)


def _load_formal_layer(path: Path, label: str) -> Image.Image:
    with Image.open(path) as source:
        layer = source.convert("RGBA")
    if layer.size != (SOURCE_SIZE, SOURCE_SIZE):
        raise ValueError(
            f"{label} must be {SOURCE_SIZE}x{SOURCE_SIZE}, got {layer.size}"
        )
    alpha = np.asarray(layer, dtype=np.uint8)[:, :, 3]
    alpha_values = set(np.unique(alpha).tolist())
    if not alpha_values.issubset({0, 255}):
        raise ValueError(
            f"{label} must use binary alpha, got {sorted(alpha_values)}"
        )
    if not np.any(alpha == 255):
        raise ValueError(f"{label} contains no visible pixels")
    return layer


def _build_offsets() -> list[int]:
    """Sample one seamless 2-second sine cycle, moving upward first."""
    if FRAME_COUNT != round(PERIOD_SECONDS * FPS):
        raise AssertionError("frame count, period and FPS constants disagree")
    if FRAME_DURATION_MS != round(1000.0 / FPS):
        raise AssertionError("frame duration and FPS constants disagree")
    offsets = [
        -round(
            AMPLITUDE_PREVIEW_PIXELS
            * math.sin(math.tau * frame_index / FRAME_COUNT)
        )
        for frame_index in range(FRAME_COUNT)
    ]
    expected_cardinals = {
        0: 0,
        FRAME_COUNT // 4: -AMPLITUDE_PREVIEW_PIXELS,
        FRAME_COUNT // 2: 0,
        FRAME_COUNT * 3 // 4: AMPLITUDE_PREVIEW_PIXELS,
    }
    for frame_index, expected_offset in expected_cardinals.items():
        if offsets[frame_index] != expected_offset:
            raise AssertionError(
                "sine sampling missed a cardinal offset at frame "
                f"{frame_index}: {offsets[frame_index]} != {expected_offset}"
            )
    if min(offsets) != -AMPLITUDE_PREVIEW_PIXELS:
        raise AssertionError("sine sampling did not reach its upper amplitude")
    if max(offsets) != AMPLITUDE_PREVIEW_PIXELS:
        raise AssertionError("sine sampling did not reach its lower amplitude")
    return offsets


def _build_rgba_frames(
    lower: Image.Image,
    heart: Image.Image,
    offsets: list[int],
) -> list[Image.Image]:
    lower_preview = lower.resize(
        (PREVIEW_SIZE, PREVIEW_SIZE),
        Image.Resampling.NEAREST,
    )
    heart_preview = heart.resize(
        (PREVIEW_SIZE, PREVIEW_SIZE),
        Image.Resampling.NEAREST,
    )
    frames: list[Image.Image] = []
    for offset_y in offsets:
        frame = lower_preview.copy()
        frame.alpha_composite(heart_preview, dest=(0, offset_y))
        frames.append(frame)
    return frames


def _build_shared_palette(
    lower: Image.Image,
    heart: Image.Image,
) -> tuple[list[tuple[int, int, int]], list[int]]:
    visible_colors: set[tuple[int, int, int]] = set()
    for layer in (lower, heart):
        rgba = np.asarray(layer, dtype=np.uint8)
        for color in np.unique(
            rgba[:, :, :3][rgba[:, :, 3] == 255],
            axis=0,
        ):
            visible_colors.add(tuple(int(channel) for channel in color))
    ordered_colors = sorted(visible_colors)
    if len(ordered_colors) > 255:
        raise ValueError(
            "formal layers exceed the GIF palette budget: "
            f"{len(ordered_colors)} visible colors"
        )

    # Index zero is reserved for transparency.  A visible exact-black color, if
    # present, receives a separate non-transparent index with the same RGB.
    palette = [0, 0, 0]
    for red, green, blue in ordered_colors:
        palette.extend((red, green, blue))
    palette.extend([0] * (768 - len(palette)))
    return ordered_colors, palette


def _convert_to_indexed(
    frame: Image.Image,
    visible_colors: list[tuple[int, int, int]],
    palette: list[int],
) -> Image.Image:
    rgba = np.asarray(frame, dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    indices = np.zeros((PREVIEW_SIZE, PREVIEW_SIZE), dtype=np.uint8)
    assigned = np.zeros_like(visible)
    for palette_index, color in enumerate(visible_colors, start=1):
        color_mask = visible & np.all(
            rgba[:, :, :3] == np.asarray(color, dtype=np.uint8),
            axis=2,
        )
        indices[color_mask] = palette_index
        assigned |= color_mask
    if not np.array_equal(assigned, visible):
        missing = int(np.count_nonzero(visible & ~assigned))
        raise AssertionError(
            f"{missing} visible preview pixels were not assigned a GIF color"
        )
    indexed = Image.fromarray(indices, mode="P")
    indexed.putpalette(palette)
    indexed.info["transparency"] = 0
    return indexed


def _save_exact_frame_gif(
    frames: list[Image.Image],
    output_path: Path,
) -> None:
    """Write every sample, including identical consecutive extrema frames.

    Pillow's normal ``save_all`` path coalesces identical adjacent frames by
    adding their durations.  A rounded sine wave intentionally contains short
    duplicate plateaus at its extrema, so writing documented GIF data blocks
    directly is necessary to keep the requested 40 decoded frames.
    """
    if len(frames) != FRAME_COUNT:
        raise ValueError(
            f"expected {FRAME_COUNT} frames, got {len(frames)}"
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    header, _ = GifImagePlugin.getheader(
        frames[0],
        info={
            "background": 0,
            "loop": 0,
            "transparency": 0,
        },
    )
    with output_path.open("wb") as gif_file:
        for block in header:
            gif_file.write(block)
        for frame in frames:
            for block in GifImagePlugin.getdata(
                frame,
                duration=FRAME_DURATION_MS,
                disposal=2,
                transparency=0,
            ):
                gif_file.write(block)
        gif_file.write(b";")


def _validate_output(
    output_path: Path,
    expected_rgba_frames: list[Image.Image],
    expected_offsets: list[int],
) -> dict[str, object]:
    decoded_durations: list[int] = []
    with Image.open(output_path) as animation:
        if animation.size != (PREVIEW_SIZE, PREVIEW_SIZE):
            raise AssertionError(
                f"GIF size is {animation.size}, expected "
                f"{PREVIEW_SIZE}x{PREVIEW_SIZE}"
            )
        if animation.n_frames != FRAME_COUNT:
            raise AssertionError(
                f"GIF has {animation.n_frames} frames, expected {FRAME_COUNT}"
            )
        if int(animation.info.get("loop", -1)) != 0:
            raise AssertionError("GIF must loop forever")
        for frame_index in range(animation.n_frames):
            animation.seek(frame_index)
            duration = int(animation.info.get("duration", 0))
            decoded_durations.append(duration)
            decoded = np.asarray(animation.convert("RGBA"), dtype=np.uint8)
            expected = np.asarray(
                expected_rgba_frames[frame_index],
                dtype=np.uint8,
            )
            if not np.array_equal(decoded, expected):
                differing = int(
                    np.count_nonzero(np.any(decoded != expected, axis=2))
                )
                raise AssertionError(
                    "decoded GIF frame differs from the exact nearest-neighbour "
                    f"composite at frame {frame_index}: {differing} pixels"
                )

    if decoded_durations != [FRAME_DURATION_MS] * FRAME_COUNT:
        raise AssertionError(
            f"GIF frame durations are not all {FRAME_DURATION_MS} ms: "
            f"{decoded_durations}"
        )
    total_duration_ms = sum(decoded_durations)
    if total_duration_ms != round(PERIOD_SECONDS * 1000):
        raise AssertionError(
            f"GIF duration is {total_duration_ms} ms, expected "
            f"{PERIOD_SECONDS * 1000:.0f} ms"
        )
    if min(expected_offsets) != -AMPLITUDE_PREVIEW_PIXELS:
        raise AssertionError("encoded heart never reaches the upper extreme")
    if max(expected_offsets) != AMPLITUDE_PREVIEW_PIXELS:
        raise AssertionError("encoded heart never reaches the lower extreme")
    return {
        "frames": FRAME_COUNT,
        "fps": FPS,
        "frame_duration_ms": FRAME_DURATION_MS,
        "total_duration_ms": total_duration_ms,
        "offsets_preview_pixels": expected_offsets,
        "amplitude_preview_pixels": AMPLITUDE_PREVIEW_PIXELS,
        "amplitude_source_pixels": AMPLITUDE_SOURCE_PIXELS,
    }


def build_life_tower_bob_preview(
    lower_path: Path,
    heart_path: Path,
    output_path: Path,
) -> dict[str, object]:
    lower = _load_formal_layer(lower_path, "lower_body")
    heart = _load_formal_layer(heart_path, "heart_foreground")
    offsets = _build_offsets()
    rgba_frames = _build_rgba_frames(lower, heart, offsets)
    visible_colors, palette = _build_shared_palette(lower, heart)
    indexed_frames = [
        _convert_to_indexed(frame, visible_colors, palette)
        for frame in rgba_frames
    ]
    _save_exact_frame_gif(indexed_frames, output_path)
    result = _validate_output(output_path, rgba_frames, offsets)
    result["visible_colors"] = len(visible_colors)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build the formal 40-frame Life Tower bobbing review GIF",
    )
    parser.add_argument(
        "--lower",
        type=Path,
        default=DEFAULT_LOWER_PATH,
        help="Formal 64x64 lower_body.png",
    )
    parser.add_argument(
        "--heart",
        type=Path,
        default=DEFAULT_HEART_PATH,
        help="Formal 64x64 heart_foreground.png",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_PATH,
        help="Destination GIF",
    )
    args = parser.parse_args()

    result = build_life_tower_bob_preview(
        args.lower.resolve(),
        args.heart.resolve(),
        args.output.resolve(),
    )
    print(f"output:                    {args.output.resolve()}")
    print(f"size:                      {PREVIEW_SIZE}x{PREVIEW_SIZE}")
    print(f"frames:                    {result['frames']}")
    print(f"fps:                       {result['fps']}")
    print(f"frame duration:            {result['frame_duration_ms']} ms")
    print(f"total duration:            {result['total_duration_ms']} ms")
    print(
        "amplitude:                 "
        f"+/-{result['amplitude_source_pixels']:.0f} source pixels "
        f"(+/-{result['amplitude_preview_pixels']} preview pixels)"
    )
    print(f"visible colors:            {result['visible_colors']}")
    print(
        "offsets (preview pixels):  "
        + ",".join(str(value) for value in result["offsets_preview_pixels"])
    )
    print("LIFE_TOWER_BOB_PREVIEW_OK")


if __name__ == "__main__":
    main()
