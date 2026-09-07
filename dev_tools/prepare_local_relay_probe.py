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
    parser.add_argument("--refresh-reconnect", action="store_true")
    args = parser.parse_args()
    if not 2 <= args.players <= 8:
        parser.error("--players must be in 2..8")
    signer = RelayAdmissionTicketSigner()
    if args.refresh_reconnect:
        context_path = args.output_dir / "relay_context.json"
        context = json.loads(context_path.read_text(encoding="utf-8"))
        for key in ("reconnect_ticket", "rejected_identity_ticket"):
            context[key] = signer.issue(context["secret"], context["room_id"], "member", f"Density{args.players - 1}", 120)
        context_path.write_text(json.dumps(context), encoding="utf-8")
        (args.output_dir / "reconnect_tickets_refreshed.json").write_text('{"ready":true}', encoding="utf-8")
        return
    room_id = "density_" + secrets.token_hex(8)
    secret = secrets.token_hex(32)
    tickets = [
        signer.issue(secret, room_id, "host" if index == 0 else "member", f"Density{index}", 120)
        for index in range(args.players)
    ]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "relay_context.json").write_text(
        json.dumps({
            "room_id": room_id, "secret": secret, "tickets": tickets,
            # Reconnect keeps the gameplay token but must use a fresh relay
            # admission nonce. Reusing the original ticket is correctly rejected.
            "reconnect_ticket": signer.issue(secret, room_id, "member", f"Density{args.players - 1}", 120),
            "rejected_identity_ticket": signer.issue(secret, room_id, "member", f"Density{args.players - 1}", 120),
        }), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
