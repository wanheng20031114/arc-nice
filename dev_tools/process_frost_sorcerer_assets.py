#!/usr/bin/env python3
"""Build native Frost Sorcerer textures from accepted imagegen sources.

The accepted source sheets are retained in ``dev_assets/source_images``.  The
background-extracted sheets are split into their authored 4x4 cells, inspected
with the project's pixel-grid analyzer, and center-sampled with nearest-neighbor
resampling into fixed native canvases.  Imagegen deliberately supplied a
pixel-styled source rather than a reliably detectable integer grid, so this
pipeline records that analysis and uses one explicitly reviewed visual scale
per asset family instead of pretending the detected 1 px texture is a logical
grid.

Output contracts:

* ``frost_sorcerer.png`` is 160x160 (4x4 frames of 40x40).
* ``frost_sorcerer_ice_spike.png`` is 128x128 (4x4 frames of 32x32).
* output alpha is binary and transparent pixels have zero RGB payload.
* living Frost Sorcerer frames share a fixed y=38 ground baseline.
* living frames use one fixed character scale and reviewed lower-body anchors;
  oversized spell VFX are clipped by the 40x40 canvas, never allowed to shrink
  the character from one action frame to the next.
* the projectile uses one fixed visual scale, so spawn/impact fragments never
  grow merely because their source bounding box is smaller.
"""

from __future__ import annotations

from pathlib import Path
from statistics import median

import numpy as np
from PIL import Image

from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/frost_sorcerer"
TEXTURE_DIR = ROOT / "resources/texture"

CHARACTER_SOURCE = SOURCE_DIR / "frost_sorcerer_alpha.png"
CHARACTER_ATTACK_REFINED_SOURCE = (
    SOURCE_DIR / "frost_sorcerer_attack_scale_refined_alpha.png"
)
ICE_SPIKE_SOURCE = SOURCE_DIR / "frost_sorcerer_ice_spike_alpha.png"
CHARACTER_OUTPUT = TEXTURE_DIR / "frost_sorcerer.png"
ICE_SPIKE_OUTPUT = TEXTURE_DIR / "frost_sorcerer_ice_spike.png"

GRID_SIZE = 4
CHARACTER_FRAME_SIZE = 40
CHARACTER_MAX_WIDTH = 36
CHARACTER_MAX_HEIGHT = 38
CHARACTER_BASELINE_Y = 38
# The lower-body anchors mirror the corresponding Fire Sorcerer action phases.
# In particular, attack frame 2 keeps the deliberate forward-cast weight shift
# without letting the much wider ice blast determine the actor's scale.
CHARACTER_LIVING_GROUND_ANCHOR_X = (
    (16, 18, 15, 15),
    (16, 23, 18, 18),
    (15, 17, 10, 15),
)
CHARACTER_GROUND_ANCHOR_DEPTH_RATIO = 1.0 / 6.0
DETACHED_BELOW_GAP = 8
DETACHED_BELOW_MAX_AREA_RATIO = 0.01
LIVING_HEIGHT_TOLERANCE = 2
ATTACK_MIN_VISIBLE_AREA_RATIO = 0.75
ICE_SPIKE_FRAME_SIZE = 32
ICE_SPIKE_MAX_WIDTH = 18
ICE_SPIKE_MAX_HEIGHT = 14
ALPHA_THRESHOLD = 96
CHARACTER_PALETTE_COLORS = 24
ICE_SPIKE_PALETTE_COLORS = 12


class AssetContractError(RuntimeError):
    """Raised when an accepted source cannot satisfy a runtime contract."""


def _normalize_alpha(image: Image.Image) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8).copy()
    visible = rgba[:, :, 3] >= ALPHA_THRESHOLD
    rgba[visible, 3] = 255
    rgba[~visible] = (0, 0, 0, 0)
    return Image.fromarray(rgba, "RGBA")


def _crop_cell(sheet: Image.Image, row: int, column: int) -> Image.Image:
    left = round(column * sheet.width / GRID_SIZE)
    right = round((column + 1) * sheet.width / GRID_SIZE)
    top = round(row * sheet.height / GRID_SIZE)
    bottom = round((row + 1) * sheet.height / GRID_SIZE)
    return _normalize_alpha(sheet.crop((left, top, right, bottom)))


