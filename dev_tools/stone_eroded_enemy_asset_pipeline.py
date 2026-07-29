#!/usr/bin/env python3
"""Build stone-eroded enemy textures from ImageGen-authored edit sheets.

ImageGen provides the authored placement and colors of the subtle stone crust.
The runtime sheet keeps the canonical texture's canvas and alpha bytes exactly,
so every existing AtlasTexture region, margin, anchor, and animation remains
valid.  Only opaque body pixels selected by the generated stone treatment are
recolored.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/stone_eroded_enemies"
TEXTURE_DIR = ROOT / "resources/texture/stone_eroded"
REVIEW_DIR = ROOT / "tmp/stone_eroded_enemies"


@dataclass(frozen=True)
class TextureAsset:
	asset_id: str
	base_path: Path
	imagegen_path: Path
	output_path: Path
	columns: int
	rows: int
	key_color: tuple[int, int, int]
	body_mode: str
	generated_columns: int | None = None
	generated_rows: int | None = None
	allow_empty_frames: tuple[int, ...] = ()


ASSETS = (
	TextureAsset(
		asset_id="capoo_ak47",
		base_path=ROOT / "resources/texture/capoo_ak47.png",
		imagegen_path=SOURCE_DIR / "capoo_ak47_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "capoo_ak47.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_knight",
		base_path=ROOT / "resources/texture/capoo_knight.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_knight_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "capoo_knight.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_right",
	),
	TextureAsset(
		asset_id="capoo_knight_elite",
		base_path=ROOT / "resources/texture/capoo_knight_elite.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_knight_elite_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "capoo_knight_elite.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_right",
	),
	TextureAsset(
		asset_id="capoo_mage",
		base_path=ROOT / "resources/texture/capoo_mage.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_mage_stone_eroded_imagegen_green.png"
		),
		output_path=TEXTURE_DIR / "capoo_mage.png",
		columns=4,
		rows=4,
		key_color=(0, 255, 0),
		body_mode="capoo_right",
	),
	TextureAsset(
		asset_id="capoo_rpg",
		base_path=ROOT / "resources/texture/capoo_rpg.png",
		imagegen_path=SOURCE_DIR / "capoo_rpg_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "capoo_rpg.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_smg",
		base_path=ROOT / "resources/texture/capoo_smg.png",
		imagegen_path=SOURCE_DIR / "capoo_smg_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "capoo_smg.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_left",
	),
	TextureAsset(
		asset_id="capoo_sniper",
		base_path=ROOT / "resources/texture/capoo_sniper.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_sniper_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "capoo_sniper.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_left",
	),
	TextureAsset(
		asset_id="capoo_swordsman",
		base_path=ROOT / "resources/texture/capoo_swordsman.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_swordsman_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "capoo_swordsman.png",
		columns=4,
		rows=4,
		key_color=(255, 0, 255),
		body_mode="capoo_left",
	),
	TextureAsset(
		asset_id="yuanshi_insect",
		base_path=ROOT / "resources/texture/源石虫.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect.png",
		columns=3,
		rows=6,
		key_color=(255, 0, 255),
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="yuanshi_insect_fire_ranged",
		base_path=ROOT / "resources/texture/yuanshi_insect_fire_ranged.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_fire_ranged_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_fire_ranged.png",
		columns=10,
		rows=1,
		key_color=(255, 0, 255),
		body_mode="yuanshi",
		generated_columns=5,
		generated_rows=2,
		allow_empty_frames=(8, 9),
	),
	TextureAsset(
		asset_id="yuanshi_insect_green_shell",
		base_path=ROOT / "resources/texture/yuanshi_insect_green_shell.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_green_shell_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_green_shell.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="yuanshi_insect_guardian",
		base_path=ROOT / "resources/texture/yuanshi_insect_guardian.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_guardian_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_guardian.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="yuanshi_insect_purple_bomber",
		base_path=ROOT / "resources/texture/yuanshi_insect_purple_bomber.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_purple_bomber_stone_eroded_imagegen_green.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_purple_bomber.png",
		columns=3,
		rows=2,
		key_color=(0, 255, 0),
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="slime",
		base_path=ROOT / "resources/texture/slime.png",
		imagegen_path=SOURCE_DIR / "slime_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "slime.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_fire",
		base_path=ROOT / "resources/texture/slime_fire.png",
		imagegen_path=SOURCE_DIR / "slime_fire_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "slime_fire.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_frost",
		base_path=ROOT / "resources/texture/slime_frost.png",
		imagegen_path=SOURCE_DIR / "slime_frost_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "slime_frost.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_golden",
		base_path=ROOT / "resources/texture/slime_golden.png",
		imagegen_path=(
			SOURCE_DIR / "slime_golden_stone_eroded_imagegen_magenta.png"
		),
		output_path=TEXTURE_DIR / "slime_golden.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_green",
		base_path=ROOT / "resources/texture/slime_green.png",
		imagegen_path=SOURCE_DIR / "slime_green_stone_eroded_imagegen_magenta.png",
		output_path=TEXTURE_DIR / "slime_green.png",
		columns=3,
		rows=2,
		key_color=(255, 0, 255),
		body_mode="slime",
	),
)

MIN_STONE_RATIO = 0.020
TARGET_STONE_RATIO = 0.035
MAX_STONE_RATIO = 0.060
CHROMA_DISTANCE = 24
MIN_COLOR_DISTANCE = 0.16
MIN_BASE_SATURATION = 0.12
MIN_STONE_LUMINANCE = 0.12
MAX_STONE_LUMINANCE = 0.90
STONE_BLEND = 0.78


def _remove_edge_connected_chroma(
	image: Image.Image,
	key_color: tuple[int, int, int],
) -> Image.Image:
	array = np.array(image.convert("RGBA"), dtype=np.uint8)
	rgb = array[:, :, :3].astype(np.int16)
	key = np.array(key_color, dtype=np.int16)
	candidate = np.max(np.abs(rgb - key), axis=2) <= CHROMA_DISTANCE
	seeds = np.zeros(candidate.shape, dtype=bool)
	seeds[0, :] = candidate[0, :]
	seeds[-1, :] = candidate[-1, :]
	seeds[:, 0] = candidate[:, 0]
	seeds[:, -1] = candidate[:, -1]
	background = ndimage.binary_propagation(seeds, mask=candidate)
	array[background] = (0, 0, 0, 0)
	return Image.fromarray(array, mode="RGBA")


def _saturation(rgb: np.ndarray) -> np.ndarray:
	maximum = rgb.max(axis=2)
	minimum = rgb.min(axis=2)
	return np.divide(
		maximum - minimum,
		np.maximum(maximum, 1.0),
		out=np.zeros_like(maximum),
		where=maximum > 0.0,
	)


def _luminance(rgb: np.ndarray) -> np.ndarray:
	return (
		rgb[:, :, 0] * 0.2126
		+ rgb[:, :, 1] * 0.7152
		+ rgb[:, :, 2] * 0.0722
	)


def _normalized_color_distance(a: np.ndarray, b: np.ndarray) -> np.ndarray:
	return np.sqrt(np.sum(np.square(a - b), axis=2) / 3.0)


def _body_eligible_mask(
	asset: TextureAsset,
	base_rgb: np.ndarray,
	base_alpha: np.ndarray,
) -> np.ndarray:
	visible = base_alpha > 0
	base_luminance = _luminance(base_rgb)
	if asset.body_mode in ("capoo_left", "capoo_right"):
		body = (
			visible
			& (base_rgb[:, :, 2] - base_rgb[:, :, 0] >= 0.06)
			& (base_rgb[:, :, 1] - base_rgb[:, :, 0] >= 0.025)
			& (base_luminance >= 0.20)
		)
		allowed_body_zone = np.ones(body.shape, dtype=bool)
		for left, top, right, bottom in _frame_rects(asset):
			frame_width = right - left
			frame_height = bottom - top
			y_coordinates, x_coordinates = np.ogrid[:frame_height, :frame_width]
			# The body turns and collapses across attack/death poses.  Keep both
			# outer flanks plus the lower body eligible while the central upper
			# face stays protected; the blue-body color test already excludes
			# weapons, hats, eyes, mouths, and spell VFX.
			allowed_body_zone[top:bottom, left:right] = (
				(x_coordinates <= frame_width * 0.38)
				| (x_coordinates >= frame_width * 0.62)
				| (y_coordinates >= frame_height * 0.68)
			)
		return body & allowed_body_zone
	if asset.body_mode == "slime":
		return visible & (base_luminance >= 0.20)
	if asset.body_mode == "yuanshi":
		if asset.asset_id == "yuanshi_insect_fire_ranged":
			# The crown and projectile accents are live fire, not shell.  Keep
			# their orange/yellow emission intact and place stone on the dark
			# carapace beneath it instead.
			return (
				visible
				& (base_luminance >= 0.08)
				& (base_luminance <= 0.32)
			)
		if asset.asset_id == "yuanshi_insect_guardian":
			# Preserve the guardian's cyan cross and luminous shell seams.
			emissive_cyan = (
				(base_rgb[:, :, 2] >= 0.70)
				& (base_rgb[:, :, 1] >= 0.55)
				& ((base_rgb[:, :, 2] - base_rgb[:, :, 0]) >= 0.10)
			)
			return visible & (base_luminance >= 0.08) & ~emissive_cyan
		base_saturation = _saturation(base_rgb)
		identity_highlight = (
			(base_saturation >= 0.75)
			& (base_luminance >= 0.55)
		)
		return visible & (base_luminance >= 0.10) & ~identity_highlight
	raise ValueError(f"Unsupported body mode: {asset.body_mode}")


def _project_stone_seeds(
	seed_mask: np.ndarray,
	body_eligible: np.ndarray,
	base_rgb: np.ndarray,
	generated_rgb: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
	candidate = np.zeros(seed_mask.shape, dtype=bool)
	stone_colors = np.zeros_like(generated_rgb)
	score = np.zeros(seed_mask.shape, dtype=np.float32)
	for left, top, right, bottom in frame_rects:
		frame_seed = seed_mask[top:bottom, left:right]
		frame_eligible = body_eligible[top:bottom, left:right]
		if not frame_seed.any() or not frame_eligible.any():
			continue
		distance, nearest = ndimage.distance_transform_edt(
			~frame_seed,
			return_indices=True,
		)
		frame_width = right - left
		frame_height = bottom - top
		max_snap_distance = max(2, round(min(frame_width, frame_height) * 0.035))
		frame_candidate = frame_eligible & (distance <= max_snap_distance)
		nearest_y, nearest_x = nearest
		frame_generated = generated_rgb[top:bottom, left:right]
		nearest_colors = frame_generated[nearest_y, nearest_x]
		frame_saturation = _saturation(nearest_colors)
		frame_color_distance = _normalized_color_distance(
			base_rgb[top:bottom, left:right],
			nearest_colors,
		)
		frame_score = (
			(1.0 - frame_saturation) * 0.50
			+ frame_color_distance * 0.35
			+ np.clip(
				nearest_colors[:, :, 0] - nearest_colors[:, :, 2],
				0.0,
				1.0,
			)
			* 0.15
			- np.minimum(distance / max(1.0, float(max_snap_distance)), 1.0)
			* 0.12
		)
		candidate[top:bottom, left:right] = frame_candidate
		stone_colors[top:bottom, left:right] = nearest_colors
		score[top:bottom, left:right] = frame_score
	return candidate, stone_colors, score


def _frame_rects(asset: TextureAsset) -> list[tuple[int, int, int, int]]:
	with Image.open(asset.base_path) as base_image:
		width, height = base_image.size
	return _grid_rects(width, height, asset.columns, asset.rows)


def _grid_rects(
	width: int,
	height: int,
	columns: int,
	rows: int,
) -> list[tuple[int, int, int, int]]:
	return [
		(
			round(column * width / columns),
			round(row * height / rows),
			round((column + 1) * width / columns),
			round((row + 1) * height / rows),
		)
		for row in range(rows)
		for column in range(columns)
	]


def _align_generated_to_base(
	asset: TextureAsset,
	generated: Image.Image,
	base_size: tuple[int, int],
) -> Image.Image:
	generated_columns = asset.generated_columns or asset.columns
	generated_rows = asset.generated_rows or asset.rows
	if generated_columns * generated_rows != asset.columns * asset.rows:
		raise ValueError(f"{asset.asset_id}: generated grid frame count mismatch.")
	generated_rects = _grid_rects(
		generated.width,
		generated.height,
		generated_columns,
		generated_rows,
	)
	base_rects = _grid_rects(
		base_size[0],
		base_size[1],
		asset.columns,
		asset.rows,
	)
	aligned = Image.new("RGBA", base_size, (0, 0, 0, 0))
	for source_rect, target_rect in zip(generated_rects, base_rects):
		target_width = target_rect[2] - target_rect[0]
		target_height = target_rect[3] - target_rect[1]
		cell = generated.crop(source_rect).resize(
			(target_width, target_height),
			Image.Resampling.BOX,
		)
		aligned.alpha_composite(cell, (target_rect[0], target_rect[1]))
	return aligned


def _write_imagegen_reference(asset: TextureAsset) -> Path:
	generated_columns = asset.generated_columns or asset.columns
	generated_rows = asset.generated_rows or asset.rows
	with Image.open(asset.base_path) as base_image:
		base = base_image.convert("RGBA")
	base_rects = _grid_rects(base.width, base.height, asset.columns, asset.rows)
	frame_width = max(rect[2] - rect[0] for rect in base_rects)
	frame_height = max(rect[3] - rect[1] for rect in base_rects)
	reference = Image.new(
		"RGBA",
		(frame_width * generated_columns, frame_height * generated_rows),
		(0, 0, 0, 0),
	)
	for frame_index, rect in enumerate(base_rects):
		cell = base.crop(rect)
		target_x = frame_index % generated_columns * frame_width
		target_y = frame_index // generated_columns * frame_height
		reference.alpha_composite(cell, (target_x, target_y))
	REVIEW_DIR.mkdir(parents=True, exist_ok=True)
	path = REVIEW_DIR / f"{asset.asset_id}_imagegen_reference.png"
	reference.save(path, format="PNG", optimize=True)
	return path


def _rank_stone_pixels(
	candidate: np.ndarray,
	score: np.ndarray,
	visible: np.ndarray,
	body_eligible: np.ndarray,
	frame_rect: tuple[int, int, int, int],
	fallback_anchor: tuple[float, float],
	allow_empty: bool,
) -> np.ndarray:
	left, top, right, bottom = frame_rect
	frame_candidate = candidate[top:bottom, left:right]
	frame_score = score[top:bottom, left:right]
	frame_visible = visible[top:bottom, left:right]
	frame_eligible = body_eligible[top:bottom, left:right]
	visible_count = int(frame_visible.sum())
	if visible_count == 0:
		return candidate

	# Positional drift in an ImageGen edit can place an unchanged gray helmet
	# or outline over a nearby colored source pixel.  True authored stone
	# patches form compact clusters; discard isolated resampling speckles before
	# measuring or ranking the treatment.
	labels, component_count = ndimage.label(
		frame_candidate,
		structure=np.ones((3, 3), dtype=bool),
	)
	minimum_component_size = 2 if visible_count >= 48 else 1
	for component_index in range(1, component_count + 1):
		component = labels == component_index
		if int(component.sum()) < minimum_component_size:
			frame_candidate[component] = False

	minimum_count = max(1, math.ceil(visible_count * MIN_STONE_RATIO))
	target_count = max(minimum_count, round(visible_count * TARGET_STONE_RATIO))
	maximum_count = max(minimum_count, math.floor(visible_count * MAX_STONE_RATIO))
	target_count = min(target_count, maximum_count)
	candidate_count = int(frame_candidate.sum())
	if allow_empty and candidate_count == 0 and not frame_eligible.any():
		return candidate
	eligible_count = int(frame_eligible.sum())
	if eligible_count < minimum_count:
		raise ValueError(
			"Not enough protected body pixels for a readable stone patch in frame "
			f"{frame_rect}: eligible={eligible_count}, visible={visible_count}."
		)
	if candidate_count < target_count:
		# Preserve the ImageGen-authored cluster when present, then grow it
		# only across protected body pixels.  If a pose has no surviving
		# authored seed, borrow the nearest pose's normalized anchor so the
		# erosion does not blink out between animation frames.
		frame_height, frame_width = frame_candidate.shape
		y_coordinates, x_coordinates = np.indices(frame_candidate.shape)
		if candidate_count > 0:
			distance = ndimage.distance_transform_edt(~frame_candidate)
			anchor_distance = distance / max(1.0, float(min(frame_width, frame_height)))
		else:
			anchor_x, anchor_y = fallback_anchor
			normalized_x = (x_coordinates + 0.5) / max(1.0, float(frame_width))
			normalized_y = (y_coordinates + 0.5) / max(1.0, float(frame_height))
			anchor_distance = np.hypot(
				normalized_x - anchor_x,
				normalized_y - anchor_y,
			)
		growth_score = frame_score * 0.20 - anchor_distance
		available = frame_eligible & ~frame_candidate
		coordinates = np.argwhere(available)
		coordinate_scores = growth_score[available]
		order = np.argsort(coordinate_scores)[::-1]
		add_count = min(
			target_count - candidate_count,
			coordinates.shape[0],
		)
		if add_count > 0:
			keep = coordinates[order[:add_count]]
			frame_candidate[keep[:, 0], keep[:, 1]] = True
		candidate_count = int(frame_candidate.sum())
		if candidate_count < minimum_count:
			raise ValueError(
				"Could not grow a readable stone patch in frame "
				f"{frame_rect}: {candidate_count}/{visible_count} pixels."
			)
	if candidate_count <= maximum_count:
		return candidate

	coordinates = np.argwhere(frame_candidate)
	coordinate_scores = frame_score[frame_candidate]
	order = np.argsort(coordinate_scores)[::-1]
	keep = coordinates[order[:target_count]]
	frame_candidate[:, :] = False
	frame_candidate[keep[:, 0], keep[:, 1]] = True
	return candidate


def _fallback_frame_anchor(
	candidate: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
	frame_index: int,
	columns: int,
	body_mode: str,
) -> tuple[float, float]:
	frame_row = frame_index // columns
	choices: list[tuple[int, int, tuple[float, float]]] = []
	for other_index, (left, top, right, bottom) in enumerate(frame_rects):
		frame_candidate = candidate[top:bottom, left:right]
		coordinates = np.argwhere(frame_candidate)
		if coordinates.size == 0:
			continue
		frame_height = max(1, bottom - top)
		frame_width = max(1, right - left)
		anchor = (
			float((coordinates[:, 1] + 0.5).mean() / frame_width),
			float((coordinates[:, 0] + 0.5).mean() / frame_height),
		)
		same_row_penalty = 0 if other_index // columns == frame_row else 1
		choices.append((same_row_penalty, abs(other_index - frame_index), anchor))
	if choices:
		choices.sort(key=lambda choice: (choice[0], choice[1]))
		return choices[0][2]
	if body_mode == "capoo_left":
		return (0.28, 0.66)
	if body_mode == "capoo_right":
		return (0.72, 0.66)
	if body_mode == "slime":
		return (0.28, 0.68)
	return (0.68, 0.62)


def _build_texture(asset: TextureAsset) -> dict[str, object]:
	with Image.open(asset.base_path) as base_image:
		base = base_image.convert("RGBA")
	with Image.open(asset.imagegen_path) as generated_image:
		generated = _remove_edge_connected_chroma(
			generated_image,
			asset.key_color,
		)

	# BOX is used only to measure ImageGen's high-resolution treatment.  The
	# canonical base image supplies every output alpha byte and every untouched
	# pixel, so this cannot rescale or soften the runtime silhouette.
	generated = _align_generated_to_base(asset, generated, base.size)
	base_array = np.array(base, dtype=np.uint8)
	generated_array = np.array(generated, dtype=np.uint8)
	base_rgb = base_array[:, :, :3].astype(np.float32) / 255.0
	generated_rgb = generated_array[:, :, :3].astype(np.float32) / 255.0
	base_alpha = base_array[:, :, 3]
	generated_alpha = generated_array[:, :, 3]

	generated_saturation = _saturation(generated_rgb)
	generated_luminance = _luminance(generated_rgb)
	warm_stone = (
		(generated_saturation <= 0.48)
		& ((generated_rgb[:, :, 0] - generated_rgb[:, :, 2]) >= 0.025)
		& ((generated_rgb[:, :, 1] - generated_rgb[:, :, 2]) >= 0.005)
	)
	visible = base_alpha > 0
	stone_seed = (
		(generated_alpha >= 96)
		& warm_stone
		& (generated_luminance >= MIN_STONE_LUMINANCE)
		& (generated_luminance <= MAX_STONE_LUMINANCE)
	)
	body_eligible = _body_eligible_mask(asset, base_rgb, base_alpha)
	frame_rects = _frame_rects(asset)
	stone_candidate, authored_stone_colors, stone_score = _project_stone_seeds(
		stone_seed,
		body_eligible,
		base_rgb,
		generated_rgb,
		frame_rects,
	)
	for frame_index, frame_rect in enumerate(frame_rects):
		fallback_anchor = _fallback_frame_anchor(
			stone_candidate,
			frame_rects,
			frame_index,
			asset.columns,
			asset.body_mode,
		)
		stone_candidate = _rank_stone_pixels(
			stone_candidate,
			stone_score,
			visible,
			body_eligible,
			frame_rect,
			fallback_anchor,
			frame_index in asset.allow_empty_frames,
		)

	result_rgb = base_rgb.copy()
	authored_luminance = np.clip(
		_luminance(authored_stone_colors),
		0.36,
		0.72,
	)
	neutral_stone_colors = np.stack(
		(
			authored_luminance * 1.06,
			authored_luminance * 0.98,
			authored_luminance * 0.84,
		),
		axis=2,
	)
	neutral_stone_colors = np.clip(neutral_stone_colors, 0.0, 1.0)
	stone_colors = (
		neutral_stone_colors * STONE_BLEND + base_rgb * (1.0 - STONE_BLEND)
	)
	result_rgb[stone_candidate] = stone_colors[stone_candidate]
	result_array = base_array.copy()
	result_array[:, :, :3] = np.clip(
		np.rint(result_rgb * 255.0),
		0,
		255,
	).astype(np.uint8)
	result_array[:, :, 3] = base_alpha

	if not np.array_equal(result_array[:, :, 3], base_array[:, :, 3]):
		raise ValueError(f"{asset.asset_id}: alpha contract changed.")
	asset.output_path.parent.mkdir(parents=True, exist_ok=True)
	Image.fromarray(result_array, mode="RGBA").save(
		asset.output_path,
		format="PNG",
		optimize=True,
	)
	changed = np.any(result_array[:, :, :3] != base_array[:, :, :3], axis=2)
	return {
		"asset_id": asset.asset_id,
		"size": base.size,
		"visible_pixels": int(visible.sum()),
		"stone_pixels": int(stone_candidate.sum()),
		"changed_pixels": int(changed.sum()),
		"ratio": float(stone_candidate.sum() / max(1, visible.sum())),
	}


def _write_review_sheet(asset: TextureAsset) -> Path:
	with Image.open(asset.base_path) as base_image:
		base = base_image.convert("RGBA")
	with Image.open(asset.output_path) as output_image:
		output = output_image.convert("RGBA")
	scale = max(1, min(8, 768 // max(1, base.width)))
	preview_size = (base.width * scale, base.height * scale)
	background = (42, 46, 52, 255)
	gap = 16
	board = Image.new(
		"RGBA",
		(preview_size[0] * 2 + gap, preview_size[1]),
		background,
	)
	board.alpha_composite(base.resize(preview_size, Image.Resampling.NEAREST), (0, 0))
	board.alpha_composite(
		output.resize(preview_size, Image.Resampling.NEAREST),
		(preview_size[0] + gap, 0),
	)
	REVIEW_DIR.mkdir(parents=True, exist_ok=True)
	review_path = REVIEW_DIR / f"{asset.asset_id}_before_after.png"
	board.convert("RGB").save(review_path, format="PNG", optimize=True)
	return review_path


def main() -> None:
	parser = argparse.ArgumentParser(
		description="Build stone-eroded enemy sheets without changing animation geometry."
	)
	parser.add_argument(
		"--asset",
		action="append",
		dest="asset_ids",
		help="Build only the named asset; repeat to select multiple assets.",
	)
	parser.add_argument(
		"--review",
		action="store_true",
		help="Also write nearest-neighbor before/after review sheets.",
	)
	parser.add_argument(
		"--prepare-reference",
		metavar="ASSET_ID",
		help="Write a grid-normalized ImageGen reference without building assets.",
	)
	args = parser.parse_args()
	if args.prepare_reference:
		asset = next(
			(candidate for candidate in ASSETS if candidate.asset_id == args.prepare_reference),
			None,
		)
		if asset is None:
			raise ValueError(f"Unknown asset: {args.prepare_reference}")
		print(_write_imagegen_reference(asset))
		return
	selected = [
		asset
		for asset in ASSETS
		if not args.asset_ids or asset.asset_id in args.asset_ids
	]
	if args.asset_ids and len(selected) != len(set(args.asset_ids)):
		known = {asset.asset_id for asset in ASSETS}
		unknown = sorted(set(args.asset_ids) - known)
		raise ValueError(f"Unknown assets: {unknown}")
	for asset in selected:
		if not asset.imagegen_path.is_file():
			raise FileNotFoundError(asset.imagegen_path)
		report = _build_texture(asset)
		print(
			f"{report['asset_id']}: {report['size'][0]}x{report['size'][1]}, "
			f"stone={report['stone_pixels']}/{report['visible_pixels']} "
			f"({report['ratio']:.2%}), changed={report['changed_pixels']}"
		)
		if args.review:
			print(f"review={_write_review_sheet(asset)}")


if __name__ == "__main__":
	main()
