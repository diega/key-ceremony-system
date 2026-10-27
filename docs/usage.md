# Production usage

Run commands from the repository root, after [setup](setup.md) and a successful [disposable rehearsal](rehearsal.md).

## Ceremony

1. Fill all three identity fields in your local configuration. Inspect the expected
   primary fingerprint and the compatible real backup before starting.
2. Reflash the SD with the production image. **This erases the rehearsal SD:**

   ```sh
   nix run --override-input vault-config path:./.local/vault-config .#flash -- /dev/diskN sd-image-pi3
   ```

3. Boot without the USB backup, with Ethernet and a **local USB keyboard** attached.
   Set the clock as above, then insert your real backup. Check `status` before
   entering its LUKS passphrase directly on the system keyboard and pressing Enter.
4. Inspect the loaded fingerprint, UIDs and dates. If recent public updates are
   missing, import a current certificate from the Mac:

   ```sh
   gpg --export YOUR_PRIMARY_FINGERPRINT | nix run --override-input vault-config path:./.local/vault-config .#vault -- import-public
   ```

5. Run `extend` with your intended future date. Enter the real OpenPGP passphrase
   **only on the system's local keyboard**, when pinentry is waiting. Production
   has no `type` command. Inspect the primary key and all subkey dates afterward.
6. Run `backup`, export the public certificate to a file and inspect it. Keep the
   public update: closing or power loss discards unsaved session changes. The
   original private backup does not need to be rewritten for an expiry extension.
7. Optionally publish the verified public certificate from the Mac as described
   below. Then `close`, remove the USB stick and `poweroff`.

The activity LED is steady when waiting for input/insertion/removal, fast blinking
while working and heartbeat while idle. Under memory pressure it can stall;
`status` gives the fuller view. A platform can omit the activity LED. Passphrase
entry uses the kernel's US keyboard layout.

## Commands and image outputs

Invoke control verbs with:

```sh
nix run --override-input vault-config path:./.local/vault-config .#vault -- COMMAND
```

| Verb | Action |
|---|---|
| `status` | Show clock, console state, selected files, public key listing, UID hashes and memory |
| `set-clock EPOCH` | Set the system clock from the operator's trusted clock |
| `import-public` | Read one matching public certificate from stdin |
| `extend YYYY-MM-DD` | Extend the primary key and every non-revoked subkey to a future date |
| `add-uid EMAIL` | Add a UID using the configured `uidName` |
| `revoke-uid UID-HASH` | Revoke the UID identified by the hash shown in `status` |
| `primary-uid UID-HASH` | Set that UID as primary |
| `backup` | Save a public snapshot on the USB public partition |
| `export-public` | Write the public certificate to stdout |
| `close` | Cancel pending work, stop the agent, clear the keyring and close LUKS |
| `poweroff` | Power off after closing |
| `type TEXT` | **Rehearsal only:** inject 1–64 characters from `[a-z0-9-]` and Enter through `uinput` |

The SSH client ignores personal SSH config, checks `known_hosts`, selects the
configured authentication key and reuses its connection for up to 15 idle minutes.
A fresh connection may need a token touch or PIN; later requests may reuse it.

The SD outputs below are under `packages.aarch64-linux`, including the cross-built
ARMv6 Pi 1 artifacts. They can be built directly with `nix build`, using the same
configuration override; `flash` adds host-key injection and pinning before writing.

| Hardware | Production | Rehearsal |
|---|---|---|
| Pi 1 Model B | `sd-image-pi1` | `sd-image-test-pi1` |
| Pi 3 B / B+ | `sd-image-pi3` | `sd-image-test-pi3` |

Disposable USB outputs need no personal configuration:

| Output | Contents |
|---|---|
| `test-stick-fast-layouts` | Recommended rehearsal: mixed filename generations, 64 MiB Argon2i |
| `test-stick-fast` | Historical filename layout, 64 MiB Argon2i |
| `test-stick` | Historical layout, 1 GiB Argon2i for memory-pressure testing |

Only `flash`, `vault` and `publish` apps for `aarch64-darwin` are currently exported.
For direct SSH host-key setup on other operator systems or different disk formats,
add a reviewed integration rather than disabling host-key verification.

## Optional public-key publication

After inspecting the production export, run on the Mac:

```sh
nix run --override-input vault-config path:./.local/vault-config .#publish -- pubkey-YYYY-MM-DD.asc
```

This is an explicit external side effect: it imports the canonical public
certificate into your Mac's GnuPG keyring and sends it to `keys.openpgp.org`,
`keyserver.ubuntu.com` and the optional `pgp.mit.edu` endpoint. It validates the
configured fingerprint and public-only content and compares readback expiry dates
for the primary key and subkeys. The MIT endpoint is plain HTTP and informational;
the first two use HKPS and are required by the script. Email verification on
keys.openpgp.org or server propagation may affect the readback result.

Do not run `publish` for the shared test key. Local ceremony commands do not
contact keyservers; publication happens separately on the operator computer.

## Troubleshooting

- **No SSH connection:** give first boot time to initialize, check Ethernet link
  LEDs, the dedicated Mac interface address and that the SD is inserted. Check
  `SSH_AUTH_SOCK` and `ssh-add -L` if authentication fails. Reflashing changes
  the host key; use the newly generated `known_hosts` from the flash operation.
- **An old SSH connection is still reused:** close its master session with
  `ssh -F none -O exit -S "$HOME/.ssh/pgp-vault-%C" keyops@10.77.0.2`, then retry.
- **Waiting for clock:** run `set-clock` each boot. The system intentionally
  does not unlock before this step.
- **Waiting for USB removal:** after an unsuccessful load or `close`, remove the
  stick for at least five seconds before reinserting it.
- **Rejected or ambiguous backup:** inspect [the selection rules](backup-formats.md).
  Filenames alone do not prove identity. Do not reformat or alter your only real
  backup to make it load; use an independent copy and export public updates safely.
- **Slow unlock:** high-memory KDFs can cause extensive SD-backed swap I/O. The
  1 GiB test took about 1 h 41 min on the tested Pi 3 setup; the 64 MiB compatibility
  fixture loaded in about five seconds. These are different workloads, not an
  isolated measurement of the Argon2 wipe. The Pi 1 did not complete a 1 GiB unlock
  in a practical time. Inspect parameters with
  `sudo python3 scripts/luks-params.py /dev/rdiskNs1` using the actual LUKS partition.
- **Cancelled operation:** inspect dates before saving. Primary/subkey updates
  happen in separate steps; rerun `extend` if necessary. `close` cancels and clears
  the session but does not undo a public snapshot already written.
- **Snapshot already exists / no public partition:** `backup` refuses; use
  `export-public` to preserve the result on the Mac. Same-day snapshots are not
  overwritten. An updated public export can differ in bytes after reloading
  because GnuPG merges older and newer self-signatures; compare identity, signatures
  and effective expiry dates, not just file hashes.


See [CI and automated validation](ci.md) for the checks and VM test.
