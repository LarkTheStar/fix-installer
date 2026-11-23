# Lists the files inside a remote ZIP archive (name, size, CRC-32) without downloading
# it: only the archive's central directory is read, with HTTP range requests. With
# -CompareFolder, each entry is compared with the file of the same relative path in a
# local folder, which is how docs/cod1-uo-files.md was made (an archive of the game's
# 1.1 / 1.5 / 1.51 files against the Steam install).
#
#   .\tools\Get-RemoteZipListing.ps1 -Url <zip url> [-CompareFolder <game folder>] [-StripPrefix 'Folder/']
#
# The server must honour Range requests. Nothing but the directory is fetched.

param(
    [Parameter(Mandatory)][string]$Url,
    [string]$CompareFolder = '',
    # Leading folder of the entry names to drop before comparing (e.g. 'Call of Duty - R/').
    [string]$StripPrefix = ''
)

$ErrorActionPreference = 'Stop'

function Get-Range {
    param([int64]$From, [int64]$To)
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'CallOfDutyHQ-SetupUtility/1.1'
    $request.AddRange($From, $To)
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 206) { throw "The server ignored the range request (HTTP $([int]$response.StatusCode)); not downloading the whole archive." }
        $buffer = New-Object IO.MemoryStream
        $response.GetResponseStream().CopyTo($buffer)
        return , $buffer.ToArray()
    } finally { $response.Close() }
}

function Get-FileCrc32Local {
    param([string]$Path)
    if (-not ('CodHqCrc32Tool' -as [type])) {
        Add-Type -TypeDefinition @'
public static class CodHqCrc32Tool {
    static readonly uint[] Table = Build();
    static uint[] Build() { var t = new uint[256]; for (uint i = 0; i < 256; i++) { uint c = i; for (int k = 0; k < 8; k++) { c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1); } t[i] = c; } return t; }
    public static uint OfFile(string path) { uint c = 0xFFFFFFFFu; var b = new byte[1 << 20]; using (var f = System.IO.File.OpenRead(path)) { int n; while ((n = f.Read(b, 0, b.Length)) > 0) { for (int i = 0; i < n; i++) { c = Table[(c ^ b[i]) & 0xFF] ^ (c >> 8); } } } return c ^ 0xFFFFFFFFu; }
}
'@
    }
    return ([CodHqCrc32Tool]::OfFile($Path)).ToString('X8')
}

$head = [Net.HttpWebRequest]::Create($Url)
$head.Method = 'HEAD'; $head.UserAgent = 'CallOfDutyHQ-SetupUtility/1.1'
$response = $head.GetResponse()
$length = [int64]$response.Headers['Content-Length']
$response.Close()
if ($length -le 22) { throw 'The server did not report the archive size.' }

# End of central directory record (and the ZIP64 one for archives over 4 GB).
$tailLength = [Math]::Min([int64]70000, $length)
$tail = Get-Range ($length - $tailLength) ($length - 1)
$eocd = -1
for ($i = $tail.Length - 22; $i -ge 0; $i--) { if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and $tail[$i + 2] -eq 5 -and $tail[$i + 3] -eq 6) { $eocd = $i; break } }
if ($eocd -lt 0) { throw 'This is not a ZIP archive (no central directory found).' }
$directorySize = [int64][BitConverter]::ToUInt32($tail, $eocd + 12)
$directoryOffset = [int64][BitConverter]::ToUInt32($tail, $eocd + 16)
if ($directoryOffset -eq 0xFFFFFFFF -and $eocd -ge 20) {
    $zip64 = [BitConverter]::ToInt64($tail, $eocd - 20 + 8)
    $record = Get-Range $zip64 ($zip64 + 55)
    $directorySize = [BitConverter]::ToInt64($record, 40)
    $directoryOffset = [BitConverter]::ToInt64($record, 48)
}
$directory = Get-Range $directoryOffset ($directoryOffset + $directorySize - 1)

$entries = [System.Collections.Generic.List[object]]::new()
$p = 0
while ($p + 46 -le $directory.Length -and [BitConverter]::ToUInt32($directory, $p) -eq 0x02014B50) {
    $nameLength = [BitConverter]::ToUInt16($directory, $p + 28)
    $extraLength = [BitConverter]::ToUInt16($directory, $p + 30)
    $commentLength = [BitConverter]::ToUInt16($directory, $p + 32)
    $name = [Text.Encoding]::UTF8.GetString($directory, $p + 46, $nameLength)
    if (-not $name.EndsWith('/')) {
        $entries.Add([pscustomobject]@{ Name = $name; Size = [int64][BitConverter]::ToUInt32($directory, $p + 24); Crc32 = ([BitConverter]::ToUInt32($directory, $p + 16)).ToString('X8') })
    }
    $p += 46 + $nameLength + $extraLength + $commentLength
}

if (-not $CompareFolder) { $entries; return }

$root = [IO.Path]::GetFullPath($CompareFolder).TrimEnd('\')
foreach ($entry in $entries) {
    $relative = $entry.Name
    if ($StripPrefix -and $relative.StartsWith($StripPrefix, [StringComparison]::OrdinalIgnoreCase)) { $relative = $relative.Substring($StripPrefix.Length) }
    $local = Join-Path $root ($relative -replace '/', '\')
    $state = if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { 'not in folder' }
             elseif ((Get-Item -LiteralPath $local).Length -ne $entry.Size) { 'differs' }
             elseif ((Get-FileCrc32Local $local) -ne $entry.Crc32) { 'differs' }
             else { 'same' }
    [pscustomobject]@{ Path = $relative; Size = $entry.Size; Crc32 = $entry.Crc32; Local = $state }
}
