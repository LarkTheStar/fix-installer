# Audits every client manifest that CB Servers publishes in its updater repository
# (github.com/CBServers/updater, folder updater/) and decides, file by file, whether
# the installer may download it:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-CbManifestAudit.ps1
#
# Rules (see docs/cb-launcher/manifests.md):
#   1. A copy of one of the game's own files is never downloaded, whoever publishes it
#      (retail executables, the retail Bink/Miles libraries, BO3/BO4 executables, BO4
#      LPC game files). Where a client needs such a file under another name, the
#      installer makes it from the player's own copy when its SHA-1 matches ("derive").
#   2. Anything else is allowed only when the client project itself publishes it:
#      matched by SHA-1 or by name and size against the upstream release, archive or
#      manifest, or published by CB as a build of its own public GPL fork.
#   3. A file with no upstream trace is not downloaded.
#
# Writes docs/cb-launcher/audit.json (every entry with its verdict and evidence) and
# prints a summary. Network: api.github.com, raw.githubusercontent.com, the upstream
# release hosts, and the three upstream manifest servers named below. Nothing from
# CB's game-content CDN is requested.

param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\docs\cb-launcher\audit.json'),
    [string]$WorkFolder = (Join-Path ([IO.Path]::GetTempPath()) 'codhq-cb-audit')
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'Default TLS settings kept.' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$headers = @{ 'User-Agent' = 'codhq-cb-audit' }
$null = New-Item -ItemType Directory -Path $WorkFolder -Force
$updaterRaw = 'https://raw.githubusercontent.com/CBServers/updater/main/updater/'

function Get-Sha1Hex { param([byte[]]$Bytes) $sha = [Security.Cryptography.SHA1]::Create(); try { (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) -join '') } finally { $sha.Dispose() } }

# Reads a CB-format manifest: [path, size, sha1, dest?] entries plus {ManifestHash}.
function Read-CbManifest {
    param([string]$Url)
    $raw = Invoke-RestMethod -Uri $Url -Headers $headers
    $entries = foreach ($item in @($raw)) {
        if ($item -is [array] -or ($item -is [System.Collections.IList] -and $item -isnot [string])) {
            [pscustomobject]@{ Path = [string]$item[0]; Size = [int64]$item[1]; Sha1 = ([string]$item[2]).ToUpperInvariant(); Dest = $(if ($item.Count -gt 3) { [string]$item[3] } else { '' }) }
        }
    }
    $hash = (@($raw) | Where-Object { $_ -isnot [array] -and $null -ne $_.ManifestHash } | Select-Object -First 1).ManifestHash
    [pscustomobject]@{ Entries = @($entries); ManifestHash = [string]$hash }
}

# Evidence collectors. Each returns a list of @{ Key; Kind; Source } where Key is
# "sha1:<HEX>" or "name:<leaf>|<size>".
function Get-ZipEvidence {
    param([string]$Url, [string]$Label)
    $file = Join-Path $WorkFolder (($Label -replace '[^\w.-]', '_') + '.zip')
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $file -Headers $headers }
    $zip = [IO.Compression.ZipFile]::OpenRead($file)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.Name) { continue }
            $stream = $entry.Open(); $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
            [pscustomobject]@{ Key = 'sha1:' + (Get-Sha1Hex $memory.ToArray()); Kind = 'sha1'; Source = "$Label ($($entry.FullName))" }
        }
    } finally { $zip.Dispose() }
}

function Get-FileEvidence {
    param([string]$Url, [string]$Label)
    $file = Join-Path $WorkFolder (($Label -replace '[^\w.-]', '_') + '.bin')
    if (-not (Test-Path -LiteralPath $file)) { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $file -Headers $headers }
    [pscustomobject]@{ Key = 'sha1:' + (Get-Sha1Hex ([IO.File]::ReadAllBytes($file))); Kind = 'sha1'; Source = $Label }
}

