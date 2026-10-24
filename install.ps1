& {
# Call of Duty HQ Fix Installer + Multi-Language Manager
# Made for luatools <3
# By Lark
# Repository: https://github.com/LarkTheStar/fix-installer
# Release asset: Call.of.Duty.Modern.Warfare.4.fix.v2.zip
# Steam AppID 1938090 is the shared Call of Duty HQ installation.

$ErrorActionPreference = 'Stop'

$AppId = '1938090'
$ReleaseTag = '1.0.0'
$ZipFileName = 'Call.of.Duty.Modern.Warfare.4.fix.v2.zip'
$ZipUrl = "https://github.com/LarkTheStar/fix-installer/releases/download/$ReleaseTag/$ZipFileName"

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}
function Write-Warn([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}
function Write-Ok([string]$Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}
function Stop-Installer([string]$Message) {
    throw $Message
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (Test-Path -LiteralPath $expanded -PathType Container) {
        $full = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
        foreach ($existing in $List) {
            if ($existing.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
                return
            }
        }
        $List.Add($full)
    }
}

function Get-SteamLibraries {
    $libraries = [System.Collections.Generic.List[string]]::new()

    $registryKeys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($key in $registryKeys) {
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if ($item.SteamPath) { Add-UniquePath $libraries $item.SteamPath }
            if ($item.InstallPath) { Add-UniquePath $libraries $item.InstallPath }
        } catch {}
    }

    Add-UniquePath $libraries "${env:ProgramFiles(x86)}\Steam"
    Add-UniquePath $libraries "$env:ProgramFiles\Steam"

    # Include every library listed in each Steam installation's libraryfolders.vdf.
    $steamRoots = @($libraries.ToArray())
    foreach ($steamRoot in $steamRoots) {
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $contents = Get-Content -LiteralPath $vdf -Raw
            foreach ($match in [regex]::Matches($contents, '"path"\s*"([^"]+)"')) {
                $libraryPath = $match.Groups[1].Value -replace '\\\\', '\'
                Add-UniquePath $libraries $libraryPath
            }
        }
    }
    return $libraries.ToArray()
}

function Find-CallOfDutyHQ {
    $matches = [System.Collections.Generic.List[string]]::new()

    foreach ($library in (Get-SteamLibraries)) {
        $manifest = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }

        $contents = Get-Content -LiteralPath $manifest -Raw
        $installMatch = [regex]::Match($contents, '"installdir"\s*"([^"]+)"')
        if (-not $installMatch.Success) { continue }

        $installDir = $installMatch.Groups[1].Value
        # Prevent a malformed manifest value from escaping steamapps\common.
        if ([IO.Path]::IsPathRooted($installDir) -or $installDir.Contains('..') -or $installDir.Contains(':')) {
            continue
        }

        $candidate = [IO.Path]::GetFullPath((Join-Path $library "steamapps\common\$installDir"))
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            if (-not ($matches | Where-Object { $_.Equals($candidate, [StringComparison]::OrdinalIgnoreCase) })) {
                $matches.Add($candidate)
            }
        }
    }
    return $matches.ToArray()
}

function Select-TargetFolder {
    $found = @(Find-CallOfDutyHQ)

    if ($found.Count -eq 1) {
        $target = $found[0]
        Write-Info "Detected Steam Call of Duty HQ installation:"
        Write-Host "  $target"
        $answer = Read-Host 'Use this folder? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes)$') {
            return $target
        }
    } elseif ($found.Count -gt 1) {
        Write-Info 'Multiple Call of Duty HQ installations were found:'
        for ($i = 0; $i -lt $found.Count; $i++) {
            Write-Host "  [$($i + 1)] $($found[$i])"
        }
        while ($true) {
            $choice = Read-Host "Choose a folder (1-$($found.Count)), or enter a different path"
            $number = 0
            if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $found.Count) {
                return $found[$number - 1]
            }
            if (Test-Path -LiteralPath $choice -PathType Container) {
                return [IO.Path]::GetFullPath($choice)
            }
            Write-Warn 'That selection is not a valid folder.'
        }
    } else {
        Write-Warn "Could not automatically locate appmanifest_$AppId.acf and its install folder."
    }

    while ($true) {
        $manual = Read-Host 'Enter the full path to the Call of Duty HQ folder (or press Enter to cancel)'
        if ([string]::IsNullOrWhiteSpace($manual)) {
            Stop-Installer 'Installation cancelled.'
        }
        if (Test-Path -LiteralPath $manual -PathType Container) {
            $full = [IO.Path]::GetFullPath($manual)
            $leaf = Split-Path -Leaf $full
            if ($leaf -notmatch '^Call of Duty HQ$') {
                $confirm = Read-Host "This folder is named '$leaf', not 'Call of Duty HQ'. Use it anyway? [y/N]"
                if ($confirm -notmatch '^(y|yes)$') { continue }
            }
            return $full
        }
        Write-Warn 'Folder not found. Enter an existing folder path.'
    }
}

function Get-ValidatedRelativePath([string]$EntryName) {
    $name = $EntryName -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($name)) { Stop-Installer 'ZIP contains an empty path.' }
    if ($name.StartsWith('\') -or [IO.Path]::IsPathRooted($name) -or $name -match '^[A-Za-z]:') {
        Stop-Installer "ZIP contains an absolute path: $EntryName"
    }

    $segments = $name.Split('\')
    foreach ($segment in $segments) {
        if ($segment -eq '..' -or $segment -eq '.' -or
            $segment.Contains(':') -or $segment.EndsWith(' ') -or $segment.EndsWith('.')) {
            Stop-Installer "ZIP contains an unsafe path: $EntryName"
        }
        if ($segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') {
            Stop-Installer "ZIP contains a reserved Windows filename: $EntryName"
        }
    }
    # Reserve this directory for backups; package contents must not overwrite backups.
    if ($name -match '^(?i:og files|language files)(\\|$)') {
        Stop-Installer "ZIP attempts to write into the reserved backup folder: $EntryName"
    }
    return $name
}

function Copy-StreamToFile {
    param(
        [System.IO.Stream]$InputStream,
        [string]$Destination
    )
    $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $InputStream.CopyTo($output)
    } finally {
        $output.Dispose()
    }
}

function Download-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )

    # GitHub requires modern TLS on many Windows installations.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'CallOfDutyHQ-SetupUtility/1.1'
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $total = [int64]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (1024 * 1024)
        [int64]$downloaded = 0
        $lastPercent = -1
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($total -gt 0) {
                $percent = [int][Math]::Min(100, [Math]::Floor(($downloaded * 100.0) / $total))
                $downloadedMB = [Math]::Round($downloaded / 1MB, 1)
                $totalMB = [Math]::Round($total / 1MB, 1)
                if ($percent -ne $lastPercent) {
                    Write-Progress -Activity $Label -Status "$downloadedMB MB of $totalMB MB ($percent%)" -PercentComplete $percent
                    $lastPercent = $percent
                }
            } else {
                Write-Progress -Activity $Label -Status ("Downloaded {0:N1} MB" -f ($downloaded / 1MB)) -PercentComplete 0
            }
        }
        $outputStream.Flush()
        if ($downloaded -le 0) { throw 'The server returned an empty download.' }
        if ($total -gt 0 -and $downloaded -ne $total) {
            throw "Download appears incomplete: received $downloaded of $total bytes."
        }
        Write-Progress -Activity $Label -Completed
        Write-Ok ("Download complete: {0:N1} MB" -f ($downloaded / 1MB))
    } catch {
        Write-Progress -Activity $Label -Completed
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        throw "Download failed: $($_.Exception.Message)"
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Get-FolderSizeBytes {
    param([Parameter(Mandatory)][string]$Path)
    [int64]$sum = 0
    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $sum += [int64]$_.Length }
    return $sum
}

