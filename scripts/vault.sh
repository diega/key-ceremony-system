# Run one key-ceremony-system control verb over the dedicated Ethernet link.
# The configured SSH public key selects its private counterpart in the operator's
# agent (a YubiKey OpenPGP authentication subkey or another supported SSH key).
# The host key is checked against the known_hosts pin produced by flash.
#
# From the repository root on the Mac:
# nix run --override-input vault-config path:./.local/vault-config .#vault -- VERB [ARG]
# An omitted verb displays the allowed verbs.
#
# ControlMaster reuses the authenticated connection for 15 idle minutes. Requests
# still run only keyops-ctl. The socket lives in ~/.ssh because macOS temporary
# directory paths can exceed Unix-socket path limits.

: "${operator_key:?Run the Nix vault app with vault-config to supply the SSH public key}"

[ -f known_hosts ] || { echo "No ./known_hosts: run from the repo root, after flash." >&2; exit 1; }

mkdir -p "$HOME/.ssh"

exec /usr/bin/ssh -F none \
  -o UserKnownHostsFile="$PWD/known_hosts" \
  -o StrictHostKeyChecking=yes \
  -o HostKeyAlgorithms=ssh-ed25519 \
  -o PreferredAuthentications=publickey \
  -o IdentitiesOnly=yes \
  -i "$operator_key" \
  -o ForwardAgent=no \
  -o ClearAllForwardings=yes \
  -o ConnectTimeout=5 \
  -o ControlMaster=auto \
  -o ControlPath="$HOME/.ssh/pgp-vault-%C" \
  -o ControlPersist=15m \
  keyops@10.77.0.2 -- "$@"
