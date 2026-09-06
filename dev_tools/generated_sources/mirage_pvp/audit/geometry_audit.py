"""Read-only Mirage geometry audit. Never imports or runs build_mirage_map.py.

Reads the shipped .tscn, literal polygon data through AST, and player circle size.
Running this file writes only sibling geometry_audit.json; it does not start Godot.
"""
from __future__ import annotations

import ast
import base64
from collections import deque
import hashlib
import json
import math
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[4]
MAP_PATH = ROOT / "scene/pvp/maps/mirage_map.tscn"
BUILDER_PATH = ROOT / "dev_tools/build_mirage_map.py"
PLAYER_PATH = ROOT / "scene/pvp/pvp_player.tscn"
ORIGINAL_RADAR_PATH = Path(__file__).with_name("de_mirage_original_radar.png")
OUTPUT_PATH = Path(__file__).with_suffix(".json")


def numbers(text: str) -> tuple[float, ...]:
    return tuple(float(part) for part in text.split(","))


def parse_scene() -> tuple[list[list[int]], list[dict], dict]:
    source = MAP_PATH.read_text(encoding="utf-8")
    shapes = {}
    for match in re.finditer(r'\[sub_resource type="RectangleShape2D" id="([^"]+)"\]\s*size = Vector2\(([^)]+)\)', source):
        shapes[match.group(1)] = numbers(match.group(2))
    nodes = {}
    floor_cells = []
    for match in re.finditer(r'\[node ([^\n]+)\]\n(.*?)(?=\n\[node |\Z)', source, re.S):
        header, body = match.groups()
        name = re.search(r'name="([^"]+)"', header).group(1)
        parent_match = re.search(r'parent="([^"]+)"', header)
        parent = parent_match.group(1) if parent_match else ""
        path = name if parent in ("", ".") else parent + "/" + name
        position_match = re.search(r'^position = Vector2\(([^)]+)\)', body, re.M)
        px, py = numbers(position_match.group(1)) if position_match else (0.0, 0.0)
        if parent in nodes:
            ppx, ppy = nodes[parent]["world_position"]
            px, py = px + ppx, py + ppy
        nodes[path] = {"world_position": (px, py), "body": body,
                       "line": source.count("\n", 0, match.start()) + 1}
        if name == "WalkableFloor":
            encoded = re.search(r'tile_map_data = PackedByteArray\("([^"]+)"\)', body).group(1)
            raw = base64.b64decode(encoded)
            assert raw[:2] == b"\x00\x00"
            floor_cells = [[x, y, atlas_x, atlas_y] for x, y, tile_source, atlas_x, atlas_y, alternative
                           in struct.iter_unpack("<hhhhhh", raw[2:])]
    obstacles = []
    for path, node in nodes.items():
        rect_match = re.search(r'metadata/obstacle_rect = Rect2\(([^)]+)\)', node["body"])
        if not rect_match:
            continue
        rx, ry, width, height = numbers(rect_match.group(1))
        px, py = node["world_position"]
        rect = (px + rx, py + ry, width, height)
        collision = nodes[path + "/Collision"]
        shape_id = re.search(r'shape = SubResource\("([^"]+)"\)', collision["body"]).group(1)
        sw, sh = shapes[shape_id]
        cx, cy = collision["world_position"]
        collision_rect = (cx - sw / 2, cy - sh / 2, sw, sh)
        assert all(abs(a - b) < 1e-5 for a, b in zip(rect, collision_rect)), path
        obstacles.append({"node": path, "node_line": node["line"], "rect": rect,
                          "collision_shape_verified": True})
    return floor_cells, obstacles, nodes


def read_builder_literals() -> dict:
    source = BUILDER_PATH.read_text(encoding="utf-8")
    module = ast.parse(source)
    areas = []
    fills = []
    constants = {}
    for node in module.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "AREAS":
                    for item in node.value.elts:
                        name, material, polygon = ast.literal_eval(item)
                        areas.append({"name": name, "material": material,
                                      "reference_polygon": polygon, "line": item.lineno})
                elif isinstance(target, ast.Name) and target.id == "S":
                    constants["cell_size"] = ast.literal_eval(node.value)
                elif isinstance(target, ast.Tuple) and [n.id for n in target.elts] == ["SX", "SY"]:
                    constants["reference_scale"] = ast.literal_eval(node.value)
        elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
            call = node.value
            if isinstance(call.func, ast.Name) and call.func.id == "fill_ref_rect":
                fills.append({"line": node.lineno, "arguments": [ast.literal_eval(a) for a in call.args]})
    return {"constants": constants, "areas": areas, "fill_rectangles": fills}


