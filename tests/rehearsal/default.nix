{ config, lib, pkgs, ... }:

# Rehearsal images only: imported by the stock test configurations.
# Expose the volatile journal on 10.77.0.2:2223 for the headless workflow:
# `nc 10.77.0.2 2223`. It contains diagnostics and public key metadata;
# keyboard contents and private exports are not deliberately logged.
# Use only disposable fixtures with this image.
{
  # The throwaway passphrases can be typed over SSH (`vault type TEXT`),
  # through uinput: built here alone, out of tree against the same kernel,
  # which itself stays the real image's (no uinput in it).
  pgpVault = {
    fingerprint = lib.mkForce (lib.fileContents ../fixtures/fingerprint);
    uidName = lib.mkForce "Rehearsal User";
    rehearsalTyper = pkgs.runCommandCC "vault-type" { } ''
      mkdir -p $out/bin
      $CC -O2 -Wall -Werror -o $out/bin/vault-type ${./vault-type.c}
    '';
  };
  boot.extraModulePackages = [
    (
      let
        kernel = config.boot.kernelPackages.kernel;
      in
      pkgs.stdenv.mkDerivation {
        pname = "uinput";
        version = kernel.modDirVersion;
        inherit (kernel) src;
        nativeBuildInputs = kernel.moduleBuildDependencies;
        # The kernel's own toolchain flags, minus those for its in-tree build.
        makeFlags = builtins.filter (f: !(lib.hasPrefix "O=" f || lib.hasPrefix "--eval" f)) kernel.makeFlags ++ [
          "-C"
          "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
          "M=$(NIX_BUILD_TOP)/input/misc"
        ];
        buildPhase = ''
          # uinput.c includes ../input-compat.h: same layout as in the tree.
          mkdir -p $NIX_BUILD_TOP/input/misc
          cp drivers/input/input-compat.h $NIX_BUILD_TOP/input/
          cp drivers/input/misc/uinput.c $NIX_BUILD_TOP/input/misc/
          echo 'obj-m := uinput.o' > $NIX_BUILD_TOP/input/misc/Kbuild
          make $makeFlags "''${makeFlagsArray[@]}" modules
        '';
        installPhase = ''
          install -D -m 0444 $NIX_BUILD_TOP/input/misc/uinput.ko \
            $out/lib/modules/${kernel.modDirVersion}/extra/uinput.ko
        '';
      }
    )
  ];
  boot.kernelModules = [ "uinput" ];

  # Every 30 s, memory pressure and argon2's progress into the kernel log
  # in the rehearsal journal.
  systemd.services.rehearsal-pressure = {
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.gawk pkgs.gnused ];
    serviceConfig.Restart = "always";
    script = ''
      while sleep 30; do
        cpu=0
        for stat in /proc/[0-9]*/stat; do
          read -r -a st < "$stat" 2>/dev/null || continue
          [ "''${st[1]}" = "(cryptsetup)" ] && cpu=$(( (st[13] + st[14]) / 100 ))
        done
        read -r _ some _ < /proc/pressure/memory
        full="$(sed -n 's/^full avg10=\([^ ]*\).*/\1/p' /proc/pressure/memory)"
        mem="$(awk '/^(MemAvailable|SwapFree|SwapCached):/ { printf "%s%d ", $1, $2 / 1024 }' /proc/meminfo)"
        echo "rehearsal: argon2 ''${cpu}s, psi mem $some full=$full, $mem" > /dev/kmsg
      done
    '';
  };

  systemd.sockets.rehearsal-journal = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "10.77.0.2:2223";
      FreeBind = true;
      Accept = true;
    };
  };
  systemd.services."rehearsal-journal@" = {
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/bin/journalctl -b --no-pager -o short-monotonic";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      DynamicUser = true;
      SupplementaryGroups = [ "systemd-journal" ];
    };
  };

  networking.nftables.ruleset = lib.mkForce ''
    table inet filter {
      chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state invalid drop
        ct state established,related accept
        ip saddr 10.77.0.1 ip daddr 10.77.0.2 tcp dport { 22, 2223 } ct state new accept
      }
      chain forward {
        type filter hook forward priority 0; policy drop;
      }
      chain output {
        type filter hook output priority 0; policy drop;
        oif lo accept
        ct state established,related accept
      }
    }
  '';
}
