# key-ceremony-system

A NixOS system for **offline OpenPGP key-extension ceremonies**, with security
boundaries enforced at the operating-system level.

It opens an encrypted backup read-only, loads the key into an ephemeral GnuPG
keyring, extends the expiry of the primary key and its subkeys, and saves the
updated public certificate. The encrypted private backup stays unchanged.
Control uses restricted SSH; production passphrases enter on a local USB keyboard.

The workflow builds on [drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide).
It maintains existing keys; it does not create primary keys or provision tokens.

## Status

Experimental, without an independent security audit. Full ceremonies have been
tested on **Raspberry Pi 3 B**. **Pi 1 Model B** has been built and booted, but did
not complete the high-memory LUKS workload in a practical time.
See the [security model](docs/design.md) and [hardware results](docs/hardware-tests.md).

The core is independent of Raspberry Pi. Contributions for other NixOS-capable
boards and architectures are welcome; see [platform modules](docs/platforms.md).
Effort has gone into minimizing the image, and further reductions are welcome.

## Use

The current operator tools run on Apple Silicon macOS with an aarch64-linux Nix builder.

1. [Set up the builder, SSH key and public configuration](docs/setup.md).
2. [Rehearse with disposable keys and a spare USB stick](docs/rehearsal.md).
3. [Run a production ceremony](docs/usage.md).

Images and commands are exposed through `nix build` and `nix run`.
The configuration contains public settings only; personal files stay outside Git.
[Supported backup formats](docs/backup-formats.md) include historical and current guide layouts.

## Development

[CI](docs/ci.md) checks configuration, backup handling and operator tools on every
PR. A Python-driven NixOS VM test exercises the real ceremony through SSH,
virtual USB storage and local keyboard input. Board-image checks are separate.

Licensed under [MIT](LICENSE). Documentation and source comments are in English.
