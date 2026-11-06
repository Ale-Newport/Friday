#!/bin/bash
# Xcode build phase: copies the native speech libraries, the wake-word and speech models, and the browser sidecar into
# Friday.app, and signs the libraries. Missing optional pieces produce a note, never a failed build: a fresh clone builds,
# and the app explains at runtime what is not installed.
set -euo pipefail

APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
FRAMEWORKS="${APP}/Contents/Frameworks"
ENGINES="${APP}/Contents/Resources/Engines"
SPEECH="${APP}/Contents/Resources/Speech"
BACKEND="${APP}/Contents/Resources/backend"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"

# With a real identity, only Release builds ask Apple's timestamp server (needed for notarisation; needs the network).
# Debug builds, or FRIDAY_CODESIGN_TIMESTAMP=0 in the environment, sign without a timestamp so the app builds offline.
sign() {
  if [[ -z "${IDENTITY}" || "${IDENTITY}" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$1"
  elif [[ "${CONFIGURATION:-Debug}" == "Release" && "${FRIDAY_CODESIGN_TIMESTAMP:-1}" != "0" ]]; then
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp "$1"
  else
    codesign --force --sign "${IDENTITY}" --options runtime --timestamp=none "$1"
  fi
}

mkdir -p "${FRAMEWORKS}" "${ENGINES}" "${SPEECH}"

# --- sherpa-onnx: wake word, Kokoro text-to-speech, Silero voice activity (one library) ----------------------------
SHERPA="${SRCROOT}/Vendor/SherpaOnnx"
SHERPA_MODEL="${SHERPA}/models/sherpa-kws"
if [[ -f "${SHERPA}/lib/libsherpa-onnx-c-api.dylib" && -f "${SHERPA}/lib/libonnxruntime.dylib" && -f "${SHERPA_MODEL}/tokens.txt" ]]; then
  cp -f "${SHERPA}/lib/libsherpa-onnx-c-api.dylib" "${FRAMEWORKS}/libsherpa-onnx-c-api.dylib"
  cp -f "${SHERPA}/lib/libonnxruntime.dylib" "${FRAMEWORKS}/libonnxruntime.dylib"
  sign "${FRAMEWORKS}/libsherpa-onnx-c-api.dylib"
  sign "${FRAMEWORKS}/libonnxruntime.dylib"
  mkdir -p "${ENGINES}/sherpa-kws"
  while read -r name; do
    cp -f "${SHERPA_MODEL}/${name}" "${ENGINES}/sherpa-kws/${name}"
  done < <(awk '$1=="EXTRACT" && $4 ~ /^models\/sherpa-kws\//{n=split($4, parts, "/"); print parts[n]}' "${SHERPA}/sherpa.lock")
  echo "Embedded the sherpa-onnx library and the wake-word model"
else
  echo "warning: Vendor/SherpaOnnx is incomplete — run Scripts/fetch-sherpa.sh. The app builds, but the wake word and Kokoro will show as not installed."
fi

# --- Speech models: Kokoro (multilingual) and Silero VAD ----------------------------------------------------------
SPEECH_SRC="${SRCROOT}/Vendor/Speech"
if [[ -d "${SPEECH_SRC}/kokoro-multi-lang-v1_0" ]]; then
  rsync -a --delete "${SPEECH_SRC}/kokoro-multi-lang-v1_0/" "${SPEECH}/kokoro-multi-lang-v1_0/"
  echo "Embedded Kokoro"
else
  echo "note: Vendor/Speech/kokoro-multi-lang-v1_0 is missing — run Scripts/fetch-speech-models.sh (Friday falls back to Apple voices)."
fi
if [[ -f "${SPEECH_SRC}/silero_vad.onnx" ]]; then
  cp -f "${SPEECH_SRC}/silero_vad.onnx" "${SPEECH}/silero_vad.onnx"
else
  echo "note: Vendor/Speech/silero_vad.onnx is missing — run Scripts/fetch-speech-models.sh (Friday uses energy-based endpointing)."
fi

# --- Porcupine (optional, paid key) ------------------------------------------------------------------------------
VENDOR="${SRCROOT}/Vendor/Porcupine"
if [[ -f "${VENDOR}/lib/libpv_porcupine.dylib" && -f "${VENDOR}/models/porcupine_params.pv" && -f "${VENDOR}/keywords/jarvis_mac.ppn" ]]; then
  cp -f "${VENDOR}/lib/libpv_porcupine.dylib" "${FRAMEWORKS}/libpv_porcupine.dylib"
  cp -f "${VENDOR}/models/porcupine_params.pv" "${ENGINES}/porcupine_params.pv"
  cp -f "${VENDOR}/keywords/jarvis_mac.ppn" "${ENGINES}/jarvis_mac.ppn"
  sign "${FRAMEWORKS}/libpv_porcupine.dylib"
fi

# --- Browser sidecar (packaged PyInstaller build, Release) ---------------------------------------------------------
SIDECAR_DIST="${SRCROOT}/Sidecar/dist/jarvis-backend"
if [[ "${CONFIGURATION:-Debug}" == "Release" && -x "${SIDECAR_DIST}/jarvis-backend" ]]; then
  rsync -a --delete "${SIDECAR_DIST}/" "${BACKEND}/"
  echo "Embedded the packaged browser sidecar"
elif [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
  echo "note: Sidecar/dist/jarvis-backend not found — run Scripts/package-sidecar.sh to embed the browser agent in the Release app (the Debug app uses Sidecar/.venv directly)."
fi
