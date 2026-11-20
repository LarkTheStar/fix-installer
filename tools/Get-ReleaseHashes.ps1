# Prints the SHA-256 of every file in this repository's GitHub releases, as GitHub
# publishes them, in the form Get-ReleaseAssetHash in install.ps1 uses:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Get-ReleaseHashes.ps1
#
# Run it after uploading or replacing a release file, and paste the lines into
# Get-ReleaseAssetHash in the same commit. Until then, the utility refuses the new
# file (it does not match its pinned checksum), which is the point: nobody gets a
# file that was not checked in on purpose.

param([string]$Repository = 'LarkTheStar/fix-installer')

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'Using the default TLS settings.' }
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers @{ 'User-Agent' = 'codhq-release-hashes' }
$rows = foreach ($release in $releases) {
    foreach ($asset in $release.assets) {
        $digest = [string]$asset.digest
        if (-not $digest.StartsWith('sha256:')) { Write-Warning "GitHub published no SHA-256 for $($release.tag_name)/$($asset.name); download it and use Get-FileHash."; continue }
        [pscustomobject]@{ Name = [string]$asset.name; Hash = $digest.Substring(7) }
    }
}
$width = ($rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum + 2
foreach ($row in $rows) { Write-Output ("        {0} = '{1}'" -f ("'" + $row.Name + "'").PadRight($width), $row.Hash) }
