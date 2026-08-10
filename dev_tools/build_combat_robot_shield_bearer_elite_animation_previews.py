#!/usr/bin/env python3
"""Build review-only animation candidates for the elite shield bearer.

ImageGen inputs are locked shape-language references only. Every native frame
is rebuilt from the committed ordinary runtime atlas with explicit integer
pixel tables. This script has no runtime writer and refuses non-dev outputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets/source_images/combat_robot_shield_bearer_elite"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
RUNTIME = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_shield_bearer.png"
ANCHOR = SOURCE_DIR / "combat_robot_shield_bearer_elite_anchor_h1c_approved_native32.png"
ANCHOR_MANIFEST = enemy_asset_report_path("combat_robot_shield_bearer_elite_anchor_manifest.json")
ANIMATION_MANIFEST = enemy_asset_report_path("combat_robot_shield_bearer_elite_animation_manifest.json")

EXPECTED_SHA = {
    RUNTIME: "07e5996a7048f4a469e247ee4aa7ce3c9f9c54a829d6a839ff3c94b2cac72ab4",
    ANCHOR: "6101e6b68fa442f2294c90a052f3e000cac0dff0076714e160853547d1bb9fb5",
    ANCHOR_MANIFEST: "2bfe36029ac758098f1cf38af878afed5599ad00d1a45d6afd06c34b3b68e409",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_move_m1_imagegen.png": "045a23194c1d45b84ab86bb3bf25823d87652bc8d80eb6bee750b23e70b944db",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_move_m2_imagegen.png": "e46d1621f47461f1cbe9f0db9606b0a08ff5e04a9860c595ba52d08a2b1f20de",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_shield_states_r1_imagegen.png": "5b876f903086b4b52e3ff5df639a420cbd293b99f327c4ef7591a00a113c6937",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_shield_states_r2_imagegen.png": "44b55dc629068090e38de89f75359d9747cb74eb076868d2f9d37ac6c6126242",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_death_d1_imagegen.png": "68d288c75a92b1677b6ee90bddf6dae22834da6294898fb6eaf53267e2bdeb3b",
    SOURCE_DIR / "combat_robot_shield_bearer_elite_death_d2_imagegen.png": "359d78c41d426a39671916e4447ce205d88a6e0dc7f36dce05c3c879de162374",
}

FRAME = 32
TRANSPARENT = (0, 0, 0, 0)
OPAQUE_BLACK = (0, 0, 0, 255)
BACKGROUND = (13, 19, 31, 255)
STEEL = (
    (21, 22, 19, 255),
    (29, 28, 30, 255),
    (55, 59, 63, 255),
    (82, 88, 94, 255),
    (112, 121, 128, 255),
    (151, 159, 164, 255),
    (190, 196, 198, 255),
    (226, 229, 226, 255),
)
PURPLE = (
    (42, 21, 60, 255),
    (74, 36, 105, 255),
    (115, 84, 134, 255),
    (125, 54, 179, 255),
    (157, 78, 221, 255),
    (197, 138, 255, 255),
)
ACCENT_MAP = {
    (102, 25, 20, 255): PURPLE[1],
    (190, 48, 31, 255): PURPLE[4],
    (239, 92, 34, 255): PURPLE[5],
}
OLD_ACCENTS = frozenset(ACCENT_MAP)
ALLOWED = frozenset((*STEEL, *PURPLE, TRANSPARENT, OPAQUE_BLACK))
O, D, M, G = STEEL[0], STEEL[1], STEEL[4], STEEL[5]

COMMON_A1 = {
    (10, 8): O,
    (21, 8): O,
    (9, 12): O,
    (10, 12): M,
    (21, 12): M,
    (22, 12): O,
    (9, 13): O,
    (22, 13): O,
}
STANDING_CAP = {(26, 15): G, (28, 15): D, (26, 22): G, (28, 22): D}
SHIELD_BOX = (24, 8, 30, 26)
OBSERVATION = ((26, 12), (27, 12), (28, 12))
GRIP = ((24, 16), (24, 17), (24, 18))

DEATH_BODY = (
    {(10, 8): O, (21, 8): O, (9, 12): O, (10, 12): M, (21, 12): M, (22, 12): O, (9, 13): O, (22, 13): O},
    {(10, 8): O, (20, 8): O, (10, 11): O, (10, 12): M, (20, 12): M, (20, 11): O, (9, 13): O, (20, 13): O},
    {(7, 9): O, (17, 8): O, (8, 12): O, (9, 13): M, (18, 11): M, (19, 12): O, (8, 14): O, (19, 13): O},
    {(8, 9): O, (17, 6): O, (8, 13): O, (8, 12): M, (18, 10): M, (18, 9): O, (7, 14): O, (18, 11): O},
    {(6, 11): O, (15, 6): O, (7, 15): O, (8, 14): M, (17, 10): M, (17, 9): O, (8, 16): O, (18, 11): O},
    {(6, 13): O, (13, 6): O, (9, 17): O, (9, 16): M, (15, 8): M, (16, 9): O, (9, 18): O, (17, 10): O},
    {(7, 19): O, (12, 10): O, (11, 21): O, (11, 20): M, (14, 11): M, (13, 10): O, (12, 22): O, (15, 11): O},
    {(8, 24): O, (9, 13): O, (12, 25): O, (11, 25): M, (12, 14): M, (11, 12): O, (13, 25): O, (12, 12): O},
)
DEATH_CAP = (
    {(26, 15): G, (28, 15): D, (26, 22): G, (28, 22): D},
    {(26, 15): G, (28, 15): D, (26, 22): G, (28, 22): D},
    {(24, 14): G, (26, 14): D, (24, 21): G, (26, 21): D},
    {(26, 14): G, (28, 14): D, (26, 21): G, (28, 21): D},
    {(23, 15): G, (25, 15): D, (27, 22): G, (29, 22): D},
    {(21, 16): G, (21, 18): D, (25, 22): G, (27, 22): D},
    {(19, 17): G, (21, 17): D, (24, 22): G, (26, 22): D},
    {(17, 20): G, (17, 22): D, (23, 22): G, (23, 24): D},
)
DEATH_D2_VISIBLE = (
    frozenset(DEATH_BODY[0]),
    frozenset(DEATH_BODY[1]),
    frozenset(DEATH_BODY[2]),
    frozenset(DEATH_BODY[3]),
    frozenset({(6, 11), (15, 6), (7, 15), (8, 14), (17, 9), (18, 11)}),
    frozenset({(6, 13), (13, 6), (9, 16), (17, 10)}),
    frozenset({(7, 19), (12, 10)}),
    frozenset(),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def assert_dev(path: Path) -> None:
    resolved = path.resolve()
    dev = (ROOT / "dev_assets").resolve()
    if resolved != dev and dev not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Preview builder refused non-dev output: {path}")


def verify_inputs() -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for path, expected in EXPECTED_SHA.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Input SHA drifted: {rel(path)} {actual}")
        records[rel(path)] = {"sha256": actual, "locked": True}
    anchor_manifest = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    if anchor_manifest.get("approved_selection") != "h1c":
        raise AssertionError("H1C is not the certified first-gate selection")
    with Image.open(ANCHOR) as image:
        if rgba_sha(image) != "c838576b0d2c321190ee08a936b8d1feea3685fd9645f12b6ad506cf18922e4c":
            raise AssertionError("Approved H1C RGBA drifted")
    return records


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        nargs=3,
        metavar=("MOVE", "SHIELD", "DEATH"),
        help="Record the user's second-gate choice, for example: m1 r1 d1.",
    )
    return parser.parse_args()


def resolve_selection(requested: list[str] | None) -> dict[str, str] | None:
    if requested is not None:
        move, shield, death = (value.lower() for value in requested)
        selection = {"move": move, "shield_states": shield, "death": death}
    elif ANIMATION_MANIFEST.is_file():
        existing = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
        selection = existing.get("approved_animation_selection")
    else:
        selection = None
    if selection is None:
        return None
    expected = {
        "move": {"m1", "m2"},
        "shield_states": {"r1", "r2"},
        "death": {"d1", "d2"},
    }
    if set(selection) != set(expected):
        raise AssertionError(f"Malformed preserved animation selection: {selection}")
    normalized = {key: str(selection[key]).lower() for key in expected}
    for key, choices in expected.items():
        if normalized[key] not in choices:
            raise AssertionError(f"Invalid {key} selection: {normalized[key]}")
    return normalized


def frames_from_runtime(row: int) -> list[Image.Image]:
    with Image.open(RUNTIME) as source:
        sheet = source.convert("RGBA")
    return [sheet.crop((i * FRAME, row * FRAME, (i + 1) * FRAME, (row + 1) * FRAME)) for i in range(8)]


def alpha_points(image: Image.Image) -> set[tuple[int, int]]:
    return {(x, y) for y in range(image.height) for x in range(image.width) if image.getpixel((x, y))[3]}


def bbox(image: Image.Image) -> tuple[int, int, int, int]:
    result = image.getchannel("A").getbbox()
    if result is None:
        raise AssertionError("Empty frame")
    return result


def map_accents(frame: Image.Image) -> Image.Image:
    result = frame.copy()
    for y in range(FRAME):
        for x in range(FRAME):
            replacement = ACCENT_MAP.get(result.getpixel((x, y)))
            if replacement is not None:
                result.putpixel((x, y), replacement)
    return result


def put_added(frame: Image.Image, base: Image.Image, points: dict[tuple[int, int], tuple[int, int, int, int]], label: str) -> None:
    for point, color in points.items():
        if base.getpixel(point) != TRANSPARENT:
            raise AssertionError(f"{label}: authored add point is not transparent: {point}")
        frame.putpixel(point, color)


def recolor_existing(frame: Image.Image, base: Image.Image, points: dict[tuple[int, int], tuple[int, int, int, int]], label: str) -> None:
    for point, color in points.items():
        if base.getpixel(point)[3] == 0:
            raise AssertionError(f"{label}: recolor point lost base Alpha: {point}")
        frame.putpixel(point, color)


def build_move(option: str) -> list[Image.Image]:
    ordinary = frames_from_runtime(0)
    result: list[Image.Image] = []
    for index, base in enumerate(ordinary):
        frame = map_accents(base)
        additions = dict(COMMON_A1)
        if option == "m2":
            additions[(10, 12)] = G if index < 4 else M
            additions[(21, 12)] = M if index < 4 else G
        put_added(frame, base, additions, f"{option}[{index}]")
        recolor_existing(frame, base, STANDING_CAP, f"{option}[{index}]")
        audit_frame(frame, f"{option}[{index}]")
        if alpha_points(frame) - alpha_points(base) != set(COMMON_A1):
            raise AssertionError(f"{option}[{index}]: move Alpha additions drifted")
        if base.crop((0, 22, 24, 32)).tobytes() != frame.crop((0, 22, 24, 32)).tobytes():
            raise AssertionError(f"{option}[{index}]: ordinary leg pixels changed")
        result.append(frame)
    return result


def darken(color: tuple[int, int, int, int], steps: int) -> tuple[int, int, int, int]:
    if color not in STEEL or color in (STEEL[0], STEEL[1]):
        return color
    index = STEEL.index(color)
    return STEEL[max(2, index - steps)]


def apply_r2_damage(frame: Image.Image, base: Image.Image, state: int) -> None:
    if state == 0 or state == 3:
        return
    for y in range(8, 26):
        for x in range(25, 30):
            point = (x, y)
            if point in OBSERVATION or point in GRIP:
                continue
            color = frame.getpixel(point)
            steps = 0
            if state == 1 and y >= 19:
                steps = 1
            elif state == 2:
                steps = 1 if y < 19 else 2
            if steps:
                frame.putpixel(point, darken(color, steps))
    separator_rows = (18,) if state == 1 else (18, 21)
    for y in separator_rows:
        for x in (26, 27, 28):
            if base.getpixel((x, y))[3] and (x, y) not in GRIP:
                frame.putpixel((x, y), D)


def build_states(option: str) -> list[Image.Image]:
    result: list[Image.Image] = []
    for state in range(4):
        base = frames_from_runtime(state)[0]
        frame = map_accents(base)
        if option == "r2":
            apply_r2_damage(frame, base, state)
        put_added(frame, base, COMMON_A1, f"{option}[{state}]")
        if state < 3:
            recolor_existing(frame, base, STANDING_CAP, f"{option}[{state}]")
        for point in (*OBSERVATION, *GRIP):
            if frame.getpixel(point) != base.getpixel(point):
                raise AssertionError(f"{option}[{state}]: protected shield point changed: {point}")
        if state < 3:
            if frame.crop(SHIELD_BOX).getchannel("A").tobytes() != base.crop(SHIELD_BOX).getchannel("A").tobytes():
                raise AssertionError(f"{option}[{state}]: shield Alpha changed")
        audit_frame(frame, f"{option}[{state}]")
        result.append(frame)
    return result


def added_components_touch_base(additions: set[tuple[int, int]], base: set[tuple[int, int]]) -> bool:
    remaining = set(additions)
    while remaining:
        component = {remaining.pop()}
        stack = list(component)
        while stack:
            x, y = stack.pop()
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                point = (x + dx, y + dy)
                if point in remaining:
                    remaining.remove(point)
                    component.add(point)
                    stack.append(point)
        if not any(
            (x + dx, y + dy) in base
            for x, y in component
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
        ):
            return False
    return True


def components8(points: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    remaining = set(points)
    components: list[set[tuple[int, int]]] = []
    while remaining:
        component = {remaining.pop()}
        stack = list(component)
        while stack:
            x, y = stack.pop()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    point = (x + dx, y + dy)
                    if point in remaining:
                        remaining.remove(point)
                        component.add(point)
                        stack.append(point)
        components.append(component)
    return sorted(components, key=len, reverse=True)


def build_death(option: str) -> list[Image.Image]:
    ordinary = frames_from_runtime(4)
    result: list[Image.Image] = []
    for index, base in enumerate(ordinary):
        frame = map_accents(base)
        visible = set(DEATH_BODY[index]) if option == "d1" else set(DEATH_D2_VISIBLE[index])
        additions = {point: DEATH_BODY[index][point] for point in visible}
        put_added(frame, base, additions, f"{option}[{index}]")
        recolor_existing(frame, base, DEATH_CAP[index], f"{option}[{index}]")
        if not added_components_touch_base(set(additions), alpha_points(base)):
            raise AssertionError(f"{option}[{index}]: authored attachment does not chain to ordinary body")
        if alpha_points(frame) - alpha_points(base) != set(additions):
            raise AssertionError(f"{option}[{index}]: explicit added Alpha set drifted")
        if alpha_points(base) - alpha_points(frame):
            raise AssertionError(f"{option}[{index}]: ordinary Alpha was deleted")
        candidate_components = components8(alpha_points(frame))
        dominant = candidate_components[0]
        if not set(additions) <= dominant or not set(DEATH_CAP[index]) <= dominant:
            raise AssertionError(f"{option}[{index}]: H1C reinforcement left the body/shield component")
        ordinary_components = components8(alpha_points(base))
        for component in ordinary_components[1:]:
            if any(frame.getpixel(point) != base.getpixel(point) for point in component):
                raise AssertionError(f"{option}[{index}]: ordinary detached death detail changed")
        audit_frame(frame, f"{option}[{index}]")
        result.append(frame)
    return result


def audit_frame(frame: Image.Image, label: str) -> None:
    box = bbox(frame)
    if box[2] - box[0] > 28 or box[3] - box[1] > 28 or box[3] != 28:
        raise AssertionError(f"{label}: bbox/baseline contract failed: {box}")
    colors = set(frame.getdata())
    if not colors <= ALLOWED:
        raise AssertionError(f"{label}: palette drift: {colors - ALLOWED}")
    if colors & OLD_ACCENTS:
        raise AssertionError(f"{label}: red/orange remains")
    for pixel in frame.getdata():
        if pixel[3] not in (0, 255):
            raise AssertionError(f"{label}: non-binary Alpha")
        if pixel[3] == 0 and pixel[:3] != (0, 0, 0):
            raise AssertionError(f"{label}: dirty transparent RGB")


def build_all() -> dict[str, list[Image.Image]]:
    built = {
        "m1": build_move("m1"),
        "m2": build_move("m2"),
        "r1": build_states("r1"),
        "r2": build_states("r2"),
        "d1": build_death("d1"),
        "d2": build_death("d2"),
    }
    if built["d1"][0].tobytes() != built["m1"][0].tobytes():
        # Ordinary death starts from a neutral leg phase, so only the approved
        # H1C reinforcement layer is required to match, not the entire frame.
        for point in (*COMMON_A1, *STANDING_CAP):
            if built["d1"][0].getpixel(point) != built["m1"][0].getpixel(point):
                raise AssertionError("Death frame0 H1C reinforcement flickers")
    if any(built["d1"][i].tobytes() != built["d2"][i].tobytes() for i in range(4)):
        raise AssertionError("D1/D2 first four frames must be identical")
    if [len(points) + 4 for points in DEATH_D2_VISIBLE[4:]] != [10, 8, 6, 4]:
        raise AssertionError("D2 occlusion counts drifted")
    return built


def make_strip(frames: list[Image.Image]) -> Image.Image:
    strip = Image.new("RGBA", (len(frames) * FRAME, FRAME), TRANSPARENT)
    for index, frame in enumerate(frames):
        strip.alpha_composite(frame, (index * FRAME, 0))
    return strip


def composite(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, BACKGROUND)
    result.alpha_composite(image)
    return result.convert("RGB")


def scaled(image: Image.Image, factor: int) -> Image.Image:
    return composite(image).resize((image.width * factor, image.height * factor), Image.Resampling.NEAREST)


def save_png(image: Image.Image, path: Path) -> None:
    assert_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def gif_palette() -> tuple[list[int], dict[tuple[int, int, int], int]]:
    colors: list[tuple[int, int, int]] = []
    for color in (BACKGROUND, OPAQUE_BLACK, *STEEL, *PURPLE):
        rgb = color[:3]
        if rgb not in colors:
            colors.append(rgb)
    palette = [channel for color in colors for channel in color]
    palette += [0] * (768 - len(palette))
    return palette, {color: index for index, color in enumerate(colors)}


def indexed_exact(image: Image.Image) -> Image.Image:
    palette, index = gif_palette()
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    result.putpalette(palette)
    result.putdata([index[pixel] for pixel in rgb.getdata()])
    return result


def save_gif(frames: list[Image.Image], path: Path, duration_ms: int, mirrored: bool) -> None:
    assert_dev(path)
    prepared: list[Image.Image] = []
    expected: list[Image.Image] = []
    for frame in frames:
        source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
        review = scaled(source, 16)
        expected.append(review)
        prepared.append(indexed_exact(review))
    path.parent.mkdir(parents=True, exist_ok=True)
    prepared[0].save(
        path,
        save_all=True,
        append_images=prepared[1:],
        duration=[duration_ms] * len(prepared),
        loop=0,
        optimize=False,
        disposal=2,
    )
    with Image.open(path) as decoded:
        if decoded.n_frames != len(expected):
            raise AssertionError(f"GIF frame count drifted: {path}")
        for index, wanted in enumerate(expected):
            decoded.seek(index)
            if decoded.convert("RGB").tobytes() != wanted.tobytes():
                raise AssertionError(f"GIF palette damaged frame {index}: {path}")


def delta_strip(frames: list[Image.Image], ordinary: list[Image.Image]) -> Image.Image:
    result = Image.new("RGBA", (len(frames) * FRAME, FRAME), TRANSPARENT)
    for index, (frame, base) in enumerate(zip(frames, ordinary)):
        for y in range(FRAME):
            for x in range(FRAME):
                before, after = base.getpixel((x, y)), frame.getpixel((x, y))
                if before == after:
                    continue
                if before[3] == 0 and after[3]:
                    color = (86, 224, 255, 255)
                elif before in OLD_ACCENTS:
                    color = (197, 138, 255, 255)
                else:
                    color = (255, 210, 80, 255)
                result.putpixel((index * FRAME + x, y), color)
    return result


def file_record(path: Path) -> dict[str, object]:
    with Image.open(path) as image:
        return {"path": rel(path), "sha256": sha256(path), "size": list(image.size), "mode": image.mode}


def write_outputs(built: dict[str, list[Image.Image]]) -> dict[str, object]:
    outputs: dict[str, object] = {}
    ordinary = {
        "m1": frames_from_runtime(0),
        "m2": frames_from_runtime(0),
        "r1": [frames_from_runtime(row)[0] for row in range(4)],
        "r2": [frames_from_runtime(row)[0] for row in range(4)],
        "d1": frames_from_runtime(4),
        "d2": frames_from_runtime(4),
    }
    durations = {"m1": 70, "m2": 70, "r1": 650, "r2": 650, "d1": 80, "d2": 80}
    long_names = {
        "m1": "move_m1",
        "m2": "move_m2",
        "r1": "shield_states_r1",
        "r2": "shield_states_r2",
        "d1": "death_d1",
        "d2": "death_d2",
    }
    for key, frames in built.items():
        name = long_names[key]
        native = SOURCE_DIR / f"combat_robot_shield_bearer_elite_{name}_candidate_native.png"
        preview = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{name}_candidate_8x.png"
        delta = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{name}_ordinary_delta_8x.png"
        gif = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{name}_candidate.gif"
        mirror = PREVIEW_DIR / f"combat_robot_shield_bearer_elite_{name}_candidate_mirrored.gif"
        strip = make_strip(frames)
        save_png(strip, native)
        save_png(scaled(strip, 8), preview)
        save_png(scaled(delta_strip(frames, ordinary[key]), 8), delta)
        save_gif(frames, gif, durations[key], False)
        save_gif(frames, mirror, durations[key], True)
        outputs[key] = {
            "native": file_record(native),
            "preview_8x": file_record(preview),
            "ordinary_delta_8x": file_record(delta),
            "gif": file_record(gif),
            "mirrored_gif": file_record(mirror),
            "frame_rgba_sha256": [rgba_sha(frame) for frame in frames],
            "runtime_fps": 14 if key.startswith("m") else (12 if key.startswith("d") else None),
            "review_frame_duration_ms": durations[key],
        }
    return outputs


def write_json(path: Path, payload: object) -> None:
    assert_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def frame_metrics(frames: list[Image.Image]) -> list[dict[str, object]]:
    return [
        {
            "rgba_sha256": rgba_sha(frame),
            "bbox": list(bbox(frame)),
            "opaque_pixels": len(alpha_points(frame)),
        }
        for frame in frames
    ]


def main() -> None:
    args = parse_args()
    selection = resolve_selection(args.approve)
    input_records = verify_inputs()
    first = build_all()
    second = build_all()
    for key in first:
        if any(a.tobytes() != b.tobytes() for a, b in zip(first[key], second[key])):
            raise AssertionError(f"{key}: in-memory deterministic rebuild drifted")
    outputs = write_outputs(first)
    stage = (
        "animation_approved_pending_fx_candidates"
        if selection is not None
        else "animation_candidates_pending_second_human_gate"
    )
    selected_outputs = None
    if selection is not None:
        selected_outputs = {
            "move": outputs[selection["move"]],
            "shield_states": outputs[selection["shield_states"]],
            "death": outputs[selection["death"]],
        }
    stability = {
        "asset": "combat_robot_shield_bearer_elite_animation_candidates",
        "stage": stage,
        "approved_anchor": "h1c",
        "approved_selection": selection,
        "runtime_written": False,
        "frame_metrics": {key: frame_metrics(frames) for key, frames in first.items()},
        "move": {
            "m1_reinforcement_states": 1,
            "m2_reinforcement_states": 2,
            "eight_leg_phases_inherited": True,
        },
        "shield_states": {
            "state_order": ["intact", "cracked", "critical", "broken"],
            "r1": "紫能纵脊分叉裂损",
            "r2": "三段盾面暗化与横向断损",
            "unbroken_shield_alpha_inherited": True,
        },
        "death": {
            "construction": "eight explicit integer point/color tables; no geometric inference",
            "d1_added_counts": [len(points) + 4 for points in DEATH_BODY],
            "d2_added_or_recolored_counts": [len(points) + 4 for points in DEATH_D2_VISIBLE],
            "d2_first_four_equal_d1": True,
            "d2_late_counts": [10, 8, 6, 4],
            "body_tables": [
                [{"point": list(point), "rgba": list(color)} for point, color in sorted(table.items())]
                for table in DEATH_BODY
            ],
            "cap_tables": [
                [{"point": list(point), "rgba": list(color)} for point, color in sorted(table.items())]
                for table in DEATH_CAP
            ],
            "d2_visible_points": [[list(point) for point in sorted(points)] for points in DEATH_D2_VISIBLE],
        },
    }
    stability_path = enemy_asset_report_path("combat_robot_shield_bearer_elite_animation_stability_report.json")
    write_json(stability_path, stability)
    report = {
        "asset": "combat_robot_shield_bearer_elite_animation_candidates",
        "stage": stage,
        "preview_only": True,
        "approved_anchor": {"selection": "h1c", "path": rel(ANCHOR), "sha256": sha256(ANCHOR)},
        "approved_selection": selection,
        "approved_outputs": selected_outputs,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "builder": {"path": rel(SCRIPT), "sha256": sha256(SCRIPT)},
        "input_locks": input_records,
        "outputs": outputs,
        "stability_report": rel(stability_path),
        "stability_report_sha256": sha256(stability_path),
        "checks": {
            "runtime_source_sha_locked": True,
            "ordinary_pixels_inherited_outside_explicit_whitelists": True,
            "death_uses_explicit_tables_only": True,
            "death_reinforcement_remains_on_dominant_body_shield_component": True,
            "ordinary_detached_death_details_byte_inherited": True,
            "no_runtime_rotation_or_inference": True,
            "binary_alpha": True,
            "transparent_rgb_zero": True,
            "fixed_palette": True,
            "old_red_orange_remaining": 0,
            "maximum_visible_28x28": True,
            "baseline_y_28": True,
            "gif_decodes_exactly_to_native_nearest_neighbor": True,
            "deterministic_in_memory_rebuild": True,
        },
    }
    report_path = enemy_asset_report_path("combat_robot_shield_bearer_elite_animation_preview_report.json")
    write_json(report_path, report)
    manifest = {
        "asset": "combat_robot_shield_bearer_elite",
        "stage": stage,
        "approved_anchor": "h1c",
        "approved_animation_selection": selection,
        "approved_outputs": selected_outputs,
        "final_human_approved": False,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "candidate_order": ["m1", "m2", "r1", "r2", "d1", "d2"],
        "report": rel(report_path),
        "report_sha256": sha256(report_path),
        "stability_report": rel(stability_path),
        "stability_report_sha256": sha256(stability_path),
    }
    write_json(ANIMATION_MANIFEST, manifest)
    print("COMBAT_ROBOT_SHIELD_BEARER_ELITE_ANIMATION_PREVIEWS_OK")
    print(f"report={rel(report_path)}")
    print(f"approved={selection}")
    print(f"manifest={rel(ANIMATION_MANIFEST)}")


if __name__ == "__main__":
    main()
