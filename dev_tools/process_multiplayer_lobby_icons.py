#!/usr/bin/env python3
"""Split and normalize the generated multiplayer-lobby icon atlas."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image


ICON_NAMES = (
    "mode_standard",
    "mode_tower_defense",
    "mode_test_p1",
    "mode_test_p2",
    "network_public",
    "network_lan",
    "action_create_room",
    "action_start_game",
)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("atlas", type=Path, help="Transparent 4x2 atlas PNG.")
    parser.add_argument("output_dir", type=Path, help="Runtime icon directory.")
    parser.add_argument(
        "--source-crops-dir",
        type=Path,
        required=True,
        help="Directory that retains full-resolution source crops.",
    )
    parser.add_argument("--size", type=int, default=32)
    parser.add_argument("--padding", type=int, default=2)
    parser.add_argument(
        "--alpha-threshold",
        type=int,
        default=127,
        help=(
            "Alpha values at or below this threshold are removed before "
            "pixel-grid analysis; surviving pixels become fully opaque."
        ),
    )
    return parser.parse_args()


def _run_pixel_crop_tool(
    raw_path: Path,
    cropped_path: Path,
    crop_tool: Path,
    alpha_threshold: int,
) -> None:
    child_env = os.environ.copy()
    child_env["PYTHONIOENCODING"] = "utf-8"
    subprocess.run(
        [
            sys.executable,
            str(crop_tool),
            str(raw_path),
            str(cropped_path),
            "--padding",
            "8",
            "--alpha-threshold",
            str(alpha_threshold),
        ],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=child_env,
    )


def _analyze_logical_grid(cropped_path: Path, analyzer: Path) -> dict:
    result = subprocess.run(
        [sys.executable, str(analyzer), str(cropped_path), "--json"],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"raw_output": result.stdout.strip()}


def _write_runtime_icon(
    source_path: Path,
    output_path: Path,
    size: int,
    padding: int,
) -> None:
    with Image.open(source_path).convert("RGBA") as source:
        alpha_bbox = source.getchannel("A").getbbox()
        if alpha_bbox is None:
            raise ValueError(f"No visible pixels in {source_path}")
        subject = source.crop(alpha_bbox)
        available = size - padding * 2
        scale = min(available / subject.width, available / subject.height)
        resized_width = max(1, round(subject.width * scale))
        resized_height = max(1, round(subject.height * scale))
        resized = subject.resize(
            (resized_width, resized_height),
            Image.Resampling.NEAREST,
        )
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.alpha_composite(
            resized,
            (
                (size - resized_width) // 2,
                (size - resized_height) // 2,
            ),
        )
        canvas.save(output_path, optimize=True)


def main() -> int:
    args = _parse_args()
    if args.size <= 0 or args.padding < 0 or args.padding * 2 >= args.size:
        raise ValueError("Invalid output size or padding.")
    if not 0 <= args.alpha_threshold <= 255:
        raise ValueError("Alpha threshold must be between 0 and 255.")

    repo_root = Path(__file__).resolve().parent.parent
    crop_tool = repo_root / "dev_tools" / "pixel_crop_tool.py"
    analyzer = repo_root / "dev_tools" / "pixel_grid_analyzer.py"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.source_crops_dir.mkdir(parents=True, exist_ok=True)

    reports: dict[str, dict] = {}
    with Image.open(args.atlas).convert("RGBA") as atlas:
        width, height = atlas.size
        for index, icon_name in enumerate(ICON_NAMES):
            row, column = divmod(index, 4)
            left = round(column * width / 4)
            right = round((column + 1) * width / 4)
            top = round(row * height / 2)
            bottom = round((row + 1) * height / 2)
            raw_path = args.source_crops_dir / f"{icon_name}_cell.png"
            cropped_path = args.source_crops_dir / f"{icon_name}_cropped.png"
            atlas.crop((left, top, right, bottom)).save(raw_path)
            _run_pixel_crop_tool(
                raw_path,
                cropped_path,
                crop_tool,
                args.alpha_threshold,
            )
            reports[icon_name] = _analyze_logical_grid(cropped_path, analyzer)
            _write_runtime_icon(
                cropped_path,
                args.output_dir / f"{icon_name}.png",
                args.size,
                args.padding,
            )

    print(json.dumps(reports, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
