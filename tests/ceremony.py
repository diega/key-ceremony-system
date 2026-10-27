"""Exercise the production ceremony through SSH, USB storage and local input.

Executed by the NixOS VM driver, which supplies vault, operator and subtest.
All passphrases, SSH keys and OpenPGP material are disposable public fixtures.
"""
from datetime import datetime, timezone
from contextlib import contextmanager
import hashlib
import json
import re
import shlex
import shutil
import time


FINGERPRINT = "475C6A3F73D438CDEDE7C3D27DE9AE9985243C38"
RENEW_UNTIL = "2028-10-27"
EPOCH = 1793102400  # 2026-10-27 12:00:00 UTC; independent of runner time.
SNAPSHOT = "gpg-0x7DE9AE9985243C38-2026-10-27.asc"
PRIVATE_EXPORT = "2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key"
SSH = (
    "ssh -F none -i /root/operator_key -o IdentitiesOnly=yes "
    "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/known_hosts "
    "-o ConnectTimeout=5 keyops@10.77.0.2 -- "
)


def control(command, *, stdin=False):
    """Return the exact shell command that a person can repeat on the operator."""
    # Ordinary SSH calls must not read the driver's virtio control channel.
    # Only import-public consumes stdin, supplied explicitly by its caller.
    return SSH + shlex.quote(command) + ("" if stdin else " < /dev/null")


@contextmanager
def step(name):
    """Keep the real service journals with the test output if a step fails."""
    with subtest(name):
        try:
            yield
        except Exception:
            for machine in (vault, operator):
                if machine.connected:
                    try:
                        _, journal = machine.execute("journalctl -b --no-pager", timeout=15)
                        (machine.out_dir / f"{machine.name}-journal.txt").write_text(journal)
                        print(f"Last journal entries for {machine.name}:\n" + "\n".join(journal.splitlines()[-100:]))
                    except Exception:
                        pass  # Preserve the original failure if diagnostics are unavailable.
            raise


def status_has(text):
    operator.wait_until_succeeds(
        control("status") + " | grep -F -- " + shlex.quote(text), timeout=90
    )


def rejected(command, message):
    code, output = operator.execute(control(command) + " 2>&1")
    assert code in (1, 2), (command, code, output)
    assert message in output, (command, output)


def encrypted_digest(path):
    """Hash only partition 1, the 40 MiB LUKS backup; partition 2 is writable."""
    with path.open("rb") as stream:
        stream.seek(1024 * 1024)
        return hashlib.sha256(stream.read(40 * 1024 * 1024)).hexdigest()


def monitor(command):
    response = vault.send_monitor_command(command)
    assert "Error:" not in response, (command, response)
    return response


def drive_present():
    return re.search(r"(?m)^stick(?:\s|:)", monitor("info block")) is not None


def plug_in():
    if not drive_present():
        monitor(f"drive_add 0 id=stick,if=none,file={stick_path},format=raw")
    monitor("device_add usb-storage,id=stick,drive=stick,removable=true")
    vault.wait_until_succeeds("lsblk -nrpo FSTYPE | grep -x crypto_LUKS")


def unplug():
    journal_command = "journalctl -b -u vault-console --no-pager"
    waiting_before = vault.succeed(journal_command).count("pgp-vault: waiting for the USB stick")
    monitor("device_del stick")
    vault.wait_for_qmp_event(lambda event: event.get("event") == "DEVICE_DELETED"
                           and event.get("data", {}).get("device") == "stick", timeout=30)
    vault.wait_until_fails("lsblk -nrpo FSTYPE | grep -x crypto_LUKS")
    if drive_present():
        monitor("drive_del stick")

    def console_saw_removal(_last_try):
        return vault.succeed(journal_command).count("pgp-vault: waiting for the USB stick") > waiting_before

    retry(console_saw_removal, timeout_seconds=30)


def unlock():
    status_has("WAITING for the USB stick passphrase")
    vault.send_chars("prueba-luks-1\n")
    status_has("idle, stick open")
    status_has(PRIVATE_EXPORT)


def check_certificate(path):
    operator.succeed("install -d -m 700 /tmp/verify")
    listing = operator.succeed(
        "gpg --no-options --homedir /tmp/verify --batch --with-colons --show-keys "
        + shlex.quote(path)
    )
    records = [line.split(":") for line in listing.splitlines()]
    assert not any(row[0] in ("sec", "ssb") for row in records), listing
    assert [row[0] for row in records if row[0] in ("pub", "sub")] == ["pub", "sub", "sub", "sub"]
    assert next(row[9] for row in records if row[0] == "fpr") == FINGERPRINT
    fixture_listing = operator.succeed(
        "gpg --no-options --homedir /tmp/verify --batch --with-colons --show-keys /etc/public-fixture.asc"
    )
    expected = {line.split(":")[9] for line in fixture_listing.splitlines() if line.startswith("fpr:")}
    actual = {row[9] for row in records if row[0] == "fpr"}
    assert len(actual) == 4 and actual == expected, listing
    for row in records:
        if row[0] in ("pub", "sub"):
            expiry = datetime.fromtimestamp(int(row[6]), timezone.utc).date().isoformat()
            assert expiry == RENEW_UNTIL, (row, expiry)
    operator.succeed("gpg --no-options --homedir /tmp/verify --batch --import " + shlex.quote(path))
    signatures = operator.succeed(
        f"gpg --no-options --homedir /tmp/verify --batch --with-colons --check-sigs {FINGERPRINT}"
    )
    valid = [line for line in signatures.splitlines() if line.startswith("sig:!:")]
    assert len(valid) >= 4, signatures
    return sorted(actual)


