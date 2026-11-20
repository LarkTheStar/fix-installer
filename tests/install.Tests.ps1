# Pester 5 tests for install.ps1. Run them with tests\Invoke-Tests.ps1.
#
# Everything here works on fake game and Steam folders under Pester's TestDrive;
# downloads, Steam, services, processes and prompts are mocked, so nothing on the
# machine running the tests is touched.

BeforeAll {
    . "$PSScriptRoot\Import-InstallScript.ps1"
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Builds a ZIP with exact entry names. Compress-Archive is not used because
    # Windows PowerShell 5.1 writes backslashes into entry names.
    function New-TestZip {
        param([string]$Path, [System.Collections.IDictionary]$Entries)
        $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $writer = [IO.StreamWriter]::new($archive.CreateEntry($name).Open())
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    }

    function Get-Text { param([string]$Path) ([IO.File]::ReadAllText($Path)).Trim() }

    # PowerShell on Linux has no Get-Service, and Pester can only mock commands that
    # exist; this stub stands in for it there.
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) { function Get-Service { param($Name) } }

    # Prompts are answered from this queue, in order.
    $global:CodhqTestAnswers = [System.Collections.Generic.Queue[string]]::new()
    function Set-Answers { param([string[]]$Answers) $global:CodhqTestAnswers.Clear(); foreach ($a in $Answers) { $global:CodhqTestAnswers.Enqueue($a) } }
}

AfterAll {
    Remove-Variable -Name CodhqTestAnswers -Scope Global -ErrorAction SilentlyContinue
}

Describe 'install.ps1 file' {
    It 'parses without errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($InstallScriptPath, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'has no byte-order mark' {
        # A BOM breaks the param block under "irm ... | iex" in Windows PowerShell 5.1.
        $InstallScriptBytes[0] | Should -Not -Be 0xEF
        $InstallScriptBytes[0] | Should -Not -Be 0xFF
        $InstallScriptBytes[0] | Should -Not -Be 0xFE
    }

    It 'is pure ASCII' {
        $lineNumber = 1
        $badLines = [System.Collections.Generic.List[int]]::new()
        foreach ($byte in $InstallScriptBytes) {
            if ($byte -eq 10) { $lineNumber++ }
            elseif ($byte -gt 127 -and -not $badLines.Contains($lineNumber)) { $badLines.Add($lineNumber) }
        }
        $badLines -join ', ' | Should -BeNullOrEmpty -Because 'non-ASCII characters must be written as \uXXXX escapes'
    }

    It 'passes its own completeness check, which the irm | iex bootstrap relies on' {
        Test-ScriptSourceLooksComplete ([IO.File]::ReadAllText($InstallScriptPath)) | Should -BeTrue
    }

    It 'rejects incomplete script text' {
        Test-ScriptSourceLooksComplete '' | Should -BeFalse
        Test-ScriptSourceLooksComplete 'function Invoke-SteamDowngrade {} # Call of Duty MW4 Setup Utility' | Should -BeFalse
    }
}

Describe 'ConvertTo-ScriptText' {
    It 'decodes bytes and drops a leading BOM' {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes('param()'))
        ConvertTo-ScriptText $bytes | Should -BeExactly 'param()'
    }

    It 'passes strings through' {
        ConvertTo-ScriptText 'param()' | Should -BeExactly 'param()'
    }
}

Describe 'ConvertFrom-UnicodeEscape and language labels' {
    It 'decodes \u escapes' {
        ConvertFrom-UnicodeEscape '\u0046\u0072\u0061\u006e\u00e7\u0061\u0069\u0073' | Should -BeExactly ('Fran' + [char]0x00E7 + 'ais')
    }

    It 'leaves text that is not a valid escape alone' {
        ConvertFrom-UnicodeEscape 'C:\users\zz' | Should -BeExactly 'C:\users\zz'
    }

    It 'gives every language pack a native name and at least one asset' {
        foreach ($name in $LanguagePacks.Keys) {
            $LanguagePacks[$name].Native | Should -Not -BeNullOrEmpty -Because $name
            @($LanguagePacks[$name].Assets).Count | Should -BeGreaterThan 0 -Because $name
        }
    }
}