def _subject_crop(cell: Image.Image, label: str) -> tuple[Image.Image, dict]:
    analysis = analyze_image(cell)
    bbox = cell.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(f"{label}: source cell is empty")
    print(
        "SOURCE_FRAME_ANALYSIS "
        f"{label} confidence={float(analysis['confidence']):.3f} "
        f"mode={analysis['detection_mode']} "
        f"estimated={analysis['subject_grid_width']}x"
        f"{analysis['subject_grid_height']}"
    )
    return cell.crop(bbox), analysis


def _fit_scale(
    subject: Image.Image,
    base_scale: float,
    max_width: int,
    max_height: int,
) -> float:
    return min(
        base_scale,
        max_width / float(max(subject.width, 1)),
        max_height / float(max(subject.height, 1)),
    )


def _resize_subject(subject: Image.Image, scale: float) -> Image.Image:
    size = (
        max(1, round(subject.width * scale)),
        max(1, round(subject.height * scale)),
    )
    native = subject.resize(size, Image.Resampling.NEAREST)
    # Nearest-neighbor center sampling can legitimately miss the sparse last
    # physical row of an irregular imagegen cluster.  Trim the sampled result
    # once more before applying the runtime anchor so the visible, not merely
    # source-declared, bounds determine the final baseline.
    bbox = native.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError(
            f"nearest-neighbor sampling erased subject {subject.size} at {scale:.5f}"
        )
    return native.crop(bbox)


def _alpha_components(alpha: np.ndarray) -> list[list[tuple[int, int]]]:
    """Return 8-connected visible components as ``(y, x)`` coordinates."""

    height, width = alpha.shape
    visited = np.zeros_like(alpha, dtype=bool)
    components: list[list[tuple[int, int]]] = []
    for start_y, start_x in zip(*np.where(alpha)):
        if visited[start_y, start_x]:
            continue
        visited[start_y, start_x] = True
        pending = [(int(start_y), int(start_x))]
        component: list[tuple[int, int]] = []
        while pending:
            y, x = pending.pop()
            component.append((y, x))
            for offset_y in (-1, 0, 1):
                for offset_x in (-1, 0, 1):
                    if offset_y == 0 and offset_x == 0:
                        continue
                    next_y = y + offset_y
                    next_x = x + offset_x
                    if not (0 <= next_y < height and 0 <= next_x < width):
                        continue
                    if not alpha[next_y, next_x] or visited[next_y, next_x]:
                        continue
                    visited[next_y, next_x] = True
                    pending.append((next_y, next_x))
        components.append(component)
    return components


def _remove_detached_below_subject(subject: Image.Image) -> Image.Image:
    """Discard tiny extraction debris isolated well below a living actor.

    Legitimate frost motes beside or above the actor remain untouched.  This
    specifically prevents a few orphan pixels below the feet from becoming a
    false baseline and making an otherwise normal frame appear much smaller.
    """

    rgba = np.asarray(subject.convert("RGBA"), dtype=np.uint8).copy()
    components = _alpha_components(rgba[:, :, 3] == 255)
    if not components:
        raise AssetContractError("living character subject is empty")
    primary = max(components, key=len)
    primary_bottom = max(y for y, _x in primary)
    max_detached_area = max(
        1,
        round(len(primary) * DETACHED_BELOW_MAX_AREA_RATIO),
    )
    for component in components:
        if component is primary or len(component) > max_detached_area:
            continue
        component_top = min(y for y, _x in component)
        if component_top <= primary_bottom + DETACHED_BELOW_GAP:
            continue
        for y, x in component:
            rgba[y, x] = (0, 0, 0, 0)
    cleaned = Image.fromarray(rgba, "RGBA")
    bbox = cleaned.getchannel("A").getbbox()
    if bbox is None:
        raise AssetContractError("living character cleanup erased the subject")
    return cleaned.crop(bbox)


def _lower_body_anchor_x(native: Image.Image) -> float:
    """Measure a stable horizontal actor anchor from the grounded robe/feet."""

    alpha = np.asarray(native.getchannel("A"), dtype=np.uint8) == 255
    visible_y, _visible_x = np.where(alpha)
    if visible_y.size == 0:
        raise AssetContractError("native character frame is empty")
    bottom = int(visible_y.max())
    depth = max(
        3,
        round(native.height * CHARACTER_GROUND_ANCHOR_DEPTH_RATIO),
    )
    strip_top = max(0, bottom - depth + 1)
    _strip_y, strip_x = np.where(alpha[strip_top : bottom + 1])
    if strip_x.size == 0:
        raise AssetContractError("native character lower-body anchor is empty")
    return float(np.median(strip_x))


