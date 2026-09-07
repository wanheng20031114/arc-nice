"""Verify the checked-in relay mirrors before releasing a network protocol.

Run: python dev_tools/check_relay_rpc_parity.py
Uses source signatures, so it also works on the deployment checkout without a
Godot editor import. Does not contact or modify the deployed service.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
RPC = re.compile(
    r"@rpc\((.*?)\)\s*(?:@\w+\([^\n]*\)\s*)*func\s+(\w+)\s*"
    r"\((.*?)\)\s*->\s*([^:\n]+):",
    re.DOTALL,
)


def signatures(relative: str) -> dict[str, tuple[str, str, str]]:
    text = (ROOT / relative).read_text(encoding="utf-8")
    result = {}
    for annotation, name, arguments, returns in RPC.findall(text):
        arguments = re.sub(r"#[^\n]*", "", arguments)
        # The standalone relay intentionally has no EnemyConfig dependency.
        # Verify this enum's declaration below before resolving its default.
        arguments = arguments.replace("EnemyConfig.DamageType.PHYSICAL", "0")
        result[name] = tuple(
            re.sub(r"\s+", "", field).rstrip(",")
            for field in (annotation, arguments, returns)
        )
    if not result:
        raise ValueError(f"No RPC signatures found in {relative}")
    return result


def main() -> int:
    failures = []
    enemy_config = (ROOT / "resources/config/enemies/enemy_config.gd").read_text(encoding="utf-8")
    if not re.search(r"enum DamageType\s*\{\s*PHYSICAL\s*,", enemy_config):
        failures.append("EnemyConfig.DamageType.PHYSICAL is no longer the implicit zero enum")
    pairs = [
        ("scene/multiplayer/net_manager.gd", "relay_servers/relay_godot_project/relay_net_manager_stub.gd"),
        ("scene/multiplayer/mp_game.gd", "relay_servers/relay_godot_project/relay_mp_game_stub.gd"),
        ("scene/multiplayer/mp_rogue_route.gd", "relay_servers/relay_godot_project/relay_rogue_route_stub.gd"),
    ]
    for production_path, relay_path in pairs:
        production, relay = signatures(production_path), signatures(relay_path)
        for method in sorted(production.keys() | relay.keys()):
            if production.get(method) != relay.get(method):
                failures.append(f"{production_path}: {method}: {production.get(method)} != {relay.get(method)}")
        print(f"RPC_PARITY {production_path}: production={len(production)} relay={len(relay)}")
    versions = []
    for relative in ("scene/multiplayer/net_constants.gd", "relay_servers/relay_godot_project/relay_server.gd"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        versions.append(int(re.search(r"^const PROTOCOL_VERSION := (\d+)$", text, re.MULTILINE)[1]))
    if versions[0] != versions[1]:
        failures.append(f"Client/relay protocol version mismatch: {versions}")
    wrapper = "scene/multiplayer/transport/authenticated_relay_multiplayer_peer.gd"
    mirror = "relay_servers/relay_godot_project/authenticated_relay_multiplayer_peer.gd"
    if (ROOT / wrapper).read_bytes() != (ROOT / mirror).read_bytes():
        failures.append("Authenticated relay transport mirror differs")
    for failure in failures:
        print("FAIL:", failure, file=sys.stderr)
    print(f"RELAY_PARITY {'FAIL' if failures else 'PASS'} protocol={versions[0]} failures={len(failures)}")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
