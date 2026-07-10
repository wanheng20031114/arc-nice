#!/usr/bin/env python3
"""Validate the rebuilt Hoe Cat against Weishidaier's native pixel language."""

from __future__ import annotations

import math
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


def _assert_soft_alpha(path: Path) -> None:
    alpha = Image.open(path).convert("RGBA").getchannel("A")
    values = set(alpha.getdata())
    if 0 not in values or 255 not in values or not any(0 < value < 255 for value in values):
        raise AssertionError(f"{path.name}: VFX must retain transparent, soft, and opaque alpha")


def _opaque_mask(frame: Image.Image) -> tuple[bool, ...]:
    return tuple(pixel[3] > 0 for pixel in frame.convert("RGBA").getdata())


def _assert_exact_frame(left: Image.Image, right: Image.Image, label: str) -> None:
    if list(left.convert("RGBA").getdata()) != list(right.convert("RGBA").getdata()):
        raise AssertionError(f"{label}: frames differ")


def _assert_mirror(right: Image.Image, left: Image.Image, label: str) -> None:
    mirrored = right.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    _assert_exact_frame(mirrored, left, label)


def _edge_dark_fraction(frame: Image.Image) -> float:
    rgba = frame.convert("RGBA")
    pixels = rgba.load()
    opaque = {
        (x, y)
        for y in range(rgba.height)
        for x in range(rgba.width)
        if pixels[x, y][3] > 0
    }
    edge = [
        (x, y)
        for x, y in opaque
        if any(
            (x + delta_x, y + delta_y) not in opaque
            for delta_x, delta_y in ((-1, 0), (1, 0), (0, -1), (0, 1))
        )
    ]
    if not edge:
        raise AssertionError("Cannot measure the edge of an empty frame")
    dark = sum(
        0.2126 * pixels[x, y][0]
        + 0.7152 * pixels[x, y][1]
        + 0.0722 * pixels[x, y][2]
        <= 70.0
        for x, y in edge
    )
    return dark / len(edge)


def _assert_crisp_character_edges(frames: list[Image.Image], label: str) -> None:
    fractions = [_edge_dark_fraction(frame) for frame in frames]
    if min(fractions) < 0.85:
        raise AssertionError(
            f"{label} outline has soft gaps: minimum dark edge {min(fractions):.3f}"
        )


def _assert_front_eyes(frames: list[Image.Image]) -> None:
    for index, frame in enumerate(frames[:4]):
        rgba = frame.convert("RGBA")
        pixels = rgba.load()
        bbox = rgba.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"Front frame {index} is empty")
        center_x = (bbox[0] + bbox[2] - 1) * 0.5
        face_top = bbox[1] + 4
        face_bottom = min(bbox[1] + 10, bbox[3])
        dark_interior: list[tuple[int, int]] = []
        for y in range(face_top, face_bottom):
            for x in range(bbox[0] + 1, bbox[2] - 1):
                red, green, blue, alpha = pixels[x, y]
                luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if alpha > 0 and luminance <= 70.0 and all(
                    pixels[x + delta_x, y + delta_y][3] > 0
                    for delta_x, delta_y in ((-1, 0), (1, 0), (0, -1), (0, 1))
                ):
                    dark_interior.append((x, y))
        has_left_eye = any(x <= center_x - 1 for x, _y in dark_interior)
        has_right_eye = any(x >= center_x + 1 for x, _y in dark_interior)
        if not has_left_eye or not has_right_eye:
            raise AssertionError(
                f"Front frame {index} lost its two-sided dark eye read: {dark_interior}"
            )


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

    expected_bottoms = (25, 25, 25, 25)
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
            and bbox[1] >= 1
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


