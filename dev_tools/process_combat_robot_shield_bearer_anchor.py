#!/usr/bin/env python3
"""Build the approved native-32 anchor for the shield-bearing robot.

ImageGen candidate C defines the shield language only.  Its high-resolution
pixels are never resized into the project.  The approved drone-operator anchor
supplies the immutable antenna, head and legs, while the aligned gunner anchor
is used as a second identity check.  A compact torso, linear arms and candidate
C's asymmetric tower shield are then authored directly on the 32x32 logical
canvas with the existing mechanical-life palette.

This is a source/review builder.  It writes no runtime texture.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw

from process_combat_robot_assets import PALETTE, snap_palette


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_shield_bearer"
)
PREVIEW_DIR = PROJECT_ROOT / "dev_assets" / "generated_previews"

IMAGEGEN_REFERENCE_PATH = (
    SOURCE_DIR / "combat_robot_shield_bearer_anchor_c_imagegen.png"
)
OPERATOR_ANCHOR_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_drone_operator"
    / "combat_robot_drone_operator_anchor_c_approved_native32.png"
)
GUNNER_ANCHOR_PATH = (
    PROJECT_ROOT
    / "dev_assets"
    / "source_images"
    / "combat_robot_gunner"
    / "combat_robot_gunner_anchor_b_native32.png"
)

SWORD_RUNTIME_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot.png"
)
GUNNER_RUNTIME_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_gunner.png"
)
OPERATOR_RUNTIME_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_drone_operator.png"
)

OUTPUT_PATH = (
    SOURCE_DIR
    / "combat_robot_shield_bearer_anchor_c_approved_native32.png"
)
UPSCALED_PATH = (
    SOURCE_DIR
    / "combat_robot_shield_bearer_anchor_c_approved_16x.png"
)
COMPARISON_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_anchor_comparison.png"
)
REPORT_PATH = (
    PREVIEW_DIR / "combat_robot_shield_bearer_anchor_audit.json"
)

FRAME_SIZE = 32
BASELINE_Y = 28
MAX_VISIBLE_SIZE = 28
REGISTERED_CENTER_X = 16
GUNNER_IDENTITY_SHIFT_X = 4
SHIELD_BBOX = (24, 8, 30, 26)
SHIELD_SIZE = (6, 18)

TRANSPARENT = (0, 0, 0, 0)
REVIEW_BACKGROUND = (13, 19, 31, 255)
REVIEW_TEXT = (226, 229, 226, 255)

OUTLINE = PALETTE[0]
DEEP_SHADOW = PALETTE[1]
JOINT_SHADOW = PALETTE[2]
DARK_STEEL = PALETTE[3]
MID_STEEL = PALETTE[4]
PLATE_GRAY = PALETTE[5]
PLATE_HIGHLIGHT = PALETTE[6]
ACTIVE_RED = PALETTE[9]
HOT_ORANGE = PALETTE[10]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _normalize(image: Image.Image) -> Image.Image:
    """Snap the fixed palette and normalize binary, clean transparency."""
    normalized = snap_palette(image.convert("RGBA"))
    pixels = normalized.load()
    for y in range(normalized.height):
        for x in range(normalized.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha < 128:
                pixels[x, y] = TRANSPARENT
            else:
                pixels[x, y] = (red, green, blue, 255)
    return normalized


def _load_identity_sources() -> tuple[Image.Image, Image.Image, int]:
    operator = _normalize(Image.open(OPERATOR_ANCHOR_PATH))
    if operator.size != (FRAME_SIZE, FRAME_SIZE):
        raise ValueError(
            f"Operator anchor must be 32x32, got {operator.size}"
        )
    if operator.getchannel("A").getbbox() != (10, 4, 24, 28):
        raise ValueError(
            "Operator anchor registration changed: "
            f"{operator.getchannel('A').getbbox()}"
        )

    gunner_source = _normalize(Image.open(GUNNER_ANCHOR_PATH))
    if gunner_source.size != (FRAME_SIZE, FRAME_SIZE):
        raise ValueError(
            f"Gunner anchor must be 32x32, got {gunner_source.size}"
        )
    gunner = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    gunner.alpha_composite(gunner_source, (GUNNER_IDENTITY_SHIFT_X, 0))

    # These regions contain only the shared robot identity.  The gun,
    # controller and their hands intentionally occupy the excluded middle band.
    shared_identity_pixels = 0
    for y in (*range(0, 14), *range(23, FRAME_SIZE)):
        for x in range(FRAME_SIZE):
            operator_pixel = operator.getpixel((x, y))
            gunner_pixel = gunner.getpixel((x, y))
            if operator_pixel[3] or gunner_pixel[3]:
                if operator_pixel != gunner_pixel:
                    raise AssertionError(
                        "Existing operator/gunner identity mismatch at "
                        f"{(x, y)}"
                    )
                shared_identity_pixels += 1
    return operator, gunner, shared_identity_pixels


def _copy_immutable_identity(operator: Image.Image) -> Image.Image:
    """Copy the approved antenna/head and the complete six-row gait anchor."""
    frame = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    # The approved head ends on row 14.  Keeping x<=20 excludes the controller
    # hand at x=22 without redrawing a single chassis pixel.
    for y in range(0, 15):
        for x in range(0, 21):
            pixel = operator.getpixel((x, y))
            if pixel[3]:
                frame.putpixel((x, y), pixel)
    # Preserve the operator's exact leg pixels and y=28 baseline contract.
    for y in range(22, FRAME_SIZE):
        for x in range(FRAME_SIZE):
            pixel = operator.getpixel((x, y))
            if pixel[3]:
                frame.putpixel((x, y), pixel)
    return frame


def _draw_body_and_arms(frame: Image.Image) -> None:
    """Author one compact box torso and two deliberately linear arms."""
    draw = ImageDraw.Draw(frame)

    # Six-row box torso, centred on the established x=16 registration.
    draw.polygon(
        ((11, 15), (20, 15), (20, 20), (19, 21), (12, 21), (11, 20)),
        fill=OUTLINE,
    )
    draw.rectangle((12, 16, 19, 19), fill=MID_STEEL)
    draw.line((12, 16, 12, 19), fill=PLATE_GRAY)
    draw.rectangle((13, 17, 18, 19), fill=DARK_STEEL)
    draw.line((13, 17, 18, 17), fill=MID_STEEL)
    draw.line((12, 20, 19, 20), fill=OUTLINE)

    # Rear arm hangs loose in candidate C's simple wire-limb language.
    rear_arm = {
        (10, 16): OUTLINE,
        (9, 17): OUTLINE,
        (9, 18): MID_STEEL,
        (8, 19): OUTLINE,
        (8, 20): OUTLINE,
        (8, 21): OUTLINE,
        (9, 21): PLATE_GRAY,
        (10, 21): OUTLINE,
    }
    for point, color in rear_arm.items():
        frame.putpixel(point, color)

    # The forward arm is drawn behind the shield and visibly joins its handle.
    draw.rectangle((20, 16, 23, 18), fill=OUTLINE)
    draw.line((20, 17, 22, 17), fill=MID_STEEL)
    frame.putpixel((23, 17), PLATE_HIGHLIGHT)


def _build_shield_layer() -> Image.Image:
    """Draw candidate C's 6x18 tower shield without any resampling."""
    shield = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(shield)

    # Eight vertices give the top-left two-step bevel and compact lower taper.
    draw.polygon(
        (
            (26, 8),
            (28, 8),
            (29, 9),
            (29, 24),
            (28, 25),
            (25, 25),
            (24, 24),
            (24, 10),
        ),
        fill=OUTLINE,
    )
    silhouette_alpha = shield.getchannel("A").tobytes()

    # Cold-steel face.  The left one-pixel highlight also makes the shield's
    # facing direction legible at native resolution.
    shield.putpixel((27, 8), MID_STEEL)
    draw.line((26, 9, 28, 9), fill=DARK_STEEL)
    draw.rectangle((25, 10, 28, 23), fill=DARK_STEEL)
    draw.line((25, 10, 25, 23), fill=PLATE_GRAY)
    draw.line((26, 10, 26, 23), fill=MID_STEEL)
    draw.line((25, 24, 28, 24), fill=DEEP_SHADOW)
    shield.putpixel((26, 25), DARK_STEEL)
    shield.putpixel((27, 25), MID_STEEL)

    # A single-row observation slit leaves steel above, below and on both
    # sides, so the dark slot can no longer visually split the shield in two.
    frame_pixels = shield.load()
    frame_pixels[26, 12] = DEEP_SHADOW
    frame_pixels[27, 12] = PLATE_HIGHLIGHT
    frame_pixels[28, 12] = DEEP_SHADOW

    # Recess the hand into the left shield rim without changing its silhouette.
    # These three pixels keep the grip readable after the shield overlays the
    # arm authored in ``_draw_body_and_arms``.
    frame_pixels[24, 16] = DARK_STEEL
    frame_pixels[24, 17] = JOINT_SHADOW
    frame_pixels[24, 18] = DARK_STEEL

    # Candidate C's thin red-orange energy spine.
    draw.line((27, 15, 27, 22), fill=ACTIVE_RED)
    frame_pixels[27, 15] = HOT_ORANGE
    frame_pixels[27, 22] = HOT_ORANGE
    normalized = _normalize(shield)
    if normalized.getchannel("A").tobytes() != silhouette_alpha:
        raise AssertionError("Shield color detailing changed its alpha mask")
    return normalized


