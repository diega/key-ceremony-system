# Hardware validation record

This record belongs to [key-ceremony-system](../README.md). It separates
hardware observations from configuration-only checks. See the [current design](design.md)
for the security model and [platform modules](platforms.md) for porting requirements.

## Validation summary

| Platform | Hardware evidence | Limits |
|---|---|---|
| Raspberry Pi 1 Model B, 512 MB | Image built and booted during the original hardware work | A 1 GiB Argon2 unlock did not complete in a practical time; no complete current compatibility rehearsal is claimed |
| Raspberry Pi 3 B, 1 GB | Full unlock, extension, backup/export, close and poweroff; the fast compatibility rehearsal also verified remove/reinsert/reload | Timings depend strongly on the SD card and KDF parameters |
| Raspberry Pi 3 B+ | Device tree and image support included | Full workflow not validated; firmware may fall back to USB/network boot if SD boot fails |
| Other hardware / architectures | Contributions welcome; common-module evaluation on x86_64 passes | No other physical platform is validated by this repository |

The Pi 1 and Pi 3 have both been exercised on hardware, with the different scopes
shown above. Four Pi configurations are evaluated by the regression suite. An
x86_64 fixture checks module portability without building or booting an x86_64 image.

## Original Pi 3 B deployment — October 2026

- The firmware boots the mainline kernel directly, with no U-Boot or initrd.
- `smsc95xx` network, SSH with the YubiKey, `set-clock`, `close`, `poweroff`.
- A USB keyboard enters the LUKS passphrase on tty1.
- Full rehearsal with the test key: unlock (read-only), load the `tmp.*` plus
  the newest public key from the unencrypted partition, `extend`, `backup` to
  the public partition, `export-public`, close, and unlock again, now loading
  the new public key with the extended dates.
- Unlocking a 1 GiB argon2i LUKS2: 1 h 46 min (Pi 3 B, Netac class 6 SD card),
  with the original wipe workaround enabled. This does not validate the new default.

## Configurable image rehearsal — 2026-10-26

Tested on the Pi 3 B using `sd-image-test-pi3`, with
upstream cryptsetup and Argon2 cleanup (the workaround was disabled for this
run and has since been removed).
The disposable `test-stick` image used LUKS2, Argon2i, 1 GiB of memory,
four iterations and four threads. Its shared test key was used exclusively.

- Boot, pinned SSH authentication and `set-clock` succeeded. Ephemeral encrypted
  swap was available (2047 MiB reported). The Pi waited for clock setup before
  requesting the USB passphrase.
- Both test passphrases were entered through the rehearsal-only `uinput` verb.
  The physical USB keyboard was disconnected during Argon2 without interrupting
  the operation. SSH status requests succeeded during memory pressure.
- The journal records virtual keyboard creation at 434.212 s after boot and
  successful key loading at 6493.642 s: approximately **1 h 41 min**, including
  passphrase injection and key loading. This is an approximate elapsed time,
  not an isolated measurement of the final Argon2 wipe or a controlled comparison
  with the older real-backup measurement.
- The encrypted filesystem mounted read-only. The test primary key and all three
  S/E/A subkeys were extended from 2027-10-21 to **2028-10-26**.
- `backup` saved `gpg-0x7DE9AE9985243C38-2026-10-26.asc` to the public partition.
  `export-public` produced a 6917-byte certificate. A separate temporary keyring
  on the Mac confirmed the test primary fingerprint, the original three subkeys,
  all four expiry dates, four valid self-signatures, and no secret-key records.
- `close` succeeded. This run does not test reloading the saved snapshot after
  removing and reinserting the stick, or interrupted writes/power loss.

The journal also contains two kernel blocked-task warnings for an SD-card
`mmc_rescan` worker and 19 `/proc` sampling races involving processes that exited
before their stat files were read. Unlocking nevertheless completed. These
observations remain relevant to diagnostics and should not be described as a
warning-free run. Raw logs and the public export are retained locally in
`.local/` and are excluded from publication.

## Backup-name compatibility rehearsal — 2026-10-27

The corrected `sd-image-test-pi3` and `test-stick-fast-layouts` images completed
an end-to-end rehearsal on the Pi 3 B. The USB fixture uses 64 MiB Argon2i with
upstream cleanup, the shared disposable RSA identity and several historical and
current backup naming conventions.

- Private selection: `2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key`, whose
  verified inode mtime is newer than the other three historical exports.
- Initial public selection: `7DE9AE9985243C38-2026-10-23.asc`, by date rather
  than the lexical order of the complete names. The optional adjacent
  `public-7DE9AE9985243C38-2026-10-22.asc` was also validated and imported.
- The journal records virtual keyboard creation at 163.048 s after boot and
  key loading at 167.853 s: approximately **5 seconds**, including typing and
  import. No swap was in use in the status observations.
- The primary key and all three S/E/A subkeys were extended to **2028-10-27**.
  `backup` saved `gpg-0x7DE9AE9985243C38-2026-10-27.asc`. The 6917-byte public
  export was checked in a separate Mac keyring: expected fingerprint, original
  three subkeys, all expiry dates, four valid signatures and no secret records.
- `close` cleared the keyring. The USB stick was removed for five seconds,
  reinserted and unlocked again through `uinput`. The reader selected the same
  private export and the newly saved `gpg-0x...-2026-10-27.asc` public snapshot.
  All four expiry dates remained **2028-10-27**.
- The second opening took approximately **5 seconds** as well (virtual keyboard
  at 468.124 s, key loaded at 472.679 s). Its public export was independently
  verified for identity, subkeys, dates and active signatures. It is not
  byte-identical to the first export: importing the original private backup
  alongside its public update merges the older and newer self-signatures
  (eight signature packets instead of four); the effective expiry dates match.
- The final `close` succeeded and status confirmed `Keyring: not loaded`.

The first hardware attempt failed before importing any key: `cmp` was missing
from the minimal runtime PATH, and the fixture filesystem had normalized its
source mtimes. These were corrected by sharing the helper dependency list
(including diffutils) with tests, restricting test PATH to that list, and setting
and verifying inode mtimes with debugfs after filesystem creation. The repeated
hardware run above used both corrections. The selection logic has 13 automated
cases, in addition to the existing image/configuration and flashing checks.

This run validates the mixed naming fixture and persistence round-trip. It does
not physically exercise every naming convention in isolation or fault injection
such as power loss during a write. The raw journals, reports and public exports
are retained under `.local/` and excluded from publication.
