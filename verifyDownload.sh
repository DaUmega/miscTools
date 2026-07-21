#!/usr/bin/env bash
#
# verify.sh — verify a downloaded file against a checksum or a PGP/GPG signature.
#
# USAGE
#   verify.sh <file> <hash-string>                   e.g. sha256 hex string
#   verify.sh <file> <checksum-file>                  sha256sum/shasum/BSD-style list
#   verify.sh <file> <signature-file>                 .asc/.sig/.gpg/.pgp
#   verify.sh <file> <signature-file> -k <pubkey>     import key first
#   verify.sh <file> <hash-string> -a <algo>          force algorithm
#
# EXAMPLES
#   verify.sh app.tar.gz e3b0c44...b855               auto-detects sha256 by length
#   verify.sh app.tar.gz SHA256SUMS.txt
#   verify.sh app.tar.gz app.tar.gz.asc -k KEYS.asc
#
# EXIT CODES
#   0 verified   1 mismatch/bad signature   2 usage error   3 missing tool

set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; NC=$'\033[0m'
ok()   { printf '%s✔ %s%s\n' "$GREEN" "$1" "$NC"; }
fail() { printf '%s✘ %s%s\n' "$RED"   "$1" "$NC"; exit 1; }
warn() { printf '%s! %s%s\n'  "$YELLOW" "$1" "$NC"; }

usage() { sed -n '2,20p' "$0"; exit 2; }

[ $# -lt 2 ] && usage

FILE="$1"; CHECK="$2"; shift 2
KEYFILE=""; ALGO_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -k|--key)  KEYFILE="$2"; shift 2 ;;
    -a|--algo) ALGO_OVERRIDE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 2; }

# ---- compute a hash using whatever tool is available, openssl as universal fallback
compute_hash() {
  local algo="$1" f="$2"
  case "$algo" in
    md5)    command -v md5sum   >/dev/null && { md5sum "$f"   | awk '{print $1}'; return; }
            command -v md5      >/dev/null && { md5 -q "$f"; return; } ;;
    sha1)   command -v sha1sum  >/dev/null && { sha1sum "$f"  | awk '{print $1}'; return; } ;;
    sha224) command -v sha224sum>/dev/null && { sha224sum "$f"| awk '{print $1}'; return; } ;;
    sha256) command -v sha256sum>/dev/null && { sha256sum "$f"| awk '{print $1}'; return; } ;;
    sha384) command -v sha384sum>/dev/null && { sha384sum "$f"| awk '{print $1}'; return; } ;;
    sha512) command -v sha512sum>/dev/null && { sha512sum "$f"| awk '{print $1}'; return; } ;;
    b2|blake2b) command -v b2sum>/dev/null && { b2sum "$f"    | awk '{print $1}'; return; } ;;
  esac
  # fallback: openssl covers md5/sha*/sha3-*/blake2* depending on version
  if command -v openssl >/dev/null; then
    openssl dgst -"$algo" -r "$f" 2>/dev/null | awk '{print $1}'
    return
  fi
  echo "No tool available to compute $algo" >&2; exit 3
}

# ---- guess algorithm from hex string length (ambiguous cases favor the common algo)
guess_algo() {
  case ${#1} in
    32)  echo md5 ;;
    40)  echo sha1 ;;
    56)  echo sha224 ;;
    64)  echo sha256 ;;      # also sha3-256 — use -a sha3-256 to force
    96)  echo sha384 ;;
    128) echo sha512 ;;      # also blake2b — use -a blake2b to force
    *)   echo "" ;;
  esac
}

verify_hash_string() {
  local hash="$1"
  hash="${hash,,}"                       # lowercase
  local algo="${ALGO_OVERRIDE:-$(guess_algo "$hash")}"
  [ -n "$algo" ] || fail "Cannot determine algorithm from hash length (${#hash} chars). Use -a."
  local actual
  actual="$(compute_hash "$algo" "$FILE")"
  actual="${actual,,}"
  echo "algo:     $algo"
  echo "expected: $hash"
  echo "actual:   $actual"
  [ "$hash" = "$actual" ] && ok "Checksum matches ($algo)" || fail "Checksum MISMATCH — file may be corrupted or tampered with"
}

verify_checksum_file() {
  local list="$1" base found=""
  base="$(basename "$FILE")"

  # 1) GNU/BSD style: "<hash>  <filename>"  or  "<hash> *<filename>"
  found="$(grep -F "$base" "$list" 2>/dev/null | head -n1 || true)"

  # 2) BSD-style: "SHA256 (filename) = <hash>"
  if [ -z "$found" ]; then
    found="$(grep -F "($base)" "$list" 2>/dev/null | head -n1 || true)"
  fi

  # 3) single-hash file with no filename in it
  if [ -z "$found" ] && [ "$(wc -l < "$list")" -le 1 ]; then
    found="$(cat "$list")"
  fi

  [ -n "$found" ] || fail "Could not find an entry for '$base' in $list"

  local hash
  if [[ "$found" =~ \(.*\)\ =\ ([0-9a-fA-F]+)$ ]]; then
    hash="${BASH_REMATCH[1]}"
  else
    hash="$(awk '{print $1}' <<<"$found")"
    hash="${hash#\*}"
  fi
  verify_hash_string "$hash"
}

verify_signature() {
  local sig="$1"
  command -v gpg >/dev/null || { echo "gpg is required for signature verification" >&2; exit 3; }
  if [ -n "$KEYFILE" ]; then
    gpg --import "$KEYFILE" 2>/dev/null || warn "Key import reported an issue (may already be imported)"
  fi
  local out
  out="$(gpg --status-fd 1 --verify "$sig" "$FILE" 2>/dev/null)" || true
  echo "$out" | grep -v '^\[GNUPG:\]' || true

  if echo "$out" | grep -q '^\[GNUPG:\] GOODSIG'; then
    if echo "$out" | grep -q '^\[GNUPG:\] TRUST_ULTIMATE\|^\[GNUPG:\] TRUST_FULLY'; then
      ok "Good signature, and key is trusted"
    else
      warn "Signature is cryptographically good, but the key is NOT in your trusted keyring"
      ok  "Good signature (untrusted key — verify the key's fingerprint out-of-band)"
    fi
  else
    fail "Signature verification FAILED — do not trust this file"
  fi
}

# ---- dispatch --------------------------------------------------------------
if [ -f "$CHECK" ]; then
  case "$CHECK" in
    *.asc|*.sig|*.gpg|*.pgp) verify_signature "$CHECK" ;;
    *)                       verify_checksum_file "$CHECK" ;;
  esac
elif [[ "$CHECK" =~ ^[0-9a-fA-F]+$ ]]; then
  verify_hash_string "$CHECK"
else
  echo "Second argument is neither an existing file nor a hex hash string." >&2
  exit 2
fi
