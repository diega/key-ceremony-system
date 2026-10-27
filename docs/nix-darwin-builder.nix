# Merge this into your EXISTING nix-darwin configuration, then rebuild it.
# This is a host configuration example, not a module for the vault image.
{ ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.distributedBuilds = true;
  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 4;
    config = {
      virtualisation.cores = 4;
      virtualisation.memorySize = 8192;
      virtualisation.diskSize = 80 * 1024;
    };
  };
}