function Install-Fix {
$workRoot = Join-Path $env:TEMP ("codhq-fix-installer-" + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $workRoot $ZipFileName
$stageRoot = Join-Path $workRoot 'staged'
$archive = $null

try {
    Write-Host ''
    Write-Host 'Call of Duty HQ Fix Installer' -ForegroundColor White
    Write-Host 'This installer will replace matching files in the selected game folder.' -ForegroundColor White
    Write-Host ''

    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        Stop-Installer "Target folder does not exist: $targetRoot"
    }

    Write-Host ''
    Write-Host "Target folder: $targetRoot" -ForegroundColor Yellow
    Write-Warn 'Existing files with matching names will be overwritten. Replaced originals will be backed up in a timestamped "og files" folder inside the game directory.'
    $proceed = Read-Host 'Continue? [y/N]'
    if ($proceed -notmatch '^(y|yes)$') {
        Stop-Installer 'Installation cancelled.'
    }

    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    Write-Info "Downloading release asset $ZipFileName ..."
    Download-FileWithProgress -Url $ZipUrl -Destination $zipPath -Label "Downloading fix: $ZipFileName"

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -le 0) {
        Stop-Installer 'The ZIP download is missing or empty.'
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)

    if ($archive.Entries.Count -eq 0) {
        Stop-Installer 'The downloaded ZIP is empty.'
    }
    if ($archive.Entries.Count -gt 20000) {
        Stop-Installer 'The ZIP contains an unexpectedly large number of entries; refusing to continue.'
    }

    $planned = [System.Collections.Generic.List[object]]::new()
    $totalUncompressed = [int64]0
    foreach ($entry in $archive.Entries) {
        $relative = Get-ValidatedRelativePath $entry.FullName
        $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
        if ($isDirectory) { continue }

        # Reject Unix symbolic-link entries. They can redirect writes outside the target tree.
        $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixMode -eq 0xA000) {
            Stop-Installer "ZIP contains a symbolic link, which is not allowed: $($entry.FullName)"
        }

        $totalUncompressed += [int64]$entry.Length
        if ($totalUncompressed -gt 5GB) {
            Stop-Installer 'The ZIP expands to more than 5 GB; refusing to continue.'
        }

        # Normalize roots before comparing them with the resolved file paths.
        $stageRootFull = [IO.Path]::GetFullPath($stageRoot).TrimEnd([char[]]@('\', '/'))
        $stagePath = [IO.Path]::GetFullPath((Join-Path $stageRootFull $relative))
        $stagePrefix = $stageRootFull + [IO.Path]::DirectorySeparatorChar
        if (-not $stagePath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Installer "ZIP path escapes the staging folder: $($entry.FullName)"
        }

        $targetRootFull = [IO.Path]::GetFullPath($targetRoot).TrimEnd([char[]]@('\', '/'))
        $targetPath = [IO.Path]::GetFullPath((Join-Path $targetRootFull $relative))
        $targetPrefix = $targetRootFull + [IO.Path]::DirectorySeparatorChar
        if (-not $targetPath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Installer "ZIP path escapes the game folder: $($entry.FullName)"
        }

        $planned.Add([pscustomobject]@{
            Relative = $relative
            StagePath = $stagePath
            TargetPath = $targetPath
            Entry = $entry
        })
    }

    if ($planned.Count -eq 0) {
        Stop-Installer 'The ZIP contains no files to install.'
    }

    Write-Info "Checking and staging $($planned.Count) files..."
    foreach ($item in $planned) {
        $parent = Split-Path -Parent $item.StagePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $inputStream = $item.Entry.Open()
        try {
            $outputStream = [IO.File]::Open($item.StagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $inputStream.CopyTo($outputStream)
            } finally {
                $outputStream.Dispose()
            }
        } finally {
            $inputStream.Dispose()
        }
    }
    $archive.Dispose()
    $archive = $null

    # Keep replaced originals inside the game root, under a timestamped "og files" folder.
    # ZIP entries targeting this reserved folder are rejected during path validation.
    $backupBase = Join-Path $targetRoot 'og files'
    if (Test-Path -LiteralPath $backupBase) {
        $backupBaseItem = Get-Item -LiteralPath $backupBase -Force
        if (-not $backupBaseItem.PSIsContainer -or
            (($backupBaseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Stop-Installer "The reserved backup path is not a normal directory: $backupBase"
        }
    }
    $backupRoot = Join-Path $backupBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $createdTargets = [System.Collections.Generic.List[string]]::new()
    $backedUpTargets = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($item in $planned) {
            $destination = $item.TargetPath
            $parent = Split-Path -Parent $destination

            # Avoid writing through existing junctions/symlinks in the destination path.
            $cursor = $parent
            while ($cursor -and $cursor.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
                if (Test-Path -LiteralPath $cursor) {
                    $attributes = [IO.File]::GetAttributes($cursor)
                    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        Stop-Installer "A junction or symbolic link exists in the destination path: $cursor"
                    }
                }
                if ($cursor.Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
                $cursor = Split-Path -Parent $cursor
            }

            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            if (Test-Path -LiteralPath $destination) {
                $existingItem = Get-Item -LiteralPath $destination -Force
                if ($existingItem.PSIsContainer) {
                    Stop-Installer "A destination file conflicts with an existing directory: $destination"
                }
                if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Stop-Installer "A symbolic link or reparse point exists at the destination file: $destination"
                }
                $relative = $item.Relative
                $backupPath = Join-Path $backupRoot $relative
                $backupParent = Split-Path -Parent $backupPath
                if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
                    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
                }
                Copy-Item -LiteralPath $destination -Destination $backupPath
                $backedUpTargets.Add([pscustomobject]@{ Target = $destination; Backup = $backupPath })
            } else {
                $createdTargets.Add($destination)
            }

            Copy-Item -LiteralPath $item.StagePath -Destination $destination -Force
        }
    } catch {
        Write-Warn 'Installation failed. Attempting to restore replaced files...'
        foreach ($newFile in $createdTargets) {
            try {
                if (Test-Path -LiteralPath $newFile -PathType Leaf) {
                    Remove-Item -LiteralPath $newFile -Force
                }
            } catch {}
        }
        for ($i = $backedUpTargets.Count - 1; $i -ge 0; $i--) {
            $record = $backedUpTargets[$i]
            try {
                Copy-Item -LiteralPath $record.Backup -Destination $record.Target -Force
            } catch {
                Write-Warn "Could not automatically restore: $($record.Target)"
            }
        }
        throw
    }

    Write-Ok 'Installation completed successfully.'
    if ($backedUpTargets.Count -gt 0) {
        Write-Info "Backed up $($backedUpTargets.Count) replaced file(s) to:"
        Write-Host "  $backupRoot"
    } else {
        Write-Info 'No existing files needed to be backed up.'
    }

    # Launch the requested batch file only after every install operation succeeds.
    $launcherPath = Join-Path $targetRoot '!start_sp26.bat'
    Write-Host ''
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        $launchAnswer = Read-Host 'Installation succeeded. Run !start_sp26.bat now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($launchAnswer) -or $launchAnswer -match '^(y|yes)$') {
            Write-Info 'Launching !start_sp26.bat ...'
            # Run from the game root so relative paths used by the batch file resolve correctly.
            Start-Process -FilePath $env:ComSpec `
                -ArgumentList @('/c', ('"' + $launcherPath + '"')) `
                -WorkingDirectory $targetRoot
            Write-Ok 'Launch command started.'
        } else {
            Write-Info 'Launch skipped. You can run !start_sp26.bat from the game folder later.'
        }
    } else {
        Write-Warn "Installation succeeded, but !start_sp26.bat was not found in the game root:"
        Write-Host "  $launcherPath"
        Write-Info 'If the batch file is in a subfolder, update the configured launcher path in install.ps1.'
    }
}
catch {
    Write-Host ''
    Write-Host "INSTALLER ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'No administrator privileges are required for this installer.' -ForegroundColor Yellow
    Write-Host 'If the download failed, check the release asset URL and your internet connection.' -ForegroundColor Yellow
}
finally {
    if ($archive) {
        try { $archive.Dispose() } catch {}
    }
    if (Test-Path -LiteralPath $workRoot) {
        try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}
}


