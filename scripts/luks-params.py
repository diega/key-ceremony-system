# Prints what unlocking a LUKS partition costs (KDF type, memory, time) from
# its header alone. Reads whole sectors covering LUKS1 header metadata or
# the LUKS2 binary header and JSON area, not the keyslot areas holding
# the encrypted volume key. Prints parameters only, writes nothing.
#
# Usage on the Mac: sudo python3 scripts/luks-params.py /dev/rdiskNs1
import json
import struct
import sys

dev = sys.argv[1]
with open(dev, "rb", buffering=0) as f:
    # Raw devices on macOS want whole-sector reads.
    head = f.read(4096)
    if head[:6] != b"LUKS\xba\xbe":
        sys.exit(f"{dev}: not a LUKS header")
    version = struct.unpack(">H", head[6:8])[0]
    if version == 1:
        cipher = head[8:40].rstrip(b"\0").decode()
        mode = head[40:72].rstrip(b"\0").decode()
        hash_ = head[72:104].rstrip(b"\0").decode()
        key_bytes = struct.unpack(">I", head[108:112])[0]
        print(f"LUKS1 {cipher}-{mode}, {key_bytes * 8}-bit key, PBKDF2-{hash_}")
        for i in range(8):
            off = 208 + i * 48
            active, iters = struct.unpack(">II", head[off : off + 8])
            if active == 0x00AC71F3:
                print(f"  keyslot {i}: PBKDF2, {iters} iterations (no memory cost)")
    elif version == 2:
        hdr_size = struct.unpack(">Q", head[8:16])[0]
        f.seek(0)
        hdr = f.read((hdr_size + 4095) // 4096 * 4096)[:hdr_size]
        meta = json.loads(hdr[4096:].split(b"\0", 1)[0])
        for n, seg in meta["segments"].items():
            print(f"LUKS2 segment {n}: {seg['encryption']}, sector size {seg.get('sector_size')}")
        for n, ks in meta["keyslots"].items():
            kdf = ks["kdf"]
            if kdf["type"] == "pbkdf2":
                print(f"  keyslot {n}: pbkdf2-{kdf['hash']}, {kdf['iterations']} iterations (no memory cost)")
            else:
                print(f"  keyslot {n}: {kdf['type']}, memory {kdf['memory'] // 1024} MiB, "
                      f"time {kdf['time']}, threads {kdf['cpus']}")
    else:
        sys.exit(f"LUKS version {version}?")