function Get-ReleaseAssetEvidence {
    param([string]$Repo, [string]$Tag)
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $headers
    foreach ($asset in $release.assets) {
        [pscustomobject]@{ Key = 'name:' + $asset.name.ToLowerInvariant() + '|' + $asset.size; Kind = 'name+size'; Source = "$Repo $Tag asset $($asset.name)" }
        # iw4x-rawfiles publishes single files as __launcher_<name>_<ext>.bin.
        if ($asset.name -match '^__launcher_(.+)_([A-Za-z0-9]+)\.bin$') {
            [pscustomobject]@{ Key = 'name:' + ($Matches[1] + '.' + $Matches[2]).ToLowerInvariant() + '|' + $asset.size; Kind = 'name+size'; Source = "$Repo $Tag asset $($asset.name)" }
        }
    }
}

# Lists a large remote ZIP from its central directory only (HTTP range requests), so
# an 800 MB archive is checked without downloading it.
function Get-RemoteZipEvidence {
    param([string]$Url, [string]$Label)
    function Get-Range([string]$From, [int64]$Start, [int64]$Length) {
        $request = [Net.HttpWebRequest]::Create($From); $request.UserAgent = 'codhq-cb-audit'; $request.AllowAutoRedirect = $true
        if ($Start -lt 0) { $request.AddRange([int64]$Start) } else { $request.AddRange([int64]$Start, [int64]($Start + $Length - 1)) }
        $response = $request.GetResponse(); $memory = New-Object IO.MemoryStream
        try { $response.GetResponseStream().CopyTo($memory) } finally { $response.Dispose() }
        , $memory.ToArray()
    }
    # GitHub's storage rejects suffix ranges ("last N bytes"), so learn the size from
    # a one-byte request first and then ask for explicit ranges.
    $probe = [Net.HttpWebRequest]::Create($Url); $probe.UserAgent = 'codhq-cb-audit'; $probe.AddRange([int64]0, [int64]0)
    $probeResponse = $probe.GetResponse()
    try { $total = [int64](([string]$probeResponse.Headers['Content-Range']) -split '/')[-1] } finally { $probeResponse.Dispose() }
    $tailLength = [Math]::Min([int64]65557, $total)
    $tail = Get-Range $Url ($total - $tailLength) $tailLength
    $eocd = -1
    for ($i = $tail.Length - 22; $i -ge 0; $i--) { if ([BitConverter]::ToUInt32($tail, $i) -eq 0x06054b50) { $eocd = $i; break } }
    if ($eocd -lt 0) { throw "No end of central directory in $Label." }
    [int64]$cdSize = [BitConverter]::ToUInt32($tail, $eocd + 12); [int64]$cdOffset = [BitConverter]::ToUInt32($tail, $eocd + 16)
    if ($cdOffset -eq 0xFFFFFFFF -or $cdSize -eq 0xFFFFFFFF) {
        $locator = $eocd - 20
        if ([BitConverter]::ToUInt32($tail, $locator) -ne 0x07064b50) { throw "ZIP64 locator missing in $Label." }
        $zip64Offset = [BitConverter]::ToInt64($tail, $locator + 8)
        $zip64 = Get-Range $Url $zip64Offset 56
        $cdSize = [BitConverter]::ToInt64($zip64, 40); $cdOffset = [BitConverter]::ToInt64($zip64, 48)
    }
    $cd = Get-Range $Url $cdOffset $cdSize
    $position = 0
    while ($position + 46 -le $cd.Length -and [BitConverter]::ToUInt32($cd, $position) -eq 0x02014b50) {
        [int64]$size = [BitConverter]::ToUInt32($cd, $position + 24)
        $nameLength = [BitConverter]::ToUInt16($cd, $position + 28); $extraLength = [BitConverter]::ToUInt16($cd, $position + 30); $commentLength = [BitConverter]::ToUInt16($cd, $position + 32)
        $name = [Text.Encoding]::UTF8.GetString($cd, $position + 46, $nameLength)
        if ($size -eq 0xFFFFFFFF) {
            # ZIP64 extra field (id 0x0001) holds the real uncompressed size first.
            $extra = $position + 46 + $nameLength; $end = $extra + $extraLength
            while ($extra + 4 -le $end) { $id = [BitConverter]::ToUInt16($cd, $extra); $len = [BitConverter]::ToUInt16($cd, $extra + 2); if ($id -eq 1) { $size = [BitConverter]::ToInt64($cd, $extra + 4); break }; $extra += 4 + $len }
        }
        if (-not $name.EndsWith('/')) {
            $leaf = ($name -split '/')[-1]
            [pscustomobject]@{ Key = 'name:' + $leaf.ToLowerInvariant() + '|' + $size; Kind = 'name+size'; Source = "$Label ($name)" }
            [pscustomobject]@{ Key = 'path:' + $name.ToLowerInvariant() + '|' + $size; Kind = 'path+size'; Source = "$Label ($name)" }
        }
        $position += 46 + $nameLength + $extraLength + $commentLength
    }
}

