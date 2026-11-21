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

    # A tiny HTTP server on 127.0.0.1 for the download tests. It serves $Content,
    # honours "Range: bytes=N-" (unless -NoRange), and for the first $FailRequests
    # requests sends only $FailAfterBytes bytes of the body and drops the connection.
    # -Statuses answers the first requests with these HTTP status codes (no body) before
    # serving normally; -RetryAfter adds a Retry-After header to those answers.
    function Start-TestHttpServer {
        param([byte[]]$Content, [int]$FailRequests = 0, [int]$FailAfterBytes = 0, [switch]$NoRange, [int[]]$Statuses = @(), [int]$RetryAfter = 0)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $state = [hashtable]::Synchronized(@{ Requests = 0; Ranges = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
        $shell = [powershell]::Create()
        [void]$shell.AddScript({
            param($listener, [byte[]]$content, $failRequests, $failAfter, $noRange, $state, [int[]]$statuses, $retryAfter)
            while ($true) {
                try { $client = $listener.AcceptTcpClient() } catch { break }
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                    $start = [int64]0
                    $line = $reader.ReadLine()
                    while ($line) {
                        if ($line -match '^Range:\s*bytes=(\d+)-') { $start = [int64]$Matches[1] }
                        $line = $reader.ReadLine()
                    }
                    $state.Requests++
                    [void]$state.Ranges.Add($start)
                    if ($state.Requests -le $statuses.Count) {
                        $code = $statuses[$state.Requests - 1]
                        $reply = "HTTP/1.1 $code Test`r`nContent-Length: 0`r`nConnection: close`r`n"
                        if ($retryAfter -gt 0) { $reply += "Retry-After: $retryAfter`r`n" }
                        $replyBytes = [Text.Encoding]::ASCII.GetBytes($reply + "`r`n")
                        $stream.Write($replyBytes, 0, $replyBytes.Length); $stream.Flush()
                        continue
                    }
                    if ($noRange) { $start = 0 }
                    $body = $content.Length - $start
                    $status = if ($start -gt 0) { '206 Partial Content' } else { '200 OK' }
                    $header = "HTTP/1.1 $status`r`nContent-Length: $body`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n"
                    if ($start -gt 0) { $header += "Content-Range: bytes $start-$($content.Length - 1)/$($content.Length)`r`n" }
                    $header += "`r`n"
                    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                    $stream.Write($headerBytes, 0, $headerBytes.Length)
                    $send = $body
                    if ($state.Requests -le $failRequests) { $send = [Math]::Min([int64]$failAfter, $body) }
                    $stream.Write($content, [int]$start, [int]$send)
                    $stream.Flush()
                } catch { } finally { $client.Close() }
            }
        }).AddArgument($listener).AddArgument($Content).AddArgument($FailRequests).AddArgument($FailAfterBytes).AddArgument([bool]$NoRange).AddArgument($state).AddArgument([int[]]$Statuses).AddArgument($RetryAfter)
        $handle = $shell.BeginInvoke()
        [pscustomobject]@{ Url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/asset.bin"; Listener = $listener; Shell = $shell; Handle = $handle; State = $state }
    }
    function Stop-TestHttpServer {
        param($Server)
        $Server.Listener.Stop()
        try { [void]$Server.Shell.EndInvoke($Server.Handle) } catch { }
        $Server.Shell.Dispose()
    }
    # Serves several files by URL path (the query string is ignored), 404 for anything
    # else; $Files maps '/folder/name' to bytes. Requested paths are counted.
    function Start-TestFileServer {
        param([hashtable]$Files)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $state = [hashtable]::Synchronized(@{ Requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) })
        $shell = [powershell]::Create()
        [void]$shell.AddScript({
            param($listener, $files, $state)
            while ($true) {
                try { $client = $listener.AcceptTcpClient() } catch { break }
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                    $first = $reader.ReadLine(); $line = $first
                    while ($line) { $line = $reader.ReadLine() }
                    $path = [Uri]::UnescapeDataString((($first -split ' ')[1] -split '\?')[0])
                    [void]$state.Requests.Add($path)
                    if ($files.ContainsKey($path)) {
                        $body = [byte[]]$files[$path]
                        $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n")
                        $stream.Write($header, 0, $header.Length); $stream.Write($body, 0, $body.Length)
                    } else {
                        $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                        $stream.Write($header, 0, $header.Length)
                    }
                    $stream.Flush()
                } catch { } finally { $client.Close() }
            }
        }).AddArgument($listener).AddArgument($Files).AddArgument($state)
        $handle = $shell.BeginInvoke()
        [pscustomobject]@{ Base = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/"; Listener = $listener; Shell = $shell; Handle = $handle; State = $state }
    }
    function Get-BytesSha1 { param([byte[]]$Bytes) $sha = [Security.Cryptography.SHA1]::Create(); try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) -join '' } finally { $sha.Dispose() } }

    function Get-BytesSha256 { param([byte[]]$Bytes) $sha = [Security.Cryptography.SHA256]::Create(); try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() } }

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

    It 'removes the folders a recorded install created, once they are empty' {
        $null = New-Item -ItemType Directory -Path (Join-Path $game 'keep') -Force
        Remove-Item -LiteralPath $fixZip -Force
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'deep/er/new.txt' = 'added'; 'keep/new.txt' = 'added' })
        Set-Answers 'y'
        Install-Fix
        Set-Answers 'y'
        Remove-Fix
        Test-Path -LiteralPath (Join-Path $game 'deep') | Should -BeFalse
        # This folder existed before the fix, so it stays even though it is empty.
        Test-Path -LiteralPath (Join-Path $game 'keep') -PathType Container | Should -BeTrue
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
            # The game holds exactly the fix's bytes, as it does after a real install.
            [IO.File]::WriteAllText((Join-Path $game 'a.txt'), 'fixed')
            $null = New-Item -ItemType Directory -Path (Join-Path $game 'sub') -Force
            [IO.File]::WriteAllText((Join-Path $game 'sub\b.txt'), 'added')
        }

        It 'removes the folder the fix created once it is empty' {
            Set-Answers 'y'
            Remove-Fix
            Test-Path -LiteralPath (Join-Path $game 'sub') | Should -BeFalse
        }

        It 'restores originals from a newer backup when an interrupted install left an older partial one' {
            # An older version: an install failed after backing up a.txt only, and its
            # rollback put a.txt and c.txt back. A later install then succeeded.
            Set-Content -LiteralPath (Join-Path $game 'c.txt') -Value 'original c'
            $complete = Join-Path $game 'og files\20240102-000000-fedcba'
            $null = New-Item -ItemType Directory -Path $complete -Force
            Set-Content -LiteralPath (Join-Path $complete 'a.txt') -Value 'original'
            Set-Content -LiteralPath (Join-Path $complete 'c.txt') -Value 'original c'
            (Get-Item -LiteralPath $legacy).CreationTimeUtc = [DateTime]::UtcNow.AddDays(-2)
            (Get-Item -LiteralPath $complete).CreationTimeUtc = [DateTime]::UtcNow.AddDays(-1)
            [IO.File]::WriteAllText((Join-Path $game 'c.txt'), 'fixed c')
            Remove-Item -LiteralPath $fixZip -Force
            New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed'; 'c.txt' = 'fixed c'; 'sub/b.txt' = 'added' })
            Set-Answers 'y'
            Remove-Fix
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
            Get-Text (Join-Path $game 'c.txt') | Should -Be 'original c'
            Test-Path -LiteralPath (Join-Path $game 'sub\b.txt') | Should -BeFalse
        }

        It 'skips a backup copy that is the fix itself, from installing twice' {
            # Second install of an older version: its backup holds the fix's a.txt.
            $second = Join-Path $game 'og files\20240103-000000-aaaaaa'
            $null = New-Item -ItemType Directory -Path (Join-Path $second 'sub') -Force
            [IO.File]::WriteAllText((Join-Path $second 'a.txt'), 'fixed')
            [IO.File]::WriteAllText((Join-Path $second 'sub\b.txt'), 'added')
            (Get-Item -LiteralPath $legacy).CreationTimeUtc = [DateTime]::UtcNow.AddDays(-2)
            (Get-Item -LiteralPath $second).CreationTimeUtc = [DateTime]::UtcNow.AddDays(-1)
            Set-Answers 'y'
            Remove-Fix
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
            Test-Path -LiteralPath (Join-Path $game 'sub\b.txt') | Should -BeFalse
        }

        It 'leaves a file alone that is neither the fix nor backed up' {
            Set-Content -LiteralPath (Join-Path $game 'sub\b.txt') -Value 'changed by someone else'
            Set-Answers 'y'
            Remove-Fix
            Get-Text (Join-Path $game 'sub\b.txt') | Should -Be 'changed by someone else'
            Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
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

    It 'uses files downloaded beforehand instead of downloading again' {
        $prefetch = Join-Path $TestDrive ('prefetch-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $prefetch -Force
        Set-Content -LiteralPath (Join-Path $prefetch 'lua') -Value 'prefetched lua'
        Copy-Item -LiteralPath $manifestZip -Destination (Join-Path $prefetch 'zip')
        Invoke-SteamDowngrade -Method Normal -Prefetched ([pscustomobject]@{ Lua = (Join-Path $prefetch 'lua'); ManifestZip = (Join-Path $prefetch 'zip') })
        Get-Text (Join-Path $plugIn '1938090.lua') | Should -Be 'prefetched lua'
        Get-Text (Join-Path $depot "$($codDepotIds[0])_222.manifest") | Should -Be 'new manifest'
        Should -Invoke Download-WithProgress -Times 0
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

    It 'reads the worker id without -Since too' {
        Write-WorkerHandshake -Method Normal
        Get-WorkerHandshakePid | Should -Be $PID
    }
}

Describe 'Pinned checksums of release files' {
    It 'has a SHA-256 for every file the utility downloads' {
        $names = @($ZipFileName, ($LuaDownloadUrl -split '/')[-1], ($ZipDownloadUrl -split '/')[-1])
        foreach ($pack in $LanguagePacks.Values) { $names += @($pack.Assets) }
        foreach ($name in $names) { Get-ReleaseAssetHash $name | Should -Match '^[0-9a-f]{64}$' -Because $name }
    }

    It 'looks up the hash of a release URL' {
        Get-ExpectedDownloadHash -Url $ZipUrl | Should -Be (Get-ReleaseAssetHash $ZipFileName)
    }

    It 'refuses a release file that has no pinned hash' {
        { Get-ExpectedDownloadHash -Url 'https://github.com/LarkTheStar/fix-installer/releases/download/1.0.0/unknown.zip' } | Should -Throw '*No pinned checksum*'
    }

    It 'does not ask for a hash outside this repository''s releases' {
        Get-ExpectedDownloadHash -Url 'https://example.com/file.zip' | Should -Be ''
    }
}

Describe 'Downloads: retries, resume and checksum' {
    BeforeAll {
        $payload = [byte[]]::new(300000)
        (New-Object Random 7).NextBytes($payload)
        $payloadHash = Get-BytesSha256 $payload
    }
    BeforeEach {
        $target = Join-Path $TestDrive ('download-' + [guid]::NewGuid().ToString('N') + '.bin')
        Mock Write-Host { }
        Mock Write-Progress { }
        $server = $null
    }
    AfterEach { if ($server) { Stop-TestHttpServer $server } }

    It 'downloads and verifies a file' {
        $server = Start-TestHttpServer -Content $payload
        Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 $payloadHash -RetryDelaySeconds 0 | Should -Be $payload.Length
        Get-BytesSha256 ([IO.File]::ReadAllBytes($target)) | Should -Be $payloadHash
    }

    It 'continues from the bytes already received after a dropped connection' {
        $server = Start-TestHttpServer -Content $payload -FailRequests 1 -FailAfterBytes 100000
        Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 $payloadHash -RetryDelaySeconds 0 | Should -Be $payload.Length
        Get-BytesSha256 ([IO.File]::ReadAllBytes($target)) | Should -Be $payloadHash
        $server.State.Requests | Should -Be 2
        $server.State.Ranges[1] | Should -Be 100000
    }

    It 'starts over when the server ignores the resume request' {
        $server = Start-TestHttpServer -Content $payload -FailRequests 1 -FailAfterBytes 100000 -NoRange
        Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 $payloadHash -RetryDelaySeconds 0 | Should -Be $payload.Length
        Get-BytesSha256 ([IO.File]::ReadAllBytes($target)) | Should -Be $payloadHash
    }

    It 'gives up after the last attempt and leaves no partial file' {
        $server = Start-TestHttpServer -Content $payload -FailRequests 10 -FailAfterBytes 1000
        # Windows PowerShell reports a short read ("incomplete"), PowerShell 7 a read
        # error ("ended prematurely"); either way it is a failed download.
        { Download-FileWithProgress -Url $server.Url -Destination $target -Label 'test' -RetryDelaySeconds 0 } | Should -Throw 'Download failed:*'
        $server.State.Requests | Should -Be 4
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'deletes a download that does not match its checksum' {
        $server = Start-TestHttpServer -Content $payload
        { Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 ('0' * 64) -RetryDelaySeconds 0 } | Should -Throw '*does not match its published checksum*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'stops at once on a file that is gone (404) and leaves nothing behind' {
        $server = Start-TestHttpServer -Content $payload -Statuses @(404)
        { Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 '' -RetryDelaySeconds 0 } | Should -Throw '*no longer published*404*'
        $server.State.Requests | Should -Be 1
    }

    It 'retries a busy server (503) and waits as long as Retry-After says' {
        Mock Start-Sleep { }
        $server = Start-TestHttpServer -Content $payload -Statuses @(503, 429) -RetryAfter 2
        Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 $payloadHash -RetryDelaySeconds 0 | Should -Be $payload.Length
        $server.State.Requests | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -ParameterFilter { $Seconds -eq 2 }
    }

    It 'checks a SHA-1 from a client manifest and returns both hashes' {
        $server = Start-TestHttpServer -Content $payload
        $sha1 = (Get-FileHash -InputStream ([IO.MemoryStream]::new($payload)) -Algorithm SHA1).Hash
        $result = Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 '' -ExpectedSha1 $sha1 -RetryDelaySeconds 0 -PassThru
        $result.Bytes | Should -Be $payload.Length
        $result.Sha1 | Should -Be $sha1
        $result.Sha256 | Should -Be $payloadHash
    }

    It 'deletes a download whose SHA-1 does not match its manifest' {
        $server = Start-TestHttpServer -Content $payload
        { Invoke-ResumableDownload -Url $server.Url -Destination $target -Label 'test' -ExpectedSha256 '' -ExpectedSha1 ('A' * 40) -RetryDelaySeconds 0 } | Should -Throw '*does not match its manifest*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'checks the downgrade downloader against the pinned hash too' {
        $server = Start-TestHttpServer -Content $payload
        Mock Get-ExpectedDownloadHash { '1' * 64 }
        { Download-WithProgress -Url $server.Url -OutFile $target -Activity 'test' -RetryDelaySeconds 0 } | Should -Throw '*does not match*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Downgrade order: check, download, then revert the fix' {
    BeforeEach {
        $game = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('game-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $game 'a.txt') -Value 'original'
        $fixZip = Join-Path $TestDrive 'fix.zip'
        Remove-Item -LiteralPath $fixZip -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $fixZip -Entries ([ordered]@{ 'a.txt' = 'fixed' })
        $steam = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('steam-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $steam 'steam.exe') -Value 'fake'
        $null = New-Item -ItemType Directory -Path (Join-Path $steam 'config\stplug-in') -Force

        Mock Select-TargetFolder { $game }
        Mock Resolve-GameFolderQuiet { $game }
        Mock Download-FileWithProgress { Copy-Item -LiteralPath $fixZip -Destination $Destination }
        Mock Get-SteamInstallationPath { $steam }
        Mock Test-IsElevated { $true }
        Mock Get-Service { }
        Mock Get-Process { }
        Mock Start-Sleep { }
        Mock Start-Process { }
        Mock Write-Host { }
        Mock Add-LogEntry { }
        Mock Read-Host { $global:CodhqTestAnswers.Dequeue() }
        Mock Invoke-SteamDowngrade { }
        Set-Answers 'y'
        Install-Fix
    }

    It 'stops before the fix is touched when a download fails' {
        Mock Download-WithProgress { throw 'network down' }
        { Invoke-DowngradeWithElevation -Method Normal } | Should -Throw '*network down*'
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'fixed'
        Test-Path -LiteralPath (Join-Path $game 'og files') | Should -BeTrue
        Should -Invoke Invoke-SteamDowngrade -Times 0
    }

    It 'hands the downloaded files to the downgrade after reverting the fix' {
        Mock Download-WithProgress { Set-Content -LiteralPath $OutFile -Value "downloaded $Activity" }
        Set-Answers 'y'
        Invoke-DowngradeWithElevation -Method Normal
        Get-Text (Join-Path $game 'a.txt') | Should -Be 'original'
        Should -Invoke Invoke-SteamDowngrade -Times 1 -ParameterFilter { $null -ne $Prefetched -and $Prefetched.Lua -like '*1938090_25909941.lua' }
        @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'codhq-prefetch-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-1) }).Count | Should -Be 0
    }
}

Describe 'Sandbox mode' {
    BeforeEach {
        $sandbox = Join-Path $TestDrive ('sandbox-' + [guid]::NewGuid().ToString('N'))
        $starter = Join-Path $PSScriptRoot 'Start-Sandbox.ps1'
        Mock Write-Host { }
        Mock Get-Process { }
        Mock Stop-Process { }
        Mock Start-Process { }
        Mock Start-Sleep { }
    }
    AfterEach { $global:SandboxRoot = '' }

    It 'builds a sandbox with the marker, a fake Steam and a fake game' {
        $output = & $starter -Path $sandbox -NoLaunch
        Test-Path -LiteralPath (Join-Path $sandbox '.codhq-sandbox') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sandbox 'Steam\steam.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sandbox 'Steam\config\stplug-in\1938090.lua') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sandbox 'Game\sp26\steam_settings\configs.user.ini') | Should -BeTrue
        ($output -join "`n") | Should -Match 'Sandbox created'
        (& $starter -Path $sandbox -Report) -join "`n" | Should -Match '1938090\.lua'
    }

    It 'refuses to reset a folder that is not a sandbox' {
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        Set-Content -LiteralPath (Join-Path $sandbox 'precious.txt') -Value 'keep me'
        { & $starter -Path $sandbox -Reset -NoLaunch } | Should -Throw '*no .codhq-sandbox marker*'
        Test-Path -LiteralPath (Join-Path $sandbox 'precious.txt') | Should -BeTrue
    }

    It 'only sees the sandbox Steam and never closes, starts or waits for the real one' {
        $null = & $starter -Path $sandbox -NoLaunch
        $global:SandboxRoot = $sandbox
        Get-SteamInstallationPath | Should -Be (Join-Path $sandbox 'Steam')
        @(Get-SteamLibraries) | Should -Be @((Join-Path $sandbox 'Steam'))
        Get-SteamClientProcess | Should -BeNullOrEmpty
        Start-SteamClient -SteamExe (Join-Path $sandbox 'Steam\steam.exe')
        Start-SteamValidation
        Wait-SteamReady
        Should -Invoke Get-Process -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'runs a whole Nuclear downgrade inside the sandbox without BetterSteamTools' {
        $null = & $starter -Path $sandbox -NoLaunch
        $global:SandboxRoot = $sandbox
        $manifestZip = Join-Path $TestDrive 'sandbox-manifests.zip'
        Remove-Item -LiteralPath $manifestZip -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $manifestZip -Entries ([ordered]@{ "depotcache/$($codDepotIds[0])_222.manifest" = 'new manifest' })
        Mock Download-WithProgress { if ($Url -eq $LuaDownloadUrl) { Set-Content -LiteralPath $OutFile -Value 'new lua' } else { Copy-Item -LiteralPath $manifestZip -Destination $OutFile } }
        Mock Invoke-RestMethod { throw 'must not download BetterSteamTools' }
        Mock Invoke-ExternalPowerShellScript { throw 'must not run BetterSteamTools' }
        Mock Write-Warning { }
        Invoke-SteamDowngrade -Method Nuclear
        Get-Text (Join-Path $sandbox 'Steam\config\stplug-in\1938090.lua') | Should -Be 'new lua'
        Test-Path -LiteralPath (Join-Path $sandbox 'Steam\logs') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox 'Steam\userdata\keep.txt') | Should -BeTrue
        Should -Invoke Invoke-ExternalPowerShellScript -Times 0
        Should -Invoke Start-Process -Times 0
        Get-Text (Join-Path $sandbox 'Steam\steamapps\appmanifest_1938090.acf') | Should -Match '"StateFlags"\s+"4"'
    }
}

Describe 'Game catalogue' {
    BeforeAll {
        $catalog = @(Get-GameCatalog)
        $auditPath = Join-Path $PSScriptRoot '..\docs\cb-launcher\audit.json'
        $audit = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
    }

    It 'has unique ids and every field the Games page needs' {
        @($catalog.Id | Select-Object -Unique).Count | Should -Be $catalog.Count
        foreach ($game in $catalog) {
            $game.Name | Should -Not -BeNullOrEmpty -Because $game.Id
            @($game.ValidFiles).Count | Should -BeGreaterThan 0 -Because $game.Id
            if (-not $game.Available) { $game.UnavailableReason | Should -Not -BeNullOrEmpty -Because $game.Id }
        }
    }

    It 'only names clients a game actually has in its modes' {
        foreach ($game in $catalog) {
            $ids = @($game.Clients | ForEach-Object { $_.Id })
            foreach ($mode in $game.Modes) { foreach ($client in $mode.Clients) { $ids | Should -Contain $client -Because "$($game.Id) mode $($mode.Id)" } }
        }
    }

    It 'pins a SHA-256 for every file it downloads outside CB manifests' {
        foreach ($client in @($catalog.Clients | Where-Object { $_.Source -ne 'cb' })) {
            @($client.Assets).Count | Should -BeGreaterThan 0 -Because $client.Id
            foreach ($asset in $client.Assets) { $asset.Sha256 | Should -Match '^[0-9a-f]{64}$' -Because "$($client.Id) $($asset.Path)" }
        }
    }

    It 'never downloads a file the audit denied or could not trace, and derives what the audit derives' {
        foreach ($client in @($catalog.Clients | Where-Object { $_.Source -eq 'cb' } | Sort-Object Id -Unique)) {
            $manifest = $audit.Manifests | Where-Object { $_.Manifest -eq $client.Manifest }
            $manifest | Should -Not -BeNullOrEmpty -Because "$($client.Id) uses $($client.Manifest)"
            foreach ($file in $manifest.Files) {
                $verdict = Get-ClientEntryVerdict -Client $client -Path $file.Path
                if ($verdict -eq 'allow') { $file.Verdict | Should -Be 'allowed' -Because "$($client.Id): $($file.Path)" }
                if ($file.Verdict -eq 'derive') { $verdict | Should -Be 'derive' -Because "$($client.Id): $($file.Path)" }
                if ($file.Verdict -in 'denied', 'no-trace') { $verdict | Should -Not -Be 'allow' -Because "$($client.Id): $($file.Path)" }
            }
        }
    }

    It 'downloads the files each client needs to run' {
        $needed = @{ 'iw4x' = 'iw4x.exe'; 'iw6x' = 'iw6x.exe'; 's1x' = 's1x.exe'; 'boiii' = 'boiii.exe'; 'h1-mod' = 'h1-mod.exe'; 'iw7-mod' = 'iw7-mod.exe'; 'h2-mod' = 'h2-mod.exe'; 'cod4x' = 'mss32.dll'; 'iw3x' = 'mss32.dll'; 'iw3sp-mod' = 'iw3sp_mod.exe'; 'cod2x' = 'mss32.dll'; 'alterware' = 'alterware-launcher.exe' }
        foreach ($id in $needed.Keys) {
            $client = $catalog.Clients | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            Get-ClientEntryVerdict -Client $client -Path $needed[$id] | Should -Be 'allow' -Because $id
        }
    }

    It 'skips a file added to a manifest after the audit' {
        $client = ($catalog | Where-Object Id -eq 'ghosts').Clients[0]
        Get-ClientEntryVerdict -Client $client -Path 'something-new.exe' | Should -Be 'skip'
        Get-ClientEntryVerdict -Client $client -Path 'data/scripts/new.gsc' | Should -Be 'allow'
    }
}

Describe 'Client manifests' {
    BeforeEach { $servers = [System.Collections.Generic.List[object]]::new() }
    AfterEach { foreach ($s in $servers) { Stop-TestHttpServer $s } }

    It 'reads entries, destinations and the manifest hash' {
        $json = '[["iw6x.exe",3,"' + ('A' * 40) + '"],["data/a.txt",1,"' + ('b' * 40) + '","appdata"],{"ManifestHash":"' + ('C' * 64) + '"}]'
        $server = Start-TestHttpServer -Content ([Text.Encoding]::ASCII.GetBytes($json)); $servers.Add($server)
        $base = $server.Url -replace 'asset\.bin$', ''
        $manifest = Get-ClientManifest -Manifest 'x.json' -Bases @($base)
        $manifest.Entries.Count | Should -Be 2
        $manifest.Entries[1].Dest | Should -Be 'appdata'
        $manifest.Entries[1].Sha1 | Should -Be ('B' * 40)
        $manifest.ManifestHash | Should -Be ('C' * 64)
    }

    It 'falls back to the next source when one fails' {
        $json = '[["iw6x.exe",3,"' + ('A' * 40) + '"]]'
        $bad = Start-TestHttpServer -Content ([byte[]]@()) -Statuses @(404); $servers.Add($bad)
        $good = Start-TestHttpServer -Content ([Text.Encoding]::ASCII.GetBytes($json)); $servers.Add($good)
        $manifest = Get-ClientManifest -Manifest 'x.json' -Bases @(($bad.Url -replace 'asset\.bin$', ''), ($good.Url -replace 'asset\.bin$', ''))
        $manifest.Base | Should -Be ($good.Url -replace 'asset\.bin$', '')
    }

    It 'refuses a manifest with an unsafe path or a bad hash' {
        foreach ($json in @('[["../evil.exe",3,"' + ('A' * 40) + '"]]', '[["ok.exe",3,"nothex"]]')) {
            $server = Start-TestHttpServer -Content ([Text.Encoding]::ASCII.GetBytes($json)); $servers.Add($server)
            { Get-ClientManifest -Manifest 'x.json' -Bases @(($server.Url -replace 'asset\.bin$', '')) } | Should -Throw '*Could not read the client manifest*'
        }
    }
}

Describe 'Game clients: install, update, remove' {
    BeforeAll {
        $served = [hashtable]::Synchronized(@{})
        $fileServer = Start-TestFileServer -Files $served
        # A manifest object as Get-ClientManifest returns it; the files are put on the
        # local server under the client's folder.
        function New-FakeManifest {
            param($Client, [System.Collections.IDictionary]$Files)
            $entries = foreach ($path in $Files.Keys) {
                $spec = $Files[$path]
                $bytes = if ($spec -is [hashtable]) { [Text.Encoding]::ASCII.GetBytes([string]$spec.Text) } else { [Text.Encoding]::ASCII.GetBytes([string]$spec) }
                $dest = if ($spec -is [hashtable] -and $spec.Dest) { $spec.Dest } else { '' }
                if (-not ($spec -is [hashtable] -and $spec.NotServed)) { $served['/' + $Client.Folder + $path] = $bytes }
                $sha1 = if ($spec -is [hashtable] -and $spec.Sha1) { $spec.Sha1 } else { Get-BytesSha1 $bytes }
                [pscustomobject]@{ Path = $path; Size = [int64]$bytes.Length; Sha1 = $sha1; Dest = $dest }
            }
            [pscustomobject]@{ Name = $Client.Manifest; Base = $fileServer.Base; Entries = @($entries); ManifestHash = ('A' * 64) }
        }
    }
    AfterAll { Stop-TestHttpServer $fileServer }

    BeforeEach {
        $served.Clear()
        $appData = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('appdata-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $ghostsFolder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('ghosts-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $ghostsFolder 'iw6mp64_ship.exe') -Value 'retail'
        $ghosts = Get-CatalogGame -Id 'ghosts'; $iw6x = $ghosts.Clients[0]
        Mock Get-ClientAppDataRoot { $appData }
        Mock Write-Host { }
        Mock Write-Progress { }
    }

    It 'installs only the audited files and records every one with its hashes' {
        $manifest = New-FakeManifest -Client $iw6x -Files ([ordered]@{ 'iw6x.exe' = 'client exe'; 'data/scripts/a.gsc' = 'script'; 'surprise.exe' = 'not audited' })
        $result = Install-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest -RetryDelaySeconds 0
        Get-Text (Join-Path $ghostsFolder 'iw6x.exe') | Should -Be 'client exe'
        Get-Text (Join-Path $ghostsFolder 'data\scripts\a.gsc') | Should -Be 'script'
        Test-Path -LiteralPath (Join-Path $ghostsFolder 'surprise.exe') | Should -BeFalse
        $result.Downloaded | Should -Be 2
        $result.Skipped | Should -Be 1
        $record = Read-ClientRecord -GameFolder $ghostsFolder -ClientId 'iw6x'
        @($record.Files).Count | Should -Be 2
        foreach ($file in $record.Files) { $file.Sha256 | Should -Match '^[0-9a-f]{64}$'; $file.Sha1 | Should -Match '^[0-9A-F]{40}$' }
        Test-GameClientInstalled -GameFolder $ghostsFolder -ClientId 'iw6x' | Should -BeTrue
    }

    It 'updates by downloading only what changed and removing what the client dropped' {
        $manifest = New-FakeManifest -Client $iw6x -Files ([ordered]@{ 'iw6x.exe' = 'v1'; 'data/old.gsc' = 'old'; 'data/keep.gsc' = 'keep' })
        $null = Install-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest -RetryDelaySeconds 0
        $same = Update-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest -RetryDelaySeconds 0
        $same.Downloaded | Should -Be 0
        $served.Clear(); $fileServer.State.Requests.Clear()
        $manifest2 = New-FakeManifest -Client $iw6x -Files ([ordered]@{ 'iw6x.exe' = 'v2'; 'data/keep.gsc' = 'keep' })
        $updated = Update-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest2 -RetryDelaySeconds 0
        $updated.Downloaded | Should -Be 1
        @($fileServer.State.Requests) | Should -Be @('/iw6x/iw6x.exe')
        Get-Text (Join-Path $ghostsFolder 'iw6x.exe') | Should -Be 'v2'
        Test-Path -LiteralPath (Join-Path $ghostsFolder 'data\old.gsc') | Should -BeFalse
    }

    It 'removes a client completely, including the folders it created' {
        $manifest = New-FakeManifest -Client $iw6x -Files ([ordered]@{ 'iw6x.exe' = 'client'; 'data/deep/x.gsc' = 'x' })
        $null = Install-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest -RetryDelaySeconds 0
        Remove-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder
        Test-Path -LiteralPath (Join-Path $ghostsFolder 'iw6x.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $ghostsFolder 'data') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $ghostsFolder -ClientId 'iw6x') | Should -BeFalse
        Get-Text (Join-Path $ghostsFolder 'iw6mp64_ship.exe') | Should -Be 'retail'
    }

    It 'never downloads a denied file, keeps the player''s own and remembers its build' {
        $mw2Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('mw2-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $mw2Folder 'iw4mp.exe') -Value 'retail'
        [IO.File]::WriteAllText((Join-Path $mw2Folder 'binkw32.dll'), 'players bink')
        $iw4x = (Get-CatalogGame -Id 'mw2').Clients[0]
        $manifest = New-FakeManifest -Client $iw4x -Files ([ordered]@{ 'iw4x.exe' = 'client'; 'binkw32.dll' = @{ Text = 'cb copy of bink'; NotServed = $true } })
        $result = Install-GameClient -GameId 'mw2' -ClientId 'iw4x' -GameFolder $mw2Folder -Manifest $manifest -RetryDelaySeconds 0
        $result.Kept | Should -Be 1
        Get-Text (Join-Path $mw2Folder 'binkw32.dll') | Should -Be 'players bink'
        @($fileServer.State.Requests | Where-Object { $_ -like '*binkw32*' }).Count | Should -Be 0
        $info = Get-GameBuildInfo -Game (Get-CatalogGame -Id 'mw2') -GameFolder $mw2Folder
        @($info.Mismatches).Count | Should -Be 1
        $info.Mismatches[0].Path | Should -Be 'binkw32.dll'
    }

    It 'makes a renamed original from the player''s own file, backs up what it replaces and restores it on removal' {
        $cod2Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod2-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod2Folder 'CoD2MP_s.exe') -Value 'retail'
        [IO.File]::WriteAllText((Join-Path $cod2Folder 'mss32.dll'), 'original miles')
        $cod2x = (Get-CatalogGame -Id 'cod2').Clients[0]
        $manifest = New-FakeManifest -Client $cod2x -Files ([ordered]@{ 'mss32.dll' = 'cod2x proxy'; 'mss32_original.dll' = @{ Text = 'original miles'; NotServed = $true } })
        $result = Install-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder -Manifest $manifest -RetryDelaySeconds 0
        $result.Derived | Should -Be 1
        Get-Text (Join-Path $cod2Folder 'mss32_original.dll') | Should -Be 'original miles'
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'cod2x proxy'
        # Installing again finds the original in the backup, although mss32.dll is now the proxy.
        $again = Install-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder -Manifest $manifest -RetryDelaySeconds 0
        $again.Downloaded | Should -Be 0
        Remove-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'original miles'
        Test-Path -LiteralPath (Join-Path $cod2Folder 'mss32_original.dll') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod2Folder '.codhq-backups') | Should -BeFalse
    }

    It 'changes nothing when the player''s file is not the original the client needs' {
        $cod2Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod2-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod2Folder 'CoD2MP_s.exe') -Value 'retail'
        [IO.File]::WriteAllText((Join-Path $cod2Folder 'mss32.dll'), 'some other build')
        $cod2x = (Get-CatalogGame -Id 'cod2').Clients[0]
        $manifest = New-FakeManifest -Client $cod2x -Files ([ordered]@{ 'mss32.dll' = 'cod2x proxy'; 'mss32_original.dll' = @{ Text = 'original miles'; NotServed = $true } })
        { Install-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder -Manifest $manifest -RetryDelaySeconds 0 } | Should -Throw '*not the original build*'
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'some other build'
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod2Folder -ClientId 'cod2x') | Should -BeFalse
    }

    It 'refuses a second client that replaces the same file differently' {
        $cod4Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod4-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod4Folder 'iw3mp.exe') -Value 'retail'
        $cod4 = Get-CatalogGame -Id 'cod4'
        $cod4x = $cod4.Clients | Where-Object Id -eq 'cod4x'; $iw3x = $cod4.Clients | Where-Object Id -eq 'iw3x'
        $null = Install-GameClient -GameId 'cod4' -ClientId 'cod4x' -GameFolder $cod4Folder -Manifest (New-FakeManifest -Client $cod4x -Files ([ordered]@{ 'mss32.dll' = @{ Text = 'cod4x proxy'; Dest = 'game' } })) -RetryDelaySeconds 0
        { Install-GameClient -GameId 'cod4' -ClientId 'iw3x' -GameFolder $cod4Folder -Manifest (New-FakeManifest -Client $iw3x -Files ([ordered]@{ 'mss32.dll' = @{ Text = 'iw3x proxy'; Dest = 'game' } })) -RetryDelaySeconds 0 } | Should -Throw '*Remove cod4x first*'
        Get-Text (Join-Path $cod4Folder 'mss32.dll') | Should -Be 'cod4x proxy'
    }

    It 'puts everything back when writing fails half way' {
        $manifest = New-FakeManifest -Client $iw6x -Files ([ordered]@{ 'data/a.gsc' = 'a'; 'iw6x.exe' = 'client' })
        Set-Content -LiteralPath (Join-Path $ghostsFolder 'iw6x.exe') -Value 'locked old'
        $handle = [IO.File]::Open((Join-Path $ghostsFolder 'iw6x.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { { Install-GameClient -GameId 'ghosts' -ClientId 'iw6x' -GameFolder $ghostsFolder -Manifest $manifest -RetryDelaySeconds 0 } | Should -Throw }
        finally { $handle.Dispose() }
        Test-Path -LiteralPath (Join-Path $ghostsFolder 'data\a.gsc') | Should -BeFalse
        Get-Text (Join-Path $ghostsFolder 'iw6x.exe') | Should -Be 'locked old'
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $ghostsFolder -ClientId 'iw6x') | Should -BeFalse
    }

    It 'puts AppData files under the client''s own AppData folder' {
        $mwrFolder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('mwr-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $mwrFolder 'h1_mp64_ship.exe') -Value 'retail'
        $h1 = (Get-CatalogGame -Id 'mwr').Clients[0]
        $null = Install-GameClient -GameId 'mwr' -ClientId 'h1-mod' -GameFolder $mwrFolder -Manifest (New-FakeManifest -Client $h1 -Files ([ordered]@{ 'h1-mod.exe' = 'exe'; 'cdata/ui/x.lua' = 'lua' })) -RetryDelaySeconds 0
        Get-Text (Join-Path $mwrFolder 'h1-mod.exe') | Should -Be 'exe'
        Get-Text (Join-Path $appData 'h1-mod\cdata\ui\x.lua') | Should -Be 'lua'
    }
}

Describe 'Plutonium and launching games' {
    BeforeEach {
        $appData = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('appdata-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Mock Get-ClientAppDataRoot { $appData }
        Mock Write-Host { }
        $config = Join-Path $appData 'Plutonium\config.json'
    }

    It 'creates config.json with every field Plutonium expects' {
        Set-PlutoniumGamePath -Key 't6Path' -Path 'D:\Games\BO2' | Should -BeTrue
        $data = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $data.t6Path | Should -Be 'D:\Games\BO2'
        foreach ($field in 'iw5Path', 't4Path', 't5Path', 'token') { $data.PSObject.Properties[$field] | Should -Not -BeNullOrEmpty -Because $field }
    }

    It 'keeps the login token and other settings' {
        $null = New-Item -ItemType Directory -Path (Split-Path $config) -Force
        Set-Content -LiteralPath $config -Value '{"token":"secret-token","t4Path":"C:\\WaW","extra":5}'
        Set-PlutoniumGamePath -Key 't6Path' -Path 'D:\BO2' | Should -BeTrue
        $data = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
        $data.token | Should -Be 'secret-token'
        $data.t4Path | Should -Be 'C:\WaW'
        $data.extra | Should -Be 5
        $data.t6Path | Should -Be 'D:\BO2'
    }

    It 'leaves a config.json it cannot read alone' {
        $null = New-Item -ItemType Directory -Path (Split-Path $config) -Force
        Set-Content -LiteralPath $config -Value '{ not json'
        Set-PlutoniumGamePath -Key 't6Path' -Path 'D:\BO2' | Should -BeFalse
        Get-Text $config | Should -Be '{ not json'
    }

    It 'builds the exact command lines' {
        $mw2 = Get-CatalogGame -Id 'mw2'
        $cmd = Get-CatalogLaunchCommand -Game $mw2 -Mode ($mw2.Modes | Where-Object Id -eq 'mp') -GameFolder 'C:\MW2' -PlayerName 'Lark'
        $cmd.FilePath | Should -Be 'C:\MW2\iw4x.exe'
        $cmd.Arguments | Should -Be '+set name "Lark"'
        $ghosts = Get-CatalogGame -Id 'ghosts'
        (Get-CatalogLaunchCommand -Game $ghosts -Mode ($ghosts.Modes | Where-Object Id -eq 'sp') -GameFolder 'C:\G' -PlayerName '').Arguments | Should -Be '-noupdate -singleplayer'
        $bo2 = Get-CatalogGame -Id 'bo2'
        $pluto = Get-CatalogLaunchCommand -Game $bo2 -Mode ($bo2.Modes | Where-Object Id -eq 'zm') -GameFolder 'C:\BO2'
        $pluto.FilePath | Should -Be (Join-Path $appData 'Plutonium\bin\plutonium-launcher-win32.exe')
        $pluto.Arguments | Should -Be 'plutonium://play/t6zm'
        $cod2 = Get-CatalogGame -Id 'cod2'
        (Get-CatalogLaunchCommand -Game $cod2 -Mode ($cod2.Modes | Where-Object Id -eq 'mp') -GameFolder 'C:\C2').Elevate | Should -BeTrue
    }

    It 'cleans the player name to what the clients accept' {
        Get-CleanPlayerName 'A very long player name here' | Should -Be 'A very long play'
        Get-CleanPlayerName 'bad"name;&' | Should -Be 'badname'
        Get-CleanPlayerName '   ' | Should -Be ''
    }

    It 'will not start a mode whose client is not installed' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('ghosts-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $folder 'iw6mp64_ship.exe') -Value 'retail'
        Mock Start-Process { }
        { Start-CatalogGame -GameId 'ghosts' -ModeId 'mp' -GameFolder $folder } | Should -Throw '*needs IW6x*'
        Should -Invoke Start-Process -Times 0
    }

    It 'starts nothing in sandbox mode and reports the command instead' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod1-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $folder 'CoDMP.exe') -Value 'retail'
        Mock Start-Process { }
        Mock Test-SandboxMode { $true }
        $cmd = Start-CatalogGame -GameId 'cod1' -ModeId 'mp' -GameFolder $folder
        $cmd.Arguments | Should -Be '+set com_hunkmegs 512 +set r_lodbias -1000'
        Should -Invoke Start-Process -Times 0
    }
}

Describe 'Game detection' {
    BeforeEach {
        $SettingsDirectory = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N'))
        $SettingsFile = Join-Path $SettingsDirectory 'settings.json'
        $library = Join-Path $TestDrive ('library-' + [guid]::NewGuid().ToString('N'))
        $cod4 = Join-Path $library 'steamapps\common\Call of Duty 4'
        $null = New-Item -ItemType Directory -Path $cod4 -Force
        Set-Content -LiteralPath (Join-Path $cod4 'iw3mp.exe') -Value 'fake'
        Set-Content -LiteralPath (Join-Path $library 'steamapps\appmanifest_7940.acf') -Value "`"AppState`"`n{`n`t`"appid`"`t`t`"7940`"`n`t`"installdir`"`t`t`"Call of Duty 4`"`n}"
        Mock Get-SteamLibraries { @($library) }
        Mock Write-Host { }
        $game = Get-CatalogGame -Id 'cod4'
    }

    It 'finds a game through its Steam app manifest' {
        $found = Find-CatalogGame -Game $game
        $found.Folder | Should -Be ([IO.Path]::GetFullPath($cod4))
        $found.Source | Should -Be 'steam'
    }

    It 'does not accept a folder without the game''s files' {
        Remove-Item -LiteralPath (Join-Path $cod4 'iw3mp.exe')
        Find-CatalogGame -Game $game | Should -BeNullOrEmpty
        Test-CatalogGameFolder -Game $game -Folder $cod4 | Should -BeFalse
    }

    It 'prefers a saved folder and keeps the MW4 settings apart' {
        $other = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod4-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $other 'iw3sp.exe') -Value 'fake'
        Save-CatalogGameFolder -Id 'cod4' -Folder $other | Should -BeTrue
        (Find-CatalogGame -Game $game).Folder | Should -Be $other.TrimEnd('\')
        (Find-CatalogGame -Game $game).Source | Should -Be 'saved'
        (Get-AppSettings).GameFolder | Should -Be ''
        Save-CatalogGameFolder -Id 'cod4' -Folder '' | Should -BeTrue
        Get-CatalogGameFolder -Id 'cod4' | Should -BeNullOrEmpty
    }

    It 'loads settings files written before the Games page existed' {
        $null = New-Item -ItemType Directory -Path $SettingsDirectory -Force
        Set-Content -LiteralPath $SettingsFile -Value '{ "GameFolder": "", "Theme": "light" }'
        (Get-AppSettings).Theme | Should -Be 'light'
        Get-CatalogGameFolder -Id 'cod4' | Should -BeNullOrEmpty
        (Find-CatalogGame -Game $game).Source | Should -Be 'steam'
    }
}
