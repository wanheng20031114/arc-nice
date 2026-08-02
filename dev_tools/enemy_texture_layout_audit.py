#!/usr/bin/env python3
"""Audit the scene-aligned enemy texture layout and every moved reference."""

from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEXTURE_ROOT = ROOT / "resources" / "texture"
ENEMY_ROOT = TEXTURE_ROOT / "enemy"

EXPECTED_PNGS: dict[str, tuple[str, ...]] = {
    "artificial_creation": (
        "stone_golem.png",
        "stone_golem_elite.png",
    ),
    "capoo": (
        "capoo_ak47.png",
        "capoo_ak47_bullet.png",
        "capoo_knight.png",
        "capoo_knight_elite.png",
        "capoo_knight_slash.png",
        "capoo_mage.png",
        "capoo_mage_fireball.png",
        "capoo_rpg.png",
        "capoo_rpg_explosion.png",
        "capoo_rpg_rocket.png",
        "capoo_smg.png",
        "capoo_smg_bullet.png",
        "capoo_sniper.png",
        "capoo_sniper_lock_reticle.png",
        "capoo_swordsman.png",
        "capoo_swordsman_slash.png",
    ),
    "mechanical_life": (
        "combat_robot.png",
        "combat_robot_gunner.png",
        "combat_robot_gunner_bullet.png",
    ),
    "slime": (
        "slime.png",
        "slime_fire.png",
        "slime_frost.png",
        "slime_golden.png",
        "slime_green.png",
    ),
    "sorcerer": (
        "fire_sorcerer.png",
        "fire_sorcerer_move.png",
        "fire_sorcerer_fireball.png",
        "fire_sorcerer_elite.png",
        "fire_sorcerer_elite_move.png",
        "fire_sorcerer_elite_fireball.png",
        "frost_sorcerer.png",
        "frost_sorcerer_move.png",
        "frost_sorcerer_ice_spike.png",
        "frost_sorcerer_elite.png",
        "frost_sorcerer_elite_move.png",
        "lightning_sorcerer.png",
        "lightning_sorcerer_move.png",
        "lightning_sorcerer_elite.png",
        "lightning_sorcerer_elite_move.png",
    ),
    "stone_eroded": (
        "capoo_ak47.png",
        "capoo_knight.png",
        "capoo_knight_elite.png",
        "capoo_mage.png",
        "capoo_rpg.png",
        "capoo_smg.png",
        "capoo_sniper.png",
        "capoo_swordsman.png",
        "slime.png",
        "slime_fire.png",
        "slime_frost.png",
        "slime_golden.png",
        "slime_green.png",
        "yuanshi_insect.png",
        "yuanshi_insect_fire_ranged.png",
        "yuanshi_insect_green_shell.png",
        "yuanshi_insect_guardian.png",
        "yuanshi_insect_purple_bomber.png",
    ),
    "yuanshi_insect": (
        "guardian_point_light.png",
        "yuanshi_insect_fire_projectile.png",
        "yuanshi_insect_fire_ranged.png",
        "yuanshi_insect_green_shell.png",
        "yuanshi_insect_guardian.png",
        "yuanshi_insect_purple_bomber.png",
        "yuanshi_insect_purple_explosion.png",
        "源石虫.png",
        "爆炸特效.png",
    ),
}

AURA_RESOURCES: dict[str, str | None] = {
    "yuanshi_insect_green_aura_colors.tres": "uid://04o6ofntabvg",
    "yuanshi_insect_green_aura_particle.tres": "uid://gpwpt2glrhpb",
    "yuanshi_insect_guardian_aura_colors.tres": None,
}