Describe 'Get-ValidatedRelativePath' {
    It 'accepts <Entry>' -ForEach @(
        @{ Entry = 'a.txt'; Expected = 'a.txt' }
        @{ Entry = 'sp26/data/file.bin'; Expected = 'sp26\data\file.bin' }
    ) {
        Get-ValidatedRelativePath $Entry | Should -BeExactly $Expected
    }

    It 'rejects <Entry>' -ForEach @(
        @{ Entry = '../evil.txt' }
        @{ Entry = 'sub/../../evil.txt' }
        @{ Entry = '/abs.txt' }
        @{ Entry = 'C:/Windows/evil.txt' }
        @{ Entry = 'og files/x.txt' }
        @{ Entry = 'language files/x.txt' }
        @{ Entry = 'CON' }
        @{ Entry = 'sub/nul.txt' }
        @{ Entry = 'trailingdot./x.txt' }
        @{ Entry = 'trailingspace /x.txt' }
        @{ Entry = 'a:b.txt' }
    ) {
        { Get-ValidatedRelativePath $Entry } | Should -Throw
    }
}

Describe 'configs.user.ini language line' {
    BeforeEach {
        $ini = Join-Path $TestDrive 'configs.user.ini'
        [IO.File]::WriteAllText($ini, "[user::general]`r`naccount_name=me`r`nlanguage=english`r`nip_country=US`r`n")
    }

    It 'reads the current value' {
        Get-ConfigLanguageValue -IniPath $ini | Should -BeExactly 'english'
    }

    It 'replaces only the language line' {
        Set-ConfigLanguageValue -IniPath $ini -Language 'german'
        [IO.File]::ReadAllText($ini) | Should -BeExactly "[user::general]`r`naccount_name=me`r`nlanguage=german`r`nip_country=US`r`n"
    }

    It 'refuses to guess when there are <Case> language lines, and leaves the file alone' -ForEach @(
        @{ Case = 'no';  Content = "[user::general]`r`naccount_name=me`r`n" }
        @{ Case = 'two'; Content = "language=english`r`nlanguage=french`r`n" }
    ) {
        [IO.File]::WriteAllText($ini, $Content)
        { Set-ConfigLanguageValue -IniPath $ini -Language 'german' } | Should -Throw
        [IO.File]::ReadAllText($ini) | Should -BeExactly $Content
    }
}

Describe 'Settings' {
    BeforeEach {
        $SettingsDirectory = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N'))
        $SettingsFile = Join-Path $SettingsDirectory 'settings.json'
        $global:SessionGameFolder = $null
        Mock Write-Host { }
    }

    It 'returns defaults when nothing is saved' {
        $settings = Get-AppSettings
        $settings.Theme | Should -Be 'dark'
        $settings.Accent | Should -Be 'Steam'
        $settings.GameFolder | Should -Be ''
    }

    It 'returns defaults when the file is corrupt' {
        $null = New-Item -ItemType Directory -Path $SettingsDirectory -Force
        Set-Content -LiteralPath $SettingsFile -Value '{ not json'
        (Get-AppSettings).Theme | Should -Be 'dark'
    }

    It 'round-trips the theme, accent and motion choices' {
        Save-ThemeChoice 'light' | Should -BeTrue
        Save-AccentChoice 'Teal' | Should -BeTrue
        Save-MotionChoice $true | Should -BeTrue
        Get-SavedTheme | Should -Be 'light'
        Get-SavedAccent | Should -Be 'Teal'
        Get-SavedMotionPreference | Should -BeTrue
    }

    It 'ignores unknown theme and accent names' {
        Save-ThemeChoice 'neon' | Should -BeFalse
        Save-AccentChoice 'Rainbow' | Should -BeFalse
        Get-SavedTheme | Should -Be 'dark'
        Get-SavedAccent | Should -Be 'Steam'
    }

    It 'remembers the game folder for this session and later runs' {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Call of Duty HQ') -Force).FullName
        Save-GameFolder -Folder $game | Should -BeTrue
        $global:SessionGameFolder | Should -Be $game.TrimEnd('\', '/')
        Get-SavedGameFolder | Should -Be $game.TrimEnd('\', '/')
    }

    It 'forgets a saved game folder that no longer exists' {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'gone') -Force).FullName
        Save-GameFolder -Folder $game | Should -BeTrue
        Remove-Item -LiteralPath $game -Recurse -Force
        Get-SavedGameFolder | Should -BeNullOrEmpty
    }
}

