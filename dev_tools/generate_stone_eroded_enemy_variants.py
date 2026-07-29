#!/usr/bin/env python3
"""Generate the 21 independent stone-eroded enemy resources.

Each variant inherits its original Godot scene, overrides only SpriteFrames,
and clones the original EnemyConfig with a prefixed name, doubled health, and
150 physical defense.  The generated text resources deliberately omit new
UIDs so Godot can import them without duplicating the originals' identities.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT / "resources/config/enemies"
ANIMATION_DIR = ROOT / "resources/animation"
SCENE_DIR = ROOT / "scene/enemy/stone_eroded"
CODEX_DIR = ROOT / "resources/config/encyclopedia/enemies"

STONE_TAG = "stone_eroded"
DISPLAY_PREFIX = "被石头侵蚀的"
PHYSICAL_DEFENSE = 150


@dataclass(frozen=True)
class EnemyVariant:
	base_id: str
	family: str
	texture_name: str
	sort_order: int
	codex_base_id: str | None = None

	@property
	def output_id(self) -> str:
		return f"stone_eroded_{self.base_id}"

	@property
	def codex_source_id(self) -> str:
		return self.codex_base_id or self.base_id


VARIANTS = (
	EnemyVariant("yuanshi_insect_basic", "yuanshi_insect", "yuanshi_insect.png", 180),
	EnemyVariant("yuanshi_insect_shell", "yuanshi_insect", "yuanshi_insect.png", 181),
	EnemyVariant("yuanshi_insect_fast", "yuanshi_insect", "yuanshi_insect.png", 182),
	EnemyVariant("yuanshi_insect_bomber", "yuanshi_insect", "yuanshi_insect.png", 183),
	EnemyVariant(
		"yuanshi_insect_purple_bomber",
		"yuanshi_insect",
		"yuanshi_insect_purple_bomber.png",
		184,
	),
	EnemyVariant(
		"yuanshi_insect_green_shell",
		"yuanshi_insect",
		"yuanshi_insect_green_shell.png",
		185,
	),
	EnemyVariant(
		"yuanshi_insect_fire_ranged",
		"yuanshi_insect",
		"yuanshi_insect_fire_ranged.png",
		186,
	),
	EnemyVariant(
		"yuanshi_insect_guardian",
		"yuanshi_insect",
		"yuanshi_insect_guardian.png",
		187,
	),
	EnemyVariant("slime", "slime", "slime.png", 250, codex_base_id="slime_basic"),
	EnemyVariant("slime_fire", "slime", "slime_fire.png", 251),
	EnemyVariant("slime_frost", "slime", "slime_frost.png", 252),
	EnemyVariant("slime_green", "slime", "slime_green.png", 253),
	EnemyVariant("slime_golden", "slime", "slime_golden.png", 254),
	EnemyVariant("capoo_knight", "capoo", "capoo_knight.png", 380),
	EnemyVariant("capoo_knight_elite", "capoo", "capoo_knight_elite.png", 381),
	EnemyVariant("capoo_swordsman", "capoo", "capoo_swordsman.png", 382),
	EnemyVariant("capoo_smg", "capoo", "capoo_smg.png", 383),
	EnemyVariant("capoo_ak47", "capoo", "capoo_ak47.png", 384),
	EnemyVariant("capoo_rpg", "capoo", "capoo_rpg.png", 385),
	EnemyVariant("capoo_mage", "capoo", "capoo_mage.png", 386),
	EnemyVariant("capoo_sniper", "capoo", "capoo_sniper.png", 387),
)


def _read(path: Path) -> str:
	return path.read_text(encoding="utf-8")


def _write(path: Path, content: str) -> None:
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(content.rstrip() + "\n", encoding="utf-8", newline="\n")


def _without_resource_uid(line: str) -> str:
	return re.sub(r'\s+uid="[^"]+"', "", line)


def _resource_path(path: Path) -> str:
	return "res://" + path.relative_to(ROOT).as_posix()


def _extract_scene_path(config_text: str) -> str:
	assignment = re.search(r'^enemy_scene = ExtResource\("([^"]+)"\)$', config_text, re.MULTILINE)
	if assignment is None:
		raise ValueError("Enemy config does not assign enemy_scene.")
	resource_id = re.escape(assignment.group(1))
	resource = re.search(
		rf'^\[ext_resource type="PackedScene"[^\n]*path="([^"]+)"[^\n]*id="{resource_id}"\]$',
		config_text,
		re.MULTILINE,
	)
	if resource is None:
		raise ValueError("Enemy scene ExtResource could not be resolved.")
	return resource.group(1)


def _replace_scene_ext_resource(config_text: str, new_scene_path: str) -> str:
	assignment = re.search(r'^enemy_scene = ExtResource\("([^"]+)"\)$', config_text, re.MULTILINE)
	if assignment is None:
		raise ValueError("Enemy config does not assign enemy_scene.")
	resource_id = re.escape(assignment.group(1))
	pattern = re.compile(
		rf'^\[ext_resource type="PackedScene"[^\n]*id="{resource_id}"\]$',
		re.MULTILINE,
	)
	match = pattern.search(config_text)
	if match is None:
		raise ValueError("Enemy scene ExtResource could not be replaced.")
	line = _without_resource_uid(match.group(0))
	line = re.sub(r'path="[^"]+"', f'path="{new_scene_path}"', line)
	return config_text[: match.start()] + line + config_text[match.end() :]


def _replace_required_line(text: str, pattern: str, replacement: str) -> str:
	updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
	if count != 1:
		raise ValueError(f"Expected exactly one match for {pattern!r}, got {count}.")
	return updated


def _append_category_tag(config_text: str) -> str:
	match = re.search(r'^category_tags = PackedStringArray\((.*)\)$', config_text, re.MULTILINE)
	if match is None:
		raise ValueError("Enemy config has no category_tags assignment.")
	values = re.findall(r'"([^"]+)"', match.group(1))
	if STONE_TAG not in values:
		values.append(STONE_TAG)
	replacement = "category_tags = PackedStringArray(" + ", ".join(
		f'"{value}"' for value in values
	) + ")"
	return config_text[: match.start()] + replacement + config_text[match.end() :]


def _set_physical_defense(config_text: str) -> str:
	if re.search(r'^physical_defense = \d+$', config_text, re.MULTILINE):
		return _replace_required_line(
			config_text,
			r'^physical_defense = \d+$',
			f"physical_defense = {PHYSICAL_DEFENSE}",
		)
	attack_match = re.search(r'^attack_damage = \d+$', config_text, re.MULTILINE)
	if attack_match is not None:
		insert_at = attack_match.end()
		return (
			config_text[:insert_at]
			+ f"\nphysical_defense = {PHYSICAL_DEFENSE}"
			+ config_text[insert_at:]
		)
	health_match = re.search(r'^max_health = \d+$', config_text, re.MULTILINE)
	if health_match is None:
		raise ValueError("Enemy config has neither attack_damage nor max_health.")
	insert_at = health_match.end()
	return (
		config_text[:insert_at]
		+ f"\nphysical_defense = {PHYSICAL_DEFENSE}"
		+ config_text[insert_at:]
	)


def _build_config(variant: EnemyVariant, output_scene_path: str) -> tuple[str, str, int]:
	source_path = CONFIG_DIR / f"{variant.base_id}.tres"
	text = _read(source_path)
	original_scene_path = _extract_scene_path(text)
	header_end = text.find("\n")
	text = _without_resource_uid(text[:header_end]) + text[header_end:]
	text = _replace_scene_ext_resource(text, output_scene_path)
	display_match = re.search(r'^display_name = "([^"]+)"$', text, re.MULTILINE)
	if display_match is None:
		raise ValueError(f"{source_path} has no display_name.")
	display_name = DISPLAY_PREFIX + display_match.group(1)
	text = text[: display_match.start()] + f'display_name = "{display_name}"' + text[display_match.end() :]
	text = _append_category_tag(text)
	health_match = re.search(r'^max_health = (\d+)$', text, re.MULTILINE)
	if health_match is None:
		raise ValueError(f"{source_path} has no max_health.")
	original_health = int(health_match.group(1))
	text = text[: health_match.start()] + f"max_health = {original_health * 2}" + text[health_match.end() :]
	text = _set_physical_defense(text)
	return text, original_scene_path, original_health


def _build_animation(variant: EnemyVariant) -> str:
	source_path = ANIMATION_DIR / f"{variant.base_id}.tres"
	text = _read(source_path)
	header_end = text.find("\n")
	text = _without_resource_uid(text[:header_end]) + text[header_end:]
	texture_pattern = re.compile(
		r'^\[ext_resource type="Texture2D"[^\n]*path="([^"]+)"[^\n]*\]$',
		re.MULTILINE,
	)
	matches = list(texture_pattern.finditer(text))
	if not matches:
		raise ValueError(f"{source_path} has no texture ExtResource.")
	main_match = matches[0]
	line = _without_resource_uid(main_match.group(0))
	new_texture_path = f"res://resources/texture/stone_eroded/{variant.texture_name}"
	line = re.sub(r'path="[^"]+"', f'path="{new_texture_path}"', line)
	return text[: main_match.start()] + line + text[main_match.end() :]


def _scene_root_name(output_id: str) -> str:
	return "".join(part.capitalize() for part in output_id.split("_"))


def _build_scene(
	variant: EnemyVariant,
	original_scene_path: str,
	animation_path: str,
) -> str:
	return "\n".join(
		(
			"[gd_scene load_steps=3 format=3]",
			"",
			f'[ext_resource type="PackedScene" path="{original_scene_path}" id="1_base"]',
			f'[ext_resource type="SpriteFrames" path="{animation_path}" id="2_frames"]',
			"",
			f'[node name="{_scene_root_name(variant.output_id)}" instance=ExtResource("1_base")]',
			"",
			'[node name="AnimatedSprite2D" parent="." index="0"]',
			'sprite_frames = ExtResource("2_frames")',
		)
	)


def _append_codex_traits(codex_text: str) -> str:
	match = re.search(r'^traits = PackedStringArray\((.*)\)$', codex_text, re.MULTILINE)
	if match is None:
		raise ValueError("Codex entry has no traits assignment.")
	values = re.findall(r'"([^"]+)"', match.group(1))
	for value in ("被石头侵蚀", "150物理防御", "双倍生命"):
		if value not in values:
			values.append(value)
	replacement = "traits = PackedStringArray(" + ", ".join(
		f'"{value}"' for value in values
	) + ")"
	return codex_text[: match.start()] + replacement + codex_text[match.end() :]


def _build_codex(
	variant: EnemyVariant,
	config_path: str,
	animation_path: str,
) -> str:
	source_path = CODEX_DIR / f"{variant.codex_source_id}.tres"
	text = _read(source_path)
	header_end = text.find("\n")
	text = _without_resource_uid(text[:header_end]) + text[header_end:]
	text, config_path_count = re.subn(
		r'path="res://resources/config/enemies/[^"]+\.tres"',
		f'path="{config_path}"',
		text,
		count=1,
	)
	if config_path_count != 1:
		raise ValueError(
			f"{source_path} must reference exactly one enemy config resource."
		)
	text, animation_path_count = re.subn(
		r'path="res://resources/animation/[^"]+\.tres"',
		f'path="{animation_path}"',
		text,
		count=1,
	)
	if animation_path_count != 1:
		raise ValueError(
			f"{source_path} must reference exactly one animation resource."
		)
	text = _replace_required_line(
		text,
		r'^entry_id = &"[^"]+"$',
		f'entry_id = &"{variant.output_id}"',
	)
	text = _replace_required_line(
		text,
		r'^sort_order = \d+$',
		f"sort_order = {variant.sort_order}",
	)
	description_match = re.search(r'^description = "([^"]*)"$', text, re.MULTILINE)
	if description_match is None:
		raise ValueError(f"{source_path} has no description.")
	description = (
		description_match.group(1)
		+ " 石质侵蚀使它的生命提升至原版两倍，并赋予150点物理防御。"
	)
	text = (
		text[: description_match.start()]
		+ f'description = "{description}"'
		+ text[description_match.end() :]
	)
	return _append_codex_traits(text)


def generate_variant(variant: EnemyVariant) -> dict[str, object]:
	output_animation = ANIMATION_DIR / f"{variant.output_id}.tres"
	output_scene = SCENE_DIR / f"{variant.output_id}.tscn"
	output_config = CONFIG_DIR / f"{variant.output_id}.tres"
	output_codex = CODEX_DIR / f"{variant.output_id}.tres"
	animation_path = _resource_path(output_animation)
	scene_path = _resource_path(output_scene)
	config_path = _resource_path(output_config)

	config_text, original_scene_path, original_health = _build_config(
		variant,
		scene_path,
	)
	_write(output_animation, _build_animation(variant))
	_write(output_scene, _build_scene(variant, original_scene_path, animation_path))
	_write(output_config, config_text)
	_write(output_codex, _build_codex(variant, config_path, animation_path))
	return {
		"id": variant.output_id,
		"health": original_health * 2,
		"physical_defense": PHYSICAL_DEFENSE,
	}


def main() -> None:
	parser = argparse.ArgumentParser(
		description="Generate all independent stone-eroded enemy resources."
	)
	parser.add_argument(
		"--variant",
		action="append",
		dest="variant_ids",
		help="Generate only this base enemy id; repeat for multiple variants.",
	)
	args = parser.parse_args()
	selected = [
		variant
		for variant in VARIANTS
		if not args.variant_ids or variant.base_id in args.variant_ids
	]
	if args.variant_ids and len(selected) != len(set(args.variant_ids)):
		known = {variant.base_id for variant in VARIANTS}
		unknown = sorted(set(args.variant_ids) - known)
		raise ValueError(f"Unknown variants: {unknown}")
	for variant in selected:
		report = generate_variant(variant)
		print(
			f"{report['id']}: health={report['health']}, "
			f"physical_defense={report['physical_defense']}"
		)


if __name__ == "__main__":
	main()
