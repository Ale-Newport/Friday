#!/bin/bash
# Downloads, and verifies against pinned SHA-256 digests, the exact source of the copyleft components in a Friday
# release, so it can be published next to the binary (GPL-3.0 §6, LGPL-3.0 §4):
#
#   * espeak-ng and piper-phonemize — the commits sherpa-onnx v1.13.8 builds into libsherpa-onnx-c-api.dylib
#     (sherpa-onnx cmake/espeak-ng-for-piper.cmake and cmake/piper-phonemize.cmake);
#   * edge-tts — the sdist of the version pinned in Sidecar/uv.lock;
#   * the GNU GPL-3.0 and LGPL-3.0 texts, taken from those archives.
#
#   Scripts/fetch-corresponding-source.sh dist/source
set -euo pipefail
OUT="${1:?usage: Scripts/fetch-corresponding-source.sh OUTPUT_DIR}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # url name sha256
  curl -fsSL --retry 3 -o "$OUT/$2" "$1"
  echo "$3  $OUT/$2" | shasum -a 256 -c - >/dev/null || { echo "error: $2 does not match its pinned digest" >&2; rm -f "$OUT/$2"; exit 1; }
  echo "  ✓ $2"
}

fetch "https://github.com/csukuangfj/espeak-ng/archive/ed530aa113046142eb5115cf2fc9157854d0ffe1.zip" \
  "espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip" e4e262cbe34f7fe21f91f1ba3397f2728e1f30eafbae7853f2b753a9ed13f0dd
fetch "https://github.com/csukuangfj/piper-phonemize/archive/f3ff95afc03640bc1399e113e83361192a2fafb4.zip" \
  "piper-phonemize-f3ff95afc03640bc1399e113e83361192a2fafb4.zip" d9cca4e2bdc7d6dd8dffb96a4668283dbd3f77a9c194a3e530c1e8eba9406a5d
fetch "https://files.pythonhosted.org/packages/a3/ce/14e713ba774063e00444a091eb790539fe0d848a9d8df35fd81a7639a28e/edge_tts-7.3.1.tar.gz" \
  "edge_tts-7.3.1.tar.gz" ee1fabf911b9ea83b38ae93aee5619ee41eaf0b109fef6e65d797dc4ebf1f20f

# The licence texts, from the archives themselves.
unzip -q -o -d "$WORK" "$OUT/espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip"
cp "$(find "$WORK" -maxdepth 2 -name COPYING | head -1)" "$OUT/GPL-3.0.txt"
tar -xzf "$OUT/edge_tts-7.3.1.tar.gz" -C "$WORK"
cp "$(find "$WORK/edge_tts-7.3.1" -maxdepth 1 \( -name 'LICENSE*' -o -name 'COPYING*' \) | head -1)" "$OUT/edge-tts-LICENSE.txt"
grep -q "GNU GENERAL PUBLIC LICENSE" "$OUT/GPL-3.0.txt"
grep -qi "LESSER GENERAL PUBLIC LICENSE" "$OUT/edge-tts-LICENSE.txt" || echo "note: edge-tts licence file is not the LGPL text; check it"
echo "  ✓ licence texts"
