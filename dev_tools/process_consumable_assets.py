#!/usr/bin/env python3
"""Deterministically build and audit the twelve new consumable icons.

Each built-in ImageGen master is retained beside its processing artifacts.  A
flat magenta background is removed without changing retained foreground RGB,
one pixel is sampled per *measured* logical source cell, and the result is
centered on a transparent 32x32 canvas.  The pipeline intentionally has no
unsafe resize or palette-reduction escape hatch: an unreliable or oversized
source must be regenerated instead of being hidden behind destructive
downscaling.

Examples:
  python dev_tools/process_consumable_assets.py --list-plan
  python dev_tools/process_consumable_assets.py --asset skill_charge_battery
  python dev_tools/process_consumable_assets.py
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path

from PIL import Image

from plant_pixel_asset_pipeline import (
    NormalizedSubject,
    TRANSPARENT,
    _key_magenta_source,
    clean_transparency,
    normalize_imagegen_subject,
    portable_path,
    source_audit,
)
from pixel_grid_analyzer import analyze_image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "dev_assets/source_images/consumables"
OUTPUT_ROOT = ROOT / "resources/texture/consumables"
PROMPT_MANIFEST_PATH = SOURCE_ROOT / "imagegen_prompt_manifest.json"
CANVAS_SIZE = (32, 32)
MIN_SUBJECT_SIZE = (8, 8)
CHROMA_KEY = "#FF00FF"
TRANSPARENT_BORDER = 1
KEY_REMAINDER_TOLERANCE = 12


@dataclass(frozen=True)
class AssetSpec:
    slug: str
    display_name: str
    tier: str
    shape: str
    max_subject_size: tuple[int, int]
    approved_source_filename: str | None = None
    rejected_sources: tuple[tuple[str, str], ...] = ()
    reviewed_logical_size: tuple[int, int] | None = None
    review_note: str = ""

    @property
    def source_directory(self) -> Path:
        return SOURCE_ROOT / self.slug

    @property
    def source_path(self) -> Path:
        filename = (
            self.approved_source_filename
            if self.approved_source_filename is not None
            else f"{self.slug}_imagegen_magenta.png"
        )
        return self.source_directory / filename

    @property
    def alpha_path(self) -> Path:
        return self.source_directory / f"{self.slug}_alpha.png"

    @property
    def logical_preview_path(self) -> Path:
        return self.source_directory / f"{self.slug}_logical_preview.png"

    @property
    def audit_path(self) -> Path:
        return self.source_directory / f"{self.slug}_asset_audit.json"

    @property
    def output_path(self) -> Path:
        return OUTPUT_ROOT / f"{self.slug}.png"

    @property
    def atlas_path(self) -> Path:
        return ROOT / "resources/atlas" / f"{self.slug}.tres"

    @property
    def config_path(self) -> Path:
        return ROOT / "resources/config/consumables" / f"{self.slug}.tres"


# Small/large pairs intentionally use the same 20-ish/25-ish width language as
# the existing healing and rock bottles.  Every cap remains <=30 on both axes,
# which guarantees at least one fully transparent pixel around a centered icon.
ASSETS = (
    AssetSpec(
        "skill_charge_battery",
        "蓝晶技力电池",
        "low",
        "small_battery",
        (22, 30),
        "skill_charge_battery_imagegen_magenta_v2.png",
        ((
            "skill_charge_battery_imagegen_magenta.png",
            "rejected: unreliable primary grid (confidence 0.388) and approximately 16x38 logical subject",
        ),),
    ),
    AssetSpec(
        "large_skill_charge_battery",
        "大型蓝晶技力电池",
        "medium",
        "large_battery",
        (27, 30),
        "large_skill_charge_battery_imagegen_magenta_v2.png",
        ((
            "large_skill_charge_battery_imagegen_magenta.png",
            "rejected: measured 28x51 logical subject exceeds the lossless 27x30 contract",
        ),),
    ),
    AssetSpec(
        "magic_resistance_potion",
        "紫晶法抗药水",
        "low",
        "small_bottle",
        (22, 30),
        "magic_resistance_potion_imagegen_magenta_v2.png",
        ((
            "magic_resistance_potion_imagegen_magenta.png",
            "rejected: measured 32x54 logical subject exceeds the lossless 22x30 contract",
        ),),
    ),
    AssetSpec(
        "large_magic_resistance_potion",
        "大型紫晶法抗药水",
        "medium",
        "large_bottle",
        (27, 30),
        "large_magic_resistance_potion_imagegen_magenta_v2.png",
        ((
            "large_magic_resistance_potion_imagegen_magenta.png",
            "rejected: independent square-grid audit measured approximately 36x42 logical cells",
        ),),
    ),
    AssetSpec("regeneration_potion", "凝胶再生剂", "low", "small_bottle", (22, 30)),
    AssetSpec(
        "large_regeneration_potion",
        "大型凝胶再生剂",
        "medium",
        "large_bottle",
        (27, 30),
        "large_regeneration_potion_imagegen_magenta_v2.png",
        ((
            "large_regeneration_potion_imagegen_magenta.png",
            "rejected: measured 26x33 logical subject exceeds the lossless 27x30 contract",
        ),),
    ),
    AssetSpec("guardian_mixture", "守护合剂", "medium", "single_bottle", (24, 30)),
    AssetSpec(
        "battle_spirit_potion",
        "战意药水",
        "medium",
        "single_bottle",
        (24, 30),
        "battle_spirit_potion_imagegen_magenta_v2.png",
        ((
            "battle_spirit_potion_imagegen_magenta.png",
            "rejected: measured 19x34 logical subject exceeds the lossless 24x30 contract",
        ),),
    ),
    AssetSpec("focus_potion", "专注药水", "medium", "single_bottle", (24, 30)),
    AssetSpec("windwalk_potion", "风行药水", "medium", "single_bottle", (24, 30)),
    AssetSpec("phantom_potion", "幻影药剂", "medium", "single_bottle", (24, 30)),
    AssetSpec(
        "void_battery",
        "虚空电池",
        "high",
        "battery",
        (28, 30),
        reviewed_logical_size=(18, 26),
        review_note=(
            "Manual per-source review accepted the 18x26 grid. The automatic "
            "analyzer reported confidence 0.574 with near-square periods "
            "30.7x30.2 physical pixels; the low score is caused by a local "
            "14px Y-axis harmonic, not a continuous or ungridded illustration."
        ),
    ),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _visible_colors(image: Image.Image) -> set[tuple[int, int, int]]:
    return {
        (red, green, blue)
        for red, green, blue, alpha in image.convert("RGBA").getdata()
        if alpha > 0
    }


def _has_near_key_foreground(image: Image.Image) -> bool:
    for red, green, blue, alpha in image.convert("RGBA").getdata():
        if alpha == 0:
            continue
        if max(abs(red - 255), abs(green), abs(blue - 255)) <= KEY_REMAINDER_TOLERANCE:
            return True
    return False


def _center_on_canvas(subject: Image.Image) -> tuple[Image.Image, tuple[int, int]]:
    if subject.width > 30 or subject.height > 30:
        raise RuntimeError(
            f"Logical subject {subject.size} cannot retain a one-pixel border on {CANVAS_SIZE}"
        )
    origin = (
        (CANVAS_SIZE[0] - subject.width) // 2,
        (CANVAS_SIZE[1] - subject.height) // 2,
    )
    canvas = Image.new("RGBA", CANVAS_SIZE, TRANSPARENT)
    canvas.alpha_composite(subject, origin)
    return clean_transparency(canvas), origin


def _nearest_upscale_to_contract(
    logical: Image.Image,
    max_subject_size: tuple[int, int],
) -> tuple[Image.Image, float]:
    """Enlarge a sparse logical sprite for a readable 32px inventory bbox.

    This operation never shrinks, smooths, quantizes, or invents colors.  The
    untouched measured-grid result remains saved as ``logical_preview``; the
    production texture only repeats those exact cells with nearest sampling.
    """
    max_width, max_height = max_subject_size
    scale = min(max_width / logical.width, max_height / logical.height)
    if scale < 1.0:
        raise RuntimeError(
            f"Logical subject {logical.size} exceeds production cap {max_subject_size}"
        )
    target_size = (
        max(logical.width, min(max_width, round(logical.width * scale))),
        max(logical.height, min(max_height, round(logical.height * scale))),
    )
    if target_size == logical.size:
        return logical.copy(), 1.0
    return (
        clean_transparency(
            logical.resize(target_size, Image.Resampling.NEAREST)
        ),
        scale,
    )


def _audit_output(
    output: Image.Image,
    subject: Image.Image,
    paste_origin: tuple[int, int],
) -> tuple[dict, tuple[int, int, int, int]]:
    rgba = output.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise RuntimeError("Output contains no visible subject")
    alpha_values = sorted(set(rgba.getchannel("A").getdata()))
    placed = rgba.crop(
        (
            paste_origin[0],
            paste_origin[1],
            paste_origin[0] + subject.width,
            paste_origin[1] + subject.height,
        )
    )
    checks = {
        "canvas_32x32": rgba.size == CANVAS_SIZE,
        "one_pixel_transparent_border": (
            bbox[0] >= TRANSPARENT_BORDER
            and bbox[1] >= TRANSPARENT_BORDER
            and bbox[2] <= CANVAS_SIZE[0] - TRANSPARENT_BORDER
            and bbox[3] <= CANVAS_SIZE[1] - TRANSPARENT_BORDER
        ),
        "binary_alpha": set(alpha_values).issubset({0, 255}),
        "transparent_rgb_clean": all(
            alpha > 0 or (red, green, blue) == (0, 0, 0)
            for red, green, blue, alpha in rgba.getdata()
        ),
        "logical_pixels_preserved": placed.tobytes() == subject.tobytes(),
        "no_near_chroma_key_foreground": not _has_near_key_foreground(rgba),
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise RuntimeError("; ".join(failures))
    return checks, bbox


def _save_lossless(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True, compress_level=9)


def _prompt_record(spec: AssetSpec) -> dict:
    if not PROMPT_MANIFEST_PATH.is_file():
        return {
            "status": "missing",
            "required_path": portable_path(PROMPT_MANIFEST_PATH),
            "note": "Exact ImageGen prompt must be copied from the original generation call; never reconstruct it from the image.",
        }
    manifest = json.loads(PROMPT_MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = manifest.get("assets", manifest.get("items", []))
    entry = next(
        (
            candidate
            for candidate in entries
            if isinstance(candidate, dict)
            and candidate.get(
                "slug",
                candidate.get("id", candidate.get("stem")),
            )
            == spec.slug
        ),
        None,
    )
    expected_source = portable_path(spec.source_path.relative_to(SOURCE_ROOT))
    selected_source = entry.get("selected_source") if entry is not None else None
    prompt_lines = entry.get("prompt_lines", []) if entry is not None else []
    prompt_text = "\n".join(str(line) for line in prompt_lines)
    return {
        "status": "linked" if entry is not None else "asset_entry_missing",
        "path": portable_path(PROMPT_MANIFEST_PATH),
        "sha256": _sha256(PROMPT_MANIFEST_PATH),
        "asset_entry_found": entry is not None,
        "selected_source": selected_source,
        "selected_source_matches": selected_source == expected_source,
        "referenced_images": entry.get("referenced_images", []) if entry is not None else [],
        "prompt_lines": prompt_lines,
        "prompt_sha256": hashlib.sha256(prompt_text.encode("utf-8")).hexdigest(),
    }


def _normalize_source(spec: AssetSpec, keyed: Image.Image) -> NormalizedSubject:
    if spec.reviewed_logical_size is None:
        return normalize_imagegen_subject(
            spec.source_path,
            max_subject_size=spec.max_subject_size,
            fit_oversized=False,
        )

    analysis = analyze_image(keyed)
    bbox_dict = analysis["subject_bbox"]
    bbox = (
        int(bbox_dict["left"]),
        int(bbox_dict["top"]),
        int(bbox_dict["right"]),
        int(bbox_dict["bottom"]),
    )
    logical_width, logical_height = spec.reviewed_logical_size
    if (
        logical_width > spec.max_subject_size[0]
        or logical_height > spec.max_subject_size[1]
    ):
        raise RuntimeError(
            f"Reviewed grid {spec.reviewed_logical_size} exceeds {spec.max_subject_size}"
        )
    cell_width = (bbox[2] - bbox[0]) / logical_width
    cell_height = (bbox[3] - bbox[1]) / logical_height
    cell_ratio = max(cell_width, cell_height) / min(cell_width, cell_height)
    if cell_ratio > 1.10:
        raise RuntimeError(
            f"Reviewed grid cells are not near-square for {spec.slug}: "
            f"{cell_width:.3f}x{cell_height:.3f}"
        )
    subject = clean_transparency(
        keyed.crop(bbox).resize(
            spec.reviewed_logical_size,
            Image.Resampling.NEAREST,
        )
    )
    reviewed_analysis = {
        **analysis,
        "manual_review": {
            "approved_logical_size": list(spec.reviewed_logical_size),
            "cell_width": round(cell_width, 3),
            "cell_height": round(cell_height, 3),
            "cell_aspect_ratio": round(cell_ratio, 3),
            "note": spec.review_note,
            "global_unsafe_override_enabled": False,
        },
    }
    return NormalizedSubject(
        image=subject,
        source_path=spec.source_path,
        source_analysis=reviewed_analysis,
        logical_size=subject.size,
        detected_logical_size=spec.reviewed_logical_size,
        logical_fit_scale=1.0,
        normalization_mode="manual_reviewed_grid_center_sample",
    )


def _build_asset(spec: AssetSpec) -> dict:
    if not spec.source_path.is_file():
        raise FileNotFoundError(spec.source_path)

    prompt_record = _prompt_record(spec)
    if PROMPT_MANIFEST_PATH.is_file() and (
        prompt_record["status"] != "linked"
        or not prompt_record["selected_source_matches"]
        or not prompt_record["prompt_lines"]
    ):
        raise RuntimeError(
            f"Prompt manifest is incomplete or selects another source for {spec.slug}: "
            f"{prompt_record}"
        )

    keyed = _key_magenta_source(spec.source_path)
    normalized = _normalize_source(spec, keyed)
    logical = clean_transparency(normalized.image)
    if logical.width < MIN_SUBJECT_SIZE[0] or logical.height < MIN_SUBJECT_SIZE[1]:
        raise RuntimeError(
            f"Logical subject {logical.size} is too small to remain legible: {spec.slug}"
        )
    if normalized.logical_fit_scale != 1.0:
        raise RuntimeError(
            f"Logical fit would be destructive for {spec.slug}: "
            f"scale={normalized.logical_fit_scale}"
        )

    production_subject, production_upscale = _nearest_upscale_to_contract(
        logical,
        spec.max_subject_size,
    )
    if _visible_colors(production_subject) != _visible_colors(logical):
        raise RuntimeError(
            f"Nearest production upscale changed the authored palette: {spec.slug}"
        )
    output, paste_origin = _center_on_canvas(production_subject)
    checks, output_bbox = _audit_output(
        output,
        production_subject,
        paste_origin,
    )

    _save_lossless(keyed, spec.alpha_path)
    _save_lossless(logical, spec.logical_preview_path)
    _save_lossless(output, spec.output_path)

    report = {
        "schema_version": 1,
        "asset": spec.slug,
        "display_name": spec.display_name,
        "status": "passed",
        "tier": spec.tier,
        "shape": spec.shape,
        "chroma_key": CHROMA_KEY,
        "pipeline": [
            "built-in ImageGen, one distinct source per item",
            "flat #FF00FF border-connected chroma-key extraction",
            "retained foreground RGB preserved without palette quantization",
            "strict pixel-grid analysis with no unsafe compression override",
            "one final pixel center-sampled per measured logical cell",
            "nearest-neighbour upscale only when needed for a readable inventory bbox",
            "centered placement on a transparent 32x32 RGBA canvas",
            "binary alpha, clean transparent RGB, and one-pixel border audit",
            "lossless PNG encoding",
        ],
        "commands": {
            "build": f"python dev_tools/process_consumable_assets.py --asset {spec.slug}",
            "pipeline_smoke": "python dev_tools/consumable_asset_pipeline_smoke_test.py",
        },
        "processing_parameters": {
            "background_remover": "connected_background_remover.remove_connected_background",
            "rgb_tolerance": 72,
            "hue_tolerance": 0.035,
            "expansion_radius": 12,
            "hard_alpha": True,
            "transparent_rgb": [0, 0, 0],
            "logical_sampler": "Pillow nearest center sample",
            "production_upscale": "nearest only; shrinking forbidden",
            "palette_quantization": "none",
            "png": "optimize=true, compress_level=9 (lossless)",
        },
        "prompt_record": prompt_record,
        "paths": {
            "source_master": portable_path(spec.source_path),
            "alpha_source": portable_path(spec.alpha_path),
            "logical_preview": portable_path(spec.logical_preview_path),
            "production_texture": portable_path(spec.output_path),
            "atlas": portable_path(spec.atlas_path),
            "config": portable_path(spec.config_path),
        },
        "source_selection": {
            "approved": {
                "path": portable_path(spec.source_path),
                "sha256": _sha256(spec.source_path),
            },
            "rejected": [
                {
                    "path": portable_path(spec.source_directory / filename),
                    "sha256": _sha256(spec.source_directory / filename),
                    "reason": reason,
                }
                for filename, reason in spec.rejected_sources
                if (spec.source_directory / filename).is_file()
            ],
            "manual_review_note": spec.review_note,
            "global_unsafe_override_enabled": False,
        },
        "hashes": {
            "source_master_sha256": _sha256(spec.source_path),
            "alpha_source_sha256": _sha256(spec.alpha_path),
            "logical_preview_sha256": _sha256(spec.logical_preview_path),
            "production_texture_sha256": _sha256(spec.output_path),
            "processing_script_sha256": _sha256(Path(__file__)),
        },
        "source": source_audit(normalized),
        "max_subject_size": list(spec.max_subject_size),
        "logical_subject_size": list(logical.size),
        "production_subject_size": list(production_subject.size),
        "production_upscale": round(production_upscale, 6),
        "paste_origin": list(paste_origin),
        "output_bbox_exclusive": list(output_bbox),
        "visible_color_count": len(_visible_colors(output)),
        "alpha_values": sorted(set(output.getchannel("A").getdata())),
        "checks": checks,
    }
    spec.audit_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def _build_contact_previews() -> tuple[Path, Path]:
    margin = 2
    gap = 2
    columns = 6
    rows = 2
    logical = Image.new(
        "RGBA",
        (
            margin * 2 + columns * CANVAS_SIZE[0] + (columns - 1) * gap,
            margin * 2 + rows * CANVAS_SIZE[1] + (rows - 1) * gap,
        ),
        (30, 34, 38, 255),
    )
    for index, spec in enumerate(ASSETS):
        with Image.open(spec.output_path) as opened:
            icon = opened.convert("RGBA")
        x = margin + (index % columns) * (CANVAS_SIZE[0] + gap)
        y = margin + (index // columns) * (CANVAS_SIZE[1] + gap)
        logical.alpha_composite(icon, (x, y))

    preview_1x = SOURCE_ROOT / "new_consumables_contact_preview_1x.png"
    preview_8x = SOURCE_ROOT / "new_consumables_contact_preview_8x.png"
    _save_lossless(logical, preview_1x)
    _save_lossless(
        logical.resize(
            (logical.width * 8, logical.height * 8),
            Image.Resampling.NEAREST,
        ),
        preview_8x,
    )
    return preview_1x, preview_8x


def _write_global_audit_if_complete() -> Path | None:
    if not all(spec.audit_path.is_file() and spec.output_path.is_file() for spec in ASSETS):
        return None
    reports = [
        json.loads(spec.audit_path.read_text(encoding="utf-8"))
        for spec in ASSETS
    ]
    preview_1x, preview_8x = _build_contact_previews()
    report = {
        "schema_version": 1,
        "status": "passed",
        "asset_count": len(ASSETS),
        "contract": {
            "canvas": [32, 32],
            "mode": "RGBA",
            "alpha_values": [0, 255],
            "minimum_transparent_border": 1,
            "chroma_key": CHROMA_KEY,
            "palette_quantization": "none",
            "resampling": "one center sample per verified logical source cell",
            "png_encoding": "lossless",
            "godot_texture_filter": "project default nearest",
        },
        "prompt_manifest": (
            {
                "status": "linked",
                "path": portable_path(PROMPT_MANIFEST_PATH),
                "sha256": _sha256(PROMPT_MANIFEST_PATH),
            }
            if PROMPT_MANIFEST_PATH.is_file()
            else {
                "status": "missing",
                "required_path": portable_path(PROMPT_MANIFEST_PATH),
            }
        ),
        "contact_previews": {
            "1x": portable_path(preview_1x),
            "8x_nearest": portable_path(preview_8x),
        },
        "assets": reports,
    }
    path = SOURCE_ROOT / "new_consumable_asset_audit.json"
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def plan_payload() -> dict:
    return {
        "schema_version": 1,
        "asset_count": len(ASSETS),
        "contract": {
            "source_chroma_key": CHROMA_KEY,
            "production_canvas": [32, 32],
            "production_mode": "RGBA",
            "alpha_values": [0, 255],
            "minimum_transparent_border": TRANSPARENT_BORDER,
            "palette_quantization": "none",
            "unsafe_grid_compression": False,
        },
        "assets": [
            {
                **asdict(spec),
                "source": portable_path(spec.source_path),
                "alpha": portable_path(spec.alpha_path),
                "logical_preview": portable_path(spec.logical_preview_path),
                "production_texture": portable_path(spec.output_path),
                "atlas": portable_path(spec.atlas_path),
                "config": portable_path(spec.config_path),
            }
            for spec in ASSETS
        ],
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build strict 32x32 consumable icons from approved ImageGen masters"
    )
    parser.add_argument(
        "--asset",
        action="append",
        choices=[spec.slug for spec in ASSETS],
        help="Build only one named asset; repeat to build several",
    )
    parser.add_argument(
        "--list-plan",
        action="store_true",
        help="Print the exact file/size contract without requiring generated sources",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    if args.list_plan:
        print(json.dumps(plan_payload(), ensure_ascii=False, indent=2))
        return

    requested = set(args.asset or [])
    specs = [spec for spec in ASSETS if not requested or spec.slug in requested]
    reports = [_build_asset(spec) for spec in specs]
    for report in reports:
        print(
            f"Built {report['asset']}: "
            f"{report['logical_subject_size']} -> 32x32, "
            f"{report['hashes']['production_texture_sha256']}"
        )
    global_audit = _write_global_audit_if_complete()
    if global_audit is not None:
        print(f"Global audit: {global_audit}")


if __name__ == "__main__":
    main()
