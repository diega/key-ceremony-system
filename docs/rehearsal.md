# Rehearse with a disposable key

The rehearsal key and both passphrases are intentionally public test fixtures:

| Item | Value |
|---|---|
| Primary fingerprint | `475C6A3F73D438CDEDE7C3D27DE9AE9985243C38` |
| LUKS passphrase | `prueba-luks-1` |
| OpenPGP passphrase | `prueba-gpg-1` |

Never use these keys for real data or attach a real private backup to a rehearsal
image. The test-only `type` command sends these dummy passphrases over SSH and
injects them with `uinput`. The journal is exposed on `10.77.0.2:2223` for
diagnostics. These two facilities are absent from stock production images.

### 1. Build and write the spare USB stick

Build the fast fixture with mixed historical/current filenames:

```sh
nix build .#packages.aarch64-linux.test-stick-fast-layouts -o result-test-stick-fast-layouts
```

Identify the **spare USB stick** using `diskutil list physical`. Device numbers
can change after reinsertion; the integrated SD reader may report a card as
internal. Replace `diskN` below with the whole USB device, not a partition.
**This command erases that spare USB stick:**

```sh
diskutil unmountDisk /dev/diskN && sudo dd if="$PWD/result-test-stick-fast-layouts" of=/dev/rdiskN bs=4m status=progress && sync && diskutil eject /dev/diskN
```

The fixture uses 64 MiB Argon2i so the workflow can be rehearsed quickly. It contains
several naming generations with verified mtimes; expected initial selections are
listed in [the fixture notes](../tests/fixtures/README.md).

### 2. Flash the rehearsal SD

Identify the **SD card separately**. Flashing erases it too:

```sh
nix run --override-input vault-config path:./.local/vault-config .#flash -- /dev/diskN sd-image-test-pi3
```

The app displays the device, reader/media name, bus, size and partition layout
before asking for confirmation. It builds the image, injects a fresh Ed25519 SSH
host key, checks the filesystem, writes the SD and pins the public host key in
`./known_hosts`. It verifies that the target is a whole external disk or removable
SD card, at most 128 GB, and aborts if unmounting fails. Reflashing changes the pin.

Always specify the image: `flash` defaults to the **production** Pi 3 image.
Start the builder yourself as above, or explicitly allow the standard nix-darwin
VM to be started with `PGP_VAULT_START_BUILDER=1` before the command. The app stops
only a builder VM that it started itself.

### 3. Boot and set the clock

Set the Mac's dedicated Ethernet interface manually:

| Setting | Value |
|---|---|
| Mac IPv4 | `10.77.0.1` |
| Netmask | `255.255.255.252` |
| Router / DNS | None on this interface |
| System IPv4 | `10.77.0.2` |

Boot the system with the SD and Ethernet attached, **without the USB backup**.
Keep the operator's authentication key/token available on the Mac. A physical
keyboard is optional for this rehearsal because `uinput` can enter its dummy secrets.

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- status
nix run --override-input vault-config path:./.local/vault-config .#vault -- set-clock "$(date +%s)"
```

The system intentionally waits for `set-clock` each boot before requesting an
unlock. The stock Pi setup has no RTC or network time synchronization.

### 4. Unlock and inspect the selected backup

Insert the test USB stick into the system. Query `status` until it reports
`WAITING for the USB stick passphrase`, then run:

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- type prueba-luks-1
nix run --override-input vault-config path:./.local/vault-config .#vault -- status
```

Wait for `idle, stick open` and the expected test fingerprint. For the mixed fixture,
the initial selection should be:

```text
Loaded:     2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key
            + 7DE9AE9985243C38-2026-10-23.asc
```

### 5. Extend, save and export

Choose a future date. On macOS, the following computes two years from today and
starts the signing operation in terminal A:

```sh
renew_until="$(date -u -v+2y +%F)"
nix run --override-input vault-config path:./.local/vault-config .#vault -- extend "$renew_until"
```

While it waits, use terminal B to query `status`. Once it reports
`WAITING for the master key passphrase`, enter the **test** passphrase:

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- type prueba-gpg-1
```

Wait for `extend` to finish successfully. Then save and inspect the public result:

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- backup
nix run --override-input vault-config path:./.local/vault-config .#vault -- export-public > pubkey-rehearsal.asc
gpg --show-keys pubkey-rehearsal.asc
```

The primary key and all non-revoked subkeys should have the chosen expiry date.
Do not publish the shared rehearsal certificate.

### 6. Verify persistence and finish

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- close
```

Remove the USB stick, wait at least five seconds, and reinsert it. Wait for the
LUKS prompt and repeat the test `type prueba-luks-1` command. `status` should now
show `gpg-0x7DE9AE9985243C38-<today>.asc` and retain the updated expiry dates, loaded
from the public partition alongside the original private export. Close and power off:

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- close
nix run --override-input vault-config path:./.local/vault-config .#vault -- poweroff
```


Run commands from the repository root, after [setup](setup.md). When the rehearsal succeeds, follow [production usage](usage.md).
