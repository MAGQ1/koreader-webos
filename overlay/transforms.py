#!/usr/bin/env python3
"""
Small edits that make a KOReader checkout know about webOS (HP TouchPad).

Why not plain patch files: upstream moves code around often (targets get added or removed, whole
third-party builds disappear), which breaks line-based patches. These edits find their place by
*meaning* instead, do nothing when already applied (safe to re-run), and stop with a clear message
when something they depend on has gone, so a human can look.

Usage: transforms.py <path-to-koreader-checkout>      exit status 1 if any edit could not be made.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
failed = []


class Missing(Exception):
    """An anchor the edit depends on is gone from upstream."""


def run(name, relpath, edit):
    path = root / relpath
    try:
        if not path.exists():
            raise Missing(f"{relpath} does not exist")
        old = path.read_text()
        new = edit(old)
        if new == old:
            print(f"   already  {name}")
        else:
            path.write_text(new)
            print(f"   applied  {name}")
    except Missing as e:
        print(f"   FAILED   {name}: {e}")
        failed.append(name)


def insert_before(text, pattern, block, what):
    """Insert `block` before the first match of regex `pattern` (multi-line)."""
    m = re.search(pattern, text, re.M)
    if not m:
        raise Missing(f"could not find {what}")
    return text[:m.start()] + block + text[m.start():]


# --------------------------------------------------------------------------------------------------
# base/Makefile.defs: the webOS target itself.
# Model: PocketBook (also Cortex-A8, softfp, glibc 2.9 toolchain, old device glibc).
# --------------------------------------------------------------------------------------------------
TARGET_BLOCK = (
    "else ifeq ($(TARGET), webos)\n"
    "\t# HP TouchPad (webOS 3.x): Cortex-A8, softfp, glibc 2.8 on the device.\n"
    "\tCHOST?=arm-webos-linux-gnueabi\n"
    "\tWEBOS=1\n"
    "\tGLIBC_VERSION_MAX = 2.8\n"
)
FLAGS_BLOCK = (
    "else ifeq ($(TARGET), webos)\n"
    "\t# Same CPU class as the Kindle 4/Touch and PocketBook: Cortex-A8 + NEON, softfp.\n"
    "\t# The TC itself is built in ARM mode (glibc 2.9), our own binaries use Thumb.\n"
    "\t# The device's libstdc++ is far too old, so we bundle ours: no legacy C++ ABI flag needed.\n"
    "\tTARGET_CFLAGS:=$(ARMV7_A8_ARCH)\n"
    "\tTARGET_CFLAGS+=-mfloat-abi=softfp\n"
    "\tCOMPAT_CFLAGS:=$(PB_COMPAT_CFLAGS) $(UBUNTU_COMPAT_CFLAGS)\n"
    "\tCOMPAT_CXXFLAGS:=$(PB_COMPAT_CFLAGS) $(UBUNTU_COMPAT_CFLAGS)\n"
)


def makefile_defs(s):
    if "TARGET), webos)" not in s:
        # 1. toolchain selection: before the remarkable CHOST block
        s = insert_before(s, r"^else ifeq \(\$\(TARGET\), remarkable\)\n\tCHOST\?=", TARGET_BLOCK,
                          "the 'remarkable' toolchain block (where TARGET picks CHOST)")
        # 2. compiler flags: before the kindle flags block
        s = insert_before(s, r"^else ifeq \(\$\(TARGET\), kindle\)\n\tTARGET_CFLAGS:=", FLAGS_BLOCK,
                          "the 'kindle' compiler-flags block")
    if not re.search(r"^set\(WEBOS\b", s, re.M):
        # 3. expose WEBOS to CMake, next to the other platform flags
        m = re.search(r"^set\(POCKETBOOK\s+\$\(POCKETBOOK\)\)\n", s, re.M)
        if not m:
            raise Missing("could not find the 'set(POCKETBOOK ...)' platform flag list")
        s = s[:m.end()] + "set(WEBOS          $(WEBOS))\n" + s[m.end():]
    return s


run("base: TARGET=webos in Makefile.defs", "base/Makefile.defs", makefile_defs)


# --------------------------------------------------------------------------------------------------
# base/thirdparty/cmake_modules/koreader_targets.cmake
#   - build blitbuffer (KOReader's drawing library) for WEBOS;
#   - don't build the evdev input module: touch comes from SDL 1.2 on the Lua side.
# --------------------------------------------------------------------------------------------------
def targets_cmake(s):
    m = re.search(r"(# blitbuffer\nif\()([^\n]*)(\)\n)", s)
    if not m:
        raise Missing("could not find the 'blitbuffer' build condition")
    if "WEBOS" not in m.group(2):
        s = s[:m.start(2)] + m.group(2) + " OR WEBOS" + s[m.end(2):]

    m = re.search(r"if\(ANDROID OR POCKETBOOK OR USE_SDL([^)]*)\)\n(\s+)set\(EXCLUDE_FROM_ALL EXCLUDE_FROM_ALL\)", s)
    if not m:
        raise Missing("could not find the 'koreader-input' exclusion (the list with ANDROID OR POCKETBOOK OR USE_SDL)")
    if "WEBOS" not in m.group(1):
        s = s[:m.start()] + "# webOS reads touch through SDL 1.2 (Lua side), not evdev.\n" \
            + s[m.start():m.start(1)] + m.group(1) + " OR WEBOS" + s[m.end(1):]
    return s


run("base: build lists in koreader_targets.cmake", "base/thirdparty/cmake_modules/koreader_targets.cmake", targets_cmake)


# --------------------------------------------------------------------------------------------------
# Old-glibc workarounds. The webOS device has glibc 2.8 while our toolchain's sysroot is 2.9, exactly
# the situation of the legacy Kindle and PocketBook builds, which KOReader already handles with
# `if(LEGACY OR POCKETBOOK)` in several third-party builds (libzmq: epoll_create1@GLIBC_2.9, ...).
# We join them wherever they exist, so this follows upstream when it adds or drops such places.
# --------------------------------------------------------------------------------------------------
def old_glibc():
    pattern = re.compile(r"if\(LEGACY OR POCKETBOOK\)")
    hits = already = 0
    files = sorted((root / "base").rglob("CMakeLists.txt")) + sorted((root / "base").rglob("*.cmake"))
    for f in files:
        if "/build/" in f.as_posix():
            continue
        text = f.read_text()
        already += text.count("LEGACY OR POCKETBOOK OR WEBOS")
        new, n = pattern.subn("if(LEGACY OR POCKETBOOK OR WEBOS)", text)
        if n:
            f.write_text(new)
            hits += n
            print(f"            {f.relative_to(root)} ({n})")
    if hits:
        print(f"   applied  base: old-glibc workarounds ({hits} places)")
    elif already:
        print(f"   already  base: old-glibc workarounds ({already} places)")
    else:
        print("   FAILED   base: old-glibc workarounds: no 'if(LEGACY OR POCKETBOOK)' found anywhere; "
              "upstream changed how it handles old glibc, so check the ARM build against glibc 2.8 by hand")
        failed.append("old-glibc")


old_glibc()


# --------------------------------------------------------------------------------------------------
# Frontend: recognise the device and choose our input backend.
# --------------------------------------------------------------------------------------------------
PROBE = (
    "    -- HP TouchPad (webOS 3.x). /etc is not visible from inside the webOS app jail,\n"
    "    -- so also accept the marker our launcher sets and a binary that is visible there.\n"
    '    local webos_test_stat = os.getenv("KO_WEBOS") or lfs.attributes("/usr/bin/LunaSysMgr")\n'
    "    if webos_test_stat then\n"
    '        return require("device/webos/device")\n'
    "    end\n\n"
)


# Newer KOReader chooses the device from the platform name in the version string ("<version>_<TARGET>",
# written by the top-level Makefile), so for TARGET=webos the name is simply "webos".
PLATFORM_BRANCH = (
    '        elseif platform:sub(1, #"webos") == "webos" then\n'
    '            return require("device/webos/device")\n'
)


def device_probe(s):
    if "device/webos/device" in s:
        return s
    if "Version:getCurrentPlatform()" in s:
        return insert_before(s, r'^        elseif platform:sub\(1, #"', PLATFORM_BRANCH,
                             "the platform branches in probeDevice()")
    return insert_before(s, r'^    local kindle_test_stat = lfs\.attributes\("/proc/usid"\)', PROBE,
                         "the Kindle device probe in probeDevice()")


run("frontend: device probe", "frontend/device.lua", device_probe)


def input_backend(s):
    if "ffi/input_webos" in s:
        return s
    block = (
        "    elseif self.device.isWebOS and self.device:isWebOS() then\n"
        '        self.input = require("ffi/input_webos")\n'
    )
    return insert_before(s, r'^    elseif self\.device:isAndroid\(\) then\n        self\.input = require\("ffi/input_android"\)',
                         block, "the Android input backend selection in Input:init()")


run("frontend: input backend", "frontend/device/input.lua", input_backend)

print()
if failed:
    print("Some edits could not be made (%s). KOReader changed upstream in a way that needs a human." % ", ".join(failed))
    sys.exit(1)
print("All webOS edits are in place.")
