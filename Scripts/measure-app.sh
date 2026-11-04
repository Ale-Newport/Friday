#!/bin/bash
# Measures what Jarvis.app costs while it runs, using the counters macOS keeps per process
# (CPU time, energy, wake-ups, memory footprint). No sudo, no estimates.
#
#   Scripts/measure-app.sh [options]
#
#   --mic              use the real microphone (grant permission to Jarvis first; default is --synthetic)
#   --synthetic        feed generated quiet noise instead of the microphone (no permission needed)
#   --engine ID        engine to run: mock (default for --synthetic), sherpa-onnx (the free engine; with --synthetic the
#                      generated noise is a quiet room, so this is its idle cost) or porcupine (needs a paid key in the Keychain)
#   --disabled         measure the app with detection turned off (the menu-bar app's own baseline)
#   --seconds N        measurement window (default 60)
#   --warmup N         settle time before measuring (default 10)
#   --app PATH         app bundle (default: build/DerivedData/Build/Products/Release/Jarvis.app)
#
# Build the app first (`make app`, or xcodebuild -configuration Release) and `make bench`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DerivedData/Build/Products/Release/Jarvis.app"
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

BENCH="$(cd "$ROOT" && swift build -c release --show-bin-path 2>/dev/null)/jarvis-bench"
[[ -x "$BENCH" ]] || { echo "jarvis-bench not built: run 'make bench'" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "app not found: $APP (build it first)" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

ARGS=()
[[ "$MODE" == synthetic ]] && ARGS+=(--synthetic-audio)
[[ -z "$ENGINE" && "$MODE" == synthetic ]] && ENGINE=mock
[[ -n "$ENGINE" ]] && ARGS+=(--engine "$ENGINE")

# The app saves its settings in the user's own preferences (sensitivity, microphone…), and a run changes some of them (the engine it was
# told to use, detection on or off). The whole domain is put back as it was when the run ends — never deleted, because it may hold the
# user's real settings.
DOMAIN_BACKUP="$(mktemp -t jarvis-prefs)"
HAD_DOMAIN=0
if defaults export "$BUNDLE_ID" "$DOMAIN_BACKUP" >/dev/null 2>&1 && [[ -s "$DOMAIN_BACKUP" ]]; then HAD_DOMAIN=1; fi

# Detection can be turned off through the app's own preference for the duration of the run.
if [[ $DISABLED -eq 1 ]]; then defaults write "$BUNDLE_ID" wakeWord.isEnabled -bool false; fi

"$APP/Contents/MacOS/Jarvis" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>&1 &
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
kill -0 "$PID" 2>/dev/null || { echo "Jarvis exited during start-up" >&2; exit 1; }
echo "Jarvis.app (pid $PID) — mode: $MODE, engine: ${ENGINE:-saved choice}, detection: $([[ $DISABLED -eq 1 ]] && echo off || echo on), window: ${SECONDS_TO_MEASURE}s"
"$BENCH" measure --pid "$PID" --seconds "$SECONDS_TO_MEASURE"
