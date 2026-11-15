#!/bin/zsh
# Drives an isolated Pitwall instance end to end and captures screenshots.
# Never touches your real boards or sessions: everything lives in PITWALL_HOME.
#
#   scripts/ui-test.sh            # run all scenarios
#   scripts/ui-test.sh restore    # run one
#
# Screenshots land in build/ui-test/<scenario>-*.png. A scenario fails if a
# check fails; the script exits non-zero if any did.
set -u
cd "${0:A:h}/.."
APP=build/dd/Build/Products/Debug/Pitwall.app
H=$APP/Contents/Helpers/pitwall
export PITWALL_HOME=$PWD/build/ui-test/home
OUT=build/ui-test
FAILED=0
mkdir -p $OUT

[[ -x build/widpid ]] || swiftc -O - -o build/widpid <<'SW'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 { print(w[kCGWindowNumber as String] as! Int); break }
SW

[[ -x build/greenpx ]] || swiftc -O scripts/greenpx.swift -o build/greenpx 2>/dev/null

start_app() { ($APP/Contents/MacOS/Pitwall >$OUT/app.log 2>&1 &); sleep 4; PID=$(pgrep -nf "MacOS/Pitwall"); }
stop_app() { kill $PID 2>/dev/null; sleep 1.2; }
shot() { screencapture -x -o -l $(build/widpid $PID) $OUT/$1.png; }
reset() {
  [[ -S $PITWALL_HOME/run/daemon.sock ]] && echo '{"op":"shutdown"}' | nc -U $PITWALL_HOME/run/daemon.sock >/dev/null 2>&1
  rm -rf $PITWALL_HOME; sleep 0.3
}
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; FAILED=1; fi }
tile_field() { $H tile list | python3 -c "import json,sys; print(next((t.get('$2') or '') for t in json.load(sys.stdin) if t['id']=='$1'))"; }

scenario_restore() {
  echo "restore: sessions survive an app restart with exact screen state"
  reset; start_app
  S=$($H tile new --cwd $PWD --title "Restore")
  sleep 2; $H tile send $S $'for i in 1 2 3; do printf "\\e[3%sm row %s\\e[0m\\n" $i $i; done; export MARK=$$\n'; sleep 1.5
  shot restore-before; stop_app; start_app; sleep 1; shot restore-after
  $H tile send $S $'echo "mark=$MARK pid=$$"\n'; sleep 1
  local txt=$($H tile read $S --bytes 2000)
  check "shell process survived" '[[ $txt =~ "mark=([0-9]+) pid=\\1" ]] || echo "$txt" | grep -Eq "mark=([0-9]+) pid=\1"'
  check "colored rows restored" 'echo "$txt" | grep -q " row 3"'
  stop_app
}

scenario_zoom() {
  echo "zoom: terminal grid never changes while zooming"
  reset; start_app
  S=$($H tile new --cwd $PWD --title "Zoom"); sleep 2
  $H tile send $S $'echo BEFORE $(stty size)\n'; sleep 1
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" \
    -e 'delay 0.3' -e 'tell application "System Events"' -e 'repeat 4 times' -e 'keystroke "-" using command down' -e 'delay 0.1' -e 'end repeat' \
    -e 'repeat 5 times' -e 'keystroke "=" using command down' -e 'delay 0.1' -e 'end repeat' -e 'end tell' >/dev/null
  sleep 1; shot zoom
  $H tile send $S $'echo AFTER $(stty size)\n'; sleep 1
  local txt=$($H tile read $S --bytes 2000)
  local b=$(echo "$txt" | grep -a '^BEFORE' | tail -1 | cut -d' ' -f2-) a=$(echo "$txt" | grep -a '^AFTER' | tail -1 | cut -d' ' -f2-)
  check "grid $b == $a" '[[ -n "$b" && "$b" == "$a" ]]'
  stop_app
}

