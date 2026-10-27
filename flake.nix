{
  description = "key-ceremony-system: NixOS isolation for offline OpenPGP key-extension ceremonies";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    vault-config = {
      url = "path:./nix/empty-config";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, vault-config }:
    let
      settings = let loaded = import vault-config; in
        assert nixpkgs.lib.assertMsg (!(loaded ? skipArgon2Wipe))
          "key-ceremony-system: skipArgon2Wipe was removed; upstream Argon2 cleanup is always enabled";
        loaded;
      settingTypes = {
        fingerprint = nixpkgs.lib.types.strMatching "[0-9A-F]{40}";
        uidName = nixpkgs.lib.types.strMatching "[^<>:\n\r]+";
        sshPublicKey = nixpkgs.lib.types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( [^\n\r]*)?";
      };
      required = name:
        if (settings.${name} or null) == null then
          throw "key-ceremony-system: set ${name} in the vault-config input (default.nix); copy config.nix.example and pass --override-input vault-config path:/directory-containing-default.nix (see README.md)"
        else if !(settingTypes.${name}.check settings.${name}) then
          throw "key-ceremony-system: invalid ${name} in the vault-config input (default.nix) (see README.md)"
        else settings.${name};
      operatorModule = {
        pgpVault = {
          fingerprint = required "fingerprint";
          uidName = required "uidName";
          sshPublicKey = required "sshPublicKey";
        };
      };
      clientConfig = darwinPkgs.writeText "pgp-vault-operator.pub" (required "sshPublicKey");
      darwinPkgs = nixpkgs.legacyPackages.aarch64-darwin;
      pkgs = nixpkgs.legacyPackages.aarch64-linux;

      systems = import ./nix/systems.nix { inherit nixpkgs operatorModule; };
      rehearsal = import ./tests/rehearsal/outputs.nix {
        inherit nixpkgs pkgs;
        sshPublicKey = required "sshPublicKey";
      };
    in
    {
      nixosModules = {
        default = import ./modules;
        pi = import ./platforms/pi.nix;
        pi1 = import ./platforms/pi1.nix;
        pi3 = import ./platforms/pi3.nix;
      };
      checks = import ./tests/outputs.nix { inherit nixpkgs; };

      nixosConfigurations = systems // rehearsal.nixosConfigurations;
      packages.aarch64-linux = {
        sd-image-pi1 = systems.pgp-vault-pi1.config.system.build.vaultImage;
        sd-image-pi3 = systems.pgp-vault-pi3.config.system.build.vaultImage;
      } // rehearsal.packages;

      # The flash app builds the selected image and injects a fresh SSH
      # host key, pins it in ./known_hosts and writes the card.
      packages.aarch64-darwin.flash = darwinPkgs.writeShellApplication {
        name = "flash";
        runtimeInputs = with darwinPkgs; [ zstd e2fsprogs python3 ];
        text = ''
          configuration_input=${vault-config}
        '' + builtins.readFile ./scripts/flash.sh;
      };
      apps.aarch64-darwin.flash = {
        type = "app";
        program = nixpkgs.lib.getExe self.packages.aarch64-darwin.flash;
      };

      # The vault app runs one restricted control verb on the system.
      packages.aarch64-darwin.vault = darwinPkgs.writeShellApplication {
        name = "vault";
        text = ''
          operator_key=${clientConfig}
        '' + builtins.readFile ./scripts/vault.sh;
      };
      apps.aarch64-darwin.vault = {
        type = "app";
        program = nixpkgs.lib.getExe self.packages.aarch64-darwin.vault;
      };

      # The publish app imports a verified public certificate on the Mac
      # and sends it to keys.openpgp.org, keyserver.ubuntu.com and pgp.mit.edu.
      # Uses the operator's own gpg/keyring on the Mac; token use is optional.
      packages.aarch64-darwin.publish = darwinPkgs.writeShellApplication {
        name = "publish";
        runtimeInputs = with darwinPkgs; [ coreutils gawk gnugrep curl ];
        text = ''
          fpr=${nixpkgs.lib.escapeShellArg (required "fingerprint")}
        '' + builtins.readFile ./scripts/publish.sh;
      };
      apps.aarch64-darwin.publish = {
        type = "app";
        program = nixpkgs.lib.getExe self.packages.aarch64-darwin.publish;
      };
    };
}
