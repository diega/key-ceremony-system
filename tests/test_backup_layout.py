#!/usr/bin/env python3
"""Run the actual system selectors on temporary backup trees; no devices."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(os.environ.get("BACKUP_LAYOUT_HELPER", ROOT / "modules/backup-layout.sh"))
PUBLIC = Path(os.environ.get("BACKUP_PUBLIC_FIXTURE", ROOT / "tests/fixtures/public.asc"))
PRIVATE = Path(os.environ.get("BACKUP_PRIVATE_FIXTURE", ROOT / "tests/fixtures/mastersub.key"))
FPR = "475C6A3F73D438CDEDE7C3D27DE9AE9985243C38"
KEYID = FPR[-16:]
BASH = shutil.which("bash")


class BackupLayout(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="backup-layout-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, LC_ALL="C", TZ="UTC")

    def run_helper(self, function, *arguments, code=0):
        result = subprocess.run(
            [BASH, "-euo", "pipefail", "-c", 'source "$1"; shift; "$@"',
             "layout-test", str(HELPER), function, *map(str, arguments)],
            env=self.environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return result.stdout.strip()

    def put(self, name, data=b"fixture", stamp=1000):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        os.utime(path, ns=(stamp * 1_000_000_000,) * 2)
        return path

    def test_private_historical_and_current_names(self):
        for name in ("mastersub.key", "certify.key", f"{KEYID}-Certify.key",
                     f"0x{KEYID}-Certify.key", f"secret-{KEYID}-Certify.key",
                     f"secret-{FPR}-Certify.key"):
            with self.subTest(name=name):
                self.run_helper("private_name_matches", name, FPR)

    def test_subkeys_and_other_identities_are_not_primary_exports(self):
        for name in ("sub.key", "subkeys.key", f"secret-{KEYID}-Subkeys.key",
                     "secret-AAAAAAAAAAAAAAAA-Certify.key", "notes.key"):
            with self.subTest(name=name):
                self.run_helper("private_name_matches", name, FPR, code=1)

    def test_newest_private_generation_wins_across_names(self):
        self.put("tmp.old/mastersub.key", b"old", 1000)
        self.put(f"2026.10.26-modern/secret-{KEYID}-Certify.key", b"new", 2000)
        self.assertEqual(self.run_helper("select_backup_file", "private", self.root, FPR),
                         f"2026.10.26-modern/secret-{KEYID}-Certify.key")

    def test_identical_aliases_are_accepted_but_conflicting_latest_files_are_not(self):
        self.put("snapshot/mastersub.key", b"same")
        self.put("snapshot/certify.key", b"same")
        self.assertEqual(self.run_helper("select_backup_file", "private", self.root, FPR),
                         "snapshot/mastersub.key")
        self.put("snapshot/certify.key", b"different")
        self.run_helper("select_backup_file", "private", self.root, FPR, code=2)

    def test_old_ambiguity_does_not_hide_a_newer_generation(self):
        self.put("old/mastersub.key", b"old-a", 1000)
        self.put("old/certify.key", b"old-b", 1000)
        self.put("new/certify.key", b"new", 2000)
        self.assertEqual(self.run_helper("select_backup_file", "private", self.root, FPR),
                         "new/certify.key")

    def test_public_naming_conventions(self):
        for name in (f"gpg-0x{KEYID}-2026-10-21.asc", f"{KEYID}-2026-10-21.asc",
                     f"public-{KEYID}-2026-10-21.asc", f"0x{KEYID}-2026-10-21.txt",
                     f"public-{FPR}-2026-10-21.asc"):
            with self.subTest(name=name):
                self.assertEqual(self.run_helper("public_name_date", name, FPR), "2026-10-21")
        self.assertEqual(self.run_helper("public_name_date", "public.asc", FPR), "0000-00-00")
        self.assertEqual(self.run_helper("public_name_date", f"0x{KEYID}.txt", FPR), "0000-00-00")

    def test_public_selection_uses_date_not_lexical_prefix(self):
        self.put(f"public-{KEYID}-2026-10-20.asc", b"old")
        self.put(f"gpg-0x{KEYID}-2026-10-21.asc", b"middle")
        self.put(f"{KEYID}-2026-10-22.asc", b"new")
        self.put("public.asc", b"undated")
        self.assertEqual(self.run_helper("select_backup_file", "public", self.root, FPR),
                         f"{KEYID}-2026-10-22.asc")

    def test_conflicting_same_date_public_exports_fail(self):
        self.put(f"public-{KEYID}-2026-10-21.asc", b"a")
        self.put(f"gpg-0x{KEYID}-2026-10-21.asc", b"b")
        self.run_helper("select_backup_file", "public", self.root, FPR, code=2)

    def test_invalid_dates_other_ids_partial_and_unrelated_files_ignored(self):
        for name in (f"{KEYID}-2026-02-30.asc", f"{KEYID}-2026-13-01.asc",
                     "AAAAAAAAAAAAAAAA-2026-10-21.asc", f"{KEYID}-2026-10-21.asc.partial",
                     "notes.asc"):
            with self.subTest(name=name):
                self.run_helper("public_name_date", name, FPR, code=1)

    def test_symlink_files_and_generations_are_not_followed(self):
        target = self.put("actual/secret.key")
        (self.root / "actual/mastersub.key").symlink_to(target)
        linked = self.root / "link"
        linked.symlink_to(self.root / "actual", target_is_directory=True)
        self.run_helper("select_backup_file", "private", self.root, FPR, code=1)
        public = self.put("actual/public.asc")
        (self.root / "public.asc").symlink_to(public)
        self.run_helper("select_backup_file", "public", self.root, FPR, code=1)

    def test_newline_path_and_oversized_candidate_rejected(self):
        self.put("bad\nname/mastersub.key")
        self.run_helper("select_backup_file", "private", self.root, FPR, code=2)
        (self.root / "bad\nname/mastersub.key").unlink()
        self.put("safe/mastersub.key", b"a" * (1048576 + 1))
        self.run_helper("select_backup_file", "private", self.root, FPR, code=2)

    def test_snapshot_bounded_and_symlinks_rejected(self):
        source = self.put("public.asc", PUBLIC.read_bytes())
        destination = self.root / "snapshot.asc"
        self.run_helper("snapshot_backup_file", source, destination)
        self.assertEqual(source.read_bytes(), destination.read_bytes())
        link = self.root / "link.asc"
        link.symlink_to(source)
        self.run_helper("snapshot_backup_file", link, destination, code=1)
        source.write_bytes(b"a" * (1048576 + 1))
        self.run_helper("snapshot_backup_file", source, destination, code=1)

    def test_real_public_certificate_identity_and_public_only_validation(self):
        home = self.root / "gnupg"
        home.mkdir(mode=0o700)
        def show(path):
            # Secret show-only can return nonzero when no agent is running;
            # its sec records must still be rejected by the public validator.
            result = subprocess.run(["gpg", "--no-options", "--no-autostart", "--homedir", str(home),
                                     "--with-colons", "--show-keys", str(path)],
                                    text=True, capture_output=True)
            self.assertTrue(result.stdout, result.stderr)
            return result.stdout
        listing = show(PUBLIC)
        self.run_helper("public_listing_matches", listing, FPR)
        self.run_helper("public_listing_matches", listing, "A" * 40, code=1)
        self.run_helper("public_listing_matches", listing + listing, FPR, code=1)
        self.run_helper("public_listing_matches", "not a certificate", FPR, code=1)
        secret = show(PRIVATE)
        self.assertIn("sec:", secret)
        self.run_helper("public_listing_matches", secret, FPR, code=1)


if __name__ == "__main__":
    unittest.main()
