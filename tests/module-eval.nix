# Configuration-only portability test. This is not a supported x86_64 image.
let
  flake = builtins.getFlake (toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  mkSystem = extra: lib.nixosSystem {
    modules = [
      flake.nixosModules.default
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        pgpVault = {
          fingerprint = lib.fileContents ./fixtures/fingerprint;
          uidName = "Module Test";
          sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPZ91Zxxk/Tb42bK7DXuZp6kBfJs+QyXe3jS6Aq40Ec fixture";
          ethernetMatch.Name = "enp1s0";
        };
        fileSystems."/" = { device = "/dev/disk/by-label/VAULT"; fsType = "ext4"; };
        boot.loader.grub.enable = false;
      }
    ] ++ extra;
  };
  generic = mkSystem [ ];
  unencrypted = mkSystem [ { swapDevices = [ { device = "/dev/test-swap"; } ]; } ];
  encrypted = mkSystem [ {
    swapDevices = [ { device = "/dev/test-swap"; randomEncryption.enable = true; } ];
  } ];
  failedAssertions = system:
    map (a: a.message) (builtins.filter (a: !a.assertion) system.config.assertions);
in
{
  system = generic.config.nixpkgs.hostPlatform.system;
  ethernetMatch = generic.config.systemd.network.networks."10-mac".matchConfig;
  activityLed = generic.config.pgpVault.activityLed;
  piOptionsImported = generic.options.pgpVault ? pi;
  sdImageOptionsImported = generic.options ? sdImage;
  swap = generic.config.swapDevices;
  console = generic.config.systemd.services.vault-console.serviceConfig.ExecStart;
  failures = failedAssertions generic;
  encryptedSwapFailures = failedAssertions encrypted;
  unencryptedSwapFailures = failedAssertions unencrypted;
}
