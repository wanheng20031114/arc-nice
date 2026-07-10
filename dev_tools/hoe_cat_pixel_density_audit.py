#!/usr/bin/env python3
"""Validate the rebuilt Hoe Cat against Weishidaier's native pixel language."""

from __future__ import annotations

from pathlib import Path
from statistics import median

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
HOE_DIR = ROOT / "resources" / "texture" / "player" / "hoe_cat"
WEISH_PATH = ROOT / "resources" / "texture" / "player" / "weishidaier" / "body.png"


def _split(
    path: Path,
    columns: int,
    rows: int,
    frame_size: int,
) -> list[Image.Image]:
    image = Image.open(path).convert("RGBA")
    expected = (columns * frame_size, rows * frame_size)
    if image.size != expected:
        raise AssertionError(f"{path.name}: expected {expected}, got {image.size}")
    return [
        image.crop(
            (
                column * frame_size,
                row * frame_size,
                (column + 1) * frame_size,
                (row + 1) * frame_size,
            )
        )
        for row in range(rows)
        for column in range(columns)
    ]


def _metrics(frame: Image.Image) -> dict[str, float | int | tuple[int, int, int, int]]:
    rgba = frame.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Animation frame is empty")
    opaque = [
        (x, y)
        for y in range(rgba.height)
        for x in range(rgba.width)
        if rgba.getpixel((x, y))[3] > 0
    ]
    opaque_set = set(opaque)
    edge = sum(
        any(
            (x + delta_x, y + delta_y) not in opaque_set
            for delta_x, delta_y in ((-1, 0), (1, 0), (0, -1), (0, 1))
        )
        for x, y in opaque
    )
    return {
        "bbox": bbox,
        "width": bbox[2] - bbox[0],
        "height": bbox[3] - bbox[1],
        "opaque": len(opaque),
        "centroid_x": sum(x for x, _y in opaque) / len(opaque),
        "edge_fraction": edge / len(opaque),
    }


def _palette(path: Path) -> set[tuple[int, int, int]]:
    image = Image.open(path).convert("RGBA")
    return {pixel[:3] for pixel in image.getdata() if pixel[3] > 0}


def _assert_binary_alpha(path: Path) -> None:
    alpha = Image.open(path).convert("RGBA").getchannel("A")
    values = set(alpha.getdata())
    if not values.issubset({0, 255}):
        raise AssertionError(f"{path.name}: alpha is not binary: {sorted(values)}")


def _opaque_mask(frame: Image.Image) -> tuple[bool, ...]:
    return tuple(pixel[3] > 0 for pixel in frame.convert("RGBA").getdata())


def _assert_exact_frame(left: Image.Image, right: Image.Image, label: str) -> None:
    if list(left.convert("RGBA").getdata()) != list(right.convert("RGBA").getdata()):
        raise AssertionError(f"{label}: frames differ")


def _assert_mirror(right: Image.Image, left: Image.Image, label: str) -> None:
    mirrored = right.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    _assert_exact_frame(mirrored, left, label)


def _weish_normal_frames() -> list[Image.Image]:
    image = Image.open(WEISH_PATH).convert("RGBA")
    return [
        image.crop((column * 32, row * 32, (column + 1) * 32, (row + 1) * 32))
        for row in range(4)
        for column in range(4)
    ]


def _assert_character_scale(
    movement_metrics: list[dict],
    weish_metrics: list[dict],
) -> None:
    movement_medians = {
        key: float(median(float(metric[key]) for metric in movement_metrics))
        for key in ("width", "height", "opaque")
    }
    weish_medians = {
        key: float(median(float(metric[key]) for metric in weish_metrics))
        for key in ("width", "height", "opaque")
    }
    ranges = {
        "width": (0.90, 1.16),
        "height": (0.90, 1.14),
        "opaque": (0.95, 1.15),
    }
    for key, (minimum, maximum) in ranges.items():
        ratio = movement_medians[key] / weish_medians[key]
        if not minimum <= ratio <= maximum:
            raise AssertionError(
                f"Movement {key} ratio to Weishidaier is {ratio:.3f}, "
                f"expected [{minimum:.2f}, {maximum:.2f}]"
            )


def _assert_movement(
    frames: list[Image.Image],
    metrics: list[dict],
) -> None:
    for index, metric in enumerate(metrics):
        bbox = metric["bbox"]
        if not (
            16 <= int(metric["width"]) <= 20
            and 18 <= int(metric["height"]) <= 20
            and 190 <= int(metric["opaque"]) <= 230
            and bbox[0] >= 3
            and bbox[1] >= 3
            and bbox[2] <= 29
            and bbox[3] <= 29
        ):
            raise AssertionError(f"Movement frame {index} escaped native scale: {metric}")

    expected_bottoms = (28, 26, 26, 26)
    for row in range(4):
        row_frames = frames[row * 4 : row * 4 + 4]
        row_metrics = metrics[row * 4 : row * 4 + 4]
        _assert_exact_frame(row_frames[0], row_frames[2], f"movement row {row} neutral beat")
        bottoms = [metric["bbox"][3] for metric in row_metrics]
        if any(bottom != expected_bottoms[row] for bottom in bottoms):
            raise AssertionError(f"Movement row {row} foot baseline drift: {bottoms}")
        centroids = [float(metric["centroid_x"]) for metric in row_metrics]
        if max(centroids) - min(centroids) > 1.0:
            raise AssertionError(f"Movement row {row} horizontal drift: {centroids}")
        areas = [int(metric["opaque"]) for metric in row_metrics]
        if max(areas) / min(areas) > 1.12:
            raise AssertionError(f"Movement row {row} body-mass drift: {areas}")

    for frame_index in range(4):
        _assert_mirror(
            frames[2 * 4 + frame_index],
            frames[3 * 4 + frame_index],
            f"movement side frame {frame_index}",
        )