# Language-pack catalog. Split assets are concatenated in the listed order.
# Configuration values for Japanese, Korean, Traditional Chinese, and Simplified Chinese
# were supplied by the repository owner: japanese, koreana, tchinese, schinese.
$LanguagePacks = [ordered]@{
    'Arabic' = [pscustomobject]@{ File = 'Arabic.zip'; Value = 'arabic'; Assets = @('Arabic.zip') }
    'French' = [pscustomobject]@{ File = 'French.zip'; Value = 'french'; Assets = @('French.zip') }
    'German' = [pscustomobject]@{ File = 'German.zip'; Value = 'german'; Assets = @('German.zip') }
    'Italian' = [pscustomobject]@{ File = 'Italian.zip'; Value = 'italian'; Assets = @('Italian.zip') }
    'Japanese' = [pscustomobject]@{ File = 'Japanese.zip'; Value = 'japanese'; Assets = @('Japanese.zip.part001', 'Japanese.zip.part002') }
    'Korean' = [pscustomobject]@{ File = 'Korean.zip'; Value = 'koreana'; Assets = @('Korean.zip.part001', 'Korean.zip.part002') }
    'Polish' = [pscustomobject]@{ File = 'Polish.zip'; Value = 'polish'; Assets = @('Polish.zip') }
    'Portuguese (Brazil)' = [pscustomobject]@{ File = 'Portuguese.-.Brazil.zip'; Value = 'brazilian'; Assets = @('Portuguese.-.Brazil.zip') }
    'Russian' = [pscustomobject]@{ File = 'Russian.zip'; Value = 'russian'; Assets = @('Russian.zip') }
    'Simplified Chinese' = [pscustomobject]@{ File = 'Simplified-Chinese.zip'; Value = 'schinese'; Assets = @('Simplified-Chinese.zip.part001', 'Simplified-Chinese.zip.part002') }
    'Spanish (Latin America)' = [pscustomobject]@{ File = 'Spanish.-.Latin.America.zip'; Value = 'latam'; Assets = @('Spanish.-.Latin.America.zip') }
    'Spanish (Spain)' = [pscustomobject]@{ File = 'Spanish.-.Spain.zip'; Value = 'spanish'; Assets = @('Spanish.-.Spain.zip') }
    'Traditional Chinese' = [pscustomobject]@{ File = 'Traditional.Chinese.zip'; Value = 'tchinese'; Assets = @('Traditional.Chinese.zip') }
}

function Get-LanguageManagerRoot {
    param([Parameter(Mandatory)][string]$TargetRoot)
    return (Join-Path $TargetRoot 'language files\language-pack-manager')
}

function Get-LanguageStatePath {
    param([Parameter(Mandatory)][string]$ManagerRoot)
    return (Join-Path $ManagerRoot 'state.json')
}

function Get-ConfigLanguageValue {
    param([Parameter(Mandatory)][string]$IniPath)
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw "Configuration file not found: $IniPath" }
    $content = [IO.File]::ReadAllText($IniPath)
    $matches = [regex]::Matches($content, '(?im)^[ \t]*language[ \t]*=[ \t]*(.*?)[ \t]*\r?$')
    if ($matches.Count -ne 1) {
        throw "Expected exactly one existing language= line in '$IniPath'; found $($matches.Count). The file was not changed."
    }
    return $matches[0].Groups[1].Value.Trim()
}

function Set-ConfigLanguageValue {
    param(
        [Parameter(Mandatory)][string]$IniPath,
        [Parameter(Mandatory)][string]$Language
    )
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw "Configuration file not found: $IniPath" }
    $content = [IO.File]::ReadAllText($IniPath)
    # Match the line contents but not CR/LF, preserving the file's existing line endings.
    $matches = [regex]::Matches($content, '(?im)^[ \t]*language[ \t]*=[^\r\n]*')
    if ($matches.Count -ne 1) {
        throw "Expected exactly one existing language= line in '$IniPath'; found $($matches.Count). The file was not changed."
    }
    $m = $matches[0]
    $updated = $content.Substring(0, $m.Index) + "language=$Language" + $content.Substring($m.Index + $m.Length)
    $tempIni = "$IniPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempIni, $updated, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempIni -Destination $IniPath -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tempIni -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Save-LanguageManagerState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ManagerRoot
    )
    $statePath = Get-LanguageStatePath -ManagerRoot $ManagerRoot
    $tempPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $statePath -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-LanguageManagerState {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$IniPath,
        [switch]$Create
    )
    $managerRoot = Get-LanguageManagerRoot -TargetRoot $TargetRoot
    $statePath = Get-LanguageStatePath -ManagerRoot $managerRoot
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if (-not ([string]$state.TargetRoot).Equals($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Language manager state belongs to a different game folder: $($state.TargetRoot)"
        }
        if (-not (Test-Path -LiteralPath ([string]$state.OriginalIniBackup) -PathType Leaf)) {
            throw "The manager's original configuration backup is missing: $($state.OriginalIniBackup). State was not changed."
        }
        return $state
    }
    if (-not $Create) { return $null }

    # Do not guess how to merge older per-install manifests: they may have been created
    # by a manager that overwrote shared files. Refuse to begin a new ownership ledger
    # until those legacy records are handled with the prior script or after a clean backup.
    $legacyRoots = @()
    if (Test-Path -LiteralPath $managerRoot -PathType Container) { $legacyRoots += $managerRoot }
    $legacyOldRoot = Join-Path $TargetRoot 'og files\language-pack-manager'
    if (Test-Path -LiteralPath $legacyOldRoot -PathType Container) { $legacyRoots += $legacyOldRoot }
    $legacy = @($legacyRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue })
    if ($legacy.Count -gt 0) {
        throw "Legacy per-install language records were found under '$managerRoot' or '$legacyOldRoot'. For safety, this manager will not mix them with its new shared-file ledger. Use Remove Language Pack with the legacy compatibility path if there is only one record, or clean multiple old records with the previous script after backing up the game."
    }

    $null = New-Item -ItemType Directory -Path $managerRoot -Force
    $originalIniBackup = Join-Path $managerRoot 'configs.user.ini.original.bak'
    if (Test-Path -LiteralPath $originalIniBackup -PathType Leaf) {
        throw "An original config backup exists but state.json does not: $originalIniBackup. Refusing to guess whether it belongs to this game state."
    }
    $currentValue = Get-ConfigLanguageValue -IniPath $IniPath
    Copy-Item -LiteralPath $IniPath -Destination $originalIniBackup -ErrorAction Stop
    $state = [pscustomobject]@{
        Version = 2
        TargetRoot = $TargetRoot
        IniPath = $IniPath
        OriginalIniBackup = $originalIniBackup
        InitialLanguageValue = $currentValue
        ActiveValue = $currentValue
        Packs = @()
        Paths = @()
    }
    Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    return $state
}

