# App Museum submission materials

Everything needed to submit/update the listing lives here:

| File | What it is | Kept current how |
|---|---|---|
| `DESCRIPTION.md` | Title, tagline, full description, keywords to paste into the listing form | Edited by hand when the app's features/description change |
| `icon-256.png` | Larger icon for the store listing page (same artwork as `webos/icon.png`, scaled up) | Regenerate if `webos/icon.png`'s source art ever changes (see below) |
| `icon-64.png` | The actual 64x64 launcher icon, a copy of `webos/icon.png` | Copy over again if `webos/icon.png` changes |
| `screenshots/` | Screenshots for the listing (Orange+Sym+P on the device saves to the tablet; copy them here) | Added by hand, whenever you take new ones |
| `<app-id>_<version>_all.ipk` | The exact package to upload | **Copied here automatically** every time you run `webos/install.ps1` (see below) — always the most recently built package, never committed to git (it's large and changes on every build; see `.gitignore`'s `*.ipk` rule) |

## Keeping the `.ipk` current

`webos/install.ps1` copies the freshly-built `.ipk` from `build/out/` into this folder every time it
runs (with `-NoInstall` too, so packaging without touching the tablet still refreshes it). Before
submitting, just run the normal build pipeline once more and this folder will have the latest package:

```
webos/build.sh      (WSL)   — builds KOReader
webos/package.sh    (WSL)   — stages the app
webos/install.ps1           — packages into .ipk, copies it here, and installs on the tablet
```

## Regenerating `icon-256.png`

It's generated from KOReader's own icon (same source as `webos/icon.png` and `webos/miniicon.png`),
scaled to 256x256 with the artwork at the same 87.5% proportion as the launcher icon. See `CLAUDE.md`
for the generation script if the source art ever changes.
