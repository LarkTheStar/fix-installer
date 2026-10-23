# Call of Duty HQ Fix Installer
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
    if ($name -match '^(?i:og files)(\\|$)') {
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
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing

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

Write-Host ''
Read-Host 'Press Enter to exit'