scenario_status() {
  echo "status: hook events drive agent state, sub-agents and attention"
  reset; start_app
  A=$($H tile new --title "Agent" -- python3 -c 'import time; time.sleep(600)'); sleep 1
  echo '{"prompt":"Fix the flaky login test"}' | PITWALL_TILE_ID=$A $H hook UserPromptSubmit
  echo '{"tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"Find causes","subagent_type":"Explore"}}' | PITWALL_TILE_ID=$A $H hook PreToolUse
  echo '{"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}' | PITWALL_TILE_ID=$A $H hook Notification
  sleep 1.5; shot status
  check "agent is waiting" '[[ $(tile_field $A state) == waiting ]]'
  check "sub-agent tile exists" '$H tile list | grep -q subagent'
  echo '{"last_assistant_message":"Fixed it."}' | PITWALL_TILE_ID=$A $H hook Stop; sleep 0.5
  check "agent is done after Stop" '[[ $(tile_field $A state) == done || $(tile_field $A state) == idle ]]'
  stop_app
}

scenario_fullscreen() {
  echo "fullscreen: a tile fills the window at 100% and restores its grid"
  reset; start_app
  S=$($H tile new --cwd $PWD --title "Full"); sleep 2
  $H tile send $S $'echo G1 $(stty size)\n'; sleep 0.8
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" -e 'delay 0.3' \
    -e 'tell application "System Events" to keystroke "f" using {command down, shift down}' >/dev/null; sleep 1
  $H tile send $S $'echo G2 $(stty size)\n'; sleep 0.8; shot fullscreen
  osascript -e 'tell application "System Events" to keystroke "f" using {command down, shift down}' >/dev/null; sleep 1
  $H tile send $S $'echo G3 $(stty size)\n'; sleep 0.8
  local txt=$($H tile read $S --bytes 3000)
  local g1=$(echo "$txt" | grep -a '^G1' | tail -1) g2=$(echo "$txt" | grep -a '^G2' | tail -1) g3=$(echo "$txt" | grep -a '^G3' | tail -1)
  check "full screen grid is bigger ($g1 → $g2)" '[[ "${g1#G1 }" != "${g2#G2 }" ]]'
  check "grid restored after exit ($g3)" '[[ "${g1#G1 }" == "${g3#G3 }" ]]'
  stop_app
}

scenario_approvals() {
  echo "approvals: a PermissionRequest waits for a decision made in the Inbox"
  reset; start_app
  A=$($H tile new --title "Agent" -- python3 -c 'import time; time.sleep(600)'); sleep 1
  ( echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo:*"}],"behavior":"allow","destination":"session"}]}' \
      | PITWALL_TILE_ID=$A $H hook PermissionRequest > $OUT/approve-out.json ) &
  sleep 1.2
  check "agent waits for approval" '[[ $(tile_field $A state) == waiting ]]'
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" -e 'delay 0.3' \
    -e 'tell application "System Events" to keystroke "i" using command down' -e 'delay 0.6' -e 'tell application "System Events" to keystroke "A" using shift down' >/dev/null
  sleep 1.5; shot approvals
  check "hook returned allow + persistent rule" 'grep -q "\"behavior\":\"allow\"" $OUT/approve-out.json && grep -q localSettings $OUT/approve-out.json'
  check "agent resumed" '[[ $(tile_field $A state) == working ]]'
  stop_app
}

scenario_handoff() {
  echo "handoff: closing a linked tile leaves no stray line or arrowhead"
  reset; start_app
  A=$($H tile new --cwd $PWD --title "Up"); B=$($H tile new --cwd $PWD --title "Down"); sleep 1.5
  $H link $A $B --handoff; PITWALL_TILE_ID=$A $H status working "Building"; sleep 1.5; shot handoff-linked
  $H tile close $B; sleep 1; shot handoff-closed
  # No arrowhead-green pixels should remain once the downstream tile is gone.
  local n=$(build/greenpx $OUT/handoff-closed.png 930 780 1100 880)
  local n0=$(build/greenpx $OUT/handoff-linked.png 930 780 1100 880)
  check "arrowhead drawn while linked ($n0 green px)" '(( n0 >= 50 ))'
  check "no link remnants after close ($n green px)" '(( n < 20 ))'
  stop_app
}

if (( $# )); then scenarios=("$@"); else scenarios=(restore zoom status fullscreen approvals handoff); fi
for s in $scenarios; do scenario_$s; done
reset
echo; [[ $FAILED == 0 ]] && echo "All UI scenarios passed. Screenshots: $OUT/" || { echo "Some UI scenarios FAILED. See $OUT/"; exit 1; }
