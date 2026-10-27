# CI architecture and caching

The lightweight checks run automatically on every `pull_request` and on pushes
to `main`/`master`. Image inspection is a separate, manually dispatched workflow.
Limiting push runs avoids duplicate builds for feature branches with an open PR.
All identities are public fixtures; no personal
configuration, signing secrets, hardware access or certificate publication is
involved. Test dependencies are build inputs, not additions to the deployed OS.

`flake.nix` imports [`tests/outputs.nix`](../tests/outputs.nix), which assembles
the portable checks from [`tests/checks.nix`](../tests/checks.nix) and the
platform-specific image checks. Physical rehearsal configurations and USB image
builders live separately under [`tests/rehearsal/`](../tests/rehearsal/outputs.nix).

## Runners and build layout

| Job | Runner | Work |
|---|---|---|
| Portable and functional checks | `ubuntu-24.04` (x86_64) | Shell/workflow lint, backup compatibility, mocked flashing, configuration/security regressions and the complete VM ceremony |
| Operator apps | `macos-15` (Apple Silicon) | The same regressions and compilation of `flash`, `vault` and `publish` |
| Pi 1 images (manual) | `ubuntu-24.04-arm` (aarch64) | Cross-build ARMv6 production and rehearsal images; inspect both |
| Pi 3 images (manual) | `ubuntu-24.04-arm` (aarch64) | Build aarch64 production and rehearsal images; inspect both |

GitHub provides standard ARM Linux and Apple Silicon macOS runners; see the
[runner reference](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).
This matches the project's existing aarch64-linux build platform and macOS apps.
Image builds do not require QEMU or an emulated ARM execution layer. Pi 3 still
uses the distinct `aarch64-pc-linux-gnu` target triple to isolate trimmed target
packages from builder tools; see [`pi3.nix`](../platforms/pi3.nix).

Pi 1 and Pi 3 run in parallel. Each job builds production and rehearsal in
sequence, reusing its compiler, kernel and common packages. Two derivations may
build concurrently with two cores each. Unused hosted-runner SDKs are removed
before building, and Nix can collect unreachable paths when disk space is low.
New commits cancel superseded runs on the same ref. Image inspection complements
functional tests; it is not the primary PR feedback loop.

## Two cache layers

Nix first reuses unchanged derivations and the default `cache.nixos.org` binary
substituter. The trimmed packages and custom kernels often differ from stock
Nixpkgs binaries, so they also need a cache of project-specific outputs.