Describe 'Activity log helpers' {
    It 'maps colours and prefixes to severities' {
        Get-LogSeverity -Color '#FF4D4D' -Text 'boom' | Should -Be 'error'
        Get-LogSeverity -Color '#FFD700' -Text 'careful' | Should -Be 'warn'
        Get-LogSeverity -Color '#4EC9B0' -Text 'done' | Should -Be 'ok'
        Get-LogSeverity -Color '#A0A0B0' -Text '[WARN] prefixed' | Should -Be 'warn'
        Get-LogSeverity -Color '#A0A0B0' -Text 'plain' | Should -Be 'info'
    }

    It 'converts #RRGGBB to a Win32 COLORREF' {
        ConvertTo-ColorRef '#FF0000' | Should -Be 0x0000FF
        ConvertTo-ColorRef '#0000FF' | Should -Be 0xFF0000
        ConvertTo-ColorRef 'nonsense' | Should -Be 0
    }

    It 'renders an error record with its message and error id' {
        try { throw 'something broke' } catch { $text = Format-ErrorRecord $_ }
        $text | Should -Match 'something broke'
        $text | Should -Match 'FullyQualifiedErrorId'
    }

    It 'defines every colour key in both themes' {
        $ThemePalettes['dark'].Keys | Sort-Object | Should -Be ($ThemePalettes['light'].Keys | Sort-Object)
    }
}

