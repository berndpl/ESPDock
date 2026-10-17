#!/bin/zsh
# macOS audit runner for ESPDock (the audit skill has no macOS backend).
#
# Drives the Debug build with real input: CGEvent clicks/hover via
# .audit/mouse.swift, keys via System Events. Every still composites ONLY
# ESPDock's own windows (main window + any menu/popover) onto a neutral
# backdrop, and flow videos record the main window alone, so nothing else on
# screen is ever captured. Writes the backend-neutral manifest that
# ~/.copilot/skills/audit/generate_scenario_report.py turns into the gallery.
#
# Limitation: window-only video keeps the window's starting size, so the
# serial-monitor flow video shows the left 520 pt; the stills show it all.
#
# Needs: a connected XIAO ESP32S3, Accessibility + Screen Recording for the
# terminal, ffmpeg. Output goes to the Progress folder, never the repo.
#
#   zsh .audit/run_macos_audit.sh
set -uo pipefail   # no -e: a failed step is a finding, not an abort

REPO=${0:A:h:h}
APP="$REPO/build/DerivedData/Build/Products/Debug/ESPDock.app"
PLAN="$REPO/.audit/audit-scenarios.json"
TS=$(date +%Y%m%d_%H%M%S)
OUT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Sparks/Screenshots/Progress/ESPDock/scenarios-$TS"
TOOLS="${TMPDIR:-/tmp}/espdock-audit-tools"
DEV=mac
START=$(date +%s)
mkdir -p "$OUT"/{screenshots,videos} "$TOOLS/tmp"

M="$TOOLS/mouse"
if [[ ! -x "$M" || "$REPO/.audit/mouse.swift" -nt "$M" ]]; then
  swiftc -O "$REPO/.audit/mouse.swift" -o "$M" || exit 1
fi

# --- helpers ---------------------------------------------------------------
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
key() {  # text [modifiers]
  local using=""; [[ -n "${2:-}" ]] && using=" using {$2}"
  osascript -e "tell application \"System Events\" to keystroke \"$1\"$using" >/dev/null
}
keycode() { osascript -e "tell application \"System Events\" to key code $1" >/dev/null; }
# Re-opening the bundle raises the running instance; System Events'
# `frontmost` didn't, so other windows covered it and swallowed hovers.
front() { open "$APP"; sleep 0.6; }

# Center ("x y") of the first element in the main window matching role
# [+ description | value]. The list must go through a variable: iterating
# `entire contents` inline silently yields nothing.
find_center() {  # role [description] [value]
  osascript - "$1" "${2:-}" "${3:-}" <<'AS' | tr -d ','
on run argv
  set {r, d, v} to argv
  tell application "System Events" to tell process "ESPDock"
    set els to entire contents of window "ESPDock"
    repeat with e in els
      try
        if role of e is r then
          set ok to true
          if d is not "" and (description of e as text) is not d then set ok to false
          if v is not "" and (value of e as text) is not v then set ok to false
          if ok then
            set p to position of e
            set s to size of e
            return ((item 1 of p) + (item 1 of s) / 2 as integer) & " " & ((item 2 of p) + (item 2 of s) / 2 as integer)
          end if
        end if
      end try
    end repeat
  end tell
  return ""
end run
AS
}
click_el() { local c; c=$(find_center "$@"); [[ -n "$c" ]] || { echo "  ! not found: $*"; return 1; }; $M click ${=c}; }

launch() {
  pkill -f "Debug/ESPDock.app" 2>/dev/null; sleep 1
  open -n "$APP" --args "$@"; sleep 3
  front
}

