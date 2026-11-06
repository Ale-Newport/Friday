#!/bin/bash
# Measures what Friday.app costs while it runs, using the counters macOS keeps per process
# (CPU time, energy, wake-ups, memory footprint). No sudo, no estimates.
#
#   Scripts/measure-app.sh [options]
#
#   --mic              use the real microphone (grant permission to Friday first; default is --synthetic)
#   --synthetic        feed generated quiet noise instead of the microphone (no permission needed)
#   --engine ID        wake-word engine to run: mock (default for --synthetic), sherpa-onnx (the free engine; with
#                      --synthetic the generated noise is a quiet room, so this is its idle cost) or porcupine (needs a
#                      paid key in the Keychain)
#   --disabled         measure the app with wake-word detection turned off (the menu-bar app's own baseline)
#   --seconds N        measurement window (default 60)
#   --warmup N         settle time before measuring (default 10)
#   --app PATH         app bundle (default: build/DerivedData/Build/Products/Release/Friday.app)
#
# Build the app first (`make release`, or xcodebuild -configuration Release) and the measurement tool (`make bench`).
# The figure covers the Friday process only: the Python sidecar is a separate child process and is not started here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Release/Friday.app"
MODE=synthetic; ENGINE=""; DISABLED=0; SECONDS_TO_MEASURE=60; WARMUP=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mic) MODE=mic ;;
    --synthetic) MODE=synthetic ;;
    --engine) ENGINE="$2"; shift ;;
    --disabled) DISABLED=1 ;;
    --seconds) SECONDS_TO_MEASURE="$2"; shift ;;
    --warmup) WARMUP="$2"; shift ;;
    --app) APP="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BENCH="$(cd "$ROOT" && swift build -c release --show-bin-path 2>/dev/null)/friday-bench"
[[ -x "$BENCH" ]] || { echo "friday-bench not built: run 'make bench' (swift build -c release --product friday-bench)" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "app not found: $APP (build it first with 'make release')" >&2; exit 1; }
EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ -x "$EXECUTABLE" ]] || { echo "app executable not found: $EXECUTABLE" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

ARGS=(--no-sidecar)
[[ "$MODE" == synthetic ]] && ARGS+=(--synthetic-audio)
[[ -z "$ENGINE" && "$MODE" == synthetic ]] && ENGINE=mock
[[ -n "$ENGINE" ]] && ARGS+=(--engine "$ENGINE")

# The app saves its settings in the user's own preferences (sensitivity, microphone, voice…), and a run changes some of
# them (the engine it was told to use, detection on or off). The whole domain is put back as it was when the run ends —
# never deleted, because it may hold the user's real settings.
DOMAIN_BACKUP="$(mktemp -t friday-prefs)"
HAD_DOMAIN=0
if defaults export "$BUNDLE_ID" "$DOMAIN_BACKUP" >/dev/null 2>&1 && [[ -s "$DOMAIN_BACKUP" ]]; then HAD_DOMAIN=1; fi

# Detection can be turned off through the app's own preferences for the duration of the run. Friday keeps the switch in
# its voice settings (a JSON blob under friday.voice.v1, which overrides the wake-word store's wakeWord.isEnabled at
# launch), so both are written.
if [[ $DISABLED -eq 1 ]]; then
  defaults write "$BUNDLE_ID" wakeWord.isEnabled -bool false
  defaults write "$BUNDLE_ID" friday.voice.v1 -data "$(printf '{"wakeWordEnabled":false}' | xxd -p | tr -d '\n')"
fi

"$EXECUTABLE" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  # `defaults import` only adds and overwrites keys, so what the run added has to be cleared first.
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  if [[ $HAD_DOMAIN -eq 1 ]]; then
    if defaults import "$BUNDLE_ID" "$DOMAIN_BACKUP" 2>/dev/null; then rm -f "$DOMAIN_BACKUP"
    else echo "could not put the app's settings back; the copy is at $DOMAIN_BACKUP" >&2; fi
  fi
}
trap cleanup EXIT

sleep "$WARMUP"
kill -0 "$PID" 2>/dev/null || { echo "Friday exited during start-up" >&2; exit 1; }
echo "Friday.app (pid $PID) — mode: $MODE, engine: ${ENGINE:-saved choice}, detection: $([[ $DISABLED -eq 1 ]] && echo off || echo on), window: ${SECONDS_TO_MEASURE}s"
"$BENCH" measure --pid "$PID" --seconds "$SECONDS_TO_MEASURE"
