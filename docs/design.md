# Security design

[key-ceremony-system](../README.md) performs offline OpenPGP key-extension
ceremonies with operating-system isolation. This document describes the current
implementation. Historical measurements and hardware-specific validation are in
[the hardware record](hardware-tests.md).

## Purpose and trust boundary

The system loads an existing encrypted backup, extends the expiry of an
OpenPGP primary key and its non-revoked subkeys, and saves the updated public
certificate. Changing expiry creates public signatures; the private export on
the encrypted backup does not need to be rewritten.

Production passphrases enter through a local USB keyboard on the system.
The operator computer sends only a restricted set of control requests over a
dedicated Ethernet connection. It never receives private-key exports or keyboard
input through that control interface. Public certificates and status are returned.

The system is isolated from the Internet but has this authenticated SSH link;
it is not a strict air gap. The build computer, Linux builder, operator SSH key,
flashing process and physical system are part of the trust boundary. A
compromised operator can request the permitted operations and supply the clock;
this design does not independently verify the operator's intended date or UID
changes. The passphrase cache can authorize several operations in a session.

The implementation is experimental and has not received an independent security
audit. It provides OS-level isolation, not a hardware trusted execution environment
or measured/verified boot.

## Identities and control protocol

| Identity | Responsibility | Boundary |
|---|---|---|
| `root` services | `vault-console` owns tty1; `vault-ctl` processes requests, opens LUKS and mounts storage | Privileged device operations run in fixed helpers; key parsing/signing drops to `signer` |
| `signer` | Owns the ephemeral GnuPG home and agent | No login; receives bounded snapshots or file descriptors, not root privileges |
| `keyops` | Authenticates over SSH and runs `keyops-ctl` | No interactive shell, forwarding, direct keyring access or writable home |

`keyops-ctl` writes validated requests to a systemd-created FIFO. The root
controller accepts an allowlist of verbs and writes responses to root-owned
files that `keyops` can read. A single worker processes operations; `close` can
cancel pending work. A loaded-and-validated key marker is required before
signing, importing public updates, backing up or exporting.

SSH accepts the configured public key, forced to `keyops-ctl`. Password login,
root login, agent/TCP/stream-local forwarding, X11 and tunnelling are disabled.
There are no setuid/setgid wrappers, sudo or interactive getty consoles.

## Local input and agent

GnuPG runs with `--no-options`; configuration files from the USB backup are
ignored. The agent reads its immutable configuration from the Nix store. Its
pinentry is fixed to tty1, and loopback and external passphrase caches are
disallowed. GnuPG operations do not autostart an agent with a different setup.

LUKS input has no timeout and allows five attempts. Pinentry allows up to 24 hours
for local input. The agent's default cache TTL is one hour, with a two-hour maximum.
A standard USB keyboard is sufficient. An AI assistant is optional.

The common module requires explicit clock setup each boot before it prompts for
the USB passphrase. Tested Pi models have no configured RTC or network time source.
The USB partition must remain stable for five seconds before unlock starts.

## Backup handling

`cryptsetup open --readonly` protects the encrypted block mapping, and its
filesystem is mounted with `ro,nosuid,nodev,noexec`. Mounts are below a root-only
directory. GnuPG sees bounded snapshots in RAM and parses them as `signer`.
The selected private export must contain exactly the configured primary
certificate and a usable primary secret key before the session becomes ready.

[Backup-name selection](backup-formats.md) supports historical and current drduh
conventions. Private files are selected by mtime, public snapshots by the date
in their names. Selected public files must contain exactly the configured
certificate and no secret records. Invalid or ambiguous selected content fails
the session rather than silently using an older generation.

`backup` writes only to a separate, unencrypted ext2/3/4 partition on the same USB
disk. It exports the configured public certificate, checks it, writes a temporary
file, syncs, renames and syncs again. Existing same-day snapshots are not replaced.
The public partition contains public identities and signatures and is not private.
These steps reduce incomplete writes; they are not a proof against every power
failure. Power-loss fault injection has not been tested.

## Volatile state and cryptography

The GnuPG home, controller state, scratch copies and journal live under `/run` or
other memory-backed filesystems. Core dumps are disabled; ptrace is restricted,
kernel memory information is restricted, and kexec is disabled. Platforms can
use swap only with a fresh random encryption key on every boot. The Pi family
creates a dedicated 2 GiB swap partition on first boot to support high-memory
LUKS KDFs; other platforms may omit swap when RAM is sufficient.

Cryptsetup and Argon2 retain their upstream memory cleanup. The earlier patch
that skipped Argon2's explicit wipe has been removed, and its old configuration
option is rejected. A historical high-memory backup can still take over an hour
on a Pi 3 and slow SD card. See [measurements](hardware-tests.md) for the tested
parameters and the limits of timing comparisons.

The target has no Nix daemon or in-place rebuild workflow. Its system definition
and packages are built with pinned flake inputs, and updates are deployed by
reflashing. The Pi root filesystem remains writable: this is a deployment model,
not a read-only root or verified-boot guarantee. SSH host keys are persistent
on the SD; OpenPGP session state is not intentionally persisted there in plaintext.

## Network and platform responsibilities

The system uses `10.77.0.2/30`, with the operator at `10.77.0.1/30`. It has no
gateway, DNS, DHCP, IPv6 or time synchronization service. Nftables allows SSH
from the operator and replies to established connections, and drops forwarding
and new outgoing connections.

Each platform selects the dedicated Ethernet interface and optional activity LED.
The Pi modules remove wireless/Bluetooth drivers and firmware; Pi 3 controller
nodes are also disabled in its device tree. The Pi firmware boots the kernel
directly, without U-Boot or an initrd. An early filesystem check repairs/reboots
or powers off on failure instead of presenting a recovery shell.

Platform behavior must be validated, not inferred from the common module. In
particular, Pi 3 B+ firmware can try USB/network boot if SD boot fails. The Pi's
firmware-driven LED can also stall under memory pressure. Other firmware, boot
chains, radios, storage and recovery paths need their own review and rehearsal.
See [platform responsibilities](platforms.md#adding-hardware).

## Rehearsal exceptions

Only the stock rehearsal images import `tests/rehearsal/default.nix`. They accept the
shared test fingerprint and enable `type TEXT`, which uses `uinput` to enter the
publicly documented test passphrases over SSH. This intentionally bypasses the
production local-input boundary. They also expose the volatile journal on
`10.77.0.2:2223` to the operator for diagnostics. Neither facility is included in
the stock production images.

Never attach a real private backup to a rehearsal image or send real passphrases
with `type`. Rehearse with disposable fixtures, then reflash the production image
before starting a real ceremony.