def _character_base_scale(subjects: list[Image.Image]) -> float:
    # The four walking frames are the identity/scale anchor.  Every living
    # frame uses this exact scale; compact death fragments must never scale up.
    widths = [subject.width for subject in subjects[:GRID_SIZE]]
    heights = [subject.height for subject in subjects[:GRID_SIZE]]
    return min(
        CHARACTER_MAX_WIDTH / float(median(widths)),
        CHARACTER_MAX_HEIGHT / float(median(heights)),
    )


def _ice_spike_base_scale(subjects: list[Image.Image]) -> float:
    fly_subjects = subjects[:GRID_SIZE]
    return min(
        ICE_SPIKE_MAX_WIDTH
        / float(median(subject.width for subject in fly_subjects)),
        ICE_SPIKE_MAX_HEIGHT
        / float(median(subject.height for subject in fly_subjects)),
    )


def _place_character(subject: Image.Image, base_scale: float) -> Image.Image:
    scale = _fit_scale(
        subject,
        base_scale,
        CHARACTER_MAX_WIDTH,
        CHARACTER_MAX_HEIGHT,
    )
    native = _resize_subject(subject, scale)
    frame = Image.new(
        "RGBA",
        (CHARACTER_FRAME_SIZE, CHARACTER_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    left = round((CHARACTER_FRAME_SIZE - native.width) * 0.5)
    top = CHARACTER_BASELINE_Y - native.height + 1
    if left < 1 or top < 0 or left + native.width > CHARACTER_FRAME_SIZE - 1:
        raise AssetContractError(
            f"character frame {native.size} cannot fit the fixed native canvas"
        )
    frame.alpha_composite(native, (left, top))
    return frame


def _place_living_character(
    subject: Image.Image,
    base_scale: float,
    ground_anchor_x: int,
) -> Image.Image:
    """Place a living frame without VFX-dependent per-frame fitting.

    The accepted source is sampled at exactly the walking identity scale.  A
    wide staff sweep or a tall frost mote may therefore extend beyond the
    native canvas; Pillow clips that peripheral VFX while the actor retains
    its authored pixel density, baseline and reviewed action-phase anchor.
    """

    native = _resize_subject(subject, base_scale)
    frame = Image.new(
        "RGBA",
        (CHARACTER_FRAME_SIZE, CHARACTER_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    left = round(ground_anchor_x - _lower_body_anchor_x(native))
    top = CHARACTER_BASELINE_Y - native.height + 1
    frame.alpha_composite(native, (left, top))
    if frame.getchannel("A").getbbox() is None:
        raise AssetContractError(
            f"living character frame {native.size} lies outside the native canvas"
        )
    return frame


def _place_ice_spike(subject: Image.Image, base_scale: float) -> Image.Image:
    scale = _fit_scale(
        subject,
        base_scale,
        ICE_SPIKE_MAX_WIDTH,
        ICE_SPIKE_MAX_HEIGHT,
    )
    native = _resize_subject(subject, scale)
    frame = Image.new(
        "RGBA",
        (ICE_SPIKE_FRAME_SIZE, ICE_SPIKE_FRAME_SIZE),
        (0, 0, 0, 0),
    )
    left = round((ICE_SPIKE_FRAME_SIZE - native.width) * 0.5)
    top = round((ICE_SPIKE_FRAME_SIZE - native.height) * 0.5)
    frame.alpha_composite(native, (left, top))
    return frame


def _assemble_sheet(frames: list[Image.Image], frame_size: int) -> Image.Image:
    if len(frames) != GRID_SIZE * GRID_SIZE:
        raise AssetContractError(f"expected 16 frames, received {len(frames)}")
    sheet = Image.new(
        "RGBA",
        (frame_size * GRID_SIZE, frame_size * GRID_SIZE),
        (0, 0, 0, 0),
    )
    for index, frame in enumerate(frames):
        sheet.alpha_composite(
            frame,
            ((index % GRID_SIZE) * frame_size, (index // GRID_SIZE) * frame_size),
        )
    return sheet


def _quantize_visible_colors(image: Image.Image, color_count: int) -> Image.Image:
    rgba = np.asarray(image.convert("RGBA"), dtype=np.uint8)
    visible = rgba[:, :, 3] == 255
    if not np.any(visible):
        return image
    visible_rgb = rgba[:, :, :3][visible]
    strip = Image.fromarray(visible_rgb.reshape(1, -1, 3), "RGB")
    palette_source = strip.quantize(
        colors=color_count,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    palette = palette_source.getpalette()
    palette_image = Image.new("P", (1, 1))
    palette_image.putpalette(palette)
    rgb_sheet = Image.fromarray(rgba[:, :, :3], "RGB")
    quantized = rgb_sheet.quantize(
        palette=palette_image,
        dither=Image.Dither.NONE,
    ).convert("RGBA")
    result = np.asarray(quantized, dtype=np.uint8).copy()
    result[:, :, 3] = rgba[:, :, 3]
    result[~visible] = (0, 0, 0, 0)
    return Image.fromarray(result, "RGBA")


def _assert_output_contract(
    sheet: Image.Image,
    label: str,
    frame_size: int,
    max_width: int,
    max_height: int,
    require_ground_baseline: bool,
) -> None:
    expected = frame_size * GRID_SIZE
    if sheet.size != (expected, expected):
        raise AssetContractError(
            f"{label}: size {sheet.size} does not match {expected}x{expected}"
        )
    rgba = np.asarray(sheet.convert("RGBA"), dtype=np.uint8)
    alpha_values = set(int(value) for value in np.unique(rgba[:, :, 3]))
    if not alpha_values.issubset({0, 255}):
        raise AssetContractError(f"{label}: alpha is not binary: {alpha_values}")
    if np.any(rgba[:, :, :3][rgba[:, :, 3] == 0] != 0):
        raise AssetContractError(f"{label}: transparent RGB payload is not zero")

    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            frame = sheet.crop(
                (
                    column * frame_size,
                    row * frame_size,
                    (column + 1) * frame_size,
                    (row + 1) * frame_size,
                )
            )
            bbox = frame.getchannel("A").getbbox()
            if bbox is None:
                raise AssetContractError(f"{label} frame {row}:{column} is empty")
            width = bbox[2] - bbox[0]
            height = bbox[3] - bbox[1]
            if width > max_width or height > max_height:
                raise AssetContractError(
                    f"{label} frame {row}:{column} is {width}x{height}, "
                    f"above {max_width}x{max_height}"
                )
            if require_ground_baseline and bbox[3] - 1 != CHARACTER_BASELINE_Y:
                raise AssetContractError(
                    f"{label} frame {row}:{column} baseline is {bbox[3] - 1}, "
                    f"expected {CHARACTER_BASELINE_Y}"
                )


def _assert_living_character_scale(sheet: Image.Image) -> None:
    """Reject the former VFX-bbox fitting regression with pixel metrics."""

    move_heights: list[int] = []
    move_areas: list[int] = []
    living_metrics: list[tuple[int, int, int, int]] = []
    for row in range(3):
        for column in range(GRID_SIZE):
            frame = sheet.crop(
                (
                    column * CHARACTER_FRAME_SIZE,
                    row * CHARACTER_FRAME_SIZE,
                    (column + 1) * CHARACTER_FRAME_SIZE,
                    (row + 1) * CHARACTER_FRAME_SIZE,
                )
            )
            alpha = np.asarray(frame.getchannel("A"), dtype=np.uint8) == 255
            visible_y, _visible_x = np.where(alpha)
            if visible_y.size == 0:
                raise AssetContractError(
                    f"living character frame {row}:{column} is empty"
                )
            height = int(visible_y.max() - visible_y.min() + 1)
            area = int(np.count_nonzero(alpha))
            living_metrics.append((row, column, height, area))
            if row == 0:
                move_heights.append(height)
                move_areas.append(area)

    move_height = float(median(move_heights))
    move_area = float(median(move_areas))
    minimum_height = move_height - LIVING_HEIGHT_TOLERANCE
    minimum_attack_area = move_area * ATTACK_MIN_VISIBLE_AREA_RATIO
    for row, column, height, area in living_metrics:
        if height < minimum_height:
            raise AssetContractError(
                f"living character frame {row}:{column} height {height} is below "
                f"the walking identity threshold {minimum_height:.1f}"
            )
        if row == 2 and area < minimum_attack_area:
            raise AssetContractError(
                f"attack frame {column} visible area {area} is below the walking "
                f"identity threshold {minimum_attack_area:.1f}"
            )


def _load_subjects(path: Path, label: str) -> list[Image.Image]:
    if not path.is_file():
        raise FileNotFoundError(path)
    sheet = Image.open(path).convert("RGBA")
    subjects: list[Image.Image] = []
    for row in range(GRID_SIZE):
        for column in range(GRID_SIZE):
            subject, _analysis = _subject_crop(
                _crop_cell(sheet, row, column),
                f"{label}_{row}_{column}",
            )
            subjects.append(subject)
    return subjects


def _load_subject_row(path: Path, label: str, row: int) -> list[Image.Image]:
    if not path.is_file():
        raise FileNotFoundError(path)
    sheet = Image.open(path).convert("RGBA")
    subjects: list[Image.Image] = []
    for column in range(GRID_SIZE):
        subject, _analysis = _subject_crop(
            _crop_cell(sheet, row, column),
            f"{label}_{row}_{column}",
        )
        subjects.append(subject)
    return subjects


def main() -> None:
    character_subjects = _load_subjects(CHARACTER_SOURCE, "character")
    # The accepted refinement changes only the attack row.  Keeping the other
    # rows from the first accepted source protects the authored walk cycle and
    # death silhouette from unrelated generative drift.
    attack_row = _load_subject_row(
        CHARACTER_ATTACK_REFINED_SOURCE,
        "character_attack_refined",
        2,
    )
    character_subjects[2 * GRID_SIZE : 3 * GRID_SIZE] = attack_row
    character_scale = _character_base_scale(character_subjects)
    living_subjects = [
        _remove_detached_below_subject(subject)
        for subject in character_subjects[: 3 * GRID_SIZE]
    ]
    character_frames = []
    for index, subject in enumerate(living_subjects):
        row = index // GRID_SIZE
        column = index % GRID_SIZE
        character_frames.append(
            _place_living_character(
                subject,
                character_scale,
                CHARACTER_LIVING_GROUND_ANCHOR_X[row][column],
            )
        )
    # Defeat fragments are not a coherent standing actor.  Retain the original
    # fit-without-upscaling behavior for that row only.
    character_frames.extend(
        _place_character(subject, character_scale)
        for subject in character_subjects[3 * GRID_SIZE :]
    )
    character_sheet = _quantize_visible_colors(
        _assemble_sheet(character_frames, CHARACTER_FRAME_SIZE),
        CHARACTER_PALETTE_COLORS,
    )
    _assert_living_character_scale(character_sheet)
    _assert_output_contract(
        character_sheet,
        "frost sorcerer",
        CHARACTER_FRAME_SIZE,
        CHARACTER_FRAME_SIZE,
        CHARACTER_BASELINE_Y + 1,
        True,
    )

    ice_spike_subjects = _load_subjects(ICE_SPIKE_SOURCE, "ice_spike")
    ice_spike_scale = _ice_spike_base_scale(ice_spike_subjects)
    ice_spike_frames = [
        _place_ice_spike(subject, ice_spike_scale)
        for subject in ice_spike_subjects
    ]
    ice_spike_sheet = _quantize_visible_colors(
        _assemble_sheet(ice_spike_frames, ICE_SPIKE_FRAME_SIZE),
        ICE_SPIKE_PALETTE_COLORS,
    )
    _assert_output_contract(
        ice_spike_sheet,
        "frost sorcerer ice spike",
        ICE_SPIKE_FRAME_SIZE,
        ICE_SPIKE_MAX_WIDTH,
        ICE_SPIKE_MAX_HEIGHT,
        False,
    )

    TEXTURE_DIR.mkdir(parents=True, exist_ok=True)
    character_sheet.save(CHARACTER_OUTPUT, optimize=True)
    ice_spike_sheet.save(ICE_SPIKE_OUTPUT, optimize=True)
    print(
        "FROST_SORCERER_ASSETS_OK "
        f"character_scale={character_scale:.5f} "
        f"ice_spike_scale={ice_spike_scale:.5f}"
    )
    print(f"WROTE {CHARACTER_OUTPUT}")
    print(f"WROTE {ICE_SPIKE_OUTPUT}")


if __name__ == "__main__":
    main()