def _assert_death(metrics: list[dict]) -> None:
    for index, metric in enumerate(metrics):
        bbox = metric["bbox"]
        if not (
            14 <= int(metric["width"]) <= 28
            and 12 <= int(metric["height"]) <= 25
            and 220 <= int(metric["opaque"]) <= 310
            and bbox[0] >= 2
            and bbox[1] >= 2
            and bbox[2] <= 30
            and bbox[3] == 26
        ):
            raise AssertionError(f"Death frame {index} is clipped or changes scale: {metric}")
    heights = [int(metric["height"]) for metric in metrics]
    if not (heights[0] < heights[1] and heights[1] > heights[2] > heights[3] > heights[4]):
        raise AssertionError(f"Death silhouette does not collapse progressively: {heights}")


def _nearby_overlap_ratio(
    first: Image.Image,
    second: Image.Image,
    radius: int = 2,
) -> float:
    first_pixels = {
        (x, y)
        for y in range(first.height)
        for x in range(first.width)
        if first.getpixel((x, y))[3] > 0
    }
    second_pixels = {
        (x, y)
        for y in range(second.height)
        for x in range(second.width)
        if second.getpixel((x, y))[3] > 0
    }
    smaller, larger = (
        (first_pixels, second_pixels)
        if len(first_pixels) <= len(second_pixels)
        else (second_pixels, first_pixels)
    )
    if not smaller:
        return 0.0
    expanded_larger = {
        (x + offset_x, y + offset_y)
        for x, y in larger
        for offset_x in range(-radius, radius + 1)
        for offset_y in range(-radius, radius + 1)
    }
    return len(smaller & expanded_larger) / len(smaller)


