{ config, lib, pkgs, modulesPath, ... }:

# Shared Raspberry Pi platform: GPU firmware boot, SD image and partitions,
# kernel/driver selection, radio shutdown and encrypted SD-backed swap.
# pi1.nix and pi3.nix import this and provide the model-specific details.
let
  cfg = config.pgpVault.pi.firmware;
  toplevel = config.system.build.toplevel;
  # The image's fixed MBR disk id names its partitions on any board.
  diskId = lib.removePrefix "0x" config.sdImage.firmwarePartitionID;
  swapPartition = "/dev/disk/by-partuuid/${diskId}-03";

  # Checks the root filesystem while the kernel still has it read-only, and
  # only hands over to NixOS when it's clean: anything else reboots (after a
  # repair that needs it) or powers off. Never a shell.
  fsckThenInit = pkgs.writeScript "fsck-then-init" ''
    #!${pkgs.runtimeShell}
    PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.coreutils pkgs.util-linux pkgs.gawk ]}
    say() { echo "fsck-then-init: $1" > /dev/console; }
    stop() {
      say "$1; powering off."
      sleep 10
      echo o > /proc/sysrq-trigger
      while :; do sleep 3600; done
    }
    mount -t proc proc /proc || { say "can't mount /proc"; while :; do sleep 3600; done; }
    mount -t sysfs sysfs /sys || stop "can't mount /sys"
    # The kernel found it by PARTUUID; which mmcblk it is depends on the board.
    root=/dev/$(basename "$(readlink -f "/sys/dev/block/$(mountpoint -d /)")")
    case $root in /dev/mmcblk[0-9]p2) ;; *) stop "unexpected root device $root" ;; esac
    [ -b "$root" ] || stop "no $root"
    [ "$(awk '$2 == "/" { split($4, o, ","); print o[1] }' /proc/mounts)" = ro ] \
      || stop "/ is not mounted read-only"
    e2fsck -p "$root"
    rc=$?
    case $rc in
      0 | 1) ;;
      2 | 3)
        # Repaired, and the kernel must not keep using the old state.
        say "root filesystem repaired; rebooting."
        sync
        echo b > /proc/sysrq-trigger
        while :; do sleep 3600; done
        ;;
      *) stop "e2fsck exit $rc on the root filesystem: reflash the card" ;;
    esac
    # Stage 2 mounts /proc and the rest itself when /proc isn't there yet.
    umount /sys || stop "can't unmount /sys"
    umount /proc || stop "can't unmount /proc"
    exec ${config.system.build.toplevel}/init
  '';

  # No U-Boot: its stock Pi build takes USB keyboard input during a boot
  # countdown and falls back to USB/PXE/DHCP boot, all before Linux and its
  # firewall exist. The GPU firmware boots the kernel itself instead; it has
  # no prompt and reads no keyboard. Firmware fallback differs by model;
  # the Pi 3 B+ USB/network-boot caveat is recorded in docs/hardware-tests.md.
  configTxt = pkgs.writeText "config.txt" ''
    kernel=${cfg.kernelFile}
    ${lib.optionalString config.boot.initrd.enable "initramfs initrd followkernel"}
    disable_splash=1
    avoid_warnings=1
    boot_delay=0
    enable_uart=0
    # The SD card's bus clock comes from the GPU core's, which the firmware
    # lowers whenever the CPU idles: exactly while argon2 waits on swap.
    # Fixed at its normal maximum (no over_voltage, so no warranty bit).
    force_turbo=1

    ${cfg.extraConfigTxt}
  '';
