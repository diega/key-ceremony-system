{ nixpkgs, pkgs, sshPublicKey }:
let
  testStick = import ./test-stick.nix { inherit pkgs; };
  systems = nixpkgs.lib.genAttrs [ "pi1" "pi3" ] (platform:
    nixpkgs.lib.nixosSystem {
      modules = [
        ../../modules
        (../../platforms + "/${platform}.nix")
        ./default.nix
        { pgpVault = { inherit sshPublicKey; }; }
      ];
    }
  );
in
{
  nixosConfigurations = nixpkgs.lib.mapAttrs' (platform: system:
    nixpkgs.lib.nameValuePair "pgp-vault-test-${platform}" system
  ) systems;

  packages = nixpkgs.lib.mapAttrs' (platform: system:
    nixpkgs.lib.nameValuePair "sd-image-test-${platform}" system.config.system.build.vaultImage
  ) systems // {
    # Historical cryptsetup defaults: Argon2i with 1 GiB of memory.
    # Public test passphrases: prueba-luks-1 / prueba-gpg-1.
    test-stick = testStick "pgp-vault-test-stick.img" 1048576 "legacy";
    test-stick-fast = testStick "pgp-vault-test-stick-fast.img" 65536 "legacy";
    # Fast compatibility rehearsal with historical and current backup names.
    test-stick-fast-layouts = testStick "pgp-vault-test-stick-fast-layouts.img" 65536 "mixed";
  };
}
