"""Fetch Windows templates from the official Godot archive using bounded ranges.

Reads ZIP metadata and the selected compressed members instead of downloading
the 1.25 GB archive. HTTPS establishes the source; ZIP sizes and CRC are checked.
The member hash is recorded locally, not claimed to be an official member hash.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import zipfile
import zlib

import requests


class RemoteArchive(io.RawIOBase):
    def __init__(self, session: requests.Session, url: str, size: int):
        self.session, self.url, self.size, self.position = session, url, size, 0

    def seek(self, offset: int, whence: int = 0) -> int:
        self.position = offset + (self.position if whence == 1 else self.size if whence == 2 else 0)
        return self.position

    def tell(self) -> int:
        return self.position

    def read(self, amount: int = -1) -> bytes:
        end = self.size if amount < 0 else min(self.position + amount, self.size)
        if end <= self.position:
            return b""
        with self.session.get(self.url, headers={"Range": f"bytes={self.position}-{end - 1}"}, stream=True, timeout=60) as response:
            response.raise_for_status()
            expected = f"bytes {self.position}-{end - 1}/{self.size}"
            if response.status_code != 206 or response.headers.get("Content-Range") != expected:
                raise RuntimeError("Download server did not honor the exact bounded byte range")
            data = response.content
        if len(data) != end - self.position:
            raise RuntimeError("Truncated range response")
        self.position = end
        return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="4.6.2-stable")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--proxy", help="Optional HTTP proxy, never read from unrelated private configuration")
    parser.add_argument("--debug", action="store_true", help="Also fetch the matching debug template")
    args = parser.parse_args()
    session = requests.Session()
    if args.proxy:
        session.proxies.update({"http": args.proxy, "https": args.proxy})
    release_api = f"https://api.github.com/repos/godotengine/godot-builds/releases/tags/{args.version}"
    response = session.get(release_api, timeout=30)
    response.raise_for_status()
    asset = next(item for item in response.json()["assets"] if item["name"] == f"Godot_v{args.version}_export_templates.tpz")
    archive = RemoteArchive(session, asset["browser_download_url"], asset["size"])
    metadata = {"release_api": release_api, "archive_url": archive.url, "archive_size": archive.size,
                "archive_published_digest": asset.get("digest"), "whole_archive_hash_verified": False,
                "verification": "Official HTTPS byte ranges, member size and ZIP CRC; local SHA256 recorded", "members": []}
    args.output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as package:
        for kind in ["release", "debug"] if args.debug else ["release"]:
            name = f"templates/windows_{kind}_x86_64.exe"
            info = package.getinfo(name)
            archive.seek(info.header_offset)
            header = archive.read(30)
            signature, _, _, compression, _, _, _, _, _, name_length, extra_length = struct.unpack("<4s5H3I2H", header)
            if signature != b"PK\x03\x04" or compression != zipfile.ZIP_DEFLATED:
                raise RuntimeError("Unexpected template ZIP header or compression")
            archive.seek(info.header_offset + 30 + name_length + extra_length)
            compressed = archive.read(info.compress_size)
            binary = zlib.decompress(compressed, -15)
            if len(binary) != info.file_size or zlib.crc32(binary) & 0xFFFFFFFF != info.CRC:
                raise RuntimeError("Template member failed size/CRC verification")
            destination = args.output / f"Godot_{kind}.exe"
            destination.write_bytes(binary)
            record = {"member": name, "path": str(destination.resolve()), "bytes": len(binary),
                      "downloaded_member_bytes": len(compressed), "sha256": hashlib.sha256(binary).hexdigest()}
            metadata["members"].append(record)
            print(json.dumps(record), flush=True)
    (args.output / "template_source.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
