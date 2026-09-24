#!/bin/bash
# Stage the KOReader webOS app: build/stage/<app-id>/  (then run webos/install.ps1 from Windows to
# turn it into an .ipk and install it, because palm-package is a Windows tool here).
#
# Usage: webos/package.sh            (run inside WSL)
#        INCLUDE_L10N=1 webos/package.sh    also ship the translations (+65 MB)
set -e

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(dirname "$HERE")
KO=${KO:-$HOME/koreader}
TREE=$KO/koreader-webos-arm-webos-linux-gnueabi/koreader
TC=$HOME/x-tools/arm-webos-linux-gnueabi
CC=$TC/bin/arm-webos-linux-gnueabi-gcc
STRIP=$TC/bin/arm-webos-linux-gnueabi-strip

[ -d "$TREE" ] || { echo "error: $TREE not found; build KOReader first (make TARGET=webos all)"; exit 1; }

APPID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/appinfo.json")
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/appinfo.json")
STAGE="$PROJ/build/stage/$APPID"
echo "== staging $APPID $VERSION in $STAGE"

rm -rf "$STAGE"
mkdir -p "$STAGE/koreader"

echo "== launcher"
"$CC" -O2 -Wall -o "$STAGE/webos-launcher" "$HERE/launcher.c" -ldl
"$STRIP" "$STAGE/webos-launcher"

echo "== KOReader tree (symlinks resolved, no debug files)"
EXCLUDES=(--exclude='*.dbg' --exclude='/spec' --exclude='/screenshots' --exclude='/ev_replay.py' --exclude='/tools')
[ "${INCLUDE_L10N:-0}" = 1 ] || EXCLUDES+=(--exclude='/l10n')
rsync -rL --no-perms --no-owner --no-group "${EXCLUDES[@]}" "$TREE/" "$STAGE/koreader/"

echo "== bundled C++ runtime (the device's is from 2008)"
SYS=$TC/arm-webos-linux-gnueabi/sysroot/lib
cp -L "$SYS/libstdc++.so.6" "$SYS/libgcc_s.so.1" "$STAGE/koreader/libs/"

echo "== appinfo + icon"
cp "$HERE/appinfo.json" "$HERE/icon.png" "$STAGE/"

echo "== done"
du -sh "$STAGE"
ls "$STAGE"
