#!/bin/bash
# Build a cross-toolchain for the HP TouchPad: modern GCC + glibc 2.9 sysroot, Cortex-A8/NEON/softfp.
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
unset LD_LIBRARY_PATH CFLAGS CXXFLAGS LDFLAGS

TC=~/tc
cd $TC/CT-NG

# 1. Our recipe: kindle5's Cortex-A8 settings + kindle-legacy's glibc 2.9.
mkdir -p samples/arm-webos-linux-gnueabi
cp samples/arm-kindle5-linux-gnueabi/* samples/arm-webos-linux-gnueabi/ 2>/dev/null || true
cat > samples/arm-webos-linux-gnueabi/crosstool.config <<'EOF'
CT_CONFIG_VERSION="4"
CT_OBSOLETE=y
CT_EXPERIMENTAL=y
CT_STRIP_TARGET_TOOLCHAIN_EXECUTABLES=y
CT_ARCH_ARM=y
CT_ARCH_CPU="cortex-a8"
CT_ARCH_ARM_MODE_ARM=y
CT_ARCH_FPU="neon"
CT_ARCH_FLOAT_SOFTFP=y
CT_TOOLCHAIN_PKGVERSION="webOS KOReader port"
CT_TARGET_VENDOR="webos"
CT_KERNEL_LINUX=y
CT_LINUX_V_2_6_32=y
CT_BINUTILS_LINKER_LD_GOLD=y
CT_BINUTILS_GOLD_THREADS=y
CT_BINUTILS_LD_WRAPPER=y
CT_BINUTILS_PLUGINS=y
CT_GLIBC_V_2_9=y
CT_GLIBC_KERNEL_VERSION_CHOSEN=y
CT_GLIBC_MIN_KERNEL_VERSION="2.6.31"
# CT_CC_GCC_STATIC_LIBSTDCXX is not set
# CT_CC_GCC_USE_GRAPHITE is not set
# CT_CC_GCC_ENABLE_TARGET_OPTSPACE is not set
CT_CC_GCC_LNK_HASH_STYLE_GNU=y
CT_CC_LANG_CXX=y
CT_PARALLEL_JOBS=4
EOF
ls samples/arm-webos-linux-gnueabi

# 2. Build crosstool-NG itself.
if [ ! -x $TC/CT_NG_BUILD/bin/ct-ng ]; then
  ./bootstrap
  mkdir -p $TC/CT_NG_BUILD
  ./configure --prefix=$TC/CT_NG_BUILD
  make -j8
  make install
fi
export PATH=$TC/CT_NG_BUILD/bin:$PATH
ct-ng version | head -1

# ct-ng reads samples from its *installed* copy, so refresh it whenever our recipe changes.
D=$TC/CT_NG_BUILD/share/crosstool-ng/samples
rm -rf "$D/arm-webos-linux-gnueabi"
cp -r samples/arm-webos-linux-gnueabi "$D/"
echo "refreshed recipe in $D"

# 3. Configure and build the toolchain.
mkdir -p $TC/webos && cd $TC/webos
CTNG=(ct-ng curl_silent_opt='' wget_silent_opt='--progress=dot:mega')
"${CTNG[@]}" distclean
"${CTNG[@]}" arm-webos-linux-gnueabi
"${CTNG[@]}" oldconfig
"${CTNG[@]}" upgradeconfig
sed -i 's/^CT_LOG_PROGRESS_BAR=y/CT_LOG_PROGRESS_BAR=n/' .config
grep -E '^CT_(ARCH_CPU|ARCH_FPU|GLIBC_VERSION|LINUX_VERSION|GCC_VERSION|BINUTILS_VERSION|TARGET|PREFIX_DIR)' .config
if grep -q '^CT_ARCH_ARM_MODE_THUMB=y' .config || ! grep -q '^CT_GLIBC_V_2_9=y' .config; then
  echo "ERROR: toolchain settings are not what we asked for (Thumb mode on, or not glibc 2.9)"; exit 1
fi
echo "=== BUILD START $(date)"
nice "${CTNG[@]}" build
echo "=== BUILD DONE $(date)"
