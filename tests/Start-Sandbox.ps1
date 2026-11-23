# Builds a sandbox - a fake Steam folder, a fake game folder and a private settings
# folder - and starts the real utility in sandbox mode against it:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Start-Sandbox.ps1
#
# In the window you can then press every button, including both downgrades and the
# UAC hand-off to the administrator window, and nothing outside the sandbox changes:
# Steam is never closed or started, BetterSteamTools is not installed, settings,
# hand-off files and logs stay in the sandbox. Downloads are real (the fix archive,
# the Lua file and the manifests come from GitHub and are checked against their
# pinned SHA-256), so this also tests the network side.
#
#   -Report   prints what is in the sandbox now (run it after a test to see what
#             a downgrade or a fix install changed)
#   -Reset    deletes the sandbox and builds a fresh one
#   -NoLaunch builds the sandbox without starting the window
#   -Path     where the sandbox lives (default: %TEMP%\codhq-sandbox)
#
# To test the hand-off with a different administrator account, start this from the
# normal account and enter the other account's password at the UAC prompt.

param(
    [string]$Path = (Join-Path ([IO.Path]::GetTempPath()) 'codhq-sandbox'),
    [switch]$Report,
    [switch]$Reset,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path '..' 'install.ps1')))
$Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
$marker = Join-Path $Path '.codhq-sandbox'

function Write-SandboxFile {
    param([string]$Relative, [string]$Text)
    $full = Join-Path $Path $Relative
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($full, $Text, [Text.UTF8Encoding]::new($false))
}

function Show-SandboxReport {
    Write-Output "Sandbox: $Path"
    foreach ($part in 'Steam', 'Game', 'Battle.net', 'Own copy', 'Settings') {
        $root = Join-Path $Path $part
        Write-Output ''
        Write-Output "--- $part ---"
        if (-not (Test-Path -LiteralPath $root)) { Write-Output '  (missing)'; continue }
        $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)
        if ($files.Count -eq 0) { Write-Output '  (empty)' }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($root.Length + 1)
            # Short text files are shown inline; binary ones (real Steam manifests) are not.
            $preview = ''
            if ($file.Length -le 200) {
                $bytes = [IO.File]::ReadAllBytes($file.FullName)
                if (-not ($bytes | Where-Object { $_ -lt 9 -or ($_ -gt 13 -and $_ -lt 32) -or $_ -gt 126 } | Select-Object -First 1)) {
                    $preview = ([Text.Encoding]::ASCII.GetString($bytes) -replace '\s+', ' ').Trim()
                    if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }
                    $preview = " : $preview"
                }
            }
            Write-Output ("  {0}  ({1:N0} bytes){2}" -f $relative, $file.Length, $preview)
        }
    }
}

if ($Report) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "No sandbox at $Path. Run this script without -Report first." }
    Show-SandboxReport
    return
}