def point_rect_distance_sq(point, rect):
    x, y = point
    rx, ry, width, height = rect
    dx = max(rx - x, 0.0, x - rx - width)
    dy = max(ry - y, 0.0, y - ry - height)
    return dx * dx + dy * dy


def segment_hits_rect(a, b, rect):
    rx, ry, width, height = rect
    low, high = 0.0, 1.0
    for origin, delta, lower, upper in ((a[0], b[0] - a[0], rx, rx + width),
                                         (a[1], b[1] - a[1], ry, ry + height)):
        if abs(delta) < 1e-12:
            if origin < lower or origin > upper:
                return False
        else:
            t1, t2 = (lower - origin) / delta, (upper - origin) / delta
            low, high = max(low, min(t1, t2)), min(high, max(t1, t2))
            if low > high:
                return False
    return True


def point_segment_distance_sq(point, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length_sq = dx * dx + dy * dy
    fraction = 0.0 if length_sq == 0 else max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length_sq))
    return (point[0] - a[0] - fraction * dx) ** 2 + (point[1] - a[1] - fraction * dy) ** 2


def segment_rect_distance_sq(a, b, rect):
    if segment_hits_rect(a, b, rect):
        return 0.0
    rx, ry, width, height = rect
    corners = ((rx, ry), (rx + width, ry), (rx + width, ry + height), (rx, ry + height))
    return min(point_rect_distance_sq(a, rect), point_rect_distance_sq(b, rect),
               *(point_segment_distance_sq(corner, a, b) for corner in corners))


def segment_evidence(obstacles):
    definitions = [
        ("ladder_to_underpass", (293, 300), (323, 300), "Ladder Room and Underpass have no separating wall", [82, 84, 118]),
        ("vip_to_underpass", (280, 350), (323, 350), "VIP directly merges into offset Underpass", [83, 84, 118]),
        ("ladder_to_catwalk", (305, 330), (390, 330), "Added rectangle gives a direct same-plane Ladder-to-Catwalk crossing", [119]),
        ("vip_to_mid", (340, 375), (383, 375), "VIP window is a bidirectional walkable staircase", [120]),
        ("market_to_mid", (225, 373), (445, 373), "Market can shoot and walk directly through VIP to Mid", [83, 85, 108, 120]),
        ("catwalk_to_mid", (450, 335), (450, 380), "Catwalk/Mid boundary has no ledge or one-way transition", [79, 80, 108]),
        ("market_to_b_site", (180, 330), (180, 292), "Broad opening beside decorative market door", [71, 85, 257]),
        ("apartments_to_b_left", (181, 164), (181, 190), "West edge of broad apartments exit is open", [72, 121]),
        ("apartments_to_b_right", (235, 164), (235, 194), "East edge of broad apartments exit is open", [72, 121]),
    ]
    output = []
    for label, a, b, description, lines in definitions:
        wa, wb = (a[0] * 2.4, a[1] * 2.2), (b[0] * 2.4, b[1] * 2.2)
        ray_hits = [o["node"] for o in obstacles if segment_hits_rect(wa, wb, o["rect"])]
        circle_hits = [o["node"] for o in obstacles if segment_rect_distance_sq(wa, wb, o["rect"]) < 7 * 7]
        output.append({"id": label, "description": description, "reference_start": a, "reference_end": b,
                       "world_start": wa, "world_end": wb, "ray_blockers": ray_hits,
                       "radius_7_swept_circle_blockers": circle_hits, "builder_lines": lines,
                       "interpretation": "Current geometry confirmed; desired CS2 portal/height behavior must use a current authoritative reference."})
    return output


