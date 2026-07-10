#!/usr/bin/env python3
"""Reject Hoe Cat sprite regressions that drift from Weishidaier's pixel scale."""

from __future__ import annotations

from pathlib import Path
from statistics import median

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
WEISH_TEXTURE = ROOT / "resources/texture/player/weishidaier/body.png"
HOE_TEXTURE_DIR = ROOT / "resources/texture/player/hoe_cat"


def _split_32_frames(path: Path, columns: int, rows: int) -> list[Image.Image]:
    image = Image.open(path).convert("RGBA")
    expected_size = (columns * 32, rows * 32)
    if image.size != expected_size:
        raise AssertionError(f"{path.name}: expected {expected_size}, got {image.size}")
    return [
        image.crop((column * 32, row * 32, (column + 1) * 32, (row + 1) * 32))
        for row in range(rows)
        for column in range(columns)
    ]


def _weish_normal_frames() -> list[Image.Image]:
    image = Image.open(WEISH_TEXTURE).convert("RGBA")
    regions = [
        (column * 32, row_y, column * 32 + 32, row_y + 32)
        for row_y in (64, 96, 0, 32)
        for column in range(4)
    ]
    return [image.crop(region) for region in regions]


def _component_sizes(frame: Image.Image) -> list[int]:
    pixels = frame.load()
    visited: set[tuple[int, int]] = set()
    sizes: list[int] = []
    for y in range(32):
        for x in range(32):
            if pixels[x, y][3] == 0 or (x, y) in visited:
                continue
            stack = [(x, y)]
            visited.add((x, y))
            size = 0
            while stack:
                current_x, current_y = stack.pop()
                size += 1
                for neighbor_y in range(current_y - 1, current_y + 2):
                    for neighbor_x in range(current_x - 1, current_x + 2):
                        neighbor = (neighbor_x, neighbor_y)
                        if (
                            0 <= neighbor_x < 32
                            and 0 <= neighbor_y < 32
                            and neighbor not in visited
                            and pixels[neighbor_x, neighbor_y][3] > 0
                        ):
                            visited.add(neighbor)
                            stack.append(neighbor)
            sizes.append(size)
    return sorted(sizes, reverse=True)


def _frame_metrics(frame: Image.Image) -> dict[str, float | int | list[int]]:
    alpha = frame.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise AssertionError("Sprite frame is empty")
    pixels = frame.load()
    opaque = [
        (x, y)
        for y in range(32)
        for x in range(32)
        if pixels[x, y][3] > 0
    ]
    edge_pixels = sum(
        any(
            neighbor_x < 0
            or neighbor_y < 0
            or neighbor_x >= 32
            or neighbor_y >= 32
            or pixels[neighbor_x, neighbor_y][3] == 0
            for neighbor_x, neighbor_y in (
                (x - 1, y),
                (x + 1, y),
                (x, y - 1),
                (x, y + 1),
            )
        )
        for x, y in opaque
    )
    return {
        "width": bbox[2] - bbox[0],
        "height": bbox[3] - bbox[1],
        "opaque": len(opaque),
        "edge": edge_pixels,
        "bottom": bbox[3] - 1,
        "centroid_x": sum(x for x, _y in opaque) / len(opaque),
        "components": _component_sizes(frame),
    }


def _median(metrics: list[dict], key: str) -> float:
    return float(median(float(metric[key]) for metric in metrics))


def _assert_ratio(
    label: str,
    actual: float,
    reference: float,
    minimum: float,
    maximum: float,
) -> None:
    ratio = actual / reference
    if not minimum <= ratio <= maximum:
        raise AssertionError(
            f"{label}: ratio {ratio:.3f} outside [{minimum:.3f}, {maximum:.3f}]"
        )


def _assert_binary_alpha(path: Path) -> None:
    image = Image.open(path).convert("RGBA")
    alpha_values = {pixel[3] for pixel in image.getdata()}
    if not alpha_values.issubset({0, 255}):
        raise AssertionError(f"{path.name}: non-binary alpha values {alpha_values}")


