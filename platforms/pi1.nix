{ lib, ... }:

# Raspberry Pi 1 Model B (BCM2835, ARMv6, no Wi-Fi or Bluetooth on the
# board). This ARMv6 system is cross-compiled on the aarch64-linux builder;
# the Apple Silicon host does not execute the target's 32-bit ARM binaries.
{
  imports = [ ./pi.nix ];
  nixpkgs.hostPlatform = lib.systems.examples.raspberryPi;

  pgpVault.pi.firmware = {
    kernelFile = "zImage";
    # The rev 2 board (512 MB); rev 1 differs only in I2C/GPIO wiring this
    # doesn't use. The firmware patches memory size and MAC in either way.
    dtbs = [ "bcm2835-rpi-b-rev2.dtb" ];
    # No monitor: the GPU gets the minimum, the rest of the 512 MB is Linux's.
    extraConfigTxt = ''
      device_tree=bcm2835-rpi-b-rev2.dtb
      gpu_mem=16
    '';
  };
  hardware.deviceTree.filter = "bcm2835-rpi-b*.dtb";
}
