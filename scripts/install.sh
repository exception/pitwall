#!/bin/zsh
# Copies the latest Debug build into /Applications so Pitwall opens from
# Launchpad, Spotlight and the Dock. Quit Pitwall first; sessions survive.
set -e
cd "${0:A:h}/.."
SRC=build/dd/Build/Products/Debug/Pitwall.app
[[ -d $SRC ]] || { echo "Build first: xcodebuild -project Pitwall.xcodeproj -scheme Pitwall -configuration Debug -derivedDataPath build/dd build"; exit 1; }
if pgrep -qf "/Applications/Pitwall.app/Contents/MacOS/Pitwall"; then echo "Quit Pitwall (⌘Q) first."; exit 1; fi
rm -rf /Applications/Pitwall.app.new
ditto $SRC /Applications/Pitwall.app.new
rm -rf /Applications/Pitwall.app
mv /Applications/Pitwall.app.new /Applications/Pitwall.app
echo "Installed /Applications/Pitwall.app"