Describe 'Fix install and removal' {
    BeforeEach {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('game-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $game 'a.txt') -Value 'original'
        $fixZip = Join-Path $TestDrive 'fix.zip'
        Remove-Item -LiteralPath $fixZip -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'sub/b.txt' = 'added' })

        Mock Select-TargetFolder { $game }
        Mock Download-FileWithProgress { Copy-Item -LiteralPath $fixZip -Destination $Destination }
        Mock Get-Service { }
        Mock Get-Process { }
        Mock Start-Sleep { }
        Mock Start-Process { }
        Mock Write-Host { }
        Mock Read-Host { $global:CodhqTestAnswers.Dequeue() }
    }

    It 'installs the fix and backs up the files it replaces' {
        Set-Answers 'y'
        Install-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        Get-Text (Join-Path $game 'sub\b.txt') | Should -Be 'added'
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $game 'og files') -Directory)
        $backups.Count | Should -Be 1
        Get-Text (Join-Path $backups[0].FullName 'a.txt') | Should -Be 'original'
    }

    It 'changes nothing when the user says no' {
        Set-Answers 'n'
        { Install-Fix } | Should -Throw -ExceptionType ([System.OperationCanceledException])
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'refuses a ZIP that would write outside the game folder' {
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; '../evil.txt' = 'evil' })
        Set-Answers 'y'
        { Install-Fix } | Should -Throw '*unsafe path*'
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $TestDrive 'evil.txt') | Should -BeFalse
    }

    It 'removes the fix again from the backup' {
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'sub\b.txt') | Should -BeFalse
    }

    It 'restores from the oldest backup when the fix was installed twice' {
        # The second install backs up the fixed files, so only the oldest backup
        # still holds the real originals.
        Set-Answers 'y'
        Install-Fix
        $first = @(Get-ChildItem -LiteralPath (Join-Path $game 'og files') -Directory)[0]
        $first.CreationTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        Set-Answers 'y'
        Install-Fix
        @(Get-ChildItem -LiteralPath (Join-Path $game 'og files') -Directory).Count | Should -Be 2
        Set-Answers 'y'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'deletes "og files" after a successful removal' {
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Remove-Fix
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'keeps "og files" and the fix when the user says no' {
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'n'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
    }

    It 'keeps "og files" and changes nothing when an original is missing from its backup' {
        Set-Answers 'y'
        Install-Fix
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $game 'og files') -Directory)[0]
        Remove-Item -LiteralPath (Join-Path $backup.FullName 'a.txt') -Force
        Set-Answers 'y'
        { Remove-Fix } | Should -Throw '*missing from its backup*'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        Get-Text (Join-Path $game 'sub\b.txt') | Should -Be 'added'
    }

    It 'writes a backup record listing the replaced and the added files' {
        Set-Answers 'y'
        Install-Fix
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $game 'og files') -Directory)[0]
        $record = Read-FixBackupRecord -Path (Join-Path $backup.FullName (Get-FixBackupRecordName))
        $record.Complete | Should -BeTrue
        @($record.ReplacedFiles) | Should -Be @('a.txt')
        @($record.AddedFiles) | Should -Be @('sub\b.txt')
    }

    It 'removes a recorded fix without downloading anything' {
        Set-Answers 'y'
        Install-Fix
        Mock Download-FileWithProgress { throw 'network down' }
        Set-Answers 'y'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'sub\b.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'refuses a ZIP that contains the backup record name' {
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; '.codhq-fix-backup.json' = '{}' })
        Set-Answers 'y'
        { Install-Fix } | Should -Throw '*reserves*'
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
    }

    It 'leaves no partial backup when an install fails, so a later removal restores every original' {
        Set-Content -LiteralPath (Join-Path $game 'c.txt') -Value 'original c'
        $null = New-Item -ItemType Directory -Path (Join-Path $game 'd') -Force
        Remove-Item -LiteralPath $fixZip -Force
        # 'd' is a folder in the game, so the install fails after a.txt and c.txt.
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'c.txt' = 'fixed c'; 'd' = 'blocked' })
        Set-Answers 'y'
        { Install-Fix } | Should -Throw '*conflicts with an existing directory*'
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Get-Text (Join-Path $game 'c.txt') | Should -Be 'original c'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse

        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'c.txt' = 'fixed c' })
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Get-Text (Join-Path $game 'c.txt') | Should -Be 'original c'
    }

    It 'removes a fix that only added files' {
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'new.txt' = 'added only' })
        Set-Answers 'y'
        Install-Fix
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        Set-Answers 'y'
        Remove-Fix
        Test-Path -LiteralPath (Join-Path $game 'new.txt') | Should -BeFalse
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'uses a recorded backup larger than 20 MB' {
        $big = Join-Path $game 'big.bin'
        [IO.File]::WriteAllBytes($big, [byte[]]::new(21MB))
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'big.bin' = 'small fixed' })
        Set-Answers 'y'
        Install-Fix
        (Get-Item -LiteralPath $big).Length | Should -BeLessThan 1KB
        Set-Answers 'y'
        Remove-Fix
        (Get-Item -LiteralPath $big).Length | Should -Be 21MB
    }

    It 'restores each file from the backup that holds its original when a newer ZIP adds files' {
        Set-Content -LiteralPath (Join-Path $game 'e.txt') -Value 'original e'
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed' })
        Set-Answers 'y'
        Install-Fix
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'e.txt' = 'fixed e' })
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Remove-Fix
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Get-Text (Join-Path $game 'e.txt') | Should -Be 'original e'
    }

    Context 'backups made before backup records existed' {
        BeforeEach {
            # What an older version left: originals only, no record.
            $legacy = Join-Path $game 'og files\20240101-000000-abcdef'
            $null = New-Item -ItemType Directory -Path $legacy -Force
            Set-Content -LiteralPath (Join-Path $legacy 'a.txt') -Value 'original'
            Set-Content -LiteralPath (Join-Path $game 'a.txt') -Value 'fixed'
            $null = New-Item -ItemType Directory -Path (Join-Path $game 'sub') -Force
            Set-Content -LiteralPath (Join-Path $game 'sub\b.txt') -Value 'added'
        }

        It 'still removes the fix the old way' {
            Set-Answers 'y'
            Remove-Fix
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
            Test-Path -LiteralPath (Join-Path $game 'sub\b.txt') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
        }

        It 'keeps "og files" when the download fails' {
            Mock Download-FileWithProgress { throw 'network down' }
            Set-Answers 'y'
            { Remove-Fix } | Should -Throw '*network down*'
            Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        }

        It 'refuses a backup holding files that are not part of the fix' {
            Set-Content -LiteralPath (Join-Path $legacy 'other.txt') -Value 'not from the fix'
            Set-Answers 'y'
            { Remove-Fix } | Should -Throw '*not part of the fix*'
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
            Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        }

        It 'is not limited to 20 MB any more' {
            [IO.File]::WriteAllBytes((Join-Path $legacy 'a.txt'), [byte[]]::new(21MB))
            Set-Answers 'y'
            Remove-Fix
            (Get-Item -LiteralPath (Join-Path $game 'a.txt')).Length | Should -Be 21MB
        }
    }

    It 'never deletes "og files" when it is a file instead of a folder' {
        Set-Content -LiteralPath (Join-Path $game 'og files') -Value 'not a folder'
        { Remove-FixBackupFolder -TargetRoot $game } | Should -Throw
        Test-Path -LiteralPath (Join-Path $game 'og files') -PathType Leaf | Should -BeTrue
    }
}

