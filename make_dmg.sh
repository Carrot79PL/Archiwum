#!/bin/zsh
set -e
cd "$(dirname "$0")"
./build.sh
STAGE=${TMPDIR:-/tmp}/archiwum-dmg; rm -rf $STAGE; mkdir -p $STAGE
ditto --noextattr --noqtn --norsrc Archiwum.app $STAGE/Archiwum.app
ln -s /Applications $STAGE/Applications
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist); OUT="../Releases/Archiwum-$VERSION.dmg"; mkdir -p ../Releases; rm -f "$OUT"
hdiutil create -volname "Archiwum" -srcfolder $STAGE -ov -format UDZO "$OUT" >/dev/null
echo "DMG: $OUT"
