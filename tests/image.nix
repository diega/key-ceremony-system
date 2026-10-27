{ pkgs, nixpkgs, platform ? "pi3", rehearsal ? false }:
let
  system = nixpkgs.lib.nixosSystem {
    modules = [
      ../modules
      (../platforms + "/${platform}.nix")
      { pgpVault = import ./fixture-config; }
    ] ++ nixpkgs.lib.optional rehearsal ./rehearsal;
  };
  config = system.config;
  closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in
pkgs.runCommand "key-ceremony-system-${platform}-${if rehearsal then "rehearsal" else "production"}-image-check" {
  nativeBuildInputs = with pkgs; [ python3 zstd e2fsprogs dosfstools mtools ];
} ''
  zstd -d ${config.system.build.vaultImage}/sd-image/*.img.zst -o image.img
  python3 ${./inspect_image.py} image.img \
    --platform ${platform} --profile ${if rehearsal then "rehearsal" else "production"} \
    --toplevel ${config.system.build.toplevel} \
    --init ${config.pgpVault.pi.firmware.init} \
    --kernel ${config.pgpVault.pi.firmware.kernelFile} \
    ${nixpkgs.lib.concatMapStringsSep " " (dtb: "--dtb ${nixpkgs.lib.escapeShellArg dtb}") config.pgpVault.pi.firmware.dtbs} \
    --closure-size "$(cat ${closure}/total-nar-size)" --report report.json
  mkdir -p $out
  cp report.json $out/
''