typeset -A STATUS SHOT TSTAMP
MANIFEST_SCN=()
# Composite every ESPDock window (back to front) onto a neutral canvas sized
# to their union, so menus/popovers are included and nothing else is.
capture() {  # scenario moment
  local f="screenshots/$1__$2__$DEV.png" ux uy uw uh scale="" inputs=() filter="" i=0 prev id x y w h
  read -r ux uy uw uh <<< "$($M union)"
  rm -f "$TOOLS"/tmp/w*.png
  while read -r id x y w h; do
    screencapture -x -o -l "$id" "$TOOLS/tmp/w$i.png"
    [[ -z "$scale" ]] && scale=$(( $(sips -g pixelWidth "$TOOLS/tmp/w$i.png" | awk '/pixelWidth/{print $2}') / w ))
    inputs+=(-i "$TOOLS/tmp/w$i.png")
    if (( i == 0 )); then prev="[0:v]"; else prev="[c$i]"; fi
    filter+="${prev}[$((i + 1)):v]overlay=$(( (x - ux) * scale )):$(( (y - uy) * scale ))[c$((i + 1))];"
    i=$((i + 1))
  done <<< "$($M list)"
  ffmpeg -y -v error -f lavfi -i "color=c=0xE9E9EC:s=$((uw * scale))x$((uh * scale))" "${inputs[@]}" \
    -filter_complex "${filter%;}" -map "[c$i]" -frames:v 1 "$OUT/$f"
  TSTAMP[$1/$2]=$(now_ms); SHOT[$1/$2]=$f
  [[ -s "$OUT/$f" ]] && STATUS[$1/$2]=pass || STATUS[$1/$2]=fail
  echo "  ${STATUS[$1/$2]} $1/$2"
}
fail() { STATUS[$1/$2]=fail; echo "  ✗ $1/$2: $3"; }
REC_PID=""; REC_START=""
record() {  # scenario seconds — main window only
  local id; read -r id _ <<< "$($M win)"
  REC_START=$(now_ms)
  screencapture -x -o -V "$2" -l "$id" "$OUT/videos/$1__$DEV.mov" &
  REC_PID=$!; sleep 0.8
}
finish() {  # scenario — wait for the recording, convert, add manifest entry
  [[ -n "$REC_PID" ]] && wait "$REC_PID" 2>/dev/null
  local video=""
  if [[ -s "$OUT/videos/$1__$DEV.mov" ]]; then
    ffmpeg -y -v error -i "$OUT/videos/$1__$DEV.mov" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
      -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT/videos/$1__$DEV.mp4" \
      && rm "$OUT/videos/$1__$DEV.mov" && video="videos/$1__$DEV.mp4"
  fi
  MANIFEST_SCN+=("$1|$video|${REC_START:-}")
  REC_PID=""; REC_START=""
}
window_width() { local w; read -r _ _ _ w _ <<< "$($M win)"; echo "$w"; }

# --- scenarios ------------------------------------------------------------
echo "▶ serialMonitor"
launch
record serialMonitor 16
capture serialMonitor launch
click_el AXButton "Serial Monitor"; sleep 1.5
capture serialMonitor monitorOpen
[[ $(window_width) -gt 600 ]] || fail serialMonitor monitorOpen "window did not widen"
click_el AXTextField && { sleep 0.3; key "ESPDOCK?"; keycode 36; sleep 2; }
capture serialMonitor queried
click_el AXCheckBox Pause; sleep 1
capture serialMonitor paused
click_el AXButton "Serial Monitor"; sleep 1.5
capture serialMonitor monitorClosed
[[ $(window_width) -lt 600 ]] || fail serialMonitor monitorClosed "window did not narrow"
finish serialMonitor

