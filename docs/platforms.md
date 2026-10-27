# Platform modules

[key-ceremony-system](../README.md) is a dedicated NixOS system. Its key operations and isolation policy
are independent of the board. Raspberry Pi is currently the only implemented
hardware family; portability checks do not imply support for other hardware.

## Layout

```text
modules/
  default.nix      common users, SSH, network isolation and volatile state
  vault.nix        key ceremony, controller, console and optional LED signalling
  minimal.nix      trimmed system packages and userland
  backup-layout.sh filename selection and public-identity validation
  backup-tools.nix shared dependency list for the reader and its tests
platforms/
  pi.nix           shared Pi firmware boot, kernel, SD layout and encrypted swap
  pi1.nix          Pi 1 architecture, firmware settings and device tree
  pi3.nix          Pi 3 architecture, device trees and radio-controller shutdown
nix/
  systems.nix      production composition for each hardware model
tests/rehearsal/
  default.nix      disposable identity, diagnostics and virtual keyboard
  outputs.nix      rehearsal configurations, SD images and USB fixtures
  test-stick.nix   encrypted disposable USB image builder
  vault-type.c     virtual keyboard helper, built only for rehearsal
```

Each model imports `pi.nix`. The common vault module does not import any Pi
module, SD image builder or Pi firmware options. Both models have explicit
configuration and package names: `pgp-vault-pi1` / `sd-image-pi1` and
`pgp-vault-pi3` / `sd-image-pi3`.

`flake.nix` imports `nix/systems.nix`, whose `nixosSystem` call combines
`modules/default.nix`, a model module and the operator identity from `vault-config`.
`modules/default.nix` imports `vault.nix` and `minimal.nix`; each model imports
the shared `platforms/pi.nix`. NixOS merges those modules into one system, and
the flake exposes its `config.system.build.vaultImage` as an image package.

Rehearsal composition is separate, in `tests/rehearsal/outputs.nix`. It reuses
the common and hardware modules, adds `tests/rehearsal/default.nix`, and takes
only the operator's SSH key. The rehearsal module forces the disposable identity
and provides its own diagnostics and keyboard helper. The common controller
retains two conditional protocol handlers for `type`; their helper option is
`null` in production, so the verb and helper are absent from production scripts.
The automated VM test imports the production modules directly, without this
rehearsal module, and uses the VM's keyboard instead.

To compose the current Pi 3 system in a downstream flake:

```nix
nixpkgs.lib.nixosSystem {
  modules = [
    keyCeremony.nixosModules.default
    keyCeremony.nixosModules.pi3
    {
      pgpVault = {
        fingerprint = "YOUR_40_CHARACTER_UPPERCASE_PRIMARY_FINGERPRINT";
        uidName = "Alex Example";
        sshPublicKey = "ssh-ed25519 AAAA... your-key-comment";
      };
    }
  ];
}
```

`keyCeremony` denotes this project's flake input in your downstream flake.
The strings above are placeholders. `nixosModules.pi1`, `pi3`, and the shared
`pi` module are exported alongside `default`. Use a model module
when building an image; the shared Pi module alone lacks model-specific settings.
Pi firmware options live under `pgpVault.pi.firmware`.

## Adding hardware

Create a module under `platforms/`, register its production configuration in
`nix/systems.nix`, and expose its image package in `flake.nix`. Add its disposable
variant in `tests/rehearsal/outputs.nix`. Reuse a family module when models share boot and
storage behavior, as Pi 1 and Pi 3 share `pi.nix`.

Register its image checks in `tests/outputs.nix`. A compatible image also needs
its package name allowed by `scripts/flash.sh`; a different image layout needs
the flashing changes described below.

The platform supplies:

- Target/build architecture, boot mechanism, kernel, necessary drivers and root
  filesystem. The shared module does not choose a bootloader or partition layout.
- `pgpVault.ethernetMatch`: systemd-networkd match settings selecting the one
  dedicated wired interface, for example `{ Name = "enp1s0"; }` or the Pi's
  `{ Driver = "smsc95xx lan78xx"; }`. The common policy supplies the static
  addresses and firewall. Match values are strings.
- Optionally `pgpVault.activityLed`: a name under `/sys/class/leds`, such as
  `"ACT"`. It defaults to `null`, which disables LED signalling. SSH status
  remains available without a LED.
- Adequate RAM, or swap with `randomEncryption.enable = true`. The common module
  rejects swap without per-boot random encryption. Pi's partition creation and
  swap tuning stay in its platform module; other targets need not create swap.
- Optionally `system.build.vaultImage` for a distributable image. Pi assigns its
  `sdImage` derivation to that output. The common module itself has no image format.

A platform must also enforce the system's security properties in its boot
chain and kernel: no interactive recovery/boot shell, no network boot fallback
where the claimed platform permits disabling it, no usable radios, and the
kernel features required by the common policy (including Yama). Disabling a
Wi-Fi service alone does not establish that radio hardware is disabled.
Review firmware needs separately: another board's Ethernet may need firmware
that is not present in the Pi profile.

The current `flash` app handles the implemented Pi images: MBR, root filesystem
in partition 2, ext4, and an image exposed under `sd-image/*.img.zst`. Its host-key
injection assumes that layout. A new image format or target architecture needs
an explicit extension to the image/flashing integration; adding a board module
does not make every firmware or disk layout compatible with that tool.

## Validation

`python3 tests/validate.py` evaluates all four existing Pi configurations and an
x86_64 configuration that imports only the common module. The latter checks a
different Ethernet match, no LED, no Pi/SD options, and the encrypted-swap policy.
It is an evaluation fixture, not a bootable or validated x86_64 target.
The [functional VM test](ci.md#functional-test-design) separately boots the common
ceremony and policy with stock packages, virtual USB storage and local keyboard
input. It does not establish support for another physical board or image format.
See the [hardware record](hardware-tests.md) for the different Pi 1 and Pi 3
validation scopes and the completed Pi 3 compatibility round-trip.

Every new platform still needs a physical rehearsal: boot, host-key verification,
clock setup, local passphrase entry, read-only unlock, extension, public backup,
export, close and poweroff. Record model, firmware/boot limitations, RAM/swap,
and test results. A successfully evaluated or built image is not hardware validation.
