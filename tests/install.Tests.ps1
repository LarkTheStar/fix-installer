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

    It 'computes both checksums without the Get-FileHash cmdlet' {
        $file = Join-Path $TestDrive ('hash-' + [guid]::NewGuid().ToString('N') + '.bin')
        [IO.File]::WriteAllBytes($file, $payload)
        Get-FileSha256 -Path $file | Should -Be (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        Get-FileSha1Hex $file | Should -Be (Get-FileHash -LiteralPath $file -Algorithm SHA1).Hash.ToUpperInvariant()
        # A Windows PowerShell process started by a PowerShell 7 one inherits PowerShell
        # 7's module path, where Get-FileHash cannot be loaded ("not recognized"): the
        # checksum must come from .NET, not from that cmdlet.
        foreach ($name in 'Get-FileHashHex', 'Get-FileSha256', 'Get-FileSha1Hex') {
            (Get-Command $name).Definition | Should -Not -Match '\bGet-FileHash\b' -Because $name
        }
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

    It 'only gives a repair step to a game that declares one' {
        # $null counts as one item in @(), so a card whose game has no Repair used to
        # grow a Repair button whose action then had nothing to delete.
        $withRepair = @($catalog | Where-Object { @(Get-CatalogRepairFiles -Game $_).Count -gt 0 })
        $withRepair.Count | Should -Be 1
        $withRepair[0].Id | Should -Be 'bo4'
        ((Get-CatalogRepairFiles -Game (Get-CatalogGame -Id 'bo4')) -join ',') | Should -Be 'BlackOps4.start'
        @(Get-CatalogRepairFiles -Game (Get-CatalogGame -Id 'cod4')).Count | Should -Be 0
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
        foreach ($client in @($catalog.Clients | Where-Object { $_.Source -notin @('cb', 'manifest') })) {
            if ($client.Extract -or $client.Source -eq 'codhq') {
                $archives = @(@($client.Archives) | Where-Object { $null -ne $_ })
                if ($archives.Count -eq 0) { $archives = @($client.Archive) }
                $archives.Count | Should -BeGreaterThan 0 -Because $client.Id
                foreach ($archive in $archives) {
                    $archive.Url | Should -Match '^https://' -Because $client.Id
                    $archive.Sha256 | Should -Match '^[0-9A-Fa-f]{64}$' -Because $client.Id
                }
                continue
            }
            @($client.Assets).Count | Should -BeGreaterThan 0 -Because $client.Id
            foreach ($asset in $client.Assets) {
                $asset.Sha256 | Should -Match '^[0-9a-f]{64}$' -Because "$($client.Id) $($asset.Path)"
                if ($asset.PSObject.Properties['Archive']) { $asset.Archive.Sha256 | Should -Match '^[0-9a-f]{64}$' -Because "$($client.Id) $($asset.Path) archive" }
            }
        }
    }

    It 'has cards for United Offensive and Call of Duty 2' {
        foreach ($id in 'coduo', 'cod2') {
            $game = Get-CatalogGame -Id $id
            $game | Should -Not -BeNullOrEmpty -Because $id
            $game.Available | Should -BeTrue -Because $id
            @($game.ValidFiles | Where-Object { $_ -like '*.exe' }).Count | Should -Be 2 -Because $id
            $game.Note | Should -Not -BeNullOrEmpty -Because $id
        }
        # Call of Duty 2 has its two community patches, and a mode for each executable.
        $cod2 = Get-CatalogGame -Id 'cod2'
        @($cod2.Clients | ForEach-Object { $_.Id }) | Should -Be @('cod2-v2', 'cod2x')
        @($cod2.Modes | ForEach-Object { $_.Exe }) | Should -Be @('CoD2SP_s.exe', 'CoD2MP_s.exe')
        # United Offensive is not looked for in Steam at all: it goes where the player
        # picks. Call of Duty 2 is still found through Steam.
        @((Get-CatalogGame -Id 'coduo').SteamAppIds).Count | Should -Be 0
        (Get-CatalogGame -Id 'coduo').Detect | Should -Be 'none'
        @((Get-CatalogGame -Id 'cod2').SteamAppIds) | Should -Be @(2630)
    }

    It 'matches every client the CB launcher shows on its cards' {
        # docs/cb-comparison.md: CB's card labels and the catalogue ids that cover them.
        $cbCards = [ordered]@{
            cod4 = @('iw3x', 'cod4x', 'iw3sp-mod')
            waw = @('plutonium'); mw2 = @('iw4x'); bo1 = @('plutonium'); mw3 = @('plutonium', 'alterware'); bo2 = @('plutonium', 't6sp-mod')
            ghosts = @('iw6x'); aw = @('s1x'); iw = @('iw7-mod'); mwr = @('h1-mod'); bo4 = @('shield'); mw2cr = @('h2-mod'); hmw = @('hmw-launcher')
        }
        foreach ($id in $cbCards.Keys) {
            $game = $catalog | Where-Object { $_.Id -eq $id }
            $game | Should -Not -BeNullOrEmpty -Because $id
            $game.Available | Should -BeTrue -Because $id
            foreach ($client in $cbCards[$id]) { @($game.Clients.Id) | Should -Contain $client -Because "CB shows it on the $id card" }
            @($game.Modes).Count | Should -BeGreaterThan 0 -Because $id
        }
    }

    It 'installs our own CodHQ BOIII build from our update site, not CB''s' {
        # Our fork's CI publishes one ZIP and boiii.json to GitHub Pages; that client is
        # the only one the BO3 card offers, pinned by the SHA-256 of the whole download.
        $bo3 = Get-CatalogGame -Id 'bo3'
        @($bo3.Clients.Id) | Should -Be @('boiii-codhq')
        $client = @($bo3.Clients)[0]
        $client.Source | Should -Be 'codhq'
        $client.Manifest | Should -Be 'boiii.json'
        $client.ManifestBase | Should -Be 'https://larkthestar.github.io/codhq-boiii/'
        [string]$client.Archive.Url | Should -Be 'https://larkthestar.github.io/codhq-boiii/codhq-boiii.zip'
        [string]$client.Archive.Sha256 | Should -Match '^[0-9A-F]{64}$'
        [string]$client.Archive.Sha256 | Should -Be ([string]$client.Archive.Sha256).ToUpperInvariant()
        [int64]$client.Archive.Size | Should -BeGreaterThan 1000000
        [int]$client.ManifestCount | Should -Be 196
        $client.Recommended | Should -BeTrue
        # Nothing of CB's is in the catalogue any more: a record an older version left
        # behind is the only thing that makes the card offer Remove for it.
        $bo3.PSObject.Properties['RetiredClients'] | Should -BeNullOrEmpty
        @(@($bo3.Modes)[0].Clients) | Should -Be @('boiii-codhq')
        [string](@($bo3.Modes)[0].Blocked) | Should -BeNullOrEmpty
        Get-ModeBlocker -Game $bo3 -Mode @($bo3.Modes)[0] -GameFolder $TestDrive | Should -Match 'needs CodHQ BOIII'
        # The executable goes into the game folder; the data tree goes to AppData\boiii,
        # where the client reads it.
        (Resolve-ClientTarget -Client $client -Path 'boiii.exe' -GameFolder $TestDrive).Dest | Should -Be 'game'
        (Resolve-ClientTarget -Client $client -Path 'data/main/zone/all_mp.ff' -GameFolder $TestDrive).Dest | Should -Be 'appdata'
        # The game executable is pinned by the PE header checksum the client compares,
        # with no CB manifest behind it.
        [int64]$bo3.ExeCheck.Checksum | Should -Be 0x6531394
        [string]::IsNullOrEmpty([string]$bo3.ExeCheck.Manifest) | Should -BeTrue
    }
    It 'takes a client published from its own site from that site only' {
        $client = New-CatalogClient -Id 'own-site' -Name 'Own site' -Source 'manifest' -Manifest 'boiii.json' -ManifestBase 'https://example.test/codhq/' -AppData 'boiii' -GameFiles @('boiii.exe') -Allow @('boiii.exe', 'data/*')
        $manifest = [pscustomobject]@{ Base = 'https://example.test/codhq/'; ManifestHash = ''; Entries = @(
            [pscustomobject]@{ Path = 'boiii.exe'; Size = 10; Sha1 = ('A' * 40); Dest = '' },
            [pscustomobject]@{ Path = 'data/main/x.txt'; Size = 4; Sha1 = ('B' * 40); Dest = '' }) }
        $plan = Get-ClientInstallPlan -Client $client -GameFolder $TestDrive -Manifest $manifest
        $plan.Base | Should -Be 'https://example.test/codhq/'
        $plan.Steps[0].Target | Should -Be (Join-Path $TestDrive 'boiii.exe')
        $plan.Steps[1].Dest | Should -Be 'appdata'
        $plan.Steps[1].Url | Should -Match '^https://example\.test/codhq/data/main/x\.txt\?B+$'
    }

    It 'names only its own clients as conflicts' {
        foreach ($game in $catalog) {
            foreach ($client in $game.Clients) { foreach ($id in @($client.Conflicts)) { @($game.Clients.Id) | Should -Contain $id -Because "$($game.Id) $($client.Id)" } }
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
        $needed = @{ 'iw4x' = 'iw4x.exe'; 'iw6x' = 'iw6x.exe'; 's1x' = 's1x.exe'; 'h1-mod' = 'h1-mod.exe'; 'iw7-mod' = 'iw7-mod.exe'; 'h2-mod' = 'h2-mod.exe'; 'cod4x' = 'mss32.dll'; 'iw3x' = 'mss32.dll'; 'iw3sp-mod' = 'iw3sp_mod.exe'; 'alterware' = 'alterware-launcher.exe' }
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
        $cod4Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod4-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod4Folder 'iw3mp.exe') -Value 'retail'
        [IO.File]::WriteAllText((Join-Path $cod4Folder 'mss32.dll'), 'original miles')
        $iw3x = (Get-CatalogGame -Id 'cod4').Clients | Where-Object Id -eq 'iw3x'
        $manifest = New-FakeManifest -Client $iw3x -Files ([ordered]@{ 'mss32.dll' = @{ Text = 'iw3x proxy'; Dest = 'game' }; 'miles32.dll' = @{ Text = 'original miles'; NotServed = $true; Dest = 'game' } })
        $result = Install-GameClient -GameId 'cod4' -ClientId 'iw3x' -GameFolder $cod4Folder -Manifest $manifest -RetryDelaySeconds 0
        $result.Derived | Should -Be 1
        Get-Text (Join-Path $cod4Folder 'miles32.dll') | Should -Be 'original miles'
        Get-Text (Join-Path $cod4Folder 'mss32.dll') | Should -Be 'iw3x proxy'
        # Installing again finds the original in the backup, although mss32.dll is now the proxy.
        $again = Install-GameClient -GameId 'cod4' -ClientId 'iw3x' -GameFolder $cod4Folder -Manifest $manifest -RetryDelaySeconds 0
        $again.Downloaded | Should -Be 0
        Remove-GameClient -GameId 'cod4' -ClientId 'iw3x' -GameFolder $cod4Folder
        Get-Text (Join-Path $cod4Folder 'mss32.dll') | Should -Be 'original miles'
        Test-Path -LiteralPath (Join-Path $cod4Folder 'miles32.dll') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod4Folder '.codhq-backups') | Should -BeFalse
    }

    It 'changes nothing when the player''s file is not the original the client needs' {
        $cod4Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod4-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod4Folder 'iw3mp.exe') -Value 'retail'
        [IO.File]::WriteAllText((Join-Path $cod4Folder 'mss32.dll'), 'some other build')
        $iw3x = (Get-CatalogGame -Id 'cod4').Clients | Where-Object Id -eq 'iw3x'
        $manifest = New-FakeManifest -Client $iw3x -Files ([ordered]@{ 'mss32.dll' = @{ Text = 'iw3x proxy'; Dest = 'game' }; 'miles32.dll' = @{ Text = 'original miles'; NotServed = $true; Dest = 'game' } })
        { Install-GameClient -GameId 'cod4' -ClientId 'iw3x' -GameFolder $cod4Folder -Manifest $manifest -RetryDelaySeconds 0 } | Should -Throw '*not the original build*'
        Get-Text (Join-Path $cod4Folder 'mss32.dll') | Should -Be 'some other build'
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod4Folder -ClientId 'iw3x') | Should -BeFalse
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