function Get-ManagerPathState {
    param($State, [string]$Relative)
    foreach ($pathState in @($State.Paths)) {
        if ([string]$pathState.Relative -ieq $Relative) { return $pathState }
    }
    return $null
}

function Get-ManagerPack {
    param($State, [string]$LanguageName)
    foreach ($packState in @($State.Packs)) {
        if ([string]$packState.Name -ieq $LanguageName) { return $packState }
    }
    return $null
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $temp = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $Destination -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Test-SafeGameDestination {
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    $cursor = $parent
    while ($cursor -and $cursor.StartsWith($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $attrs = [IO.File]::GetAttributes($cursor)
            if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "A junction/symlink exists in the destination path: $cursor"
            }
        }
        if ($cursor.Equals($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Destination is a directory or reparse point; refusing to alter it: $Destination"
        }
    }
}

function Download-LanguageArchive {
    param(
        [Parameter(Mandatory)]$Pack,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$LanguageName
    )
    $baseUrl = 'https://github.com/LarkTheStar/fix-installer/releases/download/Language-1.0.0'
    $localAssets = [System.Collections.Generic.List[string]]::new()
    $assetIndex = 0
    $assetCount = @($Pack.Assets).Count
    foreach ($assetName in @($Pack.Assets)) {
        $assetIndex++
        $destination = Join-Path $WorkRoot $assetName
        $url = "$baseUrl/$assetName"
        Write-Info "Downloading asset $assetIndex/${assetCount}: $assetName"
        Download-FileWithProgress -Url $url -Destination $destination -Label "Downloading $LanguageName - $assetName"
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-Item -LiteralPath $destination).Length -le 0) {
            throw "Downloaded asset is missing or empty: $assetName"
        }
        $localAssets.Add($destination)
    }
    if ($localAssets.Count -eq 1) { return $localAssets[0] }

    # The .part files are contiguous raw byte chunks. Concatenate them in explicit
    # .part001, .part002 order; do not unzip or recompress each part separately.
    $assembled = Join-Path $WorkRoot $Pack.File
    $out = [IO.File]::Open($assembled, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        foreach ($partPath in $localAssets) {
            $partStream = [IO.File]::OpenRead($partPath)
            try { $partStream.CopyTo($out) } finally { $partStream.Dispose() }
        }
        $out.Flush()
    } finally { $out.Dispose() }
    Write-Ok ("Reassembled {0} from {1} ordered parts ({2:N2} GiB)." -f $Pack.File, $localAssets.Count, ((Get-Item -LiteralPath $assembled).Length / 1GB))

    # Check the central directory before deleting temporary parts. The complete archive
    # is subsequently streamed entry-by-entry during staging, which checks every file can
    # be decompressed and hashed. Keeping both parts after assembly would waste several GB.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $testArchive = $null
    try {
        $testArchive = [IO.Compression.ZipFile]::OpenRead($assembled)
        if ($testArchive.Entries.Count -eq 0) { throw 'The reassembled ZIP contains no entries.' }
    } catch {
        throw "Reassembled ZIP failed its initial open test: $($_.Exception.Message)"
    } finally {
        if ($testArchive) { $testArchive.Dispose() }
    }
    foreach ($partPath in $localAssets) {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction Stop
    }
    Write-Info 'Temporary split parts were removed after successful reassembly; the reconstructed ZIP is retained until staging finishes.'
    return $assembled
}

