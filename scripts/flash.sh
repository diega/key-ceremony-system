# Builds a key-ceremony-system SD image, injects a freshly generated SSH host key, pins
# it in ./known_hosts (vault.sh connects with StrictHostKeyChecking) and writes
# the card. The private host key only exists in a temp dir on the Mac and on
# the card.
#
# From the repository root on the Mac, supply the vault-config input:
# nix run --override-input vault-config path:./.local/vault-config .#flash -- /dev/diskN [image]
# Find N with `diskutil list physical`. The default is sd-image-pi3.
# Rehearsal images use the disposable key in ./tests/fixtures.

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: flash /dev/diskN [sd-image-pi1|sd-image-pi3|sd-image-test-pi1|sd-image-test-pi3]" >&2
  exit 1
fi
disk="$1"
image="${2:-sd-image-pi3}"
case "$image" in sd-image-pi1 | sd-image-pi3 | sd-image-test-pi1 | sd-image-test-pi3) ;; *) echo "unknown image $image" >&2; exit 1 ;; esac
rawdisk="${disk/\/dev\/disk//dev/rdisk}"
[ -f flake.nix ] || { echo "Run from the repo root." >&2; exit 1; }

[[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || {
  echo "Expected a whole disk such as /dev/diskN, not a partition or raw device." >&2
  exit 1
}
# Machine-readable properties: independent of the Mac's display language.
info="$(diskutil info -plist "$disk")"
python3 -c '
import plistlib, sys
info = plistlib.loads(sys.stdin.buffer.read())
removable_sd = info.get("RemovableMedia") is True and info.get("BusProtocol") == "Secure Digital"
if (info.get("WholeDisk") is not True or info.get("OSInternalMedia") is True
        or not (info.get("Internal") is False or removable_sd)):
    sys.exit("Refusing: target must be a whole external disk or removable SD card.")
size = info.get("TotalSize", 0)
if not 0 < size <= 128 * 1000 ** 3:
    sys.exit("Refusing: target has unknown size or is larger than 128 GB.")
print("Target:    {}".format(sys.argv[1]))
print("Media:     {}".format(info.get("MediaName", "Unknown media")))
print("Bus:       {}".format(info.get("BusProtocol", "Unknown")))
print("Location:  {}".format("internal reader" if info.get("Internal") else "external"))
print("Removable: {}".format("yes" if info.get("RemovableMedia") else "no"))
print("Size:      {:.1f} GB ({:,} bytes)".format(size / 1000 ** 3, size))
' "$disk" <<<"$info"
diskutil list "$disk"
read -r -p "Erase $disk and write key-ceremony-system ($image)? [y/N] " answer
[ "$answer" = "y" ] || exit 1

work="$(mktemp -d)"
umask 077

# Optionally start the standard nix-darwin VM; stop only one we started.
builder=system/org.nixos.linux-builder
started_builder=0
cleanup() {
  rm -rf "$work"
  if [ "$started_builder" = 1 ]; then
    sudo launchctl kill TERM "$builder" || true
  fi
}
trap cleanup EXIT
# Remote authentication belongs to the Nix daemon, which owns the builder
# identity and host-key pin. A user-level SSH probe can wrongly reject it.
if [ "${PGP_VAULT_START_BUILDER:-0}" = 1 ] && ! nc -z localhost 31022 2>/dev/null; then
  sudo launchctl kickstart "$builder"
  started_builder=1
  echo "Waiting for the linux-builder VM..."
  for _ in $(seq 60); do
    nc -z localhost 31022 2>/dev/null && break
    sleep 2
  done
  sleep 3
  nc -z localhost 31022 || { echo "Linux builder did not start." >&2; exit 1; }
fi

nix build --override-input vault-config "path:${configuration_input:?Run the Nix flash app with vault-config}" ".#packages.aarch64-linux.$image" -o "$work/result"
zstd -dc "$work"/result/sd-image/*.img.zst > "$work/sd.img"

# Root filesystem = second MBR partition.
read -r start sectors < <(python3 -c '
import struct, sys
with open(sys.argv[1], "rb") as f:
    f.seek(446 + 16 + 8)
    print(*struct.unpack("<II", f.read(8)))
' "$work/sd.img")
dd if="$work/sd.img" of="$work/root.ext4" bs=512 skip="$start" count="$sectors" status=none

/usr/bin/ssh-keygen -q -t ed25519 -N "" -C "root@pgp-vault" -f "$work/host_key"

debugfs -w -f - "$work/root.ext4" >/dev/null <<EOF
mkdir etc
mkdir etc/ssh
set_inode_field etc/ssh mode 040755
write $work/host_key etc/ssh/ssh_host_ed25519_key
set_inode_field etc/ssh/ssh_host_ed25519_key mode 0100600
set_inode_field etc/ssh/ssh_host_ed25519_key uid 0
set_inode_field etc/ssh/ssh_host_ed25519_key gid 0
write $work/host_key.pub etc/ssh/ssh_host_ed25519_key.pub
set_inode_field etc/ssh/ssh_host_ed25519_key.pub mode 0100644
set_inode_field etc/ssh/ssh_host_ed25519_key.pub uid 0
set_inode_field etc/ssh/ssh_host_ed25519_key.pub gid 0
EOF
debugfs -R "stat etc/ssh/ssh_host_ed25519_key" "$work/root.ext4" 2>/dev/null | grep -q 'Mode:  0600' \
  || { echo "host key injection failed" >&2; exit 1; }

e2fsck -fn "$work/root.ext4" >/dev/null || { echo "root filesystem damaged after injection" >&2; exit 1; }

dd if="$work/root.ext4" of="$work/sd.img" bs=512 seek="$start" conv=notrunc status=none

# Forced: Spotlight (mds) grabs the card's FAT partition as soon as macOS
# mounts it and vetoes a plain unmount. Nothing on the card is kept anyway.
unmounted=0
for _ in 1 2 3; do
  if diskutil unmountDisk force "$disk"; then unmounted=1; break; fi
  sleep 2
done
[ "$unmounted" = 1 ] || { echo "Could not unmount $disk; refusing to write." >&2; exit 1; }
sudo dd if="$work/sd.img" of="$rawdisk" bs=4m status=progress
sync
diskutil eject "$disk"

echo "10.77.0.2 $(cut -d' ' -f1-2 "$work/host_key.pub")" > known_hosts
echo "Done. Host key pinned in ./known_hosts: $(/usr/bin/ssh-keygen -lf "$work/host_key.pub")"