stick_path = vault.state_dir / "ceremony-stick.img"
shutil.copyfile(fixture_path, stick_path)
original_encrypted = encrypted_digest(stick_path)
started = time.monotonic()

with step("Boot production policy and authenticate the operator"):
    start_all()
    vault.wait_for_unit("sshd.service")
    vault.wait_for_unit("vault-console.service")
    vault.wait_for_unit("vault-ctl.socket")
    operator.wait_for_unit("network.target")
    operator.succeed("install -m 600 /etc/operator-test-key /root/operator_key")
    operator.succeed(f"date -u -s @{EPOCH}")
    host_key = vault.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    operator.succeed("printf '%s\\n' " + shlex.quote("10.77.0.2 " + host_key) + " > /root/known_hosts")
    status_has("Clock:      NOT SET")
    rejected("export-public", "The stick isn't open")
    rejected("extend 2028-10-27", "The stick isn't open")
    rejected("sh", "verbs:")
    rejected("type prueba-luks-1", "verbs:")
    vault.fail("runuser -u keyops -- test -r /etc/ssh/ssh_host_ed25519_key")
    vault.fail("test -e /run/vault/key")
    assert vault.succeed("sysctl -n kernel.yama.ptrace_scope").strip() == "2"
    assert vault.succeed("swapon --noheadings").strip() == ""

with step("Require clock setup before asking for the USB passphrase"):
    plug_in()
    status_has("waiting for the clock: set-clock first")
    vault.fail("test -e /dev/mapper/vault")
    operator.succeed(control(f"set-clock {EPOCH}"))
    status_has("WAITING for the USB stick passphrase")
    vault.send_chars("incorrect-passphrase\n")
    vault.wait_until_succeeds("journalctl -b -t vault-open --no-pager | grep -F 'No key available'")
    unlock()

with step("Read-only backup, unprivileged keyring and public import"):
    assert vault.succeed("blockdev --getro /dev/mapper/vault").strip() == "1"
    mount_options = vault.succeed("findmnt -n -o OPTIONS /run/vault/root/fs").strip().split(",")
    assert {"ro", "nosuid", "nodev", "noexec"}.issubset(mount_options)
    vault.fail("runuser -u keyops -- test -r /run/vault/keyring/gnupg/pubring.kbx")
    operator.succeed(control("import-public", stdin=True) + " < /etc/public-fixture.asc")
    code, output = operator.execute("printf invalid | " + control("import-public", stdin=True))
    assert code == 1 and "Not the public key" in output, output

with step("Extend primary and subkeys with local pinentry input"):
    # Define the headless terminal's dimensions without bypassing pinentry.
    vault.succeed("stty -F /dev/tty1 rows 40 cols 120")
    operator.succeed(
        "(rc=0; " + control(f"extend {RENEW_UNTIL}")
        + " > /tmp/extend.log 2>&1 || rc=$?; echo $rc > /tmp/extend.rc) < /dev/null > /dev/null 2>&1 &"
    )
    def pinentry_ready(_last_try):
        code, _ = operator.execute("test -f /tmp/extend.rc")
        assert code != 0, operator.succeed("cat /tmp/extend.log")
        return "WAITING for the master key passphrase" in operator.succeed(control("status"))

    retry(pinentry_ready, timeout_seconds=60)
    vault.send_chars("prueba-gpg-1\n")
    operator.wait_for_file("/tmp/extend.rc")
    assert operator.succeed("cat /tmp/extend.rc").strip() == "0", operator.succeed("cat /tmp/extend.log")
    operator.succeed(control("export-public") + " > /tmp/renewed.asc")
    check_certificate("/tmp/renewed.asc")

with step("Save public update and refuse same-day overwrite"):
    operator.succeed(control("backup"))
    rejected("backup", "already exists")
    operator.succeed(control("close"))
    status_has("Keyring:    not loaded")
    vault.fail("test -e /dev/mapper/vault")
    vault.fail("test -d /run/vault/keyring/gnupg")

with step("Remove, reinsert and recover the saved expiry dates"):
    unplug()
    plug_in()
    unlock()
    status_has(SNAPSHOT)
    operator.succeed(control("export-public") + " > /tmp/reloaded.asc")
    fingerprints = check_certificate("/tmp/reloaded.asc")

with step("Cleanup, preserve the encrypted backup and power off"):
    operator.succeed(control("close"))
    status_has("Keyring:    not loaded")
    vault.fail("test -e /dev/mapper/vault")
    vault.fail("test -d /run/vault/keyring/gnupg")
    unplug()
    assert encrypted_digest(stick_path) == original_encrypted, "Encrypted backup was modified"
    code, output = operator.execute(control("poweroff") + " 2>&1")
    # A fast shutdown can close SSH before it delivers the command's exit code.
    # Accept that transport result only alongside a real, clean guest poweroff.
    assert code in (0, 255), (code, output)
    assert vault.process is not None
    assert vault.process.wait(timeout=60) == 0, "Vault VM did not exit cleanly"
    vault.wait_for_shutdown()
    retry(lambda _last_try: "reboot: Power down" in vault.get_console_log(), timeout_seconds=10)

report = {
    "fingerprint": FINGERPRINT,
    "expiry_date": RENEW_UNTIL,
    "keys_checked": 4,
    "fingerprints": fingerprints,
    "encrypted_partition_unchanged": True,
    "encrypted_partition_sha256": original_encrypted,
    "reloaded_public_update": SNAPSHOT,
    "production_control_policy": True,
    "duration_seconds": round(time.monotonic() - started, 2),
}
(vault.out_dir / "ceremony-report.json").write_text(json.dumps(report, indent=2) + "\n")