function Install-LanguagePack {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $iniPath = Join-Path $targetRoot 'sp26\steam_settings\configs.user.ini'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) {
        throw "Could not find configs.user.ini at '$iniPath'. No language files were installed."
    }

    Write-Host ''
    Write-Host 'Available language packs:' -ForegroundColor White
    $names = @($LanguagePacks.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host "  [$($i + 1)] $($names[$i])" }
    Write-Host '  [0] Cancel'
    $choice = Read-Host 'Choose a language to install'
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { Write-Info 'Language installation cancelled.'; return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $names.Count) { throw 'Invalid language selection.' }
    $languageName = $names[$number - 1]
    $pack = $LanguagePacks[$languageName]

    $managerRoot = Get-LanguageManagerRoot -TargetRoot $targetRoot
    $state = Get-LanguageManagerState -TargetRoot $targetRoot -IniPath $iniPath -Create
    if (@($state.Packs).Count -eq 0) {
        # A new install cycle begins only when no managed packs remain. Refresh the
        # baseline so any user config changes made between cycles are preserved.
        $baselineValue = Get-ConfigLanguageValue -IniPath $iniPath
        Copy-Item -LiteralPath $iniPath -Destination ([string]$state.OriginalIniBackup) -Force -ErrorAction Stop
        $state.InitialLanguageValue = $baselineValue
        $state.ActiveValue = $baselineValue
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    }
    if ($null -ne (Get-ManagerPack -State $state -LanguageName $languageName)) {
        Write-Warn "$languageName is already tracked as installed. Use Active Language Preset to switch to it."
        return
    }
    Write-Host "`nSelected: $languageName (language=$($pack.Value))" -ForegroundColor Yellow
    Write-Info 'Other installed language packs will be retained. Identical shared files will be reference-counted in the manager state.'
    $confirm = Read-Host 'Download and install this language pack? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Language installation cancelled.'; return }

    $workRoot = Join-Path $env:TEMP ('codhq-language-' + [guid]::NewGuid().ToString('N'))
    $stageRoot = Join-Path $workRoot 'staged'
    $archive = $null
    $committed = $false
    $undo = [System.Collections.Generic.List[object]]::new()
    $createdDirs = [System.Collections.Generic.List[string]]::new()
    $beforeIni = Join-Path $workRoot 'configs.user.ini.before-install.bak'
    try {
        $null = New-Item -ItemType Directory -Path $stageRoot -Force
        Copy-Item -LiteralPath $iniPath -Destination $beforeIni -ErrorAction Stop
        $zipPath = Download-LanguageArchive -Pack $pack -WorkRoot $workRoot -LanguageName $languageName
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -le 0) { throw 'The ZIP is missing or empty.' }

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 20000) { throw 'The ZIP is empty or contains too many entries.' }
        $fileEntries = @($archive.Entries | Where-Object { -not ($_.FullName.EndsWith('/') -or $_.FullName.EndsWith('\')) })
        if ($fileEntries.Count -eq 0) { throw 'The ZIP contains no files.' }

        # Strip a wrapper folder only if every file is inside the same folder and no file
        # is directly at the ZIP root. Current audit showed several root layouts, so this
        # test is deliberately conservative.
        $firstSegments = @($fileEntries | ForEach-Object { ($_.FullName -replace '\\','/').Split('/')[0] } | Select-Object -Unique)
        $stripRoot = $false
        if ($firstSegments.Count -eq 1 -and @($fileEntries | Where-Object { (($_.FullName -replace '\\','/').Split('/').Count) -lt 2 }).Count -eq 0) { $stripRoot = $true }

        $totalSize = [int64]0
        $planned = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        $entryIndex = 0
        foreach ($entry in $fileEntries) {
            $entryIndex++
            $entryName = $entry.FullName -replace '/', '\'
            if ([IO.Path]::IsPathRooted($entryName) -or $entryName.StartsWith('\') -or $entryName -match '^[A-Za-z]:' -or $entryName.Split('\') -contains '..') {
                throw "Unsafe path in ZIP: $($entry.FullName)"
            }
            $relative = $entryName
            if ($stripRoot) {
                $segments = $relative.Split('\')
                if ($segments.Count -lt 2) { throw "Unexpected archive structure: $($entry.FullName)" }
                $relative = ($segments | Select-Object -Skip 1) -join '\'
            }
            $badSegments = @($relative.Split('\') | Where-Object { $_ -in @('', '.', '..') -or $_.Contains(':') -or $_.EndsWith(' ') -or $_.EndsWith('.') })
            if ([string]::IsNullOrWhiteSpace($relative) -or $badSegments.Count -gt 0) { throw "Unsafe path in ZIP: $($entry.FullName)" }
            if ($relative -match '^(?i:og files|language files)(\\|$)') { throw "ZIP tries to write into the reserved manager/backup area: $($entry.FullName)" }
            if ($relative -match '(^|\\)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { throw "ZIP contains a reserved Windows filename: $($entry.FullName)" }
            $key = $relative.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "ZIP has duplicate/case-colliding paths: $relative" }
            $seen[$key] = $true
            $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) { throw "Symbolic links are not allowed: $($entry.FullName)" }
            $totalSize += [int64]$entry.Length
            if ($totalSize -gt 5GB) { throw 'The ZIP expands to more than 5 GB; refusing to continue.' }
            $stagePath = [IO.Path]::GetFullPath((Join-Path $stageRoot $relative))
            $stagePrefix = [IO.Path]::GetFullPath($stageRoot).TrimEnd('\') + '\'
            if (-not $stagePath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP path escapes staging: $($entry.FullName)" }
            $targetPath = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
            $targetPrefix = $targetRoot.TrimEnd('\') + '\'
            if (-not $targetPath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP path escapes game folder: $($entry.FullName)" }
            $planned.Add([pscustomobject]@{ Relative=$relative; StagePath=$stagePath; TargetPath=$targetPath; Entry=$entry })
        }

        Write-Info "Validating and staging $($planned.Count) files..."
        $stageIndex = 0
        foreach ($item in $planned) {
            $stageIndex++
            $parent = Split-Path -Parent $item.StagePath
            $null = New-Item -ItemType Directory -Path $parent -Force
            $entryStream = $item.Entry.Open()
            try {
                $output = [IO.File]::Open($item.StagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $entryStream.CopyTo($output) } finally { $output.Dispose() }
            } finally { $entryStream.Dispose() }
            $actualLength = (Get-Item -LiteralPath $item.StagePath).Length
            if ([int64]$actualLength -ne [int64]$item.Entry.Length) { throw "Entry length mismatch while extracting: $($item.Relative)" }
            $item | Add-Member -NotePropertyName SHA256 -NotePropertyValue ((Get-FileHash -LiteralPath $item.StagePath -Algorithm SHA256).Hash.ToLowerInvariant())
            Write-Progress -Activity "Staging $languageName" -Status "$stageIndex / $($planned.Count) files" -PercentComplete ([int](100 * $stageIndex / [Math]::Max(1,$planned.Count)))
        }
        Write-Progress -Activity "Staging $languageName" -Completed
        $archive.Dispose(); $archive = $null
        $archiveHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

        # Prepare updated ownership state. Any overlap must have the same runtime SHA-256
        # as the already-managed file; otherwise refuse to overwrite it.
        $newPaths = [System.Collections.Generic.List[object]]::new()
        foreach ($existingPathState in @($state.Paths)) { $newPaths.Add($existingPathState) }
        $pathIndexByKey = @{}
        for ($i = 0; $i -lt $newPaths.Count; $i++) {
            $existingKey = ([string]$newPaths[$i].Relative).ToLowerInvariant()
            $pathIndexByKey[$existingKey] = $i
        }
        $toInstall = [System.Collections.Generic.List[object]]::new()
        $originalFilesRoot = Join-Path $managerRoot 'original-files'

        foreach ($item in $planned) {
            Test-SafeGameDestination -TargetRoot $targetRoot -Destination $item.TargetPath
            $key = $item.Relative.ToLowerInvariant()
            if ($pathIndexByKey.ContainsKey($key)) {
                $idx = [int]$pathIndexByKey[$key]
                $prior = $newPaths[$idx]
                if ([string]$prior.Hash -ne [string]$item.SHA256) {
                    throw "This pack's file differs from a file already managed at '$($item.Relative)'. Nothing was committed, to avoid corrupting a shared path."
                }
                if (-not (Test-Path -LiteralPath $item.TargetPath -PathType Leaf)) { throw "Managed shared file is missing: $($item.TargetPath)" }
                $currentHash = (Get-FileHash -LiteralPath $item.TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($currentHash -ne [string]$prior.Hash) { throw "Managed shared file was changed outside the manager: $($item.TargetPath). Restore it before installing another pack." }
                $owners = @($prior.Owners)
                if ($owners -notcontains $languageName) { $owners += $languageName }
                $newPaths[$idx] = [pscustomobject]@{
                    Relative=[string]$prior.Relative; Hash=[string]$prior.Hash; Owners=@($owners)
                    OriginalExisted=[bool]$prior.OriginalExisted; OriginalBackupRelative=[string]$prior.OriginalBackupRelative
                }
            } else {
                $destExists = Test-Path -LiteralPath $item.TargetPath -PathType Leaf
                $backupRelative = ''
                if ($destExists) { $backupRelative = $item.Relative }
                $newPaths.Add([pscustomobject]@{
                    Relative=$item.Relative; Hash=$item.SHA256; Owners=@($languageName)
                    OriginalExisted=[bool]$destExists; OriginalBackupRelative=$backupRelative
                })
                $pathIndexByKey[$key] = $newPaths.Count - 1
                $toInstall.Add($item)
            }
        }

        # Apply new files. Original copies are taken once, before the first language owns
        # a path; later languages sharing that path never overwrite the original backup.
        foreach ($item in $toInstall) {
            $dest = $item.TargetPath
            $destExists = Test-Path -LiteralPath $dest -PathType Leaf
            $backupPath = Join-Path $originalFilesRoot $item.Relative
            if ($destExists) {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force
                Copy-Item -LiteralPath $dest -Destination $backupPath -Force -ErrorAction Stop
            }
            $undo.Add([pscustomobject]@{ Destination=$dest; HadOriginal=$destExists; BackupPath=$backupPath })
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                $walk = $parent; $missingDirs = [System.Collections.Generic.List[string]]::new()
                while ($walk -and -not (Test-Path -LiteralPath $walk)) { $missingDirs.Add($walk); $walk = Split-Path -Parent $walk }
                $null = New-Item -ItemType Directory -Path $parent -Force
                foreach ($dir in $missingDirs) { $createdDirs.Add($dir) }
            }
            Copy-FileAtomically -Source $item.StagePath -Destination $dest
        }

        # Activate the newly installed pack only after file changes have succeeded.
        Set-ConfigLanguageValue -IniPath $iniPath -Language $pack.Value
        $newPacks = [System.Collections.Generic.List[object]]::new()
        foreach ($installedPack in @($state.Packs)) { $newPacks.Add($installedPack) }
        $newPacks.Add([pscustomobject]@{
            Name=$languageName; Value=$pack.Value; InstalledAt=(Get-Date).ToString('o')
            ArchiveSHA256=$archiveHash; Files=@($planned | ForEach-Object { [string]$_.Relative })
        })
        $state.Paths = @($newPaths.ToArray())
        $state.Packs = @($newPacks.ToArray())
        $state.ActiveValue = $pack.Value
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
        $committed = $true

        Write-Ok "$languageName language pack installed."
        Write-Info "Active language set to '$($pack.Value)'."
        Write-Info "Installed files owned by this pack: $($planned.Count). Shared paths are tracked and will be retained while another installed pack needs them."
        Write-Info "Manager state: $(Get-LanguageStatePath -ManagerRoot $managerRoot)"
    } catch {
        Write-Warn 'Language-pack installation failed. Attempting to roll back newly written files and configuration...'
        for ($i = $undo.Count - 1; $i -ge 0; $i--) {
            $record = $undo[$i]
            try {
                if ($record.HadOriginal -and (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) {
                    Copy-FileAtomically -Source $record.BackupPath -Destination $record.Destination
                } elseif (-not $record.HadOriginal -and (Test-Path -LiteralPath $record.Destination -PathType Leaf)) {
                    Remove-Item -LiteralPath $record.Destination -Force -ErrorAction Stop
                }
            } catch { Write-Warn "Could not roll back '$($record.Destination)': $($_.Exception.Message)" }
        }
        if (Test-Path -LiteralPath $beforeIni -PathType Leaf) {
            try { Copy-FileAtomically -Source $beforeIni -Destination $iniPath } catch { Write-Warn "Could not restore pre-install config: $($_.Exception.Message)" }
        }
        foreach ($dir in @($createdDirs | Sort-Object Length -Descending)) {
            try { if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir -Force } } catch {}
        }
        throw
    } finally {
        if ($archive) { try { $archive.Dispose() } catch {} }
        if (Test-Path -LiteralPath $workRoot) { try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
        if (-not $committed) {
            # The manager's baseline config backup and any source backups are recovery
            # material. They are deliberately not deleted automatically after a failure.
        }
    }
}

function Set-ActiveLanguagePreset {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $iniPath = Join-Path $targetRoot 'sp26\steam_settings\configs.user.ini'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Could not find configs.user.ini at '$iniPath'." }
    $managerRoot = Get-LanguageManagerRoot -TargetRoot $targetRoot
    $state = Get-LanguageManagerState -TargetRoot $targetRoot -IniPath $iniPath
    $currentValue = Get-ConfigLanguageValue -IniPath $iniPath

    $options = [System.Collections.Generic.List[object]]::new()
    $options.Add([pscustomobject]@{ Name='English (included with the game)'; Value='english' })
    if ($null -ne $state) {
        foreach ($installedPack in @($state.Packs)) {
            $options.Add([pscustomobject]@{ Name=[string]$installedPack.Name; Value=[string]$installedPack.Value })
        }
    } else {
        # If the previous manager left records without state.json, do not make the list
        # appear empty and silently imply that those files are unmanaged/safe to replace.
        $legacyRoots = @()
        if (Test-Path -LiteralPath $managerRoot -PathType Container) { $legacyRoots += $managerRoot }
        $legacyOldRoot = Join-Path $targetRoot 'og files\language-pack-manager'
        if (Test-Path -LiteralPath $legacyOldRoot -PathType Container) { $legacyRoots += $legacyOldRoot }
        $legacy = @($legacyRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue })
        if ($legacy.Count -gt 0) { throw "Legacy language-pack records exist under '$managerRoot' or '$legacyOldRoot'. Remove/restore them before switching presets with this manager." }
    }

    Write-Host ''
    Write-Host 'Active Language Preset' -ForegroundColor White
    Write-Host "Current configs.user.ini value: $currentValue"
    for ($i=0; $i -lt $options.Count; $i++) { Write-Host "  [$($i+1)] $($options[$i].Name) (language=$($options[$i].Value))" }
    Write-Host '  [0] Cancel'
    $choice = Read-Host 'Choose the active language preset'
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { Write-Info 'Preset change cancelled.'; return }
    $number=0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $options.Count) { throw 'Invalid preset selection.' }
    $selected = $options[$number-1]
    if ($currentValue -eq [string]$selected.Value) {
        if (($null -ne $state) -and ([string]$state.ActiveValue -ne [string]$selected.Value)) {
            $state.ActiveValue = [string]$selected.Value
            Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
        }
        Write-Info "Preset is already active: $($selected.Name)."
        return
    }

    Set-ConfigLanguageValue -IniPath $iniPath -Language ([string]$selected.Value)
    if ($null -ne $state) {
        $state.ActiveValue = [string]$selected.Value
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    }
    Write-Ok "Active language preset changed to $($selected.Name) ($($selected.Value))."
    Write-Info 'Only the existing language= value was changed; language files were not installed, removed, or overwritten.'
}

function Remove-LegacyLanguagePack {
    param([Parameter(Mandatory)][string]$TargetRoot)

    $targetRoot = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $managerRoot = Join-Path $targetRoot 'language files\language-pack-manager'
    $legacyManagerRoot = Join-Path $targetRoot 'og files\language-pack-manager'
    $manifestRoots = @()
    if (Test-Path -LiteralPath $managerRoot -PathType Container) { $manifestRoots += $managerRoot }
    if (Test-Path -LiteralPath $legacyManagerRoot -PathType Container) { $manifestRoots += $legacyManagerRoot }
    $manifests = @($manifestRoots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue
    })

    if ($manifests.Count -eq 0) {
        Write-Warn 'No tracked legacy language-pack manifests were found.'
        return
    }

    Write-Host ''
    Write-Host 'Tracked legacy language-pack installations:' -ForegroundColor White
    for ($i = 0; $i -lt $manifests.Count; $i++) {
        try {
            $candidate = Get-Content -LiteralPath $manifests[$i].FullName -Raw | ConvertFrom-Json
            Write-Host "  [$($i + 1)] $($candidate.Language) - installed $($candidate.InstallId)"
        }
        catch {
            Write-Host "  [$($i + 1)] Unreadable manifest: $($manifests[$i].FullName)"
        }
    }
    Write-Host '  [0] Cancel'
    $choice = Read-Host 'Choose an installation to remove/restore'
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }

    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $manifests.Count) {
        throw 'Invalid selection.'
    }

    $manifestPath = $manifests[$number - 1].FullName
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not ([string]$manifest.TargetRoot).Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Manifest target does not match selected game directory.'
    }

    Write-Warn "This will restore/remove files recorded for $($manifest.Language). Recovery data is deleted only after restoration succeeds."
    $confirm = Read-Host 'Continue? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') { return }

    $packRoot = Split-Path -Parent $manifestPath
    $restoreFailed = $false
    $iniRestored = $false

    for ($i = @($manifest.Files).Count - 1; $i -ge 0; $i--) {
        $record = $manifest.Files[$i]
        try {
            $relative = [string]$record.Relative
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Unsafe relative path in legacy manifest: $relative"
            }
            $dest = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
            $prefix = $targetRoot.TrimEnd('\') + '\'
            if (-not $dest.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Destination escapes the game directory: $relative"
            }

            if ([bool]$record.HadOriginal) {
                $backupRelative = [string]$record.BackupRelative
                if ([string]::IsNullOrWhiteSpace($backupRelative) -or [IO.Path]::IsPathRooted($backupRelative) -or $backupRelative -match '(^|[\\/])\.\.([\\/]|$)') {
                    throw "Unsafe backup path in legacy manifest for $relative"
                }
                $backup = Join-Path $packRoot ('previous-files\' + $backupRelative)
                if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    throw "Backup missing for $dest"
                }
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
                Copy-Item -LiteralPath $backup -Destination $dest -Force -ErrorAction Stop
            }
            elseif (Test-Path -LiteralPath $dest -PathType Leaf) {
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
            }
        }
        catch {
            $restoreFailed = $true
            Write-Warn "Could not restore/remove a recorded file: $($_.Exception.Message)"
        }
    }

    try {
        $iniPath = [string]$manifest.IniPath
        $iniBackup = [string]$manifest.IniBackup
        if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf) -or -not (Test-Path -LiteralPath $iniBackup -PathType Leaf)) {
            throw 'configs.user.ini or its original backup is missing.'
        }
        $currentContent = [IO.File]::ReadAllText($iniPath)
        $currentMatch = [regex]::Match($currentContent, '(?im)^\s*language\s*=\s*(.*?)\s*$')
        if ($currentMatch.Success -and $currentMatch.Groups[1].Value -eq [string]$manifest.LanguageValue) {
            Copy-Item -LiteralPath $iniBackup -Destination $iniPath -Force -ErrorAction Stop
            $iniRestored = $true
            Write-Ok 'Restored the previous configs.user.ini.'
        }
        else {
            throw 'The active language setting has changed since installation; config was left unchanged.'
        }
    }
    catch {
        $restoreFailed = $true
        Write-Warn "Could not safely restore configs.user.ini: $($_.Exception.Message)"
    }

    foreach ($dir in @($manifest.CreatedDirectories | Sort-Object Length -Descending)) {
        try {
            if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) {
                Remove-Item -LiteralPath $dir -Force
            }
        }
        catch { }
    }

    if (-not $restoreFailed -and $iniRestored) {
        try {
            Remove-Item -LiteralPath $packRoot -Recurse -Force -ErrorAction Stop
            Write-Ok 'Restoration succeeded; removed this legacy pack recovery folder.'
        }
        catch {
            Write-Warn "Restoration succeeded, but the recovery folder could not be deleted: $packRoot ($($_.Exception.Message))"
        }
    }
    else {
        Write-Warn "Recovery data was retained because restoration was incomplete: $packRoot"
    }

    Write-Info 'Legacy language-pack removal/restore finished. Review any warnings above.'
}