Describe 'Call of Duty 1.1 archive client' {
    BeforeEach {
        $cod1Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod1-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod1Folder 'CoDSP.exe') -Value 'retail sp'
        Set-Content -LiteralPath (Join-Path $cod1Folder 'CoDMP.exe') -Value 'retail mp'
        $global:cod1Archive = Join-Path $TestDrive ('cod1-1.1-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod1Archive -Entries ([ordered]@{ 'Call of Duty/CoDSP.exe' = '1.1 sp'; 'Call of Duty/CoDMP.exe' = '1.1 mp'; 'Call of Duty/main/pak0.pk3' = 'data' })
        # The release itself is not downloaded here: the ZIP above takes its place.
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1Archive -Destination $Destination -Force; return 0 }
        Mock Write-Host { }
        Mock Write-Progress { }
    }

    It 'is pinned to the 1.1 release this project publishes' {
        $client = (Get-CatalogGame -Id 'cod1').Clients | Where-Object Id -eq 'cod1-v11'
        $client.Extract | Should -BeTrue
        $client.Source | Should -Be 'archive'
        $client.Archive.Url | Should -Be 'https://github.com/LarkTheStar/fix-installer/releases/download/1.1/Call.of.Duty.1.1.SP.MP.zip'
        $client.Archive.Size | Should -Be 1207836351
        $client.Archive.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $game = Get-CatalogGame -Id 'cod1'
        @($game.SteamAppIds) | Should -Be @(2620)
        @($game.Modes | ForEach-Object { $_.Exe }) | Should -Be @('CoDSP.exe', 'CoDMP.exe')
    }

    It 'copies the 1.1 files in without the folder the archive wraps them in' {
        $result = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1 mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be '1.1 sp'
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be 'data'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'Call of Duty') | Should -BeFalse
        $result.Downloaded | Should -Be 3
        $record = Read-ClientRecord -GameFolder $cod1Folder -ClientId 'cod1-v11'
        $record.Source | Should -Be 'archive'
        $record.ArchiveSha256 | Should -Be ((Get-CatalogGame -Id 'cod1').Clients[0].Archive.Sha256)
        @($record.Files).Count | Should -Be 3
        @($record.Backups).Count | Should -Be 2
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11' | Should -BeTrue
        Get-GameClientUpdateCount -Client (Get-CatalogGame -Id 'cod1').Clients[0] -GameFolder $cod1Folder | Should -Be 0
    }

    It 'puts the player''s own executables back on removal and leaves nothing behind' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'main') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod1Folder '.codhq-backups') | Should -BeFalse
    }

    It 'keeps the player''s original when the same archive is installed twice' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $again = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $again.Downloaded | Should -Be 0
        @((Read-ClientRecord -GameFolder $cod1Folder -ClientId 'cod1-v11').Backups).Count | Should -Be 2
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
    }

    It 'installs into an empty folder the player picked, and the folder is detected afterwards' {
        $empty = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod1-empty-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Test-CatalogGameFolder -Game (Get-CatalogGame -Id 'cod1') -Folder $empty | Should -BeFalse
        $result = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $empty -RetryDelaySeconds 0
        $result.Downloaded | Should -Be 3
        Get-Text (Join-Path $empty 'CoDMP.exe') | Should -Be '1.1 mp'
        Get-Text (Join-Path $empty 'CoDSP.exe') | Should -Be '1.1 sp'
        Test-CatalogGameFolder -Game (Get-CatalogGame -Id 'cod1') -Folder $empty | Should -BeTrue
        @((Read-ClientRecord -GameFolder $empty -ClientId 'cod1-v11').Backups).Count | Should -Be 0
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $empty
        Test-Path -LiteralPath (Join-Path $empty 'CoDMP.exe') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $empty -ClientId 'cod1-v11') | Should -BeFalse
    }

    It 'keeps a picked empty folder as the game folder until the files are in it' {
        $empty = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod1-picked-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $game = Get-CatalogGame -Id 'cod1'
        Save-CatalogGameFolder -Id 'cod1' -Folder $empty | Should -BeTrue
        try {
            $found = Find-CatalogGame -Game $game
            $found | Should -Not -BeNullOrEmpty
            $found.Folder | Should -Be $empty
            $found.Source | Should -Be 'saved'
        } finally { $null = Save-CatalogGameFolder -Id 'cod1' -Folder '' }
        # Every other game still needs its own files before its folder is accepted.
        $game.AllowEmptyFolder | Should -BeTrue
        (Get-CatalogGame -Id 'cod4').AllowEmptyFolder | Should -BeNullOrEmpty
    }

    It 'asks before writing into a folder that is not empty and has no game files' {
        $busy = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod1-busy-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $busy 'notes.txt') -Value 'my stuff'
        Mock Read-Host { 'n' }
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $busy -RetryDelaySeconds 0 } | Should -Throw
        Get-Text (Join-Path $busy 'notes.txt') | Should -Be 'my stuff'
        Test-Path -LiteralPath (Join-Path $busy 'CoDMP.exe') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $busy -ClientId 'cod1-v11') | Should -BeFalse
        Mock Read-Host { 'y' }
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $busy -RetryDelaySeconds 0
        # The folder is emptied into the backup first, so it holds the 1.1 files only...
        Test-Path -LiteralPath (Join-Path $busy 'notes.txt') | Should -BeFalse
        Get-Text (Join-Path $busy 'CoDMP.exe') | Should -Be '1.1 mp'
        Get-Text (Join-Path $busy 'CoDSP.exe') | Should -Be '1.1 sp'
        # ...and Remove gives the player's own file back.
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $busy
        Get-Text (Join-Path $busy 'notes.txt') | Should -Be 'my stuff'
    }

    It 'empties the folder except the two executables, then puts everything back on removal' {
        Set-Content -LiteralPath (Join-Path $cod1Folder 'steam_api.dll') -Value 'steam'
        $null = New-Item -ItemType Directory -Path (Join-Path $cod1Folder 'main') -Force
        Set-Content -LiteralPath (Join-Path $cod1Folder 'main\pak0.pk3') -Value 'old data'
        $null = New-Item -ItemType Directory -Path (Join-Path $cod1Folder 'Docs') -Force
        Set-Content -LiteralPath (Join-Path $cod1Folder 'Docs\readme.txt') -Value 'docs'
        Remove-Item -LiteralPath $global:cod1Archive -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $global:cod1Archive -Entries ([ordered]@{ 'CoDSP.exe' = '1.1 sp'; 'CoDMP.exe' = '1.1 mp'; 'main\pak0.pk3' = '1.1 data'; 'main\pak1.pk3' = '1.1 extra' })
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        # Nothing but the archive's own files is left in the folder: no old file to clash.
        Test-Path -LiteralPath (Join-Path $cod1Folder 'steam_api.dll') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod1Folder 'Docs') | Should -BeFalse
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be '1.1 data'
        Get-Text (Join-Path $cod1Folder 'main\pak1.pk3') | Should -Be '1.1 extra'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be '1.1 sp'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1 mp'
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'steam_api.dll') | Should -Be 'steam'
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be 'old data'
        Get-Text (Join-Path $cod1Folder 'Docs\readme.txt') | Should -Be 'docs'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'main\pak1.pk3') | Should -BeFalse
    }

    It 'keeps the installer''s own records and backups when it empties the folder' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $cod1Folder '.codhq-backups') | Should -BeTrue
        # Installing again must not move the record or the backup out of the folder.
        Remove-Item -LiteralPath (Join-Path $cod1Folder 'main\pak0.pk3') -Force
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be 'data'
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
    }

    It 'takes 1.1X with it when 1.1 is removed, and puts every original file back' {
        Set-Content -LiteralPath (Join-Path $cod1Folder 'steam_api.dll') -Value 'steam'
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $global:cod1xArchive = Join-Path $TestDrive ('cod1x-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod1xArchive -Entries ([ordered]@{ 'CoDMP.exe' = '1.1x mp'; 'cod1x.dll' = 'patch'; 'CoDMP_old.exe' = '1.1 old'; 'CoDExtended_Uninstall.vbs' = 'vbs' })
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1xArchive -Destination $Destination -Force; return 0 }
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1x mp'
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11x' | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11x') | Should -BeFalse
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
        Get-Text (Join-Path $cod1Folder 'steam_api.dll') | Should -Be 'steam'
        foreach ($gone in 'cod1x.dll', 'CoDMP_old.exe', 'CoDExtended_Uninstall.vbs', 'main') {
            Test-Path -LiteralPath (Join-Path $cod1Folder $gone) | Should -BeFalse -Because $gone
        }
        Test-Path -LiteralPath (Join-Path $cod1Folder '.codhq-backups') | Should -BeFalse
    }

    It 'leaves 1.1X in place when the 1.1 download fails' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $global:cod1xArchive = Join-Path $TestDrive ('cod1x-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod1xArchive -Entries ([ordered]@{ 'CoDMP.exe' = '1.1x mp'; 'cod1x.dll' = 'patch' })
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1xArchive -Destination $Destination -Force; return 0 }
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod1Folder 'cod1x.dll') | Should -Be 'patch'
        Mock Invoke-ResumableDownload { throw 'The download failed.' }
        # A file is missing, so 1.1 is installed again instead of reported as up to date.
        Remove-Item -LiteralPath (Join-Path $cod1Folder 'main\pak0.pk3') -Force
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw
        # The patch is still there: it is only taken away once the archive is verified.
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11x' | Should -BeTrue
        Get-Text (Join-Path $cod1Folder 'cod1x.dll') | Should -Be 'patch'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1x mp'
    }

    It 'puts every moved-aside file back when the extraction fails part-way' {
        Set-Content -LiteralPath (Join-Path $cod1Folder 'steam_api.dll') -Value 'steam'
        $null = New-Item -ItemType Directory -Path (Join-Path $cod1Folder 'main') -Force
        Set-Content -LiteralPath (Join-Path $cod1Folder 'main\pak0.pk3') -Value 'old data'
        $null = New-Item -ItemType Directory -Path (Join-Path $cod1Folder 'Docs') -Force
        Set-Content -LiteralPath (Join-Path $cod1Folder 'Docs\readme.txt') -Value 'docs'
        # The archive writes a file called 'main' and then a file inside 'main': the second
        # one cannot be extracted, so the install stops half-way through.
        Remove-Item -LiteralPath $global:cod1Archive -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $global:cod1Archive -Entries ([ordered]@{ 'CoDSP.exe' = '1.1 sp'; 'main' = 'not a folder'; 'main\pak0.pk3' = '1.1 data' })
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw
        # Every file the clean install moved aside is back where it was...
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'steam_api.dll') | Should -Be 'steam'
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be 'old data'
        Get-Text (Join-Path $cod1Folder 'Docs\readme.txt') | Should -Be 'docs'
        (Get-Item -LiteralPath (Join-Path $cod1Folder 'main')).PSIsContainer | Should -BeTrue
        # ...and nothing of the half-done install is left.
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod1Folder '.codhq-backups') | Should -BeFalse
    }

    It 'takes 1.1X away when 1.1 is installed again over it' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $global:cod1xArchive2 = Join-Path $TestDrive ('cod1x-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod1xArchive2 -Entries ([ordered]@{ 'CoDMP.exe' = '1.1x mp'; 'cod1x.dll' = 'patch' })
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1xArchive2 -Destination $Destination -Force; return 0 }
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Test-Path -LiteralPath (Join-Path $cod1Folder 'cod1x.dll') | Should -BeTrue
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1Archive -Destination $Destination -Force; return 0 }
        # A file is missing, so 1.1 is installed again instead of reported as up to date.
        Remove-Item -LiteralPath (Join-Path $cod1Folder 'main\pak0.pk3') -Force
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11x' | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod1Folder 'cod1x.dll') | Should -BeFalse
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1 mp'
    }

    It 'fails with a clear message and changes nothing when the archive has no game executables' {
        Remove-Item -LiteralPath $global:cod1Archive -Force -ErrorAction SilentlyContinue
        New-TestZip -Path $global:cod1Archive -Entries ([ordered]@{ 'Call of Duty/main/pak0.pk3' = 'data' })
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw '*did not put CoDSP.exe and CoDMP.exe*'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'main') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11') | Should -BeFalse
    }

    It 'keeps the player''s own files across a second install of a different archive' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $second = (Get-CatalogGame -Id 'cod1').Clients[0].PSObject.Copy()
        $second.Archive = @{ Url = 'https://example.com/changed.zip'; Size = 1; Sha256 = ('C' * 64) }
        $null = Install-GameClientArchive -Game (Get-CatalogGame -Id 'cod1') -Client $second -GameFolder $cod1Folder -RetryDelaySeconds 0
        @((Read-ClientRecord -GameFolder $cod1Folder -ClientId 'cod1-v11').Backups).Count | Should -Be 2
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be 'retail sp'
    }

    It 'reports a different archive as an update' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $newer = (Get-CatalogGame -Id 'cod1').Clients[0].PSObject.Copy()
        $newer.Archive = @{ Url = 'https://example.com/Call.of.Duty.1.2.zip'; Size = 1; Sha256 = ('B' * 64) }
        Get-GameClientUpdateCount -Client $newer -GameFolder $cod1Folder | Should -Be 1
    }

    It 'changes nothing when the archive cannot be read' {
        Set-Content -LiteralPath $global:cod1Archive -Value 'not a zip'
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'main') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11') | Should -BeFalse
    }

    It 'pins 1.1X to this project''s release and puts it after 1.1' {
        $game = Get-CatalogGame -Id 'cod1'
        @($game.Clients | ForEach-Object { $_.Id }) | Should -Be @('cod1-v11', 'cod1-v11x')
        $client = $game.Clients[1]
        $client.Source | Should -Be 'archive'
        $client.Extract | Should -BeTrue
        $client.Archive.Url | Should -Be 'https://github.com/LarkTheStar/fix-installer/releases/download/1.1/CoD1x_Archive.zip'
        $client.Archive.Size | Should -Be 2067295
        $client.Archive.Sha256 | Should -Be 'c2b31367dfbe418b1415c4ab8183fb51e6e2baadc70870d405fbba85ff19814d'
        @($client.Requires) | Should -Be @('cod1-v11')
        # The patch ships CoDMP.exe and cod1x.dll, not the whole game: it is checked for
        # its own files only.
        @($client.RequiredFiles) | Should -Be @('CoDMP.exe', 'cod1x.dll')
    }

    It 'refuses 1.1X until 1.1 is installed' {
        { Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw '*goes on top of 1.1 (singleplayer and MP)*'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be 'retail mp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'cod1x.dll') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod1Folder -ClientId 'cod1-v11x') | Should -BeFalse
    }

    It 'installs 1.1X on top of 1.1 and puts 1.1 back on removal' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $global:cod1xArchive = Join-Path $TestDrive ('cod1x-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod1xArchive -Entries ([ordered]@{ 'CoDMP.exe' = '1.1x mp'; 'cod1x.dll' = 'patch' })
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:cod1xArchive -Destination $Destination -Force; return 0 }
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1x mp'
        Get-Text (Join-Path $cod1Folder 'cod1x.dll') | Should -Be 'patch'
        # 1.1X replaces the multiplayer executable only; 1.1's own files are left alone.
        Get-Text (Join-Path $cod1Folder 'CoDSP.exe') | Should -Be '1.1 sp'
        Get-Text (Join-Path $cod1Folder 'main\pak0.pk3') | Should -Be 'data'
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11' | Should -BeTrue
        Test-GameClientInstalled -GameFolder $cod1Folder -ClientId 'cod1-v11x' | Should -BeTrue
        Remove-GameClient -GameId 'cod1' -ClientId 'cod1-v11x' -GameFolder $cod1Folder
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1 mp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'cod1x.dll') | Should -BeFalse
    }

    It 'fails 1.1X with a clear message when the patch does not ship its executable' {
        $null = Install-GameClient -GameId 'cod1' -ClientId 'cod1-v11' -GameFolder $cod1Folder -RetryDelaySeconds 0
        $wrong = (Get-CatalogGame -Id 'cod1').Clients[1].PSObject.Copy()
        $wrong.Archive = @{ Url = 'https://example.com/wrong.zip'; Size = 1; Sha256 = ('D' * 64) }
        Remove-Item -LiteralPath $global:cod1Archive -Force -ErrorAction SilentlyContinue
        $global:wrongPatch = Join-Path $TestDrive ('cod1x-wrong-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:wrongPatch -Entries ([ordered]@{ 'cod1x.dll' = 'patch' })
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $global:wrongPatch -Destination $Destination -Force; return 0 }
        { Install-GameClientArchive -Game (Get-CatalogGame -Id 'cod1') -Client $wrong -GameFolder $cod1Folder -RetryDelaySeconds 0 } | Should -Throw '*did not put CoDMP.exe*'
        Get-Text (Join-Path $cod1Folder 'CoDMP.exe') | Should -Be '1.1 mp'
        Test-Path -LiteralPath (Join-Path $cod1Folder 'cod1x.dll') | Should -BeFalse
    }
}

