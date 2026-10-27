{ config, lib, pkgs, ... }:

# Minimal system userland; independent of boot firmware and board drivers.
let
  without = names: inputs: builtins.filter (p: !(builtins.elem (p.pname or "") names)) inputs;
in
{
  nixpkgs.overlays = [
    # In the Pi cross builds, trim target packages while keeping the
    # builder's native tools on their normal dependency graph.
    (final: prev: lib.optionalAttrs (prev.stdenv.hostPlatform.config == config.nixpkgs.hostPlatform.config) {
      # gpg, gpg-agent and their tools, without the network/keyserver,
      # S/MIME and smartcard parts (dirmngr, gpgsm, scdaemon...). adns is a
      # vestigial input: 2.4 resolves with its own libdns.
      gnupg =
        (prev.gnupg.override {
          withPcsc = false;
          withTpm2Tss = false;
        }).overrideAttrs
          (old: {
            buildInputs = without [ "openldap" "sqlite" "gnutls" "libusb" "adns" ] old.buildInputs;
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--disable-ldap"
              "--disable-sqlite"
              "--disable-gnutls"
              "--disable-ccid-driver"
              "--disable-dirmngr"
              "--disable-gpgsm"
              "--disable-scdaemon"
              "--disable-keyboxd"
              "--disable-tpm2d"
              "--disable-gpgtar"
              "--disable-wks-tools"
            ];
            # The upstream suite invokes gpgsm, which is intentionally disabled.
            doCheck = false;
          });
      pinentry-curses = prev.pinentry-curses.override { withLibsecret = false; };

      # dbus builds against systemdMinimal, a second near-full systemd; the
      # full one doesn't depend on dbus, so it can be used instead. Also
      # without X11, AppArmor and audit.
      dbus =
        (prev.dbus.override {
          x11Support = false;
          systemdMinimal = final.systemd;
        }).overrideAttrs
          (old: {
            buildInputs = without [ "audit" "libapparmor" ] old.buildInputs;
            mesonFlags = map (
              f:
              if f == "-Dapparmor=enabled" then
                "-Dapparmor=disabled"
              else if f == "-Dlibaudit=enabled" then
                "-Dlibaudit=disabled"
              else
                f
            ) old.mesonFlags;
          });

      # No iptables compatibility, no libpcap (never used by nft) and no JSON
      # output (nothing calls `nft -j`).
      nftables = (prev.nftables.override { withXtables = false; }).overrideAttrs (old: {
        buildInputs = without [ "libpcap" "jansson" ] old.buildInputs;
        configureFlags = lib.remove "--with-json" old.configureFlags;
      });

      # debuginfod: libarchive, libmicrohttpd, curl.
      # Its configure still wants pkg-config, which the option drops.
      elfutils = (prev.elfutils.override { enableDebuginfod = false; }).overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [ final.buildPackages.pkg-config ];
      });
      libfido2 = prev.libfido2.override { withPcsclite = false; };

      # No lastlog2: sqlite (and tcl) are only there for it.
      util-linux = (prev.util-linux.override { withLastlog = false; }).overrideAttrs (old: {
        buildInputs = without [ "sqlite" ] old.buildInputs;
      });
      # No fuse2fs, no mke2fs -d from tarballs.
      e2fsprogs = (prev.e2fsprogs.override { withFuse = false; }).overrideAttrs (old: {
        buildInputs = without [ "libarchive" ] old.buildInputs;
        configureFlags = map (
          f: if f == "--with-libarchive=direct" then "--without-libarchive" else f
        ) old.configureFlags;
      });
      # Operator OpenPGP-token authentication uses the external SSH agent.
      # This target does not use FIDO helpers or DNS lookups.
      openssh = prev.openssh.override {
        withFIDO = false;
        withLdns = false;
      };
      linux-pam = prev.linux-pam.override { withAudit = false; };
      shadow = prev.shadow.override {
        withLibbsd = false;
        withTcb = false;
      };
      # Only interpolated into the udev rules builder (a no-op replace for
      # /sbin/mdadm in rules that aren't installed); RAID is off. Recheck with
      # `nix why-depends` if boot.swraid is ever enabled.
      mdadm = final.runCommandLocal "mdadm-stub" { } "mkdir -p $out/sbin";

      systemd = prev.systemd.override {
        withKexectools = false;
        withLibBPF = false; # clang/LLVM
        withTpm2Tss = false;
        withQrencode = false;
        withRemote = false;
        withFido2 = false;
        withHomed = false;
        withImportd = false;
        withSysupdate = false;
        withPasswordQuality = false;
        withLibarchive = false;
        withApparmor = false;
        withPortabled = false;
        withVmspawn = false;
        # systemd-cryptsetup (the cryptsetup CLI is separate) and what only
        # it needs: libfido2, p11-kit...
        withCryptsetup = false;
        withRepart = false;
        withCoredump = false; # elfutils
        withLibidn2 = false;
        withAudit = false;
        withAnalyze = false;
        withHostnamed = false;
        withLocaled = false;
        withTimedated = false;
        withMachined = false;
        withNspawn = false;
        withOomd = false;
        withPolkit = false;
        withFirstboot = false;
        # withResolved = false breaks the build (nss-resolve stays requested);
        # resolved is built but services.resolved is off.
        withTimesyncd = false;
        withVConsole = false; # with console.enable = false
        withDocumentation = false;
        withShellCompletions = false;
      };
    })
  ];

  # switch-to-configuration (Rust) and the installer tools: the image is
  # never updated in place.
  system.switch.enable = false;
  system.disableInstallerTools = true;
  # A dead legacy builder argument that pulls in two perl modules.
  system.systemBuilderArgs.perl = lib.mkForce "";

  # The system does not run Nix or register its store at boot.
  systemd.services.register-nix-paths.enable = false;

  systemd.oomd.enable = false; # with withOomd = false
  boot.enableContainers = false;

  # Its stub ld is built against musl: a second cross toolchain.
  environment.stub-ld.enable = false;

  # systemd's environment generator is nixos-init's env-generator, the one
  # piece of it used here, and it's Rust (a cross rustc). All it does is print
  # systemd.generatorEnvironment, with PATH appended to the current one.
  environment.etc."systemd/system-environment-generators/env-generator".source = lib.mkForce (
    pkgs.writeShellScript "env-generator" (
      lib.concatStrings (
        lib.mapAttrsToList (
          name: value:
          if name == "PATH" then
            ''echo "PATH=\"${value}:$PATH\""''
          else
            "echo ${lib.escapeShellArg "${name}=\"${value}\""}"
        ) config.systemd.generatorEnvironment
      )
      + "\n"
    )
  );

  # The base userland, without curl, netcat, bind's tools, archivers, a
  # second coreutils build and the like. There's no interactive shell.
  environment.corePackages = lib.mkForce (
    (map (n: lib.setPrio ((pkgs.${n}.meta.priority or lib.meta.defaultPriority) + 3) pkgs.${n}) [
      "acl"
      "attr"
      "bashInteractive"
      "coreutils"
      "findutils"
      "gawk"
      "getent"
      "gnugrep"
      "gnused"
      "ncurses"
      "util-linux"
    ])
    ++ [ pkgs.stdenv.cc.libc ]
  );
  # pam_xauth on su pulls in xauth and X11 libraries.
  security.pam.services.su.forwardXAuth = lib.mkForce false;
  # Needs util-linux's lastlog2, built without above.
  security.pam.services.login.lastlog.enable = lib.mkForce false;

  # Local tty input uses the kernel's US keyboard layout.
  console.enable = false;
  # glibc has C.UTF-8 built in.
  i18n.glibcLocales = null;
  i18n.defaultLocale = "C.UTF-8";

  boot.kexec.enable = false;
  boot.bcache.enable = false;
  services.lvm.enable = false;
  # Without LVM, nothing installs the device-mapper udev rules, so systemd
  # never sees /dev/mapper/* and the encrypted swap times out waiting for it.
  services.udev.packages = [ pkgs.lvm2.out ];
  programs.fuse.enable = false;
  services.nscd.enable = false;
  system.nssModules = lib.mkForce [ ];
  networking.resolvconf.enable = false;
  security.pki.installCACerts = false;
  services.logrotate.enable = false;
  programs.nano.enable = false;
  programs.less.lessopen = null;
  programs.bash.completion.enable = false;
  documentation.man.enable = false;
  fonts.fontconfig.enable = false;
  xdg.mime.enable = false;
  xdg.icons.enable = false;
  xdg.sounds.enable = false;
  xdg.menus.enable = false;
  xdg.autostart.enable = false;
}
