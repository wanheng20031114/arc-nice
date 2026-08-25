#!/usr/bin/env python3
"""Build stone-eroded enemy textures from ImageGen-authored edit sheets.

ImageGen provides the authored placement and colors of the readable stone crust.
The runtime sheet keeps the canonical texture's canvas and alpha bytes exactly,
so every existing AtlasTexture region, margin, anchor, and animation remains
valid.  Only opaque body pixels selected by the generated stone treatment are
recolored.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import heapq
import math
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets/source_images/stone_eroded_enemies"
TEXTURE_DIR = ROOT / "resources/texture/enemy/stone_eroded"
REVIEW_DIR = ROOT / "tmp/stone_eroded_enemies"


@dataclass(frozen=True)
class TextureAsset:
	asset_id: str
	base_path: Path
	imagegen_path: Path
	output_path: Path
	columns: int
	rows: int
	body_mode: str
	generated_columns: int | None = None
	generated_rows: int | None = None
	allow_empty_frames: tuple[int, ...] = ()
	frame_groups: tuple[tuple[int, ...], ...] = ()
	unrestricted_body_frames: tuple[int, ...] = ()
	group_anchor_overrides: tuple[tuple[int, float, float], ...] = ()


ASSETS = (
	TextureAsset(
		asset_id="capoo_ak47",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_ak47.png",
		imagegen_path=SOURCE_DIR / "capoo_ak47_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "capoo_ak47.png",
		columns=4,
		rows=4,
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_knight",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_knight.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_knight_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "capoo_knight.png",
		columns=4,
		rows=4,
		body_mode="capoo_right",
	),
	TextureAsset(
		asset_id="capoo_knight_elite",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_knight_elite.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_knight_elite_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "capoo_knight_elite.png",
		columns=4,
		rows=4,
		# Its large blue shield occupies the right flank; anchor the crust on
		# the exposed left-middle blue body.  All four poses rotate or collapse enough
		# that the generic flank crop would otherwise switch body islands.
		body_mode="capoo_left",
		unrestricted_body_frames=tuple(range(16)),
		group_anchor_overrides=(
			(0, 0.20, 0.55),
			(1, 0.20, 0.55),
			(2, 0.20, 0.55),
			(3, 0.20, 0.55),
		),
	),
	TextureAsset(
		asset_id="capoo_mage",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_mage.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_mage_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "capoo_mage.png",
		columns=4,
		rows=4,
		body_mode="capoo_right",
		# The dissolving body changes silhouette radically; a shared central-
		# lower anchor keeps the crust on the same remaining body mass.
		unrestricted_body_frames=(12, 13, 14, 15),
		group_anchor_overrides=((3, 0.60, 0.72),),
	),
	TextureAsset(
		asset_id="capoo_rpg",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_rpg.png",
		imagegen_path=SOURCE_DIR / "capoo_rpg_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "capoo_rpg.png",
		columns=4,
		rows=4,
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_smg",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_smg.png",
		imagegen_path=SOURCE_DIR / "capoo_smg_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "capoo_smg.png",
		columns=4,
		rows=4,
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_sniper",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_sniper.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_sniper_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "capoo_sniper.png",
		columns=4,
		rows=4,
		body_mode="capoo_left",
		allow_empty_frames=(15,),
	),
	TextureAsset(
		asset_id="capoo_swordsman",
		base_path=ROOT / "resources/texture/enemy/capoo/capoo_swordsman.png",
		imagegen_path=(
			SOURCE_DIR / "capoo_swordsman_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "capoo_swordsman.png",
		columns=4,
		rows=4,
		body_mode="capoo_left",
		# During the spin attack the body rotates under the sword arc.  Use the
		# common torso instead of alternating between disconnected flank pixels.
		unrestricted_body_frames=(8, 9, 10, 11),
		group_anchor_overrides=((2, 0.20, 0.55),),
	),
	TextureAsset(
		asset_id="yuanshi_insect",
		base_path=ROOT / "resources/texture/enemy/yuanshi_insect/源石虫.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect.png",
		columns=3,
		rows=6,
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="yuanshi_insect_fire_ranged",
		base_path=ROOT / "resources/texture/enemy/yuanshi_insect/yuanshi_insect_fire_ranged.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_fire_ranged_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_fire_ranged.png",
		columns=10,
		rows=1,
		body_mode="yuanshi",
		generated_columns=5,
		generated_rows=2,
		allow_empty_frames=(8, 9),
		frame_groups=((0, 1, 2), (3, 4, 5, 6), (7, 8, 9)),
	),
	TextureAsset(
		asset_id="yuanshi_insect_green_shell",
		base_path=ROOT / "resources/texture/enemy/yuanshi_insect/yuanshi_insect_green_shell.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_green_shell_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_green_shell.png",
		columns=3,
		rows=2,
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="yuanshi_insect_guardian",
		base_path=ROOT / "resources/texture/enemy/yuanshi_insect/yuanshi_insect_guardian.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_guardian_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_guardian.png",
		columns=3,
		rows=2,
		body_mode="yuanshi",
		allow_empty_frames=(5,),
	),
	TextureAsset(
		asset_id="yuanshi_insect_purple_bomber",
		base_path=ROOT / "resources/texture/enemy/yuanshi_insect/yuanshi_insect_purple_bomber.png",
		imagegen_path=(
			SOURCE_DIR / "yuanshi_insect_purple_bomber_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "yuanshi_insect_purple_bomber.png",
		columns=3,
		rows=2,
		body_mode="yuanshi",
	),
	TextureAsset(
		asset_id="slime",
		base_path=ROOT / "resources/texture/enemy/slime/slime.png",
		imagegen_path=SOURCE_DIR / "slime_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "slime.png",
		columns=3,
		rows=2,
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_fire",
		base_path=ROOT / "resources/texture/enemy/slime/slime_fire.png",
		imagegen_path=SOURCE_DIR / "slime_fire_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "slime_fire.png",
		columns=3,
		rows=2,
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_frost",
		base_path=ROOT / "resources/texture/enemy/slime/slime_frost.png",
		imagegen_path=SOURCE_DIR / "slime_frost_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "slime_frost.png",
		columns=3,
		rows=2,
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_golden",
		base_path=ROOT / "resources/texture/enemy/slime/slime_golden.png",
		imagegen_path=(
			SOURCE_DIR / "slime_golden_stone_eroded_imagegen_transparent.png"
		),
		output_path=TEXTURE_DIR / "slime_golden.png",
		columns=3,
		rows=2,
		body_mode="slime",
	),
	TextureAsset(
		asset_id="slime_green",
		base_path=ROOT / "resources/texture/enemy/slime/slime_green.png",
		imagegen_path=SOURCE_DIR / "slime_green_stone_eroded_imagegen_transparent.png",
		output_path=TEXTURE_DIR / "slime_green.png",
		columns=3,
		rows=2,
		body_mode="slime",
	),
)

MIN_STONE_RATIO = 0.050
TARGET_STONE_RATIO = 0.075
MAX_STONE_RATIO = 0.100
SMALL_FRAME_VISIBLE_THRESHOLD = 512
SMALL_MIN_STONE_RATIO = 0.075
SMALL_TARGET_STONE_RATIO = 0.110
SMALL_MAX_STONE_RATIO = 0.150
MIN_STONE_LUMINANCE = 0.12
MAX_STONE_LUMINANCE = 0.90
STONE_BLEND = 0.90


def _load_native_transparent_image(source_path: Path) -> Image.Image:
	if not source_path.is_file():
		raise FileNotFoundError(
			f"{source_path} is missing. Provide an ImageGen edit sheet exported "
			"with a native transparent background."
		)
	with Image.open(source_path) as image:
		if "A" not in image.getbands():
			raise ValueError(
				f"{source_path} has no Alpha channel. Regenerate it with a native "
				"transparent background."
			)
		minimum_alpha, maximum_alpha = image.getchannel("A").getextrema()
		if minimum_alpha >= 255 or maximum_alpha == 0:
			raise ValueError(
				f"{source_path} must contain both transparent and visible pixels "
				"in its native Alpha channel."
			)
		array = np.array(image.convert("RGBA"), dtype=np.uint8)
	transparent = array[:, :, 3] == 0
	array[:, :, :3][transparent] = 0
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


def _body_masks(
	asset: TextureAsset,
	base_rgb: np.ndarray,
	base_alpha: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
	visible = base_alpha > 0
	base_luminance = _luminance(base_rgb)
	if asset.body_mode in ("capoo_left", "capoo_right"):
		body = (
			visible
			& (base_rgb[:, :, 0] <= 0.48)
			& (base_rgb[:, :, 2] - base_rgb[:, :, 0] >= 0.06)
			& (base_rgb[:, :, 1] - base_rgb[:, :, 0] >= 0.025)
			& (base_luminance >= 0.20)
		)
		allowed_body_zone = np.ones(body.shape, dtype=bool)
		for left, top, right, bottom in _frame_rects(asset):
			frame_width = right - left
			frame_height = bottom - top
			y_coordinates, x_coordinates = np.ogrid[:frame_height, :frame_width]
			frame_body = body[top:bottom, left:right]
			if asset.asset_id in (
				"capoo_knight",
				"capoo_knight_elite",
				"capoo_swordsman",
			):
				frame_body[:, :] = _largest_component(frame_body)
			body_bbox = _mask_bbox(frame_body)
			if body_bbox is None:
				allowed_body_zone[top:bottom, left:right] = False
				continue
			body_left, body_top, body_right, body_bottom = body_bbox
			body_width = max(1.0, float(body_right - body_left))
			body_height = max(1.0, float(body_bottom - body_top))
			normalized_x = (x_coordinates + 0.5 - body_left) / body_width
			normalized_y = (y_coordinates + 0.5 - body_top) / body_height
			# The body turns and collapses across attack/death poses.  Keep both
			# outer flanks plus the lower body eligible while the central upper
			# face stays protected; the blue-body color test already excludes
			# weapons, hats, eyes, mouths, and spell VFX.
			allowed_body_zone[top:bottom, left:right] = (
				(
					(
						(normalized_x <= 0.38)
						| (normalized_x >= 0.62)
					)
					& (normalized_y >= 0.42)
				)
				| (normalized_y >= 0.68)
			)
		return body, body & allowed_body_zone
	if asset.body_mode == "slime":
		body = visible & (base_luminance >= 0.20)
		allowed_body_zone = np.ones(body.shape, dtype=bool)
		for left, top, right, bottom in _frame_rects(asset):
			frame_width = right - left
			frame_height = bottom - top
			y_coordinates, x_coordinates = np.ogrid[:frame_height, :frame_width]
			# Keep the central face readable.  The stable anchor chooses the left
			# flank; the right/lower zones remain available for collapsed death
			# poses whose silhouette no longer reaches that flank.
			allowed_body_zone[top:bottom, left:right] = (
				(x_coordinates <= frame_width * 0.42)
				| (x_coordinates >= frame_width * 0.72)
				| (y_coordinates >= frame_height * 0.72)
			)
		return body, body & allowed_body_zone
	if asset.body_mode == "yuanshi":
		if asset.asset_id == "yuanshi_insect_fire_ranged":
			# The crown and projectile accents are live fire, not shell.  Keep
			# their orange/yellow emission intact and place stone on the dark
			# carapace beneath it instead.
			emissive_red = _protected_emissive_mask(
				asset,
				np.rint(base_rgb * 255.0).astype(np.uint8),
			)
			reference = (
				visible
				& (base_luminance >= 0.08)
				& (base_luminance <= 0.45)
				& ~emissive_red
			)
			eligible = reference & (base_luminance <= 0.32)
			return reference, eligible
		if asset.asset_id == "yuanshi_insect_guardian":
			# Preserve the guardian's cyan cross and luminous shell seams.
			emissive_cyan = _protected_emissive_mask(
				asset,
				np.rint(base_rgb * 255.0).astype(np.uint8),
			)
			reference = visible & (base_luminance >= 0.08) & ~emissive_cyan
			return reference, reference.copy()
		base_saturation = _saturation(base_rgb)
		identity_highlight = (
			(base_saturation >= 0.75)
			& (base_luminance >= 0.55)
		)
		reference = visible & (base_luminance >= 0.10) & ~identity_highlight
		return reference, reference.copy()
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
	body_reference: np.ndarray,
	body_eligible: np.ndarray,
	frame_rect: tuple[int, int, int, int],
	stable_anchor: tuple[float, float],
	allow_empty: bool,
) -> np.ndarray:
	left, top, right, bottom = frame_rect
	frame_candidate = candidate[top:bottom, left:right]
	frame_score = score[top:bottom, left:right]
	frame_visible = visible[top:bottom, left:right]
	frame_reference = body_reference[top:bottom, left:right]
	frame_eligible = body_eligible[top:bottom, left:right]
	visible_count = int(frame_visible.sum())
	if visible_count == 0:
		return candidate

	if allow_empty:
		# Explicit terminal dissolve/fragment frames keep the canonical artwork.
		# Forcing a handful of stone pixels onto them creates a one-frame flash.
		frame_candidate[:, :] = False
		return candidate
	minimum_ratio, target_ratio, maximum_ratio = _stone_ratios(visible_count)
	minimum_count = max(1, math.ceil(visible_count * minimum_ratio))
	target_count = max(minimum_count, round(visible_count * target_ratio))
	maximum_count = max(minimum_count, math.floor(visible_count * maximum_ratio))
	target_count = min(target_count, maximum_count)
	eligible_count = int(frame_eligible.sum())
	if eligible_count < minimum_count:
		if visible_count < 64 and eligible_count > 0:
			# A few death frames collapse to tiny protected shell fragments.  Keep
			# every eligible pixel rather than recoloring identity-defining glow.
			minimum_count = eligible_count
			target_count = eligible_count
			maximum_count = eligible_count
		else:
			raise ValueError(
				"Not enough protected body pixels for a readable stone patch in frame "
				f"{frame_rect}: eligible={eligible_count}, visible={visible_count}."
			)
	target_count = min(target_count, eligible_count)

	# Every frame in one animation is ranked around one body-local anchor.
	# ImageGen's authored mask and color score remain a small secondary signal,
	# but can no longer move the crust from one side of the creature to another.
	body_bbox = _mask_bbox(frame_reference)
	if body_bbox is None:
		return candidate
	body_left, body_top, body_right, body_bottom = body_bbox
	body_width = max(1.0, float(body_right - body_left))
	body_height = max(1.0, float(body_bottom - body_top))
	y_coordinates, x_coordinates = np.indices(frame_candidate.shape)
	normalized_x = (x_coordinates + 0.5 - body_left) / body_width
	normalized_y = (y_coordinates + 0.5 - body_top) / body_height
	anchor_distance = np.hypot(
		normalized_x - stable_anchor[0],
		normalized_y - stable_anchor[1],
	)

	authored_mask = _largest_component(frame_candidate)
	if authored_mask.any():
		authored_distance = ndimage.distance_transform_edt(~authored_mask)
		authored_distance /= max(1.0, float(min(frame_candidate.shape)))
	else:
		authored_distance = np.ones(frame_candidate.shape, dtype=np.float32)
	selection_score = (
		-anchor_distance
		- authored_distance * 0.035
		+ frame_score * 0.025
	)
	frame_candidate[:, :] = False
	frame_candidate[:, :] = _grow_connected_stone_patch(
		frame_eligible,
		selection_score,
		target_count,
	)
	return candidate


def _grow_connected_stone_patch(
	eligible: np.ndarray,
	selection_score: np.ndarray,
	target_count: int,
) -> np.ndarray:
	"""Grow compact deterministic patches instead of picking disconnected top-N pixels."""
	selected = np.zeros(eligible.shape, dtype=bool)
	labels, component_count = ndimage.label(
		eligible,
		structure=np.ones((3, 3), dtype=bool),
	)
	if component_count == 0 or target_count <= 0:
		return selected

	quantized_score = np.rint(selection_score * 1_000_000.0).astype(np.int64)
	components: list[tuple[int, int, int, int, int]] = []
	for component_label in range(1, component_count + 1):
		component = labels == component_label
		coordinates = np.argwhere(component)
		coordinate_scores = quantized_score[component]
		seed_order = np.lexsort(
			(
				coordinates[:, 1],
				coordinates[:, 0],
				-coordinate_scores,
			)
		)
		seed_y, seed_x = coordinates[seed_order[0]]
		components.append(
			(
				int(coordinate_scores[seed_order[0]]),
				int(coordinates.shape[0]),
				int(seed_y),
				int(seed_x),
				component_label,
			)
		)

	# Prefer the nearest anchored body island that can hold the whole patch.
	# If no island is large enough, start with the largest one so the treatment
	# still reads as stone crust rather than a constellation of flashing pixels.
	large_enough = [component for component in components if component[1] >= target_count]
	if large_enough:
		component_order = sorted(
			large_enough,
			key=lambda component: (
				-component[0],
				component[2],
				component[3],
				component[4],
			),
		)
	else:
		component_order = sorted(
			components,
			key=lambda component: (
				-component[1],
				-component[0],
				component[2],
				component[3],
				component[4],
			),
		)

	remaining = target_count
	for _, component_size, seed_y, seed_x, component_label in component_order:
		if remaining <= 0:
			break
		component_target = min(remaining, component_size)
		component = labels == component_label
		component_selected = _grow_component_from_seed(
			component,
			quantized_score,
			(seed_y, seed_x),
			component_target,
		)
		selected |= component_selected
		remaining -= int(component_selected.sum())
	return selected


def _grow_component_from_seed(
	component: np.ndarray,
	quantized_score: np.ndarray,
	seed: tuple[int, int],
	target_count: int,
) -> np.ndarray:
	selected = np.zeros(component.shape, dtype=bool)
	queued = np.zeros(component.shape, dtype=bool)
	queue: list[tuple[int, int, int]] = []
	selected_count = 0

	def queue_pixel(y: int, x: int) -> None:
		if not component[y, x] or queued[y, x]:
			return
		queued[y, x] = True
		heapq.heappush(queue, (-int(quantized_score[y, x]), y, x))

	queue_pixel(*seed)
	while queue and selected_count < target_count:
		_, y, x = heapq.heappop(queue)
		selected[y, x] = True
		selected_count += 1
		for offset_y in (-1, 0, 1):
			for offset_x in (-1, 0, 1):
				if offset_y == 0 and offset_x == 0:
					continue
				neighbor_y = y + offset_y
				neighbor_x = x + offset_x
				if (
					0 <= neighbor_y < component.shape[0]
					and 0 <= neighbor_x < component.shape[1]
				):
					queue_pixel(neighbor_y, neighbor_x)
	return selected


def _stone_ratios(visible_count: int) -> tuple[float, float, float]:
	if visible_count < SMALL_FRAME_VISIBLE_THRESHOLD:
		return (
			SMALL_MIN_STONE_RATIO,
			SMALL_TARGET_STONE_RATIO,
			SMALL_MAX_STONE_RATIO,
		)
	return (MIN_STONE_RATIO, TARGET_STONE_RATIO, MAX_STONE_RATIO)


def _mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
	coordinates = np.argwhere(mask)
	if coordinates.size == 0:
		return None
	return (
		int(coordinates[:, 1].min()),
		int(coordinates[:, 0].min()),
		int(coordinates[:, 1].max()) + 1,
		int(coordinates[:, 0].max()) + 1,
	)


def _largest_component(mask: np.ndarray) -> np.ndarray:
	labels, component_count = ndimage.label(
		mask,
		structure=np.ones((3, 3), dtype=bool),
	)
	if component_count == 0:
		return np.zeros(mask.shape, dtype=bool)
	sizes = ndimage.sum(mask, labels, range(1, component_count + 1))
	largest_label = int(np.argmax(sizes)) + 1
	return labels == largest_label


def _default_body_anchor(body_mode: str) -> tuple[float, float]:
	if body_mode == "capoo_left":
		return (0.20, 0.72)
	if body_mode == "capoo_right":
		return (0.80, 0.72)
	if body_mode == "slime":
		return (0.22, 0.68)
	return (0.68, 0.58)


def _constrain_anchor_to_body_mode(
	body_mode: str,
	authored_anchor: tuple[float, float],
) -> tuple[float, float]:
	default_anchor = _default_body_anchor(body_mode)
	anchor_y = float(
		np.clip(max(authored_anchor[1], default_anchor[1]), 0.48, 0.72)
	)
	if body_mode in ("capoo_left", "slime"):
		return (min(authored_anchor[0], default_anchor[0]), anchor_y)
	return (max(authored_anchor[0], default_anchor[0]), anchor_y)


def _animation_frame_groups(
	asset: TextureAsset,
	frame_count: int,
) -> tuple[tuple[int, ...], ...]:
	if asset.frame_groups:
		groups = asset.frame_groups
	else:
		groups = tuple(
			tuple(range(row * asset.columns, (row + 1) * asset.columns))
			for row in range(asset.rows)
		)
	indices = [frame_index for group in groups for frame_index in group]
	if sorted(indices) != list(range(frame_count)):
		raise ValueError(f"{asset.asset_id}: animation frame groups are incomplete.")
	return groups


def _body_local_anchor(
	frame_candidate: np.ndarray,
	frame_reference: np.ndarray,
) -> tuple[float, float] | None:
	component = _largest_component(frame_candidate)
	coordinates = np.argwhere(component)
	if coordinates.size == 0:
		return None
	body_bbox = _mask_bbox(frame_reference)
	if body_bbox is None:
		return None
	left, top, right, bottom = body_bbox
	return (
		float((coordinates[:, 1] + 0.5).mean() - left) / max(1, right - left),
		float((coordinates[:, 0] + 0.5).mean() - top) / max(1, bottom - top),
	)


def _stable_group_anchor(
	asset: TextureAsset,
	candidate: np.ndarray,
	body_reference: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
	frame_indices: tuple[int, ...],
) -> tuple[float, float]:
	choices: list[tuple[int, tuple[float, float]]] = []
	for frame_index in frame_indices:
		if frame_index in asset.allow_empty_frames:
			continue
		left, top, right, bottom = frame_rects[frame_index]
		anchor = _body_local_anchor(
			candidate[top:bottom, left:right],
			body_reference[top:bottom, left:right],
		)
		if anchor is not None:
			choices.append((frame_index, anchor))
	if not choices:
		return _default_body_anchor(asset.body_mode)
	# A medoid selects an authored body location that genuinely occurs in one
	# frame instead of averaging two opposing, flickering patches into the face.
	best_choice = min(
		choices,
		key=lambda choice: (
			round(
				sum(
					math.dist(choice[1], other_choice[1])
					for other_choice in choices
				)
				* 1_000_000
			),
			choice[0],
		),
	)
	return best_choice[1]


def _build_temporally_stable_mask(
	asset: TextureAsset,
	candidate: np.ndarray,
	score: np.ndarray,
	visible: np.ndarray,
	body_reference: np.ndarray,
	body_eligible: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
) -> np.ndarray:
	stable = candidate.copy()
	frame_groups = _animation_frame_groups(asset, len(frame_rects))
	anchor_overrides = {
		group_index: (anchor_x, anchor_y)
		for group_index, anchor_x, anchor_y in asset.group_anchor_overrides
	}
	for group_index, frame_indices in enumerate(frame_groups):
		if group_index in anchor_overrides:
			stable_anchor = anchor_overrides[group_index]
		else:
			authored_anchor = _stable_group_anchor(
				asset,
				candidate,
				body_reference,
				frame_rects,
				frame_indices,
			)
			stable_anchor = _constrain_anchor_to_body_mode(
				asset.body_mode,
				authored_anchor,
			)
		for frame_index in frame_indices:
			stable = _rank_stone_pixels(
				stable,
				score,
				visible,
				body_reference,
				body_eligible,
				frame_rects[frame_index],
				stable_anchor,
				frame_index in asset.allow_empty_frames,
			)
	return stable


def _validate_stone_mask_geometry(
	asset: TextureAsset,
	stone_mask: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
) -> None:
	for frame_index, (left, top, right, bottom) in enumerate(frame_rects):
		frame_mask = stone_mask[top:bottom, left:right]
		stone_count = int(frame_mask.sum())
		if frame_index in asset.allow_empty_frames:
			if stone_count != 0:
				raise ValueError(
					f"{asset.asset_id} frame {frame_index}: terminal frame must be unchanged."
				)
			continue
		if stone_count == 0:
			continue
		labels, component_count = ndimage.label(
			frame_mask,
			structure=np.ones((3, 3), dtype=bool),
		)
		component_sizes = ndimage.sum(
			frame_mask,
			labels,
			range(1, component_count + 1),
		)
		largest_share = float(np.max(component_sizes)) / stone_count
		if component_count > 6 or largest_share < 0.55:
			raise ValueError(
				f"{asset.asset_id} frame {frame_index}: fragmented stone patch "
				f"({component_count} components, largest={largest_share:.1%})."
			)


def _protected_emissive_mask(
	asset: TextureAsset,
	base_rgb: np.ndarray,
) -> np.ndarray:
	if asset.asset_id == "yuanshi_insect_fire_ranged":
		return base_rgb[:, :, 0] >= 188
	if asset.asset_id == "yuanshi_insect_guardian":
		return (
			(base_rgb[:, :, 2] >= 178)
			& (base_rgb[:, :, 1] >= 140)
			& (
				base_rgb[:, :, 2].astype(np.int16)
				- base_rgb[:, :, 0].astype(np.int16)
				>= 25
			)
		)
	return np.zeros(base_rgb.shape[:2], dtype=bool)


def _stone_palette(
	authored_stone_colors: np.ndarray,
	authored_mask: np.ndarray,
) -> np.ndarray:
	authored_luminance = _luminance(authored_stone_colors)
	valid = authored_mask & np.any(authored_stone_colors > 0.0, axis=2)
	if valid.any():
		middle = float(np.median(authored_luminance[valid]))
	else:
		middle = 0.48
	middle = float(np.clip(middle, 0.42, 0.58))
	luminances = np.array(
		(
			max(0.30, middle - 0.13),
			middle,
			min(0.74, middle + 0.17),
		),
		dtype=np.float32,
	)
	palette = np.stack(
		(
			luminances * 1.06,
			luminances * 0.98,
			luminances * 0.84,
		),
		axis=1,
	)
	return np.clip(palette, 0.0, 1.0)


def _stone_color_field(
	stone_mask: np.ndarray,
	frame_rects: list[tuple[int, int, int, int]],
	palette: np.ndarray,
) -> np.ndarray:
	colors = np.zeros((*stone_mask.shape, 3), dtype=np.float32)
	for left, top, right, bottom in frame_rects:
		frame_mask = stone_mask[top:bottom, left:right]
		if not frame_mask.any():
			continue
		frame_colors = colors[top:bottom, left:right]
		frame_colors[frame_mask] = palette[1]
		interior = ndimage.binary_erosion(
			frame_mask,
			structure=np.ones((3, 3), dtype=bool),
			border_value=0,
		)
		boundary = frame_mask & ~interior
		frame_colors[boundary] = palette[0]

		# One stable upper-left-facing highlight per small cluster (and a few on
		# large Capoo patches) keeps the treatment visibly rocky without using
		# frame-specific ImageGen colors that would shimmer during playback.
		highlight_pool = interior if interior.any() else frame_mask
		coordinates = np.argwhere(highlight_pool)
		distance_inside = ndimage.distance_transform_edt(frame_mask)
		frame_height, frame_width = frame_mask.shape
		highlight_score = (
			distance_inside[highlight_pool]
			- coordinates[:, 0] / max(1.0, float(frame_height)) * 0.18
			- coordinates[:, 1] / max(1.0, float(frame_width)) * 0.12
		)
		order = np.lexsort(
			(
				coordinates[:, 1],
				coordinates[:, 0],
				-highlight_score,
			)
		)
		highlight_count = min(
			coordinates.shape[0],
			max(1, round(int(frame_mask.sum()) * 0.08)),
		)
		highlights = coordinates[order[:highlight_count]]
		frame_colors[highlights[:, 0], highlights[:, 1]] = palette[2]
	return colors


def _build_texture(asset: TextureAsset) -> dict[str, object]:
	with Image.open(asset.base_path) as base_image:
		base = base_image.convert("RGBA")
	generated = _load_native_transparent_image(asset.imagegen_path)

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
	body_reference, body_eligible = _body_masks(asset, base_rgb, base_alpha)
	frame_rects = _frame_rects(asset)
	for frame_index in asset.unrestricted_body_frames:
		left, top, right, bottom = frame_rects[frame_index]
		body_eligible[top:bottom, left:right] = body_reference[
			top:bottom,
			left:right,
		]
	stone_candidate, authored_stone_colors, stone_score = _project_stone_seeds(
		stone_seed,
		body_eligible,
		base_rgb,
		generated_rgb,
		frame_rects,
	)
	authored_stone_mask = stone_candidate.copy()
	stone_candidate = _build_temporally_stable_mask(
		asset,
		stone_candidate,
		stone_score,
		visible,
		body_reference,
		body_eligible,
		frame_rects,
	)
	_validate_stone_mask_geometry(asset, stone_candidate, frame_rects)

	result_rgb = base_rgb.copy()
	palette = _stone_palette(
		authored_stone_colors,
		authored_stone_mask,
	)
	neutral_stone_colors = _stone_color_field(
		stone_candidate,
		frame_rects,
		palette,
	)
	stone_colors = (
		neutral_stone_colors * STONE_BLEND + base_rgb * (1.0 - STONE_BLEND)
	)
	# A gray or armored source pixel can otherwise satisfy the area contract
	# while remaining visually unchanged.  Choose the more contrasting endpoint
	# of the same authored palette when the intended stone pixel is too subtle.
	stone_delta = np.max(np.abs(stone_colors - base_rgb), axis=2)
	weak_mask = stone_candidate & (stone_delta < (28.0 / 255.0))
	if weak_mask.any():
		dark_option = palette[0] * STONE_BLEND + base_rgb * (1.0 - STONE_BLEND)
		light_option = palette[2] * STONE_BLEND + base_rgb * (1.0 - STONE_BLEND)
		dark_delta = np.max(np.abs(dark_option - base_rgb), axis=2)
		light_delta = np.max(np.abs(light_option - base_rgb), axis=2)
		use_light = weak_mask & (light_delta > dark_delta)
		use_dark = weak_mask & ~use_light
		stone_colors[use_light] = light_option[use_light]
		stone_colors[use_dark] = dark_option[use_dark]
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
	protected_emissive = _protected_emissive_mask(asset, base_array[:, :, :3])
	if not np.array_equal(
		result_array[:, :, :3][protected_emissive],
		base_array[:, :, :3][protected_emissive],
	):
		raise ValueError(f"{asset.asset_id}: protected emissive identity changed.")
	asset.output_path.parent.mkdir(parents=True, exist_ok=True)
	Image.fromarray(result_array, mode="RGBA").save(
		asset.output_path,
		format="PNG",
		optimize=True,
	)
	changed = np.any(result_array[:, :, :3] != base_array[:, :, :3], axis=2)
	if not np.array_equal(changed, stone_candidate):
		raise ValueError(f"{asset.asset_id}: selected stone pixels must visibly change.")
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
			raise FileNotFoundError(
				f"{asset.imagegen_path} is missing. Provide an ImageGen edit sheet "
				"with a native transparent background."
			)
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