def local_reachability(obstacles, radius):
    # Deliberately limit the test to A1: the global alternative through A2 is not
    # evidence that the A1 arch itself can be traversed. Coordinates are the
    # player's collision-circle center (node origin is 3 px above this center).
    bounds = (1344, 1040, 224, 184)
    left, top, width, height = bounds
    start, goal = (1400, 1136), (1480, 1136)
    relevant = [o for o in obstacles if not (
        o["rect"][0] + o["rect"][2] < left - radius or o["rect"][0] > left + width + radius or
        o["rect"][1] + o["rect"][3] < top - radius or o["rect"][1] > top + height + radius)]
    clear = {(x, y) for y in range(top, top + height + 1) for x in range(left, left + width + 1)
             if all(point_rect_distance_sq((x, y), o["rect"]) >= radius * radius for o in relevant)}
    assert start in clear and goal in clear
    previous = {start: None}
    queue = deque([start])
    while queue:
        point = queue.popleft()
        if point == goal:
            break
        x, y = point
        for neighbor in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if neighbor in clear and neighbor not in previous:
                previous[neighbor] = point
                queue.append(neighbor)
    path = []
    if goal in previous:
        cursor = goal
        while cursor is not None:
            path.append(cursor)
            cursor = previous[cursor]
        path.reverse()
    # Analytic cross-section: every local left-to-right path crosses x=1438,
    # within the left pier. The only gap is narrower than a diameter-14 circle.
    return {"radius": radius, "bounds": bounds, "start_circle_center": start,
            "goal_circle_center": goal, "grid_step": 1, "neighbor_count": 4,
            "distance_test": "Exact point-to-AABB Euclidean distance (rounded circle corners, not an expanded bounding box)",
            "reachable": goal in previous, "visited_cells": len(previous), "clear_cells": len(clear),
            "path_length": len(path) - 1 if path else None,
            "path_sampled_every_8_points": path[::8] + ([path[-1]] if path else []),
            "obstacles_checked": [o["node"] for o in relevant]}