[`magic-nix-cache-action`](https://github.com/DeterminateSystems/magic-nix-cache-action)
stores these outputs in GitHub Actions' cache and makes them available as a Nix
binary cache. It avoids re-uploading paths already available from its upstream
NixOS cache. All jobs enable the GitHub backend explicitly, disable FlakeHub and
disable diagnostic uploads. No Cachix account, publishing token or paid cache
service is required. Action references use readable version tags.

Pushes to `main`/`master` warm the checks cache for later PRs, including forks.
The manual image workflow warms image/compiler entries when dispatched on the base branch.
PR caches remain scoped to their merge ref; they do not update the base branch's
cache. Workflows use `pull_request`, read-only repository permissions and no
persisted checkout credentials. GitHub documents the
[cache scope, retention and storage limits](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
The default repository cache allowance is 10 GB, with eviction after inactivity
or storage pressure. We do not increase that allowance or enable paid storage.

Nix hashes build inputs. README edits should reuse the kernel and runtime
packages; changing a script rebuilds its dependent system/image layers; changing
kernel settings or `flake.lock` can invalidate much more. A cold run still has
to compile all uncached custom packages. Cache hits are an optimization, not a
requirement for correctness, and no warm-cache duration is claimed until measured
on GitHub. If eviction becomes frequent, a shared public binary cache is a
possible later improvement for both CI and users building locally.

## Local checks

Run the lightweight checks from the repository root (use `x86_64-linux` on Linux):

```sh
python3 tests/validate.py
nix build .#checks.aarch64-darwin.scripts .#checks.aarch64-darwin.backup-layout .#checks.aarch64-darwin.flash-preflight
```

`python3 tests/validate.py --build-clients` also builds the macOS operator apps with public fixtures.

## What image checks establish

[`tests/image.nix`](../tests/image.nix) builds each profile with the common and
actual platform modules. [`inspect_image.py`](../tests/inspect_image.py) examines
the resulting image using temporary regular files, without root or mounts:

- Valid MBR entries, partition bounds and no overlap; swap is created on first boot.
- Clean FAT firmware and ext4 root filesystems.
- Expected firmware files, kernel and model-specific device trees.
- Kernel/device-tree contents match the built system closure.
- Boot command line names the expected init, and both init files exist and match the closure.
- No SSH host private key is baked into the distributed image; `flash` injects a fresh key per SD.

Each check produces `report.json` with the image size, system closure NAR size
and checks performed. The workflows print both reports. The NAR size describes
Nix's serialized closure, not compressed SD-image bytes or a RAM requirement.

The inspection is not a boot test. Continue the
[hardware rehearsal](hardware-tests.md) on each supported board.

## Functional test design

[`ceremony.nix`](../tests/ceremony.nix) defines the VMs and fixtures;
[`ceremony.py`](../tests/ceremony.py) contains the step-by-step behavioral checks.
The integration test runs on `ubuntu-24.04` x86_64 with QEMU/KVM. The
[official NixOS testing tutorial](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines.html)
describes `pkgs.testers.runNixOSTest`, and
[`install-nix-action`](https://github.com/cachix/install-nix-action#how-do-i-run-nixos-tests-on-linux)
documents enabling KVM and the required Nix builder features on Actions.
The workflow checks `/dev/kvm` explicitly, and the Linux test requires hardware
acceleration rather than silently falling back to CPU emulation.

Use x86_64 for this behavioral test; ARM runners are useful for compiling board
images but confer no benefit when the test targets hardware-independent services.
A container would need invasive privileges and extra setup to exercise tty1,
USB hotplug, device mapper and the system firewall. The NixOS VM driver supplies
a real kernel and systemd with controlled virtual hardware.

The test boots a 1 GiB vault VM plus a 512 MiB operator VM on an isolated virtual
Ethernet link. It imports the common policy and actual ceremony/controller
modules into the vault, and uses the real restricted SSH endpoint from the
operator. The same [fast mixed-backup builder](../tests/rehearsal/test-stick.nix)
used for physical rehearsals supplies a hot-plugged USB mass-storage device.
Disposable passphrases enter through the VM's emulated keyboard. The test uses no mocked GnuPG or cryptsetup,
passphrase loopback or privileged direct invocation of signing helpers.
The production `type` verb remains unavailable. Virtual tty dimensions and an
undisplayed virtual screen support real `pinentry-curses` in headless CI.

The behavioral checks cover:

1. Initial locked state and the requirement to set the clock.
2. USB insertion, local LUKS passphrase, read-only mapping/mount and selection of the expected private/public backups.
3. Extending the primary key and all three subkeys through the SSH controller, with local pinentry input.
4. Exporting a public-only certificate with the expected fingerprint and expiry dates.
5. Saving the public update and refusing to overwrite an existing same-day snapshot.
6. Closing, removal/reinsertion, loading the saved update and checking the retained expiry dates.
7. Cleanup of the keyring and encrypted mapping, then controlled poweroff.
8. Failure cases: unsupported verbs, operations before validation, an incorrect passphrase, and forbidden keyring access by `keyops`.
9. An unchanged hash of the encrypted backup partition after the ceremony.

For fast cold builds, use the pinned stock NixOS VM kernel and packages from
`cache.nixos.org`. The VM harness explicitly omits the package-trimming
module, which otherwise changes native build dependencies and causes broad
recompilation. This tests the real ceremony/policy modules but does not validate
the minimized Pi package builds; the separate image checks cover that distinction.
The test-only root control channel is provided by the NixOS driver, not exposed
by production images.

The functional derivation runs in every PR workflow and uses the existing GitHub
binary-cache backend for its custom outputs. Nix can reuse a successful test
result when all inputs are unchanged; modifying the ceremony, fixtures or test
must invalidate that result. Measure cold/warm timings before making promises
about duration. Hardware-specific boot and high-memory Argon2 tests remain separate.

For local Apple Silicon development, `checks.aarch64-darwin.ceremony` runs the
same Python scenario on aarch64 guests. It permits CPU emulation when the Nix
sandbox cannot access native acceleration. Darwin uses NixOS's standard store
image option to restore case-sensitive Linux filenames, including terminfo;
Linux CI uses the direct 9p store mount. This local variant does not establish
GitHub's x86_64 runtime or replace a first CI run.

```sh
nix build -L .#checks.aarch64-darwin.ceremony -o result-ceremony
cat result-ceremony/ceremony-report.json
```

The successful check writes `ceremony-report.json` to its output. On failure,
the test gathers the guests' journals when their control channels remain usable.
The test driver also retains command/console logs in the Nix build log. To inspect:

```sh
nix log .#checks.x86_64-linux.ceremony
```
