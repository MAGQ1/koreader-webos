#!/bin/bash
# Build KOReader for the TouchPad (run inside WSL).
#
#   webos/build.sh            apply the overlay, build, check the result against the device's glibc
#   JOBS=8 webos/build.sh     more parallel jobs (default 4: all cores can exhaust memory on this PC)
#
# Then run webos/package.sh, and webos/install.ps1 from Windows.
set -e

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(dirname "$HERE")
KO=${KO:-$HOME/koreader}
TC=$HOME/x-tools/arm-webos-linux-gnueabi
JOBS=${JOBS:-4}
GLIBC_MAX=2.8      # what the TouchPad's glibc provides (webOS 3.0.5 and CE 3.1.0)

# Clean PATH: WSL adds Windows folders with spaces, which break some build tools.
export PATH=$TC/bin:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset LD_LIBRARY_PATH CFLAGS CXXFLAGS LDFLAGS

need_version() { # <name> <have> <want>
    if [ "$(printf '%s\n%s\n' "$3" "$2" | sort -V | head -1)" != "$3" ]; then
        echo "error: $1 $2 is too old (need >= $3). See CLAUDE.md, 'Build tool versions needed'."; exit 1
    fi
}
[ -x "$TC/bin/arm-webos-linux-gnueabi-gcc" ] || { echo "error: cross-toolchain missing at $TC (run toolchain/build-webos-toolchain.sh)"; exit 1; }
need_version meson "$(meson --version)" 1.2
need_version ninja "$(ninja --version | cut -d. -f1-3)" 1.13
need_version make "$(make --version | head -1 | grep -o '[0-9][0-9.]*$')" 4.4

echo "== overlay"
bash "$PROJ/overlay/apply.sh" "$KO"

echo "== build (TARGET=webos, $JOBS jobs)"
cd "$KO"
make TARGET=webos PARALLEL_JOBS="$JOBS" all

echo "== glibc check (device has $GLIBC_MAX)"
OUT=$KO/base/build/arm-webos-linux-gnueabi
READELF=$TC/bin/arm-webos-linux-gnueabi-readelf
bad=0
while read -r f; do
    for v in $($READELF -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -u); do
        if [ "$(printf '%s\n%s\n' "${v#GLIBC_}" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]; then
            echo "   TOO NEW: $(basename "$f") needs $v"; bad=1
        fi
    done
done < <(find "$OUT/libs" "$OUT/luajit" -maxdepth 1 -type f ! -name '*.dbg' \( -name '*.so*' -o -name luajit \))
if [ $bad -ne 0 ]; then
    echo "error: some files need a newer glibc than the TouchPad has: they would fail to load on the device."
    echo "       Usually a new 'LEGACY OR POCKETBOOK' style workaround in KOReader that needs 'OR WEBOS' (see overlay/transforms.py)."
    exit 1
fi
echo "   all files need glibc <= $GLIBC_MAX"
echo "== built. Next: webos/package.sh (WSL), then webos/install.ps1 (PowerShell)."