function Get-Sha1ManifestEvidence {
    param([string]$Url, [string]$Label)
    # Assigned first: Windows PowerShell 5.1 passes a JSON array down the pipeline as
    # one object, so iterating the call directly would see a single "entry".
    $list = Invoke-RestMethod -Uri $Url -Headers $headers
    foreach ($item in @($list)) {
        if ($item -is [array]) { [pscustomobject]@{ Key = 'sha1:' + ([string]$item[2]).ToUpperInvariant(); Kind = 'sha1'; Source = "$Label ($($item[0]))" } }
    }
}

function Get-Iw3xEvidence {
    param([string]$Url)
    $manifest = Invoke-RestMethod -Uri $Url -Headers $headers
    $all = @($manifest.assets) + @($manifest.client, $manifest.launcher)
    foreach ($asset in $all) {
        $leaf = ([string]$asset.path -split '/')[-1]
        [pscustomobject]@{ Key = 'name:' + $leaf.ToLowerInvariant() + '|' + $asset.size; Kind = 'name+size'; Source = "iw3x manifest ($($asset.path))" }
    }
}

function Get-ShieldEvidence {
    param([string]$Url)
    $manifest = Invoke-RestMethod -Uri $Url -Headers $headers
    foreach ($file in $manifest.files) {
        $leaf = ([string]$file.path -split '/')[-1]
        [pscustomobject]@{ Key = 'name:' + $leaf.ToLowerInvariant() + '|' + $file.size; Kind = 'name+size'; Source = "Shield launcher manifest ($($file.path), component $($file.component))" }
    }
}

