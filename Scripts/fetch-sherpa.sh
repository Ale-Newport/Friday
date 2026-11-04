#!/bin/bash
# Fetches the pinned, checksum-verified sherpa-onnx macOS artifacts (library + keyword-spotting model) into
# Vendor/SherpaOnnx/{lib,models}. Idempotent: re-running with valid files is a no-op.
#
#   Scripts/fetch-sherpa.sh              # fetch (if needed) and verify
#   Scripts/fetch-sherpa.sh --force      # re-download everything
#
# Downloads only from github.com/k2-fsa/sherpa-onnx releases at the pinned version, verifies every archive against
# Vendor/SherpaOnnx/sherpa.lock BEFORE extracting it (into a fresh temporary directory), and installs nothing on a mismatch.
# Every installed file is then recorded with its own SHA-256 (.installed.sha256), and a re-run re-checks them, so an interrupted
# or damaged install is repaired rather than trusted. Nothing here needs an account, a key or a licence acceptance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/SherpaOnnx"
LOCK="$VENDOR/sherpa.lock"
FORCE=0
for flag in "$@"; do
  case "$flag" in
    --force) FORCE=1 ;;
    *) echo "unknown option $flag" >&2; exit 2 ;;
  esac
done

[[ -f "$LOCK" ]] || { echo "error: missing $LOCK" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# 1. The vendored C header must still be the one the lock was written for (it has to match the library's version).
read -r header_digest header_path < <(awk '$1=="HEADER"{print $2, $3}' "$LOCK")
if [[ "$(sha256_of "$ROOT/$header_path")" != "$header_digest" ]]; then
  echo "error: $header_path does not match the pinned header — it must come from the same release as the library" >&2
  exit 1
fi

# 2. What does the lock want installed, and is it all there already?
wanted() { awk '$1=="EXTRACT"{print $4}' "$LOCK"; }
all_present() {
  while read -r dest; do [[ -f "$VENDOR/$dest" ]] || return 1; done < <(wanted)
}
MANIFEST="$VENDOR/.installed.sha256"
# True when everything the lock asks for is installed, was installed from this very lock, and still hashes as recorded.
installed_and_intact() {
  all_present && [[ -f "$VENDOR/.verified" ]] && cmp -s "$LOCK" "$VENDOR/.verified" \
    && [[ -f "$MANIFEST" ]] && (cd "$VENDOR" && shasum -a 256 -c "$MANIFEST" >/dev/null 2>&1)
}
if [[ $FORCE -eq 0 ]] && installed_and_intact; then
  echo "sherpa-onnx artifacts already present and verified."
else
  # From here on the installation is "not verified" until it completes: an interruption must not leave a stale stamp behind.
  rm -f "$VENDOR/.verified" "$MANIFEST"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Fetching sherpa-onnx artifacts (github.com/k2-fsa/sherpa-onnx) …"

  # Each archive is downloaded into its own directory, hashed, and only then unpacked.
  awk '$1=="ARCHIVE"{print $2, $3, $4}' "$LOCK" | while read -r name digest url; do
    mkdir -p "$TMP/$name/download" "$TMP/$name/files"
    archive="$TMP/$name/download/$(basename "$url")"
    curl -fsSL --retry 3 --max-time 600 -o "$archive" "$url"
    actual="$(sha256_of "$archive")"
    if [[ "$actual" != "$digest" ]]; then
      echo "error: checksum mismatch for $url" >&2
      echo "  expected $digest" >&2
      echo "  actual   $actual" >&2
      exit 1
    fi
    tar -xjf "$archive" -C "$TMP/$name/files"
    printf '  ok  %s (%s bytes)\n' "$(basename "$url")" "$(wc -c < "$archive" | tr -d ' ')"
  done

  awk '$1=="EXTRACT"{print $2, $3, $4}' "$LOCK" | while read -r name path dest; do
    [[ -f "$TMP/$name/files/$path" ]] || { echo "error: $path is not in the $name archive" >&2; exit 1; }
    mkdir -p "$VENDOR/$(dirname "$dest")"
    # Copy beside the destination and rename: a file is either the old one or the complete new one, never half of it.
    cp -f "$TMP/$name/files/$path" "$VENDOR/$dest.partial"
    mv -f "$VENDOR/$dest.partial" "$VENDOR/$dest"
  done
  (cd "$VENDOR" && wanted_files=$(wanted) && shasum -a 256 $wanted_files > "$MANIFEST")
  cp -f "$LOCK" "$VENDOR/.verified"
  echo "Installed to $VENDOR/{lib,models}"
fi

for library in "$VENDOR"/lib/*.dylib; do
  architectures="$(lipo -archs "$library")" || { echo "error: $library is not a usable library" >&2; exit 1; }
  printf '  %s: %s\n' "$(basename "$library")" "$architectures"
done
cat <<'EOT'

Both libraries are free to use (sherpa-onnx: Apache-2.0, ONNX Runtime: MIT). There is no key, account or network
access involved. See docs/LICENSING_AND_PRIVACY.md.
EOT