echo "▶ pinout"
launch
record pinout 14
D4=$(find_center AXStaticText "" D4 | tr -s ' ')
if [[ -n "$D4" ]]; then
  $M move ${=D4}; sleep 0.2; $M move $(( ${D4% *} + 1 )) ${D4#* }; sleep 1.5
  capture pinout hoverPin
  $M click ${=D4}; sleep 0.8
  $M move $(( ${D4% *} + 200 )) $(( ${D4#* } + 200 )); sleep 1.2
  capture pinout pinnedGuide
  keycode 53; sleep 0.5
else
  fail pinout hoverPin "D4 label not found"; fail pinout pinnedGuide "D4 label not found"
fi
read -r _ X Y W H <<< "$($M win)"
$M click $((X + W / 2)) $((Y + H * 62 / 100)); sleep 1.5   # the board art toggles its style
capture pinout blueprint
$M click $((X + W / 2)) $((Y + H * 62 / 100)); sleep 1.5
capture pinout realistic
finish pinout

echo "▶ menus"
launch
record menus 10
click_el AXMenuButton; sleep 1
capture menus projectMenu
keycode 53; sleep 0.5
read -r _ X Y W H <<< "$($M win)"
$M rclick $((X + 300)) $((Y + 110)); sleep 1   # the board card's context menu
capture menus boardMenu
keycode 53; sleep 0.5
finish menus

echo "▶ appWindows"
front
key "," "command down"; sleep 1.5
capture appWindows settings
key "w" "command down"; sleep 0.5
osascript -e 'tell application "System Events" to tell process "ESPDock" to click menu item "About ESPDock" of menu 1 of menu bar item "ESPDock" of menu bar 1' >/dev/null
sleep 1.5
capture appWindows about
key "w" "command down"
MANIFEST_SCN+=("appWindows||")

# --- edge cases (seeded) --------------------------------------------------
echo "▶ edge cases"
launch -auditNoBoard
capture __project__ noBoard
pkill -f "Debug/ESPDock.app"; sleep 1
"$APP/Contents/MacOS/ESPDock" --render-pinout "$OUT/screenshots/__project____darkWindow__$DEV.png" dark
SHOT[__project__/darkWindow]="screenshots/__project____darkWindow__$DEV.png"
[[ -s "$OUT/${SHOT[__project__/darkWindow]}" ]] && STATUS[__project__/darkWindow]=pass || STATUS[__project__/darkWindow]=fail
open -n "$APP"   # leave the app running as found

# --- manifest + report ----------------------------------------------------
python3 - "$PLAN" "$OUT" "$DEV" "${(@kv)STATUS}" -- "${(@kv)SHOT}" -- "${(@kv)TSTAMP}" -- "${MANIFEST_SCN[@]}" <<'PY'
import json, sys
plan, out, dev = sys.argv[1:4]
parts, cur = [], []
for a in sys.argv[4:]:
    if a == "--": parts.append(cur); cur = []
    else: cur.append(a)
parts.append(cur)
kv = lambda l: dict(zip(l[::2], l[1::2]))
status, shot, stamp = kv(parts[0]), kv(parts[1]), kv(parts[2])
p = json.load(open(plan))
scns = []
for entry in parts[3]:
    sid, video, rec = entry.split("|")
    sc = next(s for s in p["scenarios"] if s["id"] == sid)
    moms = []
    for m in sc["moments"]:
        k = f"{sid}/{m['id']}"
        d = {"id": m["id"], "status": status.get(k, "fail")}
        if k in shot: d["screenshot"] = shot[k]
        if k in stamp and rec: d["timestampMs"] = int(stamp[k])
        moms.append(d)
    s = {"id": sid, "device": dev, "moments": moms,
         "status": "pass" if all(m["status"] == "pass" for m in moms) else "fail"}
    if video: s["video"] = video
    if rec: s["recStartMs"] = int(rec)
    scns.append(s)
edges = [{"id": e["id"], "device": dev, "status": status.get(f"__project__/{e['id']}", "fail"),
          **({"screenshot": shot[f"__project__/{e['id']}"]} if f"__project__/{e['id']}" in shot else {})}
         for e in p.get("edgeCases", [])]
json.dump({"platform": "macos", "project": "ESPDock", "devices": [dev],
           "scenarios": scns, "edgeCases": edges}, open(f"{out}/manifest.json", "w"), indent=2)
PY
echo "{\"durationSeconds\": $(( $(date +%s) - START ))}" > "$OUT/meta.json"
python3 ~/.copilot/skills/audit/generate_scenario_report.py "$PLAN" "$OUT" ESPDock
echo "OUT=$OUT"