def _assert_vfx(
    slash_frames: list[Image.Image],
    whirlwind_frames: list[Image.Image],
) -> None:
    slash_alpha_areas = [
        sum(pixel[3] for pixel in frame.getdata()) / 255.0
        for frame in slash_frames
    ]
    expected_area_ranges = (
        (10.0, 40.0),
        (110.0, 220.0),
        (400.0, 600.0),
        (750.0, 1000.0),
        (580.0, 800.0),
        (150.0, 300.0),
        (40.0, 110.0),
        (3.0, 20.0),
    )
    if len(slash_alpha_areas) != len(expected_area_ranges) or any(
        not minimum <= area <= maximum
        for area, (minimum, maximum) in zip(slash_alpha_areas, expected_area_ranges)
    ):
        raise AssertionError(
            f"Slash arc does not read build-impact-dissipate: {slash_alpha_areas}"
        )
    if not (
        slash_alpha_areas[0] < slash_alpha_areas[1]
        < slash_alpha_areas[2] < slash_alpha_areas[3]
        and slash_alpha_areas[3] > slash_alpha_areas[4]
        > slash_alpha_areas[5] > slash_alpha_areas[6] > slash_alpha_areas[7]
    ):
        raise AssertionError(
            f"Slash density progression is not fluid: {slash_alpha_areas}"
        )

    for frame_index, frame in enumerate(slash_frames):
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise AssertionError(f"Slash frame {frame_index} is empty")
        if bbox[0] < 4 or bbox[1] < 4 or bbox[2] > 108 or bbox[3] > 108:
            raise AssertionError(
                f"Slash frame {frame_index} lost its transparent safety padding: {bbox}"
            )
    for peak_index in (3, 4):
        peak_bbox = slash_frames[peak_index].getchannel("A").getbbox()
        if peak_bbox[2] - peak_bbox[0] < 45 or peak_bbox[3] - peak_bbox[1] < 45:
            raise AssertionError(f"Slash impact frame {peak_index} is too small: {peak_bbox}")
        peak_alpha = [
            pixel[3]
            for pixel in slash_frames[peak_index].getdata()
            if pixel[3] > 0
        ]
        partial_ratio = sum(alpha < 255 for alpha in peak_alpha) / len(peak_alpha)
        strong_core_ratio = sum(alpha >= 240 for alpha in peak_alpha) / len(peak_alpha)
        if partial_ratio > 0.35 or strong_core_ratio < 0.65:
            raise AssertionError(
                f"Slash impact frame {peak_index} lost its crisp alpha core: "
                f"partial={partial_ratio:.3f}, strong={strong_core_ratio:.3f}"
            )

    pivot = 56.0
    maximum_radii: list[float] = []
    core_maximum_radii: list[float] = []
    strict_outside_alpha_ratios: list[float] = []
    far_outside_alpha_ratios: list[float] = []
    for frame_index, frame in enumerate(slash_frames):
        maximum_radius = 0.0
        core_maximum_radius = 0.0
        alpha_total = 0
        strict_outside_alpha = 0
        far_outside_alpha = 0
        for y in range(frame.height):
            for x in range(frame.width):
                alpha = frame.getpixel((x, y))[3]
                if alpha == 0:
                    continue
                delta_x = (x + 0.5) - pivot
                delta_y = (y + 0.5) - pivot
                radius = math.hypot(delta_x, delta_y)
                maximum_radius = max(maximum_radius, radius)
                angle = abs(math.degrees(math.atan2(delta_y, delta_x)))
                if alpha >= 160:
                    core_maximum_radius = max(core_maximum_radius, radius)
                alpha_total += alpha
                if delta_x <= 0.0 or angle > 30.0 or radius > 48.0:
                    strict_outside_alpha += alpha
                # Near-pivot tapered ends may sweep wider. At meaningful reach,
                # however, even faint pixels must stay close to the authored
                # 80-degree visual envelope and the radius-48 hit range.
                if radius >= 28.0 and (
                    delta_x <= 0.0 or angle > 40.0 or radius > 53.0
                ):
                    far_outside_alpha += alpha
        maximum_radii.append(maximum_radius)
        core_maximum_radii.append(core_maximum_radius)
        strict_outside_alpha_ratios.append(strict_outside_alpha / alpha_total)
        far_outside_alpha_ratios.append(far_outside_alpha / alpha_total)

    if not all(45.0 <= core_maximum_radii[index] <= 50.5 for index in (3, 4)):
        raise AssertionError(
            f"Slash impact core no longer hugs the radius-48 reach: {core_maximum_radii}"
        )
    if not 49.0 <= max(maximum_radii[3:5]) <= 53.0:
        raise AssertionError(
            f"Slash tips must extend only slightly beyond radius 48: {maximum_radii}"
        )
    if any(far_outside_alpha_ratios[index] > 0.06 for index in (3, 4)):
        raise AssertionError(
            f"Slash peak escaped its relaxed 80-degree/radius-53 envelope: "
            f"{far_outside_alpha_ratios}"
        )
    if any(
        not 0.12 <= strict_outside_alpha_ratios[index] <= 0.45
        for index in (3, 4)
    ):
        raise AssertionError(
            "Slash peak must keep natural tapered pixels outside the exact hit mask "
            f"without overwhelming it: {strict_outside_alpha_ratios}"
        )
    if not maximum_radii[4] > maximum_radii[5] > maximum_radii[6] > maximum_radii[7]:
        raise AssertionError(f"Slash dissipation reach is not progressive: {maximum_radii}")
    overlap_ratios = [
        _nearby_overlap_ratio(first, second)
        for first, second in zip(slash_frames, slash_frames[1:])
    ]
    if any(ratio < 0.65 for ratio in overlap_ratios):
        raise AssertionError(f"Adjacent slash silhouettes jump abruptly: {overlap_ratios}")

    whirlwind_alpha_areas = [
        sum(pixel[3] for pixel in frame.getdata()) / 255.0
        for frame in whirlwind_frames
    ]
    expected_whirlwind_area_ranges = (
        (700.0, 1100.0),
        (2500.0, 3200.0),
        (4200.0, 5000.0),
        (5800.0, 6800.0),
        (4300.0, 5200.0),
        (2200.0, 3000.0),
        (1300.0, 1900.0),
        (200.0, 450.0),
    )
    if any(
        not minimum <= area <= maximum
        for area, (minimum, maximum) in zip(
            whirlwind_alpha_areas,
            expected_whirlwind_area_ranges,
        )
    ) or not (
        whirlwind_alpha_areas[0] < whirlwind_alpha_areas[1]
        < whirlwind_alpha_areas[2] < whirlwind_alpha_areas[3]
        and whirlwind_alpha_areas[3] > whirlwind_alpha_areas[4]
        > whirlwind_alpha_areas[5] > whirlwind_alpha_areas[6]
        > whirlwind_alpha_areas[7]
    ):
        raise AssertionError(
            "Whirlwind VFX must read as a strong build-impact-dissipate ring: "
            f"{whirlwind_alpha_areas}"
        )
    whirlwind_pivot = 80.0
    maximum_whirlwind_radius = 0.0
    for frame_index, frame in enumerate(whirlwind_frames):
        bbox = frame.getchannel("A").getbbox()
        if (
            bbox is None
            or bbox[0] < 10
            or bbox[1] < 10
            or bbox[2] > 150
            or bbox[3] > 150
        ):
            raise AssertionError(
                f"Whirlwind frame {frame_index} lost its 10px safety margin: {bbox}"
            )
        center_alpha_area = 0.0
        radii: list[float] = []
        covered_angle_bins: set[int] = set()
        for y in range(frame.height):
            for x in range(frame.width):
                alpha = frame.getpixel((x, y))[3]
                if alpha == 0:
                    continue
                delta_x = (x + 0.5) - whirlwind_pivot
                delta_y = (y + 0.5) - whirlwind_pivot
                radius = math.hypot(delta_x, delta_y)
                radii.append(radius)
                maximum_whirlwind_radius = max(maximum_whirlwind_radius, radius)
                if radius < 20.0:
                    center_alpha_area += alpha / 255.0
                if 48.0 <= radius <= 64.0 and alpha >= 160:
                    angle = math.degrees(math.atan2(delta_y, delta_x)) % 360.0
                    covered_angle_bins.add(int(angle / 5.0))
        if center_alpha_area > 5.0:
            raise AssertionError(
                f"Whirlwind frame {frame_index} obscures its player opening: "
                f"{center_alpha_area:.2f}"
            )
        if frame_index in (2, 3):
            angular_coverage = len(covered_angle_bins) / 72.0
            if angular_coverage < 0.95:
                raise AssertionError(
                    f"Whirlwind impact frame {frame_index} is not a true 360 ring: "
                    f"coverage={angular_coverage:.3f}"
                )
            radii.sort()
            radius_99 = radii[round((len(radii) - 1) * 0.99)]
            if frame_index == 3 and not 60.0 <= radius_99 <= 64.0:
                raise AssertionError(
                    f"Whirlwind peak no longer matches radius 62.4: r99={radius_99:.2f}"
                )
    if maximum_whirlwind_radius > 70.0:
        raise AssertionError(
            f"Whirlwind tips exceed the radius-70 visual envelope: "
            f"{maximum_whirlwind_radius:.2f}"
        )


