# KOReader for the HP TouchPad (webOS)

An **unofficial** port of [KOReader](https://koreader.rocks) (the document reader for e-readers) to the
**HP TouchPad** running the original Palm/HP **webOS 3.0.5 or later** (tested on webOS CE 3.1.0).
It is a native app: KOReader's own Lua interface and rendering libraries, cross-compiled for the
TouchPad's ARM processor, with a small webOS layer for the screen, multitouch, automatic rotation and
launching. Not affiliated with or endorsed by the KOReader project.

Currently ported: **KOReader v2026.07.2**.

## How the port is kept up to date

Nothing in KOReader's own source is stored here. Everything specific to webOS lives in a thin layer that is
applied on top of an untouched KOReader checkout, so newer KOReader releases are easy to adopt:

| Folder | What it is |
|---|---|
| `overlay/files/` | New files: a webOS device for KOReader (SDL 1.2 + PDL screen, multitouch, tilt-sensor rotation) |
| `overlay/transforms.py` | The few edits to KOReader's own files. Idempotent, and it finds its place by meaning, so it survives upstream changes; it stops with a clear message if something it needs is gone |
| `webos/` | The native launcher, app metadata, and the build, package, install and update scripts |
| `toolchain/` | Script that builds the ARM cross-compiler (modern GCC against an old glibc) |
| `hellotest/` | A minimal native app used to prove the toolchain end to end |
| `CLAUDE.md` | Detailed project notes and lessons learned (device quirks, decisions, open items) |

## Building (Windows 11 + WSL2 Ubuntu 22.04, TouchPad in developer mode)

1. Install the HP webOS SDK and PDK (Windows), and Ubuntu 22.04 under WSL2.
2. `toolchain/build-webos-toolchain.sh` (in WSL): builds the cross-compiler (about 20 minutes).
3. Get KOReader: `git clone https://github.com/koreader/koreader.git ~/koreader`, then
   `webos/update-koreader.sh v2026.07.2` (switches to that release and applies the overlay).
4. `webos/build.sh` (in WSL): builds KOReader and checks the result against the TouchPad's glibc 2.8.
5. `webos/package.sh` (in WSL), then `webos/install.ps1` (in PowerShell) packages and installs it.

Build tool versions matter (meson >= 1.2, ninja >= 1.13, GNU make >= 4.4); see `CLAUDE.md`.

## Notes

- On webOS CE the SDK's `palm-install` / `palm-launch` refuse to talk to the device ("unrecognized device
  version"); `webos/install.ps1` falls back to installing by hand with `ipkg`.
- Books go anywhere in the TouchPad's USB storage; KOReader keeps its settings in `koreader/` there.

## License

KOReader is licensed under the **AGPL-3.0**. The files in `overlay/files/` and the edits in
`overlay/transforms.py` are derived from KOReader's code and must be distributed under the same license.
A license for this repository as a whole has not been chosen yet; the repository is private for now.

## Credits

KOReader and its contributors; crosstool-NG and the koxtoolchain recipes (the old-glibc approach); the webOS
Archive and webOS Internals communities for documentation and tools.
