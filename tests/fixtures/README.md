# Disposable OpenPGP fixtures

The secret exports in this directory are intentional public test fixtures.
Never use this identity to protect real data, publish it to keyservers, or
replace these files with a personal backup.

- Primary fingerprint: see `fingerprint`.
- OpenPGP key passphrase: `prueba-gpg-1`.
- Generated rehearsal USB LUKS passphrase: `prueba-luks-1`.
- `mastersub.key` / `sub.key`: disposable RSA key exports in the historical
  backup layout.
- `public.asc`: matching public certificate.

`test-stick-fast` and `test-stick` package these files for the rehearsal images.
Rehearsal images of [key-ceremony-system](../../README.md) accept the operator
SSH public key from the selected `vault-config` input, usually
`.local/vault-config/default.nix`. They always use this test fingerprint and the
name `Rehearsal User`, regardless of production identity settings. The remote
`type` verb is intentionally available only in stock rehearsal images.

The passphrase strings above are fixed test data, not documentation language or
production credentials. Do not change them independently of the image builder
and hardware rehearsal instructions.

`test-stick-fast-layouts` is a 64 MiB Argon2 compatibility fixture. It includes
the same private export under four generations of naming conventions, with
progressively newer mtimes, plus historical/current public snapshot names.
Expected initial selections:

- Private: `2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key`.
- Adjacent public: `public-7DE9AE9985243C38-2026-10-22.asc`.
- Public partition: `7DE9AE9985243C38-2026-10-23.asc`, selected by date despite
  the other prefixes sorting after it.

After `extend` and `backup`, a close/remove/reinsert cycle should select the new
`gpg-0x7DE9AE9985243C38-<today>.asc` public snapshot and retain its updated expiry.
