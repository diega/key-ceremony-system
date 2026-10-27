#!/usr/bin/env python3
"""Evaluate fixture configurations and optionally build clients; never flash devices."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
FPR = (ROOT / "tests/fixtures/fingerprint").read_text().strip()
# Public key used only for evaluating images; no corresponding private key ships.
SSH = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPZ91Zxxk/Tb42bK7DXuZp6kBfJs+QyXe3jS6Aq40Ec fixture"

with tempfile.TemporaryDirectory(prefix="pgp-vault-check-") as temporary:
    repo = Path(temporary).resolve() / "project"
    shutil.copytree(ROOT, repo, ignore=shutil.ignore_patterns(
        ".git", ".local", "result*", "known_hosts", "yubikey.pub", "pubkey-*.asc", "__pycache__"))

    (repo / ".local").mkdir()
    (repo / ".local" / "not-for-publication").write_text("local fixture")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    tracked = subprocess.check_output(["git", "-C", str(repo), "ls-files"], text=True).splitlines()
    assert "config.nix" not in tracked and "config.nix.example" in tracked

    metadata = subprocess.run(["nix", "flake", "metadata", "--offline", "--json", str(repo)],
                              cwd=repo, text=True, capture_output=True, check=True)
    source = Path(json.loads(metadata.stdout)["path"])
    assert not (source / "config.nix").exists() and not (source / ".local").exists()
    assert (source / "config.nix.example").is_file()
    print("PASS: Git flake source excludes personal files", flush=True)

    def settings(**changes):
        values = dict(fingerprint=FPR, uidName="Fixture User", sshPublicKey=SSH)
        values.update(changes)
        # JSON string literals form valid Nix strings for these fixture values.
        (repo / "config.nix").write_text("{\n" + "".join(
            f"  {key} = {json.dumps(value)};\n" for key, value in values.items()) + "}\n")

    def evaluate(attribute, apply=None, error=None):
        command = [str(repo / "pgp-vault"), "eval", "--offline", "--json", f".#{attribute}"]
        if apply:
            command.extend(["--apply", apply])
        result = subprocess.run(command, cwd=repo, text=True, capture_output=True)
        if error:
            assert result.returncode != 0 and error in result.stderr, result.stderr
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    (repo / "config.nix").unlink(missing_ok=True)
    missing = subprocess.run([str(repo / "pgp-vault"), "eval", ".#description"],
                             cwd=repo, text=True, capture_output=True)
    assert missing.returncode != 0 and "cp config.nix.example config.nix" in missing.stderr
    print("PASS: missing local config gives setup instructions", flush=True)
    settings()
    assert subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", "config.nix"]).returncode == 0
    print("PASS: personal config is ignored in a real Git checkout", flush=True)
    summarize = '''c: let
      cryptsetup = builtins.head (builtins.filter (p: (p.pname or "") == "cryptsetup") c.environment.systemPackages);
    in {
      fingerprint = c.pgpVault.fingerprint;
      name = c.pgpVault.uidName;
      typer = c.pgpVault.rehearsalTyper != null;
      authorized = c.users.users.keyops.openssh.authorizedKeys.keys;
      console = c.systemd.services.vault-console.serviceConfig.ExecStart;
      root = c.fileSystems."/".options;
      swapEncrypted = (builtins.head c.swapDevices).randomEncryption.enable;
      hostPlatform = c.nixpkgs.hostPlatform.system;
      derivation = c.system.build.toplevel.drvPath;
      cryptsetupPatch = cryptsetup.postPatch or "";
      cryptsetupDerivation = cryptsetup.drvPath;
      ssh = c.services.openssh.settings;
      journal = c.services.journald.storage;
      temporaryKeyring = c.boot.tmp.useTmpfs;
      coredumps = c.systemd.coredump.enable;
      nixEnabled = c.nix.enable;
      ipv6 = c.networking.enableIPv6;
      dns = c.networking.nameservers;
      firewall = c.networking.nftables.ruleset;
      rehearsalJournal = c.systemd.sockets ? rehearsal-journal;
      ptraceScope = c.boot.kernel.sysctl."kernel.yama.ptrace_scope";
    }'''
    production = evaluate("nixosConfigurations.pgp-vault-pi3.config", summarize)
    assert not production["typer"] and production["swapEncrypted"]
    assert production["fingerprint"] == FPR and production["hostPlatform"] == "aarch64-linux"
    assert len(production["authorized"]) == 1 and SSH in production["authorized"][0]
    assert 'restrict,command="' in production["authorized"][0]
    assert "nosuid" in production["root"] and "nodev" in production["root"]
    print("PASS: production evaluates with restricted operator key and encrypted swap", flush=True)

    def check_isolation(configuration):
        ssh = configuration["ssh"]
        assert ssh["AllowUsers"] == ["keyops"] and ssh["PermitRootLogin"] == "no"
        assert ssh["AuthenticationMethods"] == "publickey"
        assert not ssh["PasswordAuthentication"] and not ssh["KbdInteractiveAuthentication"]
        for option in ("AllowTcpForwarding", "AllowAgentForwarding", "AllowStreamLocalForwarding", "PermitTunnel"):
            assert ssh[option] == "no", (option, ssh[option])
        assert not ssh["X11Forwarding"]
        assert configuration["journal"] == "volatile" and configuration["temporaryKeyring"]
        assert not configuration["coredumps"] and not configuration["nixEnabled"]
        assert not configuration["ipv6"] and configuration["dns"] == []
        assert configuration["ptraceScope"] == 2
        for chain in ("input", "forward", "output"):
            assert f"type filter hook {chain} priority 0; policy drop;" in configuration["firewall"]

    check_isolation(production)
    assert not production["rehearsalJournal"] and "2223" not in production["firewall"]
    print("PASS: production SSH, volatile state, network isolation and debugging restrictions", flush=True)

    settings(fingerprint="A" * 40, uidName="Production User")
    rehearsal = evaluate("nixosConfigurations.pgp-vault-test-pi3.config", summarize)
    assert rehearsal["typer"] and rehearsal["fingerprint"] == FPR
    assert rehearsal["name"] == "Rehearsal User"
    check_isolation(rehearsal)
    assert rehearsal["rehearsalJournal"] and "2223" in rehearsal["firewall"]
    print("PASS: rehearsal cannot inherit the production identity", flush=True)

    assert "FLAG_clear_internal_memory" not in production["cryptsetupPatch"]
    assert "FLAG_clear_internal_memory" not in rehearsal["cryptsetupPatch"]
    settings(skipArgon2Wipe=True)
    evaluate("nixosConfigurations.pgp-vault-pi3.config.pgpVault.fingerprint", error="skipArgon2Wipe was removed")
    print("PASS: upstream Argon2 cleanup retained; removed workaround is rejected", flush=True)

    settings(fingerprint=None, uidName=None)
    assert evaluate("nixosConfigurations.pgp-vault-test-pi3.config.pgpVault.fingerprint") == FPR
    evaluate("nixosConfigurations.pgp-vault-pi3.config.pgpVault.fingerprint", error="set fingerprint in the vault-config input")
    print("PASS: clean checkout blocks production but permits rehearsal identity", flush=True)

    settings(fingerprint="bad")
    evaluate("nixosConfigurations.pgp-vault-pi3.config.pgpVault.fingerprint", error="invalid fingerprint")
    settings(sshPublicKey="not a public key")
    evaluate("nixosConfigurations.pgp-vault-pi3.config.pgpVault.sshPublicKey", error="invalid sshPublicKey")
    print("PASS: malformed fingerprint and SSH key are rejected", flush=True)

    settings()
    for target in ("pgp-vault-pi1", "pgp-vault-test-pi1"):
        pi1 = evaluate(f"nixosConfigurations.{target}.config", summarize)
        assert pi1["hostPlatform"] == "armv6l-linux" and pi1["swapEncrypted"]
        assert pi1["typer"] == ("-test-" in target)
        check_isolation(pi1)
    print("PASS: both Pi 1 configurations still evaluate", flush=True)

    generic_run = subprocess.run([
        "nix", "eval", "--offline", "--impure", "--json", "--file", str(repo / "tests/module-eval.nix")
    ], cwd=repo, text=True, capture_output=True)
    assert generic_run.returncode == 0, generic_run.stderr
    generic = json.loads(generic_run.stdout)
    assert generic["system"] == "x86_64-linux" and generic["ethernetMatch"] == {"Name": "enp1s0"}
    assert generic["activityLed"] is None and generic["swap"] == []
    assert not generic["piOptionsImported"] and not generic["sdImageOptionsImported"]
    assert not generic["failures"] and not generic["encryptedSwapFailures"]
    assert "pgp-vault requires swap encrypted with a fresh random key on every boot." in generic["unencryptedSwapFailures"]
    print("PASS: common module evaluates without Pi firmware, SD layout or LED; plaintext swap is rejected", flush=True)

    for client in ("flash", "vault", "publish"):
        evaluate(f"packages.aarch64-darwin.{client}.drvPath")
    if "--build-clients" in sys.argv:
        subprocess.run([str(repo / "pgp-vault"), "build", "--no-link", "--max-jobs", "1"] + [
            f".#packages.aarch64-darwin.{name}"
            for name in ("flash", "vault", "publish")], cwd=repo, check=True)
        print("PASS: all Mac clients build with fixture configuration", flush=True)

    settings(uidName='Alex "Example" $HOME `id`')
    # Evaluating the console forces generation of the signing script containing uidName.
    evaluate("nixosConfigurations.pgp-vault-pi3.config.systemd.services.vault-console.serviceConfig.ExecStart")
    print("PASS: names containing shell metacharacters evaluate safely", flush=True)
