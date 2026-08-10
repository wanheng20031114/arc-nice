#!/usr/bin/env python3
"""Build review-only animation candidates for the elite combat robot ninja.

ImageGen files are locked structure-language references only. Native pixels are
rebuilt deterministically from the ordinary runtime atlas plus explicit integer
point/color tables. This script refuses every output outside ``dev_assets``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageDraw, ImageFont

from pixel_crop_tool import crop_to_square
from pixel_grid_analyzer import analyze_image
from process_combat_robot_assets import normalize_source


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
SOURCE_DIR = ROOT / "dev_assets/source_images/combat_robot_ninja_elite"
PREVIEW_DIR = ROOT / "dev_assets/generated_previews"
RUNTIME = ROOT / "resources/texture/enemy/mechanical_life/combat_robot_ninja.png"
ANCHOR = SOURCE_DIR / "combat_robot_ninja_elite_anchor_n1c_approved_native40.png"
ANCHOR_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_anchor_manifest.json")
ANIMATION_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_animation_manifest.json")

FRAME = 40
FRAMES = 8
TRANSPARENT = (0, 0, 0, 0)
BACKGROUND = (13, 19, 31, 255)
OUTLINE = (21, 22, 19, 255)
DEEP_SHADOW = (29, 28, 30, 255)
DARK_STEEL = (55, 59, 63, 255)
MID_STEEL = (82, 88, 94, 255)
PLATE_GRAY = (112, 121, 128, 255)
PLATE_HIGHLIGHT = (151, 159, 164, 255)
PALE_STEEL = (190, 196, 198, 255)
WHITE_STEEL = (226, 229, 226, 255)
STEEL = (OUTLINE, DEEP_SHADOW, DARK_STEEL, MID_STEEL, PLATE_GRAY, PLATE_HIGHLIGHT, PALE_STEEL, WHITE_STEEL)
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
ALLOWED = frozenset((*STEEL, *PURPLE, TRANSPARENT))

EXPECTED_SHA = {
    RUNTIME: "f34f15083e48af0179c1d2669a3d22bdfdb33de266d9373cbaa9defa2b434ceb",
    ANCHOR: "5aac848b278fe6f9f0d495649df4d64977856a92de875b7a3989515bcd6a1938",
    ANCHOR_MANIFEST: "11df368a76d4025aedc6c823bf3e4dfcfc06b59acc25a9427dff82b42b13162e",
    SOURCE_DIR / "combat_robot_ninja_elite_move_m1_imagegen.png": "dcb7a3e0c9d9beac46520724c48c82ed1f5d3d9704fbe41f3b51010893a923c5",
    SOURCE_DIR / "combat_robot_ninja_elite_move_m2_imagegen.png": "8d43abe25b494698ba42dde013c82ba5d5ba4c6d1196a01766f2a8045b5f78d5",
    SOURCE_DIR / "combat_robot_ninja_elite_boost_s1_imagegen.png": "9bde812b080404136e004f6687b63f783a4d8dea2e32549f7bf5a4d54c3a62b2",
    SOURCE_DIR / "combat_robot_ninja_elite_boost_s2_imagegen.png": "58780599094efccd3025d7883e2b75623a8f6e4d981f4d1fb1c089db0100cb10",
    SOURCE_DIR / "combat_robot_ninja_elite_death_d1_imagegen.png": "e7faf151352f36c3575308c35b4dc6e8747907f28c9e5620bfb594604d185941",
    SOURCE_DIR / "combat_robot_ninja_elite_death_d2_imagegen.png": "9b4e6af9ac88ede05501af5b5a0441402e0eec88bd099ff44109a2817385a7cc",
}
EXPECTED_ANCHOR_RGBA_SHA = "bb92517804d95c01719efb3bb27a952a3235c64e6e492c56273fd8492ab4ad42"

COMMON_A1 = {
    (14, 12): OUTLINE, (25, 12): OUTLINE,
    (13, 16): OUTLINE, (14, 16): MID_STEEL,
    (25, 16): MID_STEEL, (26, 16): OUTLINE,
    (13, 17): OUTLINE, (26, 17): OUTLINE,
}
MOVE_WRISTS = {
    (25, 20): PLATE_GRAY, (25, 22): MID_STEEL,
    (14, 24): MID_STEEL, (13, 25): PLATE_GRAY,
}
BOOST_WRISTS = {
    (12, 18): MID_STEEL, (11, 19): PLATE_GRAY,
    (12, 24): MID_STEEL, (13, 24): PLATE_GRAY,
}
GUARD_PHASE = (PURPLE[2], PURPLE[3], PURPLE[4], PURPLE[5], PURPLE[5], PURPLE[4], PURPLE[3], PURPLE[2])
HAND_PHASE = (PURPLE[1], PURPLE[2], PURPLE[3], PURPLE[4], PURPLE[4], PURPLE[3], PURPLE[2], PURPLE[1])

O, I, P = OUTLINE, MID_STEEL, PLATE_GRAY
DEATH_D1_POINT_TABLES = (
    {(14,12):O,(25,12):O,(13,16):O,(14,16):I,(25,16):I,(26,16):O,(13,17):O,(26,17):O,(25,20):P,(25,22):I,(14,24):I,(13,25):P},
    {(15,12):O,(26,14):O,(13,16):O,(14,16):I,(13,17):O,(25,18):I,(26,18):O,(26,19):O,(26,20):P,(26,23):I,(13,23):I,(13,25):P},
    {(17,12):O,(15,15):O,(16,15):I,(28,15):O,(15,16):O,(27,19):I,(28,19):O,(28,20):O,(26,22):P,(25,24):I,(14,25):I,(13,26):P},
    {(18,13):O,(16,16):O,(15,17):O,(16,17):O,(17,17):I,(28,18):O,(27,21):I,(27,22):O,(28,22):O,(27,23):O,(26,23):P,(25,25):I,(14,25):I,(14,27):P},
    {(19,13):O,(16,16):O,(17,16):I,(26,22):I,(27,22):I,(27,23):O,(26,26):P,(26,28):I,(16,28):I,(15,29):P},
    {(21,13):O,(17,16):O,(18,16):I,(29,21):O,(26,24):I,(26,25):O,(25,26):P,(25,28):I,(16,29):I,(15,30):P},
    {(19,15):O,(23,15):O,(18,16):O,(19,16):O,(20,16):I,(28,24):O,(28,25):O,(24,26):I,(25,26):P,(25,27):I,(15,30):I,(14,30):P},
    {(19,17):O,(20,17):O,(20,18):I,(24,18):O,(20,29):I,(19,30):O,(20,30):O,(24,31):P,(25,31):I,(15,31):I,(16,31):P},
)
DEATH_D2_POINT_TABLES = (
    DEATH_D1_POINT_TABLES[0], DEATH_D1_POINT_TABLES[1],
    DEATH_D1_POINT_TABLES[2], DEATH_D1_POINT_TABLES[3],
    {(19,13):O,(26,22):I,(27,22):I,(27,23):O,(26,26):P,(26,28):I,(16,28):I,(15,29):P},
    {(29,21):O,(26,24):I,(25,26):P,(25,28):I,(16,29):I,(15,30):P},
    {(25,26):P,(25,27):I,(15,30):I,(14,30):P},
    {(24,31):P,(16,31):P},
)

SPECS = {
    "m1": {"row": 0, "name": "move_m1", "fps": 20, "title": "M1 腕锁环全程刚性稳定", "summary": "N1C腕锁结构保持冷灰固定，严格继承普通M1八腿相和双刃轨迹。"},
    "m2": {"row": 0, "name": "move_m2", "fps": 20, "title": "M2 承重高光受控换相", "summary": "Alpha不变，仅前后腕锁内部冷灰高光按2帧一组交替承重。"},
    "s1": {"row": 1, "name": "boost_s1", "fps": 24, "title": "S1 双刀柄紫能同相", "summary": "双反手后掠疾跑中，两组既有刀柄功能点同步亮起并回落。"},
    "s2": {"row": 1, "name": "boost_s2", "fps": 24, "title": "S2 双刀柄紫能反相", "summary": "仅既有刀柄功能点前后错开四帧脉冲，不增加Alpha或尾迹。"},
    "d1": {"row": 2, "name": "death_d1", "fps": 12, "title": "D1 强化件与双刃全程外露连接", "summary": "A1/N1C强化件随普通C/D1前折轨迹倒下，八帧保持外露并连接。"},
    "d2": {"row": 2, "name": "death_d2", "fps": 12, "title": "D2 后半段强化件逐步被机体遮挡", "summary": "前四帧同D1，后四帧强化像素按8/6/4/2递减且无碎片脱落。"},
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def ensure_dev(path: Path) -> None:
    resolved = path.resolve()
    dev = (ROOT / "dev_assets").resolve()
    if resolved != dev and dev not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Refused non-dev output: {path}")


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def write_json(path: Path, payload: object) -> None:
    ensure_dev(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")


def verify_inputs() -> dict[str, dict[str, object]]:
    records = {}
    for path, expected in EXPECTED_SHA.items():
        if not path.is_file():
            raise FileNotFoundError(path)
        actual = sha256(path)
        if actual != expected:
            raise AssertionError(f"Input SHA drifted: {rel(path)} expected={expected} actual={actual}")
        records[rel(path)] = {"sha256": actual, "locked": True}
    with Image.open(ANCHOR) as image:
        if image.size != (FRAME, FRAME) or rgba_sha(image) != EXPECTED_ANCHOR_RGBA_SHA:
            raise AssertionError("Approved N1C decoded RGBA drifted")
    anchor_manifest = json.loads(ANCHOR_MANIFEST.read_text(encoding="utf-8"))
    if anchor_manifest.get("approved_selection", "").lower() != "n1c" or not anchor_manifest.get("first_human_approved"):
        raise AssertionError("N1C is not the certified first-gate anchor")
    if anchor_manifest.get("runtime_written") is not False:
        raise AssertionError("Anchor manifest unexpectedly claims runtime output")
    return records


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--approve",
        nargs=3,
        metavar=("MOVE", "BOOST", "DEATH"),
        help="Record the second-gate choice, for example: --approve m1 s2 d1.",
    )
    return parser.parse_args()


def read_existing_manifest() -> dict[str, object] | None:
    if not ANIMATION_MANIFEST.is_file():
        return None
    value = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AssertionError("Existing animation manifest must be a JSON object")
    return value


def validate_selection(value: object) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"move", "boost", "death"}:
        raise AssertionError(f"Malformed animation selection: {value}")
    selection = {key: str(value[key]).lower() for key in ("move", "boost", "death")}
    allowed = {"move": {"m1", "m2"}, "boost": {"s1", "s2"}, "death": {"d1", "d2"}}
    for key, choices in allowed.items():
        if selection[key] not in choices:
            raise AssertionError(f"Invalid {key} candidate {selection[key]!r}; allowed={sorted(choices)}")
    return selection


def resolve_selection(
    requested: list[str] | None,
    existing: dict[str, object] | None,
) -> tuple[dict[str, str] | None, dict[str, object] | None]:
    preserved_locks = None
    existing_selection = None
    if existing is not None:
        existing_selection = validate_selection(existing.get("approved_animation_selection"))
    if requested is None:
        selection = existing_selection
        if selection is not None and existing is not None:
            locks = existing.get("approved_native_locks")
            if not isinstance(locks, dict):
                raise AssertionError("Approved selection exists without approved_native_locks")
            preserved_locks = locks
        return selection, preserved_locks
    selection = validate_selection({"move": requested[0], "boost": requested[1], "death": requested[2]})
    if selection == existing_selection and existing is not None:
        locks = existing.get("approved_native_locks")
        if locks is not None and not isinstance(locks, dict):
            raise AssertionError("Existing approved_native_locks must be a JSON object")
        preserved_locks = locks
    return selection, preserved_locks


def runtime_rows() -> list[list[Image.Image]]:
    with Image.open(RUNTIME) as image:
        sheet = image.convert("RGBA")
    if sheet.size != (320, 120):
        raise AssertionError(f"Runtime atlas geometry drifted: {sheet.size}")
    return [[sheet.crop((i * FRAME, row * FRAME, (i + 1) * FRAME, (row + 1) * FRAME)) for i in range(FRAMES)] for row in range(3)]


def alpha_points(image: Image.Image) -> set[tuple[int, int]]:
    return {(x, y) for y in range(FRAME) for x in range(FRAME) if image.getpixel((x, y))[3]}


def components8(points: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    remaining = set(points)
    result = []
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
        result.append(component)
    return sorted(result, key=len, reverse=True)


def map_accents(base: Image.Image) -> Image.Image:
    frame = base.copy()
    for y in range(FRAME):
        for x in range(FRAME):
            replacement = ACCENT_MAP.get(frame.getpixel((x, y)))
            if replacement is not None:
                frame.putpixel((x, y), replacement)
    return frame


def add_points(frame: Image.Image, base: Image.Image, table: dict[tuple[int, int], tuple[int, int, int, int]], label: str) -> None:
    for point, color in table.items():
        if base.getpixel(point) != TRANSPARENT:
            raise AssertionError(f"{label}: explicit add point is not source-transparent: {point}")
        frame.putpixel(point, color)


def recolor_existing(frame: Image.Image, base: Image.Image, table: dict[tuple[int, int], tuple[int, int, int, int]], label: str) -> None:
    for point, color in table.items():
        if base.getpixel(point)[3] == 0:
            raise AssertionError(f"{label}: phase point lost ordinary Alpha: {point}")
        frame.putpixel(point, color)


def audit_frame(frame: Image.Image, label: str) -> None:
    box = frame.getchannel("A").getbbox()
    if box is None or box[2] - box[0] > 28 or box[3] - box[1] > 28 or box[3] != 32:
        raise AssertionError(f"{label}: bbox/baseline contract failed: {box}")
    colors = set(frame.getdata())
    if not colors <= ALLOWED:
        raise AssertionError(f"{label}: palette drift: {colors - ALLOWED}")
    if colors & OLD_ACCENTS:
        raise AssertionError(f"{label}: old red/orange remains")
    for red, green, blue, alpha in frame.getdata():
        if alpha not in (0, 255):
            raise AssertionError(f"{label}: non-binary Alpha")
        if alpha == 0 and (red, green, blue) != (0, 0, 0):
            raise AssertionError(f"{label}: dirty transparent RGB")


def build_move(option: str, bases: list[Image.Image]) -> list[Image.Image]:
    result = []
    for index, base in enumerate(bases):
        frame = map_accents(base)
        points = dict(COMMON_A1)
        points.update(MOVE_WRISTS)
        if option == "m2" and index in (2, 3):
            points[(25, 20)] = PLATE_HIGHLIGHT
            points[(13, 25)] = MID_STEEL
        elif option == "m2" and index in (4, 5):
            points[(25, 20)] = MID_STEEL
            points[(13, 25)] = PLATE_HIGHLIGHT
        add_points(frame, base, points, f"{option}[{index}]")
        if alpha_points(frame) - alpha_points(base) != set(COMMON_A1) | set(MOVE_WRISTS):
            raise AssertionError(f"{option}[{index}]: Alpha whitelist drifted")
        audit_frame(frame, f"{option}[{index}]")
        result.append(frame)
    return result


def build_boost(option: str, bases: list[Image.Image]) -> list[Image.Image]:
    result = []
    for index, base in enumerate(bases):
        frame = map_accents(base)
        points = dict(COMMON_A1)
        points.update(BOOST_WRISTS)
        add_points(frame, base, points, f"{option}[{index}]")
        lower_index = index if option == "s1" else (index + 4) % FRAMES
        phase = {
            (10, 18): GUARD_PHASE[index],
            (11, 18): HAND_PHASE[index],
            (11, 26): GUARD_PHASE[lower_index],
            (12, 25): HAND_PHASE[lower_index],
        }
        recolor_existing(frame, base, phase, f"{option}[{index}]")
        if alpha_points(frame) - alpha_points(base) != set(COMMON_A1) | set(BOOST_WRISTS):
            raise AssertionError(f"{option}[{index}]: Alpha whitelist drifted")
        if frame.getpixel((24, 21)) != ACCENT_MAP[base.getpixel((24, 21))]:
            raise AssertionError(f"{option}[{index}]: neutral mapped function point pulsed")
        audit_frame(frame, f"{option}[{index}]")
        result.append(frame)
    return result


def build_death(option: str, bases: list[Image.Image]) -> list[Image.Image]:
    tables = DEATH_D1_POINT_TABLES if option == "d1" else DEATH_D2_POINT_TABLES
    expected_counts = (12, 12, 12, 14, 10, 10, 12, 11) if option == "d1" else (12, 12, 12, 14, 8, 6, 4, 2)
    if tuple(map(len, tables)) != expected_counts:
        raise AssertionError(f"{option}: frozen explicit table counts drifted")
    result = []
    for index, (base, table) in enumerate(zip(bases, tables)):
        frame = map_accents(base)
        add_points(frame, base, table, f"{option}[{index}]")
        if alpha_points(frame) - alpha_points(base) != set(table):
            raise AssertionError(f"{option}[{index}]: add-only Alpha table drifted")
        if alpha_points(base) - alpha_points(frame):
            raise AssertionError(f"{option}[{index}]: ordinary Alpha was deleted")
        ordinary_components = components8(alpha_points(base))
        candidate_components = components8(alpha_points(frame))
        if len(candidate_components) != len(ordinary_components):
            raise AssertionError(f"{option}[{index}]: component count drifted")
        if not set(table) <= candidate_components[0]:
            raise AssertionError(f"{option}[{index}]: reinforcement detached from dominant component")
        audit_frame(frame, f"{option}[{index}]")
        result.append(frame)
    return result


def build_all(rows: list[list[Image.Image]]) -> dict[str, list[Image.Image]]:
    built = {
        "m1": build_move("m1", rows[0]),
        "m2": build_move("m2", rows[0]),
        "s1": build_boost("s1", rows[1]),
        "s2": build_boost("s2", rows[1]),
        "d1": build_death("d1", rows[2]),
        "d2": build_death("d2", rows[2]),
    }
    with Image.open(ANCHOR) as image:
        if built["m1"][0].tobytes() != image.convert("RGBA").tobytes():
            raise AssertionError("M1 frame0 does not exactly reproduce approved N1C")
    for index in range(FRAMES):
        if alpha_points(built["m1"][index]) != alpha_points(built["m2"][index]):
            raise AssertionError("M1/M2 Alpha masks differ")
        if alpha_points(built["s1"][index]) != alpha_points(built["s2"][index]):
            raise AssertionError("S1/S2 Alpha masks differ")
    if any(built["d1"][i].tobytes() != built["d2"][i].tobytes() for i in range(4)):
        raise AssertionError("D1/D2 first four frames must be byte-identical")
    return built


def strip(frames: list[Image.Image]) -> Image.Image:
    result = Image.new("RGBA", (FRAME * len(frames), FRAME), TRANSPARENT)
    for index, frame in enumerate(frames):
        result.alpha_composite(frame, (index * FRAME, 0))
    return result


def composite(image: Image.Image) -> Image.Image:
    result = Image.new("RGBA", image.size, BACKGROUND)
    result.alpha_composite(image)
    return result.convert("RGB")


def nearest_review(image: Image.Image, factor: int) -> Image.Image:
    return composite(image).resize((image.width * factor, image.height * factor), Image.Resampling.NEAREST)


def delta_strip(frames: list[Image.Image], bases: list[Image.Image]) -> Image.Image:
    result = Image.new("RGBA", (FRAME * FRAMES, FRAME), TRANSPARENT)
    for index, (frame, base) in enumerate(zip(frames, bases)):
        for y in range(FRAME):
            for x in range(FRAME):
                before, after = base.getpixel((x, y)), frame.getpixel((x, y))
                if before == after:
                    continue
                if before[3] == 0 and after[3]:
                    color = (86, 224, 255, 255)
                elif before in OLD_ACCENTS:
                    color = PURPLE[5]
                else:
                    color = (255, 210, 80, 255)
                result.putpixel((index * FRAME + x, y), color)
    return result


def gif_palette() -> tuple[list[int], dict[tuple[int, int, int], int]]:
    colors = []
    for color in (BACKGROUND, *STEEL, *PURPLE):
        if color[:3] not in colors:
            colors.append(color[:3])
    palette = [channel for color in colors for channel in color] + [0] * (768 - len(colors) * 3)
    return palette, {color: index for index, color in enumerate(colors)}


def indexed_exact(image: Image.Image) -> Image.Image:
    palette, indices = gif_palette()
    rgb = image.convert("RGB")
    result = Image.new("P", rgb.size)
    result.putpalette(palette)
    result.putdata([indices[pixel] for pixel in rgb.getdata()])
    return result


def save_gif(frames: list[Image.Image], path: Path, fps: int, mirrored: bool) -> None:
    ensure_dev(path)
    expected, prepared = [], []
    for frame in frames:
        source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if mirrored else frame
        review = nearest_review(source, 16)
        expected.append(review)
        prepared.append(indexed_exact(review))
    path.parent.mkdir(parents=True, exist_ok=True)
    duration = round(1000 / fps)
    prepared[0].save(path, save_all=True, append_images=prepared[1:], duration=[duration] * FRAMES, loop=0, optimize=False, disposal=2)
    with Image.open(path) as decoded:
        if decoded.n_frames != FRAMES:
            raise AssertionError(f"GIF frame count drifted: {path}")
        for index, wanted in enumerate(expected):
            decoded.seek(index)
            if decoded.convert("RGB").tobytes() != wanted.tobytes():
                raise AssertionError(f"GIF palette damaged frame {index}: {path}")


def normalize_reference(path: Path) -> Image.Image:
    with Image.open(path) as image:
        result = normalize_source(image.convert("RGBA"))
    pixels = result.load()
    for y in range(result.height):
        for x in range(result.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha == 0:
                continue
            strongest = max(red, blue)
            if green >= 72 and green >= strongest + 18:
                pixels[x, y] = TRANSPARENT
            elif green > strongest + 8:
                pixels[x, y] = (red, strongest, blue, 255)
    if result.getchannel("A").getbbox() is None:
        raise AssertionError(f"Normalized ImageGen reference is empty: {path}")
    for pixel in result.getdata():
        if pixel[3] not in (0, 255) or (pixel[3] == 0 and pixel[:3] != (0, 0, 0)):
            raise AssertionError(f"Normalized reference Alpha contract failed: {path}")
    return result


def font(size: int) -> ImageFont.ImageFont:
    for path in (Path("C:/Windows/Fonts/msyh.ttc"), Path("C:/Windows/Fonts/simhei.ttf")):
        if path.is_file():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    result = image.copy()
    result.thumbnail(size, Image.Resampling.NEAREST)
    return result


def review_panel(key: str, reference: Image.Image, frames: list[Image.Image], bases: list[Image.Image], path: Path) -> None:
    spec = SPECS[key]
    canvas = Image.new("RGBA", (1500, 1040), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    draw.text((40, 28), f"{key.upper()}  {spec['title']}", font=font(34), fill=(236, 240, 244, 255))
    draw.text((40, 82), str(spec["summary"]), font=font(22), fill=(190, 198, 208, 255))
    draw.text((40, 130), "ImageGen结构参考（像素未导入）", font=font(22), fill=(197, 138, 255, 255))
    thumb = fit(reference, (600, 320))
    canvas.alpha_composite(thumb, (40 + (600 - thumb.width) // 2, 168 + (320 - thumb.height) // 2))
    draw.text((680, 130), "确定性原生候选 4×", font=font(22), fill=(86, 224, 255, 255))
    candidate = nearest_review(strip(frames), 4).convert("RGBA")
    canvas.alpha_composite(candidate, (180, 540))
    draw.text((40, 720), "相对普通运行帧差分 4×（紫=功能色映射 / 青=新增强化件 / 黄=受控换相）", font=font(20), fill=(220, 224, 230, 255))
    delta = nearest_review(delta_strip(frames, bases), 4).convert("RGBA")
    canvas.alpha_composite(delta, (180, 760))
    draw.text((40, 950), f"40×40 × 8 | {spec['fps']} FPS | ordinary runtime direct-crop | runtime_written=false", font=font(20), fill=(160, 170, 182, 255))
    save_png(canvas, path)


def image_record(path: Path) -> dict[str, object]:
    with Image.open(path) as image:
        record = {"path": rel(path), "sha256": sha256(path), "size": list(image.size), "mode": image.mode}
        if image.format == "PNG":
            record["rgba_sha256"] = rgba_sha(image)
        return record


def frame_metrics(frames: list[Image.Image]) -> list[dict[str, object]]:
    result = []
    for frame in frames:
        box = frame.getchannel("A").getbbox()
        result.append({"rgba_sha256": rgba_sha(frame), "bbox": list(box) if box else None, "opaque_pixels": len(alpha_points(frame)), "components8": len(components8(alpha_points(frame)))})
    return result


def write_outputs(built: dict[str, list[Image.Image]], rows: list[list[Image.Image]]) -> tuple[dict[str, object], dict[str, object]]:
    outputs, references = {}, {}
    for key, frames in built.items():
        spec = SPECS[key]
        name = str(spec["name"])
        raw = SOURCE_DIR / f"combat_robot_ninja_elite_{name}_imagegen.png"
        reference = normalize_reference(raw)
        cropped = crop_to_square(reference, padding=24, align_to_grid=False)
        crop_path = SOURCE_DIR / f"combat_robot_ninja_elite_{name}_crop_tool.png"
        save_png(cropped, crop_path)
        native_path = SOURCE_DIR / f"combat_robot_ninja_elite_{name}_candidate_native.png"
        preview_path = PREVIEW_DIR / f"combat_robot_ninja_elite_{name}_candidate_16x.png"
        delta_path = PREVIEW_DIR / f"combat_robot_ninja_elite_{name}_ordinary_delta_16x.png"
        gif_path = PREVIEW_DIR / f"combat_robot_ninja_elite_{name}_candidate.gif"
        mirror_path = PREVIEW_DIR / f"combat_robot_ninja_elite_{name}_candidate_mirrored.gif"
        panel_path = PREVIEW_DIR / f"combat_robot_ninja_elite_{name}_review_panel.png"
        bases = rows[int(spec["row"])]
        save_png(strip(frames), native_path)
        save_png(nearest_review(strip(frames), 16), preview_path)
        save_png(nearest_review(delta_strip(frames, bases), 16), delta_path)
        save_gif(frames, gif_path, int(spec["fps"]), False)
        save_gif(frames, mirror_path, int(spec["fps"]), True)
        review_panel(key, cropped, frames, bases, panel_path)
        references[key] = {
            "imagegen_source": {"path": rel(raw), "sha256": sha256(raw), "pixels_imported": False},
            "pixel_crop_tool_reference": {"path": rel(crop_path), "sha256": sha256(crop_path), "analysis": analyze_image(cropped), "unsafe_for_direct_resize": True, "pixels_imported": False},
        }
        outputs[key] = {
            "title": spec["title"], "summary": spec["summary"], "runtime_fps": spec["fps"],
            "native": image_record(native_path), "integer_16x": image_record(preview_path),
            "ordinary_delta_16x": image_record(delta_path), "forward_gif": image_record(gif_path),
            "mirrored_gif": image_record(mirror_path), "review_panel": image_record(panel_path),
            "frame_rgba_sha256": [rgba_sha(frame) for frame in frames],
        }
    return outputs, references


def main() -> None:
    args = parse_args()
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    existing_manifest = read_existing_manifest()
    selection, preserved_native_locks = resolve_selection(args.approve, existing_manifest)
    input_locks = verify_inputs()
    rows = runtime_rows()
    first = build_all(rows)
    second = build_all(rows)
    for key in first:
        if any(a.tobytes() != b.tobytes() for a, b in zip(first[key], second[key])):
            raise AssertionError(f"{key}: in-memory deterministic rebuild drifted")
    outputs, references = write_outputs(first, rows)
    second_human_approved = selection is not None
    stage = "second_human_gate_approved" if second_human_approved else "animation_candidates_pending_second_human_gate"
    approved_outputs = None
    approved_native_locks = None
    if selection is not None:
        approved_outputs = {slot: outputs[key] for slot, key in selection.items()}
        approved_native_locks = {
            slot: {
                "candidate": key,
                "path": outputs[key]["native"]["path"],
                "sha256": outputs[key]["native"]["sha256"],
                "rgba_sha256": outputs[key]["native"]["rgba_sha256"],
            }
            for slot, key in selection.items()
        }
        if preserved_native_locks is not None and approved_native_locks != preserved_native_locks:
            raise AssertionError(
                "Previously approved native hashes drifted; explicit re-approval with a changed selection is required"
            )
    stability = {
        "asset": "combat_robot_ninja_elite_animation_candidates",
        "stage": stage,
        "approved_anchor": "n1c",
        "approved_selection": selection,
        "approved_animation_selection": selection,
        "approved_native_locks": approved_native_locks,
        "second_human_approved": second_human_approved,
        "runtime_written": False,
        "frame_metrics": {key: frame_metrics(frames) for key, frames in first.items()},
        "move": {"m1_wrist_states": 1, "m2_wrist_states": 3, "eight_leg_phases_inherited": True, "alpha_masks_equal": True},
        "boost": {"s1_phase_offset": 0, "s2_lower_pair_phase_offset": 4, "static_boost_wrist_points": [list(point) for point in sorted(BOOST_WRISTS)], "neutral_point_24_21_not_pulsed": True, "alpha_masks_equal": True},
        "death": {
            "construction": "eight frozen explicit add-only integer point/color tables; no rotation, search, inference, or fallback",
            "d1_counts": [len(table) for table in DEATH_D1_POINT_TABLES],
            "d2_counts": [len(table) for table in DEATH_D2_POINT_TABLES],
            "d2_first_four_byte_equal_d1": True,
            "d1_tables": [[{"point": list(point), "rgba": list(color)} for point, color in sorted(table.items())] for table in DEATH_D1_POINT_TABLES],
            "d2_tables": [[{"point": list(point), "rgba": list(color)} for point, color in sorted(table.items())] for table in DEATH_D2_POINT_TABLES],
        },
    }
    stability_path = enemy_asset_report_path("combat_robot_ninja_elite_animation_stability_report.json")
    write_json(stability_path, stability)
    report = {
        "asset": "combat_robot_ninja_elite_animation_candidates",
        "stage": stage,
        "preview_only": True,
        "approved_anchor": {"selection": "n1c", "path": rel(ANCHOR), "sha256": sha256(ANCHOR), "rgba_sha256": EXPECTED_ANCHOR_RGBA_SHA},
        "approved_selection": selection,
        "approved_animation_selection": selection,
        "approved_outputs": approved_outputs,
        "approved_native_locks": approved_native_locks,
        "second_human_approved": second_human_approved,
        "runtime_written": False,
        "imagegen_pixels_imported": False,
        "builder": {"path": rel(SCRIPT), "sha256": sha256(SCRIPT)},
        "input_locks": input_locks,
        "imagegen_references": references,
        "outputs": outputs,
        "stability_report": rel(stability_path),
        "stability_report_sha256": sha256(stability_path),
        "checks": {
            "runtime_source_sha_locked": True, "approved_n1c_file_and_rgba_locked": True,
            "six_imagegen_raw_sha_locked": True, "pixel_grid_analyzer_evidence_recorded": True,
            "pixel_crop_tool_evidence_recorded": True, "ordinary_rows_directly_cropped": True,
            "ordinary_pixels_inherited_outside_explicit_whitelists": True,
            "death_uses_frozen_explicit_tables_only": True, "no_rotation_search_inference_or_fallback": True,
            "binary_alpha": True, "transparent_rgb_zero": True, "fixed_palette": True,
            "old_red_orange_remaining": 0, "maximum_visible_28x28": True, "baseline_bottom_32": True,
            "gif_fixed_lossless_palette": True, "gif_decodes_exactly_to_native_nearest_neighbor": True,
            "deterministic_in_memory_rebuild": True, "runtime_paths_written": [],
        },
    }
    report_path = enemy_asset_report_path("combat_robot_ninja_elite_animation_preview_report.json")
    write_json(report_path, report)
    manifest = {
        "asset": "combat_robot_ninja_elite", "stage": stage,
        "approved_anchor": "n1c", "approved_animation_selection": selection,
        "approved_native_locks": approved_native_locks,
        "second_human_approved": second_human_approved, "final_human_approved": False,
        "runtime_written": False, "imagegen_pixels_imported": False,
        "candidate_order": ["m1", "m2", "s1", "s2", "d1", "d2"],
        "report": rel(report_path), "report_sha256": sha256(report_path),
        "stability_report": rel(stability_path), "stability_report_sha256": sha256(stability_path),
    }
    write_json(ANIMATION_MANIFEST, manifest)
    print("COMBAT_ROBOT_NINJA_ELITE_ANIMATION_PREVIEWS_OK")
    print(f"report={rel(report_path)}")
    print(f"approved_selection={selection}")
    print(f"manifest={rel(ANIMATION_MANIFEST)}")


if __name__ == "__main__":
    main()
