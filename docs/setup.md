# Setup

Run commands from the repository root.

## What you need

For the tested Pi 3 workflow:

- A Pi 3 B, reliable power, an SD card of at least 8 GB, and a USB keyboard for
  production use. No monitor is required for the tested headless workflow.
- A dedicated Ethernet cable to the Mac, usually through a USB-Ethernet adapter.
  Keep this interface off shared networks and disable Internet Sharing for it.
- A spare USB stick that can be erased for rehearsal, and an independent copy of
  your real encrypted backup before any production ceremony.
- Nix with `nix-command` and `flakes` enabled, plus an aarch64-linux builder.
  The recorded workflow used Nix 2.34.9. Keep `flake.lock` for the pinned inputs.
- GnuPG on the Mac and an SSH agent holding the private key corresponding to the
  configured operator public key. A YubiKey OpenPGP authentication subkey works;
  a regular supported SSH key loaded with `ssh-add` also works.

### Linux builder on macOS

For nix-darwin, merge [the builder example](nix-darwin-builder.nix) into your
existing host configuration and rebuild it. The repository does not configure
your host automatically. The first build can be substantial; later builds reuse
the Nix store. The builder may fetch dependencies online; the system does not.

Start the standard builder if it is stopped:

```sh
sudo launchctl kickstart system/org.nixos.linux-builder
```

`nc -z localhost 31022` checks its local SSH port. Nix's daemon handles the
builder's credentials and host-key pin; a separate user-level SSH probe may fail
even when distributed builds work. Other Linux remote builders can be registered
in Nix's builder configuration.

### Operator SSH authentication

For a YubiKey, configure gpg-agent's SSH support, then select its socket:

```sh
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
ssh-add -L
```

The output must include your authentication public key. Touch/PIN requirements
are determined by your token and agent. For a regular key, load its private part
with `ssh-add /path/to/private-key`. The system receives only the public key.

## Local public configuration

Run the following from the repository root:

```sh
mkdir -p .local/vault-config
cp config.nix.example .local/vault-config/default.nix
```

Edit `.local/vault-config/default.nix`, replacing the template's `null` values:

```nix
{
  fingerprint = "YOUR_40_CHARACTER_UPPERCASE_PRIMARY_FINGERPRINT";
  uidName = "Alex Example";
  sshPublicKey = "ssh-ed25519 AAAA... replace-with-your-public-key";
}
```

The strings above are placeholders. Use `gpg --fingerprint YOUR_KEY` to obtain
the **primary** fingerprint, not a subkey fingerprint. Obtain a YubiKey's SSH key
with `gpg --export-ssh-key AUTH_SUBKEY_ID`, or copy a regular SSH `.pub` file.
Supported public-key types are Ed25519, RSA and NIST P-256/P-384/P-521 ECDSA.
`uidName` supplies the name used by `add-uid`.

**These settings are public and enter the readable Nix store.** Never put
passphrases or private keys in them. `.local/` and an optional root `config.nix`
are ignored by Git; `config.nix.example` is the published template.

Configured Nix commands take the local directory as an explicit `vault-config`
input. For example:

```sh
nix eval --raw --override-input vault-config path:./.local/vault-config .#nixosConfigurations.pgp-vault-pi3.config.system.build.toplevel.drvPath
```

Use that override with every configured `flash`, `vault`, `publish`, image build
or evaluation. Without it, Nix uses an empty configuration; outputs requiring
identity settings fail with an explanation. Checks and disposable USB fixtures
that do not need your identity can run without it. Overrides do not rewrite the
project lock file; Nix may print a warning describing the temporary input change.

For rehearsal, only `sshPublicKey` must be filled: stock test images force the
shared test fingerprint and name. Production images require all three settings.
The same SSH setting is installed on the system and selected by the Mac client.

The hostname is `pgp-vault` and the NixOS option namespace is `pgpVault`.
System and SD-image outputs include the hardware model; see the
[image output table](usage.md#commands-and-image-outputs) and
[module composition](platforms.md#layout).
The optional `./pgp-vault` shorthand copies a root `config.nix` into a temporary
input; native Nix commands are used throughout this guide.


Before using a backup, check the [supported formats and selection rules](backup-formats.md). Continue with the [disposable rehearsal](rehearsal.md).