def _palette(path: Path) -> set[tuple[int, int, int]]:
    image = Image.open(path).convert("RGBA")
    return {pixel[:3] for pixel in image.getdata() if pixel[3] > 0}


def main() -> None:
    movement_path = HOE_TEXTURE_DIR / "hoe_cat_move.png"
    attack_path = HOE_TEXTURE_DIR / "hoe_cat_attack.png"
    spin_path = HOE_TEXTURE_DIR / "hoe_cat_whirlwind_body.png"
    hoe_path = HOE_TEXTURE_DIR / "hoe.png"

    weish_metrics = [_frame_metrics(frame) for frame in _weish_normal_frames()]
    movement_metrics = [
        _frame_metrics(frame) for frame in _split_32_frames(movement_path, 4, 4)
    ]
    attack_metrics = [
        _frame_metrics(frame) for frame in _split_32_frames(attack_path, 4, 4)
    ]
    spin_metrics = [
        _frame_metrics(frame) for frame in _split_32_frames(spin_path, 8, 1)
    ]

    for label, metrics in (
        ("movement", movement_metrics),
        ("attack", attack_metrics),
        ("spin", spin_metrics),
    ):
        disconnected = [
            index for index, metric in enumerate(metrics) if len(metric["components"]) != 1
        ]
        if disconnected:
            raise AssertionError(f"{label}: disconnected frames {disconnected}")

    for path in (movement_path, attack_path, spin_path, hoe_path):
        _assert_binary_alpha(path)

    _assert_ratio(
        "movement median width",
        _median(movement_metrics, "width"),
        _median(weish_metrics, "width"),
        0.75,
        1.25,
    )
    _assert_ratio(
        "movement median height",
        _median(movement_metrics, "height"),
        _median(weish_metrics, "height"),
        0.75,
        1.25,
    )
    _assert_ratio(
        "movement median opaque pixels",
        _median(movement_metrics, "opaque"),
        _median(weish_metrics, "opaque"),
        0.70,
        1.15,
    )
    _assert_ratio(
        "movement median edge pixels",
        _median(movement_metrics, "edge"),
        _median(weish_metrics, "edge"),
        0.75,
        1.30,
    )
    _assert_ratio(
        "attack median height",
        _median(attack_metrics, "height"),
        _median(weish_metrics, "height"),
        0.75,
        1.30,
    )
    _assert_ratio(
        "attack median opaque pixels",
        _median(attack_metrics, "opaque"),
        _median(weish_metrics, "opaque"),
        0.65,
        1.15,
    )
    _assert_ratio(
        "spin median height",
        _median(spin_metrics, "height"),
        _median(weish_metrics, "height"),
        0.75,
        1.25,
    )
    _assert_ratio(
        "spin median opaque pixels",
        _median(spin_metrics, "opaque"),
        _median(weish_metrics, "opaque"),
        0.75,
        1.20,
    )

    if {int(metric["bottom"]) for metric in movement_metrics} != {24}:
        raise AssertionError("Movement foot baselines must all be y=24")
    if {int(metric["bottom"]) for metric in spin_metrics} != {24}:
        raise AssertionError("Spin body baselines must all be y=24")
    if {int(attack_metrics[row * 4]["bottom"]) for row in range(4)} != {24}:
        raise AssertionError("Every directional attack ready pose must start on y=24")
    for row in range(4):
        centroids = [
            float(movement_metrics[row * 4 + column]["centroid_x"])
            for column in range(4)
        ]
        if max(centroids) - min(centroids) > 2.0:
            raise AssertionError(f"Movement row {row} jitters horizontally: {centroids}")

    movement_palette = _palette(movement_path)
    shared_palette = movement_palette | _palette(hoe_path)
    if not _palette(attack_path).issubset(shared_palette):
        raise AssertionError("Attack sheet drifted outside the shared character palette")
    if not _palette(spin_path).issubset(shared_palette):
        raise AssertionError("Spin sheet drifted outside the shared character palette")

    print("HOE_CAT_PIXEL_DENSITY_AUDIT_OK")


if __name__ == "__main__":
    main()
