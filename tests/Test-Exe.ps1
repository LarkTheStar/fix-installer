# Checks dist\CodHQ-Setup.exe (build it first with tools\Build-Exe.ps1):
#   - its version matches install.ps1's $AppVersion and it has an icon;
#   - the script it writes out is install.ps1 byte for byte;
#   - it starts Windows PowerShell 5.1 in STA mode and passes arguments through,
#     quoted correctly (spaces, quotes, trailing backslashes);
#   - with -Launch, the real window opens from the exe in sandbox mode and is closed
#     again (no real Steam or game is touched).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Exe.ps1 [-Launch]

param([switch]$Launch)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $repo 'dist\CodHQ-Setup.exe'
$script = Join-Path $repo 'install.ps1'
$failures = 0
function Check([string]$Name, [bool]$Ok) { if ($Ok) { Write-Output "[PASS] $Name" } else { Write-Output "[FAIL] $Name"; $script:failures++ } }

if (-not (Test-Path -LiteralPath $exe)) { throw "Build the exe first: tools\Build-Exe.ps1 ($exe is missing)." }
$version = [regex]::Match([IO.File]::ReadAllText($script), "(?m)^\`$AppVersion = '([0-9.]+)'").Groups[1].Value
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Check "the exe's version is $version" ($info.ProductVersion -eq $version)
Check 'the exe is named as the utility' ($info.ProductName -eq 'Call of Duty HQ Setup Utility')
Add-Type -AssemblyName System.Drawing
Check 'the exe has its icon' ($null -ne [System.Drawing.Icon]::ExtractAssociatedIcon($exe))

$out = Join-Path ([IO.Path]::GetTempPath()) ('codhq-exe-test-' + [guid]::NewGuid().ToString('N') + '.txt')
$process = Start-Process -FilePath $exe -ArgumentList @('--dry-run', ('"' + $out + '"'), '-Sandbox', '"C:\Some Folder\sandbox\\"', '-GameFolder', 'C:\Games\CoD') -Wait -PassThru
Check 'the dry run exits cleanly' ($process.ExitCode -eq 0)
$lines = [IO.File]::ReadAllLines($out)
Remove-Item -LiteralPath $out -Force
$copy = $lines[2]
Check 'it runs Windows PowerShell 5.1' ($lines[0] -like '*\System32\WindowsPowerShell\v1.0\powershell.exe')
Check 'it starts the script in STA mode with no profile' ($lines[1] -like '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File *')
Check 'the script it writes out is install.ps1 byte for byte' ((Get-FileHash -LiteralPath $copy).Hash -eq (Get-FileHash -LiteralPath $script).Hash)
Check 'the copy is kept next to the settings, not in TEMP' ($copy -like "$env:LOCALAPPDATA\CallOfDutyHQ-SetupUtility\app\install-*.ps1")
Check 'arguments are passed through and quoted' ($lines[1].EndsWith(' -Sandbox "C:\Some Folder\sandbox\\" -GameFolder C:\Games\CoD'))

if ($Launch) {
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) 'codhq-sandbox-exe'
    & (Join-Path $PSScriptRoot 'Start-Sandbox.ps1') -Path $sandbox -Reset -NoLaunch | Out-Null
    $before = @(Get-Process powershell -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    Start-Process -FilePath $exe -ArgumentList @('-Sandbox', ('"' + $sandbox + '"'))
    $window = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $window -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $window = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id -and $_.MainWindowTitle -like 'Call of Duty MW4 Setup Utility*SANDBOX*' } | Select-Object -First 1
    }
    Check 'the window opens from the exe (sandbox mode)' ($null -ne $window)
    if ($window) {
        $null = $window.CloseMainWindow()
        Check 'the window closes again' ($window.WaitForExit(20000))
    }
}

if ($failures -gt 0) { Write-Output "$failures check(s) failed."; exit 1 }
Write-Output 'All exe checks passed.'
