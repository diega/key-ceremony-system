#!/usr/bin/env python3
"""Inspect a built Pi image using regular files only; no mounts or devices."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect(args):
    image = Path(args.image)
    top = Path(args.toplevel)
    with image.open("rb") as source, tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        mbr = source.read(512)
        assert mbr[510:512] == b"\x55\xaa", "Missing MBR signature"
        partitions = []
        previous_end = 1
        for index in range(4):
            entry = mbr[446 + index * 16:462 + index * 16]
            kind = entry[4]
            start, sectors = struct.unpack("<II", entry[8:16])
            if not kind:
                assert start == sectors == 0, "Malformed empty partition"
                continue
            assert start >= previous_end and sectors > 0, "Invalid/overlapping partitions"
            assert (start + sectors) * 512 <= image.stat().st_size, "Truncated partition"
            previous_end = start + sectors
            partitions.append({"number": index + 1, "type": kind, "start": start, "sectors": sectors})
        assert len(partitions) == 2, "Expected firmware and root; swap is created on first boot"
        assert partitions[0]["number"] == 1 and partitions[0]["type"] in (0x0B, 0x0C)
        assert partitions[1]["number"] == 2 and partitions[1]["type"] == 0x83
        for partition, name in zip(partitions, ("firmware", "root")):
            source.seek(partition["start"] * 512)
            remaining = partition["sectors"] * 512
            with (work / name).open("wb") as destination:
                while remaining:
                    block = source.read(min(remaining, 4 * 1024 * 1024))
                    assert block, "Truncated image"
                    destination.write(block)
                    remaining -= len(block)
        firmware, root = work / "firmware", work / "root"
        print(run("fsck.fat", "-n", str(firmware)))
        print(run("e2fsck", "-fn", str(root)))

        def fat_file(name):
            destination = work / Path(name).name
            run("mcopy", "-i", str(firmware), f"::/{name}", str(destination))
            return destination

        configuration = fat_file("config.txt").read_text()
        command_line = fat_file("cmdline.txt").read_text().split()
        assert f"kernel={args.kernel}" in configuration.splitlines()
        assert f"init={args.init}" in command_line, "Unexpected boot init"
        for name in ("bootcode.bin", "start.elf", "fixup.dat"):
            assert fat_file(name).stat().st_size > 0
        assert digest(fat_file(args.kernel)) == digest(top / "kernel"), "Kernel differs from closure"
        for dtb in args.dtb:
            assert digest(fat_file(Path(dtb).name)) == digest(top / "dtbs" / dtb), "Device tree differs from closure"

        for index, path in enumerate(dict.fromkeys((f"{top}/init", args.init))):
            extracted = work / f"init-{index}"
            run("debugfs", "-R", f"dump {path} {extracted}", str(root))
            assert extracted.is_file() and digest(extracted) == digest(Path(path)), "Boot init missing or different"
        host_key = run("debugfs", "-R", "stat /etc/ssh/ssh_host_ed25519_key", str(root))
        assert not re.search(r"Inode:\s+\d+", host_key), "Image contains a shared SSH host key"

    report = {
        "platform": args.platform,
        "profile": args.profile + " policy with public fixture identity",
        "image_bytes": image.stat().st_size,
        "closure_nar_bytes": args.closure_size,
        "partitions": partitions,
        "checks": ["partition bounds", "FAT integrity", "ext4 integrity", "firmware files",
                   "kernel and device trees match closure", "boot init matches closure", "no shared SSH host key"],
        "boots_hardware": False,
    }
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--platform", required=True)
    parser.add_argument("--profile", choices=("production", "rehearsal"), required=True)
    parser.add_argument("--toplevel", required=True)
    parser.add_argument("--init", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--dtb", action="append", default=[])
    parser.add_argument("--closure-size", type=int, required=True)
    parser.add_argument("--report", required=True)
    inspect(parser.parse_args())
