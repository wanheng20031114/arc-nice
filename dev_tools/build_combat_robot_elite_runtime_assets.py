#!/usr/bin/env python3
"""Promote the human-approved elite combat robot atlas into runtime assets.

This writer deliberately performs no image conversion.  It accepts only the
third-stage M1/W2/C1/D2 candidate with its pinned SHA-256, copies those exact
PNG bytes to the runtime texture directory, and records the completed approval
gate in the animation manifest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = (
    PROJECT_ROOT / "dev_assets" / "source_images" / "combat_robot_elite"
)
MANIFEST_PATH = SOURCE_DIR / "combat_robot_elite_animation_manifest.json"
FINAL_CANDIDATE_PATH = SOURCE_DIR / "combat_robot_elite_final_candidate.png"
RUNTIME_TEXTURE_PATH = (
    PROJECT_ROOT
    / "resources"
    / "texture"
    / "enemy"
    / "mechanical_life"
    / "combat_robot_elite.png"
)

EXPECTED_CANDIDATE_SHA256 = (
    "ef45598db927517c52024bd758b93bb2e3b7c1bc7cc21cc5dca399e775353688"
)
EXPECTED_SELECTION = {
    "move": "M1",
    "windup": "W2",
    "dash": "C1",
    "death": "D2",
}
PENDING_STAGE = "final_candidate_pending_third_human_gate"
INTEGRATED_STAGE = "runtime_integrated"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file_handle:
        for chunk in iter(lambda: file_handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _relative(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _load_and_validate_manifest() -> dict[str, object]:
    if not MANIFEST_PATH.is_file():
        raise FileNotFoundError(MANIFEST_PATH)
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("approved_selection") != EXPECTED_SELECTION:
        raise AssertionError("Manifest selection is not approved M1/W2/C1/D2")

    stage = str(manifest.get("stage", ""))
    already_integrated = (
        stage == INTEGRATED_STAGE
        and manifest.get("final_human_approved") is True
        and manifest.get("runtime_written") is True
    )
    if not already_integrated and stage != PENDING_STAGE:
        raise AssertionError(f"Unexpected approval stage: {stage!r}")

    third_stage = manifest.get("third_stage")
    if not isinstance(third_stage, dict):
        raise AssertionError("Manifest third_stage record is missing")
    if third_stage.get("final_candidate") != _relative(FINAL_CANDIDATE_PATH):
        raise AssertionError("Manifest final candidate path changed")
    if third_stage.get("final_candidate_sha256") != EXPECTED_CANDIDATE_SHA256:
        raise AssertionError("Manifest final candidate SHA-256 changed")
    if third_stage.get("final_candidate_size") != [256, 128]:
        raise AssertionError("Manifest final candidate size changed")
    return manifest


def _validate_candidate() -> bytes:
    if not FINAL_CANDIDATE_PATH.is_file():
        raise FileNotFoundError(FINAL_CANDIDATE_PATH)
    if _sha256(FINAL_CANDIDATE_PATH) != EXPECTED_CANDIDATE_SHA256:
        raise AssertionError("Final candidate SHA-256 does not match approval")

    with Image.open(FINAL_CANDIDATE_PATH) as image:
        if image.mode != "RGBA" or image.size != (256, 128):
            raise AssertionError(
                f"Final candidate is {image.mode} {image.size}, expected RGBA 256x128"
            )
        pixels = tuple(image.getdata())
    if {pixel[3] for pixel in pixels} - {0, 255}:
        raise AssertionError("Final candidate contains partial alpha")
    if any(pixel[3] == 0 and pixel[:3] != (0, 0, 0) for pixel in pixels):
        raise AssertionError("Final candidate contains dirty transparent RGB")
    return FINAL_CANDIDATE_PATH.read_bytes()


def _write_runtime_texture(candidate_bytes: bytes) -> None:
    runtime_root = (PROJECT_ROOT / "resources").resolve()
    resolved_target = RUNTIME_TEXTURE_PATH.resolve()
    if runtime_root not in resolved_target.parents:
        raise AssertionError("Runtime texture target escaped resources")
    RUNTIME_TEXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    RUNTIME_TEXTURE_PATH.write_bytes(candidate_bytes)
    if _sha256(RUNTIME_TEXTURE_PATH) != EXPECTED_CANDIDATE_SHA256:
        raise AssertionError("Runtime texture differs from approved candidate bytes")


def _record_runtime_integration(manifest: dict[str, object]) -> None:
    third_stage = manifest["third_stage"]
    assert isinstance(third_stage, dict)
    third_stage.update(
        {
            "status": "approved_and_written_to_runtime",
            "final_human_approved": True,
            "runtime_written": True,
            "runtime_texture": _relative(RUNTIME_TEXTURE_PATH),
            "runtime_texture_sha256": EXPECTED_CANDIDATE_SHA256,
        }
    )
    manifest["stage"] = INTEGRATED_STAGE
    manifest["final_human_approved"] = True
    manifest["runtime_written"] = True
    manifest["runtime_approval"] = {
        "approved_selection": dict(EXPECTED_SELECTION),
        "approved_candidate_sha256": EXPECTED_CANDIDATE_SHA256,
        "runtime_texture": _relative(RUNTIME_TEXTURE_PATH),
        "runtime_texture_sha256": EXPECTED_CANDIDATE_SHA256,
        "imagegen_pixels_imported": False,
    }
    MANIFEST_PATH.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def build(confirm_final_human_approval: bool) -> None:
    if not confirm_final_human_approval:
        raise PermissionError(
            "Refusing runtime promotion without --confirm-final-human-approval"
        )
    manifest = _load_and_validate_manifest()
    candidate_bytes = _validate_candidate()
    _write_runtime_texture(candidate_bytes)
    _record_runtime_integration(manifest)
    print(
        "COMBAT_ROBOT_ELITE_RUNTIME_ASSETS_OK "
        f"sha256={EXPECTED_CANDIDATE_SHA256}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--confirm-final-human-approval",
        action="store_true",
        help="Record the explicit third-stage approval and write runtime bytes.",
    )
    args = parser.parse_args()
    build(args.confirm_final_human_approval)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
