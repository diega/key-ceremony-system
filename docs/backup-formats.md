# Backup formats and filename compatibility

The reader in [key-ceremony-system](../README.md) supports the Linux
LUKS + ext2/3/4 backup layout from historical and
current versions of [drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide).
It consumes an existing backup and never migrates or writes its encrypted files.
These naming rules are not a promise of compatibility with every guide variant
or filesystem; Windows and OpenBSD encrypted-volume formats are outside this scope.

## Private export

A private export lives one directory below the encrypted filesystem's root,
for example `tmp.backup/mastersub.key` or
`2026.10.26-backup/secret-7DE9AE9985243C38-Certify.key`.

| Convention | Accepted filename |
|---|---|
| Historical | `mastersub.key` |
| February 2024 | `certify.key` |
| March 2024 | `<ID>-Certify.key` |
| Current | `secret-<ID>-Certify.key` |

`<ID>` must match the configured primary key's 16-character key ID or full
40-character fingerprint, with an optional `0x` prefix. Matching is case
insensitive. Bare historical names are accepted without an ID in their names.
`sub.key`, `subkeys.key` and `*-Subkeys.key` are not primary-key backups and
are never selected as such.

Across generations, the private file's newest modification timestamp wins.
Different contents tied at the newest timestamp are ambiguous and rejected;
byte-identical aliases are accepted with a deterministic filename selection.
The selected export is copied into RAM, imported as the unprivileged signer
and checked to contain exactly the configured primary certificate and its
primary secret key. A wrong or malformed selected export fails the session;
the reader does not silently fall back to an older backup.

## Public exports

Public snapshots can be alongside the selected private file and in the root of
the separate public partition. These two locations are checked independently.

- `gpg-<ID>-YYYY-MM-DD.asc`
- `<ID>-YYYY-MM-DD.asc`
- `public-<ID>-YYYY-MM-DD.asc`
- Historical `.txt` extensions for the same patterns
- Undated `<ID>.asc`, `<ID>.txt`, `gpg-<ID>.asc`, `public-<ID>.asc`, and `public.asc`

IDs follow the same rules as private filenames. Valid calendar dates are compared
across conventions, not by the complete filename. Undated files are fallbacks
when there is no dated snapshot. Conflicting contents at the latest date are
rejected; identical aliases are accepted. Filenames for other identities and
partial-write filenames are ignored.

A selected public file must parse as exactly one public certificate with the
configured fingerprint and no secret-key records. Invalid selected content
fails the session. A public filename is never sufficient evidence of identity.

Only regular files are considered, symlinks are not followed, and candidates
larger than 1 MiB or containing line breaks in their relative paths are rejected.
GnuPG parses bounded snapshots in RAM as signer, rather than parsing as root.

`backup` continues writing `gpg-0x<ID>-YYYY-MM-DD.asc`, exclusively to the public
partition. It does not overwrite existing same-day snapshots or rename old files.
The new public snapshot is recognized by the same reader on a subsequent session.

## History

The names changed incrementally, while `--armor --export-secret-keys` remained
the operation used to export the primary key and subkeys:

- [2019 guide](https://github.com/drduh/YubiKey-Guide/blob/48bf452e4b87c816eb5d372e2dc81e78a62792a0/README.md#export-secret-keys): `mastersub.key` and `sub.key`.
- [January 2021](https://github.com/drduh/YubiKey-Guide/commit/ad09f543afd90efe93093d699411993875630367): dated temporary directories to make newer backups easier to identify.
- [August 2021](https://github.com/drduh/YubiKey-Guide/commit/7bfae573361e5dda512fe607a8e7902852da73d9): `.asc` and consistent public filenames, addressing [#222](https://github.com/drduh/YubiKey-Guide/issues/222).
- [February 2024](https://github.com/drduh/YubiKey-Guide/pull/417): standardize Certify/Subkeys terminology.
- [March 2024](https://github.com/drduh/YubiKey-Guide/commit/b2959d075b8a89e3b5f36cea224347654871258e): include key IDs in filenames during a broader simplification.
- [August 2026](https://github.com/drduh/YubiKey-Guide/commit/4f08dec9452455fee53c85f3bd7061d9ff5a5466): add `secret-` and `public-` prefixes.

## Fast compatibility rehearsal

Build `.#packages.aarch64-linux.test-stick-fast-layouts` and use the updated
`sd-image-test-pi3`. This disposable fixture uses 64 MiB Argon2i, the existing
publicly documented test passphrases and test identity, and four generations of
private-export names plus several public-snapshot conventions.

Check `status` selects the current private filename and the newest date across
public naming conventions. Then extend, save, export and verify the public key.
Finally close, remove/reinsert and unlock again: the saved public snapshot and
updated dates must be loaded. Never use real backup material in a rehearsal image.

The corrected mixed fixture completed this full round-trip on Pi 3 B on
2026-10-27, with about five seconds for each unlock and load. See the
[hardware record](hardware-tests.md#backup-name-compatibility-rehearsal--2026-10-27)
for evidence, the two initial issues corrected before the successful run, and
the test's scope.
