#!/bin/zsh
# Build KeyStats via Xcode (not xcodebuild), copy to /tmp/ksverify, embed the
# helper from the installed app so its cdhash (and TCC grant) is unchanged,
# ad-hoc re-sign the outer app, quit the running KeyStats and launch the copy.
set -euo pipefail
WORK=/tmp/ksverify
INSTALLED=/Applications/KeyStats.app
mkdir -p $WORK

result=$(osascript <<OSA
tell application "Xcode"
  set ws to workspace document "KeyStats.xcodeproj"
  set r to build ws
  repeat until completed of r
    delay 1
  end repeat
  return (status of r as string) & "|" & (error message of r as string)
end tell
OSA
)
echo "xcode build: $result"
[[ $result == succeeded* ]] || exit 1

BUILT=$(ls -td ~/Library/Developer/Xcode/DerivedData/KeyStats-*/Build/Products/Debug/KeyStats.app | head -1)
osascript -e 'tell application id "com.keystats.app" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do pgrep -f "KeyStats.app/Contents/MacOS/KeyStats$" >/dev/null || break; sleep 0.25; done

rm -rf $WORK/KeyStats.app
cp -R $BUILT $WORK/KeyStats.app
rm -rf $WORK/KeyStats.app/Contents/Resources/KeyStatsHelper.app
cp -R $INSTALLED/Contents/Resources/KeyStatsHelper.app $WORK/KeyStats.app/Contents/Resources/
codesign -d --entitlements :- $BUILT > $WORK/ent.plist 2>/dev/null
codesign --force --sign - --entitlements $WORK/ent.plist $WORK/KeyStats.app
codesign --verify --strict $WORK/KeyStats.app

open $WORK/KeyStats.app
for i in {1..40}; do pgrep -f "$WORK/KeyStats.app" >/dev/null && break; sleep 0.25; done
sleep 2
echo "running: $(pgrep -lf "$WORK/KeyStats.app")"
echo "installed helper cdhash: $(codesign -dvvv ~/Library/Application\ Support/KeyStats/Helper/KeyStatsHelper.app 2>&1 | grep ^CDHash)"