def main() -> None:
    movement_path = HOE_DIR / "hoe_cat_move.png"
    attack_path = HOE_DIR / "hoe_cat_attack.png"
    spin_path = HOE_DIR / "hoe_cat_whirlwind_body.png"
    death_path = HOE_DIR / "hoe_cat_death.png"
    slash_path = HOE_DIR / "hoe_cat_basic_slash_vfx.png"
    whirlwind_path = HOE_DIR / "hoe_cat_whirlwind_vfx.png"
    whirlwind_icon_path = HOE_DIR / "whirlwind_icon.png"
    portrait_path = HOE_DIR / "portrait.png"
    binary_output_paths = (
        movement_path,
        attack_path,
        spin_path,
        death_path,
        whirlwind_icon_path,
        portrait_path,
    )
    for path in binary_output_paths:
        _assert_binary_alpha(path)
    _assert_soft_alpha(slash_path)
    _assert_soft_alpha(whirlwind_path)

    movement_frames = _split(movement_path, 4, 4, 32)
    attack_frames = _split(attack_path, 5, 4, 32)
    spin_frames = _split(spin_path, 8, 1, 32)
    death_frames = _split(death_path, 5, 1, 32)
    slash_frames = _split(slash_path, 8, 1, 112)
    whirlwind_frames = _split(whirlwind_path, 8, 1, 160)
    movement_metrics = [_metrics(frame) for frame in movement_frames]
    attack_metrics = [_metrics(frame) for frame in attack_frames]
    spin_metrics = [_metrics(frame) for frame in spin_frames]
    death_metrics = [_metrics(frame) for frame in death_frames]
    weish_metrics = [_metrics(frame) for frame in _weish_normal_frames()]

    _assert_character_scale(movement_metrics, weish_metrics)
    _assert_movement(movement_frames, movement_metrics)
    _assert_attack(attack_frames, attack_metrics)
    _assert_spin(spin_metrics)
    _assert_death(death_metrics)
    _assert_vfx(slash_frames, whirlwind_frames)
    _assert_crisp_character_edges(movement_frames, "Movement")
    _assert_crisp_character_edges(attack_frames, "Attack")
    _assert_crisp_character_edges(spin_frames, "Whirlwind body")
    _assert_crisp_character_edges(death_frames, "Death")
    _assert_front_eyes(movement_frames)

    character_palette = _palette(movement_path)
    if len(character_palette) > 16:
        raise AssertionError(f"Movement palette has {len(character_palette)} colors")
    attack_extra_colors = _palette(attack_path) - character_palette
    if attack_extra_colors - {(0, 0, 0)}:
        raise AssertionError(
            f"Attack palette drifted from the shared character palette: {attack_extra_colors}"
        )
    if not _palette(spin_path).issubset(character_palette):
        raise AssertionError("Whirlwind body palette drifted from the shared character palette")
    if not _palette(death_path).issubset(character_palette):
        raise AssertionError("Death palette drifted from the shared character palette")
    if len(_palette(slash_path)) > 8:
        raise AssertionError("Pale-yellow slash VFX palette exceeds eight colors")
    if len(_palette(whirlwind_path)) > 8:
        raise AssertionError("Whirlwind VFX palette exceeds eight colors")
    whirlwind_icon = Image.open(whirlwind_icon_path).convert("RGBA")
    if whirlwind_icon.size != (128, 128):
        raise AssertionError(f"Whirlwind icon must be 128x128: {whirlwind_icon.size}")
    if len(_palette(whirlwind_icon_path)) > 14:
        raise AssertionError("Whirlwind icon palette exceeds fourteen colors")

    portrait = Image.open(portrait_path).convert("RGBA")
    front_bbox = movement_frames[0].getchannel("A").getbbox()
    if front_bbox is None:
        raise AssertionError("Front movement frame is empty")
    front_subject = movement_frames[0].crop(front_bbox)
    enlarged_subject = front_subject.resize(
        (front_subject.width * 6, front_subject.height * 6),
        Image.Resampling.NEAREST,
    )
    expected_portrait = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
    expected_portrait.alpha_composite(
        enlarged_subject,
        ((128 - enlarged_subject.width) // 2, (128 - enlarged_subject.height) // 2),
    )
    _assert_exact_frame(portrait, expected_portrait, "portrait cropped native upscale")
    if portrait.getchannel("A").getbbox() != (13, 10, 115, 118):
        raise AssertionError(
            f"Portrait scale or centering drifted: {portrait.getchannel('A').getbbox()}"
        )

    movement_opaque = [int(metric["opaque"]) for metric in movement_metrics]
    print(
        "HOE_CAT_PIXEL_DENSITY_AUDIT_OK "
        f"move_opaque={min(movement_opaque)}..{max(movement_opaque)} "
        f"median={median(movement_opaque):.1f} "
        f"weish_median={median(int(metric['opaque']) for metric in weish_metrics):.1f}"
    )


if __name__ == "__main__":
    main()
