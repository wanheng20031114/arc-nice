#!/usr/bin/env python3
"""Audit the approved runtime atlases for the elite drone operator."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "dev_assets" / "source_images" / "combat_robot_drone_operator_elite"
RUNTIME_DIR = ROOT / "resources" / "texture" / "enemy" / "mechanical_life"
FINAL_SELECTION = enemy_asset_report_path("combat_robot_drone_operator_elite_final_selection.json")
FINAL_MANIFEST = enemy_asset_report_path("combat_robot_drone_operator_elite_final_candidate_manifest.json")

CONTRACTS = {
    "operator": {
        "candidate": SOURCE_DIR / "combat_robot_drone_operator_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_drone_operator_elite.png",
        "sha256": "ec9fdb615610531e24350237cd8aa9556909ba135acae15d53624d0fd9221bd0",
        "size": (256, 96),
        "palette": {
            (21, 22, 19, 255), (29, 28, 30, 255), (55, 59, 63, 255),
            (74, 36, 105, 255), (82, 88, 94, 255), (112, 121, 128, 255),
            (125, 54, 179, 255), (151, 159, 164, 255),
            (157, 78, 221, 255), (190, 196, 198, 255),
            (197, 138, 255, 255),
        },
    },
    "drone": {
        "candidate": SOURCE_DIR / "combat_robot_suicide_drone_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_suicide_drone_elite.png",
        "sha256": "6e3190f928bc5d49fa654bba1f9edd2ee6e071e4d9d21420a8b8a7256fb94c0d",
        "size": (64, 16),
        "palette": {
            (21, 22, 19, 255), (55, 59, 63, 255), (74, 36, 105, 255),
            (82, 88, 94, 255), (112, 121, 128, 255),
            (125, 54, 179, 255), (151, 159, 164, 255),
            (157, 78, 221, 255), (190, 196, 198, 255),
            (197, 138, 255, 255),
        },
    },
    "target": {
        "candidate": SOURCE_DIR / "combat_robot_drone_target_marker_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_drone_target_marker_elite.png",
        "sha256": "8be355f9b24d7920b5cb350addd9af289b698e7c672f39ff7db5e77f19d6d747",
        "size": (64, 16),
        "palette": {
            (74, 36, 105, 255), (125, 54, 179, 255),
            (197, 138, 255, 255), (226, 229, 226, 255),
        },
    },
    "explosion": {
        "candidate": SOURCE_DIR / "combat_robot_mechanical_explosion_elite_final_candidate.png",
        "runtime": RUNTIME_DIR / "combat_robot_mechanical_explosion_elite.png",
        "sha256": "c3e2ba275b9151a897b8f0411c59dd7acd9ebc0e37e26bc242e960a13ea571b1",
        "size": (512, 64),
        "palette": {
            (21, 22, 19, 255), (74, 36, 105, 255), (115, 84, 134, 255),
            (157, 78, 221, 255), (197, 138, 255, 255),
            (226, 229, 226, 255),
        },
    },
}

ORDINARY_SHA = {
    "combat_robot_drone_operator.png": "9f987244da55ed3d89bae38a3eda40998518dcd3935f2bb7a1551eb94cd15395",
    "combat_robot_suicide_drone.png": "21fe9ddf09a72b080a06d346cb47ab4f3572852d9f0dae3242bc4476a7b1e06b",
    "combat_robot_drone_target_marker.png": "a2694c49e2dc04a5a7a46ebc7be5fb4078ea78c1dc4282e68ad4f6557b501436",
    "combat_robot_mechanical_explosion.png": "6edc04d40612bb626b9d0880c250f869cd7f7bdd892296887dd0b57dd058e589",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_checked(contract: dict) -> Image.Image:
    candidate = contract["candidate"]
    runtime = contract["runtime"]
    expected = contract["sha256"]
    assert sha256(candidate) == expected, f"candidate drift: {candidate.name}"
    assert sha256(runtime) == expected, f"runtime is not a byte copy: {runtime.name}"
    assert runtime.read_bytes() == candidate.read_bytes(), f"byte mismatch: {runtime.name}"
    image = Image.open(runtime).convert("RGBA")
    assert image.size == contract["size"], f"wrong size: {runtime.name}"
    colors = set(image.getdata())
    assert {pixel[3] for pixel in colors} <= {0, 255}, f"non-binary alpha: {runtime.name}"
    assert all(pixel[:3] == (0, 0, 0) for pixel in colors if pixel[3] == 0), (
        f"dirty transparent RGB: {runtime.name}"
    )
    assert colors - {(0, 0, 0, 0)} == contract["palette"], (
        f"palette drift: {runtime.name}"
    )
    assert runtime.with_suffix(runtime.suffix + ".import").is_file(), (
        f"missing Godot import UID: {runtime.name}"
    )
    return image


def frames(image: Image.Image, cell: int, count: int, row: int = 0) -> list[Image.Image]:
    return [
        image.crop((index * cell, row * cell, (index + 1) * cell, (row + 1) * cell))
        for index in range(count)
    ]


def alpha_bbox(frame: Image.Image) -> tuple[int, int, int, int]:
    bbox = frame.getchannel("A").getbbox()
    assert bbox is not None, "animation frame is empty"
    return bbox


def audit_operator(image: Image.Image) -> None:
    move = frames(image, 32, 8, 0)
    deploy = frames(image, 32, 3, 1)
    death = frames(image, 32, 8, 2)
    for frame in move + deploy + death:
        x0, y0, x1, y1 = alpha_bbox(frame)
        assert x1 - x0 <= 28 and y1 - y0 <= 28, "operator exceeds 28x28"
        assert y1 == 28, "operator foot/death baseline drifted"
    for frame in move + deploy:
        x0, _y0, x1, _y1 = alpha_bbox(frame)
        assert x0 <= 16 < x1, "live operator lost authored center x=16"
    unused_deploy = image.crop((96, 32, 256, 64))
    assert unused_deploy.getchannel("A").getbbox() is None, "unused deploy cells are dirty"


def audit_drone(image: Image.Image) -> None:
    drone_frames = frames(image, 16, 4)
    masks = [frame.getchannel("A").tobytes() for frame in drone_frames]
    assert all(mask == masks[0] for mask in masks[1:]), "drone alpha mask flickers"
    assert all(alpha_bbox(frame) == (2, 3, 14, 12) for frame in drone_frames), (
        "drone must keep its 12x9 silhouette"
    )


def audit_target(image: Image.Image) -> None:
    for frame in frames(image, 16, 4):
        x0, y0, x1, y1 = alpha_bbox(frame)
        assert x0 + x1 == 16 and y0 + y1 == 16, "target marker center drifted"
        assert frame.getpixel((7, 7))[3] == 255 or frame.getpixel((8, 8))[3] == 255, (
            "target marker lost its center confirmation"
        )


def audit_explosion(image: Image.Image) -> None:
    widths = []
    for frame in frames(image, 64, 8):
        x0, y0, x1, y1 = alpha_bbox(frame)
        assert x0 + x1 == 64 and y0 + y1 == 64, "explosion center drifted"
        widths.append(max(x1 - x0, y1 - y0))
    assert max(widths) == 56, "explosion must reach the authored 56px diameter"


def audit_manifests() -> None:
    for path in (FINAL_SELECTION, FINAL_MANIFEST):
        payload = json.loads(path.read_text(encoding="utf-8"))
        assert payload.get("final_human_approved") is True, f"approval missing: {path.name}"
        assert payload.get("runtime_written") is True, f"runtime flag missing: {path.name}"
        assert payload.get("imagegen_pixels_imported") is False, f"ImageGen import flag drift: {path.name}"
        assert payload.get("approved_anchor") == "O3", f"anchor drift: {path.name}"
        assert payload.get("approved_animation_selection") == {
            "move": "M1", "deploy": "P1", "death": "K2"
        }, f"animation selection drift: {path.name}"
        assert payload.get("approved_effect_selection") == {
            "drone": "V1", "target": "T1", "explosion": "X1"
        }, f"effect selection drift: {path.name}"


def main() -> None:
    images = {name: load_checked(contract) for name, contract in CONTRACTS.items()}
    audit_operator(images["operator"])
    audit_drone(images["drone"])
    audit_target(images["target"])
    audit_explosion(images["explosion"])
    audit_manifests()
    for filename, expected in ORDINARY_SHA.items():
        assert sha256(RUNTIME_DIR / filename) == expected, f"ordinary asset changed: {filename}"
    print("COMBAT_ROBOT_DRONE_OPERATOR_ELITE_ASSET_AUDIT_OK")


if __name__ == "__main__":
    main()
