# Encrypts a filesystem image the way dm-crypt's aes-xts-plain64 does with
# 512-byte sectors (tweak = sector number from the start of the data
# segment), and writes it into a LUKS container at the segment's offset:
# cryptsetup can't open a device in the build sandbox.
# Usage: encrypt-xts.py VOLUME_KEY FS_IMAGE CONTAINER OFFSET
import sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

key = open(sys.argv[1], "rb").read()
data = open(sys.argv[2], "rb").read()
offset = int(sys.argv[4])
assert len(key) == 64 and len(data) % 512 == 0

with open(sys.argv[3], "r+b") as out:
    out.seek(offset)
    for i in range(0, len(data), 512):
        enc = Cipher(algorithms.AES(key), modes.XTS((i // 512).to_bytes(16, "little"))).encryptor()
        out.write(enc.update(data[i : i + 512]) + enc.finalize())