# ---------------------------------------------------------------------------
# Per-client rules. Deny = copies of the game's own files (rule 1); Derive = a denied
# name the installer builds from the player's own file; Fork = CB's public GPL fork.
# ---------------------------------------------------------------------------
$retailMiles = 'the game''s own Miles Sound System library (retail mss32.dll)'
$clients = @(
    @{ Manifest = 'alt-launchers.json'; Evidence = { Get-ZipEvidence 'https://github.com/alterware/alterware-launcher/releases/download/v0.11.6/alterware-launcher-x86_64-pc-windows-msvc.zip' 'alterware-launcher v0.11.6'; Get-FileEvidence 'https://cdn.plutonium.pw/updater/plutonium.exe' 'plutonium.exe (cdn.plutonium.pw)' } }
    @{ Manifest = 'iw4x.json'; Deny = @{ 'binkw32.dll' = 'the game''s own Bink video library'; 'mss32.dll' = $retailMiles }
       Evidence = { Get-ReleaseAssetEvidence 'iw4x/iw4x-client' 'r5318'; Get-ReleaseAssetEvidence 'iw4x/iw4x-rawfiles' 'v0.2.42'; Get-RemoteZipEvidence 'https://github.com/iw4x/iw4x-rawfiles/releases/download/v0.2.42/release.zip' 'iw4x-rawfiles v0.2.42 release.zip'; Get-RemoteZipEvidence 'https://github.com/iw4x/iw4x-rawfiles/releases/download/v0.2.42/__launcher_crash-reporter.zip' 'iw4x-rawfiles crash-reporter.zip'; Get-ZipEvidence 'https://github.com/alterware/alterware-launcher/releases/download/v0.11.6/alterware-launcher-x86_64-pc-windows-msvc.zip' 'alterware-launcher v0.11.6' } }
    @{ Manifest = 'cod4x-mp.json'; Deny = @{ 'iw3mp.exe' = 'the game''s own executable'; 'miles32.dll' = $retailMiles + ', renamed' }; Derive = @{ 'miles32.dll' = 'mss32.dll' }
       Evidence = { Get-ReleaseAssetEvidence 'callofduty4x/CoD4x_Client_pub' '21.8'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-mss' '1.0.2'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-launcher' '1.1.3' } }
    @{ Manifest = 'iw3x.json'; Deny = @{ 'iw3mp.exe' = 'the game''s own executable'; 'miles32.dll' = $retailMiles + ', renamed' }; Derive = @{ 'miles32.dll' = 'mss32.dll' }
       Evidence = { Get-Iw3xEvidence 'http://74.208.200.240/manifest.json' } }
    @{ Manifest = 'iw3sp-mod.json'; Deny = @{ 'miles32.dll' = $retailMiles + ', renamed' }; Derive = @{ 'miles32.dll' = 'mss32.dll' }
       Evidence = { Get-Sha1ManifestEvidence 'https://jerryalt.codeberg.page/files.json' 'iw3sp-mod files.json'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-mss' '1.0.2'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-launcher' '1.1.3' } }
    @{ Manifest = 'cod2x.json'; Deny = @{ 'mss32_original.dll' = $retailMiles + ', renamed' }; Derive = @{ 'mss32_original.dll' = 'mss32.dll' }
       Evidence = { Get-ZipEvidence 'https://github.com/callofduty2x/CoD2x/releases/download/v1.4.6.8/CoD2x_1.4.6.8_windows.zip' 'CoD2x v1.4.6.8' } }
    @{ Manifest = 'cod1x.json'; Deny = @{ 'codmp.exe' = 'the game''s own executable (patched)' }
       Evidence = { Get-ZipEvidence 'https://github.com/xtnded/codextended-client/releases/download/2697/CoD1x_Archive.zip' 'CoD1x 2697' } }
    @{ Manifest = 'coduox.json'; Deny = @{ 'coduomp.exe' = 'the game''s own executable (patched)' }; Evidence = { } }
    @{ Manifest = 'cod1.json'; Deny = @{ 'codmp.exe' = 'the game''s own executable' }; Evidence = { } }
    @{ Manifest = 'coduo.json'; Deny = @{ 'coduomp.exe' = 'the game''s own executable' }; Evidence = { } }
    @{ Manifest = 'cod4x.json'; Deny = @{ 'iw3mp.exe' = 'the game''s own executable'; 'miles32.dll' = $retailMiles + ', renamed' }
       Evidence = { Get-ReleaseAssetEvidence 'callofduty4x/CoD4x_Client_pub' '21.8'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-mss' '1.0.2'; Get-ReleaseAssetEvidence 'callofduty4x/CoD4x-launcher' '1.1.3' } }
    @{ Manifest = 't6.json'; Evidence = { Get-FileEvidence 'https://cdn.plutonium.pw/updater/plutonium.exe' 'plutonium.exe (cdn.plutonium.pw)'; Get-ReleaseAssetEvidence 'Rattpak/T6SP-Mod-Release' 'v1.0.0-Beta' } }
    @{ Manifest = 'iw6x.json'; Fork = 'https://github.com/CBServers/iw6-mod' }
    @{ Manifest = 'iw6x-dev.json'; Fork = 'https://github.com/CBServers/iw6-mod' }
    @{ Manifest = 's1x.json'; Fork = 'https://github.com/CBServers/s1-mod' }
    @{ Manifest = 's1x-dev.json'; Fork = 'https://github.com/CBServers/s1-mod' }
    @{ Manifest = 'boiii.json'; Fork = 'https://github.com/CBServers/boiii'; Deny = @{ 'blackops3.exe' = 'the game''s own executable (Black Ops III)' } }
    @{ Manifest = 'boiii-dev.json'; Fork = 'https://github.com/CBServers/boiii'; Deny = @{ 'blackops3.exe' = 'the game''s own executable (Black Ops III)' } }
    @{ Manifest = 'h1-mod/files.json'; Fork = 'https://github.com/CBServers/h1-mod' }
    @{ Manifest = 'iw7-mod/files.json'; Fork = 'https://github.com/CBServers/iw7-mod' }
    @{ Manifest = 'h2-mod.json'; Evidence = { Get-Sha1ManifestEvidence 'https://h2-mod.alicent.cat/files.json' 'h2-mod files.json' } }
    @{ Manifest = 'project-bo4.json'; Deny = @{ 'blackops4.exe' = 'the game''s own executable (Black Ops 4)'; '*lpc/*' = 'Black Ops 4 game data (LPC fastfiles, Shield "game" component)' }
       Evidence = { Get-ShieldEvidence 'https://github.com/NotNierPea/shield-launcher/releases/download/content/manifest.json' } }
    @{ Manifest = 'h2m.json'; Evidence = { } }
    @{ Manifest = 's2x.json'; Evidence = { } }
    @{ Manifest = 's2x-dev.json'; Evidence = { } }
)

$report = [System.Collections.Generic.List[object]]::new()
foreach ($client in $clients) {
    $name = $client.Manifest
    Write-Output "Auditing $name ..."
    $manifest = Read-CbManifest ($updaterRaw + $name)
    $index = @{}
    if ($client.Evidence) {
        foreach ($item in @(& $client.Evidence)) { if ($item -and -not $index.ContainsKey($item.Key)) { $index[$item.Key] = $item } }
    }
    $deny = if ($client.Deny) { $client.Deny } else { @{} }
    $derive = if ($client.Derive) { $client.Derive } else { @{} }
    $rows = foreach ($entry in $manifest.Entries) {
        $leaf = ($entry.Path -split '/')[-1].ToLowerInvariant()
        $denyReason = $null
        foreach ($pattern in $deny.Keys) { if ($leaf -like $pattern -or $entry.Path.ToLowerInvariant() -like $pattern) { $denyReason = $deny[$pattern]; break } }
        $verdict = ''; $evidence = ''
        if ($denyReason) {
            $deriveFrom = $null; foreach ($key in $derive.Keys) { if ($leaf -eq $key.ToLowerInvariant()) { $deriveFrom = $derive[$key] } }
            if ($deriveFrom) { $verdict = 'derive'; $evidence = "$denyReason; built from the player's own $deriveFrom when its SHA-1 is $($entry.Sha1)" }
            else { $verdict = 'denied'; $evidence = $denyReason }
        } elseif ($index.ContainsKey('sha1:' + $entry.Sha1)) { $verdict = 'allowed'; $evidence = 'SHA-1 match: ' + $index['sha1:' + $entry.Sha1].Source }
        elseif ($index.ContainsKey('path:' + $entry.Path.ToLowerInvariant() + '|' + $entry.Size)) { $verdict = 'allowed'; $evidence = 'path+size match: ' + $index['path:' + $entry.Path.ToLowerInvariant() + '|' + $entry.Size].Source }
        elseif ($index.ContainsKey('name:' + $leaf + '|' + $entry.Size)) { $verdict = 'allowed'; $evidence = 'name+size match: ' + $index['name:' + $leaf + '|' + $entry.Size].Source }
        elseif ($client.Fork) { $verdict = 'allowed'; $evidence = "build of CB's public GPL-3.0 fork $($client.Fork), published by CB" }
        else { $verdict = 'no-trace'; $evidence = 'no matching file in the client project''s published releases or manifests' }
        [pscustomobject]@{ Path = $entry.Path; Size = $entry.Size; Sha1 = $entry.Sha1; Dest = $entry.Dest; Verdict = $verdict; Evidence = $evidence }
    }
    $rows = @($rows)
    $counts = [ordered]@{}; foreach ($v in 'allowed', 'derive', 'denied', 'no-trace') { $counts[$v] = @($rows | Where-Object { $_.Verdict -eq $v }).Count }
    $report.Add([pscustomobject]@{ Manifest = $name; ManifestHash = $manifest.ManifestHash; Entries = $rows.Count; Counts = $counts; Files = $rows })
    Write-Output ("  {0} entries: {1} allowed, {2} derive, {3} denied, {4} no-trace" -f $rows.Count, $counts['allowed'], $counts['derive'], $counts['denied'], $counts['no-trace'])
}

$null = New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force
[pscustomobject]@{ Generated = [DateTime]::UtcNow.ToString('o'); Source = $updaterRaw; Manifests = $report.ToArray() } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "Written: $OutputPath"

# The readable version, next to the JSON: a summary per manifest, then every file
# that is not simply allowed (denied, derived or without an upstream trace).
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# CB client manifests: per-file audit')
$md.Add('')
$md.Add("Generated by ``tools/Invoke-CbManifestAudit.ps1`` on $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) UTC from ``$updaterRaw``. Every entry with its evidence is in ``audit.json``.")
$md.Add('')
$md.Add('Rules: a copy of one of the game''s own files is never downloaded (**denied**); where a client needs such a file under another name it is built from the player''s own copy when the SHA-1 matches (**derive**); anything else is **allowed** only when the client project itself publishes it; a file with no upstream trace is not downloaded (**no-trace**).')
$md.Add('')
$md.Add('| Manifest | Entries | Allowed | Derive | Denied | No trace |')
$md.Add('| --- | ---: | ---: | ---: | ---: | ---: |')
foreach ($m in $report) { $md.Add(('| `{0}` | {1} | {2} | {3} | {4} | {5} |' -f $m.Manifest, $m.Entries, $m.Counts['allowed'], $m.Counts['derive'], $m.Counts['denied'], $m.Counts['no-trace'])) }
foreach ($m in $report) {
    $notAllowed = @($m.Files | Where-Object { $_.Verdict -ne 'allowed' })
    $md.Add('')
    $md.Add("## ``$($m.Manifest)``")
    $md.Add('')
    $sources = @($m.Files | Where-Object { $_.Verdict -eq 'allowed' } | ForEach-Object { ($_.Evidence -replace '^[^:]+: ', '') -replace ' \(.*\)$', '' } | Sort-Object -Unique)
    if ($sources.Count -gt 0) { $md.Add('Allowed files trace to: ' + (($sources | Select-Object -First 6) -join '; ') + $(if ($sources.Count -gt 6) { '; ...' } else { '' })) ; $md.Add('') }
    if ($notAllowed.Count -eq 0) { $md.Add('Every file is allowed.'); continue }
    $md.Add('| File | Size | Verdict | Reason |')
    $md.Add('| --- | ---: | --- | --- |')
    $shown = 0
    foreach ($file in $notAllowed) {
        if ($shown -ge 40) { $md.Add("| ... | | | $($notAllowed.Count - 40) more, see audit.json |"); break }
        $md.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, '| `{0}` | {1:N0} | {2} | {3} |', $file.Path, $file.Size, $file.Verdict, $file.Evidence)); $shown++
    }
}
$mdPath = Join-Path (Split-Path -Parent $OutputPath) 'manifests.md'
$md | Set-Content -LiteralPath $mdPath -Encoding UTF8
Write-Output "Written: $mdPath"
