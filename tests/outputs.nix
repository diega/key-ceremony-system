{ nixpkgs }:
nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (system:
  let
    pkgs = nixpkgs.legacyPackages.${system};
    image = import ./image.nix;
  in
  (import ./checks.nix { inherit pkgs; }) // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
    image = image { inherit pkgs nixpkgs; };
    image-rehearsal = image { inherit pkgs nixpkgs; rehearsal = true; };
    image-pi1 = image { inherit pkgs nixpkgs; platform = "pi1"; };
    image-pi1-rehearsal = image { inherit pkgs nixpkgs; platform = "pi1"; rehearsal = true; };
  }
)