Describe 'Reverting the fix before a downgrade' {
    BeforeEach {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('game-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $game 'a.txt') -Value 'original'
        $fixZip = Join-Path $TestDrive 'fix.zip'
        Remove-Item -LiteralPath $fixZip -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed' })

        Mock Select-TargetFolder { $game }
        Mock Resolve-GameFolderQuiet { $game }
        Mock Download-FileWithProgress { Copy-Item -LiteralPath $fixZip -Destination $Destination }
        Mock Get-Service { }
        Mock Get-Process { }
        Mock Start-Sleep { }
        Mock Start-Process { }
        Mock Write-Host { }
        Mock Add-LogEntry { }
        Mock Read-Host { $global:CodhqTestAnswers.Dequeue() }
    }

    It 'restores the originals and deletes "og files" when confirmed' {
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Clear-FixBeforeDowngrade -Method Normal
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    It 'cancels the downgrade and changes nothing when declined' {
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'n'
        { Clear-FixBeforeDowngrade -Method Normal } | Should -Throw -ExceptionType ([System.OperationCanceledException])
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
    }

    It 'deletes an "og files" that holds no usable backup' {
        $null = New-Item -ItemType Directory -Path (Join-Path $game 'og files\empty') -Force
        Set-Answers 'y'
        Clear-FixBeforeDowngrade -Method Normal
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
    }

    It 'does nothing when there is no "og files"' {
        Clear-FixBeforeDowngrade -Method Normal
        Should -Invoke Read-Host -Times 0
    }

    It 'restores a recorded backup larger than 20 MB instead of only deleting it' {
        $big = Join-Path $game 'big.bin'
        [IO.File]::WriteAllBytes($big, [byte[]]::new(21MB))
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'big.bin' = 'small fixed' })
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Clear-FixBeforeDowngrade -Method Normal
        (Get-Item -LiteralPath $big).Length | Should -Be 21MB
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeFalse
    }

    Context 'a downgrade that cannot run' {
        BeforeEach {
            $steam = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('steam-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
            Set-Content -LiteralPath (Join-Path $steam 'steam.exe') -Value 'fake'
            Mock Get-SteamInstallationPath { $steam }
            Mock Test-IsElevated { $true }
            Mock Invoke-SteamDowngrade { throw 'the downgrade must not start' }
            Set-Answers 'y'
            Install-Fix
        }

        It 'stops before the fix is touched when Steam is missing' {
            Mock Get-SteamInstallationPath { $null }
            { Invoke-DowngradeWithElevation -Method Normal } | Should -Throw '*Steam installation not found*'
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
            Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        }

        It 'stops before the fix is touched when Normal has no stplug-in folder' {
            { Invoke-DowngradeWithElevation -Method Normal } | Should -Throw '*stplug-in*'
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
            Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        }

        It 'lets Nuclear through without stplug-in, because it creates the folder' {
            Test-SteamDowngradeReadiness -Method Nuclear | Should -Be $steam
            { Test-SteamDowngradeReadiness -Method Normal } | Should -Throw '*stplug-in*'
        }
    }
}

Describe 'Temporary copies of the script' {
    BeforeEach {
        $temp = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('temp-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        function New-Copy {
            param([string]$Name, [int]$AgeHours)
            $path = Join-Path $temp $Name
            Set-Content -LiteralPath $path -Value 'copy'
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-$AgeHours)
            $path
        }
        $guidName = { 'codhq-setup-' + [guid]::NewGuid().ToString('N') + '.ps1' }
    }

    It 'recognises only codhq-setup-<guid>.ps1 directly in the temp folder' {
        Test-IsTempScriptCopy -Path (Join-Path $temp (& $guidName)) -TempDirectory $temp | Should -BeTrue
        Test-IsTempScriptCopy -Path (Join-Path $temp 'install.ps1') -TempDirectory $temp | Should -BeFalse
        Test-IsTempScriptCopy -Path (Join-Path $temp 'codhq-setup-notaguid.ps1') -TempDirectory $temp | Should -BeFalse
        Test-IsTempScriptCopy -Path (Join-Path (Join-Path $temp 'sub') (& $guidName)) -TempDirectory $temp | Should -BeFalse
        Test-IsTempScriptCopy -Path '' -TempDirectory $temp | Should -BeFalse
    }

    It 'deletes old copies but keeps recent ones, the running one and unrelated files' {
        $old = New-Copy -Name (& $guidName) -AgeHours 48
        $recent = New-Copy -Name (& $guidName) -AgeHours 2
        $running = New-Copy -Name (& $guidName) -AgeHours 72
        $unrelated = New-Copy -Name 'codhq-setup-keep.ps1' -AgeHours 72
        Remove-StaleScriptCopies -KeepPath $running -TempDirectory $temp | Should -Be 1
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath $running | Should -BeTrue
        Test-Path -LiteralPath $unrelated | Should -BeTrue
    }
}

