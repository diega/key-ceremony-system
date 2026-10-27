# Imports a key-ceremony-system public export into the Mac's keyring and
# sends it to the keyservers, then reads it back from each one and checks it
# has the same expiry, primary key and subkeys alike, as the exported file.
#
# From the repository root on the Mac:
# nix run --override-input vault-config path:./.local/vault-config .#publish -- pubkey.asc

: "${fpr:?Run the Nix publish app with vault-config to supply the primary fingerprint}"

if [ $# -ne 1 ] || [ ! -s "$1" ]; then
  echo "usage: publish pubkey.asc" >&2
  exit 1
fi

# Every check and parse happens in a throwaway keyring.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
scratch() { gpg --no-options --homedir "$tmp/gnupg" "$@"; }
mkdir -m 0700 "$tmp/gnupg"

# "keyid:expiry" for the primary key and each subkey of FILE, if FILE holds
# exactly one certificate, ours, with nothing secret.
expiries() {
  local listing
  listing="$(scratch --with-colons --show-keys "$1" 2>/dev/null)" || return 1
  [ "$(grep -c '^pub:' <<<"$listing")" = 1 ] || return 1
  if grep -qE '^(sec|ssb):' <<<"$listing"; then return 1; fi
  [ "$(awk -F: '$1 == "fpr" { print $10; exit }' <<<"$listing")" = "$fpr" ] || return 1
  # Keyservers don't keep the subkeys in the same order.
  awk -F: '$1 == "pub" || $1 == "sub" { print $5 ":" $7 }' <<<"$listing" | sort
}

exported="$1"
if ! expected="$(expiries "$exported")"; then
  echo "$1 is not exactly the public key $fpr" >&2
  exit 1
fi

# Import a canonical export of just that certificate, not the file as given.
scratch --batch --import "$1"
scratch --armor --export "$fpr" > "$tmp/canonical.asc"
gpg --import "$tmp/canonical.asc"

failed=0
# The MIT endpoint uses plain HTTP and is informational: upload and readback
# failures there are reported but do not fail the overall publication check.
for ks in hkps://keys.openpgp.org hkps://keyserver.ubuntu.com hkp://pgp.mit.edu; do
  echo "== $ks"
  if ! timeout 60 gpg --keyserver "$ks" --send-keys "$fpr"; then
    echo "   upload failed"
    [ "$ks" = hkp://pgp.mit.edu ] || failed=1
  fi
done

echo
echo "Read back from each keyserver:"
check() {
  local name="$1" url="$2" required="$3" got
  if ! curl -fsS -m 30 -o "$tmp/readback.asc" "$url" 2>/dev/null; then
    echo "  $name: unreachable"
  elif ! scratch --list-packets "$tmp/readback.asc" 2>/dev/null | grep -q '^:user ID packet:'; then
    # keys.openpgp.org only serves user IDs whose email has been verified.
    echo "  $name: served without user IDs (verify an email there)"
  elif ! got="$(expiries "$tmp/readback.asc")"; then
    echo "  $name: not (only) $fpr"
  elif [ "$got" != "$expected" ]; then
    echo "  $name: OLD (expiries differ from $exported)"
  else
    echo "  $name: OK"
    return 0
  fi
  [ "$required" = optional ] || failed=1
}
check keys.openpgp.org "https://keys.openpgp.org/vks/v1/by-fingerprint/$fpr" required
check keyserver.ubuntu.com "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$fpr" required
check "pgp.mit.edu (plain HTTP, informational)" "http://pgp.mit.edu/pks/lookup?op=get&options=mr&search=0x$fpr" optional

exit "$failed"