function Remove-LanguagePack {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $iniPath = Join-Path $targetRoot 'sp26\steam_settings\configs.user.ini'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Could not find configs.user.ini at '$iniPath'." }
    $managerRoot = Get-LanguageManagerRoot -TargetRoot $targetRoot
    $state = Get-LanguageManagerState -TargetRoot $targetRoot -IniPath $iniPath
    if ($null -eq $state) {
        $legacyRoots = @()
        if (Test-Path -LiteralPath $managerRoot -PathType Container) { $legacyRoots += $managerRoot }
        $legacyRootOld = Join-Path $targetRoot 'og files\language-pack-manager'
        if (Test-Path -LiteralPath $legacyRootOld -PathType Container) { $legacyRoots += $legacyRootOld }
        $legacyManifests = @($legacyRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue })
        if ($legacyManifests.Count -eq 1) {
            Write-Warn 'Found one legacy language-pack record from the previous manager. Using its compatibility removal routine.'
            Remove-LegacyLanguagePack -TargetRoot $targetRoot
            return
        }
        if ($legacyManifests.Count -gt 1) {
            throw "Multiple legacy language-pack records were found under '$managerRoot' / '$legacyRootOld'. The new manager will not guess the ownership of shared files. Keep a backup and use the previous script to clean these old records before proceeding."
        }
        Write-Warn 'No language packs tracked by the multi-language manager were found.'
        return
    }
    if (@($state.Packs).Count -eq 0) {
        Write-Warn 'No language packs are currently installed according to the manager state.'
        return
    }

    $installed = @($state.Packs)
    Write-Host ''
    Write-Host 'Installed language packs:' -ForegroundColor White
    for ($i=0; $i -lt $installed.Count; $i++) {
        Write-Host "  [$($i+1)] $($installed[$i].Name) (language=$($installed[$i].Value), files tracked=$(@($installed[$i].Files).Count))"
    }
    Write-Host '  [0] Cancel'
    $choice = Read-Host 'Choose a language pack to remove'
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { Write-Info 'Removal cancelled.'; return }
    $number=0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $installed.Count) { throw 'Invalid selection.' }
    $packState = $installed[$number-1]
    $languageName = [string]$packState.Name
    $files = @($packState.Files)
    if ($files.Count -eq 0) { throw "The state record for '$languageName' has no tracked files. Refusing to guess how to remove it." }

    Write-Warn "This removes $languageName. Files shared with other installed packs will remain. Original files are restored only after the final owning language is removed."
    Write-Warn 'If an installed file has been changed outside this manager, removal will be refused before making changes.'
    $confirm = Read-Host 'Continue? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Removal cancelled.'; return }

    # Full preflight before modifying anything: all tracked files must still match the
    # manager's expected content, and every necessary original backup must be present.
    foreach ($relative in $files) {
        $pathState = Get-ManagerPathState -State $state -Relative ([string]$relative)
        if ($null -eq $pathState) { throw "Missing ownership state for '$relative'. No files were changed." }
        if (@($pathState.Owners) -notcontains $languageName) { throw "Ownership record does not list '$languageName' for '$relative'. No files were changed." }
        $dest = [IO.Path]::GetFullPath((Join-Path $targetRoot ([string]$relative)))
        $prefix = $targetRoot.TrimEnd('\') + '\'
        if (-not $dest.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe tracked path in state file: $relative" }
        Test-SafeGameDestination -TargetRoot $targetRoot -Destination $dest
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw "Tracked language file is missing: $dest. No files were changed." }
        $item = Get-Item -LiteralPath $dest -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Tracked file is a reparse point: $dest. No files were changed." }
        $actualHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne [string]$pathState.Hash) { throw "Tracked file was changed outside the manager: $dest. No files were changed; restore the expected file before retrying." }
        if (@($pathState.Owners).Count -eq 1 -and [bool]$pathState.OriginalExisted) {
            $original = Join-Path (Join-Path $managerRoot 'original-files') ([string]$pathState.OriginalBackupRelative)
            if (-not (Test-Path -LiteralPath $original -PathType Leaf)) { throw "Original backup is missing: $original. No files were changed." }
        }
    }

    $currentValue = Get-ConfigLanguageValue -IniPath $iniPath
    $remainingPackCount = $installed.Count - 1
    $isActivePack = ($currentValue -eq [string]$packState.Value)
    if ($isActivePack) {
        # Switch away first so a partial removal cannot leave a removed/partially removed
        # language selected. English is always available in the base game.
        Set-ConfigLanguageValue -IniPath $iniPath -Language 'english'
        $state.ActiveValue = 'english'
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
        Write-Info 'The removed language was active; switched the preset to English before removing its files.'
    }

    foreach ($relative in $files) {
        $relative = [string]$relative
        $pathState = Get-ManagerPathState -State $state -Relative $relative
        $dest = Join-Path $targetRoot $relative
        $owners = @($pathState.Owners | Where-Object { [string]$_ -ine $languageName })
        if ($owners.Count -gt 0) {
            $replacement = [pscustomobject]@{
                Relative=[string]$pathState.Relative; Hash=[string]$pathState.Hash; Owners=@($owners)
                OriginalExisted=[bool]$pathState.OriginalExisted; OriginalBackupRelative=[string]$pathState.OriginalBackupRelative
            }
            $newPaths = @()
            foreach ($p in @($state.Paths)) { if ([string]$p.Relative -ieq $relative) { $newPaths += $replacement } else { $newPaths += $p } }
            $state.Paths = @($newPaths)
        } else {
            if ([bool]$pathState.OriginalExisted) {
                $original = Join-Path (Join-Path $managerRoot 'original-files') ([string]$pathState.OriginalBackupRelative)
                Copy-FileAtomically -Source $original -Destination $dest
            } else {
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
            }
            $state.Paths = @($state.Paths | Where-Object { [string]$_.Relative -ine $relative })
        }

        # Persist progress after every path. If Windows stops the removal mid-way, the
        # remaining list can be selected again without removing files a second time.
        $currentPack = Get-ManagerPack -State $state -LanguageName $languageName
        $currentPack.Files = @(@($currentPack.Files) | Where-Object { [string]$_ -ine $relative })
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    }

    $state.Packs = @($state.Packs | Where-Object { [string]$_.Name -ine $languageName })
    Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    Write-Ok "$languageName was removed. Shared files required by other installed packs were retained."

    if (@($state.Packs).Count -eq 0) {
        # Restore only the original language= value, not the entire old INI. This preserves
        # any unrelated config edits the user made since the first pack was installed.
        $now = Get-ConfigLanguageValue -IniPath $iniPath
        if ($now -eq [string]$state.ActiveValue) {
            $baselineValue = Get-ConfigLanguageValue -IniPath ([string]$state.OriginalIniBackup)
            Set-ConfigLanguageValue -IniPath $iniPath -Language $baselineValue
            $state.ActiveValue = $baselineValue
            Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
            Write-Info "No language packs remain; restored the original language setting '$baselineValue'."
        } else {
            Write-Warn 'No language packs remain, but the config language value changed outside the manager. It was left untouched.'
        }
    }
    Write-Info 'Original-file backups and the manager state are retained for recovery; they are not deleted automatically.'
}


