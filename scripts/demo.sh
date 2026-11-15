#!/bin/zsh
# Stages a realistic demo board in an isolated Pitwall (for README
# screenshots and the video). Runs real Claude Code agents on a throwaway
# repo in build/demo/trackside. Never touches your real boards.
set -u
cd "${0:A:h}/.."
APP=build/dd/Build/Products/Debug/Pitwall.app
H=$APP/Contents/Helpers/pitwall
export PITWALL_HOME=$PWD/build/demo/home
# Run from inside Pitwall, the shell carries the live app's socket and tile:
# drop them, or the helper would drive the real app instead of this one.
unset PITWALL_SOCKET PITWALL_TILE_ID PITWALL_BOARD_ID PITWALL_SESSION_ID PITWALL_CLI
DEMO=$PWD/build/demo/trackside
[[ -S $PITWALL_HOME/run/daemon.sock ]] && echo '{"op":"shutdown"}' | nc -U $PITWALL_HOME/run/daemon.sock >/dev/null 2>&1
rm -rf $PITWALL_HOME; sleep 0.3
( cd $DEMO && git worktree prune && git branch --list 'pitwall/*' | xargs -n1 git branch -D >/dev/null 2>&1; rm -rf ../trackside-worktrees ) 2>/dev/null
($APP/Contents/MacOS/Pitwall >build/demo/app.log 2>&1 &); sleep 4
PID=$(pgrep -nf "build/dd/Build/Products/Debug/Pitwall.app/Contents/MacOS/Pitwall")
echo $PID > build/demo/pid

$H board new "Trackside" --root $DEMO >/dev/null
$H board new "Docs site" >/dev/null
$H board new "Infra" >/dev/null
$H board switch "Trackside" >/dev/null

A1=$($H agent --cwd $DEMO --worktree "The bestLap test is failing. Find the bug in src/laps.js, fix it, and run npm test to confirm.")
A2=$($H agent --cwd $DEMO --worktree "Add a --json flag to src/cli.js that prints the lap summary as JSON. Keep the text output as the default.")
A3=$($H agent --cwd $DEMO --worktree "Write a concise README.md for this project: what it does, the CLI usage, and how to run the dev server.")
echo "agents: $A1 $A2 $A3"
echo "$A1 $A2 $A3" > build/demo/agents

# New worktrees ask Claude Code's folder-trust question; answer "Yes".
sleep 6
for a in $A1 $A2 $A3; do $H tile key $a down return; sleep 0.3; done

tf() { $H tile list | python3 -c "import json,sys; print(next((t.get('$2') or '') for t in json.load(sys.stdin) if t['id']=='$1'))"; }
wait_done() { for i in $(seq 1 90); do s=$(tf $1 state); [[ $s == done || $s == waiting ]] && return; sleep 2; done; }
for a in $A1 $A2 $A3; do wait_done $a; done

# Two more: one that will likely ask permission (git commit), one long-running.
A4=$($H agent --cwd $DEMO --worktree "Add a GitHub Actions workflow that runs npm test on pushes and pull requests, then commit it with a clear message.")
A5=$($H agent --cwd $DEMO --worktree "Add per-stint statistics (laps, best, average) to the CLI output, with tests for the new helper in src/laps.js.")
sleep 6
for a in $A4 $A5; do $H tile key $a down return; sleep 0.3; done

# Supporting tiles.
W=$($H watch --cwd "$(tf $A1 cwd)" -- npm test)
D=$($H diff "$(tf $A2 cwd)")
S=$($H server --cwd $DEMO -- npm run dev)
sleep 6
B=$($H tile list | python3 -c "import json,sys; print(next(t['id'] for t in json.load(sys.stdin) if t['kind']=='browser'))")
$H link $A1 $W >/dev/null; $H link $A2 $A3 --handoff >/dev/null

# Layout (world points).
$H tile move $A1 0 70;    $H tile move $W 0 640
$H tile move $A4 790 70;  $H tile move $A5 790 640
$H tile move $A2 1580 70; $H tile move $D 1580 640
$H tile move $A3 2370 70
$H tile move $S 3160 70;  $H tile move $B 3160 600
F1=$($H frame new --title "Fix the failing test" $A1 $W)
F2=$($H frame new --title "CI + stints" $A4 $A5)
F3=$($H frame new --title "CLI: --json" $A2 $D $A3)
F4=$($H frame new --title "Dev server" $S $B)
echo "A4=$A4 A5=$A5 W=$W D=$D S=$S B=$B"
echo "$A1 $A2 $A3 $A4 $A5 $W $D $S $B $F1 $F2 $F3 $F4" > build/demo/ids
