{ lib, ... }:

# Raspberry Pi 3 B / B+ (BCM2837, 64-bit), mainline kernel.
# Full ceremonies were validated on 3 B. The 3 B+ firmware can fall back to
# USB/network boot if SD boot fails; see docs/hardware-tests.md.
{
  imports = [ ./pi.nix ];

  # The builder's own architecture, but cross-compiled anyway: built
  # natively, the trimmed packages (modules/minimal.nix) would also replace the
  # builder's tools and set off rebuilds of half of nixpkgs (Rust, LLVM,
  # Haskell, Python). Cross needs a triple other than the builder's, or gcc
  # takes itself for native and looks for an unprefixed ld; "pc" is a vendor
  # field nothing reads.
  nixpkgs.hostPlatform = { config = "aarch64-pc-linux-gnu"; };
  # Unlike the Pi 1's, these binaries run on the builder, so their test
  # suites can run too. These two checks had intermittent failures on the
  # original loaded builder and remain disabled in this profile.
  nixpkgs.overlays = [
    (final: prev: lib.optionalAttrs (prev.stdenv.hostPlatform.config == "aarch64-pc-linux-gnu") {
      npth = prev.npth.overrideAttrs { doCheck = false; };
      perl = prev.perl.override {
        overrides = _: { JSON = prev.perl.pkgs.JSON.overrideAttrs { doCheck = false; }; };
      };
    })
  ];

  pgpVault.pi.firmware = {
    kernelFile = "Image";
    dtbs = [
      "broadcom/bcm2837-rpi-3-b.dtb"
      "broadcom/bcm2837-rpi-3-b-plus.dtb"
    ];
    # The mainline kernel needs its own device trees (with the overlay below
    # already applied), not the firmware's bcm2710-* ones. No monitor: the
    # GPU gets the minimum, and argon2 the rest of the 1 GB.
    extraConfigTxt = ''
      arm_64bit=1
      gpu_mem=16
      [pi3]
      device_tree=bcm2837-rpi-3-b.dtb
      [pi3+]
      device_tree=bcm2837-rpi-3-b-plus.dtb
      [all]
    '';
  };

  # The onboard radios are dead three ways: this overlay drops their
  # controllers, and pi.nix leaves no driver or firmware for them.
  # Wi-Fi hangs off the Arasan SDHCI (mmc@7e300000; the SD card is on sdhost,
  # mmc@7e202000) and Bluetooth off the PL011 (serial@7e201000).
  hardware.deviceTree.filter = "bcm2837-rpi-3-b*.dtb";
  hardware.deviceTree.overlays = [
    {
      name = "disable-radios";
      dtsText = ''
        /dts-v1/;
        /plugin/;
        / {
          compatible = "brcm,bcm2837";
          fragment@0 {
            target-path = "/soc/mmc@7e300000";
            __overlay__ { status = "disabled"; };
          };
          fragment@1 {
            target-path = "/soc/serial@7e201000";
            __overlay__ { status = "disabled"; };
          };
        };
      '';
    }
  ];

  # arm64's defconfig builds in every SoC family's drivers (a 53 MB kernel);
  # only the BCM2835 family is kept, and what depends on the rest goes too.
  boot.kernelPatches = [
    {
      name = "pi3-only";
      patch = null;
      structuredExtraConfig = lib.genAttrs [
        "ARCH_ACTIONS"
        "ARCH_AIROHA"
        "ARCH_SUNXI"
        "ARCH_ALPINE"
        "ARCH_APPLE"
        "ARCH_ARTPEC"
        "ARCH_AXIADO"
        "ARCH_BCM_IPROC"
        "ARCH_BCMBCA"
        "ARCH_BRCMSTB"
        "ARCH_BERLIN"
        "ARCH_BLAIZE"
        "ARCH_CIX"
        "ARCH_EXYNOS"
        "ARCH_K3"
        "ARCH_LG1K"
        "ARCH_HISI"
        "ARCH_KEEMBAY"
        "ARCH_MEDIATEK"
        "ARCH_MESON"
        "ARCH_MICROCHIP"
        "ARCH_SPARX5"
        "ARCH_MVEBU"
        "ARCH_LAYERSCAPE"
        "ARCH_MXC"
        "ARCH_S32"
        "ARCH_MA35"
        "ARCH_NPCM"
        "ARCH_QCOM"
        "ARCH_REALTEK"
        "ARCH_RENESAS"
        "ARCH_ROCKCHIP"
        "ARCH_SEATTLE"
        "ARCH_INTEL_SOCFPGA"
        "ARCH_SOPHGO"
        "ARCH_STM32"
        "ARCH_SYNQUACER"
        "ARCH_TEGRA"
        "ARCH_TESLA_FSD"
        "ARCH_SPRD"
        "ARCH_THUNDER"
        "ARCH_THUNDER2"
        "ARCH_UNIPHIER"
        "ARCH_VEXPRESS"
        "ARCH_VISCONTI"
        "ARCH_XGENE"
        "ARCH_ZYNQMP"
      ] (_: lib.mkForce lib.kernel.no)
      // {
        # No ARMv8 crypto extensions on the BCM2837: AES for dm-crypt (the
        # stick, the swap) is NEON's, built in rather than a module the
        # kernel would have to load mid-unlock.
        CRYPTO_AES_ARM64_NEON_BLK = lib.kernel.yes;
        CRYPTO_AES_ARM64_BS = lib.kernel.yes;
      };
    }
  ];
}
