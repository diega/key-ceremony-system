# Sourced by vault-op. GNU coreutils/findutils and Bash are supplied by Nix.
# The stick is mounted read-only; all certificate parsing runs as signer.

private_name_matches() {
  local name="${1^^}" fpr="${2^^}" id
  case "$name" in
    MASTERSUB.KEY | CERTIFY.KEY) return 0 ;;
    *-CERTIFY.KEY)
      id="${name%-CERTIFY.KEY}"
      id="${id#SECRET-}"
      id="${id#0X}"
      [[ "$id" = "$fpr" || "$id" = "${fpr: -16}" ]]
      ;;
    *) return 1 ;;
  esac
}

# Print a sortable date; undated public exports are fallback candidates.
public_name_date() {
  local name="${1^^}" fpr="${2^^}" id stamp canonical
  case "$name" in
    PUBLIC.ASC) echo 0000-00-00; return 0 ;;
    *.ASC | *.TXT) name="${name%.*}" ;;
    *) return 1 ;;
  esac
  case "$name" in GPG-* | PUBLIC-*) name="${name#*-}" ;; esac
  [[ "$name" =~ ^(0X)?([0-9A-F]{16}|[0-9A-F]{40})(-([0-9]{4}-[0-9]{2}-[0-9]{2}))?$ ]] || return 1
  id="${BASH_REMATCH[2]}"
  stamp="${BASH_REMATCH[4]:-}"
  [[ "$id" = "$fpr" || "$id" = "${fpr: -16}" ]] || return 1
  if [ -n "$stamp" ]; then
    canonical="$(date -u -d "$stamp" +%F 2>/dev/null)" || return 1
    [ "$stamp" = "$canonical" ] || return 1
    echo "$stamp"
  else
    echo 0000-00-00
  fi
}

# Print one relative filename, or return 1 for no match, 2 for an unsafe or
# ambiguous choice. Private exports live one directory below the LUKS root;
# public exports live directly in the supplied directory. Never follow links.
select_backup_file() {
  local kind="$1" root="$2" fpr="$3" depth path relative stamp size
  local selected="" best="" ambiguous=0
  case "$kind" in private) depth=2 ;; public) depth=1 ;; *) return 2 ;; esac
  while IFS= read -r -d '' path; do
    if [ "$kind" = private ]; then
      private_name_matches "${path##*/}" "$fpr" || continue
      stamp="$(TZ=UTC stat -c %y -- "$path")" || return 2
    else
      stamp="$(public_name_date "${path##*/}" "$fpr")" || continue
    fi
    relative="${path#"$root"/}"
    if [[ "$relative" = *$'\n'* || "$relative" = *$'\r'* ]]; then
      echo "Unsupported line break in backup path." >&2
      return 2
    fi
    size="$(stat -c %s -- "$path")" || return 2
    if [ "$size" -gt 1048576 ]; then
      echo "Backup candidate exceeds 1 MiB: $relative" >&2
      return 2
    fi
    if [ -z "$selected" ] || [[ "$stamp" > "$best" ]]; then
      selected="$relative"
      best="$stamp"
      ambiguous=0
    elif [ "$stamp" = "$best" ]; then
      if ! cmp -s -- "$root/$selected" "$path"; then
        ambiguous=1
      elif [[ "$relative" > "$selected" ]]; then
        # Identical aliases are harmless; select one deterministically.
        selected="$relative"
      fi
    fi
  done < <(find -P "$root" -mindepth "$depth" -maxdepth "$depth" -type f -print0)
  if [ "$ambiguous" = 1 ]; then
    echo "Ambiguous $kind backups at $best: newest candidates have different contents." >&2
    return 2
  fi
  [ -n "$selected" ] || return 1
  printf '%s\n' "$selected"
}

# A frozen, bounded copy is the only input later parsed/imported by GnuPG.
snapshot_backup_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  head -c 1048577 -- "$1" > "$2" || return 1
  [ "$(wc -c < "$2")" -le 1048576 ]
}

# Validate a GnuPG colon listing of public primary keys, never by filename.
primary_listing_matches() {
  local listing="$1" fpr="$2"
  [ "$(grep -c '^pub:' <<<"$listing")" = 1 ] || return 1
  [ "$(awk -F: '$1 == "fpr" { print $10; exit }' <<<"$listing")" = "$fpr" ]
}

public_listing_matches() {
  if grep -qE '^(sec|ssb):' <<<"$1"; then return 1; fi
  primary_listing_matches "$1" "$2"
}
