#!/usr/bin/env python3
"""Exercise flash preflight with fake diskutil; never touches a device."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FlashPreflight(unittest.TestCase):
    def run_flash(self, device="/dev/disk9", approve=False, **properties):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            info = dict(WholeDisk=True, Internal=False, TotalSize=8_000_000_000,
                        MediaName="Disposable test SD")
            info.update(properties)
            (work / "disk.plist").write_bytes(plistlib.dumps(info))
            diskutil = work / "diskutil"
            diskutil.write_text('#!/bin/sh\ncase "$1" in\n  info) cat "$MOCK_DISK_PLIST" ;;\n  list) printf "Partition layout for %s\\n" "$2" ;;\n  *) exit 98 ;;\nesac\n')
            diskutil.chmod(0o755)
            # Any attempt to reach build/write actions fails and leaves evidence.
            for command in ("nix", "sudo", "dd", "launchctl", "nc"):
                mock = work / command
                mock.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" > "$MOCK_UNEXPECTED"\nexit 99\n')
                mock.chmod(0o755)
            environment = dict(os.environ, PATH=f"{work}:{os.environ['PATH']}",
                               MOCK_DISK_PLIST=str(work / "disk.plist"),
                               MOCK_UNEXPECTED=str(work / "unexpected"),
                               PGP_VAULT_START_BUILDER="0", configuration_input=str(work))
            result = subprocess.run(
                ["bash", "-euo", "pipefail", str(ROOT / "scripts/flash.sh"), device],
                cwd=ROOT, env=environment, input="y\n" if approve else "n\n", text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            if approve:
                self.assertTrue((work / "unexpected").exists())
                self.assertTrue((work / "unexpected").read_text().startswith("build --override-input vault-config "))
            else:
                self.assertFalse((work / "unexpected").exists(), "reached a build/write action")
            return result.stdout + result.stderr

    def test_partition_rejected(self):
        self.assertIn("Expected a whole disk", self.run_flash("/dev/disk9s1"))

    def test_internal_disk_rejected(self):
        self.assertIn("whole external disk", self.run_flash(Internal=True))

    def test_non_whole_disk_rejected(self):
        self.assertIn("whole external disk", self.run_flash(WholeDisk=False))

    def test_oversized_disk_rejected(self):
        self.assertIn("larger than 128 GB", self.run_flash(TotalSize=256_000_000_000))

    def test_unknown_size_rejected(self):
        self.assertIn("unknown size", self.run_flash(TotalSize=0))

    def test_integrated_removable_sd_reader_allowed(self):
        self.assertIn("Disposable test SD", self.run_flash(
            Internal=True, RemovableMedia=True, BusProtocol="Secure Digital", OSInternalMedia=False))

    def test_internal_non_sd_media_rejected_even_if_removable(self):
        self.assertIn("whole external disk", self.run_flash(
            Internal=True, RemovableMedia=True, BusProtocol="PCI-Express"))

    def test_os_internal_media_rejected(self):
        self.assertIn("whole external disk", self.run_flash(OSInternalMedia=True))

    def test_build_uses_daemon_without_user_level_ssh_probe(self):
        self.run_flash(approve=True)

    def test_external_sd_can_be_cancelled_before_any_build(self):
        output = self.run_flash(BusProtocol="USB", RemovableMedia=True)
        self.assertIn("Target:    /dev/disk9", output)
        self.assertIn("Media:     Disposable test SD", output)
        self.assertIn("Bus:       USB", output)
        self.assertIn("Location:  external", output)
        self.assertIn("Removable: yes", output)
        self.assertIn("Size:      8.0 GB (8,000,000,000 bytes)", output)
        self.assertIn("Partition layout for /dev/disk9", output)


if __name__ == "__main__":
    unittest.main()
