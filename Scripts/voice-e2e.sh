#!/bin/bash
# End-to-end voice smoke test without a person at the microphone.
#
# Synthesises a bilingual corpus with Friday's own TTS ("Jarvis," in English followed by each command), plays every
# file into the running app's microphone pipeline (`fridayctl --voice`, which replaces the microphone samples for the
# duration of the file) and prints what the wake-word detector, the recogniser and the planner did with it.
#
# Usage: Scripts/voice-e2e.sh [path/to/Friday.app] [output-dir]
set -euo pipefail

APP=${1:-build/DerivedData/Build/Products/Debug/Friday.app}
OUT=${2:-build/voice-e2e}
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
CTL="$APP/Contents/Helpers/fridayctl"
[ -x "$CTL" ] || { echo "fridayctl not found at $CTL (build the app first)"; exit 2; }
"$CTL" --ping >/dev/null || { echo "Friday is not running"; exit 2; }
mkdir -p "$OUT"

# language|text|name|expected tool (or '-' for a spoken answer)
CORPUS=$(cat <<'EOF'
en|what time is it?|en-time|friday.current_time
es|¿qué hora es?|es-hora|friday.current_time
es|abre Notas|es-abre-notas|system.open_app
es|cierra Notas|es-cierra-notas|system.close_app
en|open Calculator|en-open-calc|system.open_app
en|close Calculator|en-close-calc|system.close_app
en|what's seventeen times twenty four?|en-arith|utilities.calculate
es|¿cuánto es diecisiete por veinticuatro?|es-arith|utilities.calculate
en|what's the weather in Madrid tomorrow?|en-weather|weather.forecast
es|¿qué tengo en el calendario mañana?|es-calendar|calendar.list_events
es|recuerda que mi color favorito es el azul|es-remember|memory.remember
es|¿cuál es mi color favorito?|es-recall|-
EOF
)

# The wake word with Kokoro's af_heart: the keyword spotter's detection of that synthetic "Jarvis" is the measured
# baseline; the commands use the configured voice chain (the online neural voice when it is reachable).
"$CTL" --synthesize "Jarvis," --output "$OUT/wake-en.wav" --language en --engine kokoro >/dev/null
echo "name              | wake | heard                                    | tools                      | total ms | ok"
echo "------------------+------+------------------------------------------+----------------------------+----------+---"
pass=0; total=0
while IFS='|' read -r lang text name expected; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  "$CTL" --synthesize "$text" --output "$OUT/cmd-$name.wav" --language "$lang" >/dev/null
  python3 -I - "$OUT/wake-en.wav" "$OUT/cmd-$name.wav" "$OUT/jarvis-$name.wav" <<'PY'
import sys, wave
def read(p):
    w = wave.open(p); r = w.getframerate(); d = w.readframes(w.getnframes()); w.close(); return r, d
rate, wake = read(sys.argv[1]); r2, cmd = read(sys.argv[2])
if r2 != rate:  # a phrase voiced by a fallback engine (Piper is 22.05 kHz): linear resampling is enough here
    import array
    src = array.array("h", cmd); n = int(len(src) * rate / r2); out = array.array("h", [0]) * n
    for i in range(n):
        x = i * r2 / rate; j = int(x); f = x - j; a = src[min(j, len(src) - 1)]; b = src[min(j + 1, len(src) - 1)]
        out[i] = int(a + (b - a) * f)
    cmd = out.tobytes()
gap = b"\x00\x00" * int(0.25 * rate)
w = wave.open(sys.argv[3], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(wake + gap + cmd); w.close()
PY
  json=$("$CTL" --voice "$OUT/jarvis-$name.wav" --json 2>/dev/null || true)
  # The keyword spotter is tuned for people, not for a 1 s synthesised clip; one retry keeps a flaky detection from
  # masking the rest of the pipeline. The table says when the second attempt was needed.
  for _attempt in 1 2; do
    printf '%s' "$json" | grep -q '"status":"no_wake_word"' || break
    sleep 2
    json=$("$CTL" --voice "$OUT/jarvis-$name.wav" --json 2>/dev/null || true)
    json=$(printf '%s' "$json" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); d.setdefault("data",{})["retried"]=True; print(json.dumps(d))' 2>/dev/null || printf '%s' "$json")
  done
  line=$(printf '%s' "$json" | python3 -I -c '
import json, sys
name, expected = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    print(f"{name:<17} | ?    | (no response)                            |                            |          | no"); sys.exit(1)
x = d.get("data") or {}
wake = ("2nd" if x.get("retried") else "yes") if x.get("wake_word_detected") else "no"
heard = (x.get("heard") or "")[:40]
tools = ",".join(r.get("tool", "") for r in d.get("results", []))[:26]
ms = (x.get("latency") or {}).get("totalMs", "")
ok = d.get("success") and (expected == "-" or expected in tools)
print(f"{name:<17} | {wake:<4} | {heard:<40} | {tools:<26} | {str(ms):>8} | {"yes" if ok else "no"}")
sys.exit(0 if ok else 1)
' "$name" "$expected") && pass=$((pass + 1)) || true
  echo "$line"
  # Give the conversation window time to close before the next wake word.
  sleep 2
done <<< "$CORPUS"
echo
echo "$pass / $total scenarios passed"
[ "$pass" -eq "$total" ]