def build_audit():
    inputs = (MAP_PATH, BUILDER_PATH, PLAYER_PATH)
    original_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    canonical_hashes = {path.relative_to(ROOT).as_posix(): hashlib.sha256(
        path.read_text(encoding="utf-8").encode("utf-8")).hexdigest() for path in inputs}
    floor_cells, obstacles, nodes = parse_scene()
    literals = read_builder_literals()
    floor_set = {(cell[0], cell[1]) for cell in floor_cells}
    apertures = []
    for label, row, min_x, max_x in (("B apartments south", 12, 400, 600), ("Market north", 21, 300, 600)):
        xs = sorted(x for x, y in floor_set if y == row and (x, row - 1) in floor_set and min_x <= x * 32 < max_x)
        apertures.append({"name": label, "world_y": row * 32, "continuous_floor_interval": [min(xs) * 32, (max(xs) + 1) * 32],
                          "floor_width": len(xs) * 32, "note": "Floor interface before separately placed props; inspect obstacle rectangles for piers."})
    blocker = next(o for o in obstacles if o["node"] == "Archways/ARampArchLeft")
    south_wall = next(o for o in obstacles if o["node"] == "Walls/Wall048")
    gap = south_wall["rect"][1] - blocker["rect"][1] - blocker["rect"][3]
    result = {
        "method": "Read-only .tscn parsing plus ast.literal_eval; no build-script import, no Godot process, no game writes.",
        "input_sha256": canonical_hashes,
        "input_hash_normalization": "UTF-8 text with CRLF/CR normalized to LF for cross-platform Git checkouts.",
        "world_size": [1920, 1600], "cell_size": 32,
        "floor_cell_format": ["grid_x", "grid_y", "atlas_x", "atlas_y"],
        "floor_cells": sorted(floor_cells), "floor_cell_count": len(floor_cells),
        "world_obstacles": obstacles, "world_obstacle_count": len(obstacles),
        "all_metadata_rects_match_native_collision_shapes": True,
        "builder_literal_data": literals, "example_segments": segment_evidence(obstacles),
        "apertures": apertures,
        "a1_local_blockage": {"left_pier": blocker, "south_wall": south_wall,
            "corridor_y_interval": [1088, 1184], "analytic_cross_section_world_x": 1438,
            "gap_below_left_pier": gap, "player_circle_radius": 7, "player_diameter": 14,
            "radius_7": local_reachability(obstacles, 7), "radius_5_control": local_reachability(obstacles, 5),
            "conclusion": "A1's local west/east corridor is blocked for radius 7. Radius 5 passes the 11.4 px gap; global A2 detours do not restore the missing A1 route.",
            "builder_lines": [257, 265, 266], "validation_gap_lines": [345, 349, 353, 355]},
        "rasterization": {"reference_scale_x": 2.4, "reference_scale_y": 2.2,
            "aspect_ratio_distortion_percent": (2.4 / 2.2 - 1) * 100,
            "one_cell_in_reference_pixels": [32 / 2.4, 32 / 2.2],
            "market_vip_reference_gap": 239 - 235, "market_vip_ideal_world_gap": (239 - 235) * 2.4,
            "builder_lines": [21, 23, 83, 85, 108, 142]},
    }
    result["original_radar_visual_review"] = {
        "file": ORIGINAL_RADAR_PATH.relative_to(ROOT).as_posix(),
        "sha256": hashlib.sha256(ORIGINAL_RADAR_PATH.read_bytes()).hexdigest(),
        "image_size": struct.unpack(">II", ORIGINAL_RADAR_PATH.read_bytes()[16:24]),
        "method": "Original radar inspected directly with view_image; no generated overlay or automatic segmentation used to establish these findings.",
        "confirmed_findings": [
            {"priority": "P1", "id": "a1_locally_blocked", "builder_lines": [257, 265, 266],
             "finding": "The original radar has a continuous A-ramp route. The local radius-7 check proves the shipped arch pier blocks this corridor; this conclusion does not depend on interpreting radar elevation."},
            {"priority": "P1", "id": "market_vip_mid_false_connection", "builder_lines": [83, 85, 108, 142],
             "finding": "Original radar separates Market from the narrow VIP/window room with a solid wall/building mass. Shipped geometry permits a straight Market-to-Mid crossing through VIP. Window is already mistraced too far west, before rasterization removes its remaining 4-reference-pixel gap from Market."},
            {"priority": "P1", "id": "underpass_ladder_vip_merged", "builder_lines": [82, 83, 84, 118, 119, 120],
             "finding": "Original radar distinguishes hatched underpass, ladder/vent room and narrow window room. Shipped offset underpass intersects both room polygons; added floor rectangles make all three one ordinary walkable and shootable plane.",
             "limit": "Radar alone does not prove every conceptual room-to-room link must be forbidden. Exact door, vent, drop and ladder directionality requires current in-game height references."},
            {"priority": "P1", "id": "market_door_window_partition_lost", "builder_lines": [71, 85, 257],
             "finding": "Original radar retains Market's north wall and distinct apertures into B. Shipped north interface is 224 world pixels wide before props, with an arch standing inside the opening instead of a wall/door/window structure."},
            {"priority": "P1", "id": "catwalk_bidirectional_flat_boundary", "builder_lines": [79, 80, 108],
             "finding": "Original radar marks the catwalk/mid ledge. Shipped boundary is continuous flat floor and can be crossed both ways at multiple points.",
             "limit": "This is loss of elevation/traversal semantics, not a claim that catwalk-to-mid shots should all be blocked."},
            {"priority": "P2", "id": "apartments_exit_broadened", "builder_lines": [72, 121],
             "finding": "Original radar shows apartments wall/exit/ledge structure. Current south aperture spans world x416..576 at y384: 160 pixels of unrestricted flat opening; the added staircase removes ledge/drop semantics.",
             "limit": "Exact current CS2 opening widths cannot be inferred from the old annotated image alone; retrace this original radar and verify elevation in game."},
        ],
        "remaining_reference_checks": [
            "Precise current CS2 doorway/window sizes and directional drop/ladder transitions.",
            "A1/Palace entrance divider and Palace Roof outline: exact corrected coordinates need a fresh trace.",
            "Do not describe all nine example segments as categorically forbidden CS2 bullet rays: they prove current flat connectivity, while height semantics differ by edge.",
        ],
    }
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == original_hashes[str(path.relative_to(ROOT))] for path in inputs)
    assert not result["a1_local_blockage"]["radius_7"]["reachable"]
    assert result["a1_local_blockage"]["radius_5_control"]["reachable"]
    return result


if __name__ == "__main__":
    audit = build_audit()
    OUTPUT_PATH.write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(OUTPUT_PATH), "floor_cells": audit["floor_cell_count"],
                      "obstacles": audit["world_obstacle_count"],
                      "radius_7_a1_reachable": audit["a1_local_blockage"]["radius_7"]["reachable"],
                      "radius_5_a1_reachable": audit["a1_local_blockage"]["radius_5_control"]["reachable"]}, ensure_ascii=False))