def _assert_attack(frames: list[Image.Image], metrics: list[dict]) -> None:
    for index, metric in enumerate(metrics):
        bbox = metric["bbox"]
        if not (
            15 <= int(metric["width"]) <= 27
            and 18 <= int(metric["height"]) <= 28
            and 185 <= int(metric["opaque"]) <= 250
            and bbox[0] >= 2
            and bbox[1] >= 2
            and bbox[2] <= 30
            and bbox[3] <= 30
        ):
            raise AssertionError(f"Attack frame {index} is clipped or changes scale: {metric}")
    for frame_index in range(5):
        _assert_mirror(
            frames[2 * 5 + frame_index],
            frames[3 * 5 + frame_index],
            f"attack side frame {frame_index}",
        )


def _assert_spin(metrics: list[dict]) -> None:
    for index, metric in enumerate(metrics):
        bbox = metric["bbox"]
        if not (
            16 <= int(metric["width"]) <= 24
            and 17 <= int(metric["height"]) <= 21
            and 195 <= int(metric["opaque"]) <= 240
            and bbox[0] >= 2
            and bbox[1] >= 3
            and bbox[2] <= 30
            and bbox[3] <= 30
        ):
            raise AssertionError(f"Whirlwind body frame {index} escaped native scale: {metric}")


def _assert_vfx(
    slash_frames: list[Image.Image],
    whirlwind_frames: list[Image.Image],
) -> None:
    slash_counts = [
        sum(1 for pixel in frame.getdata() if pixel[3] > 0)
        for frame in slash_frames
    ]
    if not (
        slash_counts[0] < slash_counts[1] < slash_counts[2]
        and slash_counts[2] > slash_counts[3] > slash_counts[4]
        and max(slash_counts) <= 90
    ):
        raise AssertionError(f"Slash arc does not read build-impact-dissipate: {slash_counts}")

    whirlwind_counts = [
        sum(1 for pixel in frame.getdata() if pixel[3] > 0)
        for frame in whirlwind_frames
    ]
    if not (
        whirlwind_counts[0] < whirlwind_counts[1] < whirlwind_counts[2] < whirlwind_counts[3]
        and whirlwind_counts[3] > whirlwind_counts[4] > whirlwind_counts[5]
        > whirlwind_counts[6] > whirlwind_counts[7]
        and max(whirlwind_counts) <= 250
    ):
        raise AssertionError(
            f"Whirlwind VFX must be a sparse build-impact-dissipate arc: {whirlwind_counts}"
        )


def main() -> None:
    movement_path = HOE_DIR / "hoe_cat_move.png"
    attack_path = HOE_DIR / "hoe_cat_attack.png"
    spin_path = HOE_DIR / "hoe_cat_whirlwind_body.png"
    slash_path = HOE_DIR / "hoe_cat_basic_slash_vfx.png"
    whirlwind_path = HOE_DIR / "hoe_cat_whirlwind_vfx.png"
    portrait_path = HOE_DIR / "portrait.png"
    output_paths = (
        movement_path,
        attack_path,
        spin_path,
        slash_path,
        whirlwind_path,
        portrait_path,
    )
    for path in output_paths:
        _assert_binary_alpha(path)

    movement_frames = _split(movement_path, 4, 4, 32)
    attack_frames = _split(attack_path, 5, 4, 32)
    spin_frames = _split(spin_path, 8, 1, 32)
    slash_frames = _split(slash_path, 5, 1, 32)
    whirlwind_frames = _split(whirlwind_path, 8, 1, 48)
    movement_metrics = [_metrics(frame) for frame in movement_frames]
    attack_metrics = [_metrics(frame) for frame in attack_frames]
    spin_metrics = [_metrics(frame) for frame in spin_frames]
    weish_metrics = [_metrics(frame) for frame in _weish_normal_frames()]

    _assert_character_scale(movement_metrics, weish_metrics)
    _assert_movement(movement_frames, movement_metrics)
    _assert_attack(attack_frames, attack_metrics)
    _assert_spin(spin_metrics)
    _assert_vfx(slash_frames, whirlwind_frames)

    character_palette = _palette(movement_path)
    if len(character_palette) > 16:
        raise AssertionError(f"Movement palette has {len(character_palette)} colors")
    if not _palette(attack_path).issubset(character_palette):
        raise AssertionError("Attack palette drifted from the shared character palette")
    if not _palette(spin_path).issubset(character_palette):
        raise AssertionError("Whirlwind body palette drifted from the shared character palette")
    if len(_palette(slash_path) | _palette(whirlwind_path)) > 8:
        raise AssertionError("Hoe VFX palette exceeds eight shared colors")

    portrait = Image.open(portrait_path).convert("RGBA")
    expected_portrait = movement_frames[0].resize((128, 128), Image.Resampling.NEAREST)
    _assert_exact_frame(portrait, expected_portrait, "portrait native upscale")

    movement_opaque = [int(metric["opaque"]) for metric in movement_metrics]
    print(
        "HOE_CAT_PIXEL_DENSITY_AUDIT_OK "
        f"move_opaque={min(movement_opaque)}..{max(movement_opaque)} "
        f"median={median(movement_opaque):.1f} "
        f"weish_median={median(int(metric['opaque']) for metric in weish_metrics):.1f}"
    )


if __name__ == "__main__":
    main()