in
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

  options.pgpVault.pi.firmware = {
    kernelFile = lib.mkOption {
      type = lib.types.str;
      description = "Name the kernel gets on the FAT partition (config.txt kernel=).";
    };
    dtbs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Device trees, relative to the system's dtbs/, copied next to the firmware.";
    };
    init = lib.mkOption {
      type = lib.types.str;
      default = "${toplevel}/init";
      description = "What the kernel runs as PID 1 (cmdline.txt init=).";
    };
    extraConfigTxt = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Board-specific config.txt lines.";
    };
  };

  config = {
    # Shared Pi platform: each model adds its architecture and device trees.
    nixpkgs.buildPlatform = "aarch64-linux";
    pgpVault.ethernetMatch.Driver = "smsc95xx lan78xx";
    pgpVault.activityLed = "ACT";
    system.build.vaultImage = config.system.build.sdImage;

    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;

    sdImage = {
      # Kernel and initrd live on the FAT partition next to the firmware.
      firmwareSize = 256;
      populateFirmwareCommands = ''
        fw=${pkgs.buildPackages.raspberrypifw}/share/raspberrypi/boot
        cp $fw/bootcode.bin $fw/fixup.dat $fw/start.elf firmware/
        # gpu_mem=16 (pi1.nix) makes the firmware load the cut-down pair
        # instead, and it won't boot without them.
        cp $fw/fixup_cd.dat $fw/start_cd.elf firmware/
        cp ${toplevel}/kernel firmware/${cfg.kernelFile}
        ${lib.optionalString config.boot.initrd.enable "cp ${toplevel}/initrd firmware/initrd"}
        ${lib.concatMapStrings (dtb: "cp ${toplevel}/dtbs/${dtb} firmware/\n") cfg.dtbs}
        cp ${configTxt} firmware/config.txt
        echo "init=${cfg.init} $(cat ${toplevel}/kernel-params)" > firmware/cmdline.txt
        # When the card is in the Mac: no Spotlight index, no fsevents log.
        touch firmware/.metadata_never_index
        mkdir firmware/.fseventsd
        touch firmware/.fseventsd/no_log
      '';
      # Mount points the kernel and fsck-then-init (below) need before
      # NixOS creates anything.
      populateRootCommands = "mkdir -p ./files/dev ./files/proc ./files/sys";
      storePaths = [ fsckThenInit ];
      # The free space is for the swap partition (below).
      expandOnBoot = false;
    };

    # The generic image pulls in ZFS; nothing here uses it.
    boot.supportedFilesystems.zfs = lib.mkForce false;

    # No firmware blobs for any radio, and no wireless/Bluetooth drivers, on
    # any board: also covers a USB dongle someone plugs in.
    hardware.enableRedistributableFirmware = lib.mkForce false;
    hardware.firmware = lib.mkForce [ ];
    boot.blacklistedKernelModules = [
      "brcmfmac" "brcmutil" "cfg80211" "mac80211"
      "bluetooth" "btbcm" "hci_uart"
    ];
    boot.extraModprobeConfig = ''
      install brcmfmac ${pkgs.coreutils}/bin/false
      install bluetooth ${pkgs.coreutils}/bin/false
      install hci_uart ${pkgs.coreutils}/bin/false
      install cfg80211 ${pkgs.coreutils}/bin/false
      install mac80211 ${pkgs.coreutils}/bin/false
    '';

    # The headless ceremony uses a local USB keyboard on tty1. Keep kernel
    # messages out of the prompts; SSH status and the optional LED provide feedback.
    boot.kernelParams = [
      "console=tty1"
      "quiet"
      # Mounted by the kernel itself, with no initrd (below). By the image's
      # fixed MBR disk id, since the mmcblk number differs between boards.
      "root=PARTUUID=${diskId}-02"
      "rootfstype=ext4"
      "rootwait"
    ];
    boot.consoleLogLevel = 3;

    # No initrd at all: the systemd one runs nixos-init (Rust, so a cross
    # rustc) and the scripted one is going away in 26.11. All an initrd would do
    # here is mount the SD card, which the kernel does itself with the SD
    # controllers and ext4 built in (root= in boot.kernelParams above).
    boot.initrd.enable = false;
    # Without an initrd nothing checks the root filesystem: NixOS's stage 2
    # remounts it read-write before systemd, so systemd-fsck-root never runs.
    # The kernel mounts it read-only; this checks it there, then hands over.
    pgpVault.pi.firmware.init = "${fsckThenInit}";

    # The platform builds every tristate option the SoC could use as a module
    # (autoModules): by far the longest compile. Here only what's asked for is
    # built, on top of the platform's defconfig (bcm2835_defconfig, arm64
    # defconfig) and nixpkgs' common config (which keeps its hardening
    # settings).
    # With autoModules off, nixpkgs' common config names many modules that
    # are never reached; as the Pi 1's platform already does, that's not an
    # error.
    # It also installs the device trees of every board of the architecture
    # (some 120 MB on arm64); only the ones the firmware gets are kept.
    boot.kernelPackages = pkgs.linuxPackagesFor (
      (pkgs.linux.override {
        autoModules = false;
        ignoreConfigErrors = true;
      }).overrideAttrs
        (old: {
          postInstall = (old.postInstall or "") + ''
            if [ -d $out/dtbs ]; then
              find $out/dtbs -type f ${
                lib.concatMapStringsSep " " (dtb: "! -path $out/dtbs/${dtb}") cfg.dtbs
              } -delete
              find $out/dtbs -type d -empty -delete
            fi
          '';
        })
    );
    boot.kernelPatches = [
      {
        name = "pgp-vault";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          # The root filesystem, mounted by the kernel itself.
          MMC = yes;
          MMC_BLOCK = yes;
          MMC_BCM2835 = yes; # sdhost
          MMC_SDHCI = yes;
          MMC_SDHCI_PLTFM = yes;
          MMC_SDHCI_IPROC = yes; # the Arasan controller
          EXT4_FS = yes;
          EXT4_USE_FOR_EXT2 = yes; # the 2019 stick may well be ext2

          # The LUKS stick.
          USB_STORAGE = yes;
          SCSI = yes;
          BLK_DEV_SD = yes;
          MD = yes;
          BLK_DEV_DM = yes;
          DM_CRYPT = yes;
          CRYPTO_AES = yes;
          CRYPTO_XTS = yes;
          CRYPTO_ECB = yes;
          CRYPTO_CBC = yes;
          CRYPTO_ESSIV = yes;
          CRYPTO_SHA1 = yes;
          CRYPTO_SHA256 = yes;
          CRYPTO_SHA512 = yes;
          CRYPTO_USER_API_HASH = yes;
          CRYPTO_USER_API_SKCIPHER = yes;
          BLK_DEV_LOOP = yes;

          # A local USB keyboard; the cable to the operator; the firewall.
          HID = yes;
          HID_GENERIC = yes;
          USB_HID = yes;
          INPUT_EVDEV = yes;
          USB_USBNET = yes;
          USB_NET_SMSC95XX = yes; # Pi 1 B, Pi 3 B
          USB_LAN78XX = yes; # Pi 3 B+
          NF_TABLES = yes;
          NF_CONNTRACK = yes;
          NFT_CT = yes;

          # bcm2835_defconfig has no LSMs at all; Yama is what makes
          # kernel.yama.ptrace_scope = 2 (default.nix) exist.
          SECURITY = yes;
          SECURITY_YAMA = yes;

          # Nothing that talks over the air, draws, plays, serves files or
          # swaps kernels; no debug info (the largest part of the compile).
          BT = lib.mkForce no;
          CFG80211 = lib.mkForce no;
          MAC80211 = lib.mkForce no;
          WLAN = lib.mkForce no;
          DRM_VC4 = lib.mkForce no;
          SOUND = lib.mkForce no;
          MEDIA_SUPPORT = lib.mkForce no;
          STAGING = lib.mkForce no;
          NFS_FS = lib.mkForce no;
          NFSD = lib.mkForce no;
          USB_GADGET = lib.mkForce no;
          KEXEC = lib.mkForce no;
          # Rust in the kernel (on by default on aarch64) means a Rust
          # toolchain for the Pi; nothing here uses it.
          RUST = lib.mkForce (option no);
          CRASH_DUMP = lib.mkForce no;
          KGDB = lib.mkForce no;
          DEBUG_INFO_NONE = lib.mkForce yes;
          DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT = lib.mkForce no;
          DEBUG_INFO_BTF = lib.mkForce no;
        };
      }
    ];

    # The Pi 1 has 512 MB of RAM and the Pi 3 1 GB, and LUKS2 sticks made in
    # 2019 ask argon2 for 1 GiB to unlock. Swap on the SD card, encrypted with
    # a key drawn from /dev/urandom at every boot and never stored: once
    # powered off, what was written there can't be read by anyone. (gpg-agent
    # keeps its secrets in locked memory, which is never swapped.) Slow, but it
    # lets cryptsetup do its work.
    #
    # A partition of its own, not a file: swap on dm-crypt on a loop device
    # on ext4 needs memory to free memory, and under argon2's pressure the
    # whole machine stalled (the kernel still answering, nothing else).
    swapDevices = lib.mkOverride 40 [
      {
        device = swapPartition;
        randomEncryption.enable = true;
        # On first boot the partition only appears once make-swap-partition
        # has created it.
        options = [ "defaults" "x-systemd.device-timeout=5min" ];
      }
    ];
    boot.kernel.sysctl = {
      # Unlocking is the one time memory runs short; spare the swap otherwise.
      "vm.swappiness" = 10;
      # argon2 reads its memory at random: reading ahead the next pages on
      # every swap-in only multiplies SD card reads.
      "vm.page-cluster" = 0;
    };
    # The image has two partitions; on first boot this adds the third, 2 GiB
    # right after the root filesystem, which keeps its size (so no
    # sdImage.expandOnBoot, which would take the space).
    systemd.services.make-swap-partition = {
      description = "Create the swap partition on the SD card";
      # Before swap.target, which local-fs.target's tmpfs mounts come after;
      # / is already read-write (stage 2), which is all sfdisk needs.
      unitConfig.DefaultDependencies = false;
      after = [ "systemd-udevd.service" ];
      before = [ "mkswap-${(lib.head config.swapDevices).deviceName}.service" "swap.target" ];
      requiredBy = [ "mkswap-${(lib.head config.swapDevices).deviceName}.service" ];
      path = [ pkgs.util-linux pkgs.coreutils config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        part=$(basename "$(readlink -f "/sys/dev/block/$(mountpoint -d /)")")
        if [ ! -e "/sys/class/block/''${part%2}3" ]; then
          echo "size=2GiB, type=S" | sfdisk --append --no-reread --no-tell-kernel "/dev/''${part%p2}"
          partx --add --nr 3 "/dev/''${part%p2}"
        fi
        # The mkswap unit opens it by this link, which udev makes: on every
        # boot, wait for it here.
        udevadm settle --timeout=60 --exit-if-exists=${swapPartition}
        [ -e ${swapPartition} ]
      '';
    };

    # Just the drivers asked for above, instead of every one the generic image
    # carries (many don't exist for armv6).
    hardware.enableAllHardware = lib.mkForce false;
    # Same for the ramfs systemd pivots into at shutdown (make-initrd-ng, Rust);
    # nothing on the SD card needs that last clean unmount.
    systemd.shutdownRamfs.enable = false;

    # The FAT partition is only read by the GPU firmware, never mounted.
    boot.supportedFilesystems.vfat = lib.mkForce false;
  };
}
