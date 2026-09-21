# KOReader Port — webOS Project

This is a **Palm/HP webOS** application (original 2009–2012 platform, not LG webOS).

## Session Setup

At the start of every session, load the webOS platform context from the `webos-mcp` server:

```
webos://knowledge/all
```

This gives you knowledge of the Mojo/Enyo frameworks, Luna service bus, SDK tools (including novacom), app structure conventions, and common gotchas — so we don't have to re-establish basics each time.

The full bundle is ~555 KB, too large to read into context in one go. Instead, read the relevant sections individually as needed (e.g. `webos://knowledge/pdk`, `nizovn-packages`, `gotchas`, `sdk-tools`, `postinst-packaging`, `windows-wsl-dev`). List them with ListMcpResourcesTool.

---

## Project Details

**App ID:** `com.magq.koreader` (chosen by the user; set in `webos/appinfo.json`. Don't change it once users have installed it: settings and updates are tied to it. A placeholder `com.example.koreader` was used in early tests and must not be used again.)
**Framework:** Native PDK app (C/C++ and Lua). **Not** Enyo or Mojo.
**Target devices:** HP TouchPad only
**webOS version(s):** 3.0.5+

## Goal and Approach

Port **real KOReader** to the TouchPad, staying as close to upstream as possible. This is a native port (the "PDK route"), chosen over rewriting the reader as an Enyo web app.

- KOReader = LuaJIT + a C library (`koreader-base`: MuPDF, CREngine, fonts, framebuffer). The Lua reader code should run unchanged.
- **Keep upstream updatable:** add only a small webOS platform layer (screen output, touch input, app packaging) on top of KOReader. Do not edit upstream code where a separate file or patch will do. Updating to a new KOReader release should mean re-applying that layer, not redoing the port.
- **Toolchain (revised 2026-09-20):** Linaro GCC 4.9.4 is fine for small C programs (hellotest) but **too old to build KOReader**, whose `koreader-base` needs `-std=gnu11` / `-std=gnu++17`. KOReader's own old-device builds use **koxtoolchain** (crosstool-NG recipes: modern GCC + an old glibc sysroot, `arm-<name>-linux-gnueabi-`). The plan is a custom koxtoolchain-style toolchain for the TouchPad. See "TouchPad facts" below. PDK SDL 1.2 + `libpdl` are still the way to get a screen and touch.
- **Main risk:** KOReader's desktop backend uses **SDL3** (`base/thirdparty/sdl3`), but the TouchPad only has SDL 1.2. The key new code is an SDL 1.2 screen and touch backend for KOReader, probably via LuaJIT FFI. Not yet explored: how `frontend/device/*` and `base/ffi/*` define a device (Kindle/Kobo use raw framebuffer + evdev; the TouchPad must go through SDL/PDL instead).

## TouchPad facts (measured on the device)

- glibc **2.8** (`Sourcery G++ 4.3-234`), kernel `2.6.35-palm-tenderloin`, ARMv7 (Qualcomm, CPU part 0x02d), features include `neon vfpv3`, **softfp** float ABI.
- The PDK ships `libc-2.5.so` for linking, but the device's actual glibc is 2.8. Binaries must not need symbols newer than glibc 2.8.
- koxtoolchain `kindle5` recipe: Cortex-A8, NEON, softfp, glibc **2.12.2**, kernel headers 2.6.32. CPU flags match the TouchPad, but glibc 2.12 is newer than 2.8. The `kindle-legacy` recipe uses glibc 2.9 (and KOReader already has flags to avoid post-2.9 symbols), closer but ARMv6-only.
- Leading option: crosstool-NG build modelled on `arm-kindle-linux-gnueabi` but with `CT_ARCH_CPU=cortex-a8`, NEON, softfp and glibc 2.9 or lower. Fallback: bundle a newer glibc inside the app (nizovn packages are **not** installed on the device; Preware is).
- **Rendering:** use SDL's own GL/video path with PDL initialised first. Never use EGL directly (touch flicker). Do not ship `metadata.json` (it forces a 320x480 phone-mode surface). Details are in the `pdk` knowledge file.

## Environment (this PC)

- Windows 11, 15 GB RAM. Project folder: `WebOS KOReader` (on the user's Desktop). Local git repo (branch `main`, not published anywhere; see "Git" below).
- **Installed:** webOS SDK (`C:\Program Files (x86)\HP webOS\SDK\bin`, has `palm-package`, `palm-install`, `palm-launch`, `novacom`) and PDK (`C:\Program Files (x86)\HP webOS\PDK`).
- **TouchPad:** in developer mode, detected by `novacom -l` as `topaz-linux`.
- **WSL 2 + Ubuntu 22.04 installed** (distro name `Ubuntu-22.04`, default user `dev` with passwordless sudo; 22 cores, ~7.4 GB RAM). Run commands with `wsl -d Ubuntu-22.04 -- bash -c "..."`. Standard build tools (gcc, git, cmake, ninja, autotools, nasm) are installed. Windows drives are at `/mnt/c/...` (the PDK is under `/mnt/c/Program Files (x86)/HP webOS/PDK`).
- **Linaro GCC 4.9.4 installed** at `~/linaro-toolchain` (WSL). Compiler: `~/linaro-toolchain/bin/arm-linux-gnueabi-gcc`. Linaro's own download links are dead (redirect to a web page); it came from the Armbian mirror `https://mirrors.tuna.tsinghua.edu.cn/armbian-releases/_toolchain/gcc-linaro-4.9.4-2017.01-x86_64_arm-linux-gnueabi.tar.xz` (sha256 `232302236c90ec136a42d44bc387d2e1199f5df010b77e97ee590216d2b5b181`).
- **PDK visible from WSL** at `/mnt/c/Program Files (x86)/HP webOS/PDK` (has `include/` with SDL, GLES, PDL.h and `device/lib/` with libSDL, libpdl, libGLES_CM). Note it has no `/opt/PalmPDK` path, so build scripts must use the `/mnt/c` path (it contains spaces and parentheses, so always quote it).
- **Toolchain verified end to end (2026-09-20).** `hellotest/` (app ID `com.koreader.hellotest`) cross-compiles, packages, installs and runs on the TouchPad. Confirmed on the device:
  - SDL 1.2 software surface: `PDL_Init(0)`, then `SDL_Init(SDL_INIT_VIDEO)`, then `SDL_SetVideoMode(1024, 768, 16, SDL_SWSURFACE | SDL_FULLSCREEN)` gives a 1024x768, 16 bpp surface. Drawing plus `SDL_Flip` works.
  - Touch: `SDL_MOUSEBUTTONDOWN/MOTION/UP` give correct 1024x768 coordinates, `which` = finger index.
  - Launch: `argv[0]` is the full path, `argv[1]` is the string `{ }`. `/media/internal` logging works.
  - Dependencies of the binary: only `libSDL-1.2.so.0`, `libpdl.so`, `libm`, `libc` (all on the device, no extra packages needed for a plain C program).
  - Build: `hellotest/build.sh` (run in WSL). Package and install from PowerShell: `palm-package package` then `palm-install <id>_<ver>_all.ipk` (SDK `bin` must be on PATH). The install output is quiet; verify with `novacom run file:///bin/ls -- -la /media/cryptofs/apps/usr/palm/applications/<id>/`.
  - `palm-package` from Windows keeps the binary executable (device shows `-rwxrwxrwx`).
- **KOReader source:** cloned to `~/koreader` in WSL, pinned to release tag **v2026.07.2** (shallow; `base/` = koreader-base submodule checked out, other submodules not yet). `~/koxtoolchain` (koxtoolchain scripts) and `~/ctng-peek` (Benoit Pierre's crosstool-NG fork samples, for reference) also cloned. KOReader platforms live in `platform/` and `make/*.mk`; cross-toolchain selection is in `base/Makefile.defs` (`CHOST=arm-<target>-linux-gnueabi`).
- **How a KOReader device plug-in is structured** (model for our overlay): `frontend/device/<name>/device.lua` (device class; detected in `frontend/device.lua` `probeDevice()`), `base/ffi/framebuffer_<name>.lua`, `base/ffi/input_<name>.lua`, `make/<name>.mk`, plus the `TARGET`/`CHOST` case in `base/Makefile.defs`. The SDL3 versions are a good template (`framebuffer_SDL3.lua` 172 lines, `input_SDL3.lua` 18 lines, `frontend/device/sdl/device.lua` 510 lines, `base/ffi/SDL3.lua` 846 lines of FFI). Plan: new `webos` device with SDL 1.2 FFI (`base/ffi/SDL1_2.lua`), `framebuffer_webos.lua`, `input_webos.lua`, `frontend/device/webos/device.lua`, `make/webos.mk`. Keep these as **added files** (kept in our own overlay dir and copied/symlinked in) and a minimal patch to `frontend/device.lua` and `base/Makefile.defs`.
- **TouchPad cross-toolchain BUILT and VERIFIED (2026-09-20):** `~/x-tools/arm-webos-linux-gnueabi/` (WSL). Prefix `arm-webos-linux-gnueabi-`, **GCC 14.4.0**, binutils 2.43.1, **glibc 2.9** sysroot, Linux 2.6.32 headers. Defaults: `-mcpu=cortex-a8 -mfpu=neon -mfloat-abi=softfp`, **ARM mode** (not Thumb). C++17 compiles. Test binaries need only GLIBC_2.4 (libstdc++ needs up to 2.6), device has 2.8, no 2.9 symbols found. Confirmed on the TouchPad: a C++17 binary runs when using the toolchain's own `libstdc++.so.6` + `libgcc_s.so.1` (copied from `.../sysroot/lib`, loaded with `LD_LIBRARY_PATH`). The device's own libstdc++ (6.0.9, 2008) is too old for modern C++, so **the app must bundle libstdc++/libgcc_s** (set rpath to the app dir).
  - Rebuild script (saved in project): `toolchain/build-webos-toolchain.sh` (uses crosstool-NG fork `benoit-pierre/crosstool-ng` at `34844bc`, cloned in `~/tc/CT-NG`; build dir `~/tc/webos`; ~20 min at 4 jobs). Gotchas we hit: (1) glibc 2.9 **cannot be built in Thumb mode** (`r15 not allowed here` in libc-start), so the recipe uses `CT_ARCH_ARM_MODE_ARM=y`; (2) ct-ng reads recipes from its **installed** copy `~/tc/CT_NG_BUILD/share/crosstool-ng/samples/`, so after editing a recipe copy it there; (3) `CT_PARALLEL_JOBS=4` because all cores exhausted RAM (Claude Code's watchdog killed the build); (4) run with a clean `PATH` (Windows PATH entries with spaces break ct-ng).
- **novacom tips:** `novacom run file:///bin/sh -- -c "..."` drops the arguments. Pipe commands on stdin instead (`"cmd; cmd" | novacom run file:///bin/sh`), and make sure the text has no BOM (PowerShell's first pipe line can gain one; put a harmless `true;` first). `/tmp` on the device is executable and writable (`novacom put file:///tmp/dir/file < localfile` needs the directory to exist first: `novacom run file:///bin/mkdir -- -p /tmp/dir`).
- **koreader-base BUILT for `TARGET=webos` and RUN on the TouchPad (2026-09-20).** Output: `~/koreader/base/build/arm-webos-linux-gnueabi/` (`luajit`, `libs/*.so`, ~19 MB without `*.dbg`; the folder is 2 GB with debug files). Confirmed on the device: LuaJIT 2.1 runs with JIT on (ARMv7, VFPv3), all 26 libs in `libs/` load via `ffi.load`, SQLite/zlib/zstd calls work. Every shipped binary needs at most GLIBC_2.8 (libzstd; libarchive/libstdc++ 2.6, rest 2.4) so it fits the device's glibc 2.8. **Ship `libstdc++.so.6` and `libgcc_s.so.1`** (LuaJIT needs libgcc_s; copy from the toolchain sysroot; `libs/` already has libstdc++). `luajit` has RPATH `$ORIGIN:$ORIGIN/libs`. Device `/tmp` is a 40 MB tmpfs (fine for tests, not for the app).
  - **Our changes to KOReader** live in `overlay/`: new files in `overlay/files/` (copied in) and a few edits in `overlay/transforms.py`. The edits are idempotent, find their place by meaning, and stop with FAILED if upstream removed something they need. There are deliberately no line-based patches: upstream moves code too often (tested against master on 2026-09-20). The edits: `TARGET=webos` in `base/Makefile.defs` (CHOST, `WEBOS=1`, `GLIBC_VERSION_MAX=2.8`, Cortex-A8/NEON/softfp/Thumb flags, `set(WEBOS ...)` for CMake); build `blitbuffer` for WEBOS and exclude the evdev `koreader-input` module (touch comes from SDL) in `koreader_targets.cmake`; `OR WEBOS` next to every `LEGACY OR POCKETBOOK` old-glibc workaround under `base/` (libzmq's `epoll_create1`@2.9 etc.); the device probe in `frontend/device.lua` (handles both the old file-probe style and the newer `Version:getCurrentPlatform()` platform-name style, where the name comes from `git-rev` = `<version>_<TARGET>`) and the input backend in `frontend/device/input.lua`. Model target: PocketBook (also Cortex-A8/softfp/glibc 2.9 toolchain).
  - **Build:** `webos/build.sh` (WSL) checks tool versions, applies the overlay, runs `make TARGET=webos PARALLEL_JOBS=4 all`, then checks every file against glibc 2.8. Resumable, about 15 min from scratch. After changing a thirdparty CMake file, delete that project's dir under `base/build/arm-webos-linux-gnueabi/thirdparty/` so it rebuilds.
  - **Build tool versions needed** (Ubuntu 22.04's are too old): meson >= 1.2 (pip: `~/.local/bin/meson`, 1.12), ninja >= 1.13 and GNU make >= 4.4 (`~/.local/bin`, for jobserver; otherwise `make: read jobs pipe: Bad file descriptor`), plus apt `gcc-multilib g++-multilib` (LuaJIT host build). `~/.local/bin` must be on PATH before `/usr/bin`. If a build dir was created with the old meson, delete `base/build/arm-webos-linux-gnueabi` and rebuild.
  - **Glibc check** is part of `webos/build.sh`: nothing may need more than GLIBC_2.8.
- **Updating KOReader:** `webos/update-koreader.sh <tag> [--build]` switches the checkout to another release and re-applies the overlay; then `webos/build.sh`, raise `version` in `webos/appinfo.json`, `webos/package.sh`, `webos/install.ps1`. Tested 2026-09-20: the overlay applies to upstream master (which had switched to platform-name detection and dropped the curl/tar builds), and switching a scratch checkout back to v2026.07.2 reproduced the working copy. The latest release at that time was v2026.07.2, the one we ship. Not yet done: a full build of a newer release.
- **Running WSL scripts from here:** quoting through `wsl -d Ubuntu-22.04 -- bash -c '...'` breaks on parentheses and quotes. Write a `.sh` file to the scratchpad and run it with `wsl -d Ubuntu-22.04 -- bash /mnt/c/.../script.sh` from **PowerShell** (Git Bash rewrites `/mnt/...` paths).

## App Structure

Key files: not created yet. Planned layout (to confirm):

- KOReader source and build tree (inside WSL, e.g. `~/koreader`)
- `webos/` overlay: our platform layer (SDL 1.2 backend, `appinfo.json`, launcher, packaging script)
- Build and package scripts that produce the `.ipk`

## Services

None planned. Runtime dependencies come from nizovn add-on packages (glibc etc.), which users install first.

## Development Notes

- **The user doesn't know much about coding, so guide them step by step.** Explain what each command does, and give exact commands to copy. Do anything needing admin rights or a reboot by asking the user to run it.
- **Jail:** PDK apps launched from the launcher run in a sandbox. `main` in `appinfo.json` must be the native binary, not a shell script. stdout/stderr are lost, so log to a file under `/media/internal/`.
- `palm-install` silently refuses a same-or-lower version. Bump `version` in `appinfo.json` before reinstalling.
- The app install dir is read-only at runtime. `/media/internal` is writable (books, settings, logs).

## HARD RULES for touching the device (learned the hard way, 2026-09-20)

**Never run `rm -rf` (or any recursive delete, move or chmod) on anything under `/var/palm/jail/`.** A jail directory holds live bind mounts, including a read-write mount of the whole `/media/internal` vfat partition (and `/proc`, `/dev`). BusyBox `rm -rf` follows them: it wiped the user's entire TouchPad storage and made `/media/cryptofs` (all installed apps) disappear. BusyBox `rm` has no `--one-file-system`.

- To remove an app use `palm-install -r <app-id>` (or `ipkg -o /media/cryptofs/apps remove <app-id>`), then **reboot** the tablet if the folder lingers. Do not delete leftover folders by hand.
- Before any delete/`rm` on the device: check `cat /proc/mounts`, delete only a single named file or a folder you have just created, and never a glob or a path containing `jail`.
- Do not run destructive commands on the device as a "cleanup" without asking the user first. Ask before anything that removes user-visible data.
- `/media/internal` is the user's personal storage (documents, music, photos). Treat it as precious: KOReader settings live in `/media/internal/koreader` and nothing else there is ours.

## Status (2026-09-20)

Working: cross-toolchain, koreader-base, full KOReader tree, SDL 1.2/PDL screen + multitouch layer (`overlay/`), native launcher and packaging (`webos/`). **KOReader v2026.07.2 ran on the TouchPad from a direct shell run**: file browser shown, taps, menus and two-finger gestures worked, the user said everything looked fine except the UI is too big (see below). Not yet confirmed: launching from the webOS launcher icon. A jailed launch earlier produced `LunaService-CRITICAL: Invalid permissions for <app-id>` from PDL_Init and the process was not found afterwards; unresolved (the log is buffered when redirected to a file, so its last lines may be missing).

The user is reflashing the TouchPad with **webOS 3.1.0 CE** (community edition) after the storage wipe. After that: re-enable developer mode, confirm `novacom -l` sees the device, then re-check device facts on the new OS (glibc version via `novacom run file:///lib/libc.so.6`, `/etc/palm-build-info`, `uname -a`), since our binaries need glibc <= 2.8 and a newer OS may differ. Then run `overlay/apply.sh` (already applied in WSL), `webos/package.sh` (WSL), `webos/install.ps1` (PowerShell).

**Update, later on 2026-09-20:** the TouchPad was reflashed with **webOS CE 3.1.0** (`/etc/palm-build-info`: `PRODUCT_VERSION_STRING=webOS CE 3.1.0`, same kernel 2.6.35-palm-tenderloin, **same glibc 2.8**, libSDL-1.2 + libpdl present, libstdc++ 6.0.10). KOReader `com.magq.koreader` v0.0.1 installed and **launches from the launcher icon** (the launcher supervises luajit and logs to `/media/internal/koreader/webos-launcher.log`, including the exit code/signal). The `LunaService-CRITICAL: Invalid permissions for <app-id>` lines in the log are harmless.

**webOS CE 3.1.0 quirks:** (1) `palm-install`, `palm-launch` etc. fail with `unrecognized device version`. `webos/install.ps1` falls back to `novacom put` into `/media/internal/.developer/` + `ipkg -o /media/cryptofs/apps -force-depends install <file>`. (2) A first install is invisible in the launcher until the app list is rescanned: **Restart Luna** (Preware) or reboot; an already-installed app updated in place should not need it. (3) `luna-send` in a novacom shell prints nothing (calls still seem to run, e.g. queued installs); don't rely on its output. (4) When sending shell scripts to the tablet, use LF line endings and no BOM: write the bytes to a file and `cmd /c "novacom run file:///bin/sh < file"`; PowerShell pipes add CRLF/BOM and break BusyBox sh (`redir error`, `not found`). (5) Don't grep `/var/log/messages` broadly: it contains the user's account details.

**Rotation, touch, time (learned 2026-09-20):**
- The panel buffer is landscape 1024x768, upright with the **home button on the right**. `framebuffer_webos.lua` sets `is_always_portrait = true`, so KOReader mode 0 (upright portrait, home button at the bottom) is the buffer rotated by 90 degrees (BB rotation 3). Rotation is done in software by KOReader's blitbuffer.
- **Touch coordinates must ALWAYS be reported in the upright portrait frame** (`lx = 767 - py, ly = px`), never rotated by us: `frontend/device/gesturedetector.lua` rotates gestures itself using `Screen:getTouchRotation()`. Rotating in our layer too applies it twice (only the upright pose looked right). Same transform as `Input:adjustTouchSwitchAxesAndMirrorX` for the SDL emulator in portrait.
- **Auto-rotation:** `PDL_SENSOR_ORIENTATION` (sensor 7) via `PDL_EnableSensor/PDL_PollSensor` (polled every 100 ms in `waitForEvent`, events are queued so drain them), emitted as `EV_MSC:MSC_GYRO` (`hasGSensor = yes`), so KOReader's ignore/lock options work. Palm's names are misleading; measured mapping (sensor -> pose -> KOReader mode): 6 RIGHT_SIDE_DOWN = landscape button right -> mode 3; 4 UP_SIDE_DOWN = portrait button bottom -> mode 0; 5 LEFT_SIDE_DOWN = landscape button left -> mode 1; 3 NORMAL = portrait button top -> mode 2; 0/1/2 ignored. The initial reading counts as a change, so startup rotation is set within ~100 ms. Note KOReader rotates only widgets that handle `SetRotationMode`: an open dialog swallows a rotation event (expected upstream behaviour, not a bug).
- **Time zone:** the jail has no `/etc`, so libc showed UTC. The launcher reads the symlink `/var/luna/preferences/localtime` -> `/usr/share/zoneinfo/<Zone>` (both visible in the jail) and sets `TZ` on every (re)start.
- **Launcher** (`webos/launcher.c`) supervises luajit: pipes and flushes its output to `/media/internal/koreader/webos-launcher.log` (previous run kept as `.log.old`), logs exit code/signal, restarts on exit code 85, forwards SIGTERM and logs how long KOReader took to exit. **It never force-kills KOReader** (the user explicitly does not want that: it could lose settings or the reading position). Known, accepted: after closing the card, the first tap on the icon may be ignored until the old process has finished exiting; check `webos-launcher.log.old` for the "luajit gone N ms later" line if this needs work.
- **Touch debug:** an empty file `/media/internal/koreader/touch-debug` makes `SDL1_2.lua` log every touch-down (raw and converted) and sensor changes to the launcher log. Delete the file to turn it off.
- Icon: `webos/icon.png` is KOReader's own `resources/koreader.png` scaled to 64x64 (PIL). After changing an icon, the launcher may need a Luna restart to refresh.

Open items: (1) UI is too big: `screen_dpi = 132` in `overlay/files/frontend/device/webos/device.lua`; the user can adjust it in KOReader's Settings > Screen > Screen DPI. Ask the user which value looks right, then make it the default. (2) Fix launcher-icon launch. (3) Ship translations (`INCLUDE_L10N=1 webos/package.sh`, +65 MB). (4) Battery, Wi-Fi status, portrait rotation, Home/back button handling. (5) Nicer icon.

## Distribution (decided 2026-09-20)

The user will submit the `.ipk` to the **webOS App Museum** (the community app store; the plain `.ipk` from `webos/install.ps1 -NoInstall`, in `build/out/`, is what it takes). Updates for users = a new `.ipk` with a higher `version` (KOReader settings live in `/media/internal/koreader` and survive upgrades).

**Decisions so far:** vendor = `MAGQ` (the user's alias; "just porting", so describe it as an unofficial port); first release version `1.0.0` (a 1.0.0 was built and installed on 2026-09-20 but that package file was later deleted by an old `install.ps1` that removed all older packages of the app, now fixed; rebuild it from the sources when releasing); English only for now; **no public source repo yet** (the user's choice; but the AGPL source must be reachable no later than when the Museum listing goes live); the default `screen_dpi = 100` ships in the code, so fresh installs start at Auto DPI (100).

Before a public release (checklist, not all done):
- **License: KOReader and MuPDF are AGPL-3.0.** Distributing the binaries means offering the corresponding source, including our overlay/build scripts (`overlay/`, `webos/`, `toolchain/`, launcher). Publish these (public repo) and link it in the Museum description. Our new files in `overlay/files/` are derived from KOReader code, so AGPL-3.0 is the matching license. The tree already ships KOReader's `COPYING` and font licenses. The bundled `libstdc++`/`libgcc_s` fall under the GCC Runtime Library Exception. Ask the user before choosing/adding a license file.
- **appinfo.json:** replace `"vendor"` with the user's name or handle, pick a real starting `version` (e.g. 1.0.0, must strictly increase each release; three dotted numbers), optionally add `vendorurl`. Never ship `metadata.json` (it forces phone-size 320x480 surfaces, see the pdk notes). The app is **TouchPad only**: say so in the description (phones have a different screen).
- **Icon** `webos/icon.png`: 64x64 PNG, artwork 56x56 centred (Palm's rule), from KOReader's own icon. Done.
- **Museum listing needs:** description, screenshots (Orange+Sym+P on the device, or KOReader's own screenshot), keywords. The description should say "unofficial port", TouchPad only, webOS 3.0.5+, books go in `/media/internal` (settings in `/media/internal/koreader`).
- **Translations:** currently NOT shipped (English only), and `.mo` files did not get built by `make all` (no `.mo` found in the tree); `INCLUDE_L10N=1 webos/package.sh` would add the `.po` sources, which KOReader cannot use. Needs a proper `msgfmt`/`mo` build before it is worth shipping.
- **Only tested on webOS CE 3.1.0 (and briefly on stock 3.0.5 before the reflash).** glibc (2.8), SDL and PDL are the same on both, so the risk is low, but a tester on stock 3.0.5 would be good before a public release.

## Update prompt from the App Museum: findings (2026-09-20) and plan. NOT IMPLEMENTED YET

Goal (user's request): the app tells the user when a newer version is in the App Museum; it may come from the launcher rather than KOReader.

Findings from tests inside the real app jail (diagnostic mode: create `/media/internal/koreader/net-probe`, tap the icon, read `webos-launcher.log`; **always delete the marker afterwards, or the icon runs the test instead of KOReader**; `webos/netprobe.lua` and `pdl_probe()` in `webos/launcher.c`):
- **Network works in the jail** (DNS and HTTP with luasocket from the luajit child), even though `/etc/resolv.conf` is not visible. The App Museum II web service works: `GET http://appcatalog.webosarchive.org/WebService/getLatestVersionInfo.php?app=<Name>%2F<version>&clientid=<id>&device=TouchPad%2F3.1.0%2FWiFi%2Fen_us` returns JSON `{"version","versionNote","downloadURI"}`; for an unregistered app it returns HTTP 200 with `{"error":"No matching app found for koreader"}` (name is matched case-insensitively). Versions must be `#.#.#`. The `app` name must equal the name registered in the Museum (unknown until the listing exists).
- **Luna permissions are per exact program.** The installer creates `/var/palm/ls2/roles/{pub,prv}/<app-id>.json` with `exeName` = `.../<app-id>/webos-launcher` (the `main` binary), public-bus `outbound: ["*"]`. Only that process is allowed to use the bus. Everything from the luajit child fails: hub logs `Invalid permissions for <app-id>`, `PDL_ServiceCall` returns 2 "Unable to dispatch service call", `PDL_LaunchBrowser` returns 2 "Unable to communicate with app card". That is also the source of the harmless `LunaService-CRITICAL` lines at every start.
- **From the launcher process** (libpdl loaded with dlopen, `PDL_Init(0)`): `PDL_LaunchBrowser(url)` **works** (the browser opened, once). `PDL_ServiceCall("palm://com.palm.applicationManager/open", {"id":"com.palm.app.calculator"})` returned 0 but nothing opened (unresolved: maybe needs a callback/event loop or different call form). Creating an SDL window in the launcher gave `Passed a NULL mutex` and nothing visible.
- Community pattern (webOS Archive `webos-common` updater): after the version check, launch Preware with `palm://com.palm.applicationManager/open` `{"id":"org.webosinternals.preware","params":{"type":"install","file":"<downloadURI>"}}`. We could not confirm this call works from the launcher.

Plan: (1) a KOReader plugin `plugins/webosupdate.koplugin` in `overlay/files/` (Lua): reads the version from `../appinfo.json`, checks the API at startup (rate-limited) and from a menu item, shows a ConfirmBox with the release notes ("Update now" / "Later"); (2) on "Update now" it writes `/media/internal/koreader/webos-request` (the URL) and quits KOReader with a special exit code (e.g. `UIManager:quit(86)`); (3) the launcher sees that code and calls `PDL_LaunchBrowser(<url>)` (works), then exits. **To test next:** whether the browser handles a direct `.ipk` URL (webOS CE registers an ipk handler: marker `ce-ipk-handler-registered` in `/var/luna/preferences`), otherwise send users to the Museum page; and try the Preware call from the launcher again with a proper callback.
Note: the first shipped version must already contain this feature for anyone to get prompts. **There is currently no release candidate file** (only `build/out/com.magq.koreader_1.0.1_all.ipk`, an older 1.0.1 without the launcher's `pdl_probe`). Recommend not submitting to the Museum until the prompt is in. The build installed on the tablet is 1.0.1 with the current launcher (inert diagnostic code, no marker). Before releasing: rebuild as the release version after the prompt exists, and take the diagnostics (`pdl_probe()` in `launcher.c`, `netprobe.lua`, the `net-probe` marker check) out of the shipped package.

**Privacy (user's request, 2026-09-21):** do not put the user's real email or name into commits, package metadata, docs or anything shareable. The git identity is the user's GitHub no-reply address; the `.ipk` "Maintainer" is palm-package's generic `N/A <nobody@example.com>`; only the alias MAGQ is used (verified: neither appears in the git history or in the package). Bundled third-party libraries contain their own authors' emails in license headers; that is normal.

**Git:** the project folder is a git repo (since 2026-09-20). Remote `origin` is the user's **private** GitHub repo `MAGQ1/koreader-webos`; the history is a single squashed commit. Commits use the user's GitHub no-reply identity (repo-local config `MAGQ1 <153867619+MAGQ1@users.noreply.github.com>`); never use or ask for the user's real email. `.gitignore` excludes `build/`, `*.ipk` and built binaries; `.gitattributes` keeps LF line endings in scripts so they still run under WSL and on the tablet. Commit and push only when the user asks. **Pushing needs an interactive GitHub sign-in that the tool sandbox cannot show** ("terminal prompts disabled"): the first time, ask the user to run `! git -C "<project folder>" push -u origin main` themselves; Git Credential Manager then caches the login. No LICENSE file yet, by decision (private repo). Before making the repo public: decide the license (AGPL-3.0 is required for the KOReader-derived files, see README), and review `CLAUDE.md`. KOReader's own checkout in WSL (`~/koreader`) is a separate, untouched upstream clone: our changes live only in `overlay/`.

## Useful Commands

```bash
# Check the TouchPad is connected
novacom -l

# Package and install (bump version in appinfo.json first)
palm-package <app-dir>/ && palm-install <appid>_<version>_all.ipk

# Launch (non-blocking)
palm-launch <appid>

# Open a shell on the device / run a command
novacom -t open tty://
novacom run file:///bin/sh -- -c 'grep <appid> /var/log/messages | tail -20'

# Pull a log file from the device
novacom get file://media/internal/<appid>.log

# Kill a PDK app (palm-launch -c does not work for PDK apps)
novacom run file:///bin/sh -- -c 'killall <binary-name>'
```
