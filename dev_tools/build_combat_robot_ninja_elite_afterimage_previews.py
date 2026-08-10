#!/usr/bin/env python3
"""Prepare and package the elite ninja afterimage third-gate previews.

``--prepare-source`` is intentionally independent from Godot capture.  It
verifies the approved second-gate manifest and concatenates the locked M1,
S2, and D1 native strips into the review-only 320x120 atlas consumed by the
Godot renderer.  The default mode validates that renderer's raw report and
packages its individual frames; it is implemented below without writing any
runtime resource.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path

from enemy_asset_report_paths import enemy_asset_report_path, is_enemy_asset_report_path

from PIL import Image, ImageChops


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORY = ROOT / "dev_assets/source_images/combat_robot_ninja_elite"
PREVIEW_DIRECTORY = ROOT / "dev_assets/generated_previews"
RAW_DIRECTORY = ROOT / "dev_tools/output/combat_robot_ninja_elite_afterimage"

ANIMATION_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_animation_manifest.json")
REVIEW_SOURCE = SOURCE_DIRECTORY / "combat_robot_ninja_elite_afterimage_review_source.png"
REVIEW_SOURCE_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_afterimage_review_source_manifest.json")
AFTERIMAGE_MANIFEST = enemy_asset_report_path("combat_robot_ninja_elite_afterimage_manifest.json")
FINAL_REPORT = enemy_asset_report_path("combat_robot_ninja_elite_afterimage_preview_report.json")

FRAME_SIZE = 40
FRAME_COUNT = 8
ATLAS_SIZE = (320, 120)
TRANSPARENT = (0, 0, 0, 0)
BACKGROUND = (13, 19, 31, 255)
CAPTURE_SIZE = (640, 640)
REVIEW_SCALE = 16
RGBA_TOLERANCE = 1

EXPECTED_REVIEW_SOURCE_SHA256 = "6c0f50f2e02be51264ba92b269d26366653a0608cbed2b186e6c43c8ae2bd23b"
EXPECTED_REVIEW_SOURCE_RGBA_SHA256 = "5fc943f0369c1e6a6f26f374c5c07542e2d92dd780e9a8ea7157220dca7001d3"
EXPECTED_SHADER_PATH = "res://scene/combat/feedback/shaders/entity_motion_status.gdshader"
EXPECTED_SHADER_SHA256 = "10454b4a7db41abf7ec5881a4f516f919868df1bbf1b395cc86346edc4de05f6"
PRODUCTION_FILE_LOCKS = {
    "scene/combat/feedback/shaders/entity_motion_status.gdshader": EXPECTED_SHADER_SHA256,
    "scene/enemy/enemy.tscn": "48127a5e51bdcdce48c299a3185dd0b0bfcd684e4041850b3e419d9e306458ee",
    "scene/enemy/enemy.gd": "6d333cdf170ae0910dc7d83f62e21c0abedf0250846a5fe6e05e205b7c6e6309",
    "scene/enemy/mechanical_life/combat_robot_ninja.gd": "ded06d64d7e10ac74dd4015f1daccb968e0ab80aec230e7208dd455e0225db21",
    "scene/enemy/mechanical_life/combat_robot_ninja.tscn": "a040c7453b200355fe7f6ec61b5873c19367d63fbbbfacd25a4b4ed6c437201c",
}

DIRECTIONS = (
    {"name": "right", "world": (1.0, 0.0), "flip_h": False, "shader_local": (1.0, 0.0)},
    {"name": "left", "world": (-1.0, 0.0), "flip_h": True, "shader_local": (1.0, 0.0)},
    {"name": "up", "world": (0.0, -1.0), "flip_h": False, "shader_local": (0.0, -1.0)},
    {"name": "down", "world": (0.0, 1.0), "flip_h": False, "shader_local": (0.0, 1.0)},
    {
        "name": "down_right",
        "world": (0.70710678, 0.70710678),
        "flip_h": False,
        "shader_local": (0.70710678, 0.70710678),
    },
    {
        "name": "up_left",
        "world": (-0.70710678, -0.70710678),
        "flip_h": True,
        "shader_local": (0.70710678, -0.70710678),
    },
)
STATUS_VARIANTS = {
    "slow": {"slow": 0.36, "burn": 0.0},
    "burn": {"slow": 0.0, "burn": 0.26},
    "slow_burn": {"slow": 0.36, "burn": 0.26},
}
TRANSITIONS = {
    "move_to_boost": {
        "durations_ms": [50, 50, 50, 50, 40, 40, 40, 40],
        "sequence": (("move", 0), ("move", 1), ("move", 2), ("move", 3), ("boost", 3), ("boost", 4), ("boost", 5), ("boost", 6)),
    },
    "boost_to_move": {
        "durations_ms": [40, 40, 40, 40, 50, 50, 50, 50],
        "sequence": (("boost", 4), ("boost", 5), ("boost", 6), ("boost", 7), ("move", 7), ("move", 0), ("move", 1), ("move", 2)),
    },
    "boost_to_death_cleanup": {
        "durations_ms": [40, 40, 40, 40, 80, 80, 80, 80],
        "sequence": (("boost", 4), ("boost", 5), ("boost", 6), ("boost", 7), ("death", 0), ("death", 1), ("death", 2), ("death", 3)),
    },
}

EXPECTED_ANIMATION_MANIFEST_SHA256 = "a2589f42897f714ffbd99300b8136c6a9eac30ff5f1aaffb4e85941e7041be61"
APPROVED_SELECTION = {"move": "m1", "boost": "s2", "death": "d1"}
APPROVED_NATIVE_LOCKS = {
    "move": {
        "path": "dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_move_m1_candidate_native.png",
        "sha256": "0d2abb9e49f38d1d9ff09a6e874485168e15798d78cd503a241fe601e1a5f3d9",
        "rgba_sha256": "cfb00c5e0c1e330d41a0bfcee6827576b52f39e8a7ca3c6875fb3511eed921ba",
    },
    "boost": {
        "path": "dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_boost_s2_candidate_native.png",
        "sha256": "d227677c16a89685489649ddb56362c84356f81181792a920f1f0180638058b2",
        "rgba_sha256": "e44ebfa9e6ba7f4cba50a38acf3f114ae87829f8fc1e047b6610243f2936cb37",
    },
    "death": {
        "path": "dev_assets/source_images/combat_robot_ninja_elite/combat_robot_ninja_elite_death_d1_candidate_native.png",
        "sha256": "e886670c43fece56df7462ce8fb8b8bacae69bd8ab0d7ff82fc1c431e4aa7ffe",
        "rgba_sha256": "616bff1518b607e5f58e60e1375eeb0fc339f41ec92e4280062d739757357ed0",
    },
}

PENDING_THIRD_GATE_MANIFEST_SHA256 = "be0884c6a47510c89d334da9438330badae80e726fe05b3266526489f03cbd8f"
PENDING_THIRD_GATE_REPORT_SHA256 = "ab4de983e3f4657f43862566da97e041525b2fe2adae2cb166f6081c48d5a522"
APPROVED_GODOT_RUNTIME_REPORT_SHA256 = "af4913f347ca094d11534c067d51b31170218b203387544dc31d3d8120368e68"
APPROVED_AFTERIMAGE_OUTPUT_LOCKS = {
    "direction_right": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_right.gif", "sha256": "e069aec97e6b46bbc73bd9724fb2a0ec423f560feb9fcf321452904b131ec3b9"},
    "direction_left": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_left.gif", "sha256": "4ec03c4caf3f37eae8e92f54969256b476522cc2026bfe6ec5e5e63557772347"},
    "direction_up": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_up.gif", "sha256": "8c3e22e5f9e902d3ccba5f358b9c0065db129c1beabf00eb71a214b48601178d"},
    "direction_down": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_down.gif", "sha256": "3a402f986c24ba6c3e25ee8e7226bb2c7fa3136c9bca6536dcf3e18f1c571042"},
    "direction_down_right": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_down_right.gif", "sha256": "63429aff422056b4744161a5ba239b259415f079aff39e9472cb03189ecfa408"},
    "direction_up_left": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_up_left.gif", "sha256": "701c24657c244efe5e9b8a54af91fa572a7d17eeaeb90b7bde9898b31bae373e"},
    "move_to_boost": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_move_to_boost.gif", "sha256": "c42b5d014e8dcbba01e1e17ac90313aa181c7121fb48e0a9ae4bc82020643c76"},
    "boost_to_move": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_boost_to_move.gif", "sha256": "1263e21212dfe05450bc6c1dbb48b523d54e2ea82a3e108ff5ed1078a7ad21e4"},
    "boost_to_death_cleanup": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_boost_to_death_cleanup.gif", "sha256": "438d27e4f7808f91f600a132cec999bd5fd449346028b96fcb5af9c2fbc9064c"},
    "status_slow": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_slow.gif", "sha256": "09a02be20a084ff41c40ce2e274db430615acb13c648f28e9eaf30835b484a61"},
    "status_burn": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_burn.gif", "sha256": "48ac7ac468129341509735780a6858cd155307fce815ca86bfd4f3cb38c815ba"},
    "status_slow_burn": {"path": "dev_assets/generated_previews/combat_robot_ninja_elite_afterimage_slow_burn.gif", "sha256": "525c35b9e2fc0910dde6a085f3b998820834ddb310f0ba4875489ff67e8ab034"},
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rgba_sha256(image: Image.Image) -> str:
    return hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest()


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def require_file(path: Path) -> Path:
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def ensure_dev_asset_output(path: Path) -> None:
    resolved = path.resolve()
    dev_assets = (ROOT / "dev_assets").resolve()
    if resolved != dev_assets and dev_assets not in resolved.parents and not is_enemy_asset_report_path(path):
        raise AssertionError(f"Refused non-dev_assets output: {path}")


def write_json(path: Path, payload: object) -> None:
    ensure_dev_asset_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def save_png(image: Image.Image, path: Path) -> None:
    ensure_dev_asset_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=False, compress_level=9)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--prepare-source",
        action="store_true",
        help="Build and audit only the locked 320x120 Godot review source atlas.",
    )
    parser.add_argument(
        "--approve",
        action="store_true",
        help="Record the user's third-gate approval without writing runtime resources.",
    )
    return parser.parse_args()


def expected_third_gate_approval() -> dict[str, object]:
    return {
        "decision": "approved",
        "method": "explicit --approve",
        "approved_pending_manifest": {
            "path": relative(AFTERIMAGE_MANIFEST),
            "sha256": PENDING_THIRD_GATE_MANIFEST_SHA256,
        },
        "approved_pending_report": {
            "path": relative(FINAL_REPORT),
            "sha256": PENDING_THIRD_GATE_REPORT_SHA256,
        },
        "godot_runtime_report": {
            "path": relative(RAW_DIRECTORY / "runtime_report.json"),
            "sha256": APPROVED_GODOT_RUNTIME_REPORT_SHA256,
        },
        "approved_outputs": APPROVED_AFTERIMAGE_OUTPUT_LOCKS,
        "approved_animation_selection": APPROVED_SELECTION,
        "runtime_written_at_approval": False,
    }


def verify_approved_output_locks(outputs: object) -> None:
    if outputs != APPROVED_AFTERIMAGE_OUTPUT_LOCKS:
        raise AssertionError("Third-gate output lock table drifted")
    for key, record in APPROVED_AFTERIMAGE_OUTPUT_LOCKS.items():
        path = ROOT / record["path"]
        require_file(path)
        actual = sha256(path)
        if actual != record["sha256"]:
            raise AssertionError(
                f"Approved third-gate output drifted: {key} "
                f"expected={record['sha256']} actual={actual}"
            )


def resolve_third_gate_approval(requested: bool) -> dict[str, object] | None:
    if not AFTERIMAGE_MANIFEST.is_file() or not FINAL_REPORT.is_file():
        if requested:
            raise AssertionError("Third-gate approval requires the pending manifest and report")
        return None
    manifest = json.loads(AFTERIMAGE_MANIFEST.read_text(encoding="utf-8"))
    report = json.loads(FINAL_REPORT.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or not isinstance(report, dict):
        raise AssertionError("Third-gate manifest/report must be JSON objects")
    if manifest.get("runtime_written") is not False or report.get("runtime_written") is not False:
        raise AssertionError("Third-gate approval cannot follow a runtime write")
    if manifest.get("final_human_approved") is not False or report.get("final_human_approved") is not False:
        raise AssertionError("Final approval must remain false during the third gate")
    if manifest.get("approved_animation_selection") != APPROVED_SELECTION:
        raise AssertionError("Third-gate manifest selection drifted")

    approved = manifest.get("third_human_approved") is True
    if approved:
        certificate = expected_third_gate_approval()
        if manifest.get("stage") != "afterimage_third_human_gate_approved":
            raise AssertionError("Approved third-gate manifest stage drifted")
        if report.get("stage") != "afterimage_third_human_gate_approved":
            raise AssertionError("Approved third-gate report stage drifted")
        if manifest.get("third_human_approval") != certificate:
            raise AssertionError("Approved third-gate manifest certificate drifted")
        if report.get("third_human_approval") != certificate:
            raise AssertionError("Approved third-gate report certificate drifted")
        if manifest.get("report_sha256") != sha256(FINAL_REPORT):
            raise AssertionError("Approved third-gate report hash chain drifted")
        verify_approved_output_locks(manifest.get("outputs"))
        return certificate

    if not requested:
        return None
    if sha256(AFTERIMAGE_MANIFEST) != PENDING_THIRD_GATE_MANIFEST_SHA256:
        raise AssertionError("Pending third-gate manifest SHA drifted before approval")
    if sha256(FINAL_REPORT) != PENDING_THIRD_GATE_REPORT_SHA256:
        raise AssertionError("Pending third-gate report SHA drifted before approval")
    if manifest.get("stage") != "afterimage_pending_third_human_gate":
        raise AssertionError("Manifest is not at the pending third gate")
    if report.get("stage") != "afterimage_pending_third_human_gate":
        raise AssertionError("Report is not at the pending third gate")
    if manifest.get("third_human_approved") is not False or report.get("third_human_approved") is not False:
        raise AssertionError("Pending third-gate approval flags drifted")
    if manifest.get("report_sha256") != PENDING_THIRD_GATE_REPORT_SHA256:
        raise AssertionError("Pending third-gate report hash chain drifted")
    runtime_record = report.get("godot_runtime_report")
    if not isinstance(runtime_record, dict) or runtime_record.get("sha256") != APPROVED_GODOT_RUNTIME_REPORT_SHA256:
        raise AssertionError("Approved Godot runtime report lock drifted")
    verify_approved_output_locks(manifest.get("outputs"))
    return expected_third_gate_approval()


def load_and_verify_approved_manifest() -> dict[str, object]:
    require_file(ANIMATION_MANIFEST)
    actual_manifest_sha = sha256(ANIMATION_MANIFEST)
    if actual_manifest_sha != EXPECTED_ANIMATION_MANIFEST_SHA256:
        raise AssertionError(
            "Approved animation manifest SHA drifted: "
            f"expected={EXPECTED_ANIMATION_MANIFEST_SHA256} actual={actual_manifest_sha}"
        )
    manifest = json.loads(ANIMATION_MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("stage") != "second_human_gate_approved":
        raise AssertionError("Animation manifest is not at the approved second gate")
    if manifest.get("approved_animation_selection") != APPROVED_SELECTION:
        raise AssertionError("Animation selection drifted from M1/S2/D1")
    if manifest.get("second_human_approved") is not True:
        raise AssertionError("Second human approval is not recorded")
    if manifest.get("final_human_approved") is not False:
        raise AssertionError("Final human approval must remain false during third gate")
    if manifest.get("runtime_written") is not False:
        raise AssertionError("Review preparation must not follow a runtime write")
    recorded_locks = manifest.get("approved_native_locks")
    if not isinstance(recorded_locks, dict):
        raise AssertionError("Animation manifest is missing approved native locks")
    for slot, expected in APPROVED_NATIVE_LOCKS.items():
        recorded = recorded_locks.get(slot)
        if not isinstance(recorded, dict):
            raise AssertionError(f"Animation manifest is missing {slot} lock")
        for key in ("path", "sha256", "rgba_sha256"):
            if recorded.get(key) != expected[key]:
                raise AssertionError(
                    f"Animation manifest {slot}.{key} drifted: "
                    f"expected={expected[key]} actual={recorded.get(key)}"
                )
    return manifest


def load_locked_strip(slot: str) -> Image.Image:
    lock = APPROVED_NATIVE_LOCKS[slot]
    path = ROOT / lock["path"]
    require_file(path)
    actual_sha = sha256(path)
    if actual_sha != lock["sha256"]:
        raise AssertionError(
            f"Approved {slot} file SHA drifted: expected={lock['sha256']} actual={actual_sha}"
        )
    with Image.open(path) as source:
        source.load()
        strip = source.convert("RGBA")
    if strip.size != (FRAME_SIZE * FRAME_COUNT, FRAME_SIZE):
        raise AssertionError(f"Approved {slot} strip geometry drifted: {strip.size}")
    actual_rgba_sha = rgba_sha256(strip)
    if actual_rgba_sha != lock["rgba_sha256"]:
        raise AssertionError(
            f"Approved {slot} decoded RGBA drifted: "
            f"expected={lock['rgba_sha256']} actual={actual_rgba_sha}"
        )
    return strip


def build_review_source() -> tuple[Image.Image, dict[str, object]]:
    load_and_verify_approved_manifest()
    atlas = Image.new("RGBA", ATLAS_SIZE, TRANSPARENT)
    row_records: dict[str, object] = {}
    for row_index, slot in enumerate(("move", "boost", "death")):
        strip = load_locked_strip(slot)
        atlas.paste(strip, (0, row_index * FRAME_SIZE))
        expected_bytes = strip.tobytes()
        actual_bytes = atlas.crop(
            (0, row_index * FRAME_SIZE, ATLAS_SIZE[0], (row_index + 1) * FRAME_SIZE)
        ).tobytes()
        if actual_bytes != expected_bytes:
            raise AssertionError(f"Review source {slot} row is not byte-identical")
        row_records[slot] = {
            "selection": APPROVED_SELECTION[slot],
            **APPROVED_NATIVE_LOCKS[slot],
            "row": row_index,
            "byte_identical": True,
        }
    if atlas.size != ATLAS_SIZE:
        raise AssertionError(f"Review source atlas geometry drifted: {atlas.size}")
    return atlas, row_records


def prepare_source() -> None:
    first, row_records = build_review_source()
    second, second_rows = build_review_source()
    if first.tobytes() != second.tobytes() or row_records != second_rows:
        raise AssertionError("In-memory review source rebuild was not deterministic")
    save_png(first, REVIEW_SOURCE)
    with Image.open(REVIEW_SOURCE) as decoded:
        decoded.load()
        round_trip = decoded.convert("RGBA")
    if round_trip.size != ATLAS_SIZE or round_trip.tobytes() != first.tobytes():
        raise AssertionError("Saved review source did not decode byte-identically")
    source_manifest = {
        "schema_version": 1,
        "asset": "combat_robot_ninja_elite_afterimage_review_source",
        "stage": "afterimage_review_source_prepared",
        "preview_only": True,
        "source": {
            "path": relative(REVIEW_SOURCE),
            "sha256": sha256(REVIEW_SOURCE),
            "rgba_sha256": rgba_sha256(round_trip),
            "size": list(round_trip.size),
            "rows": row_records,
        },
        "animation_manifest": {
            "path": relative(ANIMATION_MANIFEST),
            "sha256": EXPECTED_ANIMATION_MANIFEST_SHA256,
            "selection": APPROVED_SELECTION,
        },
        "checks": {
            "approved_input_locks": True,
            "rows_byte_identical_to_approved_native_strips": True,
            "png_round_trip_byte_identical": True,
            "deterministic_double_rebuild": True,
            "runtime_written": False,
        },
        "runtime_written": False,
    }
    write_json(REVIEW_SOURCE_MANIFEST, source_manifest)
    print("COMBAT_ROBOT_NINJA_ELITE_AFTERIMAGE_SOURCE_OK")
    print(f"source={relative(REVIEW_SOURCE)}")
    print(f"source_sha256={source_manifest['source']['sha256']}")
    print(f"source_rgba_sha256={source_manifest['source']['rgba_sha256']}")
    print(f"manifest={relative(REVIEW_SOURCE_MANIFEST)}")


def verify_prepared_source() -> tuple[Image.Image, dict[str, object]]:
    load_and_verify_approved_manifest()
    require_file(REVIEW_SOURCE)
    require_file(REVIEW_SOURCE_MANIFEST)
    if sha256(REVIEW_SOURCE) != EXPECTED_REVIEW_SOURCE_SHA256:
        raise AssertionError("Prepared review source file SHA drifted; rerun --prepare-source")
    with Image.open(REVIEW_SOURCE) as source:
        source.load()
        atlas = source.convert("RGBA")
    if atlas.size != ATLAS_SIZE:
        raise AssertionError(f"Prepared review source geometry drifted: {atlas.size}")
    if rgba_sha256(atlas) != EXPECTED_REVIEW_SOURCE_RGBA_SHA256:
        raise AssertionError("Prepared review source decoded RGBA drifted")
    rebuilt, _ = build_review_source()
    if rebuilt.tobytes() != atlas.tobytes():
        raise AssertionError("Prepared review source no longer matches its locked rows")
    source_manifest = json.loads(REVIEW_SOURCE_MANIFEST.read_text(encoding="utf-8"))
    source_record = source_manifest.get("source")
    if not isinstance(source_record, dict):
        raise AssertionError("Prepared review source sidecar is malformed")
    if source_record.get("sha256") != EXPECTED_REVIEW_SOURCE_SHA256:
        raise AssertionError("Prepared review source sidecar file SHA drifted")
    if source_record.get("rgba_sha256") != EXPECTED_REVIEW_SOURCE_RGBA_SHA256:
        raise AssertionError("Prepared review source sidecar RGBA SHA drifted")
    if source_manifest.get("runtime_written") is not False:
        raise AssertionError("Prepared review source sidecar claims a runtime write")
    return atlas, source_manifest


def expected_capture_names() -> list[str]:
    names = [
        f"direction_{direction['name']}_frame_{frame}.png"
        for direction in DIRECTIONS
        for frame in range(FRAME_COUNT)
    ]
    names.extend(
        f"{transition}_frame_{frame}.png"
        for transition in TRANSITIONS
        for frame in range(FRAME_COUNT)
    )
    names.extend(
        f"status_{status}_{state}_frame_{frame}.png"
        for status in STATUS_VARIANTS
        for state in ("active", "baseline")
        for frame in range(FRAME_COUNT)
    )
    return names


def assert_number_close(actual: object, expected: float, label: str, tolerance: float = 1.0e-6) -> None:
    if isinstance(actual, bool) or not isinstance(actual, (int, float)):
        raise AssertionError(f"{label} must be numeric, got {actual!r}")
    if abs(float(actual) - expected) > tolerance:
        raise AssertionError(f"{label} drifted: expected={expected} actual={actual}")


def assert_vector_close(actual: object, expected: tuple[float, float], label: str) -> None:
    if not isinstance(actual, list) or len(actual) != 2:
        raise AssertionError(f"{label} must be a two-number JSON array")
    assert_number_close(actual[0], expected[0], f"{label}[0]")
    assert_number_close(actual[1], expected[1], f"{label}[1]")


def assert_metric_map(
    value: object,
    expected_keys: set[str],
    label: str,
    predicate: object,
) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected_keys:
        actual_keys = set(value) if isinstance(value, dict) else set()
        raise AssertionError(
            f"{label} keys drifted: missing={sorted(expected_keys - actual_keys)} "
            f"extra={sorted(actual_keys - expected_keys)}"
        )
    check = predicate
    for key, metric in value.items():
        if not callable(check) or not check(metric):
            raise AssertionError(f"{label}[{key}] failed: {metric!r}")
    return value


def verify_local_production_locks() -> dict[str, str]:
    result: dict[str, str] = {}
    for relative_path, expected_sha in PRODUCTION_FILE_LOCKS.items():
        path = require_file(ROOT / relative_path)
        actual_sha = sha256(path)
        if actual_sha != expected_sha:
            raise AssertionError(
                f"Production file SHA drifted: {relative_path} "
                f"expected={expected_sha} actual={actual_sha}"
            )
        result[relative_path] = actual_sha
    return result


def verify_runtime_report_header(
    report: dict[str, object], source_manifest: dict[str, object]
) -> None:
    if report.get("schema_version") != 1:
        raise AssertionError("Godot runtime report schema_version must be 1")
    if report.get("asset") != "combat_robot_ninja_elite_afterimage":
        raise AssertionError("Godot runtime report asset identifier drifted")
    if report.get("stage") != "godot_capture_complete":
        raise AssertionError("Godot runtime report stage is not capture-complete")
    failures = report.get("failures")
    if failures != []:
        raise AssertionError(f"Godot capture reported failures: {failures!r}")
    if report.get("review_algorithm") != "production_original_rgb_three_offset_afterimage":
        raise AssertionError("Godot did not use the frozen production afterimage algorithm")
    if report.get("runtime_paths_written") != []:
        raise AssertionError("Godot preview capture wrote or reported runtime paths")

    source = report.get("source")
    if not isinstance(source, dict):
        raise AssertionError("Godot report is missing source lock data")
    expected_source_path = f"res://{relative(REVIEW_SOURCE)}"
    if source.get("path") != expected_source_path:
        raise AssertionError(f"Godot source path drifted: {source.get('path')!r}")
    if source.get("sha256") != EXPECTED_REVIEW_SOURCE_SHA256:
        raise AssertionError("Godot source file SHA drifted")
    if source.get("rgba_sha256") != EXPECTED_REVIEW_SOURCE_RGBA_SHA256:
        raise AssertionError("Godot source RGBA SHA drifted")
    if source.get("size") != list(ATLAS_SIZE):
        raise AssertionError(f"Godot source size drifted: {source.get('size')!r}")
    if source.get("rows") != APPROVED_SELECTION:
        raise AssertionError(f"Godot source row selection drifted: {source.get('rows')!r}")
    if source_manifest.get("source", {}).get("sha256") != source.get("sha256"):
        raise AssertionError("Godot source lock and source sidecar disagree")

    shader = report.get("shader")
    if not isinstance(shader, dict):
        raise AssertionError("Godot report is missing shader audit")
    expected_shader = {
        "path": EXPECTED_SHADER_PATH,
        "sha256": EXPECTED_SHADER_SHA256,
        "used_directly": True,
        "in_memory_modified": False,
        "sample_rgb": "original texture RGB",
        "block_before_slow_burn": True,
    }
    for key, expected in expected_shader.items():
        if shader.get(key) != expected:
            raise AssertionError(
                f"Godot shader audit {key} drifted: expected={expected!r} actual={shader.get(key)!r}"
            )


def verify_material_and_sampling(report: dict[str, object]) -> None:
    material = report.get("material")
    if not isinstance(material, dict):
        raise AssertionError("Godot report is missing shared material audit")
    exact_material_values = {
        "resource_local_to_scene": False,
        "shared_identity": True,
        "shared_material_count": 1,
        "shared_shader_count": 1,
        "created_material_count": 0,
        "duplicated_material_count": 0,
        "set_shader_parameter_call_count": 0,
        "material_uniforms_unchanged": True,
        "instance_parameter_isolation": True,
    }
    for key, expected in exact_material_values.items():
        if material.get(key) != expected:
            raise AssertionError(
                f"Godot material audit {key} drifted: expected={expected!r} actual={material.get(key)!r}"
            )
    assert_number_close(
        material.get("ninja_afterimage_pixels_before"), 4.0, "material.ninja_afterimage_pixels_before"
    )
    assert_number_close(
        material.get("ninja_afterimage_pixels_after"), 4.0, "material.ninja_afterimage_pixels_after"
    )
    uniforms_before = material.get("uniforms_before")
    uniforms_after = material.get("uniforms_after")
    if not isinstance(uniforms_before, dict) or uniforms_before != uniforms_after:
        raise AssertionError("Shared material uniform snapshots changed during capture")
    material_rids = material.get("material_rids")
    shader_rids = material.get("shader_rids")
    if not isinstance(material_rids, list) or len(set(map(str, material_rids))) != 1:
        raise AssertionError("Godot capture did not use exactly one shared material RID")
    if not isinstance(shader_rids, list) or len(set(map(str, shader_rids))) != 1:
        raise AssertionError("Godot capture did not use exactly one shared shader RID")

    sampling = report.get("sampling")
    if not isinstance(sampling, dict):
        raise AssertionError("Godot report is missing sampling audit")
    assert_number_close(sampling.get("strength"), 1.0, "sampling.strength")
    assert_number_close(sampling.get("pixels"), 4.0, "sampling.pixels")
    offsets = sampling.get("offsets")
    alphas = sampling.get("alphas")
    if not isinstance(offsets, list) or len(offsets) != 3:
        raise AssertionError("Godot sampling offsets must contain three values")
    if not isinstance(alphas, list) or len(alphas) != 3:
        raise AssertionError("Godot sampling alphas must contain three values")
    for index, expected in enumerate((1.8, 3.6, 5.4)):
        assert_number_close(offsets[index], expected, f"sampling.offsets[{index}]")
    for index, expected in enumerate((0.48, 0.34, 0.22)):
        assert_number_close(alphas[index], expected, f"sampling.alphas[{index}]")
    assert_number_close(
        sampling.get("maximum_overlap_alpha"), 0.732304, "sampling.maximum_overlap_alpha"
    )


def verify_direction_schema(report: dict[str, object]) -> None:
    directions = report.get("directions")
    if not isinstance(directions, list) or len(directions) != len(DIRECTIONS):
        raise AssertionError("Godot direction contract must contain exactly six records")
    for actual, expected in zip(directions, DIRECTIONS):
        if not isinstance(actual, dict) or actual.get("name") != expected["name"]:
            raise AssertionError(f"Godot direction order/name drifted: {actual!r}")
        if actual.get("flip_h") is not expected["flip_h"]:
            raise AssertionError(f"Godot {expected['name']} flip_h drifted")
        assert_vector_close(actual.get("world"), expected["world"], f"directions.{expected['name']}.world")
        assert_vector_close(
            actual.get("shader_local"), expected["shader_local"], f"directions.{expected['name']}.shader_local"
        )

    audit = report.get("direction_audit")
    if not isinstance(audit, dict):
        raise AssertionError("Godot report is missing direction_audit")
    expected_keys = {
        f"{direction['name']}/frame_{frame}"
        for direction in DIRECTIONS
        for frame in range(FRAME_COUNT)
    }
    assert_metric_map(
        audit.get("body_changed_pixels"), expected_keys, "direction_audit.body_changed_pixels", lambda value: int(value) == 0
    )
    assert_metric_map(
        audit.get("trail_only_pixels"), expected_keys, "direction_audit.trail_only_pixels", lambda value: int(value) > 0
    )
    assert_metric_map(
        audit.get("trail_body_intersection_pixels"),
        expected_keys,
        "direction_audit.trail_body_intersection_pixels",
        lambda value: int(value) == 0,
    )
    assert_metric_map(
        audit.get("trail_world_direction_dot"),
        expected_keys,
        "direction_audit.trail_world_direction_dot",
        lambda value: float(value) < -0.5,
    )
    assert_metric_map(
        audit.get("original_rgb_oracle_max_channel_error"),
        expected_keys,
        "direction_audit.original_rgb_oracle_max_channel_error",
        lambda value: float(value) <= (1.0 / 255.0 + 1.0e-9),
    )


def verify_status_phase_death_and_atlas_schema(report: dict[str, object]) -> None:
    status_audit = report.get("status_audit")
    if not isinstance(status_audit, dict) or set(status_audit) != set(STATUS_VARIANTS):
        raise AssertionError("Godot status_audit must contain slow, burn, and slow_burn")
    frame_keys = {f"frame_{frame}" for frame in range(FRAME_COUNT)}
    for status, expected_strengths in STATUS_VARIANTS.items():
        record = status_audit.get(status)
        if not isinstance(record, dict):
            raise AssertionError(f"Godot status_audit.{status} is malformed")
        strengths = record.get("strengths")
        if not isinstance(strengths, dict) or set(strengths) != {"slow", "burn"}:
            raise AssertionError(f"Godot status_audit.{status}.strengths is malformed")
        for key, expected in expected_strengths.items():
            assert_number_close(strengths.get(key), expected, f"status_audit.{status}.strengths.{key}")
        assert_metric_map(
            record.get("status_body_changed_vs_no_status"),
            frame_keys,
            f"status_audit.{status}.status_body_changed_vs_no_status",
            lambda value: int(value) > 0,
        )
        assert_metric_map(
            record.get("afterimage_body_changed_active_vs_baseline"),
            frame_keys,
            f"status_audit.{status}.afterimage_body_changed_active_vs_baseline",
            lambda value: int(value) == 0,
        )
        assert_metric_map(
            record.get("tail_changed_vs_no_status"),
            frame_keys,
            f"status_audit.{status}.tail_changed_vs_no_status",
            lambda value: int(value) == 0,
        )
        assert_metric_map(
            record.get("baseline_tail_pixels"),
            frame_keys,
            f"status_audit.{status}.baseline_tail_pixels",
            lambda value: int(value) == 0,
        )

    phase = report.get("phase_preservation")
    if not isinstance(phase, dict):
        raise AssertionError("Godot phase_preservation is malformed")
    if phase.get("production_method") != "_switch_locomotion_animation_preserving_phase":
        raise AssertionError("Godot phase proof did not call the production switch method")
    if phase.get("method_called") is not True:
        raise AssertionError("Godot phase proof did not record a production method call")
    if not {"move_to_boost", "boost_to_move"} <= set(phase):
        raise AssertionError("Godot phase_preservation cases are incomplete")
    phase_cases = {
        "move_to_boost": (3, 0.25),
        "boost_to_move": (7, 0.75),
    }
    for name, (frame, progress) in phase_cases.items():
        record = phase.get(name)
        if not isinstance(record, dict) or record.get("preserved") is not True:
            raise AssertionError(f"Godot phase case {name} was not preserved")
        if record.get("input_frame") != frame or record.get("output_frame") != frame:
            raise AssertionError(f"Godot phase case {name} changed frame index")
        assert_number_close(record.get("input_progress"), progress, f"phase.{name}.input_progress")
        assert_number_close(record.get("output_progress"), progress, f"phase.{name}.output_progress")
        if record.get("playing_before") is not True or record.get("playing_after") is not True:
            raise AssertionError(f"Godot phase case {name} changed playing state")

    death = report.get("death_cleanup")
    if not isinstance(death, dict):
        raise AssertionError("Godot report is missing death_cleanup")
    if int(death.get("first_death_frame_tail_pixels", -1)) != 0:
        raise AssertionError("First D1 death frame retained an afterimage")
    if int(death.get("boost_tail_pixels_before", 0)) <= 0:
        raise AssertionError("Death cleanup was not preceded by a visible boost trail")
    assert_number_close(death.get("strength_after"), 0.0, "death_cleanup.strength_after")

    lifecycle = report.get("lifecycle")
    if not isinstance(lifecycle, dict) or not lifecycle:
        raise AssertionError("Godot report is missing lifecycle checks")
    if any(value is not True for value in lifecycle.values()):
        raise AssertionError(f"Godot lifecycle checks failed: {lifecycle!r}")

    atlas = report.get("atlas_audit")
    if not isinstance(atlas, dict):
        raise AssertionError("Godot report is missing atlas_audit")
    if atlas.get("filter_clip") is not True or atlas.get("frame_count") != 24:
        raise AssertionError("Godot AtlasTexture frame/filter contract drifted")
    differences = atlas.get("atlas_standalone_changed_pixels")
    if not isinstance(differences, dict) or len(differences) != 24:
        raise AssertionError("Godot atlas/standalone audit must contain 24 frames")
    if any(int(value) != 0 for value in differences.values()):
        raise AssertionError(f"AtlasTexture diverged from standalone frames: {differences!r}")


def load_raw_capture(path: Path) -> Image.Image:
    require_file(path)
    with Image.open(path) as source:
        source.load()
        if source.format != "PNG" or source.size != CAPTURE_SIZE or source.mode != "RGBA":
            raise AssertionError(
                f"Raw capture contract drifted for {path.name}: "
                f"format={source.format} size={source.size} mode={source.mode}"
            )
        frame = source.copy()
    alpha_extrema = frame.getchannel("A").getextrema()
    if alpha_extrema != (255, 255):
        raise AssertionError(f"Raw capture must be opaque over the fixed background: {path.name} {alpha_extrema}")
    return frame


def verify_capture_inventory(report: dict[str, object]) -> tuple[dict[str, Image.Image], dict[str, object]]:
    expected_names = expected_capture_names()
    expected_set = set(expected_names)
    actual_pngs = {path.name for path in RAW_DIRECTORY.glob("*.png")}
    if actual_pngs != expected_set:
        raise AssertionError(
            f"Raw capture PNG inventory drifted: missing={sorted(expected_set - actual_pngs)} "
            f"extra={sorted(actual_pngs - expected_set)}"
        )
    captures = report.get("captures")
    if not isinstance(captures, dict) or set(captures) != expected_set:
        raise AssertionError("Godot captures lock map does not exactly match the raw PNG inventory")
    loaded: dict[str, Image.Image] = {}
    records: dict[str, object] = {}
    for name in expected_names:
        path = RAW_DIRECTORY / name
        record = captures.get(name)
        if not isinstance(record, dict):
            raise AssertionError(f"Godot capture lock is malformed: {name}")
        actual_sha = sha256(path)
        if record.get("sha256") != actual_sha:
            raise AssertionError(f"Raw capture SHA differs from runtime_report: {name}")
        if record.get("size") != list(CAPTURE_SIZE) or record.get("mode") != "RGBA":
            raise AssertionError(f"Raw capture geometry/mode lock drifted: {name}")
        frame = load_raw_capture(path)
        loaded[name] = frame
        records[name] = {
            "path": relative(path),
            "sha256": actual_sha,
            "rgba_sha256": rgba_sha256(frame),
            "size": list(frame.size),
            "mode": frame.mode,
        }
    extra_files = [
        path.name
        for path in RAW_DIRECTORY.iterdir()
        if path.is_file() and path.name != "runtime_report.json" and path.suffix.lower() != ".png"
    ]
    if extra_files:
        raise AssertionError(f"Unexpected non-PNG raw capture files: {sorted(extra_files)}")
    return loaded, records


def source_rows(atlas: Image.Image) -> dict[str, list[Image.Image]]:
    result: dict[str, list[Image.Image]] = {}
    for row, slot in enumerate(("move", "boost", "death")):
        result[slot] = [
            atlas.crop(
                (
                    frame * FRAME_SIZE,
                    row * FRAME_SIZE,
                    (frame + 1) * FRAME_SIZE,
                    (row + 1) * FRAME_SIZE,
                )
            )
            for frame in range(FRAME_COUNT)
        ]
    return result


def scaled_source_fixture(frame: Image.Image, flip_h: bool) -> tuple[Image.Image, Image.Image, Image.Image]:
    source = frame.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if flip_h else frame
    scaled = source.resize(CAPTURE_SIZE, Image.Resampling.NEAREST)
    body_mask = scaled.getchannel("A")
    transparent_mask = ImageChops.invert(body_mask)
    expected = Image.new("RGBA", CAPTURE_SIZE, BACKGROUND)
    expected.alpha_composite(scaled)
    return expected.convert("RGB"), body_mask, transparent_mask


def max_channel_image(first: Image.Image, second: Image.Image) -> Image.Image:
    difference = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
    red, green, blue = difference.split()
    return ImageChops.lighter(ImageChops.lighter(red, green), blue)


def difference_metrics(
    first: Image.Image,
    second: Image.Image,
    mask: Image.Image | None = None,
    tolerance: int = RGBA_TOLERANCE,
) -> tuple[int, int, Image.Image]:
    maximum = max_channel_image(first, second)
    if mask is not None:
        maximum = ImageChops.multiply(maximum, mask)
    histogram = maximum.histogram()
    changed = sum(histogram[tolerance + 1 :])
    largest = max((index for index, count in enumerate(histogram) if count), default=0)
    changed_mask = maximum.point(lambda value: 255 if value > tolerance else 0, mode="1").convert("L")
    return changed, largest, changed_mask


def mask_centroid(mask: Image.Image) -> tuple[float, float]:
    width, _ = mask.size
    count = 0
    sum_x = 0.0
    sum_y = 0.0
    for index, value in enumerate(mask.getdata()):
        if value == 0:
            continue
        count += 1
        sum_x += index % width
        sum_y += index // width
    if count == 0:
        raise AssertionError("Cannot compute the centroid of an empty mask")
    return sum_x / count, sum_y / count


def audit_direction_pixels(
    captures: dict[str, Image.Image], rows: dict[str, list[Image.Image]]
) -> dict[str, object]:
    body_changed: dict[str, int] = {}
    body_max_error: dict[str, int] = {}
    tail_pixels: dict[str, int] = {}
    trail_body_intersections: dict[str, int] = {}
    trail_world_dots: dict[str, float] = {}
    for direction in DIRECTIONS:
        name = str(direction["name"])
        world_x, world_y = direction["world"]
        for frame_index, source in enumerate(rows["boost"]):
            key = f"{name}/frame_{frame_index}"
            raw = captures[f"direction_{name}_frame_{frame_index}.png"].convert("RGB")
            expected, body_mask, transparent_mask = scaled_source_fixture(
                source, bool(direction["flip_h"])
            )
            changed, largest, _ = difference_metrics(raw, expected, body_mask)
            if changed != 0 or largest > RGBA_TOLERANCE:
                raise AssertionError(f"Direction {key} changed source body pixels")
            _, _, changed_mask = difference_metrics(raw, expected, transparent_mask)
            count = sum(1 for value in changed_mask.getdata() if value)
            if count <= 0:
                raise AssertionError(f"Direction {key} produced no trail-only pixels")
            intersection = ImageChops.multiply(changed_mask, body_mask)
            intersection_count = sum(1 for value in intersection.getdata() if value)
            if intersection_count != 0:
                raise AssertionError(f"Direction {key} trail intersected the body mask")
            body_x, body_y = mask_centroid(body_mask)
            tail_x, tail_y = mask_centroid(changed_mask)
            world_dot = (tail_x - body_x) * float(world_x) + (tail_y - body_y) * float(world_y)
            if world_dot >= -0.5:
                raise AssertionError(f"Direction {key} trail is not behind motion: {world_dot}")
            body_changed[key] = changed
            body_max_error[key] = largest
            tail_pixels[key] = count
            trail_body_intersections[key] = intersection_count
            trail_world_dots[key] = world_dot
    return {
        "body_changed_pixels": body_changed,
        "body_max_channel_error": body_max_error,
        "trail_only_pixels": tail_pixels,
        "trail_body_intersection_pixels": trail_body_intersections,
        "trail_world_direction_dot": trail_world_dots,
    }


def audit_status_pixels(
    captures: dict[str, Image.Image], rows: dict[str, list[Image.Image]]
) -> dict[str, object]:
    result: dict[str, object] = {}
    for status in STATUS_VARIANTS:
        body_changed_vs_no_status: dict[str, int] = {}
        afterimage_body_changed: dict[str, int] = {}
        tail_changed_vs_no_status: dict[str, int] = {}
        baseline_tail_pixels: dict[str, int] = {}
        for frame_index, source in enumerate(rows["boost"]):
            key = f"frame_{frame_index}"
            expected, body_mask, transparent_mask = scaled_source_fixture(source, False)
            no_status = captures[f"direction_right_frame_{frame_index}.png"].convert("RGB")
            active = captures[f"status_{status}_active_frame_{frame_index}.png"].convert("RGB")
            baseline = captures[f"status_{status}_baseline_frame_{frame_index}.png"].convert("RGB")
            changed_status, _, _ = difference_metrics(active, no_status, body_mask)
            if changed_status <= 0:
                raise AssertionError(f"Status {status}/{key} did not visibly change body pixels")
            changed_body, largest_body, _ = difference_metrics(active, baseline, body_mask)
            if changed_body != 0 or largest_body > RGBA_TOLERANCE:
                raise AssertionError(f"Afterimage changed status body pixels: {status}/{key}")
            changed_tail, largest_tail, _ = difference_metrics(active, no_status, transparent_mask)
            if changed_tail != 0 or largest_tail > RGBA_TOLERANCE:
                raise AssertionError(f"Status colored or changed afterimage pixels: {status}/{key}")
            baseline_tail, _, _ = difference_metrics(baseline, expected, transparent_mask)
            if baseline_tail != 0:
                raise AssertionError(f"Status baseline unexpectedly contains a tail: {status}/{key}")
            body_changed_vs_no_status[key] = changed_status
            afterimage_body_changed[key] = changed_body
            tail_changed_vs_no_status[key] = changed_tail
            baseline_tail_pixels[key] = baseline_tail
        result[status] = {
            "strengths": STATUS_VARIANTS[status],
            "status_body_changed_vs_no_status": body_changed_vs_no_status,
            "afterimage_body_changed_active_vs_baseline": afterimage_body_changed,
            "tail_changed_vs_no_status": tail_changed_vs_no_status,
            "baseline_tail_pixels": baseline_tail_pixels,
        }
    return result


def audit_transition_pixels(
    captures: dict[str, Image.Image], rows: dict[str, list[Image.Image]]
) -> dict[str, object]:
    result: dict[str, object] = {}
    for transition, spec in TRANSITIONS.items():
        changed_pixels: dict[str, int] = {}
        max_channel_error: dict[str, int] = {}
        for output_index, (slot, source_index) in enumerate(spec["sequence"]):
            raw = captures[f"{transition}_frame_{output_index}.png"].convert("RGB")
            if slot == "boost":
                expected = captures[f"direction_right_frame_{source_index}.png"].convert("RGB")
            else:
                expected, _, _ = scaled_source_fixture(rows[slot][source_index], False)
            changed, largest, _ = difference_metrics(raw, expected)
            if changed != 0 or largest > RGBA_TOLERANCE:
                raise AssertionError(
                    f"Transition {transition}/frame_{output_index} diverged from {slot}[{source_index}]"
                )
            changed_pixels[f"frame_{output_index}"] = changed
            max_channel_error[f"frame_{output_index}"] = largest
        result[transition] = {
            "sequence": [[slot, index] for slot, index in spec["sequence"]],
            "durations_ms": list(spec["durations_ms"]),
            "changed_pixels_vs_expected": changed_pixels,
            "max_channel_error_vs_expected": max_channel_error,
        }
    return result


def fixed_palette_colors(atlas: Image.Image) -> list[tuple[int, int, int]]:
    colors: list[tuple[int, int, int]] = [BACKGROUND[:3]]
    colors.extend(sorted({pixel[:3] for pixel in atlas.getdata() if pixel[3]}))
    levels = (0, 51, 102, 153, 204, 255)
    colors.extend((red, green, blue) for red in levels for green in levels for blue in levels)
    unique: list[tuple[int, int, int]] = []
    seen: set[tuple[int, int, int]] = set()
    for color in colors:
        if color not in seen:
            seen.add(color)
            unique.append(color)
    if len(unique) > 256:
        raise AssertionError(f"Frozen fallback GIF palette exceeded 256 colors: {len(unique)}")
    return unique


def palette_image(colors: list[tuple[int, int, int]]) -> Image.Image:
    palette = [channel for color in colors for channel in color]
    palette.extend([0] * (768 - len(palette)))
    image = Image.new("P", (1, 1))
    image.putpalette(palette)
    return image


def encode_gif_bytes(
    frames: list[Image.Image], durations_ms: list[int], atlas: Image.Image
) -> tuple[bytes, dict[str, object], list[Image.Image]]:
    if len(frames) != FRAME_COUNT or len(durations_ms) != FRAME_COUNT:
        raise AssertionError("Every third-gate GIF must contain exactly eight frames")
    # Godot rejects any raw frame above the GIF color budget.  Preserve each
    # accepted frame exactly with its own deterministic local color table;
    # this avoids both median-cut drift and a lossy shared union palette.
    rgb_frames = [frame.convert("RGB") for frame in frames]
    indexed: list[Image.Image] = []
    frame_palette_counts: list[int] = []
    frame_palette_sha256: list[str] = []
    for frame_index, frame in enumerate(rgb_frames):
        colors = sorted(set(frame.getdata()))
        if len(colors) > 256:
            raise AssertionError(
                f"GIF frame {frame_index} exceeds the exact local palette budget: {len(colors)}"
            )
        indices = {color: index for index, color in enumerate(colors)}
        prepared = Image.new("P", frame.size)
        prepared.putpalette(palette_image(colors).getpalette())
        prepared.putdata([indices[pixel] for pixel in frame.getdata()])
        indexed.append(prepared)
        palette_bytes = bytes(channel for color in colors for channel in color)
        frame_palette_counts.append(len(colors))
        frame_palette_sha256.append(hashlib.sha256(palette_bytes).hexdigest())
    decoded_expected = [frame.convert("RGB") for frame in indexed]
    raw_max_error = 0
    raw_changed_pixels = 0
    for raw, prepared in zip(rgb_frames, decoded_expected):
        changed, largest, _ = difference_metrics(raw, prepared, tolerance=0)
        raw_changed_pixels += changed
        raw_max_error = max(raw_max_error, largest)
    if raw_changed_pixels != 0 or raw_max_error != 0:
        raise AssertionError("Exact per-frame GIF palettes unexpectedly changed raw RGB pixels")

    def encode_once() -> bytes:
        output = io.BytesIO()
        indexed[0].save(
            output,
            format="GIF",
            save_all=True,
            append_images=indexed[1:],
            duration=durations_ms,
            loop=0,
            optimize=False,
            disposal=2,
        )
        return output.getvalue()

    first = encode_once()
    second = encode_once()
    if first != second:
        raise AssertionError("GIF encoding was not deterministic in memory")
    with Image.open(io.BytesIO(first)) as decoded:
        if decoded.n_frames != FRAME_COUNT:
            raise AssertionError(f"GIF frame count drifted: {decoded.n_frames}")
        decoded_durations: list[int] = []
        for index, expected in enumerate(decoded_expected):
            decoded.seek(index)
            decoded_durations.append(int(decoded.info.get("duration", -1)))
            if decoded.convert("RGB").tobytes() != expected.tobytes():
                raise AssertionError(f"GIF palette/decoder damaged frame {index}")
    if decoded_durations != durations_ms:
        raise AssertionError(
            f"GIF durations drifted: expected={durations_ms} actual={decoded_durations}"
        )
    audit = {
        "mode": "lossless_per_frame_exact_palette",
        "frame_palette_color_counts": frame_palette_counts,
        "frame_palette_rgb_sha256": frame_palette_sha256,
        "raw_changed_pixels_after_palette_projection": raw_changed_pixels,
        "raw_max_channel_error_after_palette_projection": raw_max_error,
        "decoded_matches_raw_rgb": True,
        "deterministic_double_encode": True,
        "durations_ms": durations_ms,
    }
    return first, audit, decoded_expected


def save_verified_gif(
    frames: list[Image.Image],
    durations_ms: list[int],
    path: Path,
    atlas: Image.Image,
) -> dict[str, object]:
    ensure_dev_asset_output(path)
    data, audit, _ = encode_gif_bytes(frames, durations_ms, atlas)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    if path.read_bytes() != data:
        raise AssertionError(f"GIF write roundtrip failed: {path}")
    return {
        "path": relative(path),
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
        "frame_count": FRAME_COUNT,
        **audit,
    }


def package_gifs(captures: dict[str, Image.Image], atlas: Image.Image) -> dict[str, object]:
    outputs: dict[str, object] = {}
    for direction in DIRECTIONS:
        name = str(direction["name"])
        frames = [captures[f"direction_{name}_frame_{frame}.png"] for frame in range(FRAME_COUNT)]
        path = PREVIEW_DIRECTORY / f"combat_robot_ninja_elite_afterimage_{name}.gif"
        outputs[f"direction_{name}"] = save_verified_gif(frames, [40] * FRAME_COUNT, path, atlas)
    for transition, spec in TRANSITIONS.items():
        frames = [captures[f"{transition}_frame_{frame}.png"] for frame in range(FRAME_COUNT)]
        path = PREVIEW_DIRECTORY / f"combat_robot_ninja_elite_afterimage_{transition}.gif"
        outputs[transition] = save_verified_gif(frames, list(spec["durations_ms"]), path, atlas)
    for status in STATUS_VARIANTS:
        frames = [captures[f"status_{status}_active_frame_{frame}.png"] for frame in range(FRAME_COUNT)]
        path = PREVIEW_DIRECTORY / f"combat_robot_ninja_elite_afterimage_{status}.gif"
        outputs[f"status_{status}"] = save_verified_gif(frames, [40] * FRAME_COUNT, path, atlas)
    if len(outputs) != 12:
        raise AssertionError(f"Third-gate GIF output count drifted: {len(outputs)}")
    return outputs


def verify_capture_builder(report: dict[str, object]) -> dict[str, str]:
    record = report.get("capture_builder")
    if not isinstance(record, dict):
        raise AssertionError("Godot runtime report is missing capture_builder lock")
    resource_path = record.get("path")
    if not isinstance(resource_path, str) or not resource_path.startswith("res://dev_tools/"):
        raise AssertionError(f"Godot capture_builder path is invalid: {resource_path!r}")
    local = ROOT / resource_path.removeprefix("res://")
    require_file(local)
    actual = sha256(local)
    if record.get("sha256") != actual:
        raise AssertionError("Godot capture builder changed after raw capture")
    return {"path": relative(local), "sha256": actual}


def package_previews(approval_requested: bool = False) -> None:
    approval_certificate = resolve_third_gate_approval(approval_requested)
    third_human_approved = approval_certificate is not None
    stage = (
        "afterimage_third_human_gate_approved"
        if third_human_approved
        else "afterimage_pending_third_human_gate"
    )
    atlas, source_manifest = verify_prepared_source()
    production_locks = verify_local_production_locks()
    raw_report_path = require_file(RAW_DIRECTORY / "runtime_report.json")
    runtime_report = json.loads(raw_report_path.read_text(encoding="utf-8"))
    if not isinstance(runtime_report, dict):
        raise AssertionError("Godot runtime_report.json must be an object")
    verify_runtime_report_header(runtime_report, source_manifest)
    verify_material_and_sampling(runtime_report)
    verify_direction_schema(runtime_report)
    verify_status_phase_death_and_atlas_schema(runtime_report)
    capture_builder = verify_capture_builder(runtime_report)
    captures, capture_records = verify_capture_inventory(runtime_report)
    rows = source_rows(atlas)
    direct_direction_audit = audit_direction_pixels(captures, rows)
    direct_status_audit = audit_status_pixels(captures, rows)
    direct_transition_audit = audit_transition_pixels(captures, rows)
    outputs = package_gifs(captures, atlas)

    report = {
        "schema_version": 1,
        "asset": "combat_robot_ninja_elite_afterimage",
        "stage": stage,
        "preview_only": True,
        "approved_animation_selection": APPROVED_SELECTION,
        "second_human_approved": True,
        "third_human_approved": third_human_approved,
        "third_human_approval": approval_certificate,
        "final_human_approved": False,
        "runtime_written": False,
        "runtime_paths_written": [],
        "builder": {
            "path": relative(Path(__file__).resolve()),
            "sha256": sha256(Path(__file__).resolve()),
        },
        "capture_builder": capture_builder,
        "animation_manifest": {
            "path": relative(ANIMATION_MANIFEST),
            "sha256": EXPECTED_ANIMATION_MANIFEST_SHA256,
        },
        "review_source": {
            "path": relative(REVIEW_SOURCE),
            "sha256": EXPECTED_REVIEW_SOURCE_SHA256,
            "rgba_sha256": EXPECTED_REVIEW_SOURCE_RGBA_SHA256,
            "size": list(ATLAS_SIZE),
            "sidecar": relative(REVIEW_SOURCE_MANIFEST),
            "sidecar_sha256": sha256(REVIEW_SOURCE_MANIFEST),
        },
        "production_file_locks": production_locks,
        "godot_runtime_report": {
            "path": relative(raw_report_path),
            "sha256": sha256(raw_report_path),
            "payload": runtime_report,
        },
        "raw_captures": capture_records,
        "direct_pixel_audit": {
            "direction": direct_direction_audit,
            "status": direct_status_audit,
            "transitions": direct_transition_audit,
            "rgba_tolerance_byte": RGBA_TOLERANCE,
            "background_rgba": list(BACKGROUND),
            "capture_size": list(CAPTURE_SIZE),
            "review_scale": REVIEW_SCALE,
        },
        "outputs": outputs,
        "checks": {
            "approved_m1_s2_d1_file_and_rgba_sha_locked": True,
            "source_rows_byte_identical": True,
            "production_shader_file_sha_locked": True,
            "production_shader_used_directly": True,
            "source_body_rgba_change_zero": True,
            "trail_samples_original_rgb_only": True,
            "slow_burn_do_not_color_trail": True,
            "six_world_flip_local_direction_contract": True,
            "phase_switch_preserves_frame_progress_and_play_state": True,
            "death_first_frame_clears_afterimage": True,
            "one_shared_material_and_shader": True,
            "no_material_creation_duplication_or_uniform_mutation": True,
            "instance_parameters_isolated": True,
            "atlas_filter_clip_and_standalone_match": True,
            "raw_capture_inventory_exact": True,
            "gif_decodes_exactly_to_declared_palette_projection": True,
            "gif_double_encode_deterministic": True,
            "third_human_approval_recorded": third_human_approved,
            "runtime_written": False,
        },
    }
    write_json(FINAL_REPORT, report)
    manifest = {
        "schema_version": 1,
        "asset": "combat_robot_ninja_elite",
        "stage": stage,
        "approved_anchor": "n1c",
        "approved_animation_selection": APPROVED_SELECTION,
        "approved_native_locks": APPROVED_NATIVE_LOCKS,
        "second_human_approved": True,
        "third_human_approved": third_human_approved,
        "third_human_approval": approval_certificate,
        "final_human_approved": False,
        "runtime_written": False,
        "runtime_paths_written": [],
        "review_source": {
            "path": relative(REVIEW_SOURCE),
            "sha256": EXPECTED_REVIEW_SOURCE_SHA256,
            "rgba_sha256": EXPECTED_REVIEW_SOURCE_RGBA_SHA256,
        },
        "report": relative(FINAL_REPORT),
        "report_sha256": sha256(FINAL_REPORT),
        "outputs": {
            key: {"path": value["path"], "sha256": value["sha256"]}
            for key, value in outputs.items()
        },
    }
    write_json(AFTERIMAGE_MANIFEST, manifest)
    print("COMBAT_ROBOT_NINJA_ELITE_AFTERIMAGE_PREVIEWS_OK")
    print(f"report={relative(FINAL_REPORT)}")
    print(f"manifest={relative(AFTERIMAGE_MANIFEST)}")
    print(f"gifs={len(outputs)}")


def main() -> None:
    args = parse_args()
    if args.prepare_source and args.approve:
        raise AssertionError("--prepare-source and --approve are mutually exclusive")
    if args.prepare_source:
        prepare_source()
    else:
        package_previews(approval_requested=args.approve)


if __name__ == "__main__":
    main()
