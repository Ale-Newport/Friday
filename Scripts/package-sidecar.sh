#!/usr/bin/env bash
# Builds the Python sidecar (browser agent + Laya) into Sidecar/dist/jarvis-backend (a PyInstaller onedir folder) and
# smoke-tests it. The Release build phase (Scripts/embed-engine-files.sh) copies that folder into Friday.app.
# Adapted from the Jarvis project's scripts/package-backend.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Sidecar"
echo "▸ Building the sidecar with PyInstaller…"
uv sync --quiet
uv run pyinstaller --noconfirm --clean --distpath "$ROOT/Sidecar/build/dist" --workpath "$ROOT/Sidecar/build/work" jarvis-backend.spec
DEST="$ROOT/Sidecar/dist"
rm -rf "$DEST/jarvis-backend"
mkdir -p "$DEST"
cp -R "$ROOT/Sidecar/build/dist/jarvis-backend" "$DEST/jarvis-backend"
echo "▸ Making the bundle copy-safe (no symlinks, so MLX is not loaded twice)…"
INTERNAL="$DEST/jarvis-backend/_internal"
if [ -d "$INTERNAL/mlx/lib" ]; then
  rm -f "$INTERNAL/libmlx.dylib" "$INTERNAL/libjaccl.dylib"
  for core in "$INTERNAL"/mlx/core.cpython-*.so; do install_name_tool -add_rpath @loader_path/lib "$core" 2>/dev/null || true; codesign --force --sign - "$core" >/dev/null 2>&1; done
  install_name_tool -add_rpath @loader_path "$INTERNAL/mlx/lib/libmlx.dylib" 2>/dev/null || true
  codesign --force --sign - "$INTERNAL/mlx/lib/libmlx.dylib" "$INTERNAL/mlx/lib/libjaccl.dylib" >/dev/null 2>&1 || true
fi
if [ -n "$(find "$DEST/jarvis-backend" -type l)" ]; then echo "error: the bundle still contains symlinks:"; find "$DEST/jarvis-backend" -type l; exit 1; fi
echo "▸ Smoke-testing the packaged sidecar…"
TOKEN="$(openssl rand -hex 16)"
DATA="$(mktemp -d)"
FRIDAY_TOKEN="$TOKEN" FRIDAY_DATA_DIR="$DATA" "$DEST/jarvis-backend/jarvis-backend" > "$DATA/out.txt" 2> "$DATA/err.txt" &
PID=$!
for _ in $(seq 1 120); do grep -q '"event": "ready"' "$DATA/out.txt" 2>/dev/null && break; kill -0 $PID 2>/dev/null || { cat "$DATA/err.txt"; echo "sidecar exited early"; exit 1; }; sleep 0.5; done
PORT="$(python3 -c "import json,sys; print(json.loads(open('$DATA/out.txt').readline())['port'])")"
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null
curl -fsS -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/route/categories" >/dev/null && echo "  routing endpoint ok"
LAYA="$(curl -fsS -X POST -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/laya/load")"
echo "$LAYA" | python3 -c "
import json,sys
s=json.load(sys.stdin)
if s['downloaded'] and s['state']!='ready': sys.exit('Laya failed to load inside the bundle: '+str(s))
print('  laya:', s['state'], '(load', s['load_ms'], 'ms, warm', s['warm_ms'], 'ms)' if s['load_ms'] else '(model not downloaded; skipped)')"
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/shutdown" >/dev/null
wait $PID && echo "  clean shutdown ✓"
rm -rf "$DATA"
echo "▸ Sidecar ready at $DEST/jarvis-backend ($(du -sh "$DEST/jarvis-backend" | cut -f1))"