Describe 'Call of Duty 2 patches' {
    BeforeEach {
        $cod2Folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('cod2-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $cod2Folder 'CoD2SP_s.exe') -Value 'retail sp'
        Set-Content -LiteralPath (Join-Path $cod2Folder 'CoD2MP_s.exe') -Value 'retail mp'
        Set-Content -LiteralPath (Join-Path $cod2Folder 'mss32.dll') -Value 'retail miles'
        # The custom patch's ZIP: its steam folder is the one this build uses. The retail
        # folder and Info.txt belong to another build and must stay in the ZIP.
        $global:cod2PatchZip = Join-Path $TestDrive ('cod2-v2-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod2PatchZip -Entries ([ordered]@{
            'CoD2_CustomPatchv2/Info.txt' = 'info'
            'CoD2_CustomPatchv2/retail/cod2patch.ini' = 'retail ini'
            'CoD2_CustomPatchv2/retail/winmm.dll' = 'retail dll'
            'CoD2_CustomPatchv2/steam/cod2patch.ini' = 'steam ini'
            'CoD2_CustomPatchv2/steam/steam.dll' = 'steam dll' })
        $global:cod2xZip = Join-Path $TestDrive ('cod2x-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:cod2xZip -Entries ([ordered]@{
            'CoD2x Installation and uninstallation manual.txt' = 'manual'
            'mss32.dll' = 'cod2x miles'
            'mss32_original.dll' = 'retail miles' })
        Mock Invoke-ResumableDownload {
            if ($Url -like '*CoD2x*') { Copy-Item -LiteralPath $global:cod2xZip -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:cod2PatchZip -Destination $Destination -Force; return 0
        }
        Mock Write-Host { }
        Mock Write-Progress { }
    }

    It 'pins both patches, CoD2x on top of the custom patch' {
        $game = Get-CatalogGame -Id 'cod2'
        @($game.Clients | ForEach-Object { $_.Id }) | Should -Be @('cod2-v2', 'cod2x')
        $patch = $game.Clients[0]
        $patch.Source | Should -Be 'archive'
        $patch.Extract | Should -BeTrue
        $patch.Archive.Url | Should -Be 'https://github.com/LarkTheStar/fix-installer/releases/download/cod2/CoD2_CustomPatchv2.zip'
        $patch.Archive.Size | Should -Be 108810
        $patch.Archive.Sha256 | Should -Be '6afdb9ce6072ffbbe682282a13026bc72012331f0dafde1bc62a37b2cbc96ddd'
        @($patch.ArchiveItems | ForEach-Object { "$($_.From)>$($_.To)" }) | Should -Be @('steam/steam.dll>steam.dll', 'steam/cod2patch.ini>cod2patch.ini')
        @($patch.RequiredFiles) | Should -Be @('steam.dll', 'cod2patch.ini')
        $cod2x = $game.Clients[1]
        $cod2x.Archive.Url | Should -Be 'https://github.com/callofduty2x/CoD2x/releases/download/v1.4.6.8/CoD2x_1.4.6.8_windows.zip'
        $cod2x.Archive.Size | Should -Be 2577745
        $cod2x.Archive.Sha256 | Should -Be 'c33f52037e67eaa948746a93967d27d8c70ab58623abab48d07803600a6a8555'
        @($cod2x.ArchiveItems | ForEach-Object { $_.To }) | Should -Be @('mss32.dll', 'mss32_original.dll')
        @($cod2x.Requires) | Should -Be @('cod2-v2')
        # The card recommends CoD2x, the layer worth adding, not the required patch.
        $cod2x.Recommended | Should -BeTrue
        $patch.Recommended | Should -BeFalse
        # Every mode plays with the custom patch alone: CoD2x only enhances it, so no Play
        # button waits for it.
        foreach ($mode in $game.Modes) { @($mode.Clients) | Should -Be @('cod2-v2') }
    }

    It 'copies only the two items of the patch''s steam folder into the game folder' {
        $result = Install-GameClient -GameId 'cod2' -ClientId 'cod2-v2' -GameFolder $cod2Folder -RetryDelaySeconds 0
        $result.Downloaded | Should -Be 2
        Get-Text (Join-Path $cod2Folder 'steam.dll') | Should -Be 'steam dll'
        Get-Text (Join-Path $cod2Folder 'cod2patch.ini') | Should -Be 'steam ini'
        # Nothing of the retail folder, of Info.txt or of the archive's own folder.
        foreach ($kept in 'winmm.dll', 'Info.txt', 'retail', 'CoD2_CustomPatchv2') {
            Test-Path -LiteralPath (Join-Path $cod2Folder $kept) | Should -BeFalse -Because $kept
        }
        @((Read-ClientRecord -GameFolder $cod2Folder -ClientId 'cod2-v2').Files).Count | Should -Be 2
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'retail miles'
    }

    It 'lets both modes play with the custom patch alone, without CoD2x' {
        $game = Get-CatalogGame -Id 'cod2'
        # The patch is the one requirement: both Play buttons wait only for it.
        foreach ($mode in $game.Modes) { Get-ModeBlocker -Game $game -Mode $mode -GameFolder $cod2Folder | Should -BeLike '*needs Custom patch v2*' }
        $null = Install-GameClient -GameId 'cod2' -ClientId 'cod2-v2' -GameFolder $cod2Folder -RetryDelaySeconds 0
        # CoD2x enhances the patch; neither mode needs it to start.
        foreach ($mode in $game.Modes) {
            Get-ModeBlocker -Game $game -Mode $mode -GameFolder $cod2Folder | Should -Be '' -Because "$($mode.Label) plays with the custom patch alone"
            Test-Path -LiteralPath (Join-Path $cod2Folder $mode.Exe) -PathType Leaf | Should -BeTrue -Because $mode.Exe
        }
        Test-Path -LiteralPath (Join-Path $cod2Folder 'mss32_original.dll') | Should -BeFalse
    }

    It 'refuses CoD2x until the custom patch is installed' {
        { Install-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder -RetryDelaySeconds 0 } | Should -Throw '*goes on top of Custom patch v2*'
        Test-Path -LiteralPath (Join-Path $cod2Folder 'mss32_original.dll') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod2Folder -ClientId 'cod2x') | Should -BeFalse
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'retail miles'
    }

    It 'installs CoD2x over the patch and puts the retail Miles library back on removal' {
        $null = Install-GameClient -GameId 'cod2' -ClientId 'cod2-v2' -GameFolder $cod2Folder -RetryDelaySeconds 0
        $null = Install-GameClient -GameId 'cod2' -ClientId 'cod2x' -GameFolder $cod2Folder -RetryDelaySeconds 0
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'cod2x miles'
        Get-Text (Join-Path $cod2Folder 'mss32_original.dll') | Should -Be 'retail miles'
        # The manual in the ZIP is not installed.
        Test-Path -LiteralPath (Join-Path $cod2Folder 'CoD2x Installation and uninstallation manual.txt') | Should -BeFalse
        Get-Text (Join-Path $cod2Folder 'steam.dll') | Should -Be 'steam dll'
        # Removing the patch takes CoD2x with it: the retail library comes back and the
        # game's own executables are untouched.
        Remove-GameClient -GameId 'cod2' -ClientId 'cod2-v2' -GameFolder $cod2Folder
        Get-Text (Join-Path $cod2Folder 'mss32.dll') | Should -Be 'retail miles'
        foreach ($gone in 'mss32_original.dll', 'steam.dll', 'cod2patch.ini') {
            Test-Path -LiteralPath (Join-Path $cod2Folder $gone) | Should -BeFalse -Because $gone
        }
        Get-Text (Join-Path $cod2Folder 'CoD2SP_s.exe') | Should -Be 'retail sp'
        Get-Text (Join-Path $cod2Folder 'CoD2MP_s.exe') | Should -Be 'retail mp'
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod2Folder -ClientId 'cod2x') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod2Folder '.codhq-backups') | Should -BeFalse
    }

    It 'changes nothing when the ZIP holds no steam files' {
        $wrong = (Get-CatalogGame -Id 'cod2').Clients[0].PSObject.Copy()
        $wrong.Archive = @{ Url = 'https://example.com/CoD2_CustomPatchv3.zip'; Size = 1; Sha256 = ('E' * 64) }
        Remove-Item -LiteralPath $global:cod2PatchZip -Force
        New-TestZip -Path $global:cod2PatchZip -Entries ([ordered]@{ 'CoD2_CustomPatchv3/retail/winmm.dll' = 'retail dll' })
        { Install-GameClientArchive -Game (Get-CatalogGame -Id 'cod2') -Client $wrong -GameFolder $cod2Folder -RetryDelaySeconds 0 } | Should -Throw '*did not put steam.dll and cod2patch.ini*'
        Test-Path -LiteralPath (Join-Path $cod2Folder 'steam.dll') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cod2Folder 'winmm.dll') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $cod2Folder -ClientId 'cod2-v2') | Should -BeFalse
    }
}

