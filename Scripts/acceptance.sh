#!/bin/bash
# Runs a set of typed acceptance scenarios through the running app (the assistant pipeline, via `fridayctl --say`)
# and prints a Markdown table with the tools that ran, the status and the reply, for docs/TEST_RESULTS.md.
#
# Scenarios are read-only or reversible by design (they create nothing in the user's apps except where marked).
# Usage: Scripts/acceptance.sh [path/to/Friday.app] > results.md
set -uo pipefail

APP=${1:-build/DerivedData/Build/Products/Debug/Friday.app}
CTL="$APP/Contents/Helpers/fridayctl"
[ -x "$CTL" ] || { echo "fridayctl not found at $CTL"; exit 2; }
"$CTL" --ping >/dev/null || { echo "Friday is not running"; exit 2; }

SCENARIOS=$(cat <<'EOF'
1|open Chrome|system.open_app
2|abre Chrome|system.open_app
3|open... no, wait, open Notes instead|system.open_app
7|Jarvis... um... what's the weather tomorrow?|weather.forecast
10a|¿qué hora es?|friday.current_time
10b|what time is it?|friday.current_time
12|list my playlists|music.
17|what's on my calendar tomorrow?|calendar.list_events
18|¿qué tengo en el calendario mañana?|calendar.list_events
29|close Chrome|system.close_app
31|find files named "Package.swift" in my Projects folder|files.
33|what is the frontmost app?|computer.frontmost
35|describe what is on my screen|computer.describe_screen
41|what did I ask you before this?|-
44|remember that my favourite editor is Xcode|memory.remember
45|what is my favourite editor?|-
49|¿cuál es la capital de Australia?|-
50|cuéntame un chiste corto|-
51|explícame en dos frases qué es un agujero negro|-
52|traduce al inglés "¿dónde está la estación de tren?"|-
53|¿cuánto es diecisiete por veinticuatro?|-
54|¿qué tiempo hace hoy en Londres?|weather.
55|busca en internet el precio actual del bitcoin|web.task
EOF
)

echo "| # | Command | Tools | Status | Reply (truncated) | ms |"
echo "|---|---|---|---|---|---|"
while IFS='|' read -r num text expected; do
  [ -z "$num" ] && continue
  # fridayctl exits non-zero for clarifications/failures but still prints the JSON; keep it.
  json=$("$CTL" --timeout 180 --say "$text" --json 2>/dev/null); [ -z "$json" ] && json='{}' 
  printf '%s' "$json" | python3 -I -c '
import json, sys
num, text, expected = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
tools = ", ".join(r.get("tool", "") for r in d.get("results", []))
status = d.get("status", "no response")
reply = (d.get("message") or "").replace("\n", " ").replace("|", "/")[:110]
ms = (((d.get("data") or {}).get("latency") or {}).get("totalMs")) or d.get("duration_ms") or ""
ok = "✅" if d.get("success") and (expected == "-" or expected in tools) else "❌"
print(f"| {num} | {text.replace(chr(124), chr(47))} | {tools or "—"} | {status} {ok} | {reply} | {ms} |")
' "$num" "$text" "$expected"
done <<< "$SCENARIOS"
