{ pkgs }:
{
  ceremony = import ./ceremony.nix { inherit pkgs; };

  scripts = pkgs.runCommand "pgp-vault-script-checks" {
    nativeBuildInputs = [ pkgs.bash pkgs.shellcheck pkgs.actionlint ];
  } ''
    for script in ${../scripts}/*.sh ${../modules/backup-layout.sh} ${../pgp-vault}; do
      bash -n "$script"
      shellcheck --shell=bash "$script"
    done
    actionlint -shellcheck= -pyflakes= ${../.github/workflows}/*.yml
    touch $out
  '';

  backup-layout = pkgs.runCommand "pgp-vault-backup-layout-checks" {
    nativeBuildInputs = [ pkgs.python3 ] ++ (import ../modules/backup-tools.nix pkgs);
  } ''
    export BACKUP_LAYOUT_HELPER=${../modules/backup-layout.sh}
    export BACKUP_PUBLIC_FIXTURE=${./fixtures/public.asc}
    export BACKUP_PRIVATE_FIXTURE=${./fixtures/mastersub.key}
    export PATH=${pkgs.lib.makeBinPath (import ../modules/backup-tools.nix pkgs)}
    ${pkgs.python3}/bin/python3 ${./test_backup_layout.py}
    touch $out
  '';

  flash-preflight = pkgs.runCommand "pgp-vault-flash-preflight-checks" {
    nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.coreutils ];
  } ''
    mkdir -p project/scripts project/tests
    cp ${../scripts/flash.sh} project/scripts/flash.sh
    cp ${./test_flash.py} project/tests/test_flash.py
    touch project/flake.nix
    python3 project/tests/test_flash.py
    touch $out
  '';
}
