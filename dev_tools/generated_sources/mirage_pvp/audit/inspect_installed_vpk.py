"""Read only VPK directory metadata and extract a narrowly selected audit asset."""
from pathlib import Path
import argparse
import json
import struct
import zlib


def directory(path: Path):
    with path.open("rb") as stream:
        signature, version, tree_size = struct.unpack("<III", stream.read(12))
        assert signature == 0x55AA1234 and version in (1, 2)
        header_size = 28 if version == 2 else 12
        stream.seek(header_size)
        tree = stream.read(tree_size)
    cursor = 0

    def cstring():
        nonlocal cursor
        end = tree.index(0, cursor)
        value = tree[cursor:end].decode("utf-8")
        cursor = end + 1
        return value

    entries = []
    while extension := cstring():
        while folder := cstring():
            while name := cstring():
                crc, preload_count, archive, offset, length, terminator = struct.unpack_from("<IHHIIH", tree, cursor)
                cursor += 18
                assert terminator == 0xFFFF
                preload = tree[cursor:cursor + preload_count]
                cursor += preload_count
                asset = ("" if folder == " " else folder + "/") + name + ("" if extension == " " else "." + extension)
                entries.append({"path": asset, "crc32": f"{crc:08x}", "preload_bytes": preload_count, "archive": archive, "offset": offset, "length": length, "preload": preload})
    return version, header_size + tree_size, entries


def extract(vpk: Path, data_start: int, entry: dict, destination: Path):
    if entry["archive"] == 0x7FFF:
        archive = vpk
        offset = data_start + entry["offset"]
    else:
        archive = vpk.with_name(vpk.name.removesuffix("_dir.vpk") + f"_{entry['archive']:03d}.vpk")
        offset = entry["offset"]
    with archive.open("rb") as stream:
        stream.seek(offset)
        data = entry["preload"] + stream.read(entry["length"])
    assert len(data) == entry["preload_bytes"] + entry["length"]
    assert f"{zlib.crc32(data):08x}" == entry["crc32"]
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return str(archive)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("vpk", type=Path)
    parser.add_argument("--contains", default="mirage")
    parser.add_argument("--extract")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    version, data_start, entries = directory(args.vpk)
    selected = [entry for entry in entries if args.contains.lower() in entry["path"].lower()]
    report = {"vpk": str(args.vpk), "vpk_version": version, "total_entries": len(entries), "matching_entries": [{key: value for key, value in entry.items() if key != "preload"} for entry in selected]}
    if args.extract:
        target = next(entry for entry in entries if entry["path"] == args.extract)
        report["extracted_archive"] = extract(args.vpk, data_start, target, args.output)
        report["extracted_output"] = str(args.output)
    print(json.dumps(report, indent=2))
