#!/bin/bash
# Move the KOReader checkout to another KOReader release and re-apply the webOS overlay (run inside WSL).
#
#   webos/update-koreader.sh v2026.09          switch to that release tag and re-apply the overlay
#   webos/update-koreader.sh v2026.09 --build  ...and build it too (then package.sh / install.ps1)
#   KO=~/some-other-checkout webos/update-koreader.sh master     try a checkout other than ~/koreader
#
# Everything we change lives in overlay/, so the checkout itself can be reset freely: any local edit
# made directly in it (outside overlay/) is thrown away here. If overlay/transforms.py reports FAILED,
# KOReader changed something we depend on: fix that edit (it says which), then run this again.
set -e

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(dirname "$HERE")
KO=${KO:-$HOME/koreader}
REF=${1:?usage: update-koreader.sh <tag-or-branch> [--build]}
BUILD=${2:-}

[ -d "$KO/.git" ] || { echo "error: $KO is not a KOReader git checkout"; exit 1; }
cd "$KO"

echo "== current: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
echo "== fetching $REF"
if git ls-remote --exit-code --tags origin "$REF" >/dev/null 2>&1; then
    git fetch --depth 1 origin tag "$REF"
    TARGET_REF="refs/tags/$REF"
else
    git fetch --depth 1 origin "$REF"
    TARGET_REF=FETCH_HEAD
fi

echo "== switching (resetting files the overlay edited)"
git submodule foreach --quiet 'git checkout -q -f -- . 2>/dev/null || true'
git checkout -q -f "$TARGET_REF"
echo "== submodules (koreader-base, fonts, translations; shallow)"
git submodule sync --quiet
git submodule update --init --force --depth 1 --jobs 3 base resources/fonts l10n

echo "== now at: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
bash "$PROJ/overlay/apply.sh" "$KO"

if [ "$BUILD" = "--build" ]; then
    bash "$HERE/build.sh"
else
    echo "== overlay applied. Build with webos/build.sh (about 15 minutes from scratch), then package.sh / install.ps1."
    echo "   Remember to raise \"version\" in webos/appinfo.json so the tablet accepts it as an upgrade."
fi