function Remove-Fix {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $backupBase = Join-Path $targetRoot 'og files'
    if (-not (Test-Path -LiteralPath $backupBase -PathType Container)) {
        throw "The backup directory was not found: $backupBase"
    }

    # Per user's rule, only consider timestamped backup folders smaller than 20 MB.
    # Language-pack backups now live outside this folder, so only fix-install backups are considered.
    $candidates = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $backupBase -Directory -Force -ErrorAction Stop)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $bytes = Get-FolderSizeBytes -Path $dir.FullName
        if ($bytes -gt 0 -and $bytes -lt 20MB) {
            $candidates += [pscustomobject]@{ Directory=$dir; Bytes=$bytes }
        }
    }
    if ($candidates.Count -eq 0) {
        throw 'No non-empty "og files" backup folder smaller than 20 MB was found. Nothing was changed.'
    }

    # Repeated fix installs back up the previously installed fix. The oldest qualifying
    # small backup is most likely to contain the true pre-fix originals.
    $candidate = $candidates | Sort-Object { $_.Directory.CreationTimeUtc } | Select-Object -First 1
    $backupRoot = $candidate.Directory.FullName
    $sizeMB = [Math]::Round($candidate.Bytes / 1MB, 2)
    Write-Host ''
    Write-Warn "Selected original-file backup: $backupRoot ($sizeMB MB)"
    if ($candidates.Count -gt 1) {
        Write-Warn "Found $($candidates.Count) qualifying backup folders under 20 MB; the oldest one will be used to favor the original pre-fix files."
    }
    Write-Warn 'The script will restore files found in this backup and remove matching fix-archive files that have no backed-up original.'
    $confirm = Read-Host 'Remove the fix and restore originals using this backup? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Fix removal cancelled.'; return }

    $workRoot = Join-Path $env:TEMP ('codhq-fix-removal-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $workRoot $ZipFileName
    $archive = $null
    try {
        $null = New-Item -ItemType Directory -Path $workRoot -Force
        Download-FileWithProgress -Url $ZipUrl -Destination $zipPath -Label "Downloading fix manifest for removal"
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt 20000) { throw 'The fix ZIP is empty or contains too many entries; refusing removal.' }

        $relativeFiles = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $relative = Get-ValidatedRelativePath $entry.FullName
            $relativeFiles.Add($relative)
        }
        if ($relativeFiles.Count -eq 0) { throw 'The fix ZIP contains no files; refusing removal.' }

        # Preflight all destinations before making changes.
        foreach ($relative in $relativeFiles) {
            $dest = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
            $prefix = $targetRoot.TrimEnd('\') + '\'
            if (-not $dest.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fix archive path: $relative" }
            if (Test-Path -LiteralPath $dest) {
                $item = Get-Item -LiteralPath $dest -Force
                if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw "Destination is not a regular file; refusing to alter it: $dest"
                }
            }
        }

        $restored = 0
        $removed = 0
        foreach ($relative in $relativeFiles) {
            $dest = Join-Path $targetRoot $relative
            $backup = Join-Path $backupRoot $relative
            if (Test-Path -LiteralPath $backup -PathType Leaf) {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
                Copy-Item -LiteralPath $backup -Destination $dest -Force -ErrorAction Stop
                $restored++
            } elseif (Test-Path -LiteralPath $dest -PathType Leaf) {
                # No original copy exists for this archive path, so it was likely introduced by the fix.
                Remove-Item -LiteralPath $dest -Force -ErrorAction Stop
                $removed++
            }
        }
        Write-Ok 'Fix removal completed.'
        Write-Info "Restored original files: $restored"
        Write-Info "Removed fix-added files: $removed"
        Write-Info "Backup retained (not deleted): $backupRoot"
    } finally {
        if ($archive) { try { $archive.Dispose() } catch {} }
        if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Launch-BatchFile {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $launcherPath = Join-Path $targetRoot '!start_sp26.bat'

    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        Write-Warn "!start_sp26.bat was not found in the selected game folder:"
        Write-Host "  $launcherPath"
        return
    }

    Write-Host "Batch file: $launcherPath"
    $confirm = Read-Host 'Launch !start_sp26.bat now? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Info 'Launch cancelled.'
        return
    }

    # Run from the game root so relative paths in the batch file resolve correctly.
    Start-Process -FilePath $env:ComSpec `
        -ArgumentList @('/c', ('"' + $launcherPath + '"')) `
        -WorkingDirectory $targetRoot
    Write-Ok 'Launch command started.'
}

