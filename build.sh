#!/bin/zsh
set -e
cd "$(dirname "$0")"
STAGE=${TMPDIR:-/tmp}/archiwum-build
APP=$STAGE/Archiwum.app
chmod -R u+w $STAGE 2>/dev/null || true; rm -rf $STAGE; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -parse-as-library Sources/*.swift -o $APP/Contents/MacOS/Archiwum
cp "$(command -v 7zz || echo /opt/homebrew/bin/7zz)" $APP/Contents/Resources/7zz
cp AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp Info.plist $APP/Contents/Info.plist
chmod -R u+w $APP; xattr -cr $APP
codesign --force --options runtime --entitlements helper.entitlements --identifier pl.local.archiwum.7zz --sign - $APP/Contents/Resources/7zz
codesign --force --options runtime --entitlements app.entitlements --sign - $APP
chmod -R u+w Archiwum.app 2>/dev/null || true; rm -rf Archiwum.app
ditto --noextattr --noqtn --norsrc $APP Archiwum.app
codesign -v Archiwum.app
echo OK
