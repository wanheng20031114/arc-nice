"""Create short-lived local-only room tickets using the production Lobby signer."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import secrets
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from relay_servers.lobby_api.relay_admission import RelayAdmissionTicketSigner


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--players", type=int, required=True)
    args = parser.parse_args()
    if not 2 <= args.players <= 8:
        parser.error("--players must be in 2..8")
    signer = RelayAdmissionTicketSigner()
    room_id = "density_" + secrets.token_hex(8)
    secret = secrets.token_hex(32)
    tickets = [
        signer.issue(secret, room_id, "host" if index == 0 else "member", f"Density{index}", 120)
        for index in range(args.players)
    ]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "relay_context.json").write_text(
        json.dumps({"room_id": room_id, "secret": secret, "tickets": tickets}), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
