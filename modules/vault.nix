{ config, lib, pkgs, ... }:

# key-ceremony-system: the OpenPGP key-extension ceremony.
# Privileged work runs in fixed systemd services; no setuid wrappers are installed.
# Three identities enforce the local control boundary:
#  - root: vault-console owns tty1 and vault-ctl processes requests. Their helpers
#    open/mount storage and drop to signer for GnuPG operations.
#  - signer: owns the ephemeral keyring and agent, with no login.
#  - keyops: the operator SSH identity, forced to keyops-ctl. It cannot directly
#    access the keyring, agent, backup mounts or tty1. Requests go through a FIFO;
#    responses contain status or public certificates.
# Production passphrases enter through a local USB keyboard on tty1: LUKS asks
# on insertion, and pinentry asks when a signing operation needs the primary key.
# The headless workflow needs no monitor. Stock rehearsal images deliberately
# add uinput injection for disposable test passphrases over SSH.
# The control protocol never exports private key material. Extending expiry
# changes public self-signatures, so the encrypted backup remains read-only and
# only the public certificate is saved to the unencrypted partition.
let
  fpr = config.pgpVault.fingerprint;
  # Its long key id, which names the public key files on the stick.
  keyid = lib.substring 24 16 fpr;
  uidName = config.pgpVault.uidName;
  operatorSsh = config.pgpVault.sshPublicKey;
  keyopsUid = 1500;
  signerUid = 1501;

  # Root-owned and world-readable: the selected private export path (present
  # exactly while the stick is open), the loaded key's public listing, the
  # clock-set marker, the request FIFO and the answers (keyops reads them,
  # only root writes them).
  stateDir = "/run/vault";
  openFlag = "${stateDir}/generation";
  # Which public key file from the public partition was imported, if any.
  publicFlag = "${stateDir}/public";
  keyListing = "${stateDir}/key";
  clockFlag = "${stateDir}/clock-set";
  ctlFifo = "${stateDir}/ctl";
  answers = "${stateDir}/answers";
  # signer's keyring sits in a directory signer owns, inside one only root
  # can write to, so nobody but root can swap the path under root's feet.
  keyringParent = "${stateDir}/keyring";
  gnupgHome = "${keyringParent}/gnupg";
  # The stick is mounted below a root-only directory: backup files can belong
  # to arbitrary numeric users from the system where they were created.
  rootOnly = "${stateDir}/root";
  # Root's scratch for checking public keys as signer (see check_snapshot).
  checkDir = "${stateDir}/check";
  mnt = "${rootOnly}/fs";
  # The stick's other, unencrypted partition, where each renewal's public
  # key is saved; historical and current public naming conventions are read.
  pubMnt = "${rootOnly}/public";
  # keyops' own scratch, for the public key it hands over with import-public.
  inbox = "/run/keyops";

  # The agent's configuration, read-only in the store: signer can't swap the
  # pinentry. Pinentries always go to tty1 (keep-tty: whatever a client
  # says), with up to 24 hours for entry. Production input stays on that tty;
  # rehearsal-only uinput emulates its keyboard. The default cache TTL is one
  # hour, capped at two hours.
  agentConf = pkgs.writeText "gpg-agent.conf" ''
    pinentry-program ${pkgs.pinentry-curses}/bin/pinentry-curses
    ttyname /dev/tty1
    ttytype linux
    keep-tty
    keep-display
    # Allow time for local keyboard entry. 0 does not mean "no timeout": the
    # agent then just sends none, and pinentry keeps its own default, 60 s.
    pinentry-timeout 86400
    default-cache-ttl 3600
    max-cache-ttl 7200
    no-allow-loopback-pinentry
    no-allow-external-cache
    # System-side smartcard support is omitted; operator tokens stay external.
    disable-scdaemon
  '';

  # Shell helpers shared by the scripts below.

  # Prints the LUKS partitions on USB sticks, one per line.
  findLuks = ''
    find_luks() {
      lsblk -rpno PATH,FSTYPE | while read -r path fstype; do
        [ "$fstype" = crypto_LUKS ] || continue
        if udevadm info -q property -n "$path" | grep -qx ID_BUS=usb; then
          echo "$path"
        fi
      done
    }
  '';

  # check_public FILE SCRATCH_GNUPGHOME: FILE is exactly one certificate, ours,
  # with nothing secret in it.
  checkPublic = ''
    check_public() {
      local listing
      listing="$(gpg --no-options --homedir "$2" --with-colons --show-keys "$1" 2>/dev/null)" || return 1
      public_listing_matches "$listing" ${fpr}
    }
  '';

  # Root only: run a command as signer or keyops, with no capabilities, no
  # way to gain any, and a clean environment.
  dropTo = ''
    drop_to() {
      local user="$1" group="$2"
      shift 2
      setpriv --reuid="$user" --regid="$group" --init-groups \
        --inh-caps=-all --bounding-set=-all --no-new-privs --reset-env -- \
        ${pkgs.coreutils}/bin/env PATH="$PATH" "$@"
    }
    # A UTF-8 locale: --reset-env drops LANG, and in the C locale pinentry
    # can't show a UID like "López" in its prompt ("A locale function
    # failed"). glibc has C.UTF-8 built in.
    as_signer() { drop_to signer signer GNUPGHOME=${gnupgHome} GPG_TTY=/dev/tty1 TERM=linux LC_ALL=C.UTF-8 "$@"; }
    # gpg as signer, talking only to the agent load started with agentConf:
    # if it's gone, fail rather than autostart one without that config.
    sgpg() { as_signer gpg --no-options --no-autostart "$@"; }
    as_keyops() { drop_to keyops users "$@"; }
  '';

  # Whether a process with this name is running (pgrep without procps).
  running = ''
    running() {
      local comm name
      # read, not cat: a fork per process made status take seconds.
      for comm in /proc/[0-9]*/comm; do
        read -r name < "$comm" 2>/dev/null || continue
        [ "$name" = "$1" ] && return 0
      done
      return 1
    }
  '';

  # Seconds of CPU the running cryptsetup has used: typing takes none,
  # Argon2 (potentially over an hour with SD-backed swap) does. Its cost doesn't depend on the
  # passphrase, so this leaks nothing.
  cryptsetupCpu = ''
    cryptsetup_cpu() {
      local stat st cpu=0
      for stat in /proc/[0-9]*/stat; do
        read -r -a st < "$stat" 2>/dev/null || continue
        [ "''${st[1]}" = "(cryptsetup)" ] || continue
        cpu=$(( (st[13] + st[14]) / 100 )) # clock ticks: USER_HZ is 100
      done
      echo "$cpu"
    }
  '';

  # An optional activity LED signals whose turn it is in a headless ceremony:
  # steady when something is expected of them (plug or unplug the stick,
  # type a passphrase), blinking fast while the system works, and the kernel's
  # heartbeat when nothing is. (Root only: /sys/class/leds.)
  led = if config.pgpVault.activityLed == null then ''
    led() { :; }
  '' else ''
    led() {
      local d=/sys/class/leds/${config.pgpVault.activityLed}
      [ -d "$d" ] || return 0
      {
        case "$1" in
          wait) echo default-on > "$d/trigger" ;;
          busy)
            echo timer > "$d/trigger"
            echo 100 > "$d/delay_on"
            echo 100 > "$d/delay_off"
            ;;
          *) echo heartbeat > "$d/trigger" ;;
        esac
      } 2>/dev/null || true
    }
  '';

  # Every root operation, one per verb. Run by vault-console and vault-ctl
  # (both root services); keyops can't run it.
  vaultOp = pkgs.writeShellApplication {
    name = "vault-op";
    runtimeInputs = (with pkgs; [ cryptsetup util-linux systemd ]) ++ (import ./backup-tools.nix pkgs);
    text = ''
      ${builtins.readFile ./backup-layout.sh}
      ${findLuks}
      ${checkPublic}
      ${dropTo}
      ${cryptsetupCpu}
      ${led}
      umask 077

      # The exact UID string whose hash (from the listing) is $1, and whether
      # it's revoked; colon listings escape some bytes as \xNN.
      uid_by_hash() {
        sgpg --with-colons --list-keys ${fpr} \
          | awk -F: -v h="$1" '$1 == "uid" && $8 == h { print $2 "\t" $10; exit }'
      }
      need_open() { [ -f ${openFlag} ] || { echo "The stick isn't open." >&2; exit 1; }; }
      need_loaded() {
        need_open
        [ -f ${keyListing} ] || { echo "The key is not loaded and validated yet." >&2; exit 1; }
      }
      # The stick's unencrypted partition (the one ext2-4 partition on the
      # same disk as the LUKS one), if it has one.
      pub_partition() {
        local luks disk parts
        mapfile -t luks < <(find_luks)
        [ "''${#luks[@]}" = 1 ] || return 1
        # The partition's parent in sysfs is its disk.
        disk="/dev/$(basename "$(readlink -f "/sys/class/block/$(basename "''${luks[0]}")/..")")"
        [ -b "$disk" ] || return 1
        # Partitions only: the open LUKS mapping (ext2 too) hangs off the disk.
        mapfile -t parts < <(lsblk -rpno PATH,FSTYPE,TYPE "$disk" | awk '$3 == "part" && $2 ~ /^ext[234]$/ { print $1 }')
        [ "''${#parts[@]}" = 1 ] || return 1
        echo "''${parts[0]}"
      }
      # The loaded key's public listing, for keyops-ctl status.
      publish_listing() {
        {
          sgpg --list-options show-unusable-uids,show-unusable-subkeys \
            --list-secret-keys --keyid-format long ${fpr}
          # What revoke-uid and primary-uid take: each UID's hash.
          echo "UID hashes:"
          sgpg --with-colons --list-keys ${fpr} \
            | awk -F: '$1 == "uid" { printf "  %s %s %s\n", $8, ($2 == "r" ? "revoked" : "valid  "), $10 }'
        } > ${keyListing}.new
        chmod 0644 ${keyListing}.new
        mv ${keyListing}.new ${keyListing}
      }
      # A root-owned scratch directory signer can read but not change, with a
      # private gpg home for signer inside; keyops can't reach any of it.
      new_work() {
        install -d -m 0711 ${checkDir}
        work="$(mktemp -d -p ${checkDir})"
        chmod 0711 "$work"
        install -d -m 0700 -o signer -g signer "$work/gnupg"
        trap 'rm -rf "$work"' EXIT
      }
      # check_public, as signer (it parses key material), on the very file
      # that is then imported or saved: root-owned, readable by signer only.
      check_snapshot() {
        chown root:signer "$1"
        chmod 0640 "$1"
        as_signer bash -c "$(declare -f primary_listing_matches public_listing_matches check_public); check_public \"\$1\" \"\$2\"" _ "$1" "$work/gnupg"
      }
      # Everything back to before the stick went in. Idempotent.
      cleanup() {
        as_signer gpgconf --kill gpg-agent 2>/dev/null || true
        rm -rf ${keyringParent}
        sync
        if mountpoint -q ${pubMnt}; then umount ${pubMnt}; fi
        if mountpoint -q ${mnt}; then umount ${mnt}; fi
        if [ -e /dev/mapper/vault ]; then cryptsetup close vault; fi
        rm -f ${openFlag} ${publicFlag} ${keyListing}
        if [ -e /dev/tty1 ]; then chown root:tty /dev/tty1; fi
      }

      case "''${1:-}" in
        # Unlocks the stick (cryptsetup asks on stdin, which is tty1), mounts
        # it read-only and selects a supported private export to load.
        open)
          mountpoint -q ${mnt} && { echo "The stick is already open." >&2; exit 1; }
          mapfile -t luks < <(find_luks)
          if [ "''${#luks[@]}" -ne 1 ]; then
            echo "Expected one LUKS partition on USB, found ''${#luks[@]}." >&2
            exit 1
          fi
          # Local entry has no LUKS timeout and allows five attempts. Its messages
          # (never the passphrase) also go to the journal: there's no monitor.
          # Steady while the passphrase is awaited, fast once argon2 runs.
          led wait
          (
            while sleep 2; do
              if [ "$(cryptsetup_cpu)" -ge 3 ]; then led busy; else led wait; fi
            done
          ) &
          watcher=$!
          rc=0
          cryptsetup open --readonly --type luks --timeout 0 --tries 5 "''${luks[0]}" vault \
            2> >(tee /dev/stderr | systemd-cat -t vault-open) || rc=$?
          kill "$watcher" 2>/dev/null || true
          led busy
          [ "$rc" = 0 ] || exit "$rc"
          install -d -m 0700 ${rootOnly}
          mkdir -p ${mnt}
          # Read-only: nothing on the encrypted partition is ever written.
          mount -o ro,nosuid,nodev,noexec /dev/mapper/vault ${mnt} || { cryptsetup close vault; exit 1; }

          # Historical and current drduh exports, without following symlinks.
          if ! key="$(select_backup_file private ${mnt} ${fpr})"; then
            echo "No unambiguous supported private-key export on the stick." >&2
            cleanup
            exit 1
          fi
          printf '%s\n' "$key" > ${openFlag}
          chmod 0644 ${openFlag}
          echo "Using $key"
          ;;

        # Imports the selected export into a fresh keyring for signer and
        # starts signer's agent (in the caller's cgroup: vault-console's).
        load)
          need_open
          key="$(cat ${openFlag})"
          gen="''${key%/*}"
          rm -rf ${keyringParent}
          install -d -m 0711 ${keyringParent}
          install -d -m 0700 -o signer -g signer ${gnupgHome}
          # pinentry runs as signer and draws on tty1 (back to root on cleanup).
          chown signer /dev/tty1
          as_signer gpg-agent --daemon --options ${agentConf} >/dev/null
          # Import only a bounded frozen copy, as signer, and verify the
          # entire keyring's identity before permitting any signing operation.
          new_work
          snapshot_backup_file "${mnt}/$key" "$work/private.key" \
            || { echo "Can't snapshot the selected private export." >&2; exit 1; }
          sgpg --batch --import < "$work/private.key"
          listing="$(sgpg --with-colons --list-keys)"
          primary_listing_matches "$listing" ${fpr} \
            || { echo "Private export must contain exactly the key ${fpr}." >&2; exit 1; }

          # Public snapshots alongside the private export are optional, but
          # subject to the same public-only identity check as the other partition.
          rc=0
          adjacent="$(select_backup_file public "${mnt}/$gen" ${fpr})" || rc=$?
          [ "$rc" -ne 2 ] || exit 1
          if [ "$rc" = 0 ]; then
            if ! snapshot_backup_file "${mnt}/$gen/$adjacent" "$work/in.asc" \
                || ! check_snapshot "$work/in.asc"; then
              echo "Invalid adjacent public certificate: $adjacent" >&2
              exit 1
            fi
            sgpg --batch --import < "$work/in.asc"
          fi
          if ! sgpg --with-colons --list-secret-keys ${fpr} 2>/dev/null \
              | awk -F: '$1 == "sec" && $15 != "#" { ok = 1 } END { exit !ok }'; then
            echo "The stick has no secret key ${fpr}." >&2
            exit 1
          fi
          # Recover later UIDs, revocations and expiry dates from the newest
          # public-partition snapshot, comparing dates across naming conventions.
          if pub="$(pub_partition)"; then
            mkdir -p ${pubMnt}
            mount -o ro,nosuid,nodev,noexec "$pub" ${pubMnt}
            rc=0
            latest="$(select_backup_file public ${pubMnt} ${fpr})" || rc=$?
            if [ "$rc" = 2 ]; then umount ${pubMnt}; exit 1; fi
            if [ "$rc" = 0 ]; then
              snapshot_backup_file "${pubMnt}/$latest" "$work/in.asc" \
                || { umount ${pubMnt}; echo "Can't snapshot $latest" >&2; exit 1; }
            fi
            umount ${pubMnt}
            if [ "$rc" = 1 ]; then
              echo "No earlier public key on the public partition."
            elif check_snapshot "$work/in.asc"; then
              sgpg --batch --import < "$work/in.asc"
              printf '%s\n' "$latest" > ${publicFlag}
              chmod 0644 ${publicFlag}
              echo "Also imported $latest"
            else
              echo "$latest is not just the public key ${fpr}." >&2
              exit 1
            fi
          else
            echo "No public partition on the stick."
          fi
          publish_listing
          ;;

        # The current public key from the operator computer (UIDs or signatures made since
        # the generation on the stick), dropped by keyops in its inbox; read
        # with keyops' rights, checked, then imported. Public data only.
        import-public)
          need_loaded
          [[ "''${2:-}" =~ ^import\.[A-Za-z0-9]{8}\.asc$ ]] || { echo "bad import file name" >&2; exit 2; }
          new_work
          # Read with keyops' rights; regular files only, and bounded in time
          # (a FIFO planted there would otherwise block this forever).
          # shellcheck disable=SC2016 # $1 belongs to the keyops shell
          timeout 30 setpriv --reuid=keyops --regid=users --init-groups \
            --inh-caps=-all --bounding-set=-all --no-new-privs --reset-env -- \
            ${pkgs.bash}/bin/bash -c '[ -f "$1" ] && [ ! -L "$1" ] && exec ${pkgs.coreutils}/bin/head -c 1048576 < "$1"' \
            _ "${inbox}/$2" > "$work/in.asc" || { echo "Can't read ${inbox}/$2" >&2; exit 1; }
          check_snapshot "$work/in.asc" || { echo "Not the public key ${fpr}." >&2; exit 1; }
          sgpg --batch --import < "$work/in.asc"
          publish_listing
          cat ${keyListing}
          ;;

        # The passphrase is asked for on tty1 by signer's agent.
        # A new UID, "${uidName} <EMAIL>". Signed with the master key:
        # pinentry asks on tty1 (unless the agent still has the passphrase).
        add-uid)
          need_loaded
          [ -f ${clockFlag} ] || { echo "Clock not set: run set-clock first." >&2; exit 1; }
          email="''${2:-}"
          [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo "usage: add-uid EMAIL" >&2; exit 2; }
          led wait
          sgpg --batch --quick-add-uid ${fpr} ${lib.escapeShellArg uidName}" <$email>"
          led idle
          publish_listing
          cat ${keyListing}
          ;;

        # Revokes a UID ("no longer valid"), or makes one the primary: by the
        # hash shown in the listing, so no UID text has to cross SSH.
        revoke-uid | primary-uid)
          need_loaded
          [ -f ${clockFlag} ] || { echo "Clock not set: run set-clock first." >&2; exit 1; }
          [[ "''${2:-}" =~ ^[0-9A-F]{40}$ ]] || { echo "usage: $1 UID-HASH" >&2; exit 2; }
          found="$(uid_by_hash "$2")"
          [ -n "$found" ] || { echo "No UID with hash $2" >&2; exit 1; }
          [ "''${found%%$'\t'*}" != r ] || { echo "That UID is already revoked." >&2; exit 1; }
          uid="$(printf '%b' "''${found#*$'\t'}")"
          led wait
          if [ "$1" = revoke-uid ]; then
            sgpg --batch --quick-revoke-uid ${fpr} "$uid"
          else
            sgpg --batch --quick-set-primary-uid ${fpr} "$uid"
          fi
          led idle
          publish_listing
          cat ${keyListing}
          ;;

        extend)
          need_loaded
          [ -f ${clockFlag} ] || { echo "Clock not set: run set-clock first." >&2; exit 1; }
          until="''${2:-}"
          [[ "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: extend YYYY-MM-DD" >&2; exit 2; }
          [ "$(date -u -d "$until" +%s)" -gt "$(date +%s)" ] || { echo "$until is in the past" >&2; exit 2; }
          led wait
          sgpg --batch --quick-set-expire ${fpr} "$until"
          # '*' would skip subkeys that have already expired; name every
          # subkey that isn't revoked.
          mapfile -t subs < <(sgpg --with-colons --list-keys ${fpr} \
            | awk -F: '$1 == "sub" { want = ($2 != "r") } $1 == "fpr" && want { print $10; want = 0 }')
          [ "''${#subs[@]}" -gt 0 ] || { echo "No subkeys to extend" >&2; exit 1; }
          sgpg --batch --quick-set-expire ${fpr} "$until" "''${subs[@]}"
          led idle
          publish_listing
          cat ${keyListing}
          ;;

        export-public)
          need_loaded
          sgpg --armor --export ${fpr}
          ;;

        # Saves the extended public key on the stick's unencrypted partition,
        # next to the earlier ones and named like them; never over an existing
        # file. The encrypted partition is never written: extending changes
        # nothing secret.
        backup)
          need_loaded
          new_work
          sgpg --armor --export ${fpr} > "$work/public.asc"
          check_snapshot "$work/public.asc" \
            || { echo "The keyring's export is not the public key ${fpr}" >&2; exit 1; }
          pub="$(pub_partition)" || { echo "The stick has no public partition." >&2; exit 1; }
          name="gpg-0x${keyid}-$(date -u +%F).asc"
          mkdir -p ${pubMnt}
          mount -o nosuid,nodev,noexec "$pub" ${pubMnt}
          if [ -e "${pubMnt}/$name" ]; then
            umount ${pubMnt}
            echo "$name already exists on the public partition: left as is." >&2
            exit 1
          fi
          cp "$work/public.asc" "${pubMnt}/.$name.partial"
          # Public, like the files of earlier renewals next to it.
          chmod 0644 "${pubMnt}/.$name.partial"
          sync
          mv -T "${pubMnt}/.$name.partial" "${pubMnt}/$name"
          sync
          echo "Saved on the public partition:"
          ls -l "${pubMnt}/$name"
          umount ${pubMnt}
          ;;

        cleanup)
          cleanup
          ;;

        # Stops vault-console (and with it any pending unlock, the import and
        # signer's agent, all in its cgroup), cleans up, and starts it again;
        # it then waits for the stick to come out before anything else.
        close)
          systemctl stop vault-console
          cleanup
          systemctl start vault-console
          echo "Closed; the stick can come out."
          ;;

        # Clock setup is explicit. The tested Pi boards have no configured RTC;
        # the operator supplies a trusted timestamp over SSH before signing.
        set-clock)
          [[ "''${2:-}" =~ ^[0-9]{10}$ ]] || { echo "usage: set-clock EPOCH" >&2; exit 2; }
          date -u -s "@$2"
          touch ${clockFlag}
          ;;

        poweroff)
          if [ -f ${openFlag} ]; then echo "Run close first." >&2; exit 1; fi
          systemctl poweroff
          ;;

        *)
          echo "unknown operation" >&2
          exit 2
          ;;
      esac
    '';
  };
  op = lib.getExe vaultOp;

  # tty1, as root. Waits for the stick, has it unlocked and loaded, then waits
  # for close (which restarts this service). Any failure exits; the trap
  # cleans up and systemd starts it over.
  vaultConsole = pkgs.writeShellApplication {
    name = "vault-console";
    runtimeInputs = with pkgs; [ coreutils util-linux systemd gnugrep ];
    text = ''
      ${findLuks}
      trap "" INT QUIT TSTP
      # What tty1 shows also goes to the journal (RAM only): there's no
      # monitor, and its messages never carry secrets (cryptsetup and
      # pinentry read passphrases from the tty itself).
      exec > >(tee >(systemd-cat -t vault-console)) 2>&1

      ${led}
      present() { [ -n "$(find_luks)" ]; }
      cleanup() { ${op} cleanup >/dev/null 2>&1 || true; }
      trap cleanup EXIT
      unplug() {
        echo "$1 Unplug the USB stick."
        led wait
        while present; do sleep 2; done
      }

      # Nothing is ever asked for unless the human has just plugged the stick
      # in: after a (re)start, one that's still in has to come out first.
      cleanup
      if present; then unplug "pgp-vault restarted."; fi

      # A stick that's still settling (a loose plug drops and re-enumerates
      # it) must not get a cryptsetup holding a node that's about to vanish:
      # the next enumeration then lands on another name and the unlock fails.
      # Go on only once the same single LUKS partition has stayed for 5 s.
      settled() {
        local first
        udevadm settle --timeout=10 || true
        first="$(find_luks)"
        [ -n "$first" ] && [ "$(wc -l <<<"$first")" = 1 ] || return 1
        sleep 5
        udevadm settle --timeout=10 || true
        [ "$(find_luks)" = "$first" ]
      }

      while true; do
        # gpg rejects a key whose self-signatures look like they're from the
        # future, and new signatures need the real date: no clock, no unlock.
        if [ ! -f ${clockFlag} ]; then
          echo "pgp-vault: waiting for the clock (set-clock over SSH)"
          led idle
          until [ -f ${clockFlag} ]; do sleep 2; done
        fi
        echo "pgp-vault: waiting for the USB stick"
        led wait
        until present && settled; do sleep 2; done
        if ! ${op} open; then
          cleanup
          unplug "Could not open the stick."
          continue
        fi
        if ! ${op} load; then
          cleanup
          unplug "Could not load the key."
          continue
        fi
        echo "pgp-vault: key loaded. Passphrases are asked for here."
        led idle
        while [ -f ${openFlag} ]; do sleep 2; done
        unplug "pgp-vault: closed."
      done
    '';
  };

  # Root, fed by the FIFO keyops writes to: one request per line,
  # "NONCE VERB [ARG]". The answer (output, then exit code) lands in
  # answers/NONCE.out and answers/NONCE.rc. Only these verbs exist; vault-op
  # validates the argument.
  # Runs one request and writes its answer.
  vaultRun = pkgs.writeShellApplication {
    name = "vault-run";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      umask 027
      nonce="$1"
      rc=0
      ${op} "$2" "$3" > "${answers}/$nonce.out" 2>&1 < /dev/null || rc=$?
      echo "$rc" > "${answers}/.$nonce.rc"
      mv "${answers}/.$nonce.rc" "${answers}/$nonce.rc"
    '';
  };
  # The loop stays responsive: each request runs as its own worker (in its
  # own process group), one at a time. While one runs, close kills it (an
  # extend blocked on the passphrase, a stuck read) and then closes; anything
  # else is answered "busy".
  vaultCtl = pkgs.writeShellApplication {
    name = "vault-ctl";
    runtimeInputs = with pkgs; [ coreutils findutils util-linux ];
    text = ''
      umask 027
      answer() {
        echo "$3" > "${answers}/$1.out"
        echo "$2" > "${answers}/.$1.rc"
        mv "${answers}/.$1.rc" "${answers}/$1.rc"
      }
      worker=""
      worker_nonce=""
      while read -r nonce verb arg; do
        [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || continue
        ${lib.optionalString typer ''
          # Right away, even while extend waits on pinentry for exactly this.
          if [ "$verb" = type ]; then
            out="$(${vaultType}/bin/vault-type "''${arg:-}" 2>&1)" && rc=0 || rc=$?
            answer "$nonce" "$rc" "''${out:-typed}"
            continue
          fi
        ''}
        case "$verb" in
          set-clock | import-public | add-uid | revoke-uid | primary-uid | extend | export-public | backup | close | poweroff) ;;
          *) continue ;;
        esac
        find ${answers} -mindepth 1 -mmin +90 -delete || true
        if [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null; then
          if [ "$verb" != close ]; then
            answer "$nonce" 1 "Busy: another operation is running."
            continue
          fi
          kill -TERM -- "-$worker" 2>/dev/null || true
          wait "$worker" 2>/dev/null || true
          answer "$worker_nonce" 1 "Cancelled by close."
        fi
        # setsid (not a group leader here) execs in place: $! is the new
        # process group's id.
        setsid ${lib.getExe vaultRun} "$nonce" "$verb" "''${arg:-}" &
        worker=$!
        worker_nonce="$nonce"
      done
    '';
  };

  # Only the disposable rehearsal module supplies a virtual keyboard helper.
  vaultType = config.pgpVault.rehearsalTyper;
  typer = vaultType != null;

  # SSH side: the configured authentication key runs only this, as keyops.
  keyopsCtl = pkgs.writeShellApplication {
    name = "keyops-ctl";
    runtimeInputs = with pkgs; [ coreutils util-linux systemd gnugrep gawk ];
    text = ''
      ${findLuks}
      ${running}
      ${cryptsetupCpu}
      read -r -a argv <<< "''${SSH_ORIGINAL_COMMAND:-}"
      verb="''${argv[0]:-help}"

      # Asks vault-ctl (root) for VERB [ARG], waits up to SECONDS for the
      # answer and relays it.
      root() {
        local seconds="$1" nonce
        shift
        nonce="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
        printf '%s %s %s\n' "$nonce" "$1" "''${2:-}" > ${ctlFifo}
        for _ in $(seq $((seconds * 5))); do
          [ -f ${answers}/"$nonce".rc ] && break
          sleep 0.2
        done
        [ -f ${answers}/"$nonce".rc ] || { echo "No answer from vault-ctl." >&2; exit 1; }
        cat ${answers}/"$nonce".out
        exit "$(cat ${answers}/"$nonce".rc)"
      }

      # One verb at a time, except looking and closing (close must be able to
      # cancel whatever is running).
      if [ "$verb" != status ] && [ "$verb" != close ] && [ "$verb" != type ]; then
        exec 9>${inbox}/ctl.lock
        flock -n 9 || { echo "Another keyops-ctl is running." >&2; exit 1; }
      fi

      case "$verb" in
        status)
          if [ -f ${clockFlag} ]; then
            echo "Clock:      $(date -u '+%F %T UTC')"
          else
            echo "Clock:      NOT SET ($(date -u '+%F %T UTC'))"
          fi
          echo "Console:    $(systemctl is-active vault-console || true)"
          # What tty1 is waiting for, so the human knows when to type.
          if running cryptsetup; then
            cpu="$(cryptsetup_cpu)"
            if [ "$cpu" -lt 3 ]; then
              echo "tty1:       WAITING for the USB stick passphrase"
            else
              echo "tty1:       unlocking the USB stick (argon2, ''${cpu}s of CPU so far)"
            fi
          elif running pinentry-curses; then
            echo "tty1:       WAITING for the master key passphrase"
          elif [ -f ${openFlag} ]; then
            if [ -f ${keyListing} ]; then
              echo "tty1:       idle, stick open"
            else
              echo "tty1:       loading and validating the key"
            fi
          elif [ ! -f ${clockFlag} ]; then
            echo "tty1:       waiting for the clock: set-clock first"
          elif [ -n "$(find_luks)" ]; then
            echo "tty1:       stick plugged in, not open"
          else
            echo "tty1:       waiting for the USB stick"
          fi
          if [ -f ${openFlag} ]; then
            echo "Loaded:     $(cat ${openFlag})"
            if [ -f ${publicFlag} ]; then echo "            + $(cat ${publicFlag})"; fi
          fi
          # SwapCached: pages back in RAM whose swap copy is kept, counted in
          # both; the rest of the swap used is what's only on the card.
          awk '/^(MemAvailable|SwapTotal|SwapFree|SwapCached):/ { m[$1] = int($2 / 1024) }
            END { printf "Memory:     %d MB available, swap %d of %d MB used (%d of them also in RAM)\n",
              m["MemAvailable:"], m["SwapTotal:"] - m["SwapFree:"], m["SwapTotal:"], m["SwapCached:"] }' /proc/meminfo
          # What each slice holds in RAM (and in swap), to size MemoryLow.
          for slice in system user vault; do
            cg=/sys/fs/cgroup/$slice.slice
            [ -r $cg/memory.current ] || continue
            printf '            %s.slice: %d MB in RAM, %d MB swapped\n' $slice \
              $(( $(cat $cg/memory.current) / 1048576 )) $(( $(cat $cg/memory.swap.current) / 1048576 ))
          done
          if [ -f ${keyListing} ]; then cat ${keyListing}; else echo "Keyring:    not loaded"; fi
          ;;
        set-clock)
          [[ "''${argv[1]:-}" =~ ^[0-9]{10}$ ]] || { echo "usage: set-clock EPOCH" >&2; exit 2; }
          root 60 set-clock "''${argv[1]}"
          ;;
        import-public)
          f="$(mktemp -p ${inbox} --suffix=.asc import.XXXXXXXX)"
          trap 'rm -f "$f"' EXIT
          head -c 1048576 > "$f"
          chmod 0600 "$f"
          root 300 import-public "$(basename "$f")"
          ;;
        add-uid)
          [[ "''${argv[1]:-}" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo "usage: add-uid EMAIL" >&2; exit 2; }
          echo "Passphrase on tty1 (if the agent doesn't have it)..." >&2
          root 3600 add-uid "''${argv[1]}"
          ;;
        revoke-uid | primary-uid)
          [[ "''${argv[1]:-}" =~ ^[0-9A-F]{40}$ ]] || { echo "usage: $verb UID-HASH (from status)" >&2; exit 2; }
          echo "Passphrase on tty1 (if the agent doesn't have it)..." >&2
          root 3600 "$verb" "''${argv[1]}"
          ;;
        extend)
          [[ "''${argv[1]:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: extend YYYY-MM-DD" >&2; exit 2; }
          echo "Passphrase on tty1..." >&2
          # Allow time for local keyboard entry or rehearsal-only injection.
          root 3600 extend "''${argv[1]}"
          ;;
        backup | export-public | close | poweroff)
          root 300 "$verb"
          ;;
        ${lib.optionalString typer ''
          type)
            [[ "''${argv[1]:-}" =~ ^[a-z0-9-]{1,64}$ ]] || { echo "usage: type TEXT ([a-z0-9-])" >&2; exit 2; }
            root 30 type "''${argv[1]}"
            ;;
        ''}
        *)
          echo "verbs: status | set-clock EPOCH | import-public < key.asc | add-uid EMAIL | revoke-uid UID-HASH | primary-uid UID-HASH | extend YYYY-MM-DD | backup | export-public | close | poweroff" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.pgpVault.activityLed = lib.mkOption {
    type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9_:.-]+");
    default = null;
    description = "LED name under /sys/class/leds for ceremony status; null disables LED signalling.";
  };

  options.pgpVault.fingerprint = lib.mkOption {
    type = lib.types.strMatching "[0-9A-F]{40}";
    description = "The only key this machine will load, extend and back up.";
  };

  options.pgpVault.uidName = lib.mkOption {
    type = lib.types.strMatching "[^<>:\n\r]+";
    description = "The name add-uid puts before the email.";
  };

  options.pgpVault.sshPublicKey = lib.mkOption {
    type = lib.types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( [^\n\r]*)?";
    description = "Operator SSH public key, restricted to keyops-ctl.";
  };

  options.pgpVault.rehearsalTyper = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    internal = true;
    description = "Disposable-test keyboard helper enabling the rehearsal-only type verb; absent in production.";
  };

  config = {
    environment.systemPackages = [ pkgs.gnupg pkgs.cryptsetup ];

    # No setuid or setgid binaries at all: no sudo, su, mount wrappers.
    security.enableWrappers = false;
    security.sudo.enable = false;

    users.users.keyops.uid = keyopsUid;
    users.users.signer = {
      isSystemUser = true;
      uid = signerUid;
      group = "signer";
      home = "/var/empty";
      # /run/user/<uid> exists from boot: the agent's socket lives there.
      linger = true;
    };
    users.groups.signer = { };

    systemd.tmpfiles.rules = [
      # pam_unix runs this helper for sshd's account check, at the path the
      # (now absent) setuid wrapper had. sshd calls it as root, so the plain,
      # non-setuid binary is enough.
      "d /run/wrappers/bin 0755 root root -"
      "L+ /run/wrappers/bin/unix_chkpwd - - - - ${pkgs.linux-pam}/bin/unix_chkpwd"
      "d ${inbox} 0700 keyops users -"
      "d ${stateDir} 0755 root root -"
      "d ${answers} 0750 root users -"
    ];

    # tty1 belongs to vault-console. No getty anywhere: no VT login prompts at
    # all, not on tty1 and not on Alt+F2..F6.
    systemd.services.vault-console = {
      description = "Key ceremony console on tty1";
      wantedBy = [ "multi-user.target" ];
      wants = [ "user-runtime-dir@${toString signerUid}.service" ];
      after = [ "user-runtime-dir@${toString signerUid}.service" "systemd-user-sessions.service" ];
      conflicts = [ "getty@tty1.service" "autovt@tty1.service" ];
      serviceConfig = {
        ExecStart = lib.getExe vaultConsole;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        Restart = "always";
        RestartSec = 2;
        # Unlocking (argon2, 1 GiB) is the one big memory user, and runs in
        # here: the only unprotected slice (below). Its CPU share goes last.
        Slice = "vault.slice";
        CPUWeight = 20;
      };
    };
    # Under argon2's memory pressure the kernel reclaims from vault.slice
    # first, and leaves system.slice (sshd, logind, dbus, journald, vault-ctl)
    # and user.slice (keyops' SSH sessions) the RAM they're using, up to these
    # amounts: a ceiling on protection, not a reservation (what they don't
    # use stays argon2's). Unlocking is slower still, but SSH keeps
    # answering. systemd mounts cgroup2 with memory_recursiveprot, so every
    # unit inside shares its slice's protection.
    systemd.slices.vault.description = "Key ceremony console";
    systemd.slices.system.sliceConfig.MemoryLow = "128M";
    systemd.slices.user.sliceConfig.MemoryLow = "64M";
    systemd.targets.getty.wants = lib.mkForce [ ];
    services.logind.settings.Login = {
      NAutoVTs = 0;
      ReserveVT = 0;
    };

    # keyops-ctl -> root. systemd creates the FIFO owned by keyops, mode 0600,
    # and keeps it open, so vault-ctl is started once and reads requests as
    # they come.
    systemd.sockets.vault-ctl = {
      description = "Requests from keyops-ctl to vault-ctl";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenFIFO = ctlFifo;
        SocketUser = "keyops";
        SocketMode = "0600";
        DirectoryMode = "0755";
      };
    };
    systemd.services.vault-ctl = {
      description = "Root side of keyops-ctl";
      serviceConfig = {
        ExecStart = lib.getExe vaultCtl;
        StandardInput = "socket";
        StandardOutput = "journal";
        Group = "users";
        Restart = "always";
      };
    };

    users.users.keyops.openssh.authorizedKeys.keys = [
      "restrict,command=\"${lib.getExe keyopsCtl}\" ${operatorSsh}"
    ];
  };
}
