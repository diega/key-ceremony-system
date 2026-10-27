{ pkgs }:
name: kdfMemory: layout:
  pkgs.runCommand name
    {
      nativeBuildInputs = with pkgs; [
        cryptsetup
        e2fsprogs
        util-linux
        jq
        (python3.withPackages (p: [ p.cryptography ]))
      ];
    }
    ''
      mkdir -p fs/tmp.TeStKeY1
      cp ${../fixtures/mastersub.key} fs/tmp.TeStKeY1/mastersub.key
      cp ${../fixtures/sub.key} fs/tmp.TeStKeY1/sub.key
      printf 'keyid-format 0xlong\nwith-fingerprint\n' > fs/tmp.TeStKeY1/gpg.conf
      ${pkgs.lib.optionalString (layout == "mixed") ''
        mkdir -p fs/gnupg_202402111200_TEST fs/gnupg-2024-03-16-TEST fs/2026.10.26-TEST
        cp ${../fixtures/mastersub.key} fs/gnupg_202402111200_TEST/certify.key
        cp ${../fixtures/mastersub.key} fs/gnupg-2024-03-16-TEST/0x7DE9AE9985243C38-Certify.key
        cp ${../fixtures/mastersub.key} fs/2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key
        cp ${../fixtures/sub.key} fs/2026.10.26-TEST/secret-7DE9AE9985243C38-Subkeys.key
        cp ${../fixtures/public.asc} fs/2026.10.26-TEST/public-7DE9AE9985243C38-2026-10-22.asc
        touch -d 2019-06-09 fs/tmp.TeStKeY1/mastersub.key
        touch -d 2024-02-11 fs/gnupg_202402111200_TEST/certify.key
        touch -d 2024-03-16 fs/gnupg-2024-03-16-TEST/0x7DE9AE9985243C38-Certify.key
        touch -d 2026-10-21 fs/2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key
      ''}
      mke2fs -q -t ext2 -d fs fs.img 16M
      ${pkgs.lib.optionalString (layout == "mixed") ''
        # e2fsprogs reproducible builds may normalize -d source mtimes.
        # Set and verify the actual inode timestamps after creating ext2.
        for entry in \
          'tmp.TeStKeY1/mastersub.key 2019-06-09' \
          'gnupg_202402111200_TEST/certify.key 2024-02-11' \
          'gnupg-2024-03-16-TEST/0x7DE9AE9985243C38-Certify.key 2024-03-16' \
          '2026.10.26-TEST/secret-7DE9AE9985243C38-Certify.key 2026-10-21'; do
          read -r key day <<< "$entry"
          stamp="$(date -u -d "$day" +%s)"
          debugfs -w -R "set_inode_field /$key mtime @$stamp" fs.img >/dev/null
          hex="$(printf '%08x' "$stamp")"
          debugfs -R "stat /$key" fs.img 2>/dev/null | grep -q "mtime: 0x$hex"
        done
      ''}

      head -c 64 /dev/urandom > volume.key
      truncate -s 40M luks.img
      echo -n prueba-luks-1 | cryptsetup luksFormat --batch-mode --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 --sector-size 512 \
        --pbkdf argon2i --pbkdf-memory ${toString kdfMemory} --pbkdf-parallel 4 --pbkdf-force-iterations 4 \
        --volume-key-file volume.key --key-file - luks.img
      offset=$(cryptsetup luksDump --dump-json-metadata luks.img | jq -r '.segments."0".offset')
      python3 ${../../scripts/encrypt-xts.py} volume.key fs.img luks.img "$offset"

      # And the unencrypted one with the public keys of past renewals.
      mkdir pubfs
      cp ${../fixtures/public.asc} pubfs/gpg-0x7DE9AE9985243C38-2026-10-21.asc
      ${pkgs.lib.optionalString (layout == "mixed") ''
        cp ${../fixtures/public.asc} pubfs/0x7DE9AE9985243C38-2026-10-20.txt
        cp ${../fixtures/public.asc} pubfs/public-7DE9AE9985243C38-2026-10-22.asc
        cp ${../fixtures/public.asc} pubfs/7DE9AE9985243C38-2026-10-23.asc
      ''}
      mke2fs -q -t ext2 -d pubfs pub.img 16M

      # The stick: LUKS at 1 MiB, the public partition right after.
      truncate -s 64M $out
      printf 'start=2048, size=81920, type=83\nstart=83968, type=83\n' | sfdisk -q $out
      dd if=luks.img of=$out bs=1M seek=1 conv=notrunc status=none
      dd if=pub.img of=$out bs=1M seek=41 conv=notrunc status=none
    ''