Describe 'United Offensive folder install' {
    BeforeEach {
        $SettingsDirectory = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N'))
        $SettingsFile = Join-Path $SettingsDirectory 'settings.json'
        # A Steam library that happens to hold United Offensive files must not be picked up:
        # the game is only the folder the player chooses.
        $library = Join-Path $TestDrive ('library-' + [guid]::NewGuid().ToString('N'))
        $uo = Join-Path $library 'steamapps\common\Call of Duty United Offensive'
        $null = New-Item -ItemType Directory -Path $uo -Force
        Set-Content -LiteralPath (Join-Path $uo 'CoDUOSP.exe') -Value 'fake'
        Set-Content -LiteralPath (Join-Path $uo 'CoDUOMP.exe') -Value 'fake'
        # The page the client's site shows: the key stands next to the game's name and a new
        # one is printed for every request. Only the CODUO one is read out of it.
        $global:uoKeyPage = Join-Path $TestDrive ('uo-key-page-' + [guid]::NewGuid().ToString('N') + '.html')
        Set-Content -LiteralPath $global:uoKeyPage -Value @(
            '<html><body><table>'
            '<tr><td>COD1</td><td><a href="downloads.php?get=codkey">key</a></td><td>ABCD-1234-EFGH-5678-IJKL</td></tr>'
            '<tr><td><b>CODUO</b></td><td><a href="downloads.php?get=coduokey">key</a></td><td>3G1K-HWJQ-TWUG-QAHW-8901</td></tr>'
            '</table></body></html>')
        Mock Get-SteamLibraries { @($library) }
        Mock Write-Host { }
    }

    It 'never looks for it in Steam' {
        $game = Get-CatalogGame -Id 'coduo'
        @($game.SteamAppIds).Count | Should -Be 0
        $game.Detect | Should -Be 'none'
        Find-CatalogGame -Game $game | Should -BeNullOrEmpty
    }

    It 'takes the folder the player picked, even an empty one' {
        $game = Get-CatalogGame -Id 'coduo'
        $game.AllowEmptyFolder | Should -BeTrue
        $picked = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-picked-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Save-CatalogGameFolder -Id 'coduo' -Folder $picked | Should -BeTrue
        try {
            $found = Find-CatalogGame -Game $game
            $found | Should -Not -BeNullOrEmpty
            $found.Folder | Should -Be $picked
            $found.Source | Should -Be 'saved'
        } finally { $null = Save-CatalogGameFolder -Id 'coduo' -Folder '' }
    }

    It 'is pinned to the 1.5 game and the United Offensive 1.5 archives, then the two server keys' {
        $client = (Get-CatalogGame -Id 'coduo').Clients | Where-Object Id -eq 'uo-15'
        $client | Should -Not -BeNullOrEmpty
        $client.Extract | Should -BeTrue
        $client.Source | Should -Be 'archive'
        @($client.Archives | ForEach-Object { [IO.Path]::GetFileName(([uri]$_.Url).AbsolutePath) }) | Should -Be @('Call.of.Duty.1.5.zip', 'Call.of.Duty.-.UO.1.5.zip')
        @($client.Archives | ForEach-Object { $_.Sha256 }) | Should -Be @('a2f94fa95394d64fee4abb527d3d2e2ad7bfc680b2ee335bc22f6e55666d08cb', '09c84a605242fc96801dd018901af6ac09b59319bddecbd83fab7655a0a0c014')
        # The two safety systems of the client's servers: their own .reg each, and the key
        # each one takes.
        @($client.ServerKey).Count | Should -Be 2
        $client.ServerKey[0].RegUrl | Should -Match '^https://de\.dvotx\.org/'
        $client.ServerKey[0].KeyUrl | Should -Match '^https://de\.dvotx\.org/'
        $client.ServerKey[0].ValueName | Should -Be 'codkey'
        # The values each .reg has to carry for the game to read them.
        $client.ServerKey[0].Version | Should -Be '1.5'
        $client.ServerKey[0].PathEndsWithBackslash | Should -BeTrue
        [bool]$client.ServerKey[0].DriveWithBackslash | Should -BeFalse
        $client.ServerKey[1].RegUrl | Should -Be 'https://de.dvotx.org/dump/cod1/coduo1.51.reg'
        # Its key is not fixed: the site prints a new one for every request, so each player
        # gets a key of their own from the page, next to the name CODUO.
        $client.ServerKey[1].KeyPageUrl | Should -Be 'https://de.dvotx.org/dump/cod1/downloads.php'
        $client.ServerKey[1].KeyLabel | Should -Be 'CODUO'
        [string]::IsNullOrWhiteSpace([string]$client.ServerKey[1].Key) | Should -BeTrue
        $client.ServerKey[1].ValueName | Should -Be 'key'
        $client.ServerKey[1].Version | Should -Be '1.51'
        $client.ServerKey[1].DriveWithBackslash | Should -BeTrue
        # The key file is the first key's route; the second one has the page.
        [string]::IsNullOrWhiteSpace([string]$client.ServerKey[1].KeyUrl) | Should -BeTrue
        @($client.ServerKey | ForEach-Object { $_.Folder }) | Should -Be @('key', 'key')
        $game = Get-CatalogGame -Id 'coduo'
        $game.RequireEmptyFolder | Should -BeTrue
        @($game.Modes | ForEach-Object { $_.Exe }) | Should -Be @('CoDUOSP.exe', 'CoDUOMP.exe')
        @($game.Modes | ForEach-Object { $_.Label }) | Should -Be @('Singleplayer', 'Multiplayer')
        # Nothing is put on the command line: United Offensive stops at its own "Out of
        # memory error" dialog when it is handed the memory settings.
        $game.DefaultArguments | Should -Be ''
    }

    It 'refuses a folder that is not empty before downloading anything' {
        $busy = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-busy-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $busy 'notes.txt') -Value 'my stuff'
        Mock Invoke-ResumableDownload { throw 'Nothing may be downloaded.' }
        { Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $busy -RetryDelaySeconds 0 } | Should -Throw '*empty folder*'
        Should -Invoke Invoke-ResumableDownload -Times 0 -Exactly
        Get-Text (Join-Path $busy 'notes.txt') | Should -Be 'my stuff'
    }

    It 'copies the 1.5 game in, then United Offensive over it, and sets up both server keys' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $global:uoGame = Join-Path $TestDrive ('uo-game-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:uoGame -Entries ([ordered]@{ 'CoDUOSP.exe' = '1.5 sp'; 'CoDUOMP.exe' = '1.5 mp'; 'main/pak0.pk3' = '1.5 data'; 'main/pak1.pk3' = '1.5 extra' })
        $global:uoUo = Join-Path $TestDrive ('uo-uo-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:uoUo -Entries ([ordered]@{ 'CoDUOSP.exe' = 'uo sp'; 'CoDUOMP.exe' = 'uo mp'; 'main/pak0.pk3' = 'uo data'; 'uo/uo1.pk3' = 'uo extra' })
        $global:uoReg = Join-Path $TestDrive ('server-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:uoReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"'
            '"InstallPath"="C:\\Games\\Call of Duty"'
            '"InstallDrive"="C:"'
            '"Version"="1.1"')
        $global:uoSecondReg = Join-Path $TestDrive ('server-uo-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:uoSecondReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="PUT-THE-KEY-HERE"'
            '"InstallPath"="C:\\Program Files (x86)\\Activision\\Call of Duty United Offensive"'
            '"InstallDrive"="C:"'
            '"Version"="1.51"')
        $global:uoKey = Join-Path $TestDrive ('codkey-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $global:uoKey -Value 'ABCD1234EFGH5678IJKL'
        Mock Invoke-ResumableDownload {
            if ($Url -like '*get=codkey*') { Copy-Item -LiteralPath $global:uoKey -Destination $Destination -Force; return 0 }
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:uoSecondReg -Destination $Destination -Force; return 0 }
            if ($Url -like '*.reg') { Copy-Item -LiteralPath $global:uoReg -Destination $Destination -Force; return 0 }
            if ($Url -like '*UO.1.5.zip') { Copy-Item -LiteralPath $global:uoUo -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:uoGame -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $false } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $result = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        $result.KeyInstalled | Should -BeTrue
        # The United Offensive archive is copied over the 1.5 game's own files.
        Get-Text (Join-Path $folder 'CoDUOSP.exe') | Should -Be 'uo sp'
        Get-Text (Join-Path $folder 'CoDUOMP.exe') | Should -Be 'uo mp'
        Get-Text (Join-Path $folder 'main\pak0.pk3') | Should -Be 'uo data'
        Get-Text (Join-Path $folder 'main\pak1.pk3') | Should -Be '1.5 extra'
        Get-Text (Join-Path $folder 'uo\uo1.pk3') | Should -Be 'uo extra'
        # The 1.5 game's own copy of a file the second archive replaced is not kept as if it
        # were the player's.
        $record = Read-ClientRecord -GameFolder $folder -ClientId 'uo-15'
        @($record.Backups).Count | Should -Be 0
        @($record.Files).Count | Should -Be 5
        # The first key is saved where the player can find it, and both registry files got
        # the key, the path, the drive and the version the game reads, quotes and all.
        Test-Path -LiteralPath (Join-Path $folder 'key\codkey.txt') | Should -BeTrue
        $escaped = [regex]::Escape($folder.TrimEnd('\').Replace('\', '\\'))
        # cod1.1_(x64).reg: the path ends in a backslash, the drive is the letter alone.
        $driveLetter = [regex]::Escape([IO.Path]::GetPathRoot($folder).TrimEnd('\'))
        # coduo1.51.reg: no trailing backslash, the drive is a root ("D:\\").
        $driveRoot = [regex]::Escape([IO.Path]::GetPathRoot($folder).TrimEnd('\').Replace('\', '\\') + '\\')
        $reg = Get-Content -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') -Raw
        $reg | Should -Match '"codkey"="ABCD1234EFGH5678IJKL"'
        $reg | Should -Match ('"InstallPath"="' + $escaped + '\\\\"')
        $reg | Should -Match ('"InstallDrive"="' + $driveLetter + '"')
        # The published file still names 1.1; this client installs 1.5.
        $reg | Should -Match '"Version"="1\.5"'
        $reg | Should -Not -Match '"Version"="1\.1"'
        # The second key is the one the page printed next to CODUO.
        $second = Get-Content -LiteralPath (Join-Path $folder 'key\codhq-uo-server-key.reg') -Raw
        $second | Should -Match '"key"="3G1KHWJQTWUGQAHW8901"'
        $second | Should -Match ('"InstallPath"="' + $escaped + '"')
        $second | Should -Match ('"InstallDrive"="' + $driveRoot + '"')
        $second | Should -Match '"Version"="1\.51"'
        Get-Text (Join-Path $folder 'key\coduo-key.txt') | Should -Be '3G1KHWJQTWUGQAHW8901'
        # Both .reg files are also kept exactly as the site published them.
        Test-Path -LiteralPath (Join-Path $folder 'key\cod1.1_(x64).reg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\coduo1.51.reg') | Should -BeTrue
        Should -Invoke Import-ServerKeyRegFile -Times 2 -Exactly
        # Both executables are in place, so the card is ready.
        Test-CatalogGameFolder -Game (Get-CatalogGame -Id 'coduo') -Folder $folder | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'CoDUOSP.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'CoDUOMP.exe') | Should -BeTrue
        # Remove takes the install and the key folder with it.
        Remove-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder
        # Removing the key added two more editor questions: each remove.reg asks for the
        # values of the filled in file it belongs to to be deleted.
        Should -Invoke Import-ServerKeyRegFile -Times 4 -Exactly
        Test-Path -LiteralPath (Join-Path $folder 'CoDUOSP.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $folder 'uo') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $folder 'key') | Should -BeFalse
        Test-Path -LiteralPath (Get-ClientRecordPath -GameFolder $folder -ClientId 'uo-15') | Should -BeFalse
    }

    It 'keeps the registry file in key\ when the key cannot be read out of it' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-bad-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $global:badGame = Join-Path $TestDrive ('uo-game-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:badGame -Entries ([ordered]@{ 'CoDUOSP.exe' = 'sp'; 'CoDUOMP.exe' = 'mp' })
        $global:badReg = Join-Path $TestDrive ('server-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:badReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"')
        $global:badSecondReg = Join-Path $TestDrive ('server-uo-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:badSecondReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="PUT-THE-KEY-HERE"')
        # A page that holds no key that can be read out of it.
        $global:badKey = Join-Path $TestDrive ('codkey-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $global:badKey -Value 'no key in here'
        Mock Invoke-ResumableDownload {
            if ($Url -like '*get=codkey*') { Copy-Item -LiteralPath $global:badKey -Destination $Destination -Force; return 0 }
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:badSecondReg -Destination $Destination -Force; return 0 }
            if ($Url -like '*.reg') { Copy-Item -LiteralPath $global:badReg -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:badGame -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $false } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $result = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        # The game files are installed all the same.
        Get-Text (Join-Path $folder 'CoDUOSP.exe') | Should -Be 'sp'
        $result.KeyInstalled | Should -BeFalse
        # The key page and the registry file it goes in stay in key\ for the player...
        Test-Path -LiteralPath (Join-Path $folder 'key\codkey.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\cod1.1_(x64).reg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') | Should -BeTrue
        # The copy carries the path, the drive and the version even though the published
        # file only had the key line: the registry editor needs all of them.
        $copy = Get-Content -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') -Raw
        $copy | Should -Match '"InstallPath"='
        $copy | Should -Match '"InstallDrive"='
        $copy | Should -Match '"Version"="1\.5"'
        # ...and the second key, which needs no download, is set up anyway.
        $second = Get-Content -LiteralPath (Join-Path $folder 'key\codhq-uo-server-key.reg') -Raw
        $second | Should -Match '"key"="3G1KHWJQTWUGQAHW8901"'
        Get-Text (Join-Path $folder 'key\coduo-key.txt') | Should -Be '3G1KHWJQTWUGQAHW8901'
        Should -Invoke Import-ServerKeyRegFile -Times 1 -Exactly
    }

    It 'does not report the key as set up when the registry did not take the values' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-nomerge-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $global:nomergeGame = Join-Path $TestDrive ('uo-game-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:nomergeGame -Entries ([ordered]@{ 'CoDUOSP.exe' = 'sp'; 'CoDUOMP.exe' = 'mp' })
        $global:nomergeKey = Join-Path $TestDrive ('codkey-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $global:nomergeKey -Value 'ABCD1234EFGH5678IJKL'
        $global:nomergeReg = Join-Path $TestDrive ('server-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:nomergeReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"')
        $global:nomergeSecond = Join-Path $TestDrive ('server-uo-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:nomergeSecond -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="PUT-THE-KEY-HERE"')
        Mock Invoke-ResumableDownload {
            if ($Url -like '*get=codkey*') { Copy-Item -LiteralPath $global:nomergeKey -Destination $Destination -Force; return 0 }
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:nomergeSecond -Destination $Destination -Force; return 0 }
            if ($Url -like '*.reg') { Copy-Item -LiteralPath $global:nomergeReg -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:nomergeGame -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $true } }
        # The editor closed without the values reaching the registry: the player clicked No,
        # or the question never came up.
        Mock Test-ServerKeyRegInRegistry { $false }
        $result = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        $result.KeyInstalled | Should -BeFalse
        # The game files are installed and both files are in key\ for the player to
        # double-click.
        Get-Text (Join-Path $folder 'CoDUOSP.exe') | Should -Be 'sp'
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-uo-server-key.reg') | Should -BeTrue
        Should -Invoke Import-ServerKeyRegFile -Times 2 -Exactly
    }

    It 'says the key was not added when the administrator prompt is cancelled' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-cancel-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $reg = Join-Path $TestDrive ('cancel-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $reg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"')
        Mock Invoke-ResumableDownload { Copy-Item -LiteralPath $reg -Destination $Destination -Force; return 0 }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 70; Output = 'The operation was canceled by the user.'; Prompted = $true; Cancelled = $true } }
        Mock Test-ServerKeyRegInRegistry { $false }
        Mock Write-Warn { }
        $spec = @{ Name = 'Call of Duty 1.5'; RegUrl = 'https://example.test/cod1.1_(x64).reg'; Key = 'ABCD1234EFGH5678IJKL'
            ValueName = 'codkey'; KeyFileName = 'codkey.txt'; CopyName = 'codhq-server-key.reg'; Folder = 'key'
            Version = '1.5'; PathEndsWithBackslash = $true }
        Install-ServerKeyReg -Spec $spec -GameFolder $folder -RetryDelaySeconds 0 | Should -BeFalse
        Should -Invoke Import-ServerKeyRegFile -Times 1 -Exactly
        # The player is told what happened, and the file stays where they can double-click it.
        Should -Invoke Write-Warn -ParameterFilter { $Message -like '*was cancelled*' }
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') | Should -BeTrue
    }

    It 'looks the registry up again on the next install of an installed client' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-relook-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $global:relookGame = Join-Path $TestDrive ('uo-game-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:relookGame -Entries ([ordered]@{ 'CoDUOSP.exe' = 'sp'; 'CoDUOMP.exe' = 'mp' })
        $global:relookKey = Join-Path $TestDrive ('codkey-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $global:relookKey -Value 'ABCD1234EFGH5678IJKL'
        $global:relookReg = Join-Path $TestDrive ('server-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:relookReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"')
        $global:relookSecond = Join-Path $TestDrive ('server-uo-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:relookSecond -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="PUT-THE-KEY-HERE"')
        Mock Invoke-ResumableDownload {
            if ($Url -like '*get=codkey*') { Copy-Item -LiteralPath $global:relookKey -Destination $Destination -Force; return 0 }
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:relookSecond -Destination $Destination -Force; return 0 }
            if ($Url -like '*.reg') { Copy-Item -LiteralPath $global:relookReg -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:relookGame -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $false } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $null = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        # Everything is in key\ and in the registry: Install has nothing to do.
        $again = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        $again.Downloaded | Should -Be 0
        $again.KeyInstalled | Should -BeFalse
        Should -Invoke Import-ServerKeyRegFile -Times 2 -Exactly
        # key\ goes missing: the setup runs again.
        Remove-Item -LiteralPath (Join-Path $folder 'key') -Recurse -Force
        $third = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        $third.Downloaded | Should -Be 0
        $third.KeyInstalled | Should -BeTrue
        Should -Invoke Import-ServerKeyRegFile -Times 4 -Exactly
    }

    It 'sets the keys up again without downloading the game again' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-again-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $global:againGame = Join-Path $TestDrive ('uo-game-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $global:againGame -Entries ([ordered]@{ 'CoDUOSP.exe' = 'sp'; 'CoDUOMP.exe' = 'mp' })
        $global:againReg = Join-Path $TestDrive ('server-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:againReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty]'
            '"codkey"="PUT-THE-KEY-HERE"')
        $global:againSecondReg = Join-Path $TestDrive ('server-uo-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $global:againSecondReg -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="PUT-THE-KEY-HERE"')
        $global:againKey = Join-Path $TestDrive ('codkey-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $global:againKey -Value 'ABCD1234EFGH5678IJKL'
        Mock Invoke-ResumableDownload {
            if ($Url -like '*get=codkey*') { Copy-Item -LiteralPath $global:againKey -Destination $Destination -Force; return 0 }
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:againSecondReg -Destination $Destination -Force; return 0 }
            if ($Url -like '*.reg') { Copy-Item -LiteralPath $global:againReg -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:againGame -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $false } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $null = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        # Someone deleted key\, or the first attempt at the registry files failed: Install
        # runs the key setup again and downloads no game file at all.
        Remove-Item -LiteralPath (Join-Path $folder 'key') -Recurse -Force
        Mock Invoke-ResumableDownload {
            if ($Url -like '*downloads.php*') { Copy-Item -LiteralPath $global:uoKeyPage -Destination $Destination -Force; return 0 }
            if ($Url -like '*.zip') { throw 'The game must not be downloaded again.' }
            if ($Url -like '*coduo1.51.reg') { Copy-Item -LiteralPath $global:againSecondReg -Destination $Destination -Force; return 0 }
            Copy-Item -LiteralPath $global:againReg -Destination $Destination -Force; return 0
        }
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $false } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $result = Install-GameClient -GameId 'coduo' -ClientId 'uo-15' -GameFolder $folder -RetryDelaySeconds 0
        $result.Downloaded | Should -Be 0
        $result.KeyInstalled | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-server-key.reg') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $folder 'key\codhq-uo-server-key.reg') | Should -BeTrue
        # Two registry files now, and the first install added the same two.
        Should -Invoke Import-ServerKeyRegFile -Times 4 -Exactly
    }
    It 'reads the key the site prints for United Offensive, and only that one' {
        $page = Join-Path $TestDrive ('page-' + [guid]::NewGuid().ToString('N') + '.html')
        # The page lists both games' keys: the one after this game's name is the one taken.
        # It is printed in groups of four, and comes back as the 20 characters the registry
        # value holds, without the dashes.
        Set-Content -LiteralPath $page -Value '<html><body>COD1  ABCD-1234-EFGH-5678-IJKL<br><b>CODUO</b>&nbsp;&nbsp;3G1K-HWJQ-TWUG-QAHW-8901<br></body></html>'
        Read-ServerKeyFromPage -Path $page -Label 'CODUO' | Should -Be '3G1KHWJQTWUGQAHW8901'
        # One key on the page and no name to look for: it is the only key there can be.
        Set-Content -LiteralPath $page -Value '<html><body>3G1K-HWJQ-TWUG-QAHW-8901</body></html>'
        Read-ServerKeyFromPage -Path $page -Label 'CODUO' | Should -Be '3G1KHWJQTWUGQAHW8901'
        # Two keys and nothing that says which one is this game's: nothing is guessed.
        Set-Content -LiteralPath $page -Value '<html><body>ABCD-1234-EFGH-5678-IJKL 3G1K-HWJQ-TWUG-QAHW-8901</body></html>'
        Read-ServerKeyFromPage -Path $page -Label 'CODUO' | Should -Be ''
    }

    It 'deletes the registry values a key added when the key is removed' {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('uo-remove-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $keyDir = Join-Path $folder 'key'
        $null = New-Item -ItemType Directory -Path $keyDir -Force
        $copy = Join-Path $keyDir 'codhq-uo-server-key.reg'
        Set-Content -LiteralPath $copy -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            '[HKEY_CURRENT_USER\Software\Call of Duty United Offensive]'
            '"key"="3G1K-HWJQ-TWUG-QAHW-8901"'
            '"InstallPath"="C:\\Games\\CoDUO"'
            '"Version"="1.51"')
        $remove = Join-Path $keyDir 'codhq-uo-server-key-remove.reg'
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 0; Output = ''; Prompted = $true } }
        Mock Test-ServerKeyRegInRegistry { $true }
        $spec = @{ Name = 'United Offensive 1.51'; RegUrl = 'https://example.test/coduo1.51.reg'; KeyPageUrl = 'https://example.test/downloads.php'
            ValueName = 'key'; KeyFileName = 'coduo-key.txt'; CopyName = 'codhq-uo-server-key.reg'; Folder = 'key'
            Version = '1.51'; DriveWithBackslash = $true }
        Remove-ServerKeyReg -Spec $spec -GameFolder $folder | Should -BeTrue
        # One question for the remove.reg, and the filled in file stays for the next setup.
        Should -Invoke Import-ServerKeyRegFile -Times 1 -Exactly
        Test-Path -LiteralPath $remove | Should -BeFalse
        Test-Path -LiteralPath $copy | Should -BeTrue
        # A prompt the player cancels keeps the remove.reg next to the filled in file.
        Mock Import-ServerKeyRegFile { [pscustomobject]@{ ExitCode = 70; Output = 'The operation was canceled by the user.'; Prompted = $true; Cancelled = $true } }
        Mock Write-Warn { }
        Remove-ServerKeyReg -Spec $spec -GameFolder $folder | Should -BeFalse
        Test-Path -LiteralPath $remove | Should -BeTrue
        Should -Invoke Write-Warn -ParameterFilter { $Message -like '*was cancelled*' }
    }
}
Describe 'Server key registry read-back' {
    It 'asks the registry whether a filled in .reg file is in it' {
        $section = 'CodebuffServerKeyTest_' + [guid]::NewGuid().ToString('N')
        $hive = 'HKCU:\Software\' + $section
        $wow = 'HKCU:\Software\Wow6432Node\' + $section
        $file = Join-Path $TestDrive ('check-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $file -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            ('[HKEY_CURRENT_USER\Software\' + $section + ']')
            '"codkey"="ABCD"'
            '"InstallPath"="C:\\Games\\Test"'
            '"InstallDrive"="C:"'
            '"Version"="1.5"')
        try {
            # Nothing written yet: the editor closed without merging the file.
            Test-ServerKeyRegInRegistry -Path $file | Should -BeFalse
            $null = New-Item -Path $hive -Force
            Set-ItemProperty -LiteralPath $hive -Name 'codkey' -Value 'ABCD'
            Set-ItemProperty -LiteralPath $hive -Name 'InstallPath' -Value 'C:\Games\Test'
            Set-ItemProperty -LiteralPath $hive -Name 'InstallDrive' -Value 'C:'
            Set-ItemProperty -LiteralPath $hive -Name 'Version' -Value '1.5'
            # The merge happened: every value the file writes is there, with the doubled
            # backslash of the .reg line read as the single one the registry holds.
            Test-ServerKeyRegInRegistry -Path $file | Should -BeTrue
            # One value differs (an older file was merged): not set up.
            Set-ItemProperty -LiteralPath $hive -Name 'Version' -Value '1.1'
            Test-ServerKeyRegInRegistry -Path $file | Should -BeFalse
            # The 32-bit view of the same section is what the game reads, so it counts.
            Remove-Item -LiteralPath $hive -Recurse -Force
            $null = New-Item -Path $wow -Force
            Set-ItemProperty -LiteralPath $wow -Name 'codkey' -Value 'ABCD'
            Set-ItemProperty -LiteralPath $wow -Name 'InstallPath' -Value 'C:\Games\Test'
            Set-ItemProperty -LiteralPath $wow -Name 'InstallDrive' -Value 'C:'
            Set-ItemProperty -LiteralPath $wow -Name 'Version' -Value '1.5'
            Test-ServerKeyRegInRegistry -Path $file | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $hive -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wow -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'deletes only the values a filled in .reg file set, and reads that back' {
        $section = 'CodebuffServerKeyRemoveTest_' + [guid]::NewGuid().ToString('N')
        $hive = 'HKCU:\Software\' + $section
        $wow = 'HKCU:\Software\Wow6432Node\' + $section
        $file = Join-Path $TestDrive ('set-' + [guid]::NewGuid().ToString('N') + '.reg')
        $cleanup = Join-Path $TestDrive ('remove-' + [guid]::NewGuid().ToString('N') + '.reg')
        Set-Content -LiteralPath $file -Value @(
            'Windows Registry Editor Version 5.00'
            ''
            ('[HKEY_CURRENT_USER\Software\' + $section + ']')
            '"key"="3G1K-HWJQ-TWUG-QAHW-8901"'
            '"InstallPath"="C:\\Games\\CoDUO"')
        try {
            $null = New-Item -Path $hive -Force
            Set-ItemProperty -LiteralPath $hive -Name 'key' -Value '3G1K-HWJQ-TWUG-QAHW-8901'
            Set-ItemProperty -LiteralPath $hive -Name 'InstallPath' -Value 'C:\Games\CoDUO'
            # Something the game itself keeps in that section is not the setup's to delete.
            Set-ItemProperty -LiteralPath $hive -Name 'net_ads' -Value '1'
            Test-ServerKeyRegInRegistry -Path $file | Should -BeTrue
            $null = New-ServerKeyRegCleanupFile -Path $file -Destination $cleanup
            $text = [IO.File]::ReadAllText($cleanup)
            $text | Should -Match '"key"=-'
            $text | Should -Match '"InstallPath"=-'
            $text | Should -Not -Match 'net_ads'
            # Nothing deleted yet: the values are still there.
            Test-ServerKeyRegInRegistry -Path $cleanup | Should -BeFalse
            $reg = Invoke-RegExe -Arguments @('import', $cleanup)
            $reg.ExitCode | Should -Be 0
            Test-ServerKeyRegInRegistry -Path $cleanup | Should -BeTrue
            Test-ServerKeyRegInRegistry -Path $file | Should -BeFalse
            (Get-ItemProperty -LiteralPath $hive).net_ads | Should -Be '1'
        } finally {
            Remove-Item -LiteralPath $hive -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $wow -Recurse -Force -ErrorAction SilentlyContinue
        }
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
        $elevated = [pscustomobject]@{ Id = 'test'; Name = 'Test game'; NameArgument = '+set name'; DefaultArguments = ''; NeedsElevation = $false }
        (Get-CatalogLaunchCommand -Game $elevated -Mode (New-CatalogMode 'mp' 'Multiplayer' -Exe 'test.exe' -Elevate $true) -GameFolder 'C:\T').Elevate | Should -BeTrue
        $elevated.NeedsElevation = $true
        (Get-CatalogLaunchCommand -Game $elevated -Mode (New-CatalogMode 'mp' 'Multiplayer' -Exe 'test.exe') -GameFolder 'C:\T').Elevate | Should -BeTrue
    }

    It 'starts United Offensive with nothing the game refuses' {
        $uo = Get-CatalogGame -Id 'coduo'
        $sp = $uo.Modes | Where-Object { $_.Id -eq 'sp' }
        # The executable on its own starts. "+set com_hunkmegs 512" makes the game show
        # "Out of memory error. You are probably low on hard disk space." before the menu.
        (Get-CatalogLaunchCommand -Game $uo -Mode $sp -GameFolder 'C:\UO').Arguments | Should -Be ''
        $mp = $uo.Modes | Where-Object { $_.Id -eq 'mp' }
        (Get-CatalogLaunchCommand -Game $uo -Mode $mp -GameFolder 'C:\UO' -PlayerName 'Lark').Arguments | Should -Be '+set name "Lark"'
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
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('test-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $folder 'test.exe') -Value 'retail'
        $testGame = [pscustomobject]@{ Id = 'test'; Name = 'Test game'; Year = '2000'; SteamAppIds = @(); Detect = 'folder'; ValidFiles = @('test.exe'); NameArgument = '+set name'
            DefaultArguments = '+set com_hunkmegs 512'; NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''; Clients = @()
            Modes = @(New-CatalogMode 'mp' 'Multiplayer' -Exe 'test.exe'); Available = $true; UnavailableReason = '' }
        Mock Get-CatalogGame { $testGame } -ParameterFilter { $Id -eq 'test' }
        Mock Start-Process { }
        Mock Test-SandboxMode { $true }
        $cmd = Start-CatalogGame -GameId 'test' -ModeId 'mp' -GameFolder $folder
        $cmd.Arguments | Should -Be '+set com_hunkmegs 512'
        Should -Invoke Start-Process -Times 0
    }

    It 'opens a Steam link through steam.exe and falls back to the web page' {
        Mock Test-SandboxMode { $false }
        Mock Get-SteamInstallationPath { $null }
        Mock Start-Process { throw 'no handler' } -ParameterFilter { $FilePath -like 'steam://*' }
        Mock Start-Process { }
        Open-SteamUrl -Url 'steam://store/7940' -WebFallback 'https://store.steampowered.com/app/7940/' | Should -Be 'web'
        Mock Start-Process { } -ParameterFilter { $FilePath -like 'steam://*' }
        Open-SteamUrl -Url 'steam://store/7940' | Should -Be 'url'
    }
}

Describe 'CD keys (the player''s own)' -Skip:([bool]$IsLinux -or [bool]$IsMacOS) {
    BeforeEach {
        $testRoot = 'HKCU:\Software\codhq-tests\' + [guid]::NewGuid().ToString('N') + '\'
        $global:CdKeyRegistryRootOverride = $testRoot
        $SettingsDirectory = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N'))
        $script:logged = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:logged.Add([string]$Object) }
        $key = 'ABCD-EFGH-JKLM-NPQR-ST12'
    }
    AfterEach {
        $global:CdKeyRegistryRootOverride = ''
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        if ((Test-Path 'HKCU:\Software\codhq-tests') -and -not (Get-ChildItem 'HKCU:\Software\codhq-tests')) { Remove-Item 'HKCU:\Software\codhq-tests' -Force }
    }

    It 'accepts a key as Steam shows it and refuses anything else' {
        ConvertTo-CdKey 'abcd-efgh-jklm-npqr-st12' | Should -BeExactly 'ABCDEFGHJKLMNPQRST12'
        { ConvertTo-CdKey 'TOO-SHORT' } | Should -Throw '*20 letters and digits*'
        { ConvertTo-CdKey 'ABCD-EFGH-JKLM-NPQR-ST1!' } | Should -Throw
    }

    It 'writes every value the game reads, reads it back and only ever shows it masked' {
        Set-GameCdKey -GameId 'cod4' -Key $key
        $status = Get-GameCdKeyStatus -GameId 'cod4'
        @($status.Values | Where-Object Present).Count | Should -Be 1
        $status.Values[0].Masked | Should -Be '****-****-****-****-ST12'
        (Get-ItemProperty -LiteralPath ($testRoot + (Get-CdKeySpec -GameId 'cod4').Subkey)).codkey | Should -BeExactly 'ABCDEFGHJKLMNPQRST12'
        ($script:logged -join "`n") | Should -Not -Match 'ABCDEFGHJKLMNPQR'
        ($script:logged -join "`n") | Should -Not -Match 'ABCD-EFGH'
    }

    It 'backs up before changing and restores the earlier key' {
        Set-GameCdKey -GameId 'cod4' -Key $key
        $backupsBefore = @(Get-GameCdKeyBackupList -GameId 'cod4')
        Set-GameCdKey -GameId 'cod4' -Key 'ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZ99'
        $latest = @(Get-GameCdKeyBackupList -GameId 'cod4')[0]
        @(Get-GameCdKeyBackupList -GameId 'cod4').Count | Should -Be ($backupsBefore.Count + 1)
        Restore-GameCdKey -GameId 'cod4' -BackupFile $latest.FullName
        (Get-GameCdKeyStatus -GameId 'cod4').Values[0].Masked | Should -Be '****-****-****-****-ST12'
    }

    It 'restoring the backup taken when there was no key removes the key again' {
        Set-GameCdKey -GameId 'cod4' -Key $key
        $first = @(Get-GameCdKeyBackupList -GameId 'cod4')[-1]
        Restore-GameCdKey -GameId 'cod4' -BackupFile $first.FullName
        (Get-GameCdKeyStatus -GameId 'cod4').Values[0].Present | Should -BeFalse
    }
}

Describe 'Checking the player''s own BO3/BO4 executable' {
    BeforeEach {
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('bo3-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $exeBytes = [Text.Encoding]::ASCII.GetBytes('fake black ops 3 build')
        [IO.File]::WriteAllBytes((Join-Path $folder 'BlackOps3.exe'), $exeBytes)
        Mock Write-Host { }
        $manifestFor = { param($Sha1, $Size) [pscustomobject]@{ Entries = @([pscustomobject]@{ Path = 'BlackOps3.exe'; Size = [int64]$Size; Sha1 = $Sha1; Dest = '' }) } }
    }

    It 'reports a match when the player''s file is the expected build' {
        $result = Test-GameExecutable -GameId 'bo3' -GameFolder $folder -Manifest (& $manifestFor (Get-BytesSha1 $exeBytes) $exeBytes.Length)
        $result.Exists | Should -BeTrue
        $result.Matches | Should -BeTrue
        $result.Sha256 | Should -Be (Get-BytesSha256 $exeBytes)
    }

    It 'reports a different build with the repair advice' {
        $result = Test-GameExecutable -GameId 'bo3' -GameFolder $folder -Manifest (& $manifestFor ('0' * 40) 123)
        $result.Matches | Should -BeFalse
        $result.Repair | Should -Match 'Verify integrity'
    }

    It 'reports a missing executable without downloading anything' {
        Remove-Item -LiteralPath (Join-Path $folder 'BlackOps3.exe')
        Mock Invoke-ResumableDownload { throw 'must not download' }
        $result = Test-GameExecutable -GameId 'bo3' -GameFolder $folder -Manifest (& $manifestFor ('0' * 40) 1)
        $result.Exists | Should -BeFalse
        Should -Invoke Invoke-ResumableDownload -Times 0
    }

    It 'pins the expected build by its PE header checksum, without a manifest' {
        $pe = 0x80
        $peBytes = New-Object byte[] 512
        $peBytes[0] = 0x4D; $peBytes[1] = 0x5A
        [BitConverter]::GetBytes([int]$pe).CopyTo($peBytes, 0x3C)
        [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($peBytes, $pe)
        [BitConverter]::GetBytes([uint32]0x6531394).CopyTo($peBytes, $pe + 24 + 64)
        $exe = Join-Path $folder 'BlackOps3.exe'
        [IO.File]::WriteAllBytes($exe, $peBytes)
        $result = Test-GameExecutable -GameId 'bo3' -GameFolder $folder
        $result.ExpectedChecksum | Should -Be 0x6531394
        $result.Checksum | Should -Be 0x6531394
        $result.Matches | Should -BeTrue

        # The dedicated server build is a different checksum: not the build a client loads.
        [BitConverter]::GetBytes([uint32]0x14C28B4).CopyTo($peBytes, $pe + 24 + 64)
        [IO.File]::WriteAllBytes($exe, $peBytes)
        $result = Test-GameExecutable -GameId 'bo3' -GameFolder $folder
        $result.Matches | Should -BeFalse
        $result.Repair | Should -Match 'Verify integrity'
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

    It 'does not mistake one game''s folder for another that ships the same library' {
        # binkw32.dll is in the marker lists of CoD4, WaW, BO1, MW2 and MW3, so only the
        # game's own executable may identify its folder.
        Set-Content -LiteralPath (Join-Path $cod4 'binkw32.dll') -Value 'shared library'
        foreach ($id in 'waw', 'bo1', 'mw2', 'mw3') {
            $other = Get-CatalogGame -Id $id
            Test-CatalogGameFolder -Game $other -Folder $cod4 | Should -BeFalse -Because $id
            Find-CatalogGame -Game $other | Should -BeNullOrEmpty -Because $id
        }
        (Find-CatalogGame -Game $game).Folder | Should -Be ([IO.Path]::GetFullPath($cod4).TrimEnd('\'))
    }

    It 'finds a game in a library''s common folder when its own manifest is gone' {
        Remove-Item -LiteralPath (Join-Path $library 'steamapps\appmanifest_7940.acf')
        (Find-CatalogGame -Game $game).Folder | Should -Be ([IO.Path]::GetFullPath($cod4).TrimEnd('\'))
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

Describe 'Game clients: release archives, launchers and conflicts' {
    BeforeAll {
        $served = [hashtable]::Synchronized(@{})
        $fileServer = Start-TestFileServer -Files $served
        function Get-FolderState {
            param([string]$Folder)
            @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Folder.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
        }
        # A real Windows executable with exactly one import (mscoree.dll): any .NET
        # Framework assembly has that. Built with the C# compiler that ships with
        # Windows, which both PowerShell versions can run.
        $script:peSource = Join-Path $TestDrive 'pe-sample.exe'
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        $csSource = Join-Path $TestDrive 'pe-sample.cs'
        Set-Content -LiteralPath $csSource -Value 'public static class CodHqPeSample { public static void Main() { } }'
        $null = & $csc /nologo /target:exe "/out:$script:peSource" $csSource
        if (-not (Test-Path -LiteralPath $script:peSource)) { throw 'The sample executable could not be built.' }
    }
    AfterAll { Stop-TestHttpServer $fileServer }

    BeforeEach {
        $served.Clear()
        $appData = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('appdata-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        $gameFolder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('game-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Set-Content -LiteralPath (Join-Path $gameFolder 'game.exe') -Value 'steam exe' -NoNewline
        Set-Content -LiteralPath (Join-Path $gameFolder 'mss32.dll') -Value 'miles' -NoNewline
        Mock Get-ClientAppDataRoot { $appData }
        Mock Write-Host { }
        Mock Write-Progress { }
        # The test game, with clients whose files are the test's own.
        $script:testGame = [pscustomobject]@{ Id = 'test-game'; Name = 'Test game'; Year = '2000'; SteamAppIds = @(); Detect = 'folder'; ValidFiles = @('game.exe')
            NameArgument = '+set name'; DefaultArguments = '+set cl_motd 0'; NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @(); Modes = @(); Available = $true; UnavailableReason = '' }
        Mock Get-CatalogGame { $script:testGame } -ParameterFilter { $Id -eq 'test-game' }
    }

    It 'takes files out of a release archive, each checked, and refuses an archive that does not match' {
        $zip = Join-Path $TestDrive ('rel-' + [guid]::NewGuid().ToString('N') + '.zip')
        New-TestZip -Path $zip -Entries ([ordered]@{ 'client.dll' = 'client dll'; 'game.exe' = 'patched exe'; 'readme.vbs' = 'not needed' })
        $bytes = [IO.File]::ReadAllBytes($zip); $served['/rel/client.zip'] = $bytes
        $archive = [pscustomobject]@{ Url = $fileServer.Base + 'rel/client.zip'; Size = $bytes.Length; Sha256 = (Get-BytesSha256 $bytes) }
        $assets = @(
            [pscustomobject]@{ Path = 'client.dll'; Entry = 'client.dll'; Size = 10; Sha256 = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('client dll'))); Archive = $archive },
            [pscustomobject]@{ Path = 'game.exe'; Entry = 'game.exe'; Size = 11; Sha256 = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('patched exe'))); Archive = $archive })
        $script:testGame.Clients = @(New-CatalogClient -Id 'fake-x' -Name 'Test X' -Source 'github' -Assets $assets)
        $result = Install-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder -RetryDelaySeconds 0
        $result.Downloaded | Should -Be 2
        Get-Text (Join-Path $gameFolder 'client.dll') | Should -Be 'client dll'
        Get-Text (Join-Path $gameFolder 'game.exe') | Should -Be 'patched exe'
        Test-Path -LiteralPath (Join-Path $gameFolder 'readme.vbs') | Should -BeFalse
        Remove-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder
        Get-Text (Join-Path $gameFolder 'game.exe') | Should -Be 'steam exe'

        $bad = @($assets | ForEach-Object { $c = $_.PSObject.Copy(); $c.Archive = [pscustomobject]@{ Url = $archive.Url; Size = $archive.Size; Sha256 = ('0' * 64) }; $c })
        $script:testGame.Clients = @(New-CatalogClient -Id 'fake-x' -Name 'Test X' -Source 'github' -Assets $bad)
        { Install-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder -RetryDelaySeconds 0 } | Should -Throw
        Get-Text (Join-Path $gameFolder 'game.exe') | Should -Be 'steam exe'
    }

    It 'reads an executable''s imports and reports the ones that are missing' {
        @(Get-ExecutableImportNames -Path $script:peSource) | Should -Contain 'mscoree.dll'
        @(Get-MissingExecutableDependency -Executable $script:peSource).Count | Should -Be 0
        $script:testGame.Modes = @(New-CatalogMode 'sp' 'Campaign' -Exe 'game.exe')
        $isolated = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('dep-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Copy-Item -LiteralPath $script:peSource -Destination (Join-Path $isolated 'game.exe')
        Mock Get-ExecutableImportNames { @('mss32.dll') }
        Get-ModeBlocker -Game $script:testGame -Mode $script:testGame.Modes[0] -GameFolder $isolated | Should -BeLike '*missing mss32.dll*Verify integrity*'
    }

    It 'backs up the files a launcher replaces and removes what it added, keeping the rest' {
        Set-Content -LiteralPath (Join-Path $gameFolder 'BlackOps4.exe') -Value 'battle.net exe' -NoNewline
        $null = New-Item -ItemType Directory -Path (Join-Path $gameFolder 'LPC') -Force
        Set-Content -LiteralPath (Join-Path $gameFolder 'LPC\core.ff') -Value 'battle.net lpc' -NoNewline
        $served['/l/launcher.exe'] = [Text.Encoding]::ASCII.GetBytes('launcher')
        $script:testGame.Clients = @(New-CatalogClient -Id 'fake-x' -Name 'Test launcher' -Source 'github' -Protect @('BlackOps4.exe', 'LPC\*') -Watch @('project-bo4\*', 'LPC\*', 'XInput9_1_0.dll', 'BlackOps4.exe') -Assets @(
            [pscustomobject]@{ Path = 'project-bo4/launcher/launcher.exe'; Url = $fileServer.Base + 'l/launcher.exe'; Size = 8; Sha256 = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('launcher'))) }))
        $before = Get-FolderState $gameFolder
        $null = Install-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder -RetryDelaySeconds 0
        # What the launcher itself does later: its exe, LPC and DLL over the player's.
        Set-Content -LiteralPath (Join-Path $gameFolder 'BlackOps4.exe') -Value 'launcher exe' -NoNewline
        Set-Content -LiteralPath (Join-Path $gameFolder 'LPC\core.ff') -Value 'launcher lpc' -NoNewline
        Set-Content -LiteralPath (Join-Path $gameFolder 'LPC\extra.ff') -Value 'launcher lpc 2' -NoNewline
        Set-Content -LiteralPath (Join-Path $gameFolder 'XInput9_1_0.dll') -Value 'client' -NoNewline
        $null = New-Item -ItemType Directory -Path (Join-Path $gameFolder 'project-bo4\zone') -Force
        Set-Content -LiteralPath (Join-Path $gameFolder 'project-bo4\zone\support.ff') -Value 'content' -NoNewline
        Remove-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder
        Get-FolderState $gameFolder | Should -Be $before
        Test-Path -LiteralPath (Join-Path $gameFolder 'project-bo4') | Should -BeFalse
    }

    It 'asks before removing what a launcher added across the whole game folder' {
        $served['/l/launcher.exe'] = [Text.Encoding]::ASCII.GetBytes('launcher')
        $script:testGame.Clients = @(New-CatalogClient -Id 'fake-x' -Name 'Test launcher' -Source 'github' -AppData 'TestLauncher' -Watch @('*') -ConfirmCleanup $true -Assets @(
            [pscustomobject]@{ Path = 'launcher.exe'; Url = $fileServer.Base + 'l/launcher.exe'; Size = 8; Sha256 = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('launcher'))) }))
        $null = Install-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder -RetryDelaySeconds 0
        Test-Path -LiteralPath (Join-Path $appData 'TestLauncher\launcher.exe') | Should -BeTrue
        Set-Content -LiteralPath (Join-Path $gameFolder 'hmw-mod.exe') -Value 'mod' -NoNewline
        $null = New-Item -ItemType Directory -Path (Join-Path $gameFolder 'players2') -Force
        Set-Content -LiteralPath (Join-Path $gameFolder 'players2\config.cfg') -Value 'settings' -NoNewline
        Mock Read-Host { 'n' }
        Remove-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder
        Test-Path -LiteralPath (Join-Path $gameFolder 'hmw-mod.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $appData 'TestLauncher\launcher.exe') | Should -BeFalse

        $null = Install-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder -RetryDelaySeconds 0
        Set-Content -LiteralPath (Join-Path $gameFolder 'hmw-mod2.exe') -Value 'mod' -NoNewline
        Mock Read-Host { 'y' }
        Remove-GameClient -GameId 'test-game' -ClientId 'fake-x' -GameFolder $gameFolder
        Test-Path -LiteralPath (Join-Path $gameFolder 'hmw-mod2.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $gameFolder 'hmw-mod.exe') | Should -BeTrue
        Get-Text (Join-Path $gameFolder 'players2\config.cfg') | Should -Be 'settings'
    }

    It 'refuses a client that conflicts with one already installed' {
        $script:testGame.Clients = @((New-CatalogClient -Id 'fake-y' -Name 'Test Y' -Source 'github' -Conflicts @('fake-x')), (New-CatalogClient -Id 'fake-x' -Name 'Test X' -Source 'github' -Conflicts @('fake-y')))
        Write-ClientRecord -GameFolder $gameFolder -ClientId 'fake-x' -Record ([pscustomobject]@{ ClientId = 'fake-x'; ClientName = 'Test X'; Files = @() })
        { Install-GameClient -GameId 'test-game' -ClientId 'fake-y' -GameFolder $gameFolder } | Should -Throw '*cannot be installed together*'
    }

    It 'leaves out the default arguments when a mode asks for that' {
        (Get-CatalogLaunchCommand -Game $script:testGame -Mode (New-CatalogMode 'x' 'X' -Exe 'a.exe' -NoDefaultArguments $true) -GameFolder $gameFolder -PlayerName 'Lark').Arguments | Should -Be '+set name "Lark"'
        (Get-CatalogLaunchCommand -Game $script:testGame -Mode (New-CatalogMode 'x' 'X' -Exe 'a.exe') -GameFolder $gameFolder -PlayerName 'Lark').Arguments | Should -Be '+set cl_motd 0 +set name "Lark"'
    }
    It 'writes values into a launcher settings file and keeps everything else in it' {
        $file = Join-Path $gameFolder 'project-bo4.json'
        Set-Content -LiteralPath $file -Value '{"identity":{"name":"Old","xuid":"123"},"dedicated":{"lobby":"public"}}'
        Set-JsonSettingValues -Path $file -Values @{ 'identity.name' = 'Lark'; 'demonware.ipv4' = '127.0.0.1' } | Should -BeTrue
        $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $data.identity.name | Should -Be 'Lark'
        $data.identity.xuid | Should -Be '123'
        $data.demonware.ipv4 | Should -Be '127.0.0.1'
        $data.dedicated.lobby | Should -Be 'public'
        Set-Content -LiteralPath $file -Value 'not json'
        Mock Write-Warn { }
        Set-JsonSettingValues -Path $file -Values @{ 'identity.name' = 'Lark' } | Should -BeFalse
        Get-Text $file | Should -Be 'not json'
    }

    It 'reads the result Shield''s launcher writes' {
        $check = ConvertFrom-ShieldSyncLog -Lines @('phase hashing total 61', 'manifest https://x/manifest.json', 'ok 1 ready 0 download 2217 launcher_update 0 error ', 'component game missing download 1')
        $check.Ok | Should -BeTrue; $check.Ready | Should -BeFalse; $check.Download | Should -Be 2217; $check.LauncherUpdate | Should -BeFalse
        $sync = ConvertFrom-ShieldSyncLog -Lines @('ok 1 ready 0 download 5 launcher_update 1 error ', 'sync failed disk full')
        $sync.Synced | Should -BeFalse; $sync.Error | Should -Be 'disk full'; $sync.LauncherUpdate | Should -BeTrue
        (ConvertFrom-ShieldSyncLog -Lines @('ok 1 ready 1 download 0 launcher_update 0 error ', 'sync ok ')).Synced | Should -BeTrue
    }

    It 'moves a GitHub client to its newest release with the digests GitHub publishes' {
        $client = New-CatalogClient -Id 'fake-x' -Name 'Test X' -Source 'github' -ReleaseRepo 'owner/repo' -ReleaseTag 'v1' -Assets @(
            [pscustomobject]@{ Path = 'a.exe'; Url = 'https://github.com/owner/repo/releases/download/v1/a.exe'; Size = 1; Sha256 = ('1' * 64) },
            [pscustomobject]@{ Path = 'b.dll'; Entry = 'b.dll'; Size = 2; Sha256 = ('2' * 64); Archive = [pscustomobject]@{ Url = 'https://github.com/owner/repo/releases/download/v1/pack.zip'; Size = 3; Sha256 = ('3' * 64) } })
        Mock Get-GitHubRelease { [pscustomobject]@{ Tag = 'v2'; Assets = @(
            [pscustomobject]@{ Name = 'a.exe'; Size = 10; Url = 'https://github.com/owner/repo/releases/download/v2/a.exe'; Sha256 = ('a' * 64) },
            [pscustomobject]@{ Name = 'pack.zip'; Size = 30; Url = 'https://github.com/owner/repo/releases/download/v2/pack.zip'; Sha256 = ('c' * 64) }) } }
        $list = Get-ClientAssetList -Client $client -Latest
        $list.Tag | Should -Be 'v2'
        $list.Assets[0].Sha256 | Should -Be ('a' * 64)
        $list.Assets[0].Url | Should -BeLike '*/v2/a.exe'
        $list.Assets[1].Archive.Sha256 | Should -Be ('c' * 64)
        (Get-ClientAssetList -Client $client).Assets[0].Sha256 | Should -Be ('1' * 64)
        Mock Get-GitHubRelease { [pscustomobject]@{ Tag = 'v2'; Assets = @([pscustomobject]@{ Name = 'a.exe'; Size = 10; Url = 'u'; Sha256 = '' }) } }
        { Get-ClientAssetList -Client $client -Latest } | Should -Throw '*no checked*'
    }
}

Describe 'Automatic client updates' {
    BeforeEach {
        $global:GameUpdateCounts = @{}
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ('ghosts-' + [guid]::NewGuid().ToString('N'))) -Force).FullName
        Mock Find-CatalogGame { [pscustomobject]@{ Folder = $folder; Source = 'saved' } } -ParameterFilter { $Game.Id -eq 'ghosts' }
        Mock Find-CatalogGame { $null } -ParameterFilter { $Game.Id -ne 'ghosts' }
        Mock Test-GameClientInstalled { $true }
        Mock Write-Host { }
        Mock Update-GameClient { [pscustomobject]@{ Downloaded = 1 } }
    }

    It 'updates only the installed clients that have something new' {
        Mock Get-GameClientUpdateCount { 2 }
        $result = Invoke-ClientAutoUpdate
        $result.Checked | Should -Be 1
        $result.Updated | Should -Be 1
        Should -Invoke Update-GameClient -Times 1 -ParameterFilter { $GameId -eq 'ghosts' -and $ClientId -eq 'iw6x' }
        $global:GameUpdateCounts['ghosts|iw6x'] | Should -Be 0
    }

    It 'leaves up-to-date clients alone and carries on when a check fails' {
        Mock Get-GameClientUpdateCount { 0 }
        (Invoke-ClientAutoUpdate -GameId 'ghosts').Updated | Should -Be 0
        Should -Invoke Update-GameClient -Times 0
        Mock Get-GameClientUpdateCount { throw 'offline' }
        Mock Write-Warn { }
        { Invoke-ClientAutoUpdate -GameId 'ghosts' } | Should -Not -Throw
        Should -Invoke Write-Warn -ParameterFilter { $Message -like '*offline*' }
    }

    It 'only checks the clients a mode uses when asked to' {
        Mock Get-GameClientUpdateCount { 1 }
        (Invoke-ClientAutoUpdate -GameId 'ghosts' -ClientIds @('someone-else')).Checked | Should -Be 0
        Should -Invoke Update-GameClient -Times 0
    }
}
Describe 'CodHQ BOIII release' {
    It 'matches the release published on our site, file by file' {
        $client = @((Get-CatalogGame -Id 'bo3').Clients)[0]
        $work = Join-Path $TestDrive ('release-' + [guid]::NewGuid().ToString('N'))
        try {
            $release = Get-CodhqRelease -Client $client -WorkRoot $work -RetryDelaySeconds 1
            $release.ArchiveSha256 | Should -Be ([string]$client.Archive.Sha256).ToUpperInvariant()
            @($release.Entries).Count | Should -Be ([int]$client.ManifestCount)
            (Get-Item -LiteralPath $release.ZipPath).Length | Should -Be ([int64]$client.Archive.Size)
            @(Get-ChildItem -LiteralPath $release.FilesRoot -Recurse -File).Count | Should -Be ([int]$client.ManifestCount)
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'fails when the pin, the count or an entry disagrees with the archive' {
        $source = Join-Path $TestDrive 'codhq-source'
        $null = New-Item -ItemType Directory -Path (Join-Path $source 'data') -Force
        [IO.File]::WriteAllText((Join-Path $source 'boiii.exe'), 'exe')
        [IO.File]::WriteAllText((Join-Path $source 'data/a.txt'), 'alpha')
        [IO.File]::WriteAllText((Join-Path $source 'data/b.txt'), 'bravo')
        $zip = Join-Path $TestDrive 'codhq-release.zip'
        Compress-Archive -Path (Join-Path $source '*') -DestinationPath $zip
        $entries = @('boiii.exe', 'data/a.txt', 'data/b.txt') | ForEach-Object {
            $full = Join-Path $source ($_ -replace '/', '\')
            [pscustomobject]@{ Path = $_; Size = (Get-Item -LiteralPath $full).Length; Sha1 = (Get-FileSha1Hex $full); Dest = '' }
        }
        $client = New-CatalogClient -Id 'tamper' -Name 'Tamper' -Source 'codhq' -ManifestCount 3
        { Test-CodhqArchiveEntries -Client $client -ZipPath $zip -Entries $entries -FilesRoot (Join-Path $TestDrive 'checked') } | Should -Not -Throw

        $altered = @($entries | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = $_.Size; Sha1 = $_.Sha1; Dest = '' } })
        $altered[1].Sha1 = '0' * 40
        { Test-CodhqArchiveEntries -Client $client -ZipPath $zip -Entries $altered -FilesRoot (Join-Path $TestDrive 'bad-sha1') } | Should -Throw '*has SHA-1*'

        $missing = @($entries[0], [pscustomobject]@{ Path = 'data/missing.txt'; Size = 1; Sha1 = ('A' * 40); Dest = '' }, $entries[2])
        { Test-CodhqArchiveEntries -Client $client -ZipPath $zip -Entries $missing -FilesRoot (Join-Path $TestDrive 'bad-missing') } | Should -Throw '*does not contain data/missing.txt*'

        $wrongSize = @($entries | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = [int64]($_.Size + 1); Sha1 = $_.Sha1; Dest = '' } })
        { Test-CodhqArchiveEntries -Client $client -ZipPath $zip -Entries $wrongSize -FilesRoot (Join-Path $TestDrive 'bad-size') } | Should -Throw '*bytes, but its manifest says*'

        $wrongCount = New-CatalogClient -Id 'tamper' -Name 'Tamper' -Source 'codhq' -ManifestCount 4
        { Test-CodhqArchiveEntries -Client $wrongCount -ZipPath $zip -Entries $entries -FilesRoot (Join-Path $TestDrive 'bad-count') } | Should -Throw '*expects 4*'

        # A pin that is not a SHA-256, or one that disagrees with the download, never
        # passes for an install.
        $badPin = New-CatalogClient -Id 'tamper' -Name 'Tamper' -Source 'codhq' -ManifestCount 3 -Archive @{ Url = 'https://larkthestar.github.io/codhq-boiii/codhq-boiii.zip'; Size = 1; Sha256 = 'nope' }
        { Get-CodhqRelease -Client $badPin -WorkRoot (Join-Path $TestDrive 'bad-pin') } | Should -Throw '*not a SHA-256*'
    }
    It 'rejects an installed file that does not match, naming it' {
        $sandbox = Join-Path $TestDrive 'codhq-sandbox'
        $game = Join-Path $sandbox 'game'
        $null = New-Item -ItemType Directory -Path $game -Force
        $global:SandboxRoot = $sandbox
        try {
            $client = New-CatalogClient -Id 'check' -Name 'Check' -Source 'codhq' -ManifestCount 2 -AppData 'boiii' -GameFiles @('boiii.exe')
            [IO.File]::WriteAllText((Join-Path $game 'boiii.exe'), 'exe')
            $appData = Join-Path $sandbox 'AppData\boiii'
            $null = New-Item -ItemType Directory -Path (Join-Path $appData 'data') -Force
            [IO.File]::WriteAllText((Join-Path $appData 'data\a.txt'), 'alpha')
            $entries = @(
                [pscustomobject]@{ Path = 'boiii.exe'; Size = 3; Sha1 = (Get-FileSha1Hex (Join-Path $game 'boiii.exe')); Dest = '' },
                [pscustomobject]@{ Path = 'data/a.txt'; Size = 5; Sha1 = (Get-FileSha1Hex (Join-Path $appData 'data\a.txt')); Dest = '' })
            { Assert-CodhqInstalled -Client $client -Entries $entries -GameFolder $game } | Should -Not -Throw
            [IO.File]::WriteAllText((Join-Path $appData 'data\a.txt'), 'ALPHA')
            { Assert-CodhqInstalled -Client $client -Entries $entries -GameFolder $game } | Should -Throw '*data/a.txt*SHA-1*'
            Remove-Item -LiteralPath (Join-Path $game 'boiii.exe') -Force
            { Assert-CodhqInstalled -Client $client -Entries $entries -GameFolder $game } | Should -Throw '*boiii.exe is missing*'
        } finally { $global:SandboxRoot = '' }
    }
}
