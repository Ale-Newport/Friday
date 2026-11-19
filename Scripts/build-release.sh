#!/bin/bash
# Builds the downloadable Friday release: an ad-hoc-signed Apple Silicon Friday.app with the packaged browser
# sidecar, speech models and every third-party notice, zipped with its SHA-256.
#
#   Scripts/build-release.sh 0.2.0          # → dist/Friday-0.2.0-macos-arm64.zip (+ .sha256)
#
# Used by .github/workflows/release.yml; runs the same on a Mac with Xcode, XcodeGen and uv.
# The app is ad-hoc signed ("-"): there is no Developer ID certificate, and a personal development certificate would
# publish the developer's e-mail inside the signature. See docs/INSTALL.md for opening it past Gatekeeper.
set -euo pipefail

VERSION="${1:?usage: Scripts/build-release.sh VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/ReleaseDerivedData"
NAME="Friday-${VERSION}-macos-arm64"
STAGE="$DIST/$NAME"

echo "▸ Fetching the pinned, checksum-verified speech libraries and models…"
Scripts/fetch-sherpa.sh
Scripts/fetch-speech-models.sh

echo "▸ Packaging the Python sidecar…"
Scripts/package-sidecar.sh

echo "▸ Building Friday.app (Release, arm64, ad-hoc signed)…"
xcodegen generate >/dev/null
xcodebuild -project Friday.xcodeproj -scheme Friday -configuration Release -derivedDataPath "$DERIVED" \
  ARCHS=arm64 MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build > "$DIST.xcodebuild.log" 2>&1 || { grep -nE "error|Stack dump" "$DIST.xcodebuild.log" | head -60; exit 1; }
APP="$DERIVED/Build/Products/Release/Friday.app"

echo "▸ Checking the bundle…"
codesign --verify --deep --strict "$APP"
test -x "$APP/Contents/Helpers/fridayctl"
test -x "$APP/Contents/Resources/backend/jarvis-backend" || { echo "error: the browser sidecar is not embedded"; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION"
if strings -a "$APP/Contents/MacOS/Friday" | grep -q "/Users/$(id -un)/"; then
  echo "note: the binary contains this machine's home path (#file strings); CI builds use the runner's paths."
fi

echo "▸ Collecting third-party notices…"
rm -rf "$STAGE" && mkdir -p "$STAGE/Licenses"
ditto "$APP" "$STAGE/Friday.app"
cp LICENSE NOTICE.md NOTICE-ATTICUS.md "$STAGE/Licenses/"
cp Vendor/SherpaOnnx/LICENSE "$STAGE/Licenses/sherpa-onnx-LICENSE.txt"
cp Vendor/SherpaOnnx/LICENSE.onnxruntime "$STAGE/Licenses/onnxruntime-LICENSE.txt"
cp Vendor/Speech/kokoro-multi-lang-v1_0/LICENSE "$STAGE/Licenses/kokoro-LICENSE.txt"
cp Vendor/Speech/piper-es_ES-miro-high/README.md "$STAGE/Licenses/piper-es_ES-miro-README-CC-BY-NC-SA-4.0.md"
cp Sidecar/NOTICE "$STAGE/Licenses/sidecar-NOTICE.txt"
(cd Sidecar && uv run --quiet python ../Scripts/collect-licenses.py "$STAGE/Licenses/python-packages.md")
cp docs/INSTALL.md "$STAGE/INSTALL.md"
cat > "$STAGE/Licenses/SOURCE.md" <<EOF
# Source code

Friday ${VERSION} is built from https://github.com/Ale-Newport/Friday/tree/v${VERSION} (MIT).

The bundled sherpa-onnx library links espeak-ng and piper-phonemize (GPL-3.0-or-later), and the sidecar contains
edge-tts (LGPL-3.0, shipped as editable .py files in Contents/Resources/backend/_internal/edge_tts). Their exact
corresponding source is attached to the same GitHub release as this download:

* espeak-ng-ed530aa113046142eb5115cf2fc9157854d0ffe1.zip
* piper-phonemize-f3ff95afc03640bc1399e113e83361192a2fafb4.zip
* the edge-tts source distribution

(the commits sherpa-onnx v1.13.8 builds from), together with the GNU GPL and LGPL texts.
EOF

echo "▸ Zipping…"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$DIST/$NAME.zip"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
du -sh "$DIST/$NAME.zip"
cat "$DIST/$NAME.zip.sha256"
