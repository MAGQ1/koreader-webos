# Package the staged app into an .ipk and (optionally) install it on the TouchPad.
# Run from PowerShell:   .\webos\install.ps1               package + install
#                        .\webos\install.ps1 -NoInstall    package only
#
# The SDK's palm-install / palm-launch refuse "webOS CE 3.1.0" ("unrecognized device version"), so if
# palm-install fails we install the same way it does, by hand: copy the .ipk to the tablet and run
# ipkg there. On a FIRST install of an app, webOS does not notice it until the app list is rescanned:
# do "Restart Luna" (Preware / Dev Mode) or reboot, then launch it from the launcher.
param([switch]$NoInstall)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$env:Path += ";C:\Program Files (x86)\HP webOS\SDK\bin"

$info = Get-Content "$root\webos\appinfo.json" -Raw | ConvertFrom-Json
$stage = "$root\build\stage\$($info.id)"
if (-not (Test-Path $stage)) { throw "Nothing staged at $stage. Run webos/package.sh in WSL first." }

$out = "$root\build\out"
New-Item -ItemType Directory -Force $out | Out-Null
# Only replace a package of the SAME version: older releases stay in build/out (they are handy to keep).
Get-ChildItem $out -Filter "$($info.id)_$($info.version)_*.ipk" -ErrorAction SilentlyContinue | Remove-Item -Force

# Send a shell script to the tablet with plain LF line endings and no BOM (PowerShell pipes add both,
# which the tablet's BusyBox sh rejects).
function Invoke-DeviceScript([string]$Script) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes(($Script -replace "`r`n", "`n") + "`n")
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        cmd /c "novacom run file:///bin/sh < `"$tmp`"" 2>&1 | Out-String
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

Push-Location $out
try {
    Write-Host "== palm-package"
    palm-package $stage
    $ipk = Get-ChildItem $out -Filter "$($info.id)_$($info.version)_*.ipk" | Select-Object -First 1
    if (-not $ipk) { throw "palm-package did not produce an .ipk" }
    Write-Host ("== {0}  ({1:N1} MB)" -f $ipk.Name, ($ipk.Length / 1MB))
    if ($NoInstall) { return }

    Write-Host "== palm-install (bump `"version`" in webos/appinfo.json if this is a re-install)"
    $ok = $true
    try { palm-install $ipk.FullName 2>&1 | Out-Host } catch { $ok = $false }
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    if (-not $ok) {
        Write-Host "== palm-install failed: installing by hand (ipkg)"
        $dev = "/media/internal/.developer"
        $devfile = "$dev/$($ipk.Name)"
        Invoke-DeviceScript "mkdir -p $dev" | Out-Null
        cmd /c "novacom put file://$devfile < `"$($ipk.FullName)`"" 2>&1 | Out-Null
        Write-Host (Invoke-DeviceScript "ipkg -o /media/cryptofs/apps -force-depends install $devfile 2>&1 | tail -3")
        # Remove only the single package file we just copied (never a directory).
        Invoke-DeviceScript "rm -f $devfile" | Out-Null
        Write-Host "== installed. First install of this app? Restart Luna (or reboot) so the launcher shows it."
    }
} finally {
    Pop-Location
}