function Show-MainMenu {
    while ($true) {
        Write-Host ''
        Write-Host '========================================' -ForegroundColor DarkCyan
        Write-Host '      Call of Duty HQ Setup Utility' -ForegroundColor White
        Write-Host '          made for luatools <3' -ForegroundColor Magenta
        Write-Host '                 - by lark' -ForegroundColor DarkGray
        Write-Host '========================================' -ForegroundColor DarkCyan
        Write-Host '  [1] Install Fix'
        Write-Host '  [2] Install Language Pack'
        Write-Host '  [3] Remove Language Pack'
        Write-Host '  [4] Active Language Preset'
        Write-Host '  [5] Remove Fix / Restore Originals'
        Write-Host '  [6] Launch !start_sp26.bat'
        Write-Host '  [7] Exit'
        $choice = Read-Host 'Select an option'
        try {
            switch ($choice) {
                '1' { Install-Fix }
                '2' { Install-LanguagePack }
                '3' { Remove-LanguagePack }
                '4' { Set-ActiveLanguagePreset }
                '5' { Remove-Fix }
                '6' { Launch-BatchFile }
                '7' { return }
                default { Write-Warn 'Please choose 1, 2, 3, 4, 5, 6, or 7.' }
            }
        } catch {
            Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
        [void](Read-Host 'Press Enter to return to the main menu')
    }
}

Show-MainMenu
Read-Host 'Press Enter to exit'

}
