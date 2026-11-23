# Builds dist\CodHQ-Setup.exe: tools\exe\Launcher.cs with install.ps1 embedded, the
# icon tools\exe\app.ico and the version from install.ps1's $AppVersion. Uses the C#
# compiler of the .NET Framework 4 that every Windows 10/11 has, so nothing needs
# installing.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Exe.ps1

param([string]$OutputDirectory = '')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo 'install.ps1'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework 4 C# compiler (csc.exe) was not found.' }

# The script must parse and be plain ASCII (it runs under Windows PowerShell 5.1).
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors)
if (@($errors).Count -gt 0) { throw "install.ps1 does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
$bytes = [IO.File]::ReadAllBytes($script)
if (@($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1).Count -gt 0) { throw 'install.ps1 is not plain ASCII.' }

$match = [regex]::Match([IO.File]::ReadAllText($script), "(?m)^\`$AppVersion = '([0-9]+(\.[0-9]+){1,3})'")
if (-not $match.Success) { throw 'The $AppVersion line was not found in install.ps1.' }
$version = [version]$match.Groups[1].Value
$fileVersion = '{0}.{1}.{2}.{3}' -f $version.Major, $version.Minor, [Math]::Max(0, $version.Build), [Math]::Max(0, $version.Revision)

$work = Join-Path ([IO.Path]::GetTempPath()) ('codhq-exe-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
try {
    $info = Join-Path $work 'AssemblyVersion.cs'
    [IO.File]::WriteAllText($info, "[assembly: System.Reflection.AssemblyVersion(`"$fileVersion`")]`r`n[assembly: System.Reflection.AssemblyFileVersion(`"$fileVersion`")]`r`n[assembly: System.Reflection.AssemblyInformationalVersion(`"$version`")]`r`n")
    $exe = Join-Path $OutputDirectory 'CodHQ-Setup.exe'
    $arguments = @('/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
        "/out:$exe", ('/win32icon:' + (Join-Path $PSScriptRoot 'exe\app.ico')),
        "/resource:$script,install.ps1", '/reference:System.Windows.Forms.dll',
        (Join-Path $PSScriptRoot 'exe\Launcher.cs'), $info)
    $output = & $csc @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "csc.exe failed:`n$($output -join "`n")" }
} finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Built $exe"
Write-Output "Version $version, $((Get-Item -LiteralPath $exe).Length) bytes, SHA-256 $hash"