def _build_anchor(operator: Image.Image) -> tuple[Image.Image, Image.Image]:
    frame = _copy_immutable_identity(operator)
    _draw_body_and_arms(frame)
    shield = _build_shield_layer()
    frame.alpha_composite(shield)
    return _normalize(frame), shield


def _immutable_pixel_count_and_check(
    frame: Image.Image,
    operator: Image.Image,
) -> int:
    count = 0
    for y in (*range(0, 15), *range(22, FRAME_SIZE)):
        maximum_x = 21 if y < 15 else FRAME_SIZE
        for x in range(maximum_x):
            source = operator.getpixel((x, y))
            if not source[3]:
                continue
            if frame.getpixel((x, y)) != source:
                raise AssertionError(
                    f"Approved operator identity changed at {(x, y)}"
                )
            count += 1
    return count


def _audit(
    frame: Image.Image,
    shield: Image.Image,
    operator: Image.Image,
    shared_identity_pixels: int,
) -> dict[str, object]:
    bbox = frame.getchannel("A").getbbox()
    if bbox is None:
        raise AssertionError("Shield-bearer anchor is empty")
    width = bbox[2] - bbox[0]
    height = bbox[3] - bbox[1]
    if width > MAX_VISIBLE_SIZE or height > MAX_VISIBLE_SIZE:
        raise AssertionError(
            f"Visible bbox {width}x{height} exceeds {MAX_VISIBLE_SIZE}x{MAX_VISIBLE_SIZE}"
        )
    if bbox[3] != BASELINE_Y:
        raise AssertionError(
            f"Baseline is {bbox[3]}, expected {BASELINE_Y}"
        )

    shield_bbox = shield.getchannel("A").getbbox()
    if shield_bbox != SHIELD_BBOX:
        raise AssertionError(
            f"Shield bbox is {shield_bbox}, expected {SHIELD_BBOX}"
        )
    shield_size = (
        shield_bbox[2] - shield_bbox[0],
        shield_bbox[3] - shield_bbox[1],
    )
    if shield_size != SHIELD_SIZE:
        raise AssertionError(
            f"Shield size is {shield_size}, expected {SHIELD_SIZE}"
        )

    grip = (24, 17)
    grip_neighbors = ((23, 17), (25, 17), (24, 16), (24, 18))
    if frame.getpixel(grip) != JOINT_SHADOW:
        raise AssertionError("Shield grip is not the approved joint-shadow pixel")
    if any(frame.getpixel(point)[3] != 255 for point in grip_neighbors):
        raise AssertionError("Shield grip lost a four-neighbour connection")
    grip_colors = {frame.getpixel(grip)} | {
        frame.getpixel(point) for point in grip_neighbors
    }
    if len(grip_colors) < 3:
        raise AssertionError("Shield grip has insufficient local contrast")

    slit_points = ((26, 12), (27, 12), (28, 12))
    if tuple(frame.getpixel(point) for point in slit_points) != (
        DEEP_SHADOW,
        PLATE_HIGHLIGHT,
        DEEP_SHADOW,
    ):
        raise AssertionError("Observation slit no longer matches the 3x1 contract")
    steel_colors = set(PALETTE[3:8])
    top_steel_pixels = sum(
        1 for x in range(SHIELD_BBOX[0], SHIELD_BBOX[2])
        if frame.getpixel((x, SHIELD_BBOX[1])) in steel_colors
    )
    bottom_steel_pixels = sum(
        1 for x in range(SHIELD_BBOX[0], SHIELD_BBOX[2])
        if frame.getpixel((x, SHIELD_BBOX[3] - 1)) in steel_colors
    )
    if top_steel_pixels < 1 or bottom_steel_pixels < 2:
        raise AssertionError(
            "Shield bevels lack the required non-near-black steel pixels"
        )

    allowed = set(PALETTE) | {TRANSPARENT}
    used = set(frame.getdata())
    unexpected = used - allowed
    if unexpected:
        raise AssertionError(
            f"Anchor contains colors outside the fixed palette: {unexpected}"
        )
    alpha_values = sorted({pixel[3] for pixel in frame.getdata()})
    if alpha_values != [0, 255]:
        raise AssertionError(f"Alpha is not binary: {alpha_values}")
    dirty_transparent = sum(
        1
        for red, green, blue, alpha in frame.getdata()
        if alpha == 0 and (red, green, blue) != (0, 0, 0)
    )
    if dirty_transparent:
        raise AssertionError(
            f"Anchor has {dirty_transparent} dirty transparent pixels"
        )

    immutable_pixels = _immutable_pixel_count_and_check(frame, operator)
    return {
        "canvas": [FRAME_SIZE, FRAME_SIZE],
        "visible_bbox": list(bbox),
        "visible_size": [width, height],
        "baseline": bbox[3],
        "registered_center_x": REGISTERED_CENTER_X,
        "shield_bbox": list(shield_bbox),
        "shield_size": list(shield_size),
        "shield_vertices": 8,
        "shield_alpha_pixels": sum(
            1 for alpha in shield.getchannel("A").getdata() if alpha
        ),
        "shield_alpha_sha256": hashlib.sha256(
            shield.getchannel("A").tobytes()
        ).hexdigest(),
        "grip": {
            "point": list(grip),
            "four_neighbours_opaque": True,
            "local_color_count": len(grip_colors),
        },
        "observation_slit_bbox": [26, 12, 29, 13],
        "observation_slit_size": [3, 1],
        "top_bevel_steel_pixels": top_steel_pixels,
        "bottom_bevel_steel_pixels": bottom_steel_pixels,
        "fixed_palette": True,
        "opaque_palette_colors": len({pixel for pixel in used if pixel[3]}),
        "binary_alpha": True,
        "alpha_values": alpha_values,
        "transparent_rgb_clean": True,
        "immutable_operator_pixels": immutable_pixels,
        "shared_operator_gunner_identity_pixels": shared_identity_pixels,
        "imagegen_pixels_resampled": False,
        "runtime_written": False,
    }