if ($Reset -and (Test-Path -LiteralPath $Path)) {
    # Only ever delete a folder this script created.
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to delete ${Path}: it has no .codhq-sandbox marker." }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
    if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
        throw "$Path already exists and is not a sandbox. Choose another -Path."
    }
    Write-SandboxFile '.codhq-sandbox' 'Sandbox for the Call of Duty MW4 Setup Utility. Safe to delete.'

    # Fake Steam: the files a downgrade reads and changes, plus a few that the
    # Nuclear downgrade deletes and a few it keeps.
    Write-SandboxFile 'Steam\steam.exe' 'fake steam.exe (sandbox)'
    Write-SandboxFile 'Steam\config\stplug-in\1938090.lua' '-- old lua (sandbox)'
    Write-SandboxFile 'Steam\depotcache\1938091_1111111111111111111.manifest' 'old manifest for this game (sandbox)'
    Write-SandboxFile 'Steam\depotcache\999999_1.manifest' 'manifest of another game (sandbox) - Normal keeps it; Nuclear deletes all of depotcache'
    Write-SandboxFile 'Steam\steamapps\appmanifest_1938090.acf' ("`"AppState`"`n{`n`t`"appid`"`t`t`"1938090`"`n`t`"name`"`t`t`"Call of Duty HQ`"`n`t`"StateFlags`"`t`t`"6`"`n`t`"installdir`"`t`t`"Call of Duty HQ`"`n`t`"SizeOnDisk`"`t`t`"123456`"`n`t`"buildid`"`t`t`"20000000`"`n`t`"BytesToDownload`"`t`t`"5`"`n`t`"BytesDownloaded`"`t`t`"1`"`n`t`"UpdateResult`"`t`t`"2`"`n}`n")
    Write-SandboxFile 'Steam\userdata\keep.txt' 'kept by Nuclear (sandbox)'
    Write-SandboxFile 'Steam\logs\deleted-by-nuclear.txt' 'deleted by Nuclear (sandbox)'
    Write-SandboxFile 'Steam\package\deleted-by-nuclear.txt' 'deleted by Nuclear (sandbox)'

    # Fake game: what the folder check and the language tools look for.
    Write-SandboxFile 'Game\cod.exe' 'fake cod.exe (sandbox)'
    Write-SandboxFile 'Game\steam_api64.dll' 'fake steam_api64.dll (sandbox)'
    Write-SandboxFile 'Game\!start_sp26.bat' "@echo off`r`necho This is the sandbox's fake game launcher.`r`npause`r`n"
    Write-SandboxFile 'Game\sp26\steam_settings\configs.user.ini' "[user::general]`r`naccount_name=sandbox`r`nlanguage=english`r`n"

    # Fake Steam installs of a few Games-page titles: each has its Steam app manifest
    # and the marker file the installer looks for (placeholder text, not the games).
    $fakeGames = @(
        @{ AppId = 2630; Dir = 'Call of Duty 2'; Files = @('CoD2SP_s.exe', 'CoD2MP_s.exe', 'mss32.dll') }
        @{ AppId = 7940; Dir = 'Call of Duty 4'; Files = @('iw3mp.exe', 'iw3sp.exe', 'binkw32.dll', 'mss32.dll') }
        @{ AppId = 10180; Dir = 'Call of Duty Modern Warfare 2'; Files = @('iw4mp.exe', 'iw4sp.exe', 'binkw32.dll') }
        @{ AppId = 202970; Dir = 'Call of Duty Black Ops II'; Files = @('t6mp.exe', 't6zm.exe', 't6sp.exe', 'binkw32.dll') }
        @{ AppId = 209160; Dir = 'Call of Duty Ghosts'; Files = @('iw6mp64_ship.exe', 'iw6sp64_ship.exe') }
        # Call of Duty and United Offensive share one folder on Steam, as on a real PC.
        @{ AppId = 2620; Dir = 'Call of Duty'; Files = @('CoDSP.exe', 'CoDMP.exe', 'mss32.dll', 'Main\pak0.pk3', 'Main\game_mp_x86.dll') }
        @{ AppId = 2640; Dir = 'Call of Duty'; Files = @('CoDUOSP.exe', 'CoDUOMP.exe', 'uo\pakuo00.pk3') }
        # Modern Warfare Remastered: H1-Mod and HorizonMW both use it.
        @{ AppId = 393080; Dir = 'Call of Duty Modern Warfare Remastered'; Files = @('h1_mp64_ship.exe', 'h1_sp64_ship.exe') }
    )
    foreach ($fake in $fakeGames) {
        Write-SandboxFile ("Steam\steamapps\appmanifest_{0}.acf" -f $fake.AppId) ("`"AppState`"`n{`n`t`"appid`"`t`t`"$($fake.AppId)`"`n`t`"installdir`"`t`t`"$($fake.Dir)`"`n}`n")
        foreach ($file in $fake.Files) { Write-SandboxFile ("Steam\steamapps\common\{0}\{1}" -f $fake.Dir, $file) "placeholder $file (sandbox)" }
    }
    # Black Ops 4 is a Battle.net game, which sandbox mode does not search for: pick this
    # folder with Change folder on its card. Its exe and LPC files are placeholders, so
    # Install shows the backup of both and Remove shows them put back.
    foreach ($file in 'BlackOps4.exe', 'Black Ops 4 Launcher.exe', 'LPC\core_ffotd_placeholder.ff') { Write-SandboxFile ("Battle.net\Call of Duty Black Ops 4\{0}" -f $file) "placeholder $file (sandbox)" }
    # A stand-in for the player's own copy of the older games. Its files are
    # placeholders, so Import lists every file it could not match (the real check).
    Write-SandboxFile 'Own copy\Call of Duty\Main\pak0.pk3' 'placeholder, not the 1.1 pak0.pk3 (sandbox)'

    $null = New-Item -ItemType Directory -Path (Join-Path $Path 'Settings') -Force
    Write-Output "Sandbox created at $Path"
} else {
    Write-Output "Using the existing sandbox at $Path (add -Reset for a fresh one)."
}

if ($NoLaunch) { return }
Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$scriptPath`" -Sandbox `"$Path`""
Write-Output 'The utility is starting in sandbox mode; its title ends in [SANDBOX].'
Write-Output "Afterwards, see what changed with: .\tests\Start-Sandbox.ps1 -Report"
