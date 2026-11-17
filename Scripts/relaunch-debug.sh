#!/bin/bash
# Quits any running Friday (waiting for it to really exit, then killing it) and launches the Debug build.
set -u
APP=${1:-build/DerivedData/Build/Products/Debug/Friday.app}
osascript -e 'tell application id "com.alejandro.friday" to quit' >/dev/null 2>&1
for _ in $(seq 1 20); do pgrep -f "Friday.app/Contents/MacOS/Friday" >/dev/null || break; sleep 0.5; done
pgrep -f "Friday.app/Contents/MacOS/Friday" >/dev/null && { pkill -9 -f "Friday.app/Contents/MacOS/Friday"; sleep 1; }
pkill -f "jarvis.server" >/dev/null 2>&1
# LaunchServices refuses (error -600) while the old process is still being torn down: retry for a few seconds.
for _ in 1 2 3 4 5; do open "$APP" 2>/dev/null && break; sleep 1; done
CTL="$APP/Contents/Helpers/fridayctl"
for _ in $(seq 1 40); do "$CTL" --ping >/dev/null 2>&1 && { echo "Friday is running ($(pgrep -f 'Friday.app/Contents/MacOS/Friday' | head -1))"; exit 0; }; sleep 0.5; done
echo "Friday did not answer"; exit 1