def _review_tile(frame: Image.Image, scale: int) -> Image.Image:
    tile = Image.new("RGBA", frame.size, REVIEW_BACKGROUND)
    tile.alpha_composite(frame)
    return tile.resize(
        (FRAME_SIZE * scale, FRAME_SIZE * scale),
        Image.Resampling.NEAREST,
    )


def _runtime_frame(path: Path) -> Image.Image:
    sheet = Image.open(path).convert("RGBA")
    if sheet.width < FRAME_SIZE or sheet.height < FRAME_SIZE:
        raise ValueError(f"Runtime sheet is too small: {path}")
    return _normalize(sheet.crop((0, 0, FRAME_SIZE, FRAME_SIZE)))


def _write_comparison(anchor: Image.Image) -> None:
    scale = 12
    label_height = 24
    gutter = 12
    references = (
        ("sword", _runtime_frame(SWORD_RUNTIME_PATH)),
        ("gunner", _runtime_frame(GUNNER_RUNTIME_PATH)),
        ("operator", _runtime_frame(OPERATOR_RUNTIME_PATH)),
        ("shield C", anchor),
    )
    tile_size = FRAME_SIZE * scale
    board = Image.new(
        "RGBA",
        (
            len(references) * tile_size + (len(references) - 1) * gutter,
            label_height + tile_size,
        ),
        REVIEW_BACKGROUND,
    )
    draw = ImageDraw.Draw(board)
    for index, (label, frame) in enumerate(references):
        left = index * (tile_size + gutter)
        draw.text((left + 4, 5), label, fill=REVIEW_TEXT)
        board.alpha_composite(_review_tile(frame, scale), (left, label_height))
    board.save(COMPARISON_PATH)