PIPELINE_MARKERS = {
    "dev_tools/process_capoo_variant_assets.py": (
        "resources/texture/enemy/capoo",
    ),
    "dev_tools/process_capoo_single_asset.py": (
        "res://resources/texture/enemy/capoo/{name}.png",
    ),
    "dev_tools/process_combat_robot_assets.py": (
        "resources/texture/enemy/mechanical_life/combat_robot.png",
    ),
    "dev_tools/process_combat_robot_gunner_assets.py": (
        "resources/texture/enemy/mechanical_life",
    ),
    "dev_tools/combat_robot_gunner_asset_audit.py": (
        "resources/texture/enemy/mechanical_life",
    ),
    "dev_tools/process_fire_sorcerer_assets.py": (
        "resources/texture/enemy/sorcerer",
    ),
    "dev_tools/process_fire_sorcerer_elite_assets.py": (
        "resources/texture/enemy/sorcerer",
    ),
    "dev_tools/process_frost_sorcerer_assets.py": (
        "resources/texture/enemy/sorcerer",
    ),
    "dev_tools/process_lightning_sorcerer_assets.py": (
        "resources/texture/enemy/sorcerer/lightning_sorcerer.png",
        "resources/texture/enemy/sorcerer/lightning_sorcerer_move.png",
    ),
    "dev_tools/process_lightning_sorcerer_elite_assets.py": (
        "resources/texture/enemy/sorcerer",
    ),
    "dev_tools/stone_eroded_enemy_asset_pipeline.py": (
        "resources/texture/enemy/stone_eroded",
    ),
    "dev_tools/generate_stone_eroded_enemy_variants.py": (
        "res://resources/texture/enemy/stone_eroded/{variant.texture_name}",
    ),
    "dev_tools/generate_yuanshi_insect_fire_assets.gd": (
        "res://resources/texture/enemy/yuanshi_insect",
    ),
    "dev_tools/generate_yuanshi_insect_guardian_assets.gd": (
        "res://resources/texture/enemy/yuanshi_insect",
    ),
}

TEXT_EXTENSIONS = {
    ".cfg",
    ".gd",
    ".gdshader",
    ".html",
    ".import",
    ".json",
    ".md",
    ".ps1",
    ".py",
    ".tres",
    ".tscn",
    ".txt",
}
IGNORED_DIRECTORIES = {".git", ".godot", "tmp", "__pycache__"}
UID_RE = re.compile(r'^uid="(uid://[^"]+)"$', re.MULTILINE)
ENEMY_REFERENCE_RE = re.compile(
    r"res://(resources/texture/enemy/[^\"'`\s\],)]+)"
)


def _project_text_files() -> list[Path]:
    files: list[Path] = []
    for directory, names, filenames in os.walk(ROOT):
        names[:] = [name for name in names if name not in IGNORED_DIRECTORIES]
        parent = Path(directory)
        for filename in filenames:
            path = parent / filename
            if path.suffix.lower() in TEXT_EXTENSIONS:
                files.append(path)
    return files


def _read_project_text(path: Path) -> str:
    raw = path.read_bytes()
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16")
    return raw.decode("utf-8-sig")


def _expected_cache_path(resource_path: str, filename: str) -> str:
    digest = hashlib.md5(resource_path.encode("utf-8")).hexdigest()
    return f"res://.godot/imported/{filename}-{digest}.ctex"


