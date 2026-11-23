#!/bin/zsh
# Quit the test build and relaunch the installed KeyStats.
osascript -e 'tell application id "com.keystats.app" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do pgrep -f "KeyStats.app/Contents/MacOS/KeyStats$" >/dev/null || break; sleep 0.25; done
open /Applications/KeyStats.app
sleep 2
pgrep -lf "KeyStats.app/Contents/MacOS/KeyStats$"