def main() -> None:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    for required in (
        IMAGEGEN_REFERENCE_PATH,
        OPERATOR_ANCHOR_PATH,
        GUNNER_ANCHOR_PATH,
        SWORD_RUNTIME_PATH,
        GUNNER_RUNTIME_PATH,
        OPERATOR_RUNTIME_PATH,
    ):
        if not required.is_file():
            raise FileNotFoundError(required)

    operator, _gunner, shared_identity_pixels = _load_identity_sources()
    anchor, shield = _build_anchor(operator)
    audit = _audit(anchor, shield, operator, shared_identity_pixels)

    anchor.save(OUTPUT_PATH)
    _review_tile(anchor, 16).save(UPSCALED_PATH)
    _write_comparison(anchor)

    report: dict[str, object] = {
        "asset": "combat_robot_shield_bearer_anchor_c",
        "status": "approved_native32_source",
        "imagegen_reference": {
            "path": str(IMAGEGEN_REFERENCE_PATH.relative_to(PROJECT_ROOT)),
            "sha256": _sha256(IMAGEGEN_REFERENCE_PATH),
            "role": "shield_shape_language_only",
        },
        "identity_sources": {
            "operator": str(OPERATOR_ANCHOR_PATH.relative_to(PROJECT_ROOT)),
            "gunner": str(GUNNER_ANCHOR_PATH.relative_to(PROJECT_ROOT)),
            "gunner_shift": [GUNNER_IDENTITY_SHIFT_X, 0],
        },
        "outputs": {
            "native32": str(OUTPUT_PATH.relative_to(PROJECT_ROOT)),
            "preview_16x": str(UPSCALED_PATH.relative_to(PROJECT_ROOT)),
            "comparison": str(COMPARISON_PATH.relative_to(PROJECT_ROOT)),
        },
        "audit": audit,
    }
    REPORT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
