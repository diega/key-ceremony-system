{ config, lib, pkgs, ... }:

# Hardware-independent vault policy. Combine with one dedicated platform module.
{
  imports = [ ./minimal.nix ./vault.nix ];

  options.pgpVault.ethernetMatch = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    description = "systemd-networkd match settings selecting the dedicated wired interface.";
  };

  config = {
    networking.hostName = "pgp-vault";
    time.timeZone = "UTC";
    system.stateVersion = "26.05";

    # The image is the only way to change this machine: reflash, never rebuild
    # in place.
    nix.enable = false;
    documentation.enable = false;
    environment.defaultPackages = lib.mkForce [ ];

    # Key material only ever lives in RAM: /tmp and the journal in tmpfs, no
    # core dumps of gpg-agent. Platforms may supply only ephemeral encrypted swap.
    assertions = [ {
      assertion = lib.all (swap: swap.randomEncryption.enable) config.swapDevices;
      message = "pgp-vault requires swap encrypted with a fresh random key on every boot.";
    } ];
    boot.tmp.useTmpfs = true;
    services.journald.storage = "volatile";
    systemd.coredump.enable = false;
    security.pam.loginLimits = [
      { domain = "*"; type = "hard"; item = "core"; value = "0"; }
    ];
    systemd.settings.Manager = {
      DefaultLimitCORE = "0:0";
      # Ctrl+Alt+Del from a local USB keyboard must not reboot mid-ceremony.
      CtrlAltDelBurstAction = "none";
    };
    systemd.ctrlAltDelUnit = "multi-user.target";
    # The root filesystem permits neither setuid execution nor device nodes.
    fileSystems."/".options = [ "noatime" "nosuid" "nodev" ];

    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.sysrq" = 0;
      "fs.suid_dumpable" = 0;
      # Not even keyops can attach to its own gpg-agent and read its memory.
      "kernel.yama.ptrace_scope" = 2;
    };
    # nixpkgs' kernel has no lockdown LSM; at least no kexec into another kernel.
    security.protectKernelImage = true;

    users.mutableUsers = false;
    # Users come from systemd-sysusers at boot, not NixOS's Perl activation
    # script: no Perl in the image (cross-compiled, it also drags in the
    # builder's own coreutils and glibc). sysusers only sets initial passwords,
    # which on a reflash-only machine are the only ones.
    systemd.sysusers.enable = true;
    users.users.root.initialHashedPassword = "!";
    # Privileged work is exposed only through fixed services (vault.nix);
    # the image installs no setuid wrappers or privilege-escalation command.
    users.allowNoPasswordLogin = true;
    # No password: SSH only runs keyops-ctl (see vault.nix). A system user
    # (sysusers creates no others), with bash, which sshd runs the forced
    # command through.
    users.users.keyops = {
      isSystemUser = true;
      group = "users";
      shell = pkgs.bashInteractive;
      # Read-only and root-owned: no ~/.bashrc or ~/.ssh for anything to plant
      # (bash sources ~/.bashrc even for an SSH forced command).
      home = "/var/empty";
      createHome = false;
    };

    # A single point-to-point cable to the Mac: 10.77.0.1 (Mac) <-> 10.77.0.2 (Pi).
    # No gateway, no DNS, no IPv6; the firewall lets in SSH from the Mac and lets
    # nothing start on the way out.
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    networking.wireless.enable = false;
    hardware.bluetooth.enable = false;
    networking.nameservers = [ ];
    services.resolved.enable = false;
    services.timesyncd.enable = false;

    systemd.network.networks."10-mac" = {
      matchConfig = config.pgpVault.ethernetMatch;
      address = [ "10.77.0.2/30" ];
      networkConfig = {
        DHCP = "no";
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
      linkConfig.RequiredForOnline = "no";
    };

    networking.firewall.enable = false;
    networking.nftables = {
      enable = true;
      ruleset = ''
        table inet filter {
          chain input {
            type filter hook input priority 0; policy drop;
            iif lo accept
            ct state invalid drop
            ct state established,related accept
            ip saddr 10.77.0.1 ip daddr 10.77.0.2 tcp dport 22 ct state new accept
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
    };

    # No logind session for SSH logins: no systemd user manager (and its
    # D-Bus, tmpfiles, activation) started per keyops-ctl call. Each one used
    # to fork a dozen processes in the middle of argon2's memory pressure, the
    # likeliest push behind an unlock that stalled. keyops-ctl needs none of it.
    security.pam.services.sshd.startSession = lib.mkForce false;

    services.openssh = {
      enable = true;
      hostKeys = [ { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; } ];
      # Only the key baked into the image (restricted to keyops-ctl) counts.
      authorizedKeysInHomedir = false;
      settings = {
        AllowUsers = [ "keyops" ];
        AuthenticationMethods = "publickey";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        MaxAuthTries = 2;
        X11Forwarding = false;
        AllowTcpForwarding = "no";
        AllowAgentForwarding = "no";
        AllowStreamLocalForwarding = "no";
        PermitTunnel = "no";
      };
    };
  };
}