# The language installer builds its paths with Windows separators, so it only runs
# on Windows (Windows PowerShell 5.1 or PowerShell 7). Elsewhere these are skipped.
Describe 'Language packs' -Skip:([bool]$IsLinux -or [bool]$IsMacOS) {
    BeforeEach {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('game-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $ini = Join-Path $game 'sp26\steam_settings\configs.user.ini'
        $null = New-Item -ItemType File -Path $ini -Force
        [IO.File]::WriteAllText($ini, "[user::general]`r`nlanguage=english`r`n")
        Set-Content -LiteralPath (Join-Path $game 'readme.txt') -Value 'original readme'
        $langZip = Join-Path $TestDrive 'German.zip'
        Remove-Item -LiteralPath $langZip -Force -ErrorAction SilentlyContinue
        # One shared top folder, which the installer strips.
        New-TestZip -Path $langZip -Entries ([ordered]@{ 'German/data/german.str' = 'guten tag'; 'German/readme.txt' = 'german readme' })
        $germanChoice = [string](([array]$LanguagePacks.Keys).IndexOf('German') + 1)

        Mock Select-TargetFolder { $game }
        Mock Download-LanguageArchive {
            $target = Join-Path $WorkRoot 'German.zip'
            Copy-Item -LiteralPath $langZip -Destination $target
            $target
        }
        Mock Write-Host { }
        Mock Write-Progress { }
        Mock Read-Host { $global:CodhqTestAnswers.Dequeue() }
    }

    It 'installs a pack, switches the language and backs up replaced files' {
        Set-Answers $germanChoice, 'y'
        Install-LanguagePack
        Get-ConfigLanguageValue -IniPath $ini | Should -Be 'german'
        Get-Text (Join-Path $game 'data\german.str') | Should -Be 'guten tag'
        Get-Text (Join-Path $game 'readme.txt') | Should -Be 'german readme'
        Test-Path -LiteralPath (Join-Path $game 'language files\language-pack-manager\state.json') | Should -BeTrue
    }

    It 'removes the pack and puts everything back' {
        Set-Answers $germanChoice, 'y'
        Install-LanguagePack
        Set-Answers '1', 'y'
        Remove-LanguagePack
        Get-ConfigLanguageValue -IniPath $ini | Should -Be 'english'
        Test-Path -LiteralPath (Join-Path $game 'data\german.str') | Should -BeFalse
        Get-Text (Join-Path $game 'readme.txt') | Should -Be 'original readme'
    }

    It 'switches the active preset back to English' {
        Set-Answers $germanChoice, 'y'
        Install-LanguagePack
        Set-Answers '1'
        Set-ActiveLanguagePreset
        Get-ConfigLanguageValue -IniPath $ini | Should -Be 'english'
        Test-Path -LiteralPath (Join-Path $game 'data\german.str') | Should -BeTrue
    }

    It 'rolls back when the ZIP is corrupt' {
        Set-Content -LiteralPath $langZip -Value 'not a zip'
        Set-Answers $germanChoice, 'y'
        { Install-LanguagePack } | Should -Throw
        Get-ConfigLanguageValue -IniPath $ini | Should -Be 'english'
        Get-Text (Join-Path $game 'readme.txt') | Should -Be 'original readme'
    }
}

Describe 'Steam downgrade: Lua file and manifests' {
    BeforeEach {
        $steam = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('steam-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $plugIn = Join-Path $steam 'config\stplug-in'
        $depot = Join-Path $steam 'depotcache'
        $null = New-Item -ItemType Directory -Path $plugIn, $depot -Force
        Set-Content -LiteralPath (Join-Path $plugIn '1938090.lua') -Value 'old lua'
        Set-Content -LiteralPath (Join-Path $depot "$($codDepotIds[0])_111.manifest") -Value 'old manifest'
        Set-Content -LiteralPath (Join-Path $depot '999_1.manifest') -Value 'other game'
        $manifestZip = Join-Path $TestDrive 'manifests.zip'
        Remove-Item -LiteralPath $manifestZip -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $manifestZip -Entries ([ordered]@{ "depotcache/$($codDepotIds[0])_222.manifest" = 'new manifest' })
        $global:CodhqDowngradeFail = ''

        Mock Get-SteamInstallationPath { $steam }
        Mock Get-Process { }
        Mock Stop-Process { }
        Mock Start-Process { }
        Mock Start-Sleep { }
        Mock Wait-SteamReady { }
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Download-WithProgress {
            if ($Url -eq $LuaDownloadUrl) {
                if ($global:CodhqDowngradeFail -eq 'lua') { Set-Content -LiteralPath $OutFile -Value 'partial'; throw 'Lua download failed' }
                Set-Content -LiteralPath $OutFile -Value 'new lua'
            } else {
                if ($global:CodhqDowngradeFail -eq 'zip') { throw 'manifest download failed' }
                if ($global:CodhqDowngradeFail -eq 'corrupt') { Set-Content -LiteralPath $OutFile -Value 'not a zip'; return }
                Copy-Item -LiteralPath $manifestZip -Destination $OutFile
            }
        }

        $leftoverBackups = { @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'codhq-downgrade-*' -ErrorAction SilentlyContinue) }
        $before = & $leftoverBackups
    }

    AfterAll { Remove-Variable -Name CodhqDowngradeFail -Scope Global -ErrorAction SilentlyContinue }

    It 'installs the new Lua file and manifests and deletes the temporary backup' {
        Invoke-SteamDowngrade -Method Normal
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'new lua'
        Test-Path -LiteralPath (Join-Path $plugIn '1938090_25909941.lua') | Should -BeFalse
        Get-Text (Join-Path $depot "$($codDepotIds[0])_222.manifest") | Should -Be 'new manifest'
        Test-Path -LiteralPath (Join-Path $depot "$($codDepotIds[0])_111.manifest") | Should -BeFalse
        Get-Text (Join-Path $depot '999_1.manifest') | Should -Be 'other game'
        (& $leftoverBackups).Count | Should -Be $before.Count
    }

    It 'restores the old Lua file and manifests when the <Failure> fails' -ForEach @(
        @{ Failure = 'Lua download'; Mode = 'lua' }
        @{ Failure = 'manifest download'; Mode = 'zip' }
        @{ Failure = 'manifest extraction'; Mode = 'corrupt' }
    ) {
        $global:CodhqDowngradeFail = $Mode
        { Invoke-SteamDowngrade -Method Normal } | Should -Throw
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'old lua'
        Test-Path -LiteralPath (Join-Path $plugIn '1938090_25909941.lua') | Should -BeFalse
        Get-Text (Join-Path $depot "$($codDepotIds[0])_111.manifest") | Should -Be 'old manifest'
        Test-Path -LiteralPath (Join-Path $depot "$($codDepotIds[0])_222.manifest") | Should -BeFalse
        Get-Text (Join-Path $depot '999_1.manifest') | Should -Be 'other game'
        (& $leftoverBackups).Count | Should -Be $before.Count
    }

    It 'refuses a manifest ZIP that would write outside the Steam folder' {
        Remove-Item -LiteralPath $manifestZip -Force
        New-TestZip -Path $manifestZip -Entries ([ordered]@{ "depotcache/$($codDepotIds[0])_222.manifest" = 'new manifest'; '../evil.txt' = 'evil' })
        { Invoke-SteamDowngrade -Method Normal } | Should -Throw '*unsafe path*'
        Test-Path -LiteralPath (Join-Path (Split-Path $steam -Parent) 'evil.txt') | Should -BeFalse
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'old lua'
        Get-Text (Join-Path $depot "$($codDepotIds[0])_111.manifest") | Should -Be 'old manifest'
        Test-Path -LiteralPath (Join-Path $depot "$($codDepotIds[0])_222.manifest") | Should -BeFalse
    }

    It 'puts back a Steam file the manifest ZIP overwrote when extraction fails half way' {
        $other = Join-Path $steam 'config\other.cfg'
        Set-Content -LiteralPath $other -Value 'original cfg'
        $locked = Join-Path $steam 'locked.bin'
        Set-Content -LiteralPath $locked -Value 'in use'
        Remove-Item -LiteralPath $manifestZip -Force
        New-TestZip -Path $manifestZip -Entries ([ordered]@{
            "depotcache/$($codDepotIds[0])_222.manifest" = 'new manifest'
            'config/other.cfg' = 'zip cfg'
            'locked.bin' = 'zip copy'
        })
        # An open file cannot be moved aside, so the third entry fails.
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            { Invoke-SteamDowngrade -Method Normal } | Should -Throw
        } finally { $handle.Dispose() }
        Get-Text $other | Should -Be 'original cfg'
        Get-Text $locked | Should -Be 'in use'
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'old lua'
        Get-Text (Join-Path $depot "$($codDepotIds[0])_111.manifest") | Should -Be 'old manifest'
        Test-Path -LiteralPath (Join-Path $depot "$($codDepotIds[0])_222.manifest") | Should -BeFalse
        (& $leftoverBackups).Count | Should -Be $before.Count
    }

    It 'keeps non-ASCII text in the appmanifest intact' {
        $acf = Join-Path $steam 'steamapps\appmanifest_1938090.acf'
        $null = New-Item -ItemType Directory -Path (Split-Path $acf -Parent) -Force
        $name = 'Caf' + [char]0x00E9 + ' HQ'
        $content = "`"AppState`"`n{`n`t`"name`"`t`t`"$name`"`n`t`"StateFlags`"`t`t`"6`"`n`t`"buildid`"`t`t`"123`"`n}`n"
        [IO.File]::WriteAllText($acf, $content, [Text.UTF8Encoding]::new($false))
        Invoke-SteamDowngrade -Method Normal
        $after = [IO.File]::ReadAllText($acf, [Text.UTF8Encoding]::new($false))
        $after | Should -Match ([regex]::Escape($name))
        $after | Should -Match '"StateFlags"\s+"4"'
        $after | Should -Match '"buildid"\s+"1"'
        [IO.File]::ReadAllBytes($acf)[0] | Should -Not -Be 0xEF
    }

    It 'Nuclear creates config\stplug-in when it is missing and runs BetterSteamTools out of process' {
        Remove-Item -LiteralPath $plugIn -Recurse -Force
        Mock Invoke-RestMethod { 'Write-Host "fake installer"' }
        Mock Invoke-ExternalPowerShellScript { [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = @('fake installer'); Errors = @() } }
        Invoke-SteamDowngrade -Method Nuclear
        Test-Path -LiteralPath $plugIn -PathType Container | Should -BeTrue
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'new lua'
        Should -Invoke Invoke-ExternalPowerShellScript -Times 1
        Should -Invoke Write-Warning -ParameterFilter { $Message -like '*exit code 1*' }
    }
}

Describe 'Running a downloaded script in its own process' {
    BeforeEach { $work = Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N')) }

    It 'returns its exit code and output, and its exit and variables stay in that process' {
        $global:CodhqChildMarker = 'untouched'
        $script = 'Write-Host "hello from the child"; $global:CodhqChildMarker = "changed"; Write-Error "something bad" -ErrorAction Continue; exit 3'
        $run = Invoke-ExternalPowerShellScript -ScriptText $script -WorkRoot $work -Name 'child'
        $run.ExitCode | Should -Be 3
        $run.TimedOut | Should -BeFalse
        $run.Output -join "`n" | Should -Match 'hello from the child'
        $run.Errors -join "`n" | Should -Match 'something bad'
        $global:CodhqChildMarker | Should -Be 'untouched'
        Remove-Variable -Name CodhqChildMarker -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stops a script that runs past its time limit' {
        $run = Invoke-ExternalPowerShellScript -ScriptText 'Start-Sleep -Seconds 60' -WorkRoot $work -Name 'slow' -TimeoutSeconds 3
        $run.TimedOut | Should -BeTrue
    }
}

Describe 'Administrator hand-off folder' {
    BeforeEach {
        $SettingsDirectory = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N'))
        $handoff = Join-Path $TestDrive ('handoff-' + [guid]::NewGuid().ToString('N'))
        $global:HandoffDirectory = ''
    }
    AfterEach { $global:HandoffDirectory = '' }

    It 'uses this account''s settings folder when no hand-off folder is given' {
        Get-HandoffDirectory | Should -Be $SettingsDirectory
        Write-WorkerHandshake -Method Normal
        Test-Path -LiteralPath (Join-Path $SettingsDirectory 'worker.json') | Should -BeTrue
    }

    It 'writes the worker files into -HandoffDirectory when it is given' {
        $global:HandoffDirectory = $handoff
        Write-WorkerHandshake -Method Nuclear
        Write-LastWorkerResult -Method Nuclear -State Ready -LogPath ''
        Test-Path -LiteralPath (Join-Path $handoff 'worker.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $handoff 'last-run.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $SettingsDirectory 'worker.json') | Should -BeFalse
        Get-WorkerHandshakePid -Since (Get-Date).AddMinutes(-1) | Should -Be $PID
    }

    It 'quotes paths so a trailing backslash cannot escape the quote' {
        ConvertTo-QuotedArgument 'C:\Users\Some One' | Should -BeExactly '"C:\Users\Some One"'
        ConvertTo-QuotedArgument 'D:\' | Should -BeExactly '"D:\\"'
    }
}
