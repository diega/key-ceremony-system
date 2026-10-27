{ nixpkgs, operatorModule }:

# Production composition: common policy + hardware + deployment identity.
let
  mkSystem = platform: nixpkgs.lib.nixosSystem {
    modules = [ ../modules platform operatorModule ];
  };
in
{
  pgp-vault-pi1 = mkSystem ../platforms/pi1.nix;
  pgp-vault-pi3 = mkSystem ../platforms/pi3.nix;
}
