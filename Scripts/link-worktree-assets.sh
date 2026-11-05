#!/bin/bash
# Links the git-ignored build assets (vendored sherpa-onnx/Porcupine libraries and models, speech models, the sidecar's
# virtualenv and the machine-specific signing config) from a main checkout into a worktree, so `swift build`,
# `swift test` and the app build work there without re-downloading anything.
#
# Usage: Scripts/link-worktree-assets.sh [/path/to/main/checkout]   (run from inside the worktree)
set -euo pipefail
MAIN=${1:-/Users/alejandro/Projects/Friday}
[ -d "$MAIN/Vendor" ] || { echo "no Vendor directory at $MAIN"; exit 2; }
for p in Vendor/SherpaOnnx/lib Vendor/SherpaOnnx/models Vendor/SherpaOnnx/.verified Vendor/SherpaOnnx/.installed.sha256 \
         Vendor/Speech/silero_vad.onnx Vendor/Speech/kokoro-multi-lang-v1_0 Vendor/Speech/.verified Vendor/Speech/.installed.sha256 \
         Vendor/Porcupine/lib Vendor/Porcupine/models Vendor/Porcupine/keywords Vendor/Porcupine/downloads \
         Sidecar/.venv Config/Local.xcconfig; do
  if [ -e "$MAIN/$p" ] && [ ! -e "$p" ]; then
    mkdir -p "$(dirname "$p")"
    ln -s "$MAIN/$p" "$p"
    echo "linked $p"
  fi
done
