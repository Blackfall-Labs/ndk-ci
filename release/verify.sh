#!/usr/bin/env bash
# Check a release with the operating system's own tools (NS-0002 R-5, R-6, R-7, R-11).
#
#   release/verify.sh DIR [--pubkey FILE] [FILE ...]
#
# DIR holds SHA256SUMS, SHA256SUMS.sig and the files to check. First the signature: it must
# be SHA256SUMS signed in namespace `blackfall-release` by the public key in FILE (default:
# blackfall-release.pub beside this script). Then each named FILE, or with none every file
# SHA256SUMS lists, must be present and match its sha256.
#
# Needs only ssh-keygen (OpenSSH 8.2 or later) and sha256sum or shasum. Reads no token and
# no network: a customer runs exactly this. Exits 0 when everything checks, non-zero with
# the failing file named otherwise.
set -euo pipefail

IDENTITY="release@blackfall.dev"
NAMESPACE="blackfall-release"

[ $# -ge 1 ] || { echo "usage: verify.sh DIR [--pubkey FILE] [FILE ...]" >&2; exit 2; }
dir="$1"; shift
pub="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blackfall-release.pub"
if [ "${1:-}" = "--pubkey" ]; then pub="$2"; shift 2; fi

fail() { echo "FAIL $*" >&2; exit 1; }

[ -f "$pub" ] || fail "$pub: no public key to verify against"
[ -f "$dir/SHA256SUMS" ] || fail "SHA256SUMS: missing from $dir"
[ -f "$dir/SHA256SUMS.sig" ] || fail "SHA256SUMS.sig: missing from $dir"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s namespaces="%s" %s\n' "$IDENTITY" "$NAMESPACE" "$(awk 'NF {print $1, $2; exit}' "$pub")" \
  >"$work/allowed_signers"

if ! ssh-keygen -Y verify -f "$work/allowed_signers" -I "$IDENTITY" -n "$NAMESPACE" \
     -s "$dir/SHA256SUMS.sig" <"$dir/SHA256SUMS" >/dev/null 2>"$work/err"; then
  cat "$work/err" >&2
  fail "SHA256SUMS.sig: does not verify SHA256SUMS with $(basename "$pub") (SHA256SUMS or its signature was altered, or another key signed it)"
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Every line must be `<64 hex>  <name>`, and no name may reach outside DIR. Written for the
# bash 3.2 macOS ships, so no associative arrays.
listed="$work/listed"
: >"$listed"
while read -r hash name; do
  [ -n "$hash" ] || continue
  name="${name#\*}"
  case "$name" in */* | *\\* | .. | . | "") fail "SHA256SUMS: refuses the name '$name'" ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail "SHA256SUMS: bad line for $name"
  printf '%s %s\n' "$hash" "$name" >>"$listed"
done <"$dir/SHA256SUMS"
[ -s "$listed" ] || fail "SHA256SUMS: lists no files"

if [ $# -eq 0 ]; then
  # shellcheck disable=SC2046
  set -- $(awk '{print $2}' "$listed")
fi

for name in "$@"; do
  name="$(basename "$name")"
  expect="$(awk -v n="$name" '$2 == n {print $1; exit}' "$listed")"
  [ -n "$expect" ] || fail "$name: not listed in SHA256SUMS"
  [ -f "$dir/$name" ] || fail "$name: missing from $dir"
  [ "$(sha256 "$dir/$name")" = "$expect" ] || fail "$name: sha256 does not match SHA256SUMS"
  echo "ok   $name"
done
echo "verified $# file(s) against SHA256SUMS signed by $(basename "$pub")"
