#!/bin/bash
# Cross-compile hellotest for the TouchPad. Run inside WSL (Ubuntu).
set -e
cd "$(dirname "$0")"

TOOLCHAIN_BIN="$HOME/linaro-toolchain/bin"
PDK="/mnt/c/Program Files (x86)/HP webOS/PDK"
CC="$TOOLCHAIN_BIN/arm-linux-gnueabi-gcc"

CFLAGS="-O2 -mcpu=cortex-a8 -mfpu=neon -mfloat-abi=softfp"
CFLAGS="$CFLAGS -D__webos__ -DLINUX -Wall -fsigned-char -D_GNU_SOURCE=1 -D_REENTRANT"

# Quotes matter: the PDK path contains spaces and parentheses.
"$CC" $CFLAGS \
    -I"$PDK/include" -I"$PDK/include/SDL" \
    src/main.c \
    -L"$PDK/device/lib" -Wl,-rpath-link,"$PDK/device/lib" \
    -lSDL -lpdl -lm \
    -o package/hellotest

echo "Built package/hellotest"
file package/hellotest
"$TOOLCHAIN_BIN/arm-linux-gnueabi-readelf" -d package/hellotest | grep NEEDED
