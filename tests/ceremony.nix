{ pkgs }:
let
  # The driver may run on Darwin; the guests and USB fixture are always Linux.
  guestPkgs = pkgs.pkgsLinux;
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" guestPkgs;
  stick = (import ./rehearsal/test-stick.nix { pkgs = guestPkgs; })
    "ceremony-test-stick.img" 65536 "mixed";
in
pkgs.testers.runNixOSTest {
  name = "key-ceremony-system";
  enableOCR = false;
  # Require KVM in Linux CI. Darwin can use software emulation for local checks
  # when Hypervisor.framework is unavailable inside the Nix build sandbox.
  qemu.forceAccel = pkgs.stdenv.hostPlatform.isLinux;
  requiredFeatures.apple-virt = false;
  globalTimeout = 10 * 60;

  defaults = { lib, ... }: {
    virtualisation = {
      graphics = false;
      memorySize = lib.mkDefault 512;
      vlans = [ ];
      interfaces.eth1 = { vlan = 1; assignIP = false; };
      restrictNetwork = true;
      # Darwin's case-insensitive store renames colliding terminfo entries.
      # The standard store image restores their Linux names; Linux CI uses 9p.
      useNixStoreImage = pkgs.stdenv.hostPlatform.isDarwin;
      # Keep the test driver's normal overlay-store lifecycle with either base.
      writableStore = true;
    };
    networking.useDHCP = false;
    services.timesyncd.enable = false;
    nix.enable = false;
    systemd.services.register-nix-paths.enable = false;
    documentation.enable = false;
  };

  nodes.vault = { pkgs, lib, ... }: {
    imports = [ ../modules ];
    # Reuse cached stock packages/kernel. The ceremony and isolation policy
    # are unchanged; package minimization is covered by separate image checks.
    disabledModules = [ ../modules/minimal.nix ];
    # qemu-vm normally supplies an empty root password for interactive tests.
    # Keep the production lock; the driver has its separate virtio channel.
    users.users.root.hashedPasswordFile = lib.mkForce null;
    pgpVault = {
      fingerprint = pkgs.lib.fileContents ./fixtures/fingerprint;
      uidName = "Ceremony Test";
      sshPublicKey = keys.snakeOilEd25519PublicKey;
      ethernetMatch.Name = "eth1";
    };
    virtualisation.memorySize = 1024;
    # Exercise tty1 with an undisplayed virtual screen.
    virtualisation.graphics = lib.mkForce true;
    virtualisation.qemu.options = [ "-display none" ];
    environment.systemPackages = [ pkgs.procps ];
  };

  nodes.operator = { pkgs, ... }: {
    system.stateVersion = "26.05";
    networking.interfaces.eth1.ipv4.addresses = [ {
      address = "10.77.0.1";
      prefixLength = 30;
    } ];
    environment.systemPackages = [ pkgs.openssh pkgs.gnupg ];
    environment.etc."operator-test-key".source = keys.snakeOilEd25519PrivateKey;
    environment.etc."public-fixture.asc".source = ./fixtures/public.asc;
  };

  testScript = ''
    fixture_path = "${stick}"
  '' + builtins.readFile ./ceremony.py;
}
