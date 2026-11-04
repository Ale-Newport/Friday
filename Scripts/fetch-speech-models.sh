#!/bin/bash
# Fetches the pinned, checksum-verified speech models — Kokoro multi-lang v1.0 (text-to-speech) and Silero VAD (voice
# activity) — into Vendor/Speech. Idempotent: re-running with valid files is a no-op.
#
#   Scripts/fetch-speech-models.sh                # fetch (if needed) and verify
#   Scripts/fetch-speech-models.sh --force        # re-download everything
#   Scripts/fetch-speech-models.sh --cache DIR    # take a download from DIR/<file name> instead of the network when its
#                                                 # checksum matches (anything else there is ignored and downloaded)
#
# Downloads only from github.com/k2-fsa/sherpa-onnx releases, verifies every download against Vendor/Speech/speech.lock
# BEFORE extracting it (into a fresh temporary directory), and installs nothing on a mismatch. Every installed file is then
# recorded with its own SHA-256 (.installed.sha256), and a re-run re-checks them, so an interrupted or damaged install is
# repaired rather than trusted. The library these models run on comes from Scripts/fetch-sherpa.sh. Nothing here needs an
# account, a key or a licence acceptance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/Speech"
LOCK="$VENDOR/speech.lock"
FORCE=0
CACHE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --cache) [[ $# -ge 2 ]] || { echo "error: --cache needs a directory" >&2; exit 2; }; CACHE="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

[[ -f "$LOCK" ]] || { echo "error: missing $LOCK" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

MANIFEST="$VENDOR/.installed.sha256"
# True when everything was installed from this very lock and still hashes as recorded (the manifest lists every file,
# including each one below a TREE).
installed_and_intact() {
  [[ -f "$VENDOR/.verified" ]] && cmp -s "$LOCK" "$VENDOR/.verified" \
    && [[ -f "$MANIFEST" ]] && (cd "$VENDOR" && shasum -a 256 -c "$MANIFEST" >/dev/null 2>&1)
}

if [[ $FORCE -eq 0 ]] && installed_and_intact; then
  echo "speech models already present and verified."
else
  # From here on the installation is "not verified" until it completes: an interruption must not leave a stale stamp behind.
  rm -f "$VENDOR/.verified" "$MANIFEST"
  mkdir -p "$VENDOR"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Fetching speech models (github.com/k2-fsa/sherpa-onnx) …"

  # Puts the verified download <name> at $TMP/<name>/download/<file name>: from the cache when the copy there has the pinned
  # digest, from the network otherwise. Nothing is unpacked or installed before the digest matched.
  obtain() {
    local name="$1" digest="$2" url="$3"
    local file; file="$(basename "$url")"
    mkdir -p "$TMP/$name/download" "$TMP/$name/files"
    if [[ -n "$CACHE" && -f "$CACHE/$file" && "$(sha256_of "$CACHE/$file")" == "$digest" ]]; then
      cp -f "$CACHE/$file" "$TMP/$name/download/$file"
      printf '  ok  %s (from %s)\n' "$file" "$CACHE"
      return
    fi
    curl -fsSL --retry 3 --max-time 1800 -o "$TMP/$name/download/$file" "$url"
    local actual; actual="$(sha256_of "$TMP/$name/download/$file")"
    if [[ "$actual" != "$digest" ]]; then
      echo "error: checksum mismatch for $url" >&2
      echo "  expected $digest" >&2
      echo "  actual   $actual" >&2
      exit 1
    fi
    printf '  ok  %s (%s bytes)\n' "$file" "$(wc -c < "$TMP/$name/download/$file" | tr -d ' ')"
  }
  # A file is either the old one or the complete new one, never half of it: copied beside its destination, then renamed.
  install_file() {
    mkdir -p "$VENDOR/$(dirname "$2")"
    cp -f "$1" "$VENDOR/$2.partial"
    mv -f "$VENDOR/$2.partial" "$VENDOR/$2"
  }
  install_tree() {
    mkdir -p "$VENDOR/$(dirname "$2")"
    rm -rf "$VENDOR/$2.partial"
    cp -R "$1" "$VENDOR/$2.partial"
    rm -rf "$VENDOR/$2"
    mv "$VENDOR/$2.partial" "$VENDOR/$2"
  }

  while read -r name digest url; do
    obtain "$name" "$digest" "$url"
    tar -xjf "$TMP/$name/download/$(basename "$url")" -C "$TMP/$name/files"
  done < <(awk '$1=="ARCHIVE"{print $2, $3, $4}' "$LOCK")

  while read -r name digest url dest; do
    obtain "$name" "$digest" "$url"
    install_file "$TMP/$name/download/$(basename "$url")" "$dest"
  done < <(awk '$1=="FILE"{print $2, $3, $4, $5}' "$LOCK")

  while read -r name path dest; do
    [[ -f "$TMP/$name/files/$path" ]] || { echo "error: $path is not in the $name archive" >&2; exit 1; }
    install_file "$TMP/$name/files/$path" "$dest"
  done < <(awk '$1=="EXTRACT"{print $2, $3, $4}' "$LOCK")

  while read -r name path dest; do
    [[ -d "$TMP/$name/files/$path" ]] || { echo "error: $path is not a directory in the $name archive" >&2; exit 1; }
    install_tree "$TMP/$name/files/$path" "$dest"
  done < <(awk '$1=="TREE"{print $2, $3, $4}' "$LOCK")

  # Every installed path, relative to Vendor/Speech, so the next run can check each one.
  installed() {
    awk '$1=="EXTRACT"{print $4} $1=="FILE"{print $5}' "$LOCK"
    while read -r dest; do (cd "$VENDOR" && find "$dest" -type f | LC_ALL=C sort); done < <(awk '$1=="TREE"{print $4}' "$LOCK")
  }
  (cd "$VENDOR" && installed | tr '\n' '\0' | xargs -0 shasum -a 256 > "$MANIFEST")
  cp -f "$LOCK" "$VENDOR/.verified"
  echo "Installed to $VENDOR"
fi

printf '  %s files, %s\n' "$(wc -l < "$MANIFEST" | tr -d ' ')" "$(du -sh "$VENDOR" | awk '{print $1}')"
cat <<'EOT'

The models are free to use (Kokoro: Apache-2.0, its espeak-ng data: GPL-3.0-or-later, Silero VAD: MIT). There is no key,
account or network access involved at run time.
EOT
