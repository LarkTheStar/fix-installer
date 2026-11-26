# Reads the CodHQ BOIII release our site publishes right now and compares it with the
# pin in install.ps1 (the ZIP's size and SHA-256, and how many files its manifest lists).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-BoiiiPin.ps1 -Check
#       Only reports: exits 1 when the site has moved on from the pin, 0 when they agree.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Update-BoiiiPin.ps1
#       Writes the published size, SHA-256 and file count into the BO3 catalogue entry
#       (and the count the test expects), then reads them back to prove the edit landed.
#
# Run the second form after the fork publishes a new v* tag, then run the tests: the
# live release test downloads the archive and checks every file against boiii.json, so a
# pin that was not updated fails there instead of reaching a user.

param(
    [string]$Site = 'https://larkthestar.github.io/codhq-boiii/',
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'),
    [string]$TestsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\install.Tests.ps1'),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'Using the default TLS settings.' }

$base = $Site.TrimEnd('/')
$manifestUrl = $base + '/boiii.json'
$archiveUrl = $base + '/codhq-boiii.zip'

# What the site publishes now. Windows PowerShell 5.1's Invoke-RestMethod flattens a
# JSON array of arrays, so the text is parsed with ConvertFrom-Json instead.
Write-Host "Reading $manifestUrl ..."
$web = New-Object Net.WebClient
$web.Headers.Add('User-Agent', 'codhq-boiii-pin')
$manifest = @($web.DownloadString($manifestUrl) | ConvertFrom-Json)
# Depending on how the text reaches ConvertFrom-Json, the whole list arrives as one
# element holding the entries; unwrap that instead of reading it as one file.
while ($manifest.Count -eq 1 -and $manifest[0] -is [Array] -and @($manifest[0]).Count -ne 3) {
    $manifest = @($manifest[0])
}
$publishedCount = $manifest.Count
if ($publishedCount -le 0) { throw "$manifestUrl lists no files; the release is not usable." }
foreach ($entry in $manifest) {
    if (@($entry).Count -ne 3) { throw "$manifestUrl has an entry that is not [path, size, sha1]; the release is not usable." }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('codhq-pin-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp -Force
try {
    $zip = Join-Path $temp 'codhq-boiii.zip'
    Write-Host "Downloading $archiveUrl ..."
    $web.DownloadFile($archiveUrl, $zip)
    $publishedSize = (Get-Item -LiteralPath $zip).Length
    $publishedSha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# What install.ps1 pins now.
$bytes = [IO.File]::ReadAllBytes($Path)
$text = [Text.Encoding]::ASCII.GetString($bytes)
$start = $text.IndexOf("-Id 'boiii-codhq'")
if ($start -lt 0) { throw "$Path has no boiii-codhq catalogue entry." }
$end = $text.IndexOf('-Recommended', $start)
if ($end -lt 0) { throw "The boiii-codhq entry in $Path has no -Recommended marker to delimit it." }
$block = $text.Substring($start, $end - $start)

$pinPattern = "-Archive @\{ Url = '([^']+)'; Size = (\d+); Sha256 = '([0-9A-Fa-f]{64})' \}"
$countPattern = '-ManifestCount (\d+)'
$pinMatch = [regex]::Match($block, $pinPattern)
$countMatch = [regex]::Match($block, $countPattern)
if (-not $pinMatch.Success) { throw "The boiii-codhq entry in $Path has no pinned archive." }
if (-not $countMatch.Success) { throw "The boiii-codhq entry in $Path has no ManifestCount." }

$pinnedUrl = $pinMatch.Groups[1].Value
$pinnedSize = [int64]$pinMatch.Groups[2].Value
$pinnedSha = $pinMatch.Groups[3].Value.ToUpperInvariant()
$pinnedCount = [int]$countMatch.Groups[1].Value

$matches = $pinnedUrl -eq $archiveUrl -and $pinnedSize -eq $publishedSize -and $pinnedSha -eq $publishedSha -and $pinnedCount -eq $publishedCount

Write-Output ''
Write-Output ('{0,-14} {1,12}  {2}' -f 'Field', 'Value', 'Source')
Write-Output ('{0,-14} {1,12}  {2}' -f 'Archive size', $pinnedSize, 'install.ps1')
Write-Output ('{0,-14} {1,12}  {2}' -f 'Archive size', $publishedSize, 'published')
Write-Output ('{0,-14} {1,12}  {2}' -f 'File count', $pinnedCount, 'install.ps1')
Write-Output ('{0,-14} {1,12}  {2}' -f 'File count', $publishedCount, 'published')
Write-Output ('{0,-14} {1} (pinned)' -f 'SHA-256', $pinnedSha.Substring(0, 16))
Write-Output ('{0,-14} {1} (published)' -f 'SHA-256', $publishedSha.Substring(0, 16))
Write-Output ''

if ($matches) {
    Write-Output "The pin in install.ps1 matches the release at $base."
    exit 0
}

if ($Check) {
    Write-Output "The release at $base does not match the pin in install.ps1."
    Write-Output "Run this script without -Check to update the pin, then run the tests."
    exit 1
}

# Replace only the three values inside the CodHQ BOIII entry.
$newBlock = [regex]::Replace($block, $pinPattern, { param($m) "-Archive @{ Url = '$archiveUrl'; Size = $publishedSize; Sha256 = '$publishedSha' }" })
$newBlock = [regex]::Replace($newBlock, $countPattern, "-ManifestCount $publishedCount")
$newText = $text.Substring(0, $start) + $newBlock + $text.Substring($end)

if ([Text.Encoding]::ASCII.GetByteCount($newText) -ne $newText.Length) { throw 'The edited script would contain non-ASCII characters; nothing was written.' }
[IO.File]::WriteAllBytes($Path, [Text.Encoding]::ASCII.GetBytes($newText))

# The catalogue test pins the same count; keep the two from drifting apart.
if (Test-Path -LiteralPath $TestsPath) {
    $testBytes = [IO.File]::ReadAllBytes($TestsPath)
    $testText = [Text.Encoding]::ASCII.GetString($testBytes)
    $testPattern = '(?<prefix>\[int\]\$client\.ManifestCount \| Should -Be )(?<count>\d+)'
    $testMatch = [regex]::Match($testText, $testPattern)
    if ($testMatch.Success -and [int]$testMatch.Groups['count'].Value -ne $publishedCount) {
        $testText = [regex]::Replace($testText, $testPattern, { param($m) $m.Groups['prefix'].Value + $publishedCount })
        [IO.File]::WriteAllBytes($TestsPath, [Text.Encoding]::ASCII.GetBytes($testText))
        Write-Output "Updated the expected count in $TestsPath."
    }
}

# Read the edited entry back instead of trusting the replacement.
$written = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path))
$writtenBlock = $written.Substring($written.IndexOf("-Id 'boiii-codhq'"))
$writtenBlock = $writtenBlock.Substring(0, $writtenBlock.IndexOf('-Recommended'))
$writtenPin = [regex]::Match($writtenBlock, $pinPattern)
$writtenCount = [regex]::Match($writtenBlock, $countPattern)
if (-not $writtenPin.Success -or -not $writtenCount.Success) { throw "The pin could not be read back from $Path." }
if ([int64]$writtenPin.Groups[2].Value -ne $publishedSize -or $writtenPin.Groups[3].Value.ToUpperInvariant() -ne $publishedSha -or [int]$writtenCount.Groups[1].Value -ne $publishedCount) {
    throw "The pin read back from $Path does not match the published release."
}

Write-Output "Updated ${Path}: size $publishedSize, SHA-256 $($publishedSha.Substring(0, 16))..., $publishedCount files."
Write-Output 'Run .\tests\Invoke-Tests.ps1 (both PowerShell 5.1 and 7) before committing.'
exit 0
