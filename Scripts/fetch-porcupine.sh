#!/bin/bash
# Fetches the pinned, checksum-verified Picovoice Porcupine macOS artifacts into
# Vendor/Porcupine/{lib,models,keywords}. Idempotent: re-running with valid files is a no-op.
#
#   Scripts/fetch-porcupine.sh            # fetch (if needed) and verify
#   Scripts/fetch-porcupine.sh --force    # re-download everything
#
# Downloads only from raw.githubusercontent.com/Picovoice/porcupine at a pinned commit, verifies
# every file against Vendor/Porcupine/porcupine.lock, and refuses to install on a mismatch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/Porcupine"
LOCK="$VENDOR/porcupine.lock"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

[[ -f "$LOCK" ]] || { echo "error: missing $LOCK" >&2; exit 1; }
COMMIT="$(awk '$1=="COMMIT"{print $2}' "$LOCK")"
BASE="https://raw.githubusercontent.com/Picovoice/porcupine/$COMMIT"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

ready() {
  [[ $FORCE -eq 0 ]] || return 1
  [[ -f "$VENDOR/lib/libpv_porcupine.dylib" && -f "$VENDOR/models/porcupine_params.pv" \
     && -f "$VENDOR/keywords/jarvis_mac.ppn" ]] || return 1
  # Re-verify the single-architecture inputs we recorded when we built the universal binary.
  [[ -f "$VENDOR/downloads/.verified-$COMMIT" ]]
}

if ready; then
  echo "Porcupine artifacts already present and verified (commit ${COMMIT:0:12})."
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Fetching Porcupine artifacts from github.com/Picovoice/porcupine @ ${COMMIT:0:12} …"

  grep -v -E '^\s*(#|COMMIT|$)' "$LOCK" | while read -r digest repo_path dest_path; do
    mkdir -p "$TMP/$(dirname "$dest_path")"
    curl -fsSL --retry 3 --max-time 120 -o "$TMP/$dest_path" "$BASE/$repo_path"
    actual="$(sha256_of "$TMP/$dest_path")"
    if [[ "$actual" != "$digest" ]]; then
      echo "error: checksum mismatch for $repo_path" >&2
      echo "  expected $digest" >&2
      echo "  actual   $actual" >&2
      exit 1
    fi
    printf '  ok  %s (%s bytes)\n' "$repo_path" "$(wc -c < "$TMP/$dest_path" | tr -d ' ')"
  done

  mkdir -p "$VENDOR/lib" "$VENDOR/models" "$VENDOR/keywords" "$VENDOR/downloads"
  # One universal dylib so a single bundle runs natively on Apple Silicon and Intel.
  lipo -create "$TMP/arm64/libpv_porcupine.dylib" "$TMP/x86_64/libpv_porcupine.dylib" \
       -output "$VENDOR/lib/libpv_porcupine.dylib"
  # lipo invalidates the original ad-hoc signature; re-sign (the app build re-signs again).
  codesign --force --sign - "$VENDOR/lib/libpv_porcupine.dylib" >/dev/null 2>&1
  cp "$TMP/models/porcupine_params.pv" "$VENDOR/models/porcupine_params.pv"
  cp "$TMP/keywords/jarvis_mac.ppn"    "$VENDOR/keywords/jarvis_mac.ppn"
  : > "$VENDOR/downloads/.verified-$COMMIT"
  echo "Installed to $VENDOR/{lib,models,keywords}"
fi

lipo -info "$VENDOR/lib/libpv_porcupine.dylib"
cat <<'EOF'

Reminder: the library is Apache-2.0, but the engine will not run without a valid Picovoice
AccessKey, which is validated online when the engine initialises. Picovoice discontinued its
Free Tier on 2026-06-30; see NOTICE.md and Vendor/Porcupine/README.md.
EOF