def main() -> int:
    failures: list[str] = []
    expected_paths: list[Path] = []
    import_uids: dict[str, Path] = {}

    expected_total = sum(len(names) for names in EXPECTED_PNGS.values())
    if expected_total != 68:
        failures.append(f"Audit inventory must contain 68 PNGs, found {expected_total}.")

    actual_categories = {
        path.name for path in ENEMY_ROOT.iterdir() if path.is_dir()
    } if ENEMY_ROOT.is_dir() else set()
    if actual_categories != set(EXPECTED_PNGS):
        failures.append(
            "Enemy categories differ: "
            f"expected={sorted(EXPECTED_PNGS)} actual={sorted(actual_categories)}"
        )

    for category, filenames in EXPECTED_PNGS.items():
        category_dir = ENEMY_ROOT / category
        actual_pngs = (
            {path.name for path in category_dir.glob("*.png")}
            if category_dir.is_dir()
            else set()
        )
        if actual_pngs != set(filenames):
            failures.append(
                f"{category} PNG inventory differs: "
                f"expected={sorted(filenames)} actual={sorted(actual_pngs)}"
            )

        for filename in filenames:
            png_path = category_dir / filename
            import_path = png_path.with_name(f"{filename}.import")
            expected_paths.append(png_path)
            if not png_path.is_file():
                failures.append(f"Missing PNG: {png_path.relative_to(ROOT)}")
                continue
            if png_path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                failures.append(f"Invalid PNG signature: {png_path.relative_to(ROOT)}")
            if not import_path.is_file():
                failures.append(f"Missing import sidecar: {import_path.relative_to(ROOT)}")
                continue

            import_text = import_path.read_text(encoding="utf-8")
            resource_path = "res://" + png_path.relative_to(ROOT).as_posix()
            expected_cache = _expected_cache_path(resource_path, filename)
            if f'source_file="{resource_path}"' not in import_text:
                failures.append(f"Wrong source_file: {import_path.relative_to(ROOT)}")
            if import_text.count(expected_cache) != 2:
                failures.append(
                    f"Wrong path/dest_files cache target: {import_path.relative_to(ROOT)}"
                )

            uid_match = UID_RE.search(import_text)
            if uid_match is None:
                failures.append(f"Missing UID: {import_path.relative_to(ROOT)}")
            else:
                uid = uid_match.group(1)
                if uid in import_uids:
                    failures.append(
                        f"Duplicate UID {uid}: {import_uids[uid].relative_to(ROOT)} and "
                        f"{import_path.relative_to(ROOT)}"
                    )
                import_uids[uid] = import_path

    aura_dir = ENEMY_ROOT / "yuanshi_insect"
    for filename, expected_uid in AURA_RESOURCES.items():
        path = aura_dir / filename
        expected_paths.append(path)
        if not path.is_file():
            failures.append(f"Missing aura resource: {path.relative_to(ROOT)}")
            continue
        if expected_uid is not None and f'uid="{expected_uid}"' not in path.read_text(
            encoding="utf-8"
        ):
            failures.append(f"Changed aura UID: {path.relative_to(ROOT)}")

    if not (TEXTURE_ROOT / "道具ui.png").is_file():
        failures.append("Shared texture resources/texture/道具ui.png was moved or removed.")

    texture_prefix = "resources" + "/texture"
    legacy_paths: set[str] = {f"{texture_prefix}/stone_eroded/"}
    for category, filenames in EXPECTED_PNGS.items():
        if category == "stone_eroded":
            continue
        legacy_paths.update(f"{texture_prefix}/{filename}" for filename in filenames)
    legacy_paths.update(
        f"{texture_prefix}/{filename}" for filename in AURA_RESOURCES
    )

    for path in _project_text_files():
        text = _read_project_text(path)
        relative = path.relative_to(ROOT)
        for legacy_path in legacy_paths:
            if legacy_path in text:
                failures.append(f"Legacy path in {relative}: {legacy_path}")
        for match in ENEMY_REFERENCE_RE.finditer(text):
            reference = match.group(1)
            if any(marker in reference for marker in ("{", "}", "%")):
                continue
            if not (ROOT / Path(reference)).exists():
                failures.append(f"Broken enemy texture reference in {relative}: {reference}")

    for relative, markers in PIPELINE_MARKERS.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"Missing pipeline or audit: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                failures.append(f"Missing new-path marker in {relative}: {marker}")

    legacy_files = [
        path
        for path in TEXTURE_ROOT.iterdir()
        if path.is_file()
        and any(path.name == candidate.name for candidate in expected_paths)
    ]
    if legacy_files:
        failures.append(
            "Enemy files remain at the texture root: "
            + ", ".join(path.name for path in legacy_files)
        )
    if (TEXTURE_ROOT / "stone_eroded").exists():
        failures.append("Legacy directory resources/texture/stone_eroded still exists.")

    if failures:
        print("ENEMY_TEXTURE_LAYOUT_AUDIT_FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(
        "ENEMY_TEXTURE_LAYOUT_AUDIT_OK "
        f"categories={len(EXPECTED_PNGS)} png={len(expected_paths) - len(AURA_RESOURCES)} "
        f"imports={len(import_uids)} aura_resources={len(AURA_RESOURCES)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
