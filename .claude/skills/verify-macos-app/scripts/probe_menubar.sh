#!/bin/zsh
# Locate the KeyStats status item via Accessibility and run menubar_probe on it.
# usage: probe_menubar.sh [keys=60] [kps=20] [sampleSeconds=6]
set -euo pipefail
DIR=${0:A:h}
mkdir -p /tmp/ksverify
BIN=/tmp/ksverify/menubar_probe
[[ $BIN -nt $DIR/menubar_probe.swift ]] || swiftc -O $DIR/menubar_probe.swift -o $BIN
frame=$(osascript -e 'tell application "System Events" to tell (first process whose bundle identifier is "com.keystats.app") to get {position, size} of menu bar item 1 of menu bar 2' | tr -d ' ')
IFS=, read x y w h <<< "$frame"
echo "status item frame: $x,$y ${w}x$h"
$BIN $x $y $w $h ${1:-60} ${2:-20} ${3:-6}
