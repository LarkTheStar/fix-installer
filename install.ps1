param(
    [switch]$RunDowngradeOnly,
    # Which downgrade the elevated relaunch must run. The relaunch used to pass only
    # -RunDowngradeOnly, so a Nuclear relaunch silently ran Normal instead.
    [ValidateSet('Normal', 'Nuclear')][string]$DowngradeMethod = 'Normal',
    # Passed to the administrator window by the window that started it. When the
    # administrator is a different account, its own %LOCALAPPDATA% and saved game
    # folder are not the user's, so the hand-off files go to the folder named here
    # and the downgrade uses the game folder the user's window was using.
    [string]$HandoffDirectory = '',
    [string]$GameFolder = '',
    # Test mode: run against a fake Steam and game folder (see Test-SandboxMode and
    # tests\Start-Sandbox.ps1). The folder must contain the .codhq-sandbox marker.
    [string]$Sandbox = ''
)

# ==========================================
# VERSION
# ==========================================
$AppVersion = '1.1.0'
# Also exposed globally: the diagnostics header is built from a handler, and a
# global survives any scope the handler ends up running in.
$global:AppVersion = $AppVersion

# Where this script lives when it is fetched with "irm <url> | iex".
$ScriptRawUrl = 'https://raw.githubusercontent.com/LarkTheStar/fix-installer/main/install.ps1'

# Piped-in code has to be saved to a file so the GUI can run (and elevate) on its
# own, but the text a script was handed is not reliable: under "irm ... | iex" the
# scriptblock can describe the enclosing command instead of this script. Anything
# written to disk must pass this check first.
function Test-ScriptSourceLooksComplete {
    param([string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { return $false }
    if ($Source.Length -lt 20000) { return $false }
    return ($Source -match 'function Invoke-SteamDowngrade') -and ($Source -match 'Call of Duty MW4 Setup Utility')
}

# Invoke-WebRequest returns Content as a string for text/plain but as a byte array
# for other MIME types, and raw hosts differ, so decode both to script text (and
# drop a leading BOM so it cannot end up doubled when the copy is written).
function ConvertTo-ScriptText {
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [byte[]]) {
        try { return ([System.Text.Encoding]::UTF8.GetString($Content)).TrimStart([char]0xFEFF) } catch { return '' }
    }
    return ([string]$Content).TrimStart([char]0xFEFF)
}

# Quotes a path for a powershell.exe command line. A trailing backslash would escape
# the closing quote ("C:\" -> C:"), so trailing backslashes are doubled.
function ConvertTo-QuotedArgument {
    param([string]$Value)
    $trimmed = $Value.TrimEnd('\')
    $trailing = $Value.Length - $trimmed.Length
    return '"' + $trimmed + ('\' * ($trailing * 2)) + '"'
}

# "irm ... | iex" saves a copy of this script as %TEMP%\codhq-setup-<guid>.ps1 and
# runs that. Only those copies may ever be deleted by the cleanup below, never a
# file the user downloaded and started themselves.
function Test-IsTempScriptCopy {
    param([string]$Path, [string]$TempDirectory = [IO.Path]::GetTempPath())
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($TempDirectory)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $temp = [IO.Path]::GetFullPath($TempDirectory).TrimEnd('\', '/')
    } catch { return $false }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($full).TrimEnd('\', '/'), $temp, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ([IO.Path]::GetFileName($full) -match '^codhq-setup-[0-9a-f]{32}\.ps1$')
}

# Copies left by earlier runs. A window deletes its own copy when it closes, so these
# are only left behind by crashes or a killed process. Anything younger than a day
# is skipped, because another window may still be running from it.
function Remove-StaleScriptCopies {
    param([string]$KeepPath, [string]$TempDirectory = [IO.Path]::GetTempPath(), [TimeSpan]$OlderThan = [TimeSpan]::FromDays(1))
    $cutoff = [DateTime]::UtcNow - $OlderThan
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $TempDirectory -Filter 'codhq-setup-*.ps1' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-IsTempScriptCopy -Path $file.FullName -TempDirectory $TempDirectory)) { continue }
        if ($KeepPath -and [string]::Equals($file.FullName, [IO.Path]::GetFullPath($KeepPath), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($file.LastWriteTimeUtc -gt $cutoff) { continue }
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ } catch { }
    }
    return $removed
}

# ==========================================
# BOOTSTRAP (own process + STA + a real file)
# ==========================================
# WPF needs an STA thread, and a GUI should own its process life. Two cases need a
# relaunch: started from a file on a non-STA host (PowerShell 7), or piped in with
# "irm ... | iex", where there is no file at all and the console belongs to the
# user's own terminal.
$global:ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($global:ScriptPath)) { $global:ScriptPath = $MyInvocation.MyCommand.Path }
# "iex" run from inside another script still reports that caller's file here, so
# only keep a path whose file really is this utility. Otherwise the app would
# think it lives elsewhere and would relaunch (as administrator) the wrong file.
if (-not [string]::IsNullOrWhiteSpace($global:ScriptPath)) {
    $ownSource = ''
    try { $ownSource = [IO.File]::ReadAllText($global:ScriptPath) } catch { $ownSource = '' }
    if (-not (Test-ScriptSourceLooksComplete $ownSource)) { $global:ScriptPath = '' }
}

$needsOwnProcess = [string]::IsNullOrWhiteSpace($global:ScriptPath)
$needsSta = [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'

if ($needsOwnProcess -or $needsSta) {
    $launchFile = $global:ScriptPath
    if ($needsOwnProcess) {
        # No file to point at. Save a complete copy to a temp file so the GUI can
        # run on its own (and later relaunch itself elevated) and the terminal keeps
        # its prompt. The published copy is fetched first, because the text we were
        # handed can be the wrong thing entirely; the handed text is only a fallback.
        $source = ''
        try { $source = ConvertTo-ScriptText (Invoke-WebRequest -Uri $ScriptRawUrl -UseBasicParsing -TimeoutSec 60).Content } catch { $source = '' }
        if (-not (Test-ScriptSourceLooksComplete $source)) {
            $source = ''
            try { $source = ConvertTo-ScriptText ($MyInvocation.MyCommand.ScriptBlock.ToString()) } catch { }
        }
        if (Test-ScriptSourceLooksComplete $source) {
            $launchFile = Join-Path ([IO.Path]::GetTempPath()) ('codhq-setup-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $source | Out-File -LiteralPath $launchFile -Encoding UTF8
            $global:ScriptPath = $launchFile
        } else {
            Write-Warning 'Could not obtain a complete copy of the setup utility; running it inside this session instead.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($launchFile)) {
        # Forward the parameters, otherwise a launch without -STA (double-click, "Run
        # with PowerShell") restarts the GUI and silently forgets the requested work.
        $forwarded = ''
        if ($PSBoundParameters.ContainsKey('RunDowngradeOnly')) { $forwarded += ' -RunDowngradeOnly' }
        if ($PSBoundParameters.ContainsKey('DowngradeMethod')) { $forwarded += " -DowngradeMethod $DowngradeMethod" }
        if (-not [string]::IsNullOrWhiteSpace($HandoffDirectory)) { $forwarded += ' -HandoffDirectory ' + (ConvertTo-QuotedArgument $HandoffDirectory) }
        if (-not [string]::IsNullOrWhiteSpace($GameFolder)) { $forwarded += ' -GameFolder ' + (ConvertTo-QuotedArgument $GameFolder) }
        if (-not [string]::IsNullOrWhiteSpace($Sandbox)) { $forwarded += ' -Sandbox ' + (ConvertTo-QuotedArgument $Sandbox) }
        Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launchFile`"$forwarded"
        return
    }
    # Could not prepare a relaunch: fall through and try to run here instead.
}

# This is the process that shows the window. Keep the script text in memory: if the
# temp copy disappears while the window is open (another run's cleanup, or a temp
# cleaner), the administrator relaunch writes it back from here.
$global:ScriptSourceText = ''
if (-not [string]::IsNullOrWhiteSpace($global:ScriptPath)) { $global:ScriptSourceText = $ownSource }
if (-not $RunDowngradeOnly) { $null = Remove-StaleScriptCopies -KeepPath $global:ScriptPath }

# ==========================================
# HIDE THE CONSOLE WINDOW (GUI ONLY)
# ==========================================
# The utility is a GUI, so the hosting console is hidden as soon as it starts.
# This is best-effort: hosting under Windows Terminal or an IDE uses a virtual
# console that has no window of its own, and nothing breaks when Hide() is a no-op.
function Hide-ConsoleWindow {
    try {
        if (-not ('CodebuffConsoleHost' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodebuffConsoleHost {
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static bool Hide() {
        IntPtr handle = GetConsoleWindow();
        if (handle == IntPtr.Zero) { return false; }
        return ShowWindow(handle, 0); // SW_HIDE
    }
}
'@ -ErrorAction Stop
        }
        [void][CodebuffConsoleHost]::Hide()
    } catch { }
}

# Only hide a console this script actually owns. With "irm ... | iex" the console
# belongs to the user's terminal, where hiding it would make their window vanish.
if (-not [string]::IsNullOrWhiteSpace($global:ScriptPath)) { Hide-ConsoleWindow }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ==========================================
# CONFIGURATION & VARIABLES
# ==========================================
$ErrorActionPreference = 'Stop'
$global:IsProcessing = $false

# $global:ScriptPath was captured in the bootstrap, before any handler can run:
# inside a WPF click handler $MyInvocation.MyCommand.Definition is the handler's own
# code block, not the file path, so elevation must use the bootstrap value.

# Folder chosen in this session (set even if writing the settings file fails).
$global:SessionGameFolder = $null

$AppId = '1938090'
$ReleaseTag = '1.0.0'
$ZipFileName = 'Call.of.Duty.Modern.Warfare.4.fix.v2.zip'
$ZipUrl = "https://github.com/LarkTheStar/fix-installer/releases/download/$ReleaseTag/$ZipFileName"
$LuaDownloadUrl = "https://github.com/LarkTheStar/fix-installer/releases/download/ManifestLua-1.0.0/1938090_25909941.lua"
$ZipDownloadUrl = "https://github.com/LarkTheStar/fix-installer/releases/download/ManifestLua-1.0.0/MW4_25909941_manifests.zip"
$TargetFileName     = "1938090.lua"
$SourceFileName     = "1938090_25909941.lua"
$SteamConfigSubPath = "config\stplug-in"
$AppManifestFile    = "appmanifest_1938090.acf"

# Remembered game folder, so a manual selection is reused next time the utility
# (or a later PowerShell session) starts.
$SettingsDirectory  = Join-Path $env:LOCALAPPDATA 'CallOfDutyHQ-SetupUtility'
$SettingsFile       = Join-Path $SettingsDirectory 'settings.json'

# Sandbox mode: everything is redirected into the sandbox folder before anything
# reads settings or looks for Steam. A folder without the marker is refused, so the
# switch can never be pointed at a real Steam or game folder by mistake.
$global:SandboxRoot = ''
if (-not [string]::IsNullOrWhiteSpace($Sandbox)) {
    $sandboxFull = ''
    try { $sandboxFull = [IO.Path]::GetFullPath($Sandbox.Trim().Trim('"')).TrimEnd('\') } catch { $sandboxFull = '' }
    if (-not $sandboxFull -or -not (Test-Path -LiteralPath (Join-Path $sandboxFull '.codhq-sandbox') -PathType Leaf)) {
        [void][System.Windows.MessageBox]::Show("Sandbox mode was requested, but this folder is not a sandbox (the .codhq-sandbox marker is missing):`n`n$Sandbox`n`nCreate one with tests\Start-Sandbox.ps1. The utility did not start.", 'Call of Duty MW4 Setup Utility', 'OK', 'Error')
        return
    }
    $global:SandboxRoot = $sandboxFull
    $SettingsDirectory = Join-Path $sandboxFull 'Settings'
    $SettingsFile = Join-Path $SettingsDirectory 'settings.json'
    # The sandbox's game folder, unless the starting window passed one.
    if ([string]::IsNullOrWhiteSpace($GameFolder)) { $GameFolder = Join-Path $sandboxFull 'Game' }
}

# Where worker.json, last-run.json and the downgrade logs go (see Get-HandoffDirectory).
# Worked out in a local first: when the script runs in the global scope (the
# in-session fallback), the parameter and the global are the same variable.
$handoffValue = ''
if (-not [string]::IsNullOrWhiteSpace($HandoffDirectory)) {
    try { if ([IO.Path]::IsPathRooted($HandoffDirectory)) { $handoffValue = [IO.Path]::GetFullPath($HandoffDirectory).TrimEnd('\') } }
    catch { $handoffValue = '' }
}
$global:HandoffDirectory = $handoffValue
# The game folder the starting window used; Resolve-GameFolderQuiet and
# Select-TargetFolder take it before the (possibly different account's) settings.
if (-not [string]::IsNullOrWhiteSpace($GameFolder)) {
    $passedFolder = $null
    try { $passedFolder = [IO.Path]::GetFullPath($GameFolder.Trim().Trim('"')).TrimEnd('\') }
    catch { $passedFolder = $null }
    if ($passedFolder -and (Test-Path -LiteralPath $passedFolder -PathType Container)) { $global:SessionGameFolder = $passedFolder }
}

# ==========================================
# THEMES
# ==========================================
# Every semantic colour used by the window, the prompt dialogs, the status pill
# and the activity log lives here. The XAML ships the dark values; switching
# themes replaces the window's brush resources in place, and DynamicResource
# references update live.
$ThemePalettes = @{
    dark = @{
        BgDark = '#0B0B0E'; BgSidebar = '#08080A'; BgCard = '#15151E'; BgCardHover = '#1E1E2B'
        Accent = '#00A8FF'; AccentHover = '#33BFFF'; AccentPressed = '#0088CC'
        TextPrimary = '#FFFFFF'; TextSecondary = '#A0A0B0'; TextMuted = '#606070'
        Green = '#4EC9B0'; Red = '#FF4D4D'; Yellow = '#FFD700'; Magenta = '#C586C0'
        Border = '#2A2A35'; InputBg = '#0B0B0E'; PopupBg = '#15151E'
        PopupItemHover = '#1E1E2B'; PopupItemSelected = '#16283A'; PopupArrow = '#8A8A9A'
        ScrollThumb = '#3A3A4A'; ScrollThumbHover = '#5A5A70'
        CardHoverDanger = '#2A1515'; HintBg = '#101018'
        ButtonBg = '#24242F'; ButtonHoverBg = '#2E2E3C'; ButtonPressedBg = '#1B1B25'; ButtonBorder = '#33333F'
        SmallButtonBg = '#1B1B26'; SmallButtonText = '#D8D8E4'; TextOnAccent = '#FFFFFF'
        StatusReadyBg = '#152A22'; StatusReadyBorder = '#2D4B3A'
        StatusBusyBg = '#15202A'; StatusBusyBorder = '#2D3F4B'
        StatusFailedBg = '#2A1515'; StatusFailedBorder = '#4B2D2D'
        StatusCancelledBg = '#2A2615'; StatusCancelledBorder = '#4B452D'
    }
    light = @{
        BgDark = '#F5F6F8'; BgSidebar = '#ECEEF2'; BgCard = '#FFFFFF'; BgCardHover = '#F0F3F7'
        Accent = '#0A84D0'; AccentHover = '#0F98E8'; AccentPressed = '#086AA8'
        TextPrimary = '#16161C'; TextSecondary = '#4E5460'; TextMuted = '#7A828E'
        Green = '#178A6E'; Red = '#C62F2F'; Yellow = '#8A6D00'; Magenta = '#8A3FA0'
        Border = '#DCDFE6'; InputBg = '#F2F4F7'; PopupBg = '#FFFFFF'
        PopupItemHover = '#EEF3F8'; PopupItemSelected = '#DCEBF8'; PopupArrow = '#7A828E'
        ScrollThumb = '#C4C9D2'; ScrollThumbHover = '#A9B0BC'
        CardHoverDanger = '#FBE9E9'; HintBg = '#F7F8FA'
        ButtonBg = '#EFF1F5'; ButtonHoverBg = '#E4E8EE'; ButtonPressedBg = '#D8DDE5'; ButtonBorder = '#D5DAE2'
        SmallButtonBg = '#FFFFFF'; SmallButtonText = '#2B3039'; TextOnAccent = '#FFFFFF'
        StatusReadyBg = '#E7F5F0'; StatusReadyBorder = '#BFE3D7'
        StatusBusyBg = '#E8F3FC'; StatusBusyBorder = '#BEDDF6'
        StatusFailedBg = '#FCEBEB'; StatusFailedBorder = '#F3C7C7'
        StatusCancelledBg = '#FBF4DE'; StatusCancelledBorder = '#EBDCA8'
    }
}

# Accent presets: layered on top of whichever theme is active, so every preset
# works in both dark and light mode. Dark/Light are @(Accent, AccentHover, AccentPressed).
$AccentPresets = [ordered]@{
    Steam   = @{ Label = 'Steam blue'; Swatch = '#00A8FF'; Dark = @('#00A8FF', '#33BFFF', '#0088CC'); Light = @('#0A84D0', '#0F98E8', '#086AA8') }
    Teal    = @{ Label = 'Teal';       Swatch = '#12B5A0'; Dark = @('#12B5A0', '#38D6C1', '#0E8F7F'); Light = @('#0C8C7C', '#11A896', '#076A5E') }
    Violet  = @{ Label = 'Violet';     Swatch = '#8B7BFF'; Dark = @('#8B7BFF', '#A79AFF', '#6F5FE0'); Light = @('#6C57D8', '#8875EA', '#523FBD') }
    Amber   = @{ Label = 'Amber';      Swatch = '#F2A03D'; Dark = @('#F2A03D', '#FFB75E', '#CE8427'); Light = @('#B26C10', '#CC8120', '#8C540B') }
    Crimson = @{ Label = 'Crimson';    Swatch = '#F2586C'; Dark = @('#F2586C', '#FF7387', '#CC4054'); Light = @('#C22F44', '#DB4358', '#9C2338') }
}

$global:ThemeName = 'dark'
$global:AccentName = 'Steam'
$global:ReduceMotion = $false
$global:StatusState = 'Ready'
$global:GameCardState = $null
$global:CurrentPage = 0
$global:LogEntries = [System.Collections.Generic.List[object]]::new()
$global:LogFilter = 'all'
$global:LogAutoScroll = $true
# A long downgrade can out-log the screen many times over, so the transcript is
# capped; Save says so in its header when lines were dropped.
$global:LogMaxLines = 5000
$global:LogTrimmed = $false
$global:LastUiPumpUtc = [DateTime]::MinValue
$global:IsUiPumping = $false
$global:SuppressUiPump = $false
# Set right before a Close() the app itself initiates (the elevation hand-off), so
# the "do not close while working" guard does not block it.
$global:AllowProgrammaticClose = $false
$global:StatusPulseTriggers = $null
# Watchdog for the elevation hand-off (see Start-WorkerWatcher).
$global:WorkerWatcher = $null
$global:WorkerWatcherPid = 0
$global:WorkerWatcherFallbackPid = 0
$global:WorkerWatcherAnnounced = $false
$global:WorkerWatcherMethod = 'Normal'
$global:WorkerWatcherStartedAt = [DateTime]::MinValue

$codDepotIds = "1938091 1938092 1938093 1938094 1938095 1938096 1938097 1938098 1938099 1962660 1962661 1962662 1962663 1962664 1962665 1962666 1962667 1962668 1962669 2014030 2014031 2014032 2014033 2014034 2014035 2014036 2014037 2014038 2014039 2014040 2014041 2014042 2014043 2014044 2014045 2014046 2014047 2014048 2014049 2014050 2014051 2014052 2014053 2014054 2014055 2014056 2014057 2014058 2014059 2014060 2014061 2014062 2014063 2014064 2014065 2014066 2014067 2014068 2014069 2014070 2014071 2014072 2014073 2014074 2014075 2014076 2014077 2014078 2014079 2014080 2014081 2014082 2014083 2014084 2014085 2014086 2014087 2014088 2014089 2014261 2014262 2014263 2014264 2014265 2014266 2014267 2014268 2014269 2021992 2021993 2021994 2021995 2021996 2021997 2021998 2021999 2053672 2053673 2053674 2053675 2053676 2053677 2053678 2053679 2062851 2062852 2062853 2062854 2062855 2062856 2062857 2062858 2062859 2120531 2120532 2120533 2120534 2120535 2120536 2120537 2120538 2120539 2127792 2127793 2127794 2127795 2127796 2127797 2127798 2127799 2134251 2134252 2134253 2134254 2134255 2134256 2134257 2134258 2134259 2137911 2137912 2137913 2137914 2137915 2137916 2137917 2137918 2137919 2139273 2139274 2139275 2139276 2139277 2139278 2139279 2170979 2228971 2228972 2228973 2228974 2228975 2228976 2228977 2228978 2228979 2278281 2278282 2278283 2278284 2278285 2278286 2278287 2278288 2278289 2316851 2519060 2625839 2790671 2790672 2790673 2790674 2790675 2790676 2790677 2790678 2790679 2790690 2790691 2790692 2790693 2790694 2790695 2790696 2790697 2790698 2790699 3180215 3180216 3180217 3180218 3180219 3203381 3203382 3203383 3203384 3203385 3203386 3203387 3203388 3203389 3203391 3203392 3203393 3203394 3203395 3203396 3203397 3203398 3203399 3203401 3203402 3203403 3203404 3203405 3203406 3203407 3203408 3203409 3203411 3203412 3203413 3203414 3203415 3203416 3203417 3203418 3203419 4085076 4085077 4085078 4085079 4085081 4085082 4085083 4085084 4085085 4085086 4085087 4085088 4085089 4085091 4085092 4085093 4085094 4085095 4085096 4085097 4085098 4085099 4085111 4085112 4085113 4085114 4085115 4085116 4085117 4085118 4085119 4085121 4085122 4085123 4085124 4085125 4085126 4085127 4085128 4085129 4085131 4085132 4085133 4085134 4085135 4085136 4085137 4085138 4085139 4098661 4098662 4098663 4098664 4098665 4098666 4098667 4098668 4098669 4435490 4435500 4435510 5092423 5092424 5092425 5092426 5092427 5092428 5092429 5092431 5092432 5092433 5092434 5092435 5092436 5092437 5092438 5092439 5092441 5092442 5092443 5092444 5092445 5092446 5092447 5092448 5092449 5092461 5092462 5092463 5092464 5092465 5092466 5092467 5092468 5092469 5092491 5092492 5092493 5092494 5092495 5092496 5092497 5092498 5092499 5092511 5092512 5092513 5092514 5092515 5092516 5092517 5092518 5092519 5177101 5177102 5177103 5177104 5177105 5177106 5177107 5177108 5177109" -split ' '

# ==========================================
# FUNCTIONS
# ==========================================
function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Ok([string]$Message) { Write-Host "[OK]   $Message" -ForegroundColor Green }
function Stop-Installer([string]$Message) { throw $Message }

# A user-driven cancel is not a failure. It is reported neutrally by the GUI so
# answering "No" never looks like a crash.
function Stop-Cancelled([string]$Message = 'Installation cancelled.') { throw [System.OperationCanceledException]::new($Message) }

# Stops a Windows service without letting sc.exe write to the real console.
# A service that is already stopped makes sc print "ControlService FAILED 1062",
# which used to leak into a visible PowerShell window; output is captured and
# discarded here, and failures are non-fatal just like before.
function Stop-ServiceQuietly {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $env:SystemRoot 'System32\sc.exe'
        $startInfo.Arguments = "stop `"$Name`""
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $null = $process.StandardOutput.ReadToEnd()
            $null = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
        } finally { $process.Dispose() }
    } catch { }
}

function Add-UniquePath {
    param([System.Collections.Generic.List[string]]$List, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (Test-Path -LiteralPath $expanded -PathType Container) {
        $full = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
        foreach ($existing in $List) { if ($existing.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { return } }
        $List.Add($full)
    }
}

function Get-SteamLibraries {
    $libraries = [System.Collections.Generic.List[string]]::new()
    # Sandbox mode only ever looks at the sandbox's fake Steam folder.
    if (Test-SandboxMode) {
        Add-UniquePath $libraries (Join-Path $global:SandboxRoot 'Steam')
        return $libraries.ToArray()
    }
    $registryKeys = @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')
    foreach ($key in $registryKeys) {
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if ($item.SteamPath) { Add-UniquePath $libraries $item.SteamPath }
            if ($item.InstallPath) { Add-UniquePath $libraries $item.InstallPath }
        } catch {}
    }
    Add-UniquePath $libraries "${env:ProgramFiles(x86)}\Steam"
    Add-UniquePath $libraries "$env:ProgramFiles\Steam"
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
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($library in (Get-SteamLibraries)) {
        $manifest = Join-Path $library "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $contents = Get-Content -LiteralPath $manifest -Raw
        $installMatch = [regex]::Match($contents, '"installdir"\s*"([^"]+)"')
        if (-not $installMatch.Success) { continue }
        $installDir = $installMatch.Groups[1].Value
        if ([IO.Path]::IsPathRooted($installDir) -or $installDir.Contains('..') -or $installDir.Contains(':')) { continue }
        $candidate = [IO.Path]::GetFullPath((Join-Path $library "steamapps\common\$installDir"))
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            if (-not ($found | Where-Object { $_.Equals($candidate, [StringComparison]::OrdinalIgnoreCase) })) { $found.Add($candidate) }
        }
    }
    return $found.ToArray()
}

# ------------------------------------------
# Settings (game folder, theme, window state)
# ------------------------------------------
function New-DefaultSettings {
    [pscustomobject]@{
        GameFolder = ''
        Theme = 'dark'
        Accent = 'Steam'
        ReduceMotion = $false
        WindowWidth = 0
        WindowHeight = 0
        WindowLeft = 0
        WindowTop = 0
        WindowMaximized = $false
        LastPage = 0
        # Games page: one remembered folder per catalogue game (id -> folder), and the
        # player name passed to the clients that take one.
        Games = [pscustomobject]@{}
        PlayerName = ''
        # Games page: check and install client updates when the page opens and before Play.
        AutoUpdateClients = $false
        SavedAt = ''
        AppId = $AppId
    }
}

function Get-AppSettings {
    $settings = New-DefaultSettings
    try {
        if (Test-Path -LiteralPath $SettingsFile -PathType Leaf) {
            $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            foreach ($name in @('GameFolder', 'Theme', 'Accent', 'ReduceMotion', 'WindowWidth', 'WindowHeight', 'WindowLeft', 'WindowTop', 'WindowMaximized', 'LastPage', 'Games', 'PlayerName', 'AutoUpdateClients')) {
                $property = $saved.PSObject.Properties[$name]
                if ($null -ne $property -and $null -ne $property.Value) { $settings.$name = $property.Value }
            }
        }
    } catch { }
    return $settings
}

function Save-AppSettings {
    param([Parameter(Mandatory)]$Settings)
    $tempFile = $null
    try {
        if (-not (Test-Path -LiteralPath $SettingsDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $SettingsDirectory -Force }
        $Settings.SavedAt = (Get-Date).ToString('o')
        $Settings.AppId = $AppId
        $tempFile = "$SettingsFile.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($tempFile, ($Settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempFile -Destination $SettingsFile -Force -ErrorAction Stop
        return $true
    } catch {
        if ($tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        Write-Warn "Could not save settings: $($_.Exception.Message)"
        return $false
    }
}

# Returns the remembered game folder, or $null when there is no valid saved one.
function Get-SavedGameFolder {
    try {
        $folder = [string](Get-AppSettings).GameFolder
        if ([string]::IsNullOrWhiteSpace($folder)) { return $null }
        $folder = [IO.Path]::GetFullPath($folder.Trim().Trim('"')).TrimEnd('\')
        if (Test-Path -LiteralPath $folder -PathType Container) { return $folder }
    } catch { }
    return $null
}

# Persists the selected game folder for later runs. Returns $true on success.
function Save-GameFolder {
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $folder = [IO.Path]::GetFullPath($Folder.Trim().Trim('"')).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "The folder does not exist: $folder" }
        $settings = Get-AppSettings
        $settings.GameFolder = $folder
        if (Save-AppSettings -Settings $settings) {
            $global:SessionGameFolder = $folder
            return $true
        }
        return $false
    } catch {
        Write-Warn "Could not save the game folder: $($_.Exception.Message)"
        return $false
    }
}

function Get-SavedTheme {
    $theme = [string](Get-AppSettings).Theme
    if ($ThemePalettes.ContainsKey($theme)) { return $theme }
    return 'dark'
}

function Save-ThemeChoice {
    param([string]$Name)
    if (-not $ThemePalettes.ContainsKey($Name)) { return $false }
    $settings = Get-AppSettings
    $settings.Theme = $Name
    return (Save-AppSettings -Settings $settings)
}

function Get-SavedAccent {
    $accent = [string](Get-AppSettings).Accent
    if ($AccentPresets.Contains($accent)) { return $accent }
    return 'Steam'
}

function Save-AccentChoice {
    param([string]$Name)
    if (-not $AccentPresets.Contains($Name)) { return $false }
    $settings = Get-AppSettings
    $settings.Accent = $Name
    return (Save-AppSettings -Settings $settings)
}

function Get-SavedMotionPreference {
    try { return [bool](Get-AppSettings).ReduceMotion } catch { return $false }
}

function Save-MotionChoice {
    param([bool]$Reduce)
    $settings = Get-AppSettings
    $settings.ReduceMotion = $Reduce
    return (Save-AppSettings -Settings $settings)
}

function Save-WindowPreferences {
    param([int]$Page, [double]$Width, [double]$Height, [double]$Left, [double]$Top, [bool]$Maximized)
    $settings = Get-AppSettings
    $settings.LastPage = $Page
    $settings.WindowMaximized = $Maximized
    if (-not $Maximized -and $Width -gt 0 -and $Height -gt 0) {
        $settings.WindowWidth = $Width
        $settings.WindowHeight = $Height
        $settings.WindowLeft = $Left
        $settings.WindowTop = $Top
    }
    return (Save-AppSettings -Settings $settings)
}

# ------------------------------------------
# Theme colour lookup
# ------------------------------------------
function Get-ThemeColor {
    param([string]$Key)
    $palette = $ThemePalettes[$global:ThemeName]
    if ($null -eq $palette) { $palette = $ThemePalettes['dark'] }
    if ($palette.ContainsKey($Key)) { return [string]$palette[$Key] }
    return '#FF00FF'
}

function Get-ThemeBrush {
    param([string]$Key)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString((Get-ThemeColor $Key))
}

# Older call sites pass the original dark palette hex values; map them to semantic
# keys so the activity log stays readable in both themes.
$LogColorAliases = @{
    '#A0A0B0' = 'TextSecondary'
    '#606070' = 'TextMuted'
    '#FFFFFF' = 'TextPrimary'
    '#4EC9B0' = 'Green'
    '#FF4D4D' = 'Red'
    '#FFD700' = 'Yellow'
    '#00A8FF' = 'Accent'
    '#33BFFF' = 'AccentHover'
    '#C586C0' = 'Magenta'
    '#B5CEA8' = 'Yellow'
}

function Resolve-ThemeColor {
    param([string]$Color)
    if ([string]::IsNullOrWhiteSpace($Color)) { return (Get-ThemeColor 'TextSecondary') }
    $key = $Color.ToUpperInvariant()
    if ($LogColorAliases.ContainsKey($key)) { return (Get-ThemeColor $LogColorAliases[$key]) }
    return $Color
}

# ------------------------------------------
# Game folder shape check (used for manual picks)
# ------------------------------------------
# Best-effort check for files a Call of Duty HQ install normally contains. It does
# not inspect Steam manifests or block anything: it only produces a warning the
# user can override.
function Test-GameFolder {
    param([Parameter(Mandatory)][string]$Folder)
    $checks = @(
        @{ Relative = '!start_sp26.bat'; Label = '!start_sp26.bat' },
        @{ Relative = 'sp26\steam_settings\configs.user.ini'; Label = 'sp26\steam_settings\configs.user.ini' },
        @{ Relative = 'sp26'; Label = 'sp26 folder' },
        @{ Relative = 'cod.exe'; Label = 'cod.exe' },
        @{ Relative = 'steam_api64.dll'; Label = 'steam_api64.dll' }
    )
    $found = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $full = $Folder
    try { $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\') } catch { }
    foreach ($check in $checks) {
        if (Test-Path -LiteralPath (Join-Path $full $check.Relative)) { $found.Add($check.Label) }
        else { $missing.Add($check.Label) }
    }
    $leaf = ''
    try { $leaf = Split-Path -Leaf $full } catch { }
    $looksValid = ($found.Count -gt 0) -or ($leaf -eq 'Call of Duty HQ')
    return [pscustomobject]@{
        Folder = $full
        LooksValid = $looksValid
        Found = @($found.ToArray())
        Missing = @($missing.ToArray())
        Leaf = $leaf
    }
}

function Select-TargetFolder {
    # A folder the user picked earlier wins over detection, so the prompt only
    # appears when nothing has been saved yet (or the saved folder is gone).
    if ($global:SessionGameFolder -and (Test-Path -LiteralPath $global:SessionGameFolder -PathType Container)) {
        Write-Info 'Using your selected game folder:'
        Write-Host "  $global:SessionGameFolder"
        return $global:SessionGameFolder
    }
    $saved = Get-SavedGameFolder
    if ($saved) {
        Write-Info 'Using your saved game folder:'
        Write-Host "  $saved"
        return $saved
    }

    $found = @(Find-CallOfDutyHQ)
    if ($found.Count -eq 1) {
        $target = $found[0]
        Write-Info "Detected Steam Call of Duty HQ installation:"
        Write-Host "  $target"
        $answer = Read-Host "Detected path:`n$target`n`nUse this folder? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(y|yes)$') {
            $null = Save-GameFolder -Folder $target
            return $target
        }
    } elseif ($found.Count -gt 1) {
        Write-Info 'Multiple Call of Duty HQ installations were found:'
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Host "  [$($i + 1)] $($found[$i])" }
        while ($true) {
            $choice = Read-Host "Choose a folder (1-$($found.Count)), or enter a different path"
            if ([string]::IsNullOrWhiteSpace($choice)) { Stop-Cancelled 'Installation cancelled.' }
            $number = 0
            if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $found.Count) {
                $null = Save-GameFolder -Folder $found[$number - 1]
                return $found[$number - 1]
            }
            if (Test-Path -LiteralPath $choice -PathType Container) {
                $chosen = [IO.Path]::GetFullPath($choice)
                $null = Save-GameFolder -Folder $chosen
                return $chosen
            }
            Write-Warn 'That selection is not a valid folder.'
        }
    } else {
        Write-Warn "Could not automatically locate appmanifest_$AppId.acf and its install folder."
        Write-Info 'Pick your Call of Duty HQ folder in the window that opens; it will be remembered.'
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the Call of Duty HQ game folder"
    $dialog.ShowNewFolderButton = $false
    
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $full = [IO.Path]::GetFullPath($dialog.SelectedPath)
        $layout = Test-GameFolder -Folder $full
        if (-not $layout.LooksValid) {
            $missing = ($layout.Missing -join ', ')
            $confirm = Read-Host "This folder doesn't look like Call of Duty HQ:`n$full`n`nNone of these were found: $missing`n`nUse it anyway? [y/N]"
            if ($confirm -notmatch '^(y|yes)$') { Stop-Cancelled 'Installation cancelled.' }
        }
        $null = Save-GameFolder -Folder $full
        return $full
    } else {
        Stop-Cancelled 'Installation cancelled.'
    }
}

function Get-ValidatedRelativePath([string]$EntryName) {
    $name = $EntryName -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($name)) { Stop-Installer 'ZIP contains an empty path.' }
    if ($name.StartsWith('\') -or [IO.Path]::IsPathRooted($name) -or $name -match '^[A-Za-z]:') { Stop-Installer "ZIP contains an absolute path: $EntryName" }
    $segments = $name.Split('\')
    foreach ($segment in $segments) {
        if ($segment -eq '..' -or $segment -eq '.' -or $segment.Contains(':') -or $segment.EndsWith(' ') -or $segment.EndsWith('.')) { Stop-Installer "ZIP contains an unsafe path: $EntryName" }
        if ($segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') { Stop-Installer "ZIP contains a reserved Windows filename: $EntryName" }
    }
    if ($name -match '^(?i:og files|language files)(\\|$)') { Stop-Installer "ZIP attempts to write into the reserved backup folder: $EntryName" }
    return $name
}

# SHA-256 of every file this utility downloads from its own GitHub releases, as
# published by GitHub for each asset. A download that does not match is deleted and
# nothing is installed from it. When a release asset is replaced, its hash here
# must be updated in the same change: tools\Get-ReleaseHashes.ps1 prints this table.
function Get-ReleaseAssetHash {
    param([string]$Name)
    $hashes = @{
        'Call.of.Duty.Modern.Warfare.4.fix.v2.zip' = '99f1a58eac2122dcbb7a2e06423536585d0c9f23815e46bf48f428b075450008'
        '1938090_25909941.lua'                     = 'e7e9434b627818b65bc58bebc31e6449fced4c6cf3667cae776c061342e75c0b'
        'MW4_25909941_manifests.zip'               = 'c2add7096149c5a316fa822cd2e2faca54b29b8c27191144f47ed68072884e3f'
        'Arabic.zip'                               = '1b3bf77c7de72a58b245b174c1dfeb9e1ebe6a8c89a5656bd4af2dfee0b6acb2'
        'French.zip'                               = '3e0ac31f3710a5a94bc9f96ee264e6908dc41fbbf3de0de509bcfc00f13962cd'
        'German.zip'                               = 'c18ede4328f88eafd7e222572900cc451c1ce5c6172f7a615f978a2d9e504a0c'
        'Italian.zip'                              = '72792f4dd5fa7ea47f9540a4a046470955a9e4b95c25afd0061ccf35cd9acd37'
        'Japanese.zip.part001'                     = 'fe736e45c252034b657accc9e43ba25fc15579367547803da9c63c6c561d728b'
        'Japanese.zip.part002'                     = '48499f052f2aa0b242664fde155975948e98a89b093e4737a2a98d024053085c'
        'Korean.zip.part001'                       = '2b7a788d985baadec96a52e3bddd640b8d40fe551c802f585d9cd93cc0fca639'
        'Korean.zip.part002'                       = 'cfc1f94027dee87c7d898c811c18472607632c0f26ea8718e1a4660f39d4b575'
        'Polish.zip'                               = 'b944eebe0b5ecf48451ba99f1863dcfef874bd815d7fcb3794082161239df3bb'
        'Portuguese.-.Brazil.zip'                  = 'e90c6c0cd1a963583e50239cd9d7103e767d38ac5bff240ed76ecfb03ce57f6c'
        'Russian.zip'                              = '48b095e1635a9fc3ce1adfedd58c1e99dd7166f3156aa62b389e1f05da6be50d'
        'Simplified-Chinese.zip.part001'           = '53a56a847fef8c0599abe4a3e13632906672e480f088b5ba7a02fb719de504a5'
        'Simplified-Chinese.zip.part002'           = '1fb012fe2c9f9942bb9aac3a0e5a4cb27aab7421b9f932db667cd8149c4277a6'
        'Spanish.-.Latin.America.zip'              = 'c6492979b7b12db64e3bcbc1f86c24e86e79ef68b1fca1aedb1d42fca260fda0'
        'Spanish.-.Spain.zip'                      = '8aa1cb521fa133fb294655b1c2d33930bd7cba02ed5642cb03219b59c6b5b5d7'
        'Traditional.Chinese.zip'                  = '9d59c3a4c66f4253e7a243aeb6aca15de6dbce65939e937996d5758fd7268748'
    }
    if ([string]::IsNullOrWhiteSpace($Name) -or -not $hashes.ContainsKey($Name)) { return '' }
    return [string]$hashes[$Name]
}

# Downloads from this repository's releases must have a pinned hash; anything else
# (there is nothing else today) is downloaded unchecked.
function Get-ExpectedDownloadHash {
    param([Parameter(Mandatory)][string]$Url)
    $releasePrefix = 'https://github.com/LarkTheStar/fix-installer/releases/download/'
    if (-not $Url.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $assetName = [Uri]::UnescapeDataString(($Url -split '/')[-1])
    $hash = Get-ReleaseAssetHash $assetName
    if (-not $hash) { throw "No pinned checksum is known for the release file '$assetName', so it was not downloaded. Update the utility, or add the file's SHA-256 to Get-ReleaseAssetHash." }
    return $hash
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# One attempt at a download. With -ResumeFrom it asks the server for the rest of
# the file only (an HTTP Range request) and appends to what is already on disk; a
# server that ignores the range sends the whole file, which then starts over. A
# partial file is left on disk for the next attempt to continue from.
function Receive-DownloadAttempt {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [string]$UserAgent = 'CallOfDutyHQ-SetupUtility/1.1',
        [int64]$ResumeFrom = 0
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.UserAgent = $UserAgent
    # A connection that stalls without closing counts as a failure after 2 minutes,
    # instead of hanging the window for good.
    $request.ReadWriteTimeout = 120000
    if ($ResumeFrom -gt 0) { $request.AddRange([int64]$ResumeFrom) }
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        try { $response = $request.GetResponse() }
        catch [System.Net.WebException] {
            $status = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            # 416: the range is past the end (the file on disk is already complete or
            # wrong). Start the next attempt from scratch.
            if ($ResumeFrom -gt 0 -and $status -eq 416) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            # 404/410: the file is gone; trying again cannot help.
            if ($status -eq 404 -or $status -eq 410) {
                $gone = [System.Exception]::new("The file is no longer published at $Url (HTTP $status).", $_.Exception)
                $gone.Data['NoRetry'] = $true
                throw $gone
            }
            # 429 and 5xx: busy or failing server; a Retry-After header says how long to wait.
            if ($status -eq 429 -or ($status -ge 500 -and $status -le 599)) {
                $busy = [System.Exception]::new("The server answered HTTP $status for $Url.", $_.Exception)
                $retryAfter = 0
                if ([int]::TryParse([string]$_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) -and $retryAfter -gt 0) { $busy.Data['RetryAfter'] = [Math]::Min($retryAfter, 60) }
                throw $busy
            }
            throw
        }
        $resuming = ($ResumeFrom -gt 0 -and [int]$response.StatusCode -eq 206)
        if (-not $resuming) { $ResumeFrom = 0 }
        $total = if ([int64]$response.ContentLength -gt 0) { $ResumeFrom + [int64]$response.ContentLength } else { [int64]-1 }
        $inputStream = $response.GetResponseStream()
        $mode = if ($resuming) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $outputStream = [System.IO.File]::Open($Destination, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (1024 * 1024)
        [int64]$downloaded = $ResumeFrom; $lastPercent = -1
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($total -gt 0) {
                $percent = [int][Math]::Min(100, [Math]::Floor(($downloaded * 100.0) / $total))
                $downloadedMB = [Math]::Round($downloaded / 1MB, 1)
                $totalMB = [Math]::Round($total / 1MB, 1)
                if ($percent -ne $lastPercent) { Write-Progress -Activity $Label -Status "$downloadedMB MB of $totalMB MB ($percent%)" -PercentComplete $percent; $lastPercent = $percent }
            } else { Write-Progress -Activity $Label -Status ([string]::Format([cultureinfo]::InvariantCulture, 'Downloaded {0:N1} MB', ($downloaded / 1MB))) -PercentComplete 0 }
        }
        $outputStream.Flush()
        # A dropped connection ends the read loop quietly, so check the size here;
        # otherwise a truncated file would count as a successful download.
        if ($downloaded -le 0) { throw "The server returned an empty download: $Url" }
        if ($total -gt 0 -and $downloaded -ne $total) { throw "Download appears incomplete: received $downloaded of $total bytes." }
        return $downloaded
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

# Downloads with up to -MaxAttempts tries. After a failure the next try continues
# from the bytes already received, so a dropped connection near the end of a
# multi-gigabyte language pack does not start it over. The finished file is then
# checked against its pinned SHA-256 (see Get-ReleaseAssetHash); a mismatch deletes
# it and fails. Returns the size in bytes. On failure a partial file may remain;
# the callers below delete it.
function Invoke-ResumableDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [string]$ExpectedSha256 = $null,
        # CB's client manifests publish SHA-1 only; checked in addition to any SHA-256.
        [string]$ExpectedSha1 = '',
        [string]$UserAgent = 'CallOfDutyHQ-SetupUtility/1.1',
        [int]$MaxAttempts = 4,
        [int]$RetryDelaySeconds = 3,
        # Returns size, SHA-256 and SHA-1 instead of the size alone (for install records).
        [switch]$PassThru
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'TLS 1.2 could not be selected; using the system default.' }
    if (-not $PSBoundParameters.ContainsKey('ExpectedSha256')) { $ExpectedSha256 = Get-ExpectedDownloadHash -Url $Url }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
    $attempt = 0
    $bytes = [int64]0
    while ($true) {
        $attempt++
        $resumeFrom = [int64]0
        if (Test-Path -LiteralPath $Destination -PathType Leaf) { $resumeFrom = [int64](Get-Item -LiteralPath $Destination).Length }
        try {
            $bytes = Receive-DownloadAttempt -Url $Url -Destination $Destination -Label $Label -UserAgent $UserAgent -ResumeFrom $resumeFrom
            break
        } catch {
            if ($_.Exception.Data['NoRetry'] -eq $true) { throw }
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warn ([string]::Format([cultureinfo]::InvariantCulture, 'Download interrupted ({0}). Trying again ({1} of {2}), continuing from the {3:N1} MB already received...', $_.Exception.Message, ($attempt + 1), $MaxAttempts, ($(if (Test-Path -LiteralPath $Destination -PathType Leaf) { (Get-Item -LiteralPath $Destination).Length } else { 0 }) / 1MB)))
            $retryAfter = $_.Exception.Data['RetryAfter']
            if ($null -ne $retryAfter) { Start-Sleep -Seconds ([int]$retryAfter) }
            elseif ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds ($RetryDelaySeconds * $attempt) }
        }
    }
    $sha256 = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -or $PassThru) { $sha256 = Get-FileSha256 -Path $Destination }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $sha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "The downloaded file does not match its published checksum (expected SHA-256 $ExpectedSha256, got $sha256). It was deleted and nothing was installed from it."
    }
    $sha1 = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha1) -or $PassThru) { $sha1 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA1).Hash.ToUpperInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha1) -and $sha1 -ne $ExpectedSha1.ToUpperInvariant()) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "The downloaded file does not match its manifest (expected SHA-1 $ExpectedSha1, got $sha1). It was deleted and nothing was installed from it."
    }
    if ($PassThru) { return [pscustomobject]@{ Bytes = $bytes; Sha256 = $sha256; Sha1 = $sha1 } }
    return $bytes
}

# CB's client update sources, in the launcher's own order: its CDN mirrors (North
# America, then Europe), then GitHub as the last resort.
function Get-ClientUpdateSource {
    return @('https://cdn-na.cbservers.xyz/updater/', 'https://cdn-eu.cbservers.dev/updater/', 'https://github.com/CBServers/updater/raw/main/updater/')
}

# Reads a CB client manifest ([path, size, sha1, dest?] entries plus an optional
# {ManifestHash}) from the first source that answers, checking every entry. Returns
# the entries, the ManifestHash and the base URL it came from (files are fetched from
# the same base first).
function Get-ClientManifest {
    param([Parameter(Mandatory)][string]$Manifest, [string[]]$Bases = @(Get-ClientUpdateSource))
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($base in $Bases) {
        try {
            $url = $base + $Manifest + '?' + [DateTime]::UtcNow.Ticks
            $raw = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'CallOfDutyHQ-SetupUtility/1.1' } -TimeoutSec 60
            # Mirrors differ in the content type they send, so text or bytes may come
            # back unparsed.
            if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
            if ($raw -is [string]) { $raw = ConvertFrom-Json -InputObject $raw.TrimStart([char]0xFEFF) }
            $items = @($raw)
            $entries = [System.Collections.Generic.List[object]]::new()
            $manifestHash = ''
            foreach ($item in $items) {
                if ($item -is [array] -or ($item -is [System.Collections.IList] -and $item -isnot [string])) {
                    if ($item.Count -lt 3) { throw "An entry has fewer than three fields." }
                    $path = [string]$item[0]
                    $null = Get-ValidatedRelativePath $path
                    $size = [int64]$item[1]
                    $sha1 = ([string]$item[2]).ToUpperInvariant()
                    if ($size -lt 0) { throw "Negative size for $path." }
                    if ($sha1 -notmatch '^[0-9A-F]{40}$') { throw "Bad SHA-1 for $path." }
                    $dest = if ($item.Count -gt 3) { [string]$item[3] } else { '' }
                    if ($dest -and $dest -notin @('game', 'appdata')) { throw "Unknown destination '$dest' for $path." }
                    $entries.Add([pscustomobject]@{ Path = ($path -replace '\\', '/'); Size = $size; Sha1 = $sha1; Dest = $dest })
                } elseif ($null -ne $item -and $null -ne $item.ManifestHash) {
                    $manifestHash = [string]$item.ManifestHash
                }
            }
            if ($entries.Count -eq 0) { throw 'The manifest lists no files.' }
            return [pscustomobject]@{ Name = $Manifest; Base = $base; Entries = $entries.ToArray(); ManifestHash = $manifestHash }
        } catch {
            $errors.Add("$base$Manifest : $($_.Exception.Message)")
        }
    }
    throw ("Could not read the client manifest $Manifest from any source:`n  " + ($errors -join "`n  "))
}

function Download-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [int]$RetryDelaySeconds = 3
    )
    try {
        $expected = Get-ExpectedDownloadHash -Url $Url
        $downloaded = Invoke-ResumableDownload -Url $Url -Destination $Destination -Label $Label -ExpectedSha256 $expected -RetryDelaySeconds $RetryDelaySeconds
        Write-Progress -Activity $Label -Completed
        Write-Ok ([string]::Format([cultureinfo]::InvariantCulture, 'Download complete: {0:N1} MB', ($downloaded / 1MB)))
        if ($expected) { Write-Ok 'Checksum verified: the file matches the published release.' }
    } catch {
        Write-Progress -Activity $Label -Completed
        if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
        throw "Download failed: $($_.Exception.Message)"
    }
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
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { Stop-Installer "Target folder does not exist: $targetRoot" }
        Write-Host ''
        Write-Host "Target folder: $targetRoot" -ForegroundColor Yellow
        Write-Warn 'Existing files with matching names will be overwritten. Replaced originals will be backed up in a timestamped "og files" folder inside the game directory.'
        $proceed = Read-Host 'Continue? [y/N]'
        if ($proceed -notmatch '^(y|yes)$') { Stop-Cancelled 'Installation cancelled.' }
        
        if (Test-SandboxMode) {
            Write-Host '[SANDBOX] The game and anti-cheat services are not closed in sandbox mode.' -ForegroundColor DarkYellow
        } else {
            # NEW: Kill game processes and stop anti-cheat services to release file locks
            Write-Info "Closing running game processes and anti-cheat services to release file locks..."
            $services = @("randgrid", "EasyAntiCheat", "EasyAntiCheat_EOS", "BEService")
            foreach ($svc in $services) {
                $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
                # Only ask to stop services that are actually running, and keep sc.exe's
                # output out of any console window that happens to be visible.
                if ($service -and $service.Status -ne 'Stopped') { Stop-ServiceQuietly -Name $svc }
            }
            $gameProcs = @("cod", "modernwarfare", "randgrid", "easyanticheat")
            foreach ($proc in $gameProcs) {
                Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 3
        }

        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        Write-Info "Downloading release asset $ZipFileName ..."
        Download-FileWithProgress -Url $ZipUrl -Destination $zipPath -Label "Downloading fix: $ZipFileName"
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -le 0) { Stop-Installer 'The ZIP download is missing or empty.' }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        if ($archive.Entries.Count -eq 0) { Stop-Installer 'The downloaded ZIP is empty.' }
        if ($archive.Entries.Count -gt 20000) { Stop-Installer 'The ZIP contains an unexpectedly large number of entries; refusing to continue.' }
        $planned = [System.Collections.Generic.List[object]]::new()
        $totalUncompressed = [int64]0
        foreach ($entry in $archive.Entries) {
            $relative = Get-ValidatedRelativePath $entry.FullName
            $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')
            if ($isDirectory) { continue }
            $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) { Stop-Installer "ZIP contains a symbolic link, which is not allowed: $($entry.FullName)" }
            $totalUncompressed += [int64]$entry.Length
            if ($totalUncompressed -gt 5GB) { Stop-Installer 'The ZIP expands to more than 5 GB; refusing to continue.' }
            $stageRootFull = [IO.Path]::GetFullPath($stageRoot).TrimEnd([char[]]@('\', '/'))
            $stagePath = [IO.Path]::GetFullPath((Join-Path $stageRootFull $relative))
            $stagePrefix = $stageRootFull + [IO.Path]::DirectorySeparatorChar
            if (-not $stagePath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { Stop-Installer "ZIP path escapes the staging folder: $($entry.FullName)" }
            $targetRootFull = [IO.Path]::GetFullPath($targetRoot).TrimEnd([char[]]@('\', '/'))
            $targetPath = [IO.Path]::GetFullPath((Join-Path $targetRootFull $relative))
            $targetPrefix = $targetRootFull + [IO.Path]::DirectorySeparatorChar
            if (-not $targetPath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { Stop-Installer "ZIP path escapes the game folder: $($entry.FullName)" }
            # The backup record shares the backup folder with the backed-up files, so a
            # ZIP file of the same name would overwrite it.
            if ($relative -ieq (Get-FixBackupRecordName)) { Stop-Installer "ZIP contains a file name the installer reserves for its backup record: $($entry.FullName)" }
            $planned.Add([pscustomobject]@{ Relative = $relative; StagePath = $stagePath; TargetPath = $targetPath; Entry = $entry })
        }
        if ($planned.Count -eq 0) { Stop-Installer 'The ZIP contains no files to install.' }
        Write-Info "Checking and staging $($planned.Count) files..."
        foreach ($item in $planned) {
            $parent = Split-Path -Parent $item.StagePath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $inputStream = $item.Entry.Open()
            try {
                $outputStream = [IO.File]::Open($item.StagePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
        $archive.Dispose()
        $archive = $null
        $backupBase = Join-Path $targetRoot 'og files'
        $backupBaseExisted = Test-Path -LiteralPath $backupBase
        if ($backupBaseExisted) {
            $backupBaseItem = Get-Item -LiteralPath $backupBase -Force
            if (-not $backupBaseItem.PSIsContainer -or (($backupBaseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Stop-Installer "The reserved backup path is not a normal directory: $backupBase" }
        }
        $backupRoot = Join-Path $backupBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $createdTargets = [System.Collections.Generic.List[string]]::new()
        $createdRelatives = [System.Collections.Generic.List[string]]::new()
        $createdFolders = [System.Collections.Generic.List[string]]::new()
        $backedUpTargets = [System.Collections.Generic.List[object]]::new()
        $targetPrefixLength = $targetRoot.TrimEnd('\').Length + 1
        try {
            foreach ($item in $planned) {
                $destination = $item.TargetPath
                $parent = Split-Path -Parent $destination
                $cursor = $parent
                while ($cursor -and $cursor.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    if (Test-Path -LiteralPath $cursor) {
                        $attributes = [IO.File]::GetAttributes($cursor)
                        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Installer "A junction or symbolic link exists in the destination path: $cursor" }
                    }
                    if ($cursor.Equals($targetRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
                    $cursor = Split-Path -Parent $cursor
                }
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                    # Note each folder this creates, so Remove Fix (or a rollback) can take
                    # it away again once it is empty.
                    $walk = $parent
                    while ($walk -and $walk.Length -gt $targetPrefixLength -and -not (Test-Path -LiteralPath $walk)) {
                        $createdFolders.Add($walk.Substring($targetPrefixLength))
                        $walk = Split-Path -Parent $walk
                    }
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                if (Test-Path -LiteralPath $destination) {
                    $existingItem = Get-Item -LiteralPath $destination -Force
                    if ($existingItem.PSIsContainer) { Stop-Installer "A destination file conflicts with an existing directory: $destination" }
                    if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Installer "A symbolic link or reparse point exists at the destination file: $destination" }
                    $relative = $item.Relative
                    $backupPath = Join-Path $backupRoot $relative
                    $backupParent = Split-Path -Parent $backupPath
                    if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                    Copy-Item -LiteralPath $destination -Destination $backupPath
                    $backedUpTargets.Add([pscustomobject]@{ Target = $destination; Backup = $backupPath; Relative = $relative })
                } else { $createdTargets.Add($destination); $createdRelatives.Add($item.Relative) }
                Copy-Item -LiteralPath $item.StagePath -Destination $destination -Force
            }
            # Written last, so a record only exists for an install that completed. It
            # tells Remove Fix exactly which originals this folder holds and which
            # files the fix added, without guessing from folder age or size.
            Write-FixBackupRecord -BackupRoot $backupRoot -ReplacedFiles @($backedUpTargets | ForEach-Object { [string]$_.Relative }) -AddedFiles @($createdRelatives) -AddedDirectories @($createdFolders)
        } catch {
            Write-Warn 'Installation failed. Attempting to restore replaced files...'
            $rollbackFailed = $false
            foreach ($newFile in $createdTargets) {
                try { if (Test-Path -LiteralPath $newFile -PathType Leaf) { Remove-Item -LiteralPath $newFile -Force -ErrorAction Stop } }
                catch { $rollbackFailed = $true; Write-Warn "Could not automatically remove: $newFile" }
            }
            for ($i = $backedUpTargets.Count - 1; $i -ge 0; $i--) {
                $record = $backedUpTargets[$i]
                try { Copy-Item -LiteralPath $record.Backup -Destination $record.Target -Force -ErrorAction Stop } catch { $rollbackFailed = $true; Write-Warn "Could not automatically restore: $($record.Target)" }
            }
            # Folders this run created and left empty go too.
            try { $null = Remove-EmptyFixFolder -TargetRoot $targetRoot -Relatives @($createdFolders) } catch { Write-Warn "Could not remove an empty folder the install created: $($_.Exception.Message)" }
            if (-not $rollbackFailed) {
                # Everything is back as it was, so this run's partial backup must go: left
                # behind, it would later look like the oldest backup and make Remove Fix
                # delete originals it does not hold.
                try {
                    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction Stop }
                    if (-not $backupBaseExisted -and (Test-Path -LiteralPath $backupBase -PathType Container) -and -not (Get-ChildItem -LiteralPath $backupBase -Force | Select-Object -First 1)) {
                        Remove-Item -LiteralPath $backupBase -Force -ErrorAction Stop
                    }
                } catch { Write-Warn "Could not remove the partial backup folder: $backupRoot" }
            } else {
                # Some files still hold fix content, and their originals are only in this
                # folder. Record what was touched so Remove Fix can finish the job.
                try {
                    Write-FixBackupRecord -BackupRoot $backupRoot -ReplacedFiles @($backedUpTargets | ForEach-Object { [string]$_.Relative }) -AddedFiles @($createdRelatives) -AddedDirectories @($createdFolders) -Incomplete
                    Write-Warn "The originals of the files above are kept in: $backupRoot. Run Remove Fix to put them back."
                } catch { Write-Warn "Could not record the partial backup; its originals are kept in: $backupRoot" }
            }
            throw # Re-throw the exact exception
        }
        Write-Ok 'Installation completed successfully.'
        if ($backedUpTargets.Count -gt 0) {
            Write-Info "Backed up $($backedUpTargets.Count) replaced file(s) to:"
            Write-Host "  $backupRoot"
        } else { Write-Info 'No existing files needed to be backed up.' }
        $launcherPath = Join-Path $targetRoot '!start_sp26.bat'
        Write-Host ''
        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            $launchAnswer = Read-Host 'Installation succeeded. Run !start_sp26.bat now? [Y/n]'
            if ([string]::IsNullOrWhiteSpace($launchAnswer) -or $launchAnswer -match '^(y|yes)$') {
                Write-Info 'Launching !start_sp26.bat ...'
                Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('"' + $launcherPath + '"')) -WorkingDirectory $targetRoot
                Write-Ok 'Launch command started.'
            } else { Write-Info 'Launch skipped. You can run !start_sp26.bat from the game folder later.' }
        } else {
            Write-Warn "Installation succeeded, but !start_sp26.bat was not found in the game root:"
            Write-Host "  $launcherPath"
        }
    } finally {
        if ($archive) { try { $archive.Dispose() } catch {} }
        if (Test-Path -LiteralPath $workRoot) { try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    }
}

# Native is display-only: it never takes part in selection, download, or state logic.
# Native names below are written as \uXXXX escapes and decoded at startup so this
# file stays pure ASCII. That is not cosmetic: "irm ... | iex" hands PowerShell the
# script as a string, and a UTF-8 byte-order mark at the start of that string makes
# Windows PowerShell 5.1 fail to parse the param block ("Cannot convert value
# "System.String" ... SwitchParameter"), so the utility never started.
function ConvertFrom-UnicodeEscape {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # Not $text: PowerShell variable names are case-insensitive, so that would be
    # the same variable as $Text and would replace the input with the builder.
    $builder = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $Text.Length) {
        if ($Text[$index] -eq '\' -and ($index + 5) -lt $Text.Length -and $Text[$index + 1] -eq 'u') {
            $code = 0
            if ([int]::TryParse($Text.Substring($index + 2, 4), [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                [void]$builder.Append([char]$code)
                $index += 6
                continue
            }
        }
        [void]$builder.Append($Text[$index])
        $index++
    }
    return $builder.ToString()
}

$LanguagePacks = [ordered]@{
    'Arabic' = [pscustomobject]@{ File = 'Arabic.zip'; Value = 'arabic'; Native = (ConvertFrom-UnicodeEscape '\u0627\u0644\u0639\u0631\u0628\u064a\u0629'); Assets = @('Arabic.zip') }
    'French' = [pscustomobject]@{ File = 'French.zip'; Value = 'french'; Native = (ConvertFrom-UnicodeEscape '\u0046\u0072\u0061\u006e\u00e7\u0061\u0069\u0073'); Assets = @('French.zip') }
    'German' = [pscustomobject]@{ File = 'German.zip'; Value = 'german'; Native = 'Deutsch'; Assets = @('German.zip') }
    'Italian' = [pscustomobject]@{ File = 'Italian.zip'; Value = 'italian'; Native = 'Italiano'; Assets = @('Italian.zip') }
    'Japanese' = [pscustomobject]@{ File = 'Japanese.zip'; Value = 'japanese'; Native = (ConvertFrom-UnicodeEscape '\u65e5\u672c\u8a9e'); Assets = @('Japanese.zip.part001', 'Japanese.zip.part002') }
    'Korean' = [pscustomobject]@{ File = 'Korean.zip'; Value = 'koreana'; Native = (ConvertFrom-UnicodeEscape '\ud55c\uad6d\uc5b4'); Assets = @('Korean.zip.part001', 'Korean.zip.part002') }
    'Polish' = [pscustomobject]@{ File = 'Polish.zip'; Value = 'polish'; Native = 'Polski'; Assets = @('Polish.zip') }
    'Portuguese (Brazil)' = [pscustomobject]@{ File = 'Portuguese.-.Brazil.zip'; Value = 'brazilian'; Native = (ConvertFrom-UnicodeEscape '\u0050\u006f\u0072\u0074\u0075\u0067\u0075\u00ea\u0073\u0020\u0028\u0042\u0072\u0061\u0073\u0069\u006c\u0029'); Assets = @('Portuguese.-.Brazil.zip') }
    'Russian' = [pscustomobject]@{ File = 'Russian.zip'; Value = 'russian'; Native = (ConvertFrom-UnicodeEscape '\u0420\u0443\u0441\u0441\u043a\u0438\u0439'); Assets = @('Russian.zip') }
    'Simplified Chinese' = [pscustomobject]@{ File = 'Simplified-Chinese.zip'; Value = 'schinese'; Native = (ConvertFrom-UnicodeEscape '\u7b80\u4f53\u4e2d\u6587'); Assets = @('Simplified-Chinese.zip.part001', 'Simplified-Chinese.zip.part002') }
    'Spanish (Latin America)' = [pscustomobject]@{ File = 'Spanish.-.Latin.America.zip'; Value = 'latam'; Native = (ConvertFrom-UnicodeEscape '\u0045\u0073\u0070\u0061\u00f1\u006f\u006c\u0020\u0028\u004c\u0061\u0074\u0069\u006e\u006f\u0061\u006d\u00e9\u0072\u0069\u0063\u0061\u0029'); Assets = @('Spanish.-.Latin.America.zip') }
    'Spanish (Spain)' = [pscustomobject]@{ File = 'Spanish.-.Spain.zip'; Value = 'spanish'; Native = (ConvertFrom-UnicodeEscape '\u0045\u0073\u0070\u0061\u00f1\u006f\u006c\u0020\u0028\u0045\u0073\u0070\u0061\u00f1\u0061\u0029'); Assets = @('Spanish.-.Spain.zip') }
    'Traditional Chinese' = [pscustomobject]@{ File = 'Traditional.Chinese.zip'; Value = 'tchinese'; Native = (ConvertFrom-UnicodeEscape '\u7e41\u9ad4\u4e2d\u6587'); Assets = @('Traditional.Chinese.zip') }
}

# Friendly label for menus: "English name - native name".
function Get-LanguageLabel {
    param([string]$Name)
    $pack = $LanguagePacks[$Name]
    if ($null -ne $pack -and -not [string]::IsNullOrWhiteSpace([string]$pack.Native)) { return ($Name + ' ' + [char]0x2014 + ' ' + $pack.Native) }
    return $Name
}

function Get-LanguageManagerRoot { param([Parameter(Mandatory)][string]$TargetRoot) return (Join-Path $TargetRoot 'language files\language-pack-manager') }
function Get-LanguageStatePath { param([Parameter(Mandatory)][string]$ManagerRoot) return (Join-Path $ManagerRoot 'state.json') }

function Get-ConfigLanguageValue {
    param([Parameter(Mandatory)][string]$IniPath)
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw "Configuration file not found: $IniPath" }
    $content = [IO.File]::ReadAllText($IniPath)
    $languageLines = [regex]::Matches($content, '(?im)^[ \t]*language[ \t]*=[ \t]*(.*?)[ \t]*\r?$')
    if ($languageLines.Count -ne 1) { throw "Expected exactly one existing language= line in '$IniPath'; found $($languageLines.Count). The file was not changed." }
    return $languageLines[0].Groups[1].Value.Trim()
}

function Set-ConfigLanguageValue {
    param([Parameter(Mandatory)][string]$IniPath, [Parameter(Mandatory)][string]$Language)
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { throw "Configuration file not found: $IniPath" }
    $content = [IO.File]::ReadAllText($IniPath)
    $languageLines = [regex]::Matches($content, '(?im)^[ \t]*language[ \t]*=[^\r\n]*')
    if ($languageLines.Count -ne 1) { throw "Expected exactly one existing language= line in '$IniPath'; found $($languageLines.Count). The file was not changed." }
    $m = $languageLines[0]
    $updated = $content.Substring(0, $m.Index) + "language=$Language" + $content.Substring($m.Index + $m.Length)
    $tempIni = "$IniPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempIni, $updated, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempIni -Destination $IniPath -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $tempIni -Force -ErrorAction SilentlyContinue; throw }
}

function Save-LanguageManagerState {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$ManagerRoot)
    $statePath = Get-LanguageStatePath -ManagerRoot $ManagerRoot
    $tempPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $statePath -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw }
}

function Get-LanguageManagerState {
    param([Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][string]$IniPath, [switch]$Create)
    $managerRoot = Get-LanguageManagerRoot -TargetRoot $TargetRoot
    $statePath = Get-LanguageStatePath -ManagerRoot $managerRoot
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if (-not ([string]$state.TargetRoot).Equals($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Language manager state belongs to a different game folder: $($state.TargetRoot)" }
        if (-not (Test-Path -LiteralPath ([string]$state.OriginalIniBackup) -PathType Leaf)) { throw "The manager's original configuration backup is missing: $($state.OriginalIniBackup). State was not changed." }
        return $state
    }
    if (-not $Create) { return $null }
    $legacyRoots = @()
    if (Test-Path -LiteralPath $managerRoot -PathType Container) { $legacyRoots += $managerRoot }
    $legacyOldRoot = Join-Path $TargetRoot 'og files\language-pack-manager'
    if (Test-Path -LiteralPath $legacyOldRoot -PathType Container) { $legacyRoots += $legacyOldRoot }
    $legacy = @($legacyRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue })
    if ($legacy.Count -gt 0) { throw "Legacy per-install language records were found under '$managerRoot' or '$legacyOldRoot'. For safety, this manager will not mix them with its new shared-file ledger." }
    $null = New-Item -ItemType Directory -Path $managerRoot -Force
    $originalIniBackup = Join-Path $managerRoot 'configs.user.ini.original.bak'
    if (Test-Path -LiteralPath $originalIniBackup -PathType Leaf) { throw "An original config backup exists but state.json does not: $originalIniBackup. Refusing to guess whether it belongs to this game state." }
    $currentValue = Get-ConfigLanguageValue -IniPath $IniPath
    Copy-Item -LiteralPath $IniPath -Destination $originalIniBackup -ErrorAction Stop
    $state = [pscustomobject]@{ Version = 2; TargetRoot = $TargetRoot; IniPath = $IniPath; OriginalIniBackup = $originalIniBackup; InitialLanguageValue = $currentValue; ActiveValue = $currentValue; Packs = @(); Paths = @() }
    Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    return $state
}

function Get-ManagerPathState { param($State, [string]$Relative) foreach ($pathState in @($State.Paths)) { if ([string]$pathState.Relative -ieq $Relative) { return $pathState } } return $null }
function Get-ManagerPack { param($State, [string]$LanguageName) foreach ($packState in @($State.Packs)) { if ([string]$packState.Name -ieq $LanguageName) { return $packState } } return $null }

function Copy-FileAtomically {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $temp = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try { Copy-Item -LiteralPath $Source -Destination $temp -ErrorAction Stop; Move-Item -LiteralPath $temp -Destination $Destination -Force -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
}

function Test-SafeGameDestination {
    param([Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][string]$Destination)
    $parent = Split-Path -Parent $Destination
    $cursor = $parent
    while ($cursor -and $cursor.StartsWith($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $attrs = [IO.File]::GetAttributes($cursor)
            if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "A junction/symlink exists in the destination path: $cursor" }
        }
        if ($cursor.Equals($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Destination is a directory or reparse point; refusing to alter it: $Destination" }
    }
}

function Download-LanguageArchive {
    param([Parameter(Mandatory)]$Pack, [Parameter(Mandatory)][string]$WorkRoot, [Parameter(Mandatory)][string]$LanguageName)
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
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-Item -LiteralPath $destination).Length -le 0) { throw "Downloaded asset is missing or empty: $assetName" }
        $localAssets.Add($destination)
    }
    if ($localAssets.Count -eq 1) { return $localAssets[0] }
    $assembled = Join-Path $WorkRoot $Pack.File
    $out = [IO.File]::Open($assembled, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        foreach ($partPath in $localAssets) { $partStream = [IO.File]::OpenRead($partPath); try { $partStream.CopyTo($out) } finally { $partStream.Dispose() } }
        $out.Flush()
    } finally { $out.Dispose() }
    Write-Ok ([string]::Format([cultureinfo]::InvariantCulture, 'Reassembled {0} from {1} ordered parts ({2:N2} GiB).', $Pack.File, $localAssets.Count, ((Get-Item -LiteralPath $assembled).Length / 1GB)))
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $testArchive = $null
    try {
        $testArchive = [IO.Compression.ZipFile]::OpenRead($assembled)
        if ($testArchive.Entries.Count -eq 0) { throw 'The reassembled ZIP contains no entries.' }
    } catch { throw "Reassembled ZIP failed its initial open test: $($_.Exception.Message)" }
    finally { if ($testArchive) { $testArchive.Dispose() } }
    foreach ($partPath in $localAssets) { Remove-Item -LiteralPath $partPath -Force -ErrorAction Stop }
    Write-Info 'Temporary split parts were removed after successful reassembly; the reconstructed ZIP is retained until staging finishes.'
    return $assembled
}

function Install-LanguagePack {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $iniPath = Join-Path $targetRoot 'sp26\steam_settings\configs.user.ini'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Could not find configs.user.ini at '$iniPath'. No language files were installed." }
    Write-Host ''
    Write-Host 'Available language packs:' -ForegroundColor White
    $names = @($LanguagePacks.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host "  [$($i + 1)] $(Get-LanguageLabel $names[$i])" }
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
        $baselineValue = Get-ConfigLanguageValue -IniPath $iniPath
        Copy-Item -LiteralPath $iniPath -Destination ([string]$state.OriginalIniBackup) -Force -ErrorAction Stop
        $state.InitialLanguageValue = $baselineValue
        $state.ActiveValue = $baselineValue
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    }
    if ($null -ne (Get-ManagerPack -State $state -LanguageName $languageName)) { Write-Warn "$languageName is already tracked as installed. Use Active Language Preset to switch to it."; return }
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
            if ([IO.Path]::IsPathRooted($entryName) -or $entryName.StartsWith('\') -or $entryName -match '^[A-Za-z]:' -or $entryName.Split('\') -contains '..') { throw "Unsafe path in ZIP: $($entry.FullName)" }
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
        $newPaths = [System.Collections.Generic.List[object]]::new()
        foreach ($existingPathState in @($state.Paths)) { $newPaths.Add($existingPathState) }
        $pathIndexByKey = @{}
        for ($i = 0; $i -lt $newPaths.Count; $i++) { $existingKey = ([string]$newPaths[$i].Relative).ToLowerInvariant(); $pathIndexByKey[$existingKey] = $i }
        $toInstall = [System.Collections.Generic.List[object]]::new()
        $originalFilesRoot = Join-Path $managerRoot 'original-files'
        foreach ($item in $planned) {
            Test-SafeGameDestination -TargetRoot $targetRoot -Destination $item.TargetPath
            $key = $item.Relative.ToLowerInvariant()
            if ($pathIndexByKey.ContainsKey($key)) {
                $idx = [int]$pathIndexByKey[$key]
                $prior = $newPaths[$idx]
                if ([string]$prior.Hash -ne [string]$item.SHA256) { throw "This pack's file differs from a file already managed at '$($item.Relative)'. Nothing was committed, to avoid corrupting a shared path." }
                if (-not (Test-Path -LiteralPath $item.TargetPath -PathType Leaf)) { throw "Managed shared file is missing: $($item.TargetPath)" }
                $currentHash = (Get-FileHash -LiteralPath $item.TargetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($currentHash -ne [string]$prior.Hash) { throw "Managed shared file was changed outside the manager: $($item.TargetPath). Restore it before installing another pack." }
                $owners = @($prior.Owners)
                if ($owners -notcontains $languageName) { $owners += $languageName }
                $newPaths[$idx] = [pscustomobject]@{ Relative=[string]$prior.Relative; Hash=[string]$prior.Hash; Owners=@($owners); OriginalExisted=[bool]$prior.OriginalExisted; OriginalBackupRelative=[string]$prior.OriginalBackupRelative }
            } else {
                $destExists = Test-Path -LiteralPath $item.TargetPath -PathType Leaf
                $backupRelative = ''
                if ($destExists) { $backupRelative = $item.Relative }
                $newPaths.Add([pscustomobject]@{ Relative=$item.Relative; Hash=$item.SHA256; Owners=@($languageName); OriginalExisted=[bool]$destExists; OriginalBackupRelative=$backupRelative })
                $pathIndexByKey[$key] = $newPaths.Count - 1
                $toInstall.Add($item)
            }
        }
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
        Set-ConfigLanguageValue -IniPath $iniPath -Language $pack.Value
        $newPacks = [System.Collections.Generic.List[object]]::new()
        foreach ($installedPack in @($state.Packs)) { $newPacks.Add($installedPack) }
        $newPacks.Add([pscustomobject]@{ Name=$languageName; Value=$pack.Value; InstalledAt=(Get-Date).ToString('o'); ArchiveSHA256=$archiveHash; Files=@($planned | ForEach-Object { [string]$_.Relative }) })
        $state.Paths = @($newPaths.ToArray())
        $state.Packs = @($newPacks.ToArray())
        $state.ActiveValue = $pack.Value
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
        $committed = $true
        Write-Ok "$languageName language pack installed."
        Write-Info "Active language set to '$($pack.Value)'."
        Write-Info "Installed files owned by this pack: $($planned.Count)."
    } catch {
        # Already saved as installed: rolling files back now would leave state.json
        # describing files that are gone, so report the error and keep the install.
        if ($committed) { throw }
        Write-Warn 'Language-pack installation failed. Attempting to roll back newly written files and configuration...'
        for ($i = $undo.Count - 1; $i -ge 0; $i--) {
            $record = $undo[$i]
            try {
                if ($record.HadOriginal -and (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) { Copy-FileAtomically -Source $record.BackupPath -Destination $record.Destination }
                elseif (-not $record.HadOriginal -and (Test-Path -LiteralPath $record.Destination -PathType Leaf)) { Remove-Item -LiteralPath $record.Destination -Force -ErrorAction Stop }
            } catch { Write-Warn "Could not roll back '$($record.Destination)': $($_.Exception.Message)" }
        }
        if (Test-Path -LiteralPath $beforeIni -PathType Leaf) { try { Copy-FileAtomically -Source $beforeIni -Destination $iniPath } catch { Write-Warn "Could not restore pre-install config: $($_.Exception.Message)" } }
        foreach ($dir in @($createdDirs | Sort-Object Length -Descending)) { try { if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir -Force } } catch {} }
        throw # Re-throw the exact exception
    } finally {
        if ($archive) { try { $archive.Dispose() } catch {} }
        if (Test-Path -LiteralPath $workRoot) { try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
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
        foreach ($installedPack in @($state.Packs)) { $options.Add([pscustomobject]@{ Name=[string]$installedPack.Name; Value=[string]$installedPack.Value }) }
    } else {
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
    for ($i=0; $i -lt $options.Count; $i++) { Write-Host "  [$($i+1)] $(Get-LanguageLabel $options[$i].Name) (language=$($options[$i].Value))" }
    Write-Host '  [0] Cancel'
    $choice = Read-Host 'Choose the active language preset'
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { Write-Info 'Preset change cancelled.'; return }
    $number=0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $options.Count) { throw 'Invalid preset selection.' }
    $selected = $options[$number-1]
    if ($currentValue -eq [string]$selected.Value) {
        if (($null -ne $state) -and ([string]$state.ActiveValue -ne [string]$selected.Value)) { $state.ActiveValue = [string]$selected.Value; Save-LanguageManagerState -State $state -ManagerRoot $managerRoot }
        Write-Info "Preset is already active: $($selected.Name)."
        return
    }
    Set-ConfigLanguageValue -IniPath $iniPath -Language ([string]$selected.Value)
    if ($null -ne $state) { $state.ActiveValue = [string]$selected.Value; Save-LanguageManagerState -State $state -ManagerRoot $managerRoot }
    Write-Ok "Active language preset changed to $($selected.Name) ($($selected.Value))."
    Write-Info 'Only the existing language= value was changed; language files were not installed, removed, or overwritten.'
}

function Remove-LanguagePack {
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $iniPath = Join-Path $targetRoot 'sp26\steam_settings\configs.user.ini'
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "Could not find configs.user.ini at '$iniPath'." }
    $managerRoot = Get-LanguageManagerRoot -TargetRoot $targetRoot
    $state = Get-LanguageManagerState -TargetRoot $targetRoot -IniPath $iniPath
    if ($null -eq $state) {
        Write-Warn 'No language packs tracked by the multi-language manager were found.'
        return
    }
    if (@($state.Packs).Count -eq 0) { Write-Warn 'No language packs are currently installed according to the manager state.'; return }
    $installed = @($state.Packs)
    Write-Host ''
    Write-Host 'Installed language packs:' -ForegroundColor White
    for ($i=0; $i -lt $installed.Count; $i++) { Write-Host "  [$($i+1)] $(Get-LanguageLabel $installed[$i].Name) (language=$($installed[$i].Value), files tracked=$(@($installed[$i].Files).Count))" }
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
    $confirm = Read-Host 'Continue? [y/N]'
    if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Removal cancelled.'; return }
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
    $isActivePack = ($currentValue -eq [string]$packState.Value)
    if ($isActivePack) {
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
            $replacement = [pscustomobject]@{ Relative=[string]$pathState.Relative; Hash=[string]$pathState.Hash; Owners=@($owners); OriginalExisted=[bool]$pathState.OriginalExisted; OriginalBackupRelative=[string]$pathState.OriginalBackupRelative }
            $newPaths = @()
            foreach ($p in @($state.Paths)) { if ([string]$p.Relative -ieq $relative) { $newPaths += $replacement } else { $newPaths += $p } }
            $state.Paths = @($newPaths)
        } else {
            if ([bool]$pathState.OriginalExisted) {
                $original = Join-Path (Join-Path $managerRoot 'original-files') ([string]$pathState.OriginalBackupRelative)
                Copy-FileAtomically -Source $original -Destination $dest
            } else { Remove-Item -LiteralPath $dest -Force -ErrorAction Stop }
            $state.Paths = @($state.Paths | Where-Object { [string]$_.Relative -ine $relative })
        }
        $currentPack = Get-ManagerPack -State $state -LanguageName $languageName
        $currentPack.Files = @(@($currentPack.Files) | Where-Object { [string]$_ -ine $relative })
        Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    }
    $state.Packs = @($state.Packs | Where-Object { [string]$_.Name -ine $languageName })
    Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
    Write-Ok "$languageName was removed. Shared files required by other installed packs were retained."
    if (@($state.Packs).Count -eq 0) {
        $now = Get-ConfigLanguageValue -IniPath $iniPath
        if ($now -eq [string]$state.ActiveValue) {
            $baselineValue = Get-ConfigLanguageValue -IniPath ([string]$state.OriginalIniBackup)
            Set-ConfigLanguageValue -IniPath $iniPath -Language $baselineValue
            $state.ActiveValue = $baselineValue
            Save-LanguageManagerState -State $state -ManagerRoot $managerRoot
            Write-Info "No language packs remain; restored the original language setting '$baselineValue'."
        } else { Write-Warn 'No language packs remain, but the config language value changed outside the manager. It was left untouched.' }
    }
}

# Name of the record an install writes into its backup folder. A function rather
# than a variable, so every scope (handlers, tests) resolves the same value.
function Get-FixBackupRecordName { return '.codhq-fix-backup.json' }

# Records what one install did: which originals its backup folder holds and which
# files the fix added. Written through a temp file, so a record is never half there.
function Write-FixBackupRecord {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [string[]]$ReplacedFiles = @(),
        [string[]]$AddedFiles = @(),
        # Folders the install created (relative), so Remove Fix can delete them
        # again once they are empty.
        [string[]]$AddedDirectories = @(),
        [switch]$Incomplete
    )
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { $null = New-Item -ItemType Directory -Path $BackupRoot -Force }
    $record = [ordered]@{
        Version          = 2
        CreatedAt        = [DateTime]::UtcNow.ToString('o')
        AppVersion       = [string]$AppVersion
        ZipFileName      = [string]$ZipFileName
        Complete         = (-not $Incomplete)
        ReplacedFiles    = @($ReplacedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        AddedFiles       = @($AddedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        AddedDirectories = @($AddedDirectories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $recordPath = Join-Path $BackupRoot (Get-FixBackupRecordName)
    $tempPath = "$recordPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($record | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $recordPath -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue; throw }
}

# Reads a backup record. A record that exists but cannot be read is an error, not
# "no record": guessing would risk restoring or deleting the wrong files.
function Read-FixBackupRecord {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # PowerShell 7 turns ISO dates into DateTime by itself; 5.1 leaves a string.
        $created = $raw.CreatedAt
        if ($created -is [DateTime]) { $createdUtc = $created.ToUniversalTime() }
        else { $createdUtc = [DateTime]::Parse([string]$created, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        return [pscustomobject]@{
            CreatedAtUtc  = $createdUtc
            Complete      = [bool]$raw.Complete
            ReplacedFiles = @($raw.ReplacedFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
            AddedFiles    = @($raw.AddedFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
            # Version 1 records have no folder list.
            AddedDirectories = @($raw.AddedDirectories | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    } catch {
        throw "The fix backup record could not be read: $Path ($($_.Exception.Message)). Nothing was changed."
    }
}

# Backup folders inside 'og files' that can be used to revert the fix: a real
# directory (not a link) that either carries a backup record (any size, even one
# with no replaced files) or, for backups made before records existed, holds at
# least one file. Shared by Remove-Fix and the pre-downgrade cleanup, so both agree
# on what counts as a backup.
function Get-FixBackupCandidates {
    param([Parameter(Mandatory)][string]$TargetRoot)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $backupBase = Join-Path $TargetRoot 'og files'
    if (-not (Test-Path -LiteralPath $backupBase -PathType Container)) { return $candidates }
    foreach ($dir in (Get-ChildItem -LiteralPath $backupBase -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $recordPath = Join-Path $dir.FullName (Get-FixBackupRecordName)
        $record = $null
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) { $record = Read-FixBackupRecord -Path $recordPath }
        $bytes = [int64](Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $record -and $bytes -le 0) { continue }
        # Recorded backups are ordered by their record (exact time of the install);
        # older ones by the folder's creation time, as before.
        $sortKey = if ($null -ne $record) { $record.CreatedAtUtc } else { $dir.CreationTimeUtc }
        $candidates.Add([pscustomobject]@{ Directory = $dir; Bytes = $bytes; Record = $record; SortKey = $sortKey })
    }
    return $candidates
}

# Decides, per file, what Remove-Fix does with recorded backups: the oldest record
# that mentions a file wins. "Replaced" there means that folder holds the original,
# "Added" means the file did not exist before the fix. Installing twice (whose
# second backup only holds fix copies), a newer ZIP that added files, and a failed
# install followed by a good one all resolve correctly this way.
function Get-FixRemovalPlan {
    param([Parameter(Mandatory)][string]$TargetRoot, [Parameter(Mandatory)][object[]]$Candidates)
    $decisions = [ordered]@{}
    foreach ($candidate in @($Candidates | Where-Object { $null -ne $_.Record } | Sort-Object SortKey)) {
        foreach ($name in $candidate.Record.ReplacedFiles) {
            $relative = Get-ValidatedRelativePath $name
            $key = $relative.ToLowerInvariant()
            if ($decisions.Contains($key)) { continue }
            $decisions[$key] = [pscustomobject]@{ Relative = $relative; Action = 'Restore'; Source = (Join-Path $candidate.Directory.FullName $relative) }
        }
        foreach ($name in $candidate.Record.AddedFiles) {
            $relative = Get-ValidatedRelativePath $name
            $key = $relative.ToLowerInvariant()
            if ($decisions.Contains($key)) { continue }
            $decisions[$key] = [pscustomobject]@{ Relative = $relative; Action = 'Delete'; Source = $null }
        }
    }
    $plan = @($decisions.Values)
    # Check everything before touching anything: a missing original must stop the
    # removal while the game folder is still exactly as it was.
    foreach ($step in $plan) {
        $step | Add-Member -NotePropertyName Destination -NotePropertyValue (Join-Path $TargetRoot $step.Relative)
        Test-SafeGameDestination -TargetRoot $TargetRoot -Destination $step.Destination
        if ($step.Action -eq 'Restore' -and -not (Test-Path -LiteralPath $step.Source -PathType Leaf)) {
            throw "An original file is missing from its backup: $($step.Source). Nothing was changed."
        }
    }
    return $plan
}

function Remove-Fix {
    # -SkipPrompt is used by the pre-downgrade cleanup, which asks its own
    # question (and explains that the backups are deleted afterwards too).
    param([switch]$SkipPrompt)
    $targetRoot = Select-TargetFolder
    $targetRoot = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    $backupBase = Join-Path $targetRoot 'og files'
    if (-not (Test-Path -LiteralPath $backupBase -PathType Container)) { throw "The backup directory was not found: $backupBase" }
    $candidates = @(Get-FixBackupCandidates -TargetRoot $targetRoot | Sort-Object SortKey)
    if ($candidates.Count -eq 0) { throw 'No usable backup was found in "og files". Nothing was changed.' }
    $candidate = $candidates[0]
    $backupRoot = $candidate.Directory.FullName

    # Recorded backups say exactly what to do and need no download. When the oldest
    # backup predates records, only it holds the true originals, so the whole
    # removal follows the earlier rule for it.
    if ($null -ne $candidate.Record) {
        $plan = @(Get-FixRemovalPlan -TargetRoot $targetRoot -Candidates $candidates)
        Write-Warn "Selected original-file backup: $backupRoot"
        if (-not $SkipPrompt) {
            $confirm = Read-Host "Selected backup:`n$backupRoot`n`nRemove the fix, restore the originals recorded in ""og files"", and then delete the whole ""og files"" folder? [y/N]"
            if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Fix removal cancelled.'; return }
        }
        $restored = 0; $removed = 0
        foreach ($step in $plan) {
            if ($step.Action -eq 'Restore') {
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $step.Destination) -Force
                Copy-Item -LiteralPath $step.Source -Destination $step.Destination -Force -ErrorAction Stop
                $restored++
            } elseif (Test-Path -LiteralPath $step.Destination -PathType Leaf) {
                Remove-Item -LiteralPath $step.Destination -Force -ErrorAction Stop
                $removed++
            }
        }
        $addedFolders = @($candidates | Where-Object { $null -ne $_.Record } | ForEach-Object { $_.Record.AddedDirectories })
        $removedFolders = Remove-EmptyFixFolder -TargetRoot $targetRoot -Relatives $addedFolders
        Write-Ok 'Fix removal completed.'
        Write-Info "Restored original files: $restored"
        Write-Info "Removed fix-added files: $removed"
        if ($removedFolders -gt 0) { Write-Info "Removed empty fix folders: $removedFolders" }
        Remove-FixBackupFolder -TargetRoot $targetRoot
        return
    }

    Write-Warn "Selected original-file backup: $backupRoot"
    if (-not $SkipPrompt) {
        $confirm = Read-Host "Selected backup:`n$backupRoot`n`nRemove the fix, restore the originals from this backup, and then delete the whole ""og files"" folder? [y/N]"
        if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Fix removal cancelled.'; return }
    }
    $workRoot = Join-Path $env:TEMP ('codhq-fix-removal-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $workRoot $ZipFileName
    $archive = $null
    try {
        $null = New-Item -ItemType Directory -Path $workRoot -Force
        Download-FileWithProgress -Url $ZipUrl -Destination $zipPath -Label "Downloading fix manifest for removal"
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        # The fix's own content, file by file: what each path holds when the fix is
        # applied. That is what tells a fix copy apart from an original below.
        $fixFiles = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $fixFiles.Add([pscustomobject]@{ Relative = (Get-ValidatedRelativePath $entry.FullName); Hash = (Get-ZipEntrySha256 -Entry $entry) })
        }
        $archive.Dispose(); $archive = $null
        # An unrecorded backup is only trusted when every file in it is a path the fix
        # installs; anything else means the folder is not what it seems.
        $knownFiles = @{}
        foreach ($fixFile in $fixFiles) { $knownFiles[$fixFile.Relative.ToLowerInvariant()] = $true }
        foreach ($legacy in @($candidates | Where-Object { $null -eq $_.Record })) {
            $legacyPrefix = $legacy.Directory.FullName.TrimEnd('\') + '\'
            foreach ($backupFile in @(Get-ChildItem -LiteralPath $legacy.Directory.FullName -File -Recurse -Force -ErrorAction Stop)) {
                $inside = $backupFile.FullName.Substring($legacyPrefix.Length)
                if (-not $knownFiles.ContainsKey($inside.ToLowerInvariant())) {
                    throw "The backup holds a file that is not part of the fix: $($backupFile.FullName). Nothing was changed."
                }
            }
        }

        # Decide everything before changing anything. Per file:
        #  - restore the oldest backup copy whose content differs from the fix (a copy
        #    equal to the fix was backed up from an earlier install, so it is no original);
        #  - otherwise delete the game file only when it is exactly the fix's content;
        #  - otherwise leave it alone: it is not fix content, and there is no original
        #    to put back (for example a file an interrupted install already restored).
        $backupDirs = @($candidates | ForEach-Object { $_.Directory.FullName })
        $steps = [System.Collections.Generic.List[object]]::new()
        foreach ($fixFile in $fixFiles) {
            $dest = Join-Path $targetRoot $fixFile.Relative
            Test-SafeGameDestination -TargetRoot $targetRoot -Destination $dest
            $source = $null
            foreach ($dir in $backupDirs) {
                $copy = Join-Path $dir $fixFile.Relative
                if ((Test-Path -LiteralPath $copy -PathType Leaf) -and (Get-FileSha256 -Path $copy) -ne $fixFile.Hash) { $source = $copy; break }
            }
            if ($source) { $steps.Add([pscustomobject]@{ Action = 'Restore'; Relative = $fixFile.Relative; Destination = $dest; Source = $source }) }
            elseif (Test-Path -LiteralPath $dest -PathType Leaf) {
                if ((Get-FileSha256 -Path $dest) -eq $fixFile.Hash) { $steps.Add([pscustomobject]@{ Action = 'Delete'; Relative = $fixFile.Relative; Destination = $dest; Source = $null }) }
                else { $steps.Add([pscustomobject]@{ Action = 'Keep'; Relative = $fixFile.Relative; Destination = $dest; Source = $null }) }
            }
        }

        $restored = 0; $removed = 0; $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($step in $steps) {
            switch ($step.Action) {
                'Restore' {
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $step.Destination) -Force
                    Copy-Item -LiteralPath $step.Source -Destination $step.Destination -Force -ErrorAction Stop
                    $restored++
                }
                'Delete' { Remove-Item -LiteralPath $step.Destination -Force -ErrorAction Stop; $removed++ }
                'Keep' { $kept.Add($step.Relative) }
            }
        }
        # Folders the fix's files live in that are now empty were created by the fix.
        $folders = [System.Collections.Generic.List[string]]::new()
        foreach ($fixFile in $fixFiles) {
            $parent = Split-Path -Parent $fixFile.Relative
            while (-not [string]::IsNullOrEmpty($parent)) { $folders.Add($parent); $parent = Split-Path -Parent $parent }
        }
        $removedFolders = Remove-EmptyFixFolder -TargetRoot $targetRoot -Relatives @($folders)
        Write-Ok 'Fix removal completed.'
        Write-Info "Restored original files: $restored"
        Write-Info "Removed fix-added files: $removed"
        if ($removedFolders -gt 0) { Write-Info "Removed empty fix folders: $removedFolders" }
        if ($kept.Count -gt 0) {
            Write-Warn "Left alone, because they are not the fix's files and no original was backed up: $($kept.Count)"
            foreach ($keptFile in $kept) { Write-Host "  $keptFile" }
        }
    } finally {
        if ($archive) { try { $archive.Dispose() } catch { Write-Verbose 'The fix archive was already closed.' } }
        if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # Every file was restored (any failure above throws before this point), so the
    # backups have done their job. Newer backups hold fix files rather than
    # originals, so none of them are worth keeping once the fix is gone.
    Remove-FixBackupFolder -TargetRoot $targetRoot
}

# SHA-256 of one file inside a ZIP, read straight from the archive.
function Get-ZipEntrySha256 {
    param([Parameter(Mandatory)]$Entry)
    $stream = $Entry.Open()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

# Removes the given folders (relative to the game folder) when they are empty,
# deepest first, so nested folders the fix created all go. A folder that holds
# anything, or is a link, stays. Returns how many were removed.
function Remove-EmptyFixFolder {
    param([Parameter(Mandatory)][string]$TargetRoot, [string[]]$Relatives = @())
    $removedCount = 0
    $prefix = $TargetRoot.TrimEnd('\') + '\'
    $unique = @($Relatives | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    foreach ($relative in @($unique | Sort-Object { $_.Length } -Descending)) {
        $relative = Get-ValidatedRelativePath $relative
        $full = [IO.Path]::GetFullPath((Join-Path $TargetRoot $relative))
        if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or -not $item.PSIsContainer) { continue }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (Get-ChildItem -LiteralPath $full -Force | Select-Object -First 1) { continue }
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        $removedCount++
    }
    return $removedCount
}

# Deletes "og files" under the game folder. Guarded: exactly an "og files" directory
# directly under the game folder, and never a link, so a stray path cannot be wiped.
function Remove-FixBackupFolder {
    param([Parameter(Mandatory)][string]$TargetRoot)
    $backupBase = Join-Path $TargetRoot 'og files'
    if ((Split-Path -Leaf $backupBase) -ne 'og files') { throw "Refusing to delete an unexpected path: $backupBase" }
    $item = Get-Item -LiteralPath $backupBase -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer) { throw "Refusing to delete something that is not a folder: $backupBase" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to delete a linked folder: $backupBase" }
    Remove-Item -LiteralPath $backupBase -Recurse -Force -ErrorAction Stop
    Write-Ok ('Deleted "og files" and every backup inside it: ' + $backupBase)
}

# Resolves the game folder without ever opening a picker: a downgrade should not be
# interrupted by a folder dialog just to look for fix backups.
function Resolve-GameFolderQuiet {
    if ($global:SessionGameFolder -and (Test-Path -LiteralPath $global:SessionGameFolder -PathType Container)) {
        try { return ([IO.Path]::GetFullPath($global:SessionGameFolder).TrimEnd('\')) } catch { }
    }
    $saved = Get-SavedGameFolder
    if ($saved) { return $saved }
    $detected = @(Find-CallOfDutyHQ)
    if ($detected.Count -eq 1) { return $detected[0] }
    return $null
}

# A downgrade changes which game version is installed, so a fix applied for the
# current version (and the originals it backed up) no longer belongs to the
# install. This reverts the fix and then deletes "og files" entirely, before the
# downgrade touches anything. Declining cancels the downgrade, because carrying on
# would leave originals and fix files mixed across two game versions.
function Clear-FixBeforeDowngrade {
    param([string]$Method = 'Normal')

    $targetRoot = Resolve-GameFolderQuiet
    if (-not $targetRoot) {
        Add-LogEntry -Text '[WARN] The game folder is unknown, so a previously applied fix could not be checked or reverted.' -Color '#FFD700'
        return
    }
    $backupBase = Join-Path $targetRoot 'og files'
    if (-not (Test-Path -LiteralPath $backupBase -PathType Container)) {
        Add-LogEntry -Text '[OK]   No fix backup in the game folder, so there is nothing to revert before the downgrade.' -Color '#4EC9B0'
        return
    }

    $candidates = @(Get-FixBackupCandidates -TargetRoot $targetRoot)
    $canRevert = $candidates.Count -gt 0
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('"og files" is present in your game folder, so the fix is still applied.')
    $lines.Add('')
    $lines.Add($targetRoot)
    $lines.Add('')
    $lines.Add("The $Method downgrade changes the game version, so these files and backups no")
    $lines.Add('longer match the install. Before anything else this will:')
    $lines.Add('')
    if ($canRevert) {
        $lines.Add('  1. restore the originals from the oldest backup (revert the fix)')
        $lines.Add('  2. delete the whole "og files" folder, backups included - not reversible')
    } else {
        $lines.Add('  1. delete the whole "og files" folder, backups included - not reversible')
        $lines.Add('     (no usable backup was found inside it, so nothing is restored first)')
    }
    $lines.Add('')
    $lines.Add('Revert the fix and delete "og files", then continue with the downgrade? [y/N]')
    if ((Read-Host ($lines -join "`n")) -notmatch '^(y|yes)$') {
        Stop-Cancelled 'Downgrade cancelled: the fix is still applied and its backups were left untouched.'
    }

    if ($canRevert) {
        Write-Host ''
        Write-Info 'Reverting the applied fix before the downgrade...'
        Remove-Fix -SkipPrompt
        Write-Ok 'Fix reverted to the original files.'
    } else {
        Write-Warn 'No usable backup was found in "og files"; only the folder itself will be removed.'
    }

    # Remove-Fix already deletes "og files" after a successful restore; this covers
    # the case where there was no usable backup to restore from.
    try {
        Remove-FixBackupFolder -TargetRoot $targetRoot
    } catch {
        throw ('The downgrade was not started because "og files" could not be deleted: ' + $_.Exception.Message)
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
    if ($confirm -notmatch '^(y|yes)$') { Write-Info 'Launch cancelled.'; return }
    Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('"' + $launcherPath + '"')) -WorkingDirectory $targetRoot
    Write-Ok 'Launch command started.'
}


# ==========================================
# SCRIPT 2 FUNCTIONS (Downgrade Tool)
# ==========================================
# Steam's running processes, to be closed. In sandbox mode none are returned: the
# real Steam is never closed while testing against the sandbox's fake Steam folder.
function Get-SteamClientProcess {
    if (Test-SandboxMode) {
        Write-Host '[SANDBOX] Steam is not closed in sandbox mode; your real Steam keeps running.' -ForegroundColor DarkYellow
        return $null
    }
    return (Get-Process -Name steam* -ErrorAction SilentlyContinue)
}

function Start-SteamClient {
    param([Parameter(Mandatory)][string]$SteamExe, [switch]$OnlyIfNotRunning)
    if (Test-SandboxMode) {
        Write-Host "[SANDBOX] Steam would be started here ($SteamExe); skipped in sandbox mode." -ForegroundColor DarkYellow
        return
    }
    if ($OnlyIfNotRunning -and (Get-Process -Name steam -ErrorAction SilentlyContinue)) { return }
    try {
        Start-Process -FilePath $SteamExe
    } catch {
        throw "Steam could not be started from '$SteamExe': $($_.Exception.Message)"
    }
}

function Start-SteamValidation {
    if (Test-SandboxMode) {
        Write-Host "[SANDBOX] Steam would be asked to validate app $AppId here; skipped in sandbox mode." -ForegroundColor DarkYellow
        return
    }
    $null = Open-SteamUrl -Url "steam://validate/$AppId"
}

# Opens a steam:// URL. Steam's installer registers the protocol handler; when it is
# missing (Steam was moved or set up without it), steam.exe takes the URL as its
# argument, and when Steam cannot be started at all the web page is opened instead, so
# a button never fails without a usable result.
function Open-SteamUrl {
    param([Parameter(Mandatory)][string]$Url, [string]$WebFallback = '')
    if (Test-SandboxMode) {
        Write-Host "[SANDBOX] Would open: $Url" -ForegroundColor DarkYellow
        return 'sandbox'
    }
    try {
        Start-Process $Url
        return 'url'
    } catch {
        Write-Verbose "The steam:// handler could not be used: $($_.Exception.Message)"
    }
    $steamRoot = Get-SteamInstallationPath
    if ($steamRoot) {
        $steamExe = Join-Path $steamRoot 'steam.exe'
        if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
            try {
                Start-Process -FilePath $steamExe -ArgumentList @($Url)
                return 'steam'
            } catch {
                Write-Verbose "Steam could not be started: $($_.Exception.Message)"
            }
        }
    }
    if ($WebFallback) {
        Start-Process $WebFallback
        Write-Warn "Steam could not be opened; the store page was opened in your browser instead: $WebFallback"
        return 'web'
    }
    throw "Steam could not be opened ($Url). Start Steam yourself, then try again."
}

# Sandbox mode (-Sandbox <folder>) is for testing the utility end to end, including
# the UAC hand-off, without touching the real Steam or game: Steam is <folder>\Steam,
# the game is <folder>\Game and settings, hand-off files and logs live in
# <folder>\Settings. tests\Start-Sandbox.ps1 builds such a folder and starts it.
function Test-SandboxMode { return (-not [string]::IsNullOrWhiteSpace([string]$global:SandboxRoot)) }

function Get-SteamInstallationPath {
    if (Test-SandboxMode) {
        $sandboxSteam = Join-Path $global:SandboxRoot 'Steam'
        if (Test-Path -LiteralPath $sandboxSteam -PathType Container) { return $sandboxSteam }
        return $null
    }
    $registryPaths = @(
        @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Valve\Steam"; Name = "InstallPath" },
        @{ Path = "HKCU:\Software\Valve\Steam";             Name = "SteamPath"   },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam";             Name = "InstallPath" }
    )
    foreach ($reg in $registryPaths) {
        try {
            $steamPath = (Get-ItemProperty -Path $reg.Path -Name $reg.Name -ErrorAction Stop).$($reg.Name)
            if ($steamPath -and (Test-Path $steamPath -PathType Container)) { return $steamPath }
        } catch { }
    }
    $fallbackPaths = @("${env:ProgramFiles(x86)}\Steam", "${env:ProgramFiles}\Steam", "${env:HOME}\Steam")
    foreach ($path in $fallbackPaths) { if (Test-Path $path -PathType Container) { return $path } }
    return $null
}

# The downgrade's downloader: same retries, resume and checksum as
# Download-FileWithProgress, but it leaves reporting to the downgrade's own log
# lines. A failed download leaves no partial file behind.
function Download-WithProgress {
    param([string]$Url, [string]$OutFile, [string]$Activity = "Downloading file", [int]$RetryDelaySeconds = 3)
    try {
        $expected = Get-ExpectedDownloadHash -Url $Url
        $null = Invoke-ResumableDownload -Url $Url -Destination $OutFile -Label $Activity -ExpectedSha256 $expected `
            -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell' -RetryDelaySeconds $RetryDelaySeconds
        if ($expected) { Write-Ok 'Checksum verified: the file matches the published release.' }
    } catch {
        if (Test-Path -LiteralPath $OutFile -PathType Leaf) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        throw
    } finally { Write-Progress -Activity $Activity -Completed }
}

# Extracts the downgrade's manifest ZIP into the Steam folder. Every entry is
# checked before anything is written (same rules as the fix ZIP, and every target
# must stay inside the Steam folder). With -Journal and -BackupDirectory, a file
# about to be overwritten is moved to the backup first and every change is written
# to the journal, so Undo-ZipExtraction can put the Steam folder back exactly.
function Expand-ZipOverwrite {
    param(
        [string]$ZipPath,
        [string]$DestinationPath,
        [System.Collections.Generic.List[object]]$Journal = $null,
        [string]$BackupDirectory = '',
        # Folder the archive wraps all its entries in (for example "Call of Duty\"), left
        # out of the paths that are written.
        [string]$StripPrefix = ''
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path $DestinationPath)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
    $destRoot = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    $destPrefix = $destRoot + [IO.Path]::DirectorySeparatorChar
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $stripPrefix = ($StripPrefix -replace '/', '\').TrimEnd('\')
        $planned = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $zip.Entries) {
            $entryPath = $entry.FullName -replace '/', '\'
            if ([string]::IsNullOrEmpty($entryPath)) { continue }
            if ($stripPrefix) {
                $trimmed = $entryPath.TrimEnd('\')
                if ($trimmed -ieq $stripPrefix) { continue }
                if (-not $trimmed.StartsWith($stripPrefix + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-Installer "ZIP entry is not inside the archive's root folder: $($entry.FullName)" }
                $entryPath = $trimmed.Substring($stripPrefix.Length + 1)
            }
            $isDirectory = [string]::IsNullOrEmpty($entry.Name)
            $relative = (Get-ValidatedRelativePath $entryPath).TrimEnd('\')
            if ([string]::IsNullOrEmpty($relative)) { continue }
            $unixMode = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) { Stop-Installer "ZIP contains a symbolic link, which is not allowed: $($entry.FullName)" }
            $fullPath = [IO.Path]::GetFullPath((Join-Path $destRoot $relative))
            if (-not $fullPath.StartsWith($destPrefix, [StringComparison]::OrdinalIgnoreCase)) { Stop-Installer "ZIP path escapes the Steam folder: $($entry.FullName)" }
            if (-not $isDirectory) { Test-SafeGameDestination -TargetRoot $destRoot -Destination $fullPath }
            $planned.Add([pscustomobject]@{ Entry = $entry; Relative = $relative; FullPath = $fullPath; IsDirectory = $isDirectory })
        }

        $total = $planned.Count; $current = 0
        foreach ($item in $planned) {
            $current++; $percent = [int][Math]::Floor(($current / [Math]::Max(1, $total)) * 100)
            Write-Progress -Activity "Extracting manifests" -Status $item.Entry.FullName -PercentComplete $percent
            $folder = if ($item.IsDirectory) { $item.FullPath } else { Split-Path $item.FullPath -Parent }
            if (-not (Test-Path -LiteralPath $folder)) {
                # Note every folder this creates (outermost first), so an undo can remove
                # the ones that end up empty.
                $missing = [System.Collections.Generic.List[string]]::new()
                $walk = $folder
                while ($walk -and -not (Test-Path -LiteralPath $walk)) { $missing.Insert(0, $walk); $walk = Split-Path $walk -Parent }
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                if ($null -ne $Journal) { foreach ($dir in $missing) { $Journal.Add([pscustomobject]@{ Kind = 'Directory'; Path = $dir; Backup = $null }) } }
            }
            if ($item.IsDirectory) { continue }
            if ($null -ne $Journal -and -not [string]::IsNullOrEmpty($BackupDirectory)) {
                if (Test-Path -LiteralPath $item.FullPath -PathType Leaf) {
                    $backupPath = Join-Path $BackupDirectory $item.Relative
                    $backupParent = Split-Path $backupPath -Parent
                    if (-not (Test-Path -LiteralPath $backupParent)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                    Move-Item -LiteralPath $item.FullPath -Destination $backupPath -Force -ErrorAction Stop
                    $Journal.Add([pscustomobject]@{ Kind = 'Replaced'; Path = $item.FullPath; Backup = $backupPath })
                } else {
                    # Logged before the write, so a half-written file is removed too.
                    $Journal.Add([pscustomobject]@{ Kind = 'Created'; Path = $item.FullPath; Backup = $null })
                }
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.FullPath, $true)
        }
    } finally { $zip.Dispose(); Write-Progress -Activity "Extracting manifests" -Completed }
}

# Reverses a journal written by Expand-ZipOverwrite, newest change first. Returns
# $false when anything could not be put back (the backup is then kept by the caller).
function Undo-ZipExtraction {
    param([System.Collections.Generic.List[object]]$Journal)
    $ok = $true
    if ($null -eq $Journal) { return $ok }
    for ($i = $Journal.Count - 1; $i -ge 0; $i--) {
        $change = $Journal[$i]
        try {
            switch ($change.Kind) {
                'Created' {
                    if (Test-Path -LiteralPath $change.Path -PathType Leaf) { Remove-Item -LiteralPath $change.Path -Force -ErrorAction Stop }
                }
                'Replaced' {
                    if (Test-Path -LiteralPath $change.Path -PathType Leaf) { Remove-Item -LiteralPath $change.Path -Force -ErrorAction Stop }
                    Move-Item -LiteralPath $change.Backup -Destination $change.Path -Force -ErrorAction Stop
                }
                'Wiped' {
                    $parent = Split-Path -Parent $change.Path
                    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
                    if (Test-Path -LiteralPath $change.Path -PathType Leaf) { Remove-Item -LiteralPath $change.Path -Force -ErrorAction Stop }
                    Move-Item -LiteralPath $change.Backup -Destination $change.Path -Force -ErrorAction Stop
                }
                'Directory' {
                    if ((Test-Path -LiteralPath $change.Path -PathType Container) -and -not (Get-ChildItem -LiteralPath $change.Path -Force | Select-Object -First 1)) {
                        Remove-Item -LiteralPath $change.Path -Force -ErrorAction Stop
                    }
                }
            }
        } catch {
            $ok = $false
            Write-Warning "Could not undo an extracted file: $($change.Path)"
        }
    }
    return $ok
}

# Checks what a downgrade needs before anything is changed - before the fix is
# reverted and before the UAC prompt. Read-only. Returns the Steam folder.
function Test-SteamDowngradeReadiness {
    param([ValidateSet('Normal', 'Nuclear')][string]$Method = 'Normal')
    $untouched = 'Nothing was changed: the fix and "og files" were left as they are.'
    $steamRoot = Get-SteamInstallationPath
    if (-not $steamRoot) { throw "Steam installation not found. $untouched" }
    $steamExe = Join-Path -Path $steamRoot -ChildPath 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) { throw "steam.exe was not found in the Steam folder: $steamRoot. $untouched" }
    # Nuclear installs BetterSteamTools and creates this folder if it is missing;
    # Normal only writes into it.
    if ($Method -eq 'Normal') {
        $plugInDir = Join-Path -Path $steamRoot -ChildPath $SteamConfigSubPath
        if (-not (Test-Path -LiteralPath $plugInDir -PathType Container)) {
            throw "Folder not found: $plugInDir. The Normal downgrade needs SteamTools or BetterSteamTools to be installed (the Nuclear downgrade installs BetterSteamTools). $untouched"
        }
    }
    return $steamRoot
}

# Runs a downloaded PowerShell script in its own powershell.exe, so its "exit",
# its variables and its preference settings cannot reach this process. Its output
# and errors are streamed into the activity log line by line while the window keeps
# repainting. Stdin is closed, so a prompt cannot hang it; a run longer than
# -TimeoutSeconds is stopped.
function Invoke-ExternalPowerShellScript {
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [Parameter(Mandatory)][string]$WorkRoot,
        [string]$Name = 'external-script',
        [int]$TimeoutSeconds = 600
    )
    if (-not (Test-Path -LiteralPath $WorkRoot -PathType Container)) { $null = New-Item -ItemType Directory -Path $WorkRoot -Force }
    $scriptFile = Join-Path $WorkRoot ($Name + '.ps1')
    # With a BOM, Windows PowerShell 5.1 reads the file as UTF-8 instead of ANSI.
    [IO.File]::WriteAllText($scriptFile, $ScriptText, [Text.UTF8Encoding]::new($true))
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) { $shell = 'powershell.exe' }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $shell
    $startInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptFile`""
    $startInfo.WorkingDirectory = $WorkRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $output = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $timedOut = $false
    $exitCode = $null
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $outDone = $false; $errDone = $false
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not ($outDone -and $errDone)) {
            $gotLine = $false
            if (-not $outDone -and $outTask.IsCompleted) {
                $line = $outTask.Result
                if ($null -eq $line) { $outDone = $true }
                else { $output.Add($line); Add-LogEntry -Text $line -Color '#A0A0B0'; $outTask = $process.StandardOutput.ReadLineAsync() }
                $gotLine = $true
            }
            if (-not $errDone -and $errTask.IsCompleted) {
                $line = $errTask.Result
                if ($null -eq $line) { $errDone = $true }
                else { $errors.Add($line); Add-LogEntry -Text $line -Color '#FF4D4D'; $errTask = $process.StandardError.ReadLineAsync() }
                $gotLine = $true
            }
            if ($gotLine) { continue }
            if ([DateTime]::UtcNow -gt $deadline) {
                $timedOut = $true
                try { $process.Kill() } catch { Write-Verbose "The script exited before it could be stopped: $($_.Exception.Message)" }
                break
            }
            Invoke-UiPump
            [System.Threading.Thread]::Sleep(50)
        }
        if (-not $timedOut) {
            [void]$process.WaitForExit(30000)
            if ($process.HasExited) { $exitCode = $process.ExitCode }
        }
    } finally { $process.Dispose() }
    return [pscustomobject]@{ ExitCode = $exitCode; TimedOut = $timedOut; Output = @($output.ToArray()); Errors = @($errors.ToArray()) }
}

function Wait-SteamReady {
    param([int]$Timeout = 180)
    if (Test-SandboxMode) {
        Write-Host '[SANDBOX] Not waiting for Steam to load; it is not started in sandbox mode.' -ForegroundColor DarkYellow
        return
    }
    $steamReady = $false
    $elapsed = 0
    Write-Host "Waiting for Steam to fully open (Do not close this window)..." -ForegroundColor Yellow
    Write-Host "!!  DO NOT CLOSE THIS POWERSHELL WINDOW YET  !!" -ForegroundColor Red
    
    while (-not $steamReady -and $elapsed -lt $Timeout) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        
        try {
            $webHelper = Get-Process -Name "steamwebhelper" -ErrorAction SilentlyContinue
            if ($webHelper) { $steamReady = $true }
        } catch { }
    }
    
    Write-Host "" 
    
    if ($steamReady) {
        Write-Host "[OK] Steam client is fully loaded and ready!" -ForegroundColor Green
        Start-Sleep -Seconds 3 
    } else {
        Write-Host "[WARN] Timed out waiting for Steam to load completely, but proceeding..." -ForegroundColor Yellow
    }
}

# Downloads the version-locked Lua file and manifests ZIP into -Destination. Run
# before the fix is reverted and before Steam is closed, so a network problem stops
# the downgrade while nothing has been changed yet.
function Save-DowngradeDownload {
    param([Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { $null = New-Item -ItemType Directory -Path $Destination -Force }
    $luaPath = Join-Path $Destination $SourceFileName
    $zipPath = Join-Path $Destination 'MW4_25909941_manifests.zip'
    Write-Host "`nDownloading the version-locked Lua file and manifests before anything is changed..." -ForegroundColor Yellow
    Download-WithProgress -Url $LuaDownloadUrl -OutFile $luaPath -Activity "Downloading version locked Lua file"
    Download-WithProgress -Url $ZipDownloadUrl -OutFile $zipPath -Activity "Downloading manifests ZIP"
    Write-Host "Both downloads are ready." -ForegroundColor Green
    return [pscustomobject]@{ Lua = $luaPath; ManifestZip = $zipPath }
}

# The whole downgrade in the order that keeps a failure harmless: check it can run,
# download what it needs, and only then revert the fix and change Steam.
function Invoke-PreparedDowngrade {
    param([ValidateSet('Normal', 'Nuclear')][string]$Method = 'Normal')
    $null = Test-SteamDowngradeReadiness -Method $Method
    $prefetchRoot = Join-Path $env:TEMP ('codhq-prefetch-' + [guid]::NewGuid().ToString('N'))
    try {
        $prefetched = Save-DowngradeDownload -Destination $prefetchRoot
        # Revert an applied fix first: its files and backups belong to the version
        # that is about to be replaced.
        Clear-FixBeforeDowngrade -Method $Method
        Invoke-SteamDowngrade -Method $Method -Prefetched $prefetched
    } finally {
        if (Test-Path -LiteralPath $prefetchRoot) { Remove-Item -LiteralPath $prefetchRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-SteamDowngrade {
    # -Prefetched: the Lua file and manifests ZIP already downloaded by
    # Save-DowngradeDownload. Without it they are downloaded here, as before.
    param([string]$Method, $Prefetched = $null)

    Write-Host "`n==================================================" -ForegroundColor Cyan
    Write-Host "       Steam MW4 Version Downgrade Tool" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    $steamRoot = Get-SteamInstallationPath
    if (-not $steamRoot) { Write-Error "Steam installation not found."; return }
    Write-Host "Steam found at: $steamRoot" -ForegroundColor Green
    $plugInDir = Join-Path -Path $steamRoot -ChildPath $SteamConfigSubPath
    # Normal needs the folder already; Nuclear installs BetterSteamTools first and
    # creates the folder afterwards if it is still missing (see below).
    if ($Method -ne "Nuclear" -and -not (Test-Path $plugInDir -PathType Container)) { Write-Error "Folder not found: $plugInDir"; return }

    if ($Method -eq "Nuclear") {
        Write-Host "`n=== INITIATING NUCLEAR METHOD ===" -ForegroundColor Magenta
        Write-Host "`nClosing all Steam processes..." -ForegroundColor Yellow
        $steamProcesses = Get-SteamClientProcess
        if ($steamProcesses) { $steamProcesses | Stop-Process -Force; Start-Sleep -Seconds 3; Write-Host "Steam closed." -ForegroundColor Green }
        Write-Host "Cleaning Steam installation folder (this may take a moment)..." -ForegroundColor Yellow
        $safeItems = @("appcache", "config", "steam", "steamapps", "userdata", "steam.exe")
        $itemsToDelete = Get-ChildItem -Path $steamRoot -Force | Where-Object { $safeItems -notcontains $_.Name }
        foreach ($item in $itemsToDelete) {
            Write-Host "  Removing: $($item.Name)" -ForegroundColor DarkGray
            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Cleanup complete." -ForegroundColor Green
        $steamExe = Join-Path -Path $steamRoot -ChildPath "steam.exe"
        Write-Host "`nStarting Steam..." -ForegroundColor Yellow
        Start-SteamClient -SteamExe $steamExe
        Wait-SteamReady
        Write-Host "`nClosing Steam to run installer..." -ForegroundColor Yellow
        $steamProcesses = Get-SteamClientProcess
        if ($steamProcesses) { $steamProcesses | Stop-Process -Force; Start-Sleep -Seconds 3 }
        Write-Host "`nDownloading BetterSteamTools (irm https://ps.lua.tools/install-ost.ps1 | iex)..." -ForegroundColor Yellow
        # The installer runs in its own powershell.exe: it ends with "exit 1" when it
        # fails, which inside this process would close the administrator window half
        # way through the downgrade. Its output still appears in the log line by line.
        $bstRoot = Join-Path $env:TEMP ('codhq-bst-' + [guid]::NewGuid().ToString('N'))
        if (Test-SandboxMode) {
            # The installer finds Steam through the registry, so it would always change
            # the real Steam; in sandbox mode it is not run at all.
            Write-Host '[SANDBOX] BetterSteamTools is not installed in sandbox mode: its installer always targets the real Steam.' -ForegroundColor DarkYellow
        } else { try {
            $bstScript = ConvertTo-ScriptText (Invoke-RestMethod -Uri "https://ps.lua.tools/install-ost.ps1")
            $bstRun = Invoke-ExternalPowerShellScript -ScriptText $bstScript -WorkRoot $bstRoot -Name 'install-ost' -TimeoutSeconds 600
            if ($bstRun.TimedOut) { Write-Warning 'The BetterSteamTools installer did not finish within 10 minutes and was stopped. Continuing with the downgrade.' }
            elseif ($bstRun.ExitCode -ne 0) { Write-Warning "The BetterSteamTools installer reported an error (exit code $($bstRun.ExitCode)). Continuing with the downgrade." }
            else { Write-Ok 'BetterSteamTools installer finished.' }
        } catch { Write-Warning "Failed to run the installer script: $($_.Exception.Message)" }
        finally { if (Test-Path -LiteralPath $bstRoot) { Remove-Item -LiteralPath $bstRoot -Recurse -Force -ErrorAction SilentlyContinue } } }
        Write-Host "`nRestarting Steam (via BetterSteamTools)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        Start-SteamClient -SteamExe $steamExe -OnlyIfNotRunning
        Wait-SteamReady
        Write-Host "`nNuclear method phase complete. Proceeding to normal installation..." -ForegroundColor Magenta
        # BetterSteamTools reads Lua files from config\stplug-in (its own config says
        # so) but does not create that folder.
        if (-not (Test-Path $plugInDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $plugInDir -Force
            Write-Ok "Created $plugInDir, the folder BetterSteamTools reads Lua files from."
        }
    }

    Write-Host "`nClosing all Steam processes..." -ForegroundColor Yellow
    $steamProcesses = Get-SteamClientProcess
    if ($steamProcesses) { $steamProcesses | Stop-Process -Force; Start-Sleep -Seconds 3; Write-Host "Steam closed." -ForegroundColor Green }

    # The old Lua files and this game's depotcache manifests are moved to a temporary
    # backup instead of being deleted. They are only deleted for good once the new
    # Lua file and manifests are downloaded and in place; if anything fails first,
    # they are moved back so Steam is left exactly as it was.
    $workRoot = Join-Path $env:TEMP ('codhq-downgrade-' + [guid]::NewGuid().ToString('N'))
    $backupLuaDir = Join-Path $workRoot 'backup\stplug-in'
    $backupDepotDir = Join-Path $workRoot 'backup\depotcache'
    $depotCacheDir = Join-Path -Path $steamRoot -ChildPath "depotcache"
    $newLuaPath = Join-Path -Path $plugInDir -ChildPath $TargetFileName
    $movedLua = [System.Collections.Generic.List[object]]::new()
    $movedManifests = [System.Collections.Generic.List[object]]::new()
    $extractJournal = [System.Collections.Generic.List[object]]::new()
    $backupExtractDir = Join-Path $workRoot 'backup\extracted'
    $newLuaPlaced = $false
    $manifestsMoved = $false
    $null = New-Item -ItemType Directory -Path $backupLuaDir -Force
    $null = New-Item -ItemType Directory -Path $backupDepotDir -Force

    try {
        Write-Host "`nMoving old Lua files to a temporary backup..." -ForegroundColor Yellow
        foreach ($file in @($TargetFileName, $SourceFileName)) {
            $fullPath = Join-Path -Path $plugInDir -ChildPath $file
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $backupPath = Join-Path $backupLuaDir $file
                Move-Item -LiteralPath $fullPath -Destination $backupPath -Force -ErrorAction Stop
                $movedLua.Add([pscustomobject]@{ Original = $fullPath; Backup = $backupPath })
                Write-Host "Backed up: $file" -ForegroundColor Green
            }
        }

        # Downloaded into the work folder, so a failed download never leaves a
        # partial file in stplug-in.
        $tempLua = Join-Path $workRoot $SourceFileName
        if ($null -ne $Prefetched) {
            Write-Host "`nUsing the version locked Lua file downloaded earlier..." -ForegroundColor Yellow
            Copy-Item -LiteralPath $Prefetched.Lua -Destination $tempLua -Force -ErrorAction Stop
        } else {
            Write-Host "`nDownloading version locked Lua file..." -ForegroundColor Yellow
            Download-WithProgress -Url $LuaDownloadUrl -OutFile $tempLua -Activity "Downloading version locked Lua file"
        }
        Move-Item -LiteralPath $tempLua -Destination $newLuaPath -Force -ErrorAction Stop
        $newLuaPlaced = $true
        Write-Host "Downloaded and installed as: $TargetFileName" -ForegroundColor Green

        if (Test-Path -LiteralPath $depotCacheDir -PathType Container) {
            Write-Host "`nMoving this game's old manifests from depotcache to a temporary backup..." -ForegroundColor Yellow
            foreach ($manifest in @(Get-ChildItem -LiteralPath $depotCacheDir -Filter "*.manifest" -File)) {
                foreach ($id in $codDepotIds) {
                    if ($manifest.Name.StartsWith("$($id)_")) {
                        $backupPath = Join-Path $backupDepotDir $manifest.Name
                        Move-Item -LiteralPath $manifest.FullName -Destination $backupPath -Force -ErrorAction Stop
                        $movedManifests.Add([pscustomobject]@{ Original = $manifest.FullName; Backup = $backupPath })
                        break
                    }
                }
            }
            Write-Host "Moved $($movedManifests.Count) old manifest files to the temporary backup." -ForegroundColor Green
        } else { Write-Host "`nDepotcache folder not found. It will be created by extraction." -ForegroundColor Gray }
        $manifestsMoved = $true

        $tempZip = Join-Path $workRoot "MW4_25909941_manifests.zip"
        if ($null -ne $Prefetched) {
            Write-Host "`nUsing the manifests ZIP downloaded earlier..." -ForegroundColor Yellow
            Copy-Item -LiteralPath $Prefetched.ManifestZip -Destination $tempZip -Force -ErrorAction Stop
        } else {
            Write-Host "`nDownloading manifests ZIP..." -ForegroundColor Yellow
            Download-WithProgress -Url $ZipDownloadUrl -OutFile $tempZip -Activity "Downloading manifests ZIP"
        }
        Write-Host "Extracting downgrade manifests into Steam root: $steamRoot" -ForegroundColor Gray
        Expand-ZipOverwrite -ZipPath $tempZip -DestinationPath $steamRoot -Journal $extractJournal -BackupDirectory $backupExtractDir
        Write-Host "Downgrade manifests extracted successfully." -ForegroundColor Green
    } catch {
        Write-Warning "The new Lua file or manifests could not be installed. Restoring the previous ones..."
        $restoreFailed = $false
        # Remove whatever the new files already put in place. Only files this run
        # created are touched: an original that was never moved stays where it is.
        if ($newLuaPlaced -and (Test-Path -LiteralPath $newLuaPath -PathType Leaf)) {
            try { Remove-Item -LiteralPath $newLuaPath -Force -ErrorAction Stop } catch { $restoreFailed = $true; Write-Warning "Could not remove the new Lua file: $newLuaPath" }
        }
        # Every file the manifest ZIP wrote or overwrote, wherever in the Steam folder.
        if (-not (Undo-ZipExtraction -Journal $extractJournal)) { $restoreFailed = $true }
        if ($manifestsMoved -and (Test-Path -LiteralPath $depotCacheDir -PathType Container)) {
            # Every matching manifest was moved out before extraction began, so any
            # matching one present now came from the new ZIP.
            foreach ($manifest in @(Get-ChildItem -LiteralPath $depotCacheDir -Filter "*.manifest" -File -ErrorAction SilentlyContinue)) {
                foreach ($id in $codDepotIds) {
                    if ($manifest.Name.StartsWith("$($id)_")) {
                        try { Remove-Item -LiteralPath $manifest.FullName -Force -ErrorAction Stop } catch { $restoreFailed = $true; Write-Warning "Could not remove a new manifest: $($manifest.FullName)" }
                        break
                    }
                }
            }
        }
        foreach ($record in @($movedLua) + @($movedManifests)) {
            try { Move-Item -LiteralPath $record.Backup -Destination $record.Original -Force -ErrorAction Stop }
            catch { $restoreFailed = $true; Write-Warning "Could not restore: $($record.Original)" }
        }
        if ($restoreFailed) {
            # Keep the backup so nothing is lost; the user can copy files back by hand.
            Write-Warning "Some files could not be restored automatically. The backup was kept at: $workRoot"
        } else {
            Write-Host "Restored $($movedLua.Count) Lua file(s) and $($movedManifests.Count) manifest file(s)." -ForegroundColor Green
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    # Both downloads succeeded and the new files are in place: the backup is no
    # longer needed.
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Deleted the temporary backup of the old Lua file and manifests." -ForegroundColor Green

    $acfPath = Join-Path -Path $steamRoot -ChildPath "steamapps\$AppManifestFile"
    $acfFixed = $false
    if (Test-Path $acfPath) {
        Write-Host "`nModifying $AppManifestFile to bypass disk space check..." -ForegroundColor Yellow
        try {
            Set-ItemProperty -Path $acfPath -Name IsReadOnly -Value $false
            # Steam writes appmanifests as UTF-8 without a BOM; read and write them the
            # same way so a non-ASCII game or folder name survives the edit.
            $content = [IO.File]::ReadAllText($acfPath, [Text.UTF8Encoding]::new($false))
            if ($content -match '"StateFlags"') {
                $content = $content -replace '"StateFlags"\s*"\d+"', '"StateFlags"		"4"'
                $content = $content -replace '"BytesToDownload"\s*"\d+"', '"BytesToDownload"		"0"'
                $content = $content -replace '"BytesDownloaded"\s*"\d+"', '"BytesDownloaded"		"0"'
                $content = $content -replace '"UpdateResult"\s*"\d+"', '"UpdateResult"		"0"'
                $content = $content -replace '"SizeOnDisk"\s*"\d+"', '"SizeOnDisk"		"0"'
                $content = $content -replace '"buildid"\s*"\d+"', '"buildid"		"1"'
                [IO.File]::WriteAllText($acfPath, $content, [Text.UTF8Encoding]::new($false))
                $acfFixed = $true
                Write-Host "AppManifest modified successfully. Steam will treat the game as already installed." -ForegroundColor Green
            } else { Write-Warning "The AppManifest file is severely corrupted (missing StateFlags)." }
        } catch { Write-Warning "Failed to modify the appmanifest file: $_" }
    }

    if (-not $acfFixed -and (Test-Path $acfPath)) {
        Write-Host "`nDeleting corrupted AppManifest to force a full rebuild..." -ForegroundColor Yellow
        try {
            Set-ItemProperty -Path $acfPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            Remove-Item -Path $acfPath -Force -ErrorAction Stop
            Write-Host "Deleted $AppManifestFile successfully." -ForegroundColor Green
            Write-Host "NOTE: Because the file was deleted, the 'Install' button might be greyed out if you are low on disk space." -ForegroundColor Red
        } catch { Write-Warning "Could not delete the appmanifest file. Please delete it manually: $acfPath" }
    }

    $steamExe = Join-Path -Path $steamRoot -ChildPath "steam.exe"
    if (Test-Path $steamExe) {
        Write-Host "`nLaunching Steam..." -ForegroundColor Yellow
        Start-SteamClient -SteamExe $steamExe
        Wait-SteamReady
        Write-Host "`nTriggering automatic validation..." -ForegroundColor Cyan
        Start-SteamValidation
        Write-Host ">> IMPORTANT: Steam should now begin validating your files." -ForegroundColor Cyan
    } else { Write-Warning "steam.exe was not found at the expected path: $steamExe" }
    
    Write-Host "`n=== Operation Complete ===" -ForegroundColor Cyan
}

# ==========================================
# GAMES: CATALOGUE AND DETECTION
# ==========================================
# The older Call of Duty games and their community clients, researched from the CB
# Servers launcher (docs/cb-launcher/). Executables, modes and arguments follow its
# game_config.cpp; which client files may be downloaded follows the per-file audit in
# docs/cb-launcher/manifests.md:
#   Allow  - path patterns the client project publishes (anything else in a manifest is
#            skipped, so a new, unaudited file is never downloaded automatically);
#   Deny   - copies of the game's own files, never downloaded;
#   Derive - a denied name the client needs, made from the player's own file when its
#            SHA-1 matches the manifest (for example miles32.dll from mss32.dll).
# Source 'cb' clients come from CB's public updater repository (CDN mirror, then
# GitHub); 'github' clients from the project's own release, pinned by SHA-256;
# 'plutonium' from Plutonium's own server.

function New-CatalogClient {
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Name, [string]$Source = 'cb',
        [string]$Manifest = '', [string]$Folder = '', [string[]]$Allow = @(), [string[]]$Deny = @(),
        [hashtable]$Derive = @{}, [string]$AppData = '', [string[]]$GameFiles = @(), [object[]]$Assets = @(),
        # GitHub release the assets come from, for update checks.
        [string]$ReleaseRepo = '', [string]$ReleaseTag = '',
        # Clients of the same game that cannot be installed at the same time.
        [string[]]$Conflicts = @(),
        # Game files a launcher-type client's own launcher replaces later: backed up at
        # install, put back by Remove.
        [string[]]$Protect = @(),
        # Where such a launcher adds files: what is new there since the install is deleted
        # by Remove (after asking, with -ConfirmCleanup).
        [string[]]$Watch = @(), [bool]$ConfirmCleanup = $false,
        # Text shown as the tooltip of the client's install button.
        [string]$Description = '',
        # A release archive installed exactly as published: it goes into the game folder
        # as it is (pinned by SHA-256; its contents are not listed in the catalogue).
        $Archive = $null, [bool]$Extract = $false,
        # Clients this one is put on top of: they have to be installed first.
        [string[]]$Requires = @(),
        # Files the archive has to contain; the game's marker files when empty.
        [string[]]$RequiredFiles = @(),
        # Everything in the game folder except KeepFiles is moved into the backup before
        # the archive is extracted, so it lands in a folder of its own files only.
        [bool]$CleanInstall = $false, [string[]]$KeepFiles = @()
    )
    [pscustomobject]@{ Id = $Id; Name = $Name; Source = $Source; Manifest = $Manifest; Folder = $Folder; Allow = @($Allow); Deny = @($Deny)
        Derive = $Derive; AppData = $AppData; GameFiles = @($GameFiles); Assets = @($Assets)
        ReleaseRepo = $ReleaseRepo; ReleaseTag = $ReleaseTag; Conflicts = @($Conflicts)
        Protect = @($Protect); Watch = @($Watch); ConfirmCleanup = $ConfirmCleanup; Description = $Description
        Archive = $Archive; Extract = $Extract; Requires = @($Requires); RequiredFiles = @($RequiredFiles)
        CleanInstall = $CleanInstall; KeepFiles = @($KeepFiles) }
}

function New-CatalogMode {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Label, [string]$Kind = 'exe', [string]$Exe = '',
          [string]$Arguments = '', [string[]]$Clients = @(), [bool]$UseName = $true, [string]$Uri = '',
          [bool]$Elevate = $false, [bool]$NoDefaultArguments = $false,
          # Values written to a JSON settings file in the game folder before starting:
          # @{ File = 'x.json'; Values = @{ 'section.key' = 'value' }; NameKey = 'section.key' }.
          $Config = $null)
    [pscustomobject]@{ Id = $Id; Label = $Label; Kind = $Kind; Exe = $Exe; Arguments = $Arguments; Clients = @($Clients); UseName = $UseName; Uri = $Uri
        Elevate = $Elevate; NoDefaultArguments = $NoDefaultArguments; Config = $Config }
}

# Catalogue entries for the files of one release archive: each is taken out of the
# archive (downloaded once, SHA-256 checked) and checked against its own SHA-256.
function Get-ArchiveAssetList {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][int64]$Size, [Parameter(Mandatory)][string]$Sha256, [Parameter(Mandatory)][object[]]$Entries)
    $archive = [pscustomobject]@{ Url = $Url; Size = $Size; Sha256 = $Sha256 }
    foreach ($entry in $Entries) { [pscustomobject]@{ Path = [string]$entry[0]; Entry = [string]$entry[0]; Size = [int64]$entry[1]; Sha256 = [string]$entry[2]; Archive = $archive } }
}

# The single folder an archive wraps all its files in, or '' when it has none. A wrapper
# that is one of the game's own folders (a ZIP that starts with main/, miles/, pb/ or
# uo/) is already the game layout and is never stripped.
function Get-GameArchiveRoot {
    param([Parameter(Mandatory)][string]$ZipPath, [string[]]$KeepFolders = @('main', 'miles', 'pb', 'uo', 'zone', 'players2'))
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $tops = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $zip.Entries) {
            $path = $entry.FullName -replace '\\', '/'
            if ([string]::IsNullOrEmpty($path)) { continue }
            $slash = $path.IndexOf('/')
            if ($slash -lt 0) { return '' }
            $top = $path.Substring(0, $slash)
            if ($tops.Count -eq 0) { $tops.Add($top) }
            elseif ($tops[0] -ine $top) { return '' }
        }
        if ($tops.Count -ne 1) { return '' }
        foreach ($keep in @($KeepFolders)) { if ($tops[0] -ieq $keep) { return '' } }
        return $tops[0]
    } finally { $zip.Dispose() }
}

# The Plutonium bootstrapper and the AlterWare launcher are shared by several games.
function Get-PlutoniumClient {
    New-CatalogClient -Id 'plutonium' -Name 'Plutonium' -Source 'plutonium' -Assets @(
        [pscustomobject]@{ Path = 'plutonium.exe'; Url = 'https://cdn.plutonium.pw/updater/plutonium.exe'; Size = 4863736; Sha256 = '85d1d1ca4d5881d9b98928c2006fb0eec9655e2705fe74088e6f974a19703f0f' })
}

function Get-GameCatalog {
    # The Games page sorts these by Year, so the order below is only for reading.
    $cod4Deny = @('iw3mp.exe')
    $cod4Derive = @{ 'miles32.dll' = 'mss32.dll' }
    @(
        # Call of Duty (2003): the 1.1 singleplayer and multiplayer files, from this
        # project's own release, installed exactly as published.
        [pscustomobject]@{ Id = 'cod1'; Name = 'Call of Duty'; Year = '2003'; SteamAppIds = @(2620); Detect = 'steam'
            ValidFiles = @('CoDSP.exe', 'CoDMP.exe'); NameArgument = '+set name'; DefaultArguments = '+set com_hunkmegs 512 +set r_lodbias -1000'
            NeedsElevation = $false; DpiFix = @('CoDSP.exe', 'CoDMP.exe'); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'cod1-v11' -Name '1.1 (singleplayer and MP)' -Source 'archive' -Extract $true -CleanInstall $true -KeepFiles @('CoDSP.exe', 'CoDMP.exe') -Description 'Moves everything in the game folder except CoDSP.exe and CoDMP.exe into the backup, then copies the 1.1 files in.' -Archive @{
                    Url = 'https://github.com/LarkTheStar/fix-installer/releases/download/1.1/Call.of.Duty.1.1.SP.MP.zip'
                    Size = 1207836351
                    Sha256 = '715bef06e94a98b5654fee62da81cd5f17ded051a88b84890e7df0db06c91652' }),
                # 1.1X is a community multiplayer patch that goes on top of 1.1: it replaces
                # CoDMP.exe and adds cod1x.dll. The 1.1/1.1x servers use it.
                (New-CatalogClient -Id 'cod1-v11x' -Name '1.1X (Multiplayer patch)' -Source 'archive' -Extract $true -Requires @('cod1-v11') -RequiredFiles @('CoDMP.exe', 'cod1x.dll') -Description 'Installs the community 1.1X multiplayer patch on top of 1.1. Install 1.1 (singleplayer and MP) first.' -Archive @{
                    Url = 'https://github.com/LarkTheStar/fix-installer/releases/download/1.1/CoD1x_Archive.zip'
                    Size = 2067295
                    Sha256 = 'c2b31367dfbe418b1415c4ab8183fb51e6e2baadc70870d405fbba85ff19814d' }))
            Note = 'Install 1.1 moves everything in the game folder except CoDSP.exe and CoDMP.exe into the backup, then copies the 1.1 files in, so nothing old is left to clash with them. 1.1X goes on top of 1.1: install 1.1 first. Remove takes 1.1X and 1.1 away and puts every original file back.'
            Modes = @((New-CatalogMode 'sp' 'Singleplayer' -Exe 'CoDSP.exe' -Clients @('cod1-v11')), (New-CatalogMode 'mp' 'Multiplayer' -Exe 'CoDMP.exe' -Clients @('cod1-v11')))
            # The 1.1 archive is the whole singleplayer and multiplayer file set, so a folder
            # the player picks or creates is enough: Install writes the game files there.
            AllowEmptyFolder = $true
            Available = $true; UnavailableReason = '' }
        # United Offensive and Call of Duty 2: cards only for now. They find the game and
        # list it; a client can be added when there is one to place.
        # United Offensive is installed where the player says, not into the Call of Duty
        # (2003) folder, where its files would sit next to the 1.1 ones and clash with
        # them. Nothing is looked for in Steam: the folder is the one picked.
        [pscustomobject]@{ Id = 'coduo'; Name = 'Call of Duty: United Offensive'; Year = '2004'; SteamAppIds = @(); Detect = 'none'
            ValidFiles = @('CoDUOSP.exe', 'CoDUOMP.exe'); NameArgument = '+set name'; DefaultArguments = '+set com_hunkmegs 512 +set r_lodbias -1000'
            NeedsElevation = $false; DpiFix = @('CoDUOSP.exe', 'CoDUOMP.exe'); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @(); Modes = @()
            Note = 'Pick the folder to put United Offensive in with Change folder: it is not looked for in Steam, and it is not installed over Call of Duty (2003).'
            AllowEmptyFolder = $true
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'cod2'; Name = 'Call of Duty 2'; Year = '2005'; SteamAppIds = @(2630); Detect = 'steam'
            ValidFiles = @('CoD2SP_s.exe', 'CoD2MP_s.exe'); NameArgument = '+set name'; DefaultArguments = ''
            NeedsElevation = $true; DpiFix = @('CoD2SP_s.exe', 'CoD2MP_s.exe'); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @(); Modes = @()
            Note = 'No client to install yet: the card finds the game and nothing else for now.'
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'cod4'; Name = 'Call of Duty 4: Modern Warfare'; Year = '2007'; SteamAppIds = @(7940); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 'iw3mp.exe', 'iw3sp.exe'); NameArgument = '+set name'; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = 'cod4'; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @(
                (New-CatalogClient -Id 'iw3x' -Name 'iw3x (CoD4R)' -Manifest 'iw3x.json' -Folder 'iw3x/' -AppData 'CallofDuty4MW' -Allow @('bin/*', 'main/*', 'zone/*', 'mss32.dll', 'miles32.dll') -Deny ($cod4Deny + 'miles32.dll') -Derive $cod4Derive),
                (New-CatalogClient -Id 'cod4x' -Name 'CoD4x' -Manifest 'cod4x-mp.json' -Folder 'cod4x-mp/' -AppData 'CallofDuty4MW' -Allow @('bin/*', 'main/*', 'zone/*', 'mss32.dll', 'miles32.dll') -Deny ($cod4Deny + 'miles32.dll') -Derive $cod4Derive),
                (New-CatalogClient -Id 'iw3sp-mod' -Name 'IW3SP-Mod' -Manifest 'iw3sp-mod.json' -Folder 'iw3sp-mod/' -AppData 'CallofDuty4MW' -Allow @('bin/*', 'game.dll', 'iw3sp_data/*', 'iw3sp_mod.exe', 'mss32.dll', 'miles32.dll') -Deny @('miles32.dll') -Derive $cod4Derive))
            Note = 'Multiplayer uses iw3x or CoD4x with your own iw3mp.exe; the campaign uses IW3SP-Mod.'
            Modes = @((New-CatalogMode 'mp' 'Multiplayer' -Exe 'iw3mp.exe' -Clients @('iw3x', 'cod4x')), (New-CatalogMode 'sp' 'Campaign (IW3SP-Mod)' -Exe 'iw3sp_mod.exe' -Arguments '+set iw3sp_auto_update 0' -Clients @('iw3sp-mod')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'waw'; Name = 'Call of Duty: World at War'; Year = '2008'; SteamAppIds = @(10090); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 'CoDWaW.exe', 'CoDWaWmp.exe'); NameArgument = ''; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = 't4Path'; ExeCheck = $null; ProjectUrl = ''
            Clients = @((Get-PlutoniumClient)); Note = 'Plutonium needs a free Plutonium account; sign in with the Plutonium login button.'
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Kind 'plutonium' -Uri 't4sp' -Clients @('plutonium')), (New-CatalogMode 'mp' 'Multiplayer' -Kind 'plutonium' -Uri 't4mp' -Clients @('plutonium')), (New-CatalogMode 'zm' 'Zombies' -Kind 'plutonium' -Uri 't4sp' -Clients @('plutonium')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'mw2'; Name = 'Call of Duty: Modern Warfare 2'; Year = '2009'; SteamAppIds = @(10180); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 'iw4mp.exe', 'iw4sp.exe'); NameArgument = '+set name'; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'iw4x' -Name 'IW4x' -Manifest 'iw4x.json' -Folder 'iw4x/' -Allow @('iw4x.dll', 'iw4x.exe', 'companion64.dll', 'zonebuilder.exe', 'Unlinker.exe', 'alterware-launcher.exe', 'iw4x/*', 'zone/*', 'miles/*', 'crash-reporter/*') -Deny @('binkw32.dll', 'mss32.dll', 'iw4mp.exe', 'iw4sp.exe')))
            Note = 'IW4x for multiplayer; the campaign and Spec Ops start through AlterWare, which IW4x includes.'
            Modes = @((New-CatalogMode 'mp' 'Multiplayer' -Exe 'iw4x.exe' -Clients @('iw4x')), (New-CatalogMode 'sp' 'Campaign / Spec Ops' -Exe 'alterware-launcher.exe' -Arguments 'iw4x-sp --skip-launcher-update' -Clients @('iw4x') -UseName $false))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'bo1'; Name = 'Call of Duty: Black Ops'; Year = '2010'; SteamAppIds = @(42700); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 'BlackOps.exe', 'BlackOpsMP.exe'); NameArgument = ''; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = 't5Path'; ExeCheck = $null; ProjectUrl = ''
            Clients = @((Get-PlutoniumClient)); Note = 'Plutonium needs a free Plutonium account; sign in with the Plutonium login button.'
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Kind 'plutonium' -Uri 't5sp' -Clients @('plutonium')), (New-CatalogMode 'mp' 'Multiplayer' -Kind 'plutonium' -Uri 't5mp' -Clients @('plutonium')), (New-CatalogMode 'zm' 'Zombies' -Kind 'plutonium' -Uri 't5sp' -Clients @('plutonium')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'mw3'; Name = 'Call of Duty: Modern Warfare 3'; Year = '2011'; SteamAppIds = @(42680); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 'iw5mp.exe', 'iw5sp.exe'); NameArgument = '+set name'; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = 'iw5Path'; ExeCheck = $null; ProjectUrl = ''
            Clients = @((Get-PlutoniumClient), (New-CatalogClient -Id 'alterware' -Name 'AlterWare' -Manifest 'alt-launchers.json' -Folder 'alt-launchers/' -Allow @('alterware-launcher.exe')))
            Note = 'Plutonium for multiplayer (needs a free Plutonium account); AlterWare for the campaign and Spec Ops.'
            Modes = @((New-CatalogMode 'mp' 'Multiplayer' -Kind 'plutonium' -Uri 'iw5mp' -Clients @('plutonium')), (New-CatalogMode 'sp' 'Campaign / Spec Ops' -Exe 'alterware-launcher.exe' -Arguments 'iw5-mod --skip-launcher-update --pass "-singleplayer"' -Clients @('alterware') -UseName $false))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'bo2'; Name = 'Call of Duty: Black Ops II'; Year = '2012'; SteamAppIds = @(202970); Detect = 'steam'
            ValidFiles = @('binkw32.dll', 't6mp.exe', 't6zm.exe', 't6sp.exe'); NameArgument = ''; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = 't6Path'; ExeCheck = $null; ProjectUrl = ''
            Clients = @((Get-PlutoniumClient), (New-CatalogClient -Id 't6sp-mod' -Name 'T6SP-Mod' -Source 'github' -ReleaseRepo 'Rattpak/T6SP-Mod-Release' -ReleaseTag 'v1.0.0-Beta' -Assets @(
                    [pscustomobject]@{ Path = 'T6SP-Mod.exe'; Url = 'https://github.com/Rattpak/T6SP-Mod-Release/releases/download/v1.0.0-Beta/T6SP-Mod.exe'; Size = 11338240; Sha256 = '9224396f424e6c010f0e91f9893d453eb99c7265735fc785f9b5f166fa4394e7' },
                    [pscustomobject]@{ Path = 't6sp-mod.dll'; Url = 'https://github.com/Rattpak/T6SP-Mod-Release/releases/download/v1.0.0-Beta/t6sp-mod.dll'; Size = 2551296; Sha256 = '965d010e8fdfbb454fb830d4e3ee108218223cbb101585f2c8ae407e63e956b5' })))
            Note = 'Plutonium for multiplayer and Zombies (needs a free Plutonium account); T6SP-Mod for the campaign.'
            Modes = @((New-CatalogMode 'mp' 'Multiplayer' -Kind 'plutonium' -Uri 't6mp' -Clients @('plutonium')), (New-CatalogMode 'zm' 'Zombies' -Kind 'plutonium' -Uri 't6zm' -Clients @('plutonium')), (New-CatalogMode 'sp' 'Campaign (T6SP-Mod)' -Exe 'T6SP-Mod.exe' -Clients @('t6sp-mod') -UseName $false))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'ghosts'; Name = 'Call of Duty: Ghosts'; Year = '2013'; SteamAppIds = @(209160); Detect = 'steam'
            ValidFiles = @('iw6mp64_ship.exe', 'iw6sp64_ship.exe'); NameArgument = '+set name'; DefaultArguments = '-noupdate'
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'iw6x' -Name 'IW6x' -Manifest 'iw6x.json' -Folder 'iw6x/' -Allow @('iw6x.exe', 'data/*'))); Note = ''
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Exe 'iw6x.exe' -Arguments '-singleplayer' -Clients @('iw6x')), (New-CatalogMode 'mp' 'Multiplayer' -Exe 'iw6x.exe' -Arguments '-multiplayer' -Clients @('iw6x')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'aw'; Name = 'Call of Duty: Advanced Warfare'; Year = '2014'; SteamAppIds = @(209650); Detect = 'steam'
            ValidFiles = @('s1_sp64_ship.exe', 's1_mp64_ship.exe'); NameArgument = '+set name'; DefaultArguments = '-noupdate'
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 's1x' -Name 'S1x' -Manifest 's1x.json' -Folder 's1x/' -Allow @('s1x.exe', 'data/*'))); Note = ''
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Exe 's1x.exe' -Arguments '-singleplayer' -Clients @('s1x')), (New-CatalogMode 'mp' 'Multiplayer' -Exe 's1x.exe' -Arguments '-multiplayer' -Clients @('s1x')), (New-CatalogMode 'zm' 'Exo Zombies' -Exe 's1x.exe' -Arguments '-zombies' -Clients @('s1x')), (New-CatalogMode 'sv' 'Exo Survival' -Exe 's1x.exe' -Arguments '-survival' -Clients @('s1x')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'bo3'; Name = 'Call of Duty: Black Ops III'; Year = '2015'; SteamAppIds = @(311210); Detect = 'steam'
            ValidFiles = @('BlackOps3.exe'); NameArgument = '-name'; DefaultArguments = '-launch -noupdate'
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ProjectUrl = ''
            ExeCheck = [pscustomobject]@{ File = 'BlackOps3.exe'; Manifest = 'boiii.json'; Repair = 'In Steam: right-click Black Ops III > Properties > Installed Files > Verify integrity of game files.' }
            Clients = @((New-CatalogClient -Id 'boiii' -Name 'BOIII' -Manifest 'boiii.json' -Folder 'boiii/' -AppData 'boiii' -GameFiles @('boiii.exe') -Allow @('boiii.exe', 'data/*') -Deny @('BlackOps3.exe')))
            Note = 'BOIII runs your own BlackOps3.exe; use Check game exe if it does not start.'
            Modes = @((New-CatalogMode 'play' 'Play' -Exe 'boiii.exe' -Clients @('boiii')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'iw'; Name = 'Call of Duty: Infinite Warfare'; Year = '2016'; SteamAppIds = @(292730); Detect = 'steam'
            ValidFiles = @('iw7_ship.exe'); NameArgument = '+set name'; DefaultArguments = '-noupdate'
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'iw7-mod' -Name 'IW7-Mod' -Manifest 'iw7-mod/files.json' -Folder 'iw7-mod/data/' -AppData 'auroramod\iw7-mod' -GameFiles @('iw7-mod.exe') -Allow @('iw7-mod.exe', 'cdata/*')))
            Note = ''; Modes = @((New-CatalogMode 'play' 'Play' -Exe 'iw7-mod.exe' -Clients @('iw7-mod')))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'mwr'; Name = 'Call of Duty: Modern Warfare Remastered'; Year = '2017'; SteamAppIds = @(393080); Detect = 'steam'
            ValidFiles = @('h1_sp64_ship.exe', 'h1_mp64_ship.exe'); NameArgument = '+set name'; DefaultArguments = '-noupdate'
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'h1-mod' -Name 'H1-Mod' -Manifest 'h1-mod/files.json' -Folder 'h1-mod/data/' -AppData 'h1-mod' -GameFiles @('h1-mod.exe') -Allow @('h1-mod.exe', 'cdata/*') -Conflicts @('h1-mod-aurora')),
                (New-CatalogClient -Id 'h1-mod-aurora' -Name 'H1-Mod (AuroraMod release)' -Source 'github' -ReleaseRepo 'auroramod/h1-mod' -ReleaseTag 'v2.1.1' -Conflicts @('h1-mod') -Assets @(
                    [pscustomobject]@{ Path = 'h1-mod.exe'; Url = 'https://github.com/auroramod/h1-mod/releases/download/v2.1.1/h1-mod.exe'; Size = 10039808; Sha256 = '4d818232ea6103682f74da480206017cf66a7da1ef1a24107355f6c5f709d308' })))
            Note = 'Two sources for H1-Mod: CB''s build or AuroraMod''s own release (which updates its data itself when it starts). Install one of them.'
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Exe 'h1-mod.exe' -Arguments '-singleplayer' -Clients @('h1-mod')), (New-CatalogMode 'mp' 'Multiplayer' -Exe 'h1-mod.exe' -Arguments '-multiplayer' -Clients @('h1-mod')),
                (New-CatalogMode 'sp-aurora' 'Campaign (AuroraMod)' -Exe 'h1-mod.exe' -Arguments '-singleplayer' -Clients @('h1-mod-aurora') -NoDefaultArguments $true),
                (New-CatalogMode 'mp-aurora' 'Multiplayer (AuroraMod)' -Exe 'h1-mod.exe' -Arguments '-multiplayer' -Clients @('h1-mod-aurora') -NoDefaultArguments $true))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'mw2cr'; Name = 'Call of Duty: Modern Warfare 2 Campaign Remastered'; Year = '2020'; SteamAppIds = @(); Detect = 'folder'
            ValidFiles = @('MW2CR.exe', 'MW2 Campaign Remastered Launcher.exe'); NameArgument = ''; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = ''
            Clients = @((New-CatalogClient -Id 'h2-mod' -Name 'H2-Mod' -Manifest 'h2-mod.json' -Folder 'h2-mod/' -AppData 'h2-mod' -GameFiles @('h2-mod.exe') -Allow @('h2-mod.exe', 'cdata/*')))
            Note = 'Not sold on Steam; pick its folder with Change folder.'
            Modes = @((New-CatalogMode 'sp' 'Campaign' -Exe 'h2-mod.exe' -Arguments '-singleplayer +set cg_auto_update 0' -Clients @('h2-mod') -UseName $false))
            Available = $true; UnavailableReason = '' }
        [pscustomobject]@{ Id = 'bo4'; Name = 'Call of Duty: Black Ops 4'; Year = '2018'; SteamAppIds = @(); Detect = 'battlenet'
            ValidFiles = @('BlackOps4.exe', 'BlackOps4_boot.exe', 'Black Ops 4 Launcher.exe'); NameArgument = '-name'; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ProjectUrl = ''
            ExeCheck = [pscustomobject]@{ File = 'BlackOps4.exe'; Manifest = 'project-bo4.json'; Repair = 'In Battle.net: select Black Ops 4 > the gear next to Play > Scan and Repair.' }
            # Shield's official launcher (NotNierPea/shield-launcher) goes into the game folder
            # as its guide says; it downloads the client, the support mod and Target Range
            # itself (run headless with --sync) and prepares the game each time it starts it.
            # The player's own BlackOps4.exe and LPC files are backed up before it runs.
            Clients = @((New-CatalogClient -Id 'shield' -Name 'Project BO4 (Shield)' -Source 'shield' -ReleaseRepo 'NotNierPea/shield-launcher' -ReleaseTag 'Release' -Protect @('BlackOps4.exe', 'LPC\*') -Watch @('project-bo4\*', 'LPC\*', 'XInput9_1_0.dll', 'discord_game_sdk.dll', 'project-bo4.json', 'BlackOps4.start', 'BlackOps4.exe') -Assets @(
                    (Get-ArchiveAssetList -Url 'https://github.com/NotNierPea/shield-launcher/releases/download/Release/Project_BO4_Launcher_Update_1.1.4.zip' -Size 5127341 -Sha256 '04044074780574075616cc1050090fd2b7611467bbfcdfd9016059cda5fb3a8b' -Entries @(
                        @('Launch Project BO4.exe', 112640, 'f9d7d012110511497e8f9fc585d7cba24eefbed894b5167d2443e55f8617db6d'),
                        @('project-bo4/launcher/Shield_Launcher.exe', 644096, 'c90219d57eaaf01f6fa4f061a1797bc2224ff0f92b14d5a4fad04a1c7800065c'),
                        @('project-bo4/launcher/images/launcher.jpg', 178864, 'c6256a24fa8d2103323af7c06c537d73b519ff1e488c60ffaab4ef3b19b8a19b'),
                        @('project-bo4/launcher/images/launcher.png', 280896, '3299f8fba90c5e7f8cdcc666303113d3f80aa992217861ff426b194bbb427cf6'),
                        @('project-bo4/launcher/Sounds/startup_sound.mp3', 4431360, 'c609c9f853698653f2543a43d1a805dcb40f2550de24d8fa336cceefab3b72dd'))))))
            Note = 'Install downloads Shield''s client files (about 2.2 GB) with its own launcher. Play opens Shield''s launcher with your name and server set; press Play Client there. Repair fixes the black screen at start.'
            Modes = @(
                (New-CatalogMode 'online' 'Online' -Exe 'Launch Project BO4.exe' -Clients @('shield') -UseName $false -NoDefaultArguments $true -Config @{ File = 'project-bo4.json'; Values = @{ 'demonware.ipv4' = '78.157.42.107' }; NameKey = 'identity.name' }),
                (New-CatalogMode 'offline' 'Offline' -Exe 'Launch Project BO4.exe' -Clients @('shield') -UseName $false -NoDefaultArguments $true -Config @{ File = 'project-bo4.json'; Values = @{ 'demonware.ipv4' = '127.0.0.1' }; NameKey = 'identity.name' }))
            Repair = @('BlackOps4.start')
            Available = $true; UnavailableReason = '' }
        # HorizonMW's official launcher (api.horizonmw.org) goes into its own folder, as
        # its guide says; it downloads the mod into the Modern Warfare Remastered folder.
        [pscustomobject]@{ Id = 'hmw'; Name = 'HorizonMW'; Year = '2024'; SteamAppIds = @(393080); Detect = 'steam'
            ValidFiles = @('h1_mp64_ship.exe'); NameArgument = '+set name'; DefaultArguments = ''
            NeedsElevation = $false; DpiFix = @(); CdKey = ''; PlutoniumKey = ''; ExeCheck = $null; ProjectUrl = 'https://horizonmw.org/docs/installation'
            Clients = @((New-CatalogClient -Id 'hmw-launcher' -Name 'HMW Launcher' -Source 'hmw' -AppData 'HorizonMW\Launcher' -ReleaseTag '2.0.0' -Watch @('*') -ConfirmCleanup $true -Assets @(
                    (Get-ArchiveAssetList -Url 'https://s3.horizonmw.org/hmw/downloads/2.0.0_1788099721128_HMW_Launcher.zip' -Size 26444831 -Sha256 'ac366929246e0d8a97ea62e094c3661aa673f3835f1e8a2a01ce00904bcf9b94' -Entries @(
                        @('HMW Launcher.exe', 45439936, 'acc4ebe3e829741fd7f91e08db33687fddf311bb5bd6513dd6f95e1aa59ac289'),
                        @('HMW Updater.exe', 3575744, 'a7a2e6d41e025a51564f1e5d9bb94c7378302fed568854b94eff801f3a2fe10b'),
                        @('av_libglesv2.dll', 4440576, 'caff1be1faee32f7c5bfba9162ee617c347aad40772caa9a1aff794e3a191420'),
                        @('libHarfBuzzSharp.dll', 1607208, 'a54cfda99ffb965d4daa307c381763051ee638b629bfc0f424feb7a8046a7e36'),
                        @('libSkiaSharp.dll', 9414216, '9a0d95e8caaa852c70d085af6a40a744242172ad9ea3fd6bc7599875a8a1dbcd'),
                        @('version.txt', 8, '6d2c7d9bfcc2a2f40f75dbe57096bc8dd8c65511ed9dbe58abd08996f4618ff0'))))))
            Note = 'Runs on Modern Warfare Remastered (Multiplayer installed). After installing, the HMW Launcher opens: set its install directory to your MWR folder (copied to the clipboard), then Verify game files. Needs the Visual C++ runtimes.'
            Modes = @(
                (New-CatalogMode 'play' 'Play' -Exe 'hmw-mod.exe' -Clients @('hmw-launcher')),
                (New-CatalogMode 'launcher' 'HMW Launcher' -Kind 'client' -Exe 'HMW Launcher.exe' -Clients @('hmw-launcher') -UseName $false))
            Available = $true; UnavailableReason = '' }
    )
}

# What the installer does with one manifest entry of a client:
#   'derive' - a denied name with a Derive rule: made from the player's own file;
#   'deny'   - a copy of one of the game's own files: never downloaded;
#   'allow'  - matches one of the client's audited path patterns: downloaded;
#   'skip'   - anything else (for example a file added to the manifest after the
#              audit): not downloaded until the catalogue is updated.
function Get-ClientEntryVerdict {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$Path)
    $normal = ($Path -replace '\\', '/')
    $leaf = ($normal -split '/')[-1]
    foreach ($denied in $Client.Deny) {
        if ($leaf -ieq $denied -or $normal -ieq $denied) {
            foreach ($key in $Client.Derive.Keys) { if ($leaf -ieq $key) { return 'derive' } }
            return 'deny'
        }
    }
    foreach ($pattern in $Client.Allow) { if ($normal -like $pattern) { return 'allow' } }
    return 'skip'
}

function Get-CatalogGame {
    param([Parameter(Mandatory)][string]$Id)
    $game = Get-GameCatalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -eq $game) { throw "Unknown game: $Id" }
    return $game
}

# Where a client keeps the files that do not go into the game folder. In sandbox mode
# everything stays inside the sandbox.
function Get-ClientAppDataRoot {
    if (Test-SandboxMode) {
        $root = Join-Path $global:SandboxRoot 'AppData'
        if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
        return $root
    }
    return $env:LOCALAPPDATA
}

# A folder is the game when at least one of its marker files is there (as CB checks).
function Test-CatalogGameFolder {
    param([Parameter(Mandatory)]$Game, [string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return $false }
    # Only the game's own executable can identify its folder: a library several games ship
    # (binkw32.dll is in CoD4's, WaW's, BO1's, MW2's and MW3's lists) would otherwise make
    # one game's folder count as another's. DLLs are used only when the game has no exe.
    $markers = @($Game.ValidFiles | Where-Object { $_ -like '*.exe' })
    if ($markers.Count -eq 0) { $markers = @($Game.ValidFiles) }
    foreach ($file in $markers) { if (Test-Path -LiteralPath (Join-Path $Folder $file) -PathType Leaf) { return $true } }
    return $false
}

# The repair files a game declares, without the $null that a missing property gives: it
# counts as one item in @(), which used to put a Repair button on every card.
function Get-CatalogRepairFiles {
    param([Parameter(Mandatory)]$Game)
    return @($Game.Repair | Where-Object { $_ })
}

function Get-CatalogGameFolder {
    param([Parameter(Mandatory)][string]$Id)
    $games = (Get-AppSettings).Games
    if ($null -eq $games) { return $null }
    $property = $games.PSObject.Properties[$Id]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
    $folder = [string]$property.Value
    if (Test-Path -LiteralPath $folder -PathType Container) { return $folder }
    return $null
}

function Save-CatalogGameFolder {
    param([Parameter(Mandatory)][string]$Id, [string]$Folder = '')
    $settings = Get-AppSettings
    $games = [ordered]@{}
    if ($null -ne $settings.Games) { foreach ($property in $settings.Games.PSObject.Properties) { $games[$property.Name] = [string]$property.Value } }
    if ([string]::IsNullOrWhiteSpace($Folder)) { $games.Remove($Id) }
    else { $games[$Id] = [IO.Path]::GetFullPath($Folder).TrimEnd('\') }
    $settings.Games = [pscustomobject]$games
    return (Save-AppSettings -Settings $settings)
}

# Battle.net games have no Steam manifest; their uninstall entry names the folder.
function Find-BattleNetInstall {
    param([string[]]$DisplayNames)
    $keys = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($key in $keys) {
        foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            $name = [string]$entry.DisplayName
            foreach ($wanted in $DisplayNames) {
                if ($name -like $wanted -and $entry.InstallLocation -and (Test-Path -LiteralPath ([string]$entry.InstallLocation) -PathType Container)) { return ([string]$entry.InstallLocation).TrimEnd('\') }
            }
        }
    }
    return $null
}

# Finds a catalogue game: the saved folder first, then the Steam libraries (the app's
# manifest names its install folder), then Battle.net. Every hit is checked against
# the game's marker files.
function Find-CatalogGame {
    param([Parameter(Mandatory)]$Game)
            $saved = Get-CatalogGameFolder -Id $Game.Id
        if ($saved -and ((Test-CatalogGameFolder -Game $Game -Folder $saved) -or $Game.AllowEmptyFolder)) { return [pscustomobject]@{ Folder = $saved; Source = 'saved' } }
    # A game that is not looked for anywhere (United Offensive is installed where the
    # player says): only the folder picked with Change folder counts.
    $libraries = if ($Game.Detect -eq 'none') { @() } else { @(Get-SteamLibraries) }
    foreach ($library in $libraries) {
        foreach ($appId in $Game.SteamAppIds) {
            $manifest = Join-Path $library "steamapps\appmanifest_$appId.acf"
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
            $match = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"installdir"\s*"([^"]+)"')
            if (-not $match.Success) { continue }
            $installDir = $match.Groups[1].Value
            if ([IO.Path]::IsPathRooted($installDir) -or $installDir.Contains('..') -or $installDir.Contains(':')) { continue }
            $candidate = Join-Path $library "steamapps\common\$installDir"
            if (Test-CatalogGameFolder -Game $Game -Folder $candidate) { return [pscustomobject]@{ Folder = [IO.Path]::GetFullPath($candidate).TrimEnd('\'); Source = 'steam' } }
        }
    }
    # A game's own appmanifest can be missing after a move or a manual copy. Look
    # through each library's common folder for the game's marker files before giving up.
    foreach ($library in $libraries) {
        $common = Join-Path $library 'steamapps\common'
        if (-not (Test-Path -LiteralPath $common -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $common -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-CatalogGameFolder -Game $Game -Folder $directory.FullName) {
                return [pscustomobject]@{ Folder = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\'); Source = 'steam' }
            }
        }
    }
    if ($Game.Detect -eq 'battlenet' -and -not (Test-SandboxMode)) {
        $folder = Find-BattleNetInstall -DisplayNames @('Call of Duty*Black Ops 4*', 'Call of Duty: Black Ops 4*')
        if ($folder -and (Test-CatalogGameFolder -Game $Game -Folder $folder)) { return [pscustomobject]@{ Folder = $folder; Source = 'battlenet' } }
    }
    return $null
}

# ==========================================
# GAMES: CLIENT INSTALL, UPDATE AND REMOVAL
# ==========================================
# Every client install leaves a record in the game folder (.codhq-client-<id>.json)
# listing each file it placed (with SHA-1 and SHA-256), every original game file it
# had to replace (backed up under .codhq-backups\<id>), and every folder it created,
# so Remove client puts the game back exactly. Files are downloaded and checked into a
# staging folder first; only then is anything in the game written, and a failure while
# writing undoes what was written.

function Get-ClientRecordPath { param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)][string]$ClientId) Join-Path $GameFolder ('.codhq-client-' + $ClientId + '.json') }
function Get-ClientBackupRoot { param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)][string]$ClientId) Join-Path $GameFolder ('.codhq-backups\' + $ClientId) }

function Read-ClientRecord {
    param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)][string]$ClientId)
    $path = Get-ClientRecordPath -GameFolder $GameFolder -ClientId $ClientId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { throw "The install record of $ClientId could not be read: $path ($($_.Exception.Message))." }
}

function Write-ClientRecord {
    param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)]$Record)
    $path = Get-ClientRecordPath -GameFolder $GameFolder -ClientId $ClientId
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, ($Record | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
}

# Every file the other installed clients of this game placed (full path -> owner).
function Get-ClientFileOwnerMap {
    param([Parameter(Mandatory)][string]$GameFolder, [string]$ExceptClientId = '')
    $owners = @{}
    foreach ($recordFile in @(Get-ChildItem -LiteralPath $GameFolder -Filter '.codhq-client-*.json' -File -Force -ErrorAction SilentlyContinue)) {
        $record = $null
        try { $record = Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ([string]$record.ClientId -eq $ExceptClientId) { continue }
        foreach ($file in @($record.Files)) { $owners[([string]$file.Target).ToLowerInvariant()] = [pscustomobject]@{ ClientId = [string]$record.ClientId; Sha1 = [string]$file.Sha1 } }
        foreach ($backup in @($record.Backups)) { $owners['backup:' + ([string]$backup.Target).ToLowerInvariant()] = [pscustomobject]@{ ClientId = [string]$record.ClientId; Backup = [string]$backup.Backup } }
    }
    return $owners
}

# Where one entry of a client goes: its own destination field, else the game folder for
# clients without an AppData folder or for their listed game files, else AppData.
function Resolve-ClientTarget {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$Path, [string]$Dest = '', [Parameter(Mandatory)][string]$GameFolder)
    if (-not $Dest) {
        if ([string]::IsNullOrEmpty($Client.AppData)) { $Dest = 'game' }
        elseif (@($Client.GameFiles | Where-Object { $_ -ieq $Path }).Count -gt 0) { $Dest = 'game' }
        else { $Dest = 'appdata' }
    }
    $root = if ($Dest -eq 'game') { $GameFolder } else { Join-Path (Get-ClientAppDataRoot) $Client.AppData }
    $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $relative = Get-ValidatedRelativePath $Path
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "A client file would land outside its folder: $Path" }
    return [pscustomobject]@{ Dest = $Dest; Root = $root; Target = $full; Relative = $relative }
}

function Get-FileSha1Hex { param([Parameter(Mandatory)][string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToUpperInvariant() }

# The DLLs a Windows executable imports, read from its PE import table.
function Get-ExecutableImportNames {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return @() }
    $pe = [int][BitConverter]::ToUInt32($bytes, 0x3C)
    if ($pe -lt 0 -or $pe + 24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { return @() }
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optional = $pe + 24
    $directories = if ([BitConverter]::ToUInt16($bytes, $optional) -eq 0x20B) { $optional + 112 } else { $optional + 96 }
    $importRva = [int64][BitConverter]::ToUInt32($bytes, $directories + 8)
    if ($importRva -eq 0) { return @() }
    $sectionTable = $optional + $optionalSize
    $toOffset = {
        param([int64]$Rva)
        for ($s = 0; $s -lt $sectionCount; $s++) {
            $h = $sectionTable + 40 * $s
            $va = [int64][BitConverter]::ToUInt32($bytes, $h + 12)
            $span = [Math]::Max([int64][BitConverter]::ToUInt32($bytes, $h + 8), [int64][BitConverter]::ToUInt32($bytes, $h + 16))
            if ($Rva -ge $va -and $Rva -lt $va + $span) { return [int]($Rva - $va + [int64][BitConverter]::ToUInt32($bytes, $h + 20)) }
        }
        return -1
    }
    $descriptor = & $toOffset $importRva
    $names = [System.Collections.Generic.List[string]]::new()
    while ($descriptor -ge 0 -and $descriptor + 20 -le $bytes.Length) {
        $nameRva = [int64][BitConverter]::ToUInt32($bytes, $descriptor + 12)
        if ($nameRva -eq 0) { break }
        $nameOffset = & $toOffset $nameRva
        if ($nameOffset -lt 0) { break }
        $end = $nameOffset
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        $names.Add([Text.Encoding]::ASCII.GetString($bytes, $nameOffset, $end - $nameOffset))
        $descriptor += 20
    }
    return $names.ToArray()
}

# DLLs an executable imports that are neither next to it nor in Windows. A game that is
# missing one of them shows a Windows error box instead of starting.
function Get-MissingExecutableDependency {
    param([Parameter(Mandatory)][string]$Executable)
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return @() }
    $key = $Executable.ToLowerInvariant() + '|' + (Get-Item -LiteralPath $Executable).LastWriteTimeUtc.Ticks
    if ($null -eq $global:MissingDependencyCache) { $global:MissingDependencyCache = @{} }
    if ($global:MissingDependencyCache.ContainsKey($key)) { return $global:MissingDependencyCache[$key] }
    $missing = [System.Collections.Generic.List[string]]::new()
    $folder = Split-Path -Parent $Executable
    $systemDirs = @((Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'SysWOW64'), $env:WINDIR)
    foreach ($name in @(Get-ExecutableImportNames -Path $Executable)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $found = Test-Path -LiteralPath (Join-Path $folder $name) -PathType Leaf
        if (-not $found) {
            foreach ($dir in $systemDirs) { if ($dir -and (Test-Path -LiteralPath (Join-Path $dir $name) -PathType Leaf)) { $found = $true; break } }
        }
        if (-not $found -and -not ($missing -contains $name)) { $missing.Add($name) }
    }
    $result = $missing.ToArray()
    $global:MissingDependencyCache[$key] = $result
    return $result
}

# The newest GitHub release of a repository, with each asset's size and SHA-256 digest
# as GitHub publishes it.
function Get-GitHubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    $headers = @{ 'User-Agent' = 'CallOfDutyHQ-SetupUtility/1.1'; 'Accept' = 'application/vnd.github+json' }
    $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 30
    $releases = @($response)
    $release = $releases | Select-Object -First 1
    if ($null -eq $release) { throw "$Repo has no matching release." }
    $assets = foreach ($asset in @($release.assets)) {
        $digest = [string]$asset.digest
        [pscustomobject]@{ Name = [string]$asset.name; Size = [int64]$asset.size; Url = [string]$asset.browser_download_url
            Sha256 = $(if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLowerInvariant() } else { '' }) }
    }
    return [pscustomobject]@{ Tag = [string]$release.tag_name; Assets = @($assets) }
}

# The files a non-CB client installs. Pinned assets come from the catalogue; with
# -Latest, a client that names its GitHub release takes the newest one instead, each
# file still checked against the digest GitHub publishes for it (files taken out of a
# release archive are covered by the archive's digest).
function Get-ClientAssetList {
    param([Parameter(Mandatory)]$Client, [switch]$Latest)
    $assets = @($Client.Assets)
    if ($Latest -and $Client.Source -eq 'hmw') {
        # HorizonMW publishes its launcher through its own API; a new version is checked
        # against the size (and checksum, when it gives one) the API reports.
        $release = Get-HmwLatestRelease
        if ($release.Version -eq $Client.ReleaseTag) { return [pscustomobject]@{ Tag = $release.Version; Assets = $assets } }
        $archive = [pscustomobject]@{ Url = $release.Url; Size = $release.Size; Sha256 = $release.Sha256 }
        $updated = foreach ($asset in $assets) { $copy = $asset.PSObject.Copy(); $copy.Archive = $archive; $copy.Size = 0; $copy.Sha256 = ''; $copy }
        if (-not $release.Sha256) { Write-Warn "HorizonMW $($release.Version) has no published checksum; its size is checked instead." }
        return [pscustomobject]@{ Tag = $release.Version; Assets = @($updated) }
    }
    if (-not $Latest -or -not $Client.ReleaseRepo) { return [pscustomobject]@{ Tag = [string]$Client.ReleaseTag; Assets = $assets } }
    $release = Get-GitHubRelease -Repo $Client.ReleaseRepo
    if ($release.Tag -eq $Client.ReleaseTag) { return [pscustomobject]@{ Tag = $release.Tag; Assets = $assets } }
    $updated = foreach ($asset in $assets) {
        $copy = $asset.PSObject.Copy()
        if ($asset.Archive) {
            $archiveName = ([string]$asset.Archive.Url -split '/')[-1]
            $match = $release.Assets | Where-Object { $_.Name -ieq $archiveName } | Select-Object -First 1
            if ($null -eq $match -or -not $match.Sha256) { throw "$($Client.Name) $($release.Tag) has no checked $archiveName." }
            $copy.Archive = [pscustomobject]@{ Url = $match.Url; Size = $match.Size; Sha256 = $match.Sha256 }
            $copy.Size = 0; $copy.Sha256 = ''
        } elseif ($asset.Url) {
            $assetName = ([string]$asset.Url -split '/')[-1]
            $match = $release.Assets | Where-Object { $_.Name -ieq $assetName } | Select-Object -First 1
            if ($null -eq $match -or -not $match.Sha256) { throw "$($Client.Name) $($release.Tag) has no checked $assetName." }
            $copy.Url = $match.Url; $copy.Size = $match.Size; $copy.Sha256 = $match.Sha256
        }
        $copy
    }
    return [pscustomobject]@{ Tag = $release.Tag; Assets = @($updated) }
}

# Takes one file out of a downloaded release archive into staging. The archive is
# downloaded once per install (resumable, SHA-256 checked) and kept in the staging
# folder for the other files in it.
function Save-ArchiveEntry {
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)][string]$StagePath, [Parameter(Mandatory)][string]$ArchiveCache, [string]$Label = '', [int]$RetryDelaySeconds = 3)
    $archive = $Step.Asset.Archive
    if (-not (Test-Path -LiteralPath $ArchiveCache)) { $null = New-Item -ItemType Directory -Path $ArchiveCache -Force }
    $key = if ($archive.Sha256) { [string]$archive.Sha256 } else { [string]([Math]::Abs(([string]$archive.Url).GetHashCode())) }
    $zipPath = Join-Path $ArchiveCache ($key + '.zip')
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        $partial = $zipPath + '.download'
        $null = Invoke-ResumableDownload -Url ([string]$archive.Url) -Destination $partial -Label $(if ($Label) { $Label } else { 'Downloading ' + (([string]$archive.Url -split '/')[-1]) }) -ExpectedSha256 ([string]$archive.Sha256) -RetryDelaySeconds $RetryDelaySeconds
        Move-Item -LiteralPath $partial -Destination $zipPath -Force
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $entryName = ([string]$Step.Asset.Entry) -replace '\\', '/'
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -ieq $entryName } | Select-Object -First 1
        if ($null -eq $entry) { throw "$entryName is not in $(([string]$archive.Url -split '/')[-1])." }
        $parent = Split-Path -Parent $StagePath
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $StagePath, $true)
    } finally { $zip.Dispose() }
    $bytes = (Get-Item -LiteralPath $StagePath).Length
    $sha256 = Get-FileSha256 -Path $StagePath
    if ($Step.Size -gt 0 -and $bytes -ne [int64]$Step.Size) { throw "$entryName from the archive is $bytes bytes, expected $($Step.Size)." }
    if ($Step.Sha256 -and $sha256 -ne ([string]$Step.Sha256).ToLowerInvariant()) { throw "$entryName from the archive does not match its pinned SHA-256." }
    return [pscustomobject]@{ Bytes = $bytes; Sha256 = $sha256; Sha1 = (Get-FileSha1Hex $StagePath) }
}

# Works out what installing a client would do, without changing anything: which files
# to download, which are already current, which of the game's own files are kept, which
# names are made from the player's own files, and which manifest entries are skipped.
function Get-ClientInstallPlan {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GameFolder, $Manifest = $null,
          # Take the client's newest GitHub release instead of the pinned one.
          [switch]$Latest)
    $steps = [System.Collections.Generic.List[object]]::new()
    $manifestHash = ''; $base = ''; $releaseTag = [string]$Client.ReleaseTag
    if ($Client.Source -eq 'cb') {
        if ($null -eq $Manifest) { $Manifest = Get-ClientManifest -Manifest $Client.Manifest }
        $manifestHash = $Manifest.ManifestHash; $base = $Manifest.Base
        $entries = @($Manifest.Entries | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = $_.Size; Sha1 = $_.Sha1; Sha256 = ''; Dest = $_.Dest; Url = ''; Asset = $null } })
    } else {
        $assetList = Get-ClientAssetList -Client $Client -Latest:$Latest
        $releaseTag = $assetList.Tag
        $entries = @($assetList.Assets | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = [int64]$_.Size; Sha1 = ''; Sha256 = [string]$_.Sha256; Dest = [string]$_.Dest; Url = [string]$_.Url; Asset = $_ } })
    }
    $previous = Read-ClientRecord -GameFolder $GameFolder -ClientId $Client.Id
    foreach ($entry in $entries) {
        $verdict = if ($Client.Source -eq 'cb') { Get-ClientEntryVerdict -Client $Client -Path $entry.Path } else { 'allow' }
        $target = Resolve-ClientTarget -Client $Client -Path $entry.Path -Dest $entry.Dest -GameFolder $GameFolder
        $step = [pscustomobject]@{ Path = $entry.Path; Verdict = $verdict; Action = ''; Dest = $target.Dest; Root = $target.Root; Target = $target.Target; Relative = $target.Relative
            Size = $entry.Size; Sha1 = $entry.Sha1; Sha256 = $entry.Sha256; Url = $entry.Url; DeriveFrom = ''; Kind = 'file'; Asset = $entry.Asset }
        $asset = $entry.Asset
        if ($asset -and $asset.Archive) { $step.Kind = 'archive' }
        switch ($verdict) {
            'skip' { $step.Action = 'skip' }
            'deny' { $step.Action = 'keep' }
            'derive' {
                $leaf = ($entry.Path -split '/')[-1]
                $from = ''; foreach ($key in $Client.Derive.Keys) { if ($leaf -ieq $key) { $from = $Client.Derive[$key] } }
                if ((Test-Path -LiteralPath $target.Target -PathType Leaf) -and (Get-FileSha1Hex $target.Target) -eq $entry.Sha1) { $step.Action = 'current'; break }
                # The player's own original: this client's earlier backup of it, another
                # client's backup of it, or the file in the game folder.
                $candidates = [System.Collections.Generic.List[string]]::new()
                $sourceTarget = (Resolve-ClientTarget -Client $Client -Path $from -Dest 'game' -GameFolder $GameFolder).Target
                if ($previous) { foreach ($b in @($previous.Backups)) { if ([string]$b.Target -ieq $sourceTarget) { $candidates.Add([string]$b.Backup) } } }
                foreach ($recordFile in @(Get-ChildItem -LiteralPath $GameFolder -Filter '.codhq-client-*.json' -File -Force -ErrorAction SilentlyContinue)) {
                    try { foreach ($b in @((Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json).Backups)) { if ([string]$b.Target -ieq $sourceTarget) { $candidates.Add([string]$b.Backup) } } } catch { Write-Verbose "Unreadable record: $($recordFile.Name)" }
                }
                $candidates.Add($sourceTarget)
                foreach ($candidate in $candidates) {
                    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Get-Item -LiteralPath $candidate).Length -eq $entry.Size -and (Get-FileSha1Hex $candidate) -eq $entry.Sha1) { $step.DeriveFrom = $candidate; break }
                }
                $step.Action = if ($step.DeriveFrom) { 'derive' } else { 'derive-missing' }
                if (-not $step.DeriveFrom) { $step.DeriveFrom = $sourceTarget }
            }
            default {
                $current = $false
                if ((Test-Path -LiteralPath $target.Target -PathType Leaf) -and (Get-Item -LiteralPath $target.Target).Length -eq $entry.Size) {
                    $current = if ($entry.Sha1) { (Get-FileSha1Hex $target.Target) -eq $entry.Sha1 } else { (Get-FileSha256 -Path $target.Target) -eq $entry.Sha256 }
                }
                $step.Action = if ($current) { 'current' } else { 'download' }
                if ($Client.Source -eq 'cb') { $step.Url = $base + $Client.Folder + ((($entry.Path -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/') + '?' + $entry.Sha1 }
            }
        }
        $steps.Add($step)
    }
    return [pscustomobject]@{ Client = $Client; GameFolder = $GameFolder; ManifestHash = $manifestHash; Base = $base; Steps = $steps.ToArray(); Previous = $previous; ReleaseTag = $releaseTag }
}

# Downloads one planned file into staging, trying the plan's source first and the
# other CB sources after it.
function Save-ClientFile {
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$StagePath, [int]$RetryDelaySeconds = 3, [string]$ArchiveCache = '')
    $parent = Split-Path -Parent $StagePath
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $label = "Downloading $($Plan.Client.Name): $($Step.Path)"
    if ($Step.Kind -eq 'archive') {
        if (-not $ArchiveCache) { $ArchiveCache = Join-Path (Split-Path -Parent $StagePath) '_archives' }
        $result = Save-ArchiveEntry -Step $Step -StagePath $StagePath -ArchiveCache $ArchiveCache -Label "Downloading $($Plan.Client.Name)" -RetryDelaySeconds $RetryDelaySeconds
        Write-Progress -Activity "Downloading $($Plan.Client.Name)" -Completed
        return $result
    }
    if ($Plan.Client.Source -ne 'cb') {
        $result = Invoke-ResumableDownload -Url $Step.Url -Destination $StagePath -Label $label -ExpectedSha256 $Step.Sha256 -RetryDelaySeconds $RetryDelaySeconds -PassThru
        Write-Progress -Activity $label -Completed
        return $result
    }
    $relativeUrl = $Plan.Client.Folder + ((($Step.Path -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/') + '?' + $Step.Sha1
    $bases = @($Plan.Base) + @(Get-ClientUpdateSource | Where-Object { $_ -ne $Plan.Base })
    $lastError = $null
    foreach ($base in $bases) {
        try {
            $result = Invoke-ResumableDownload -Url ($base + $relativeUrl) -Destination $StagePath -Label $label -ExpectedSha256 '' -ExpectedSha1 $Step.Sha1 -RetryDelaySeconds $RetryDelaySeconds -PassThru
            Write-Progress -Activity $label -Completed
            return $result
        } catch {
            $lastError = $_
            if (Test-Path -LiteralPath $StagePath) { Remove-Item -LiteralPath $StagePath -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Progress -Activity $label -Completed
    throw "Could not download $($Step.Path) for $($Plan.Client.Name): $($lastError.Exception.Message)"
}

# Creates a folder and returns the folders it had to create (outermost first).
function New-TrackedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $missing = [System.Collections.Generic.List[string]]::new()
    $walk = $Path
    while ($walk -and -not (Test-Path -LiteralPath $walk)) { $missing.Insert(0, $walk); $walk = Split-Path -Parent $walk }
    if ($missing.Count -gt 0) { $null = New-Item -ItemType Directory -Path $Path -Force }
    return $missing.ToArray()
}

# Files under a client's Protect / Watch patterns (relative to the game folder):
# 'name' is one file, 'dir\*' every file below dir, '*' every file of the game. The
# installer's own records and backups, and the players2 settings folder, never count.
function Get-WatchedGameFiles {
    param([Parameter(Mandatory)][string]$GameFolder, [string[]]$Patterns = @())
    $found = [System.Collections.Generic.List[string]]::new()
    $root = [IO.Path]::GetFullPath($GameFolder).TrimEnd('\')
    foreach ($pattern in @($Patterns)) {
        $pattern = ([string]$pattern).Replace('/', '\')
        if ($pattern -eq '*' -or $pattern.EndsWith('\*')) {
            $dir = if ($pattern -eq '*') { $root } else { Join-Path $root $pattern.Substring(0, $pattern.Length - 2) }
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $found.Add($file.FullName.Substring($root.Length + 1)) }
        } elseif (Test-Path -LiteralPath (Join-Path $root $pattern) -PathType Leaf) { $found.Add($pattern) }
    }
    return @($found | Where-Object { $_ -notlike '.codhq-*' -and $_ -notlike 'players2\*' } | Sort-Object -Unique)
}

# Installing an archive client (the Call of Duty 1.1 files this project publishes in its
# own release): the ZIP goes into the game folder as it is, every file it writes is
# journaled, a game file it replaces is moved into the client's backup folder first, and
# the record lists every file, so Remove puts the folder back exactly. The archive is
# pinned by SHA-256; its contents are deliberately not listed anywhere.
# Clients installed on top of another one (1.1X sits on top of 1.1), newest first: they
# have to go when the one below them is removed or installed again.
function Get-InstalledDependentClients {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$GameFolder)
    return @($Game.Clients | Where-Object { $_.Id -ne $ClientId -and @($_.Requires) -contains $ClientId -and (Test-GameClientInstalled -GameFolder $GameFolder -ClientId $_.Id) })
}

# Moves everything in a game folder into a backup folder except a few files (the two Call
# of Duty (2003) executables), so an archive is extracted into a folder that holds nothing
# but its own files. Everything it moves is in the backup, so Remove puts the folder back
# the way it was before the install.
function Move-GameFolderAside {
    param(
        [Parameter(Mandatory)][string]$GameFolder,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [string[]]$Keep = @(),
        # Files this client wrote itself: the archive writes them again, so they are not
        # worth a backup.
        [hashtable]$SkipTargets = @{},
        [System.Collections.Generic.List[object]]$Journal = $null
    )
    $kept = @{}
    foreach ($name in @($Keep)) { $kept[$name.ToLowerInvariant()] = $true }
    $root = [IO.Path]::GetFullPath($GameFolder).TrimEnd('\')
    $prefix = $root + '\'
    $moved = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $full = $file.FullName
        $relative = $full.Substring($prefix.Length)
        $top = ($relative -split '\\')[0]
        if ($kept.ContainsKey($top.ToLowerInvariant())) { continue }
        # The installer's own backups and install records stay where they are.
        if ($top -ieq '.codhq-backups' -or $file.Name -like '.codhq-client-*.json') { continue }
        if ($SkipTargets.ContainsKey($full.ToLowerInvariant())) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue; continue }
        $backupPath = Join-Path $BackupDirectory ('wiped\' + $relative)
        $parent = Split-Path $backupPath -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        Move-Item -LiteralPath $full -Destination $backupPath -Force -ErrorAction Stop
        if ($null -ne $Journal) { $Journal.Add([pscustomobject]@{ Kind = 'Wiped'; Path = $full; Backup = $backupPath }) }
        $moved++
    }
    # Folders left empty go too, deepest first; restoring a file makes its folder again.
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        $relative = $dir.FullName.Substring($prefix.Length)
        $top = ($relative -split '\\')[0]
        if ($kept.ContainsKey($top.ToLowerInvariant()) -or $top -ieq '.codhq-backups') { continue }
        if (-not (Get-ChildItem -LiteralPath $dir.FullName -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $moved
}

function Install-GameClientArchive {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GameFolder, [int]$RetryDelaySeconds = 3)
    $archive = $Client.Archive
    if ($null -eq $archive -or [string]::IsNullOrWhiteSpace([string]$archive.Url) -or [string]::IsNullOrWhiteSpace([string]$archive.Sha256)) { throw "$($Client.Name) has no archive to install." }
    $previous = Read-ClientRecord -GameFolder $GameFolder -ClientId $Client.Id
    $owners = Get-ClientFileOwnerMap -GameFolder $GameFolder -ExceptClientId $Client.Id
    # The same archive, and every file it wrote is still there: nothing to do.
    if ($previous -and [string]$previous.ArchiveSha256 -eq [string]$archive.Sha256) {
        $missing = @($previous.Files | Where-Object { -not (Test-Path -LiteralPath ([string]$_.Target) -PathType Leaf) })
        if ($missing.Count -eq 0) {
            Write-Ok "$($Client.Name) is already installed and up to date."
            return [pscustomobject]@{ GameFolder = $GameFolder; Downloaded = 0; Current = @($previous.Files).Count; Derived = 0; Kept = 0; Skipped = 0 }
        }
    }
    # A clean install empties the folder, so a client that sits on top of this one goes
    # first (1.1X before 1.1); it is installed again afterwards.
    if ($Client.CleanInstall) {
        foreach ($dependent in @(Get-InstalledDependentClients -Game $Game -ClientId $Client.Id -GameFolder $GameFolder)) {
            Write-Info "Removing $($dependent.Name) first: $($Client.Name) is installed as a clean copy."
            Remove-GameClient -GameId $Game.Id -ClientId $dependent.Id -GameFolder $GameFolder
        }
    }
    $stage = Join-Path $env:TEMP ('codhq-archive-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage -Force
    $zipPath = Join-Path $stage (([string]$archive.Url -split '/')[-1])
    $backupRoot = Get-ClientBackupRoot -GameFolder $GameFolder -ClientId $Client.Id
    # One folder per run, so a backup this client already holds is never written over.
    $runBackup = Join-Path $backupRoot ('run-' + [guid]::NewGuid().ToString('N'))
    $journal = [System.Collections.Generic.List[object]]::new()
    try {
        Write-Info "Downloading $($Client.Name): $(([string]$archive.Url -split '/')[-1])"
        $null = Invoke-ResumableDownload -Url ([string]$archive.Url) -Destination $zipPath -Label "Downloading $($Client.Name)" -ExpectedSha256 ([string]$archive.Sha256) -RetryDelaySeconds $RetryDelaySeconds
        $root = Get-GameArchiveRoot -ZipPath $zipPath
        if ($root) { Write-Info "The archive keeps its files in '$root\'; they are copied in without it." }
        if ($Client.CleanInstall) {
            $previousTargets = @{}
            if ($previous) { foreach ($f in @($previous.Files)) { $previousTargets[([string]$f.Target).ToLowerInvariant()] = $true } }
            Write-Info "Moving everything in $GameFolder except $(@($Client.KeepFiles) -join ' and ') into the backup ..."
            $aside = Move-GameFolderAside -GameFolder $GameFolder -BackupDirectory $runBackup -Keep @($Client.KeepFiles) -SkipTargets $previousTargets -Journal $journal
            Write-Info "Files moved aside: $aside. They are all in the backup, and Remove puts them back as they were."
        }
        Write-Info "Copying $($Client.Name) into $GameFolder ..."
        Expand-ZipOverwrite -ZipPath $zipPath -DestinationPath $GameFolder -Journal $journal -BackupDirectory $runBackup -StripPrefix $root
    } catch {
        Write-Warn "Installing $($Client.Name) failed; putting back what was changed..."
        $undone = Undo-ZipExtraction -Journal $journal
        if ($undone -and (Test-Path -LiteralPath $runBackup -PathType Container) -and -not (Get-ChildItem -LiteralPath $runBackup -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $runBackup -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $backups = [System.Collections.Generic.List[object]]::new()
    if ($previous) { foreach ($b in @($previous.Backups)) { $backups.Add([pscustomobject]@{ Target = [string]$b.Target; Backup = [string]$b.Backup }) } }
    $previousFiles = @{}
    if ($previous) { foreach ($f in @($previous.Files)) { $previousFiles[([string]$f.Target).ToLowerInvariant()] = $true } }
    $files = [System.Collections.Generic.List[object]]::new()
    $createdDirs = [System.Collections.Generic.List[string]]::new()
    if ($previous) { foreach ($d in @($previous.CreatedDirs)) { $createdDirs.Add([string]$d) } }
    foreach ($change in $journal) {
        if ($change.Kind -eq 'Directory') { $createdDirs.Add([string]$change.Path); continue }
        if ($change.Kind -eq 'Wiped') { $backups.Add([pscustomobject]@{ Target = [string]$change.Path; Backup = [string]$change.Backup }); continue }
        $full = [string]$change.Path
        if ($change.Kind -eq 'Replaced') {
            # What Expand-ZipOverwrite moved aside is the file the previous install wrote;
            # the player's own original is already in this client's record. Keep that one.
            # A file this client wrote last time is not the player's: no backup is kept for it.
            $earlier = @($backups | Where-Object { $_.Target -ieq $full }) | Select-Object -First 1
            if ($earlier -or $previousFiles.ContainsKey($full.ToLowerInvariant())) { Remove-Item -LiteralPath ([string]$change.Backup) -Force -ErrorAction SilentlyContinue }
            else { $backups.Add([pscustomobject]@{ Target = $full; Backup = [string]$change.Backup }) }
        }
        $files.Add([pscustomobject]@{ Path = $full.Substring($GameFolder.Length + 1); Dest = 'game'; Target = $full
            Size = (Get-Item -LiteralPath $full).Length; Sha1 = (Get-FileSha1Hex $full); Sha256 = (Get-FileSha256 -Path $full); Derived = $false; Kind = 'archive' })
    }

    # The archive has to be the game's own file set: every marker file must have been
    # written by it. Anything else means the wrong ZIP or a different layout, so the
    # extraction is undone and nothing is installed.
    # A patch archive replaces only part of the file set (1.1X ships CoDMP.exe and
    # cod1x.dll), so a client says which files it must put in place; the game's own
    # marker files when it does not.
    $required = @($Client.RequiredFiles)
    if ($required.Count -eq 0) { $required = @($Game.ValidFiles) }
    $writtenPaths = @{}
    foreach ($file in $files) { $writtenPaths[([string]$file.Path).ToLowerInvariant()] = $true }
    $missing = @($required | Where-Object { -not $writtenPaths.ContainsKey($_.ToLowerInvariant()) })
    if ($missing.Count -gt 0) {
        $undone = Undo-ZipExtraction -Journal $journal
        if ($undone -and (Test-Path -LiteralPath $runBackup -PathType Container) -and -not (Get-ChildItem -LiteralPath $runBackup -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $runBackup -Force -ErrorAction SilentlyContinue }
        throw "The archive did not put $(($missing -join ' and ')) in $GameFolder, so it is not the $($Game.Name) file set. Nothing was installed: the folder is as it was. Check that the ZIP you published contains $($required -join ' and ') at its top level, or inside one folder."
    }

    # Files the previous install wrote that this archive no longer has: put the original
    # back if there is one, otherwise delete them (unless another client still uses them).
    if ($previous) {
        $written = @{}
        foreach ($file in $files) { $written[([string]$file.Target).ToLowerInvariant()] = $true }
        foreach ($old in @($previous.Files)) {
            $oldTarget = [string]$old.Target
            if ($written.ContainsKey($oldTarget.ToLowerInvariant()) -or $owners.ContainsKey($oldTarget.ToLowerInvariant())) { continue }
            $backup = @($backups | Where-Object { $_.Target -ieq $oldTarget }) | Select-Object -First 1
            if ($backup -and (Test-Path -LiteralPath ([string]$backup.Backup) -PathType Leaf)) {
                Copy-FileAtomically -Source ([string]$backup.Backup) -Destination $oldTarget
                Remove-Item -LiteralPath ([string]$backup.Backup) -Force -ErrorAction SilentlyContinue
                $null = $backups.Remove($backup)
            } elseif (Test-Path -LiteralPath $oldTarget -PathType Leaf) { Remove-Item -LiteralPath $oldTarget -Force -ErrorAction Stop }
            Write-Info "Removed a file $($Client.Name) no longer ships: $($old.Path)"
        }
    }

    Write-ClientRecord -GameFolder $GameFolder -ClientId $Client.Id -Record ([pscustomobject]@{
        Version = 1; GameId = $Game.Id; ClientId = $Client.Id; ClientName = $Client.Name; Source = 'archive'; Manifest = ''
        ManifestHash = ''; ReleaseTag = ''; ArchiveUrl = [string]$archive.Url; ArchiveSha256 = [string]$archive.Sha256
        InstalledAt = [DateTime]::UtcNow.ToString('o'); GameFolder = $GameFolder
        Files = @($files.ToArray()); Backups = @($backups.ToArray()); CreatedDirs = @($createdDirs | Select-Object -Unique); ExpectedGameFiles = @()
        Snapshot = @() })
    if ((Test-Path -LiteralPath $runBackup -PathType Container) -and -not (Get-ChildItem -LiteralPath $runBackup -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $runBackup -Force -ErrorAction SilentlyContinue }
    Write-Ok "$($Client.Name) is installed for $($Game.Name)."
    Write-Info ([string]::Format([cultureinfo]::InvariantCulture, 'Files copied from the archive: {0}. Your own game files kept: {1}.', $files.Count, $backups.Count))
    return [pscustomobject]@{ GameFolder = $GameFolder; Downloaded = $files.Count; Current = 0; Derived = 0; Kept = $backups.Count; Skipped = 0 }
}

function Install-GameClient {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$ClientId, [string]$GameFolder = '', $Manifest = $null, [int]$RetryDelaySeconds = 3,
          # Take the newest release of a GitHub client instead of the pinned one.
          [switch]$Latest)
    $game = Get-CatalogGame -Id $GameId
    $client = $game.Clients | Where-Object { $_.Id -eq $ClientId } | Select-Object -First 1
    if ($null -eq $client) { throw "$($game.Name) has no client '$ClientId'." }
    if (-not $GameFolder) { $found = Find-CatalogGame -Game $game; if ($found) { $GameFolder = $found.Folder } }
    if (-not $GameFolder) {
        if ($game.Detect -eq 'none') { throw "$($game.Name) is not detected: pick its folder with Change folder first." }
        throw "$($game.Name) was not found. Install it from Steam or pick its folder with Change folder."
    }
    $GameFolder = [IO.Path]::GetFullPath($GameFolder).TrimEnd('\')
    if (-not (Test-CatalogGameFolder -Game $game -Folder $GameFolder)) {
        # A game whose client ships the whole file set (Call of Duty 2003) can be put in a
        # folder the player picked or created; every other game must already be there.
        if (-not $game.AllowEmptyFolder) { throw "$($game.Name) was not found. Install it from Steam or pick its folder with Change folder." }
        if (-not (Test-Path -LiteralPath $GameFolder -PathType Container)) { $null = New-Item -ItemType Directory -Path $GameFolder -Force }
        # An empty (or new) folder is taken as it is. A folder that already holds files but
        # nothing of this game is only written into after the player says yes.
        $occupied = @(Get-ChildItem -LiteralPath $GameFolder -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0
        if ($occupied -and -not (Test-SandboxMode)) {
            Write-Warn "$GameFolder already has files in it, but none of them is $($game.Name) ($($game.ValidFiles -join ', '))."
            if ((Read-Host "Install $($client.Name) downloads the archive into that folder and may replace files with the same names. Continue? [y/N]") -notmatch '^(y|yes)$') { Stop-Cancelled 'Nothing was installed.' }
        }
        Write-Info "$GameFolder does not have $($game.Name) yet; $($client.Name) puts its files there."
    }
    # A client that goes on top of another one (1.1X on 1.1) needs that one in place first.
    foreach ($need in @($client.Requires)) {
        if (Test-GameClientInstalled -GameFolder $GameFolder -ClientId $need) { continue }
        $needName = Get-CatalogClientName $need $game
        throw "$($client.Name) goes on top of $needName. Install $needName first; nothing was changed."
    }
    foreach ($other in @($client.Conflicts)) {
        if (Test-GameClientInstalled -GameFolder $GameFolder -ClientId $other) {
            $otherName = ($game.Clients | Where-Object { $_.Id -eq $other } | Select-Object -First 1).Name
            if (-not $otherName) { $otherName = $other }
            throw "$($client.Name) and $otherName replace the same files and cannot be installed together. Remove $otherName first; nothing was changed."
        }
    }

    if ($client.Extract) {
        return (Install-GameClientArchive -Game $game -Client $client -GameFolder $GameFolder -RetryDelaySeconds $RetryDelaySeconds)
    }

    Write-Info "Checking what $($client.Name) needs in $GameFolder ..."
    $plan = Get-ClientInstallPlan -Client $client -GameFolder $GameFolder -Manifest $Manifest -Latest:$Latest
    $missing = @($plan.Steps | Where-Object { $_.Action -eq 'derive-missing' })
    if ($missing.Count -gt 0) {
        $names = ($missing | ForEach-Object { (Split-Path -Leaf $_.DeriveFrom) + ' (for ' + $_.Path + ')' }) -join ', '
        throw "$($client.Name) needs the game's original $names, but the file in your game folder is not the original build. Nothing was changed. Verify the game files in Steam, then try again."
    }
    $placing = @('download', 'current', 'derive')
    # Two clients that put different versions of the same file in place cannot be
    # installed together.
    $owners = Get-ClientFileOwnerMap -GameFolder $GameFolder -ExceptClientId $client.Id
    foreach ($step in @($plan.Steps | Where-Object { $_.Action -in $placing })) {
        $owner = $owners[$step.Target.ToLowerInvariant()]
        if ($owner -and $step.Sha1 -and $owner.Sha1 -and $owner.Sha1 -ne $step.Sha1) {
            throw "$($client.Name) and $($owner.ClientId) both replace $($step.Path) with different files. Remove $($owner.ClientId) first; nothing was changed."
        }
        if ($owner -and -not $step.Sha1 -and $step.Action -ne 'current') {
            throw "$($client.Name) would replace $($step.Path), which $($owner.ClientId) placed. Remove $($owner.ClientId) first; nothing was changed."
        }
    }

    $downloads = @($plan.Steps | Where-Object { $_.Action -eq 'download' })
    $stage = Join-Path $env:TEMP ('codhq-client-' + [guid]::NewGuid().ToString('N'))
    $journal = [System.Collections.Generic.List[object]]::new()
    $createdDirs = [System.Collections.Generic.List[string]]::new()
    $backups = [System.Collections.Generic.List[object]]::new()
    if ($plan.Previous) { foreach ($b in @($plan.Previous.Backups)) { $backups.Add([pscustomobject]@{ Target = [string]$b.Target; Backup = [string]$b.Backup }) } }
    if ($plan.Previous) { foreach ($d in @($plan.Previous.CreatedDirs)) { $createdDirs.Add([string]$d) } }
    $hashes = @{}
    $backupRoot = Get-ClientBackupRoot -GameFolder $GameFolder -ClientId $client.Id
    # What the folder held before the client's own launcher first ran (kept across updates).
    $snapshot = if ($plan.Previous -and $null -ne $plan.Previous.Snapshot) { @($plan.Previous.Snapshot) } elseif (@($client.Watch).Count -gt 0) { @(Get-WatchedGameFiles -GameFolder $GameFolder -Patterns $client.Watch) } else { @() }
    try {
        $index = 0
        foreach ($step in $downloads) {
            $index++
            Write-Info ([string]::Format([cultureinfo]::InvariantCulture, 'Downloading {0}/{1}: {2} ({3:N1} MB)', $index, $downloads.Count, $step.Path, ($step.Size / 1MB)))
            $result = Save-ClientFile -Step $step -Plan $plan -StagePath (Join-Path $stage ($step.Path -replace '/', '\')) -RetryDelaySeconds $RetryDelaySeconds -ArchiveCache (Join-Path $stage '_archives')
            $hashes[$step.Target] = $result
        }
        if ($downloads.Count -gt 0) { Write-Ok "All $($downloads.Count) file(s) downloaded and checked." }

        # Game files a launcher-type client's launcher replaces later: kept before it runs.
        foreach ($relative in @(Get-WatchedGameFiles -GameFolder $GameFolder -Patterns $client.Protect)) {
            $full = Join-Path $GameFolder $relative
            if (@($backups | Where-Object { $_.Target -ieq $full }).Count -gt 0 -or $owners.ContainsKey($full.ToLowerInvariant())) { continue }
            $backupPath = Join-Path $backupRoot ('protect\' + $relative)
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force
            Copy-Item -LiteralPath $full -Destination $backupPath -Force -ErrorAction Stop
            $backups.Add([pscustomobject]@{ Target = $full; Backup = $backupPath })
        }
        if (@($client.Protect).Count -gt 0) { Write-Ok "Your own $(@($client.Protect) -join ', ') are backed up." }

        $previousTargets = @{}
        if ($plan.Previous) { foreach ($f in @($plan.Previous.Files)) { $previousTargets[([string]$f.Target).ToLowerInvariant()] = $true } }
        $writeSteps = @($plan.Steps | Where-Object { $_.Action -eq 'derive' }) + $downloads
        try {
            foreach ($step in $writeSteps) {
                Test-SafeGameDestination -TargetRoot $step.Root -Destination $step.Target
                foreach ($dir in (New-TrackedDirectory -Path (Split-Path -Parent $step.Target))) { $createdDirs.Add($dir) }
                $backupPath = $null
                $key = $step.Target.ToLowerInvariant()
                # An existing file that no client placed is the player's own: keep a copy.
                if ((Test-Path -LiteralPath $step.Target -PathType Leaf) -and -not $previousTargets.ContainsKey($key) -and -not $owners.ContainsKey($key) -and -not @($backups | Where-Object { $_.Target -ieq $step.Target }).Count) {
                    $backupPath = Join-Path $backupRoot ($step.Dest + '\' + $step.Relative)
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force
                    Copy-Item -LiteralPath $step.Target -Destination $backupPath -Force -ErrorAction Stop
                    $backups.Add([pscustomobject]@{ Target = $step.Target; Backup = $backupPath })
                }
                $source = if ($step.Action -eq 'derive') { $step.DeriveFrom } else { Join-Path $stage ($step.Path -replace '/', '\') }
                $journal.Add([pscustomobject]@{ Target = $step.Target; Existed = (Test-Path -LiteralPath $step.Target -PathType Leaf); Backup = $backupPath })
                Copy-FileAtomically -Source $source -Destination $step.Target
            }
        } catch {
            Write-Warn "Installing $($client.Name) failed; putting back what was changed..."
            for ($i = $journal.Count - 1; $i -ge 0; $i--) {
                $change = $journal[$i]
                try {
                    if ($change.Backup -and (Test-Path -LiteralPath $change.Backup)) { Copy-FileAtomically -Source $change.Backup -Destination $change.Target; Remove-Item -LiteralPath $change.Backup -Force -ErrorAction SilentlyContinue }
                    elseif (-not $change.Existed -and (Test-Path -LiteralPath $change.Target)) { Remove-Item -LiteralPath $change.Target -Force -ErrorAction Stop }
                } catch { Write-Warn "Could not undo: $($change.Target)" }
            }
            throw
        }

        # Files the client no longer ships: put back the original if one was replaced,
        # otherwise delete them (unless another client still uses them).
        $keepTargets = @{}
        foreach ($step in @($plan.Steps | Where-Object { $_.Action -in $placing })) { $keepTargets[$step.Target.ToLowerInvariant()] = $true }
        if ($plan.Previous) {
            foreach ($old in @($plan.Previous.Files)) {
                $oldTarget = [string]$old.Target
                if ($keepTargets.ContainsKey($oldTarget.ToLowerInvariant()) -or $owners.ContainsKey($oldTarget.ToLowerInvariant())) { continue }
                $backup = $backups | Where-Object { $_.Target -ieq $oldTarget } | Select-Object -First 1
                if ($backup -and (Test-Path -LiteralPath $backup.Backup)) { Copy-FileAtomically -Source $backup.Backup -Destination $oldTarget; Remove-Item -LiteralPath $backup.Backup -Force; $null = $backups.Remove($backup) }
                elseif (Test-Path -LiteralPath $oldTarget -PathType Leaf) { Remove-Item -LiteralPath $oldTarget -Force -ErrorAction Stop }
                Write-Info "Removed a file $($client.Name) no longer ships: $($old.Path)"
            }
        }

        $files = foreach ($step in @($plan.Steps | Where-Object { $_.Action -in $placing })) {
            $sha256 = if ($hashes.ContainsKey($step.Target)) { $hashes[$step.Target].Sha256 } else { Get-FileSha256 -Path $step.Target }
            $sha1 = if ($step.Sha1) { $step.Sha1 } else { Get-FileSha1Hex $step.Target }
            $size = if ($step.Size -gt 0) { $step.Size } else { (Get-Item -LiteralPath $step.Target).Length }
            [pscustomobject]@{ Path = $step.Path; Dest = $step.Dest; Target = $step.Target; Size = $size; Sha1 = $sha1; Sha256 = $sha256; Derived = ($step.Action -eq 'derive'); Kind = $step.Kind }
        }
        # The game's own files the client was built against (for the build check before Play).
        $expected = foreach ($step in @($plan.Steps | Where-Object { $_.Action -eq 'keep' })) { [pscustomobject]@{ Path = $step.Path; Target = $step.Target; Size = $step.Size; Sha1 = $step.Sha1 } }
        Write-ClientRecord -GameFolder $GameFolder -ClientId $client.Id -Record ([pscustomobject]@{
            Version = 1; GameId = $game.Id; ClientId = $client.Id; ClientName = $client.Name; Source = $client.Source; Manifest = $client.Manifest
            ManifestHash = $plan.ManifestHash; ReleaseTag = $plan.ReleaseTag; InstalledAt = [DateTime]::UtcNow.ToString('o'); GameFolder = $GameFolder
            Files = @($files); Backups = @($backups.ToArray()); CreatedDirs = @($createdDirs | Select-Object -Unique); ExpectedGameFiles = @($expected)
            Snapshot = @($snapshot) })
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $count = { param($action) @($plan.Steps | Where-Object { $_.Action -eq $action }).Count }
    Write-Ok "$($client.Name) is installed for $($game.Name)."
    Write-Info ([string]::Format([cultureinfo]::InvariantCulture, 'Downloaded: {0}. Already current: {1}. Made from your own files: {2}. Your own game files kept: {3}. Skipped (not audited): {4}.',
        (& $count 'download'), (& $count 'current'), (& $count 'derive'), (& $count 'keep'), (& $count 'skip')))
    foreach ($skipped in @($plan.Steps | Where-Object { $_.Action -eq 'skip' } | Select-Object -First 5)) { Write-Host "  skipped: $($skipped.Path)" -ForegroundColor DarkGray }
    if ($client.Id -eq 'plutonium') { Complete-PlutoniumSetup -Game $game -GameFolder $GameFolder }
    if ($client.Source -eq 'shield') { $null = Invoke-ShieldContentSync -GameFolder $GameFolder }
    if ($client.Source -eq 'hmw') { Complete-HmwSetup -Client $client -GameFolder $GameFolder }
    return [pscustomobject]@{ GameFolder = $GameFolder; Downloaded = (& $count 'download'); Current = (& $count 'current'); Derived = (& $count 'derive'); Kept = (& $count 'keep'); Skipped = (& $count 'skip') }
}

# Same as installing: only changed files are downloaded, removed ones are cleaned up.
function Update-GameClient {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$ClientId, [string]$GameFolder = '', $Manifest = $null, [int]$RetryDelaySeconds = 3)
    $game = Get-CatalogGame -Id $GameId
    $client = $game.Clients | Where-Object { $_.Id -eq $ClientId } | Select-Object -First 1
    if ($client -and $client.Source -eq 'shield') {
        if (-not $GameFolder) { $found = Find-CatalogGame -Game $game; if ($found) { $GameFolder = $found.Folder } }
        $null = Invoke-ShieldContentSync -GameFolder $GameFolder
        return [pscustomobject]@{ Downloaded = 0 }
    }
    # GitHub clients and the HMW launcher move to their newest release.
    $latest = [bool]($client -and ($client.ReleaseRepo -or $client.Source -eq 'hmw'))
    $result = Install-GameClient -GameId $GameId -ClientId $ClientId -GameFolder $GameFolder -Manifest $Manifest -RetryDelaySeconds $RetryDelaySeconds -Latest:$latest
    if ($result.Downloaded -eq 0) { Write-Ok 'Already up to date.' }
    return $result
}

function Test-GameClientInstalled {
    param([Parameter(Mandatory)][string]$GameFolder, [Parameter(Mandatory)][string]$ClientId)
    $record = $null
    try { $record = Read-ClientRecord -GameFolder $GameFolder -ClientId $ClientId } catch { return $false }
    if ($null -eq $record) { return $false }
    foreach ($file in @($record.Files)) { if (-not (Test-Path -LiteralPath ([string]$file.Target) -PathType Leaf)) { return $false } }
    return $true
}

# How many files an update would download (needs the network). 0 means up to date.
function Get-GameClientUpdateCount {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GameFolder)
    switch ($Client.Source) {
        'archive' {
            $record = Read-ClientRecord -GameFolder $GameFolder -ClientId $Client.Id
            if ($null -eq $record) { return 1 }
            if ([string]$record.ArchiveSha256 -ne [string]$Client.Archive.Sha256) { return 1 }
            foreach ($file in @($record.Files)) { if (-not (Test-Path -LiteralPath ([string]$file.Target) -PathType Leaf)) { return 1 } }
            return 0
        }
        'shield' { $status = Invoke-ShieldLauncherHeadless -GameFolder $GameFolder; if (-not $status.Ok) { throw $(if ($status.Error) { $status.Error } else { 'Shield''s launcher could not check.' }) }; return [int]([bool]($status.Download -gt 0 -or $status.LauncherUpdate)) }
        'hmw' {
            $record = Read-ClientRecord -GameFolder $GameFolder -ClientId $Client.Id
            $installedVersion = if ($record -and $record.ReleaseTag) { [string]$record.ReleaseTag } else { $Client.ReleaseTag }
            return [int]((Get-HmwLatestRelease).Version -ne $installedVersion)
        }
    }
    $plan = Get-ClientInstallPlan -Client $Client -GameFolder $GameFolder -Latest:([bool]$Client.ReleaseRepo)
    return @($plan.Steps | Where-Object { $_.Action -eq 'download' }).Count
}

function Remove-GameClient {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$ClientId, [string]$GameFolder = '')
    $game = Get-CatalogGame -Id $GameId
    if (-not $GameFolder) { $found = Find-CatalogGame -Game $game; if ($found) { $GameFolder = $found.Folder } }
    if (-not $GameFolder) { throw "$($game.Name) was not found." }
    $GameFolder = [IO.Path]::GetFullPath($GameFolder).TrimEnd('\')
    $record = Read-ClientRecord -GameFolder $GameFolder -ClientId $ClientId
    if ($null -eq $record) { Write-Info "$ClientId is not installed in $GameFolder."; return }
    # A client installed on top of this one goes first (1.1X before 1.1), so a revert puts
    # every file of the folder back and not just this client's.
    foreach ($dependent in @(Get-InstalledDependentClients -Game $game -ClientId $ClientId -GameFolder $GameFolder)) {
        Write-Info "Removing $($dependent.Name) first: it was installed on top of $($record.ClientName)."
        Remove-GameClient -GameId $GameId -ClientId $dependent.Id -GameFolder $GameFolder
    }
    $owners = Get-ClientFileOwnerMap -GameFolder $GameFolder -ExceptClientId $ClientId
    $removed = 0; $restored = 0; $shared = 0
    foreach ($file in @($record.Files)) {
        $target = [string]$file.Target
        if ($owners.ContainsKey($target.ToLowerInvariant())) { $shared++; continue }
        if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop; $removed++ }
    }
    # A launcher-type client's launcher added files of its own: everything new since
    # the install under its watched paths goes (after asking, for whole-game watches).
    $client = $game.Clients | Where-Object { $_.Id -eq $ClientId } | Select-Object -First 1
    if ($client -and @($client.Watch).Count -gt 0 -and $null -ne $record.Snapshot) {
        $before = @{}
        foreach ($path in @($record.Snapshot)) { $before[([string]$path).ToLowerInvariant()] = $true }
        $added = @(Get-WatchedGameFiles -GameFolder $GameFolder -Patterns $client.Watch | Where-Object {
            -not $before.ContainsKey($_.ToLowerInvariant()) -and -not $owners.ContainsKey((Join-Path $GameFolder $_).ToLowerInvariant()) })
        if ($added.Count -gt 0) {
            $delete = $true
            if ($client.ConfirmCleanup) {
                Write-Info "$($added.Count) file(s) were added to $GameFolder since $($record.ClientName) was installed, for example:"
                foreach ($path in ($added | Select-Object -First 15)) { Write-Host "  $path" -ForegroundColor DarkGray }
                $delete = ((Read-Host "Delete these $($added.Count) file(s) too? [y/N]") -match '^(y|yes)$')
            }
            if ($delete) {
                $dirs = [System.Collections.Generic.List[string]]::new()
                foreach ($path in $added) {
                    $full = Join-Path $GameFolder $path
                    if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop; $removed++ }
                    $dirs.Add((Split-Path -Parent $full))
                }
                foreach ($dir in @($dirs | Select-Object -Unique | Sort-Object Length -Descending)) {
                    $walk = $dir
                    while ($walk -and $walk.Length -gt $GameFolder.Length -and (Test-Path -LiteralPath $walk -PathType Container) -and -not (Get-ChildItem -LiteralPath $walk -Force | Select-Object -First 1)) {
                        Remove-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue; $walk = Split-Path -Parent $walk
                    }
                }
            } else { Write-Info 'The added files were kept.' }
        }
    }
    # A client that sits on top of another one (1.1X on 1.1) backed up that client's own
    # file, so removing it puts that file back even though the other client owns the path.
    $layered = @($(if ($client) { @($client.Requires) } else { @() }))
    foreach ($backup in @($record.Backups)) {
        $owner = $owners[[string]$backup.Target.ToLowerInvariant()]
        if ($owner -and $layered -notcontains [string]$owner.ClientId) { continue }
        if (Test-Path -LiteralPath ([string]$backup.Backup) -PathType Leaf) { Copy-FileAtomically -Source ([string]$backup.Backup) -Destination ([string]$backup.Target); $restored++ }
    }
    foreach ($dir in @(@($record.CreatedDirs) | Sort-Object { ([string]$_).Length } -Descending)) {
        $dir = [string]$dir
        if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    }
    $backupRoot = Get-ClientBackupRoot -GameFolder $GameFolder -ClientId $ClientId
    if (Test-Path -LiteralPath $backupRoot) { Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $backupsBase = Join-Path $GameFolder '.codhq-backups'
    if ((Test-Path -LiteralPath $backupsBase) -and -not (Get-ChildItem -LiteralPath $backupsBase -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $backupsBase -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Get-ClientRecordPath -GameFolder $GameFolder -ClientId $ClientId) -Force -ErrorAction Stop
    Write-Ok "$($record.ClientName) was removed from $($game.Name)."
    Write-Info "Removed files: $removed. Original game files put back: $restored. Kept because another client uses them: $shared."
}

# ==========================================
# GAMES: PROJECT BO4 (SHIELD) AND HORIZONMW LAUNCHERS
# ==========================================
function Get-ShieldLauncherPath { param([Parameter(Mandatory)][string]$GameFolder) Join-Path $GameFolder 'project-bo4\launcher\Shield_Launcher.exe' }

# Runs Shield's launcher without its window: --check reports what it would download,
# --sync downloads it (the launcher's own content updater, with its own checksums).
# The result is the launcher's content-sync.log.
function Invoke-ShieldLauncherHeadless {
    param([Parameter(Mandatory)][string]$GameFolder, [switch]$Sync, [int]$TimeoutMinutes = 360)
    $exe = Get-ShieldLauncherPath -GameFolder $GameFolder
    $result = [pscustomobject]@{ Ok = $false; Ready = $false; Download = 0; LauncherUpdate = $false; Synced = $false; Error = ''; Log = @() }
    if (Test-SandboxMode) {
        Write-Host "[SANDBOX] Would run: `"$exe`" $(if ($Sync) { '--sync' } else { '--check' })" -ForegroundColor DarkYellow
        $result.Ok = $true; $result.Ready = $true; $result.Synced = [bool]$Sync
        return $result
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Shield's launcher is missing ($exe). Install Project BO4 again." }
    $launcherDir = Split-Path -Parent $exe
    $log = Join-Path $launcherDir 'content-sync.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $exe -ArgumentList $(if ($Sync) { '--sync' } else { '--check' }) -WorkingDirectory $launcherDir -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $shown = 0
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        Invoke-UiPump
        if (Test-Path -LiteralPath $log) {
            $lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
            for (; $shown -lt $lines.Count; $shown++) { if ($lines[$shown] -match '^phase (.+) total (\d+)') { Write-Info ("Shield: {0} ({1})" -f $Matches[1], $Matches[2]) } }
        }
    }
    if (-not $process.HasExited) { try { $process.Kill() } catch { Write-Verbose 'Already closed.' }; $result.Error = 'Shield''s launcher did not finish in time.'; return $result }
    $result = ConvertFrom-ShieldSyncLog -Lines @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
    if ($process.ExitCode -ne 0 -and -not $result.Error) { $result.Error = "Shield's launcher exited with code $($process.ExitCode)." }
    return $result
}

# Reads the result lines Shield's launcher writes (launcher_main.cpp, run_headless):
# "ok <0|1> ready <0|1> download <n> launcher_update <0|1> error <text>", per-component
# lines, and with --sync "sync ok|failed <error>".
function ConvertFrom-ShieldSyncLog {
    param([string[]]$Lines = @())
    $result = [pscustomobject]@{ Ok = $false; Ready = $false; Download = 0; LauncherUpdate = $false; Synced = $false; Error = ''; Log = @($Lines) }
    foreach ($line in @($Lines)) {
        if ($line -match '^ok (\d) ready (\d) download (\d+) launcher_update (\d) error ?(.*)$') {
            $result.Ok = ($Matches[1] -eq '1'); $result.Ready = ($Matches[2] -eq '1'); $result.Download = [int64]$Matches[3]; $result.LauncherUpdate = ($Matches[4] -eq '1'); $result.Error = $Matches[5].Trim()
        }
        if ($line -match '^sync (ok|failed) ?(.*)$') { $result.Synced = ($Matches[1] -eq 'ok'); if ($Matches[1] -eq 'failed') { $result.Error = $Matches[2].Trim() } }
    }
    return $result
}

function Invoke-ShieldContentSync {
    param([Parameter(Mandatory)][string]$GameFolder)
    Write-Info 'Shield''s launcher is downloading the client, the support mod and Target Range (about 2.2 GB) ...'
    $result = Invoke-ShieldLauncherHeadless -GameFolder $GameFolder -Sync
    if ($result.Synced -or ($result.Ok -and $result.Ready -and $result.Download -eq 0)) { Write-Ok 'Shield''s files are downloaded and checked by its launcher.'; return $result }
    Write-Warn "Shield's launcher did not finish its download: $(if ($result.Error) { $result.Error } else { 'no result' }). Use Update to try again, or open Shield's launcher (Play) and press Download all."
    return $result
}

function Get-HmwLatestRelease {
    $info = Invoke-RestMethod -Uri 'https://api.horizonmw.org/downloads/latest' -Headers @{ 'User-Agent' = 'CallOfDutyHQ-SetupUtility/1.1' } -TimeoutSec 30
    $url = [string]$info.fileUrl
    if ($url -notmatch '^https://([a-z0-9-]+\.)*horizonmw\.org/') { throw "HorizonMW's download address is not on horizonmw.org: $url" }
    $checksum = [string]$info.checksum
    [pscustomobject]@{ Version = [string]$info.version; Url = $url; Size = [int64]$info.fileSize
        Sha256 = $(if ($checksum -match '^(sha256:)?([0-9a-fA-F]{64})$') { $Matches[2].ToLowerInvariant() } else { '' }) }
}

# The Microsoft Visual C++ 2015-2022 runtime (x64) that HorizonMW's guide asks for.
function Test-VcRuntimeInstalled {
    foreach ($path in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') {
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($item -and [int]$item.Installed -eq 1) { return $true }
    }
    return $false
}

# After the launcher is in place, as HorizonMW's guide continues: point it at the MWR
# folder, then Verify game files (which downloads the mod).
function Complete-HmwSetup {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][string]$GameFolder)
    if (-not (Test-VcRuntimeInstalled)) { Write-Warn 'The Visual C++ runtime HorizonMW needs is not installed. Get it from Microsoft: https://aka.ms/vs/17/release/vc_redist.x64.exe' }
    try { [System.Windows.Forms.Clipboard]::SetText($GameFolder); Write-Info "Your MWR folder is on the clipboard: $GameFolder" } catch { Write-Info "Your MWR folder: $GameFolder" }
    Write-Info 'In the HMW Launcher: cog button > Select Install Directory > paste the MWR folder, then press Verify game files, then Reverify game files. After that, Play works from this card.'
    $launcher = Join-Path (Join-Path (Get-ClientAppDataRoot) $Client.AppData) 'HMW Launcher.exe'
    if (Test-SandboxMode) { Write-Host "[SANDBOX] Would open: $launcher" -ForegroundColor DarkYellow; return }
    if (Test-Path -LiteralPath $launcher -PathType Leaf) { Start-Process -FilePath $launcher -WorkingDirectory (Split-Path -Parent $launcher); Write-Ok 'HMW Launcher opened.' }
}

# ==========================================
# GAMES: WHEN A MODE CAN START
# ==========================================
function Get-CatalogClientName {
    param([Parameter(Mandatory)][string]$Id, $Game = $null)
    if ($Game) { $own = $Game.Clients | Where-Object { $_.Id -eq $Id } | Select-Object -First 1; if ($own) { return $own.Name } }
    foreach ($game in Get-GameCatalog) { $client = $game.Clients | Where-Object { $_.Id -eq $Id } | Select-Object -First 1; if ($client) { return $client.Name } }
    return $Id
}

# Why a mode cannot start right now, or '' when it can.
function Get-ModeBlocker {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)]$Mode, [Parameter(Mandatory)][string]$GameFolder)
    # A Windows error box ("could not be located in the DLL", "Failed to find Steam") is
    # never useful: check the executable's own DLLs first.
    if ($Mode.Kind -eq 'exe') {
        $exePath = Join-Path $GameFolder $Mode.Exe
        if (Test-Path -LiteralPath $exePath -PathType Leaf) {
            $missingDlls = @(Get-MissingExecutableDependency -Executable $exePath)
            if ($missingDlls.Count -gt 0) {
                return "$($Mode.Label) cannot start: your $($Game.Name) install is missing $($missingDlls -join ', '). In Steam: right-click the game > Properties > Installed Files > Verify integrity of game files, then try again."
            }
        }
    }
    if (@($Mode.Clients).Count -gt 0) {
        $installed = @($Mode.Clients | Where-Object { Test-GameClientInstalled -GameFolder $GameFolder -ClientId $_ })
        if ($installed.Count -eq 0) { return ("$($Mode.Label) needs " + (($Mode.Clients | ForEach-Object { Get-CatalogClientName $_ $Game }) -join ' or ') + '. Use Install client first.') }
    }
    return ''
}

# Writes values into a client's JSON settings file (dotted keys: 'section.key'), keeping
# everything else in it. A file that cannot be read is left alone.
function Set-JsonSettingValues {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Values = @{})
    $data = [pscustomobject]@{}
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try { $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warn "$(Split-Path -Leaf $Path) could not be read; it was left alone."; return $false }
        if ($data -isnot [pscustomobject]) { Write-Warn "$(Split-Path -Leaf $Path) is not a settings object; it was left alone."; return $false }
    }
    foreach ($key in $Values.Keys) {
        $parts = ([string]$key) -split '\.'
        $node = $data
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $child = $node.PSObject.Properties[$parts[$i]]
            if ($null -eq $child -or $child.Value -isnot [pscustomobject]) { $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{}) -Force; $child = $node.PSObject.Properties[$parts[$i]] }
            $node = $child.Value
        }
        $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Values[$key] -Force
    }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, ($data | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
    return $true
}

# ==========================================
# GAMES: PLUTONIUM
# ==========================================
function Get-PlutoniumRoot { Join-Path (Get-ClientAppDataRoot) 'Plutonium' }

function Get-PlutoniumRemoteRevision {
    $prod = Invoke-RestMethod -Uri 'https://cdn.plutonium.pw/updater/prod.json' -Headers @{ 'User-Agent' = 'CallOfDutyHQ-SetupUtility/1.1' } -TimeoutSec 30
    $infoUrl = [string]@($prod.manifests)[0]
    if (-not $infoUrl) { throw 'Plutonium''s prod.json lists no manifest.' }
    $info = Invoke-RestMethod -Uri $infoUrl -Headers @{ 'User-Agent' = 'CallOfDutyHQ-SetupUtility/1.1' } -TimeoutSec 30
    return [int]$info.revision
}

function Get-PlutoniumLocalRevision {
    $info = Join-Path (Get-PlutoniumRoot) 'info.json'
    if (-not (Test-Path -LiteralPath $info -PathType Leaf)) { return $null }
    try { return [int](Get-Content -LiteralPath $info -Raw | ConvertFrom-Json).revision } catch { return $null }
}

# Writes one game path into Plutonium's config.json the way the CB launcher does: all
# required fields present, written through a temp file, and a file that cannot be
# read or parsed is left alone (it holds the login token).
function Set-PlutoniumGamePath {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Path)
    $root = Get-PlutoniumRoot
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force }
    $config = Join-Path $root 'config.json'
    $data = [ordered]@{}
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        try { $existing = Get-Content -LiteralPath $config -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warn "Plutonium's config.json could not be read; it was left alone."; return $false }
        if ($existing -isnot [pscustomobject]) { Write-Warn "Plutonium's config.json is not an object; it was left alone."; return $false }
        foreach ($property in $existing.PSObject.Properties) { $data[$property.Name] = $property.Value }
    }
    foreach ($field in 'iw5Path', 't4Path', 't5Path', 't6Path', 'token') { if (-not $data.Contains($field)) { $data[$field] = '' } }
    if ([string]$data[$Key] -eq $Path) { return $true }
    $data[$Key] = $Path
    $temp = Join-Path $root 'config.json.tmp'
    try {
        [IO.File]::WriteAllText($temp, ([pscustomobject]$data | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $config -Force -ErrorAction Stop
    } catch { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw }
    return $true
}

# Brings Plutonium up to date with the bootstrapper in the game folder, like the CB
# launcher: only when the published revision differs from the installed one; the
# updater's window stays open when it is done, so the new revision appearing is what
# marks completion.
function Update-Plutonium {
    param([Parameter(Mandatory)][string]$GameFolder, [int]$TimeoutSeconds = 900)
    $bootstrapper = Join-Path $GameFolder 'plutonium.exe'
    if (-not (Test-Path -LiteralPath $bootstrapper -PathType Leaf)) { throw 'plutonium.exe is missing from the game folder; install the Plutonium client first.' }
    $remote = $null
    try { $remote = Get-PlutoniumRemoteRevision } catch { Write-Warn "Could not read Plutonium's published revision ($($_.Exception.Message)); assuming it is current." ; return }
    $local = Get-PlutoniumLocalRevision
    if ($null -ne $local -and $local -eq $remote) { Write-Ok "Plutonium is up to date (revision $remote)."; return }
    if (Test-SandboxMode) { Write-Host "[SANDBOX] Plutonium would be updated to revision $remote here; skipped in sandbox mode." -ForegroundColor DarkYellow; return }
    Write-Info "Updating Plutonium from revision $(if ($null -ne $local) { $local } else { 'none' }) to $remote ..."
    $process = Start-Process -FilePath $bootstrapper -ArgumentList '-update-only -no-self-update' -WorkingDirectory $GameFolder -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        Invoke-UiPump
        if ((Get-PlutoniumLocalRevision) -eq $remote) {
            if (-not $process.HasExited) { try { $process.Kill() } catch { Write-Verbose 'The Plutonium updater had already closed.' } }
            Write-Ok "Plutonium updated to revision $remote."
            return
        }
        if ($process.HasExited -and (Get-PlutoniumLocalRevision) -ne $remote) { break }
    }
    Write-Warn 'The Plutonium updater did not finish. Start it again with Update, or run plutonium.exe from the game folder.'
}

function Complete-PlutoniumSetup {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)][string]$GameFolder)
    if ($Game.PlutoniumKey) { if (Set-PlutoniumGamePath -Key $Game.PlutoniumKey -Path $GameFolder) { Write-Ok "Plutonium knows where $($Game.Name) is." } }
    Update-Plutonium -GameFolder $GameFolder
    Write-Info 'Plutonium needs a free account: use Plutonium login to sign in once.'
}

# Opens Plutonium's own window (no arguments), where the player signs in.
function Start-PlutoniumLogin {
    $launcher = Join-Path (Get-PlutoniumRoot) 'bin\plutonium-launcher-win32.exe'
    if (Test-SandboxMode) { Write-Host "[SANDBOX] Would open Plutonium's login: $launcher" -ForegroundColor DarkYellow; return }
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Plutonium is not installed yet. Install the Plutonium client for one of its games first.' }
    Start-Process -FilePath $launcher -WorkingDirectory (Get-PlutoniumRoot)
    Write-Ok 'Plutonium opened. Sign in there; the login is remembered.'
}

# ==========================================
# GAMES: LAUNCH
# ==========================================
# The player name, as the clients accept it: printable characters, at most 16.
function Get-CleanPlayerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $clean = ($Name -replace '[^\w \-\.\[\]\(\)]', '').Trim()
    if ($clean.Length -gt 16) { $clean = $clean.Substring(0, 16) }
    return $clean
}

function Save-PlayerName {
    param([string]$Name)
    $settings = Get-AppSettings
    $settings.PlayerName = Get-CleanPlayerName $Name
    return (Save-AppSettings -Settings $settings)
}

# The main executable's version and size, and whether the game files a client was
# built against still match (shown before every Play).
function Get-GameBuildInfo {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)][string]$GameFolder)
    $exe = $Game.ValidFiles | Where-Object { $_ -like '*.exe' -and (Test-Path -LiteralPath (Join-Path $GameFolder $_) -PathType Leaf) } | Select-Object -First 1
    $info = [pscustomobject]@{ Executable = $exe; Version = ''; Size = 0; Mismatches = @() }
    if ($exe) {
        $path = Join-Path $GameFolder $exe
        $info.Version = [string]([Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion)
        $info.Size = (Get-Item -LiteralPath $path).Length
    }
    $mismatches = [System.Collections.Generic.List[object]]::new()
    foreach ($recordFile in @(Get-ChildItem -LiteralPath $GameFolder -Filter '.codhq-client-*.json' -File -Force -ErrorAction SilentlyContinue)) {
        $record = $null
        try { $record = Get-Content -LiteralPath $recordFile.FullName -Raw | ConvertFrom-Json } catch { continue }
        foreach ($expected in @($record.ExpectedGameFiles)) {
            $target = [string]$expected.Target
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $mismatches.Add([pscustomobject]@{ Client = [string]$record.ClientName; Path = [string]$expected.Path; Found = 'missing'; Expected = [string]$expected.Sha1 }); continue }
            if ((Get-Item -LiteralPath $target).Length -ne [int64]$expected.Size -or (Get-FileSha1Hex $target) -ne [string]$expected.Sha1) {
                $mismatches.Add([pscustomobject]@{ Client = [string]$record.ClientName; Path = [string]$expected.Path; Found = (Get-FileSha1Hex $target); Expected = [string]$expected.Sha1 })
            }
        }
    }
    $info.Mismatches = $mismatches.ToArray()
    return $info
}

# CB adds this compatibility flag for the oldest games so they scale correctly.
function Set-DpiAwareFlag {
    param([Parameter(Mandatory)][string]$Executable)
    if (Test-SandboxMode) { return }
    $key = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    $current = [string](Get-ItemProperty -LiteralPath $key -Name $Executable -ErrorAction SilentlyContinue).$Executable
    if ($current -split ' ' -contains 'HIGHDPIAWARE') { return }
    $value = if ([string]::IsNullOrWhiteSpace($current)) { '~ HIGHDPIAWARE' } else { $current.Trim() + ' HIGHDPIAWARE' }
    New-ItemProperty -LiteralPath $key -Name $Executable -Value $value -PropertyType String -Force | Out-Null
}

# Builds the exact command for a game and mode (from the CB launcher's configuration).
function Get-CatalogLaunchCommand {
    param([Parameter(Mandatory)]$Game, [Parameter(Mandatory)]$Mode, [Parameter(Mandatory)][string]$GameFolder, [string]$PlayerName = '')
    if ($Mode.Kind -eq 'plutonium') {
        return [pscustomobject]@{ FilePath = (Join-Path (Get-PlutoniumRoot) 'bin\plutonium-launcher-win32.exe'); Arguments = 'plutonium://play/' + $Mode.Uri; WorkingDirectory = (Get-PlutoniumRoot); Elevate = $false }
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Game.DefaultArguments -and -not $Mode.NoDefaultArguments) { $parts.Add($Game.DefaultArguments) }
    if ($Mode.Arguments) { $parts.Add($Mode.Arguments) }
    $name = Get-CleanPlayerName $PlayerName
    if ($name -and $Mode.UseName -and $Game.NameArgument) { $parts.Add($Game.NameArgument + ' "' + $name + '"') }
    $folder = $GameFolder
    if ($Mode.Kind -eq 'client') {
        # A launcher kept in the client's own folder (outside the game).
        $client = $Game.Clients | Where-Object { $_.Id -eq @($Mode.Clients)[0] } | Select-Object -First 1
        $folder = Join-Path (Get-ClientAppDataRoot) $client.AppData
    }
    return [pscustomobject]@{ FilePath = (Join-Path $folder $Mode.Exe); Arguments = ($parts -join ' '); WorkingDirectory = $folder; Elevate = ([bool]$Game.NeedsElevation -or [bool]$Mode.Elevate) }
}

function Start-CatalogGame {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$ModeId, [string]$GameFolder = '')
    $game = Get-CatalogGame -Id $GameId
    $mode = $game.Modes | Where-Object { $_.Id -eq $ModeId } | Select-Object -First 1
    if ($null -eq $mode) { throw "$($game.Name) has no mode '$ModeId'." }
    if (-not $GameFolder) { $found = Find-CatalogGame -Game $game; if ($found) { $GameFolder = $found.Folder } }
    if (-not $GameFolder) {
        if ($game.Detect -eq 'none') { throw "$($game.Name) is not detected: pick its folder with Change folder first." }
        throw "$($game.Name) was not found. Install it from Steam or pick its folder with Change folder."
    }
    $blocker = Get-ModeBlocker -Game $game -Mode $mode -GameFolder $GameFolder
    if ($blocker) { throw $blocker }
    $build = Get-GameBuildInfo -Game $game -GameFolder $GameFolder
    if ($build.Executable) { Write-Info ([string]::Format([cultureinfo]::InvariantCulture, 'Game build: {0} version {1}, {2:N0} bytes.', $build.Executable, $(if ($build.Version) { $build.Version } else { 'unknown' }), $build.Size)) }
    foreach ($m in $build.Mismatches) {
        Write-Warn "$($m.Client) was installed against a different $($m.Path) (expected SHA-1 $($m.Expected), found $($m.Found)). If the game does not start, verify the game files in Steam."
    }
    if ($mode.Kind -eq 'plutonium') {
        if ($game.PlutoniumKey) { $null = Set-PlutoniumGamePath -Key $game.PlutoniumKey -Path $GameFolder }
        Update-Plutonium -GameFolder $GameFolder
    }
    foreach ($exe in @($game.DpiFix)) { try { Set-DpiAwareFlag -Executable (Join-Path $GameFolder $exe) } catch { Write-Verbose 'DPI flag not set.' } }
    $playerName = [string](Get-AppSettings).PlayerName
    if ($mode.Config) {
        $values = @{}
        foreach ($key in $mode.Config.Values.Keys) { $values[$key] = $mode.Config.Values[$key] }
        $clean = Get-CleanPlayerName $playerName
        if ($clean -and $mode.Config.NameKey) { $values[$mode.Config.NameKey] = $clean }
        if (Set-JsonSettingValues -Path (Join-Path $GameFolder $mode.Config.File) -Values $values) { Write-Info "Settings written to $($mode.Config.File): $((($values.Keys | Sort-Object) | ForEach-Object { "$_ = $($values[$_])" }) -join ', ')" }
    }
    $command = Get-CatalogLaunchCommand -Game $game -Mode $mode -GameFolder $GameFolder -PlayerName $playerName
    if (Test-SandboxMode) {
        Write-Host ("[SANDBOX] Would start: `"{0}`" {1}" -f $command.FilePath, $command.Arguments) -ForegroundColor DarkYellow
        return $command
    }
    if (-not (Test-Path -LiteralPath $command.FilePath -PathType Leaf)) { throw "Not found: $($command.FilePath). Install or update the client first." }
    Write-Info ("Starting {0} - {1}: `"{2}`" {3}" -f $game.Name, $mode.Label, $command.FilePath, $command.Arguments)
    $startArgs = @{ FilePath = $command.FilePath; WorkingDirectory = $command.WorkingDirectory }
    if ($command.Arguments) { $startArgs.ArgumentList = $command.Arguments }
    if ($command.Elevate) { $startArgs.Verb = 'RunAs' }
    Start-Process @startArgs
    Write-Ok "$($game.Name) started."
    return $command
}

# ==========================================
# GAMES: AUTOMATIC UPDATES
# ==========================================
# Checks the given installed clients (all of them when none are named) and updates
# the ones whose source has something new. One client failing does not stop the others.
function Invoke-ClientAutoUpdate {
    param([string]$GameId = '', [string[]]$ClientIds = @())
    $updated = 0; $checked = 0
    if ($null -eq $global:GameUpdateCounts) { $global:GameUpdateCounts = @{} }
    foreach ($game in Get-GameCatalog) {
        if ($GameId -and $game.Id -ne $GameId) { continue }
        $found = $null
        try { $found = Find-CatalogGame -Game $game } catch { $found = $null }
        if (-not $found) { continue }
        foreach ($client in $game.Clients) {
            if (@($ClientIds).Count -gt 0 -and @($ClientIds) -notcontains $client.Id) { continue }
            if (-not (Test-GameClientInstalled -GameFolder $found.Folder -ClientId $client.Id)) { continue }
            $checked++
            try {
                $count = Get-GameClientUpdateCount -Client $client -GameFolder $found.Folder
                $global:GameUpdateCounts[$game.Id + '|' + $client.Id] = $count
                if ($count -le 0) { continue }
                Write-Info "$($game.Name) - $($client.Name): an update is available; installing it."
                $null = Update-GameClient -GameId $game.Id -ClientId $client.Id -GameFolder $found.Folder
                $global:GameUpdateCounts[$game.Id + '|' + $client.Id] = 0
                $updated++
            } catch { Write-Warn "$($game.Name) - $($client.Name): could not update ($($_.Exception.Message))" }
        }
    }
    if ($checked -gt 0) { Write-Ok "Automatic update: checked $checked client(s), updated $updated." }
    return [pscustomobject]@{ Checked = $checked; Updated = $updated }
}

# The version of this utility published on the main branch (read from the first
# bytes of install.ps1 there), or $null when it cannot be read.
function Get-PublishedAppVersion {
    try {
        $request = [Net.HttpWebRequest]::Create($ScriptRawUrl)
        $request.UserAgent = 'CallOfDutyHQ-SetupUtility/1.1'
        $request.Timeout = 15000
        $request.AddRange(0, 4095)
        $response = $request.GetResponse()
        try { $reader = New-Object IO.StreamReader($response.GetResponseStream()); $head = $reader.ReadToEnd() } finally { $response.Close() }
        $match = [regex]::Match($head, '\$AppVersion\s*=\s*''([0-9]+(\.[0-9]+){1,3})''')
        if ($match.Success) { return [version]$match.Groups[1].Value }
    } catch { Write-Verbose "Could not read the published version: $($_.Exception.Message)" }
    return $null
}

function Test-AppUpdate {
    $published = Get-PublishedAppVersion
    if ($null -eq $published) { Write-Info 'Could not check for a newer version of this utility.'; return $null }
    if ($published -gt [version]$global:AppVersion) {
        $how = if ($env:CODHQ_LAUNCHER -eq 'exe') { 'Download the new CodHQ-Setup.exe from https://github.com/LarkTheStar/fix-installer/releases' } else { 'Start it again with the same command to get it' }
        Write-Warn "A newer version of this utility is out: $published (this is $($global:AppVersion)). $how."
        return $true
    }
    Write-Ok "This utility is up to date ($($global:AppVersion))."
    return $false
}

# ==========================================
# GAMES: EXECUTABLE CHECK (BO3 / BO4)
# ==========================================
# Checks the player's own executable against the build the client expects (the size
# and SHA-1 CB publishes for it). The executable itself is never downloaded.
function Test-GameExecutable {
    param([Parameter(Mandatory)][string]$GameId, [string]$GameFolder = '', $Manifest = $null)
    $game = Get-CatalogGame -Id $GameId
    if ($null -eq $game.ExeCheck) { throw "$($game.Name) has no executable check." }
    if (-not $GameFolder) { $found = Find-CatalogGame -Game $game; if ($found) { $GameFolder = $found.Folder } }
    if (-not $GameFolder) { throw "$($game.Name) was not found. Pick its folder with Change folder." }
    $file = Join-Path $GameFolder $game.ExeCheck.File
    $result = [pscustomobject]@{ File = $file; Exists = $false; Version = ''; Product = ''; Size = 0; Sha1 = ''; Sha256 = ''
        ExpectedSize = 0; ExpectedSha1 = ''; Matches = $false; MissingFiles = @(); Repair = $game.ExeCheck.Repair }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Write-Warn "$($game.ExeCheck.File) was not found in $GameFolder."
        Write-Info $game.ExeCheck.Repair
        return $result
    }
    $item = Get-Item -LiteralPath $file -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$file is a link, not the game's own file." }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
    $result.Exists = $true
    $result.Version = [string]$versionInfo.FileVersion
    $result.Product = [string]$versionInfo.ProductName
    $result.Size = $item.Length
    $result.Sha1 = Get-FileSha1Hex $file
    $result.Sha256 = Get-FileSha256 -Path $file
    $result.MissingFiles = @($game.ValidFiles | Where-Object { $_ -ne $game.ExeCheck.File -and -not (Test-Path -LiteralPath (Join-Path $GameFolder $_)) })
    Write-Info ([string]::Format([cultureinfo]::InvariantCulture, '{0}: version {1}, {2:N0} bytes', $game.ExeCheck.File, $(if ($result.Version) { $result.Version } else { 'unknown' }), $result.Size))
    Write-Info "  SHA-1   $($result.Sha1)"
    Write-Info "  SHA-256 $($result.Sha256)"
    try {
        if ($null -eq $Manifest) { $Manifest = Get-ClientManifest -Manifest $game.ExeCheck.Manifest }
        $expected = $Manifest.Entries | Where-Object { ($_.Path -split '/')[-1] -ieq $game.ExeCheck.File } | Select-Object -First 1
        if ($expected) {
            $result.ExpectedSize = $expected.Size; $result.ExpectedSha1 = $expected.Sha1
            $result.Matches = ($expected.Size -eq $result.Size -and $expected.Sha1 -eq $result.Sha1)
            if ($result.Matches) { Write-Ok "This is the build the client expects." }
            else {
                Write-Warn ([string]::Format([cultureinfo]::InvariantCulture, 'This is a different build than the client expects ({0:N0} bytes, SHA-1 {1}).', $expected.Size, $expected.Sha1))
                Write-Info $game.ExeCheck.Repair
            }
        } else { Write-Warn 'The client''s manifest does not name an expected build; only your file was checked.' }
    } catch { Write-Warn "Could not read the expected build ($($_.Exception.Message)); only your file was checked." }
    foreach ($missingFile in $result.MissingFiles) { Write-Info "Not present (may be normal for your edition): $missingFile" }
    return $result
}

# ==========================================
# GAMES: CD KEYS (the player's own)
# ==========================================
# The registry locations the CB launcher uses (docs/cb-launcher/executables-and-keys.md).
# Values are 20 uppercase letters and digits without dashes. Only a key the player
# types is written; this file contains none. Keys never reach the log.
function Get-CdKeySpec {
    param([Parameter(Mandatory)][string]$GameId)
    switch ($GameId) {
        'cod4' { return [pscustomobject]@{ Subkey = 'SOFTWARE\Activision\Call of Duty 4'; ValueNames = @('codkey'); Hklm = '' } }
        default { throw "$GameId has no CD key." }
    }
}

# Where CD keys are written: the real HKCU, or a private key in sandbox mode and tests.
function Get-CdKeyRegistryRoot {
    if (-not [string]::IsNullOrWhiteSpace([string]$global:CdKeyRegistryRootOverride)) { return [string]$global:CdKeyRegistryRootOverride }
    if (Test-SandboxMode) { return 'HKCU:\SOFTWARE\codhq-sandbox\' }
    return 'HKCU:\'
}

function ConvertTo-CdKey {
    param([string]$Key)
    $normal = ([string]$Key -replace '[\s-]', '').ToUpperInvariant()
    if ($normal -notmatch '^[A-Z0-9]{20}$') { throw 'A CD key is 20 letters and digits (dashes and spaces are ignored). Copy it from Steam: right-click the game > Manage > CD Keys.' }
    return $normal
}

function Format-MaskedCdKey {
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return '(none)' }
    $tail = if ($Key.Length -ge 4) { $Key.Substring($Key.Length - 4) } else { $Key }
    return ('****-****-****-****-' + $tail)
}

# The retail installer's key in HKLM (32-bit view), which must never be shadowed.
function Get-RetailCdKeyPresent {
    param([Parameter(Mandatory)]$Spec)
    if (-not $Spec.Hklm -or (Get-CdKeyRegistryRoot) -ne 'HKCU:\') { return $false }
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $key = $base.OpenSubKey($Spec.Hklm)
        if ($null -eq $key) { return $false }
        try { foreach ($name in $Spec.ValueNames) { if (-not [string]::IsNullOrEmpty([string]$key.GetValue($name))) { return $true } } } finally { $key.Dispose() }
    } catch { Write-Verbose 'HKLM not readable.' }
    return $false
}

function Get-GameCdKeyStatus {
    param([Parameter(Mandatory)][string]$GameId)
    $spec = Get-CdKeySpec -GameId $GameId
    $path = (Get-CdKeyRegistryRoot) + $spec.Subkey
    $values = foreach ($name in $spec.ValueNames) {
        $value = [string](Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue).$name
        [pscustomobject]@{ Name = $name; Present = -not [string]::IsNullOrEmpty($value); Masked = (Format-MaskedCdKey $value) }
    }
    [pscustomobject]@{ GameId = $GameId; RegistryPath = $path; Values = @($values); RetailKeyInHklm = (Get-RetailCdKeyPresent -Spec $spec) }
}

function Get-CdKeyBackupFolder { Join-Path $SettingsDirectory 'cdkey-backups' }

# Runs reg.exe with its output captured. reg.exe reports success on stderr, which
# Windows PowerShell would otherwise turn into an error; the exit code decides.
function Invoke-RegExe {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\reg.exe'
    $startInfo.Arguments = ($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEnd(); $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr).Trim() }
    } finally { $process.Dispose() }
}

# Exports the current key to a .reg file. When there is no key yet, the backup says
# so, and restoring it removes the values again.
function Backup-GameCdKey {
    param([Parameter(Mandatory)][string]$GameId)
    $spec = Get-CdKeySpec -GameId $GameId
    $root = Get-CdKeyRegistryRoot
    $folder = Get-CdKeyBackupFolder
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $file = Join-Path $folder ('{0}-{1}.reg' -f $GameId, (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
    if (Test-Path -LiteralPath ($root + $spec.Subkey)) {
        $regPath = (($root -replace '^HKCU:\\', 'HKCU\') + $spec.Subkey)
        $reg = Invoke-RegExe -Arguments @('export', $regPath, $file, '/y')
        if ($reg.ExitCode -ne 0) { throw "Backing up the CD key failed: $($reg.Output)" }
    } else {
        [IO.File]::WriteAllText($file, "Windows Registry Editor Version 5.00`r`n`r`n; codhq: no key existed`r`n", [Text.Encoding]::Unicode)
    }
    Write-Ok "CD key backed up to $file"
    return $file
}

function Get-GameCdKeyBackupList {
    param([Parameter(Mandatory)][string]$GameId)
    $folder = Get-CdKeyBackupFolder
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $folder -Filter "$GameId-*.reg" -File | Sort-Object Name -Descending)
}

function Set-GameCdKey {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$Key)
    $spec = Get-CdKeySpec -GameId $GameId
    $normal = ConvertTo-CdKey $Key
    if (Get-RetailCdKeyPresent -Spec $spec) { throw 'This game already has a key from its own installer (in HKLM). It is used as it is; nothing was changed.' }
    $null = Backup-GameCdKey -GameId $GameId
    $path = (Get-CdKeyRegistryRoot) + $spec.Subkey
    if (-not (Test-Path -LiteralPath $path)) { $null = New-Item -Path $path -Force }
    foreach ($name in $spec.ValueNames) { New-ItemProperty -LiteralPath $path -Name $name -Value $normal -PropertyType String -Force | Out-Null }
    foreach ($name in $spec.ValueNames) {
        if ([string](Get-ItemProperty -LiteralPath $path -Name $name).$name -ne $normal) { throw "The CD key could not be confirmed after writing ($name)." }
    }
    Write-Ok ("CD key saved: {0}" -f (Format-MaskedCdKey $normal))
}

function Restore-GameCdKey {
    param([Parameter(Mandatory)][string]$GameId, [Parameter(Mandatory)][string]$BackupFile)
    $spec = Get-CdKeySpec -GameId $GameId
    if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) { throw "Backup not found: $BackupFile" }
    $path = (Get-CdKeyRegistryRoot) + $spec.Subkey
    $text = [IO.File]::ReadAllText($BackupFile)
    if ($text -match '; codhq: no key existed') {
        foreach ($name in $spec.ValueNames) { Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue }
    } else {
        $reg = Invoke-RegExe -Arguments @('import', $BackupFile)
        if ($reg.ExitCode -ne 0) { throw "Restoring the CD key failed: $($reg.Output)" }
    }
    $status = Get-GameCdKeyStatus -GameId $GameId
    Write-Ok ("CD key restored: {0}" -f (($status.Values | ForEach-Object { "$($_.Name) $($_.Masked)" }) -join ', '))
}

# ==========================================
# WPF GUI DEFINITION (Ultimate Cool Design)
# ==========================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Call of Duty MW4 Setup Utility" Height="780" Width="1150"
        MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"
        Background="{DynamicResource BgDark}" Foreground="{DynamicResource TextPrimary}" FontFamily="Segoe UI">
    <Window.Resources>
        <!-- Colors -->
        <SolidColorBrush x:Key="BgDark" Color="#0B0B0E"/>
        <SolidColorBrush x:Key="BgSidebar" Color="#08080A"/>
        <SolidColorBrush x:Key="BgCard" Color="#15151E"/>
        <SolidColorBrush x:Key="BgCardHover" Color="#1E1E2B"/>
        <SolidColorBrush x:Key="Accent" Color="#00A8FF"/>
        <SolidColorBrush x:Key="AccentHover" Color="#33BFFF"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#A0A0B0"/>
        <SolidColorBrush x:Key="TextMuted" Color="#606070"/>
        <SolidColorBrush x:Key="Green" Color="#4EC9B0"/>
        <SolidColorBrush x:Key="Red" Color="#FF4D4D"/>
        <SolidColorBrush x:Key="Yellow" Color="#FFD700"/>
        <SolidColorBrush x:Key="Border" Color="#2A2A35"/>
        <SolidColorBrush x:Key="AccentPressed" Color="#0088CC"/>
        <SolidColorBrush x:Key="TextOnAccent" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="Magenta" Color="#C586C0"/>
        <SolidColorBrush x:Key="InputBg" Color="#0B0B0E"/>
        <SolidColorBrush x:Key="PopupBg" Color="#15151E"/>
        <SolidColorBrush x:Key="PopupItemHover" Color="#1E1E2B"/>
        <SolidColorBrush x:Key="PopupItemSelected" Color="#16283A"/>
        <SolidColorBrush x:Key="PopupArrow" Color="#8A8A9A"/>
        <SolidColorBrush x:Key="ScrollThumb" Color="#3A3A4A"/>
        <SolidColorBrush x:Key="ScrollThumbHover" Color="#5A5A70"/>
        <SolidColorBrush x:Key="CardHoverDanger" Color="#2A1515"/>
        <SolidColorBrush x:Key="HintBg" Color="#101018"/>
        <SolidColorBrush x:Key="ButtonBg" Color="#24242F"/>
        <SolidColorBrush x:Key="ButtonHoverBg" Color="#2E2E3C"/>
        <SolidColorBrush x:Key="ButtonPressedBg" Color="#1B1B25"/>
        <SolidColorBrush x:Key="ButtonBorder" Color="#33333F"/>
        <SolidColorBrush x:Key="SmallButtonBg" Color="#1B1B26"/>
        <SolidColorBrush x:Key="SmallButtonText" Color="#D8D8E4"/>
        <SolidColorBrush x:Key="StatusReadyBg" Color="#152A22"/>
        <SolidColorBrush x:Key="StatusReadyBorder" Color="#2D4B3A"/>
        <SolidColorBrush x:Key="StatusBusyBg" Color="#15202A"/>
        <SolidColorBrush x:Key="StatusBusyBorder" Color="#2D3F4B"/>
        <SolidColorBrush x:Key="StatusFailedBg" Color="#2A1515"/>
        <SolidColorBrush x:Key="StatusFailedBorder" Color="#4B2D2D"/>
        <SolidColorBrush x:Key="StatusCancelledBg" Color="#2A2615"/>
        <SolidColorBrush x:Key="StatusCancelledBorder" Color="#4B452D"/>

        <!-- ToolTip Style -->
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="{DynamicResource PopupBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <!-- Sidebar Button Style -->
        <Style x:Key="NavButton" TargetType="RadioButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="Padding" Value="15,12"/>
            <Setter Property="Margin" Value="10,2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource BgCardHover}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource BgCard}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="3,0,0,0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Action Button Style (shared look; the hover lift lives in ActionButton) -->
        <Style x:Key="ActionButtonBase" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource BgCard}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="Margin" Value="5,0,5,10"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <!-- Hover motion is a small vertical shift, not a scale: scaling made the
                 card grow past its own bounds (over the scrollbar and the page edge). -->
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <TranslateTransform X="0" Y="0"/>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{DynamicResource BgCardHover}"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Hover lift in its own style so "reduce motion" can swap it off at runtime. -->
        <Style x:Key="ActionButton" TargetType="Button" BasedOn="{StaticResource ActionButtonBase}">
            <Style.Triggers>
                <EventTrigger RoutedEvent="MouseEnter">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="-2" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
                <EventTrigger RoutedEvent="MouseLeave">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="0" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
            </Style.Triggers>
        </Style>

        <!-- Same card, no motion: used when "reduce motion" is on. -->
        <Style x:Key="ActionButtonMotionless" TargetType="Button" BasedOn="{StaticResource ActionButtonBase}"/>

        <!-- Play card: green accent at rest, and the whole card fills green on hover. -->
        <ControlTemplate x:Key="PlayButtonTemplate" TargetType="Button">
            <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="border" Property="Background" Value="{DynamicResource Green}"/>
                    <Setter TargetName="border" Property="BorderBrush" Value="{DynamicResource Green}"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                    <Setter Property="Cursor" Value="Arrow"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <Style x:Key="PlayButtonBase" TargetType="Button" BasedOn="{StaticResource ActionButtonBase}">
            <Setter Property="Template" Value="{StaticResource PlayButtonTemplate}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Green}"/>
        </Style>

        <Style x:Key="PlayButton" TargetType="Button" BasedOn="{StaticResource PlayButtonBase}">
            <Style.Triggers>
                <EventTrigger RoutedEvent="MouseEnter">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="-2" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
                <EventTrigger RoutedEvent="MouseLeave">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="0" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="PlayButtonMotionless" TargetType="Button" BasedOn="{StaticResource PlayButtonBase}"/>

        <!-- Play card content: green at rest, dark on the green fill so it stays readable. -->
        <Style x:Key="PlayIcon" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="26"/>
            <Setter Property="Foreground" Value="{DynamicResource Green}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0,0,20,0"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=Button}, Path=IsMouseOver}" Value="True">
                    <Setter Property="Foreground" Value="#06140F"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="PlayTitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="19"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{DynamicResource Green}"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=Button}, Path=IsMouseOver}" Value="True">
                    <Setter Property="Foreground" Value="#06140F"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="PlaySubtitle" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="Margin" Value="0,5,0,0"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=Button}, Path=IsMouseOver}" Value="True">
                    <Setter Property="Foreground" Value="#0B2A20"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <!-- Danger Action Button Style -->
        <ControlTemplate x:Key="DangerButtonTemplate" TargetType="Button">
            <Border x:Name="border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="border" Property="Background" Value="{DynamicResource CardHoverDanger}"/>
                    <Setter TargetName="border" Property="BorderBrush" Value="{DynamicResource Red}"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                    <Setter Property="Cursor" Value="Arrow"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <Style x:Key="DangerButtonBase" TargetType="Button" BasedOn="{StaticResource ActionButtonBase}">
            <Setter Property="Template" Value="{StaticResource DangerButtonTemplate}"/>
        </Style>

        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource DangerButtonBase}">
            <Style.Triggers>
                <EventTrigger RoutedEvent="MouseEnter">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="-2" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
                <EventTrigger RoutedEvent="MouseLeave">
                    <BeginStoryboard>
                        <Storyboard>
                            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.Y)" To="0" Duration="0:0:0.1"/>
                        </Storyboard>
                    </BeginStoryboard>
                </EventTrigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DangerButtonMotionless" TargetType="Button" BasedOn="{StaticResource DangerButtonBase}"/>

        <!-- Card Style -->
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource BgCard}"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="Margin" Value="5,0,5,14"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
        </Style>

        <!-- Card Icon Style -->
        <Style x:Key="CardIcon" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="24"/>
            <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
            <Setter Property="Margin" Value="0,0,0,15"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=Button}, Path=IsMouseOver}" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource AccentHover}"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <!-- Icon used at the left of a full-width action button -->
        <Style x:Key="ActionIcon" TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="26"/>
            <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0,0,20,0"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding RelativeSource={RelativeSource AncestorType=Button}, Path=IsMouseOver}" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource AccentHover}"/>
                </DataTrigger>
            </Style.Triggers>
        </Style>

        <!-- Spinner Animation -->
        <Storyboard x:Key="SpinStoryboard" RepeatBehavior="Forever">
            <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="0" To="360" Duration="0:0:1"/>
        </Storyboard>

        <!-- Flat text button used for the log toolbar (Copy / Clear) -->
        <Style x:Key="LogLinkButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="{DynamicResource TextMuted}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="Transparent" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ============================== -->
        <!-- DARK THEME SCROLLBAR           -->
        <!-- ============================== -->
        <Style x:Key="DarkScrollThumb" TargetType="Thumb">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border x:Name="grip" Background="{DynamicResource ScrollThumb}" CornerRadius="3" Margin="3"/>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="grip" Property="Background" Value="{DynamicResource ScrollThumbHover}"/>
                            </Trigger>
                            <Trigger Property="IsDragging" Value="True">
                                <Setter TargetName="grip" Property="Background" Value="{DynamicResource Accent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkScrollBar" TargetType="ScrollBar">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="12"/>
            <Setter Property="MinWidth" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="{TemplateBinding Background}" SnapsToDevicePixels="True">
                            <Track x:Name="PART_Track" Focusable="False" IsDirectionReversed="True"
                                   Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
                                   Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton x:Name="DecreaseButton" Command="ScrollBar.PageUpCommand" Focusable="False" IsTabStop="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource DarkScrollThumb}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton x:Name="IncreaseButton" Command="ScrollBar.PageDownCommand" Focusable="False" IsTabStop="False">
                                        <RepeatButton.Template>
                                            <ControlTemplate TargetType="RepeatButton">
                                                <Border Background="Transparent"/>
                                            </ControlTemplate>
                                        </RepeatButton.Template>
                                    </RepeatButton>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter Property="Width" Value="Auto"/>
                                <Setter Property="MinWidth" Value="0"/>
                                <Setter Property="Height" Value="12"/>
                                <Setter Property="MinHeight" Value="12"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                                <Setter TargetName="DecreaseButton" Property="Command" Value="{x:Static ScrollBar.PageLeftCommand}"/>
                                <Setter TargetName="IncreaseButton" Property="Command" Value="{x:Static ScrollBar.PageRightCommand}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Implicit: every scrollbar in the window (log, pages, popups) follows the dark theme -->
        <Style TargetType="ScrollBar" BasedOn="{StaticResource DarkScrollBar}"/>

        <!-- ============================== -->
        <!-- DARK THEME DROPDOWN (ComboBox) -->
        <!-- ============================== -->
        <Style x:Key="DarkComboBoxItem" TargetType="ComboBoxItem">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Padding" Value="12,9"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="itemBorder" Background="{TemplateBinding Background}" CornerRadius="4"
                                Padding="{TemplateBinding Padding}" Margin="2,1">
                            <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="{DynamicResource PopupItemHover}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="itemBorder" Property="Background" Value="{DynamicResource PopupItemSelected}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkComboBox" TargetType="ComboBox">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="MaxDropDownHeight" Value="320"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid x:Name="root" SnapsToDevicePixels="True">
                            <Border x:Name="frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"/>

                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="38"/>
                                </Grid.ColumnDefinitions>

                                <!-- Clicking anywhere opens the list, like a normal dropdown -->
                                <ToggleButton x:Name="ToggleButton" Grid.ColumnSpan="2" Focusable="False" ClickMode="Press"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                    <ToggleButton.Template>
                                        <ControlTemplate TargetType="ToggleButton">
                                            <Grid Background="Transparent">
                                                <TextBlock x:Name="arrow" Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10"
                                                           Foreground="{DynamicResource PopupArrow}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0"/>
                                            </Grid>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="arrow" Property="Foreground" Value="{DynamicResource AccentHover}"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </ToggleButton.Template>
                                </ToggleButton>

                                <ContentPresenter x:Name="SelectionBox" Grid.Column="0" Margin="{TemplateBinding Padding}" IsHitTestVisible="False"
                                                  HorizontalAlignment="Left" VerticalAlignment="Center"
                                                  Content="{TemplateBinding SelectionBoxItem}"
                                                  ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                                  ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                                  ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>

                                <TextBox x:Name="PART_EditableTextBox" Grid.Column="0" Margin="{TemplateBinding Padding}" Padding="0"
                                         Background="Transparent" BorderThickness="0" Foreground="{TemplateBinding Foreground}"
                                         CaretBrush="{TemplateBinding Foreground}" VerticalAlignment="Center"
                                         HorizontalAlignment="Stretch" Visibility="Hidden"/>
                            </Grid>

                            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                                   PopupAnimation="Slide" IsOpen="{TemplateBinding IsDropDownOpen}">
                                <Border x:Name="dropDown" Background="{DynamicResource PopupBg}" BorderBrush="{DynamicResource Border}" BorderThickness="1"
                                        CornerRadius="6" Margin="0,4,0,0" Padding="2"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                                        MaxHeight="{Binding MaxDropDownHeight, RelativeSource={RelativeSource TemplatedParent}}">
                                    <Border.Resources>
                                        <Style TargetType="ScrollBar" BasedOn="{StaticResource DarkScrollBar}"/>
                                    </Border.Resources>
                                    <ScrollViewer SnapsToDevicePixels="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsDropDownOpen" Value="True">
                                <Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsEditable" Value="True">
                                <Setter TargetName="SelectionBox" Property="Visibility" Value="Hidden"/>
                                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="root" Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ============================== -->
        <!-- DIALOG BUTTONS (prompt window)  -->
        <!-- ============================== -->
        <Style x:Key="DialogPrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource Accent}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextOnAccent}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="18,7"/>
            <Setter Property="MinWidth" Value="96"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="{DynamicResource AccentHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="{DynamicResource AccentPressed}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Small pill button used for inline actions (Change folder, etc.) -->
        <Style x:Key="SmallButton" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource SmallButtonBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource SmallButtonText}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}" CornerRadius="5"
                                BorderBrush="{DynamicResource Border}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="btnBorder" Property="Opacity" Value="0.4"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Shared intro line at the top of every page -->
        <Style x:Key="PageIntro" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="Margin" Value="5,0,5,12"/>
        </Style>

        <!-- Shared explanatory card at the bottom of a page -->
        <Style x:Key="HintCard" TargetType="Border" BasedOn="{StaticResource Card}">
            <Setter Property="Background" Value="{DynamicResource HintBg}"/>
            <Setter Property="Padding" Value="14,12"/>
            <Setter Property="Margin" Value="5,0,5,6"/>
        </Style>

        <Style x:Key="HintText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="Foreground" Value="{DynamicResource TextMuted}"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="LineHeight" Value="18"/>
        </Style>

        <Style x:Key="DialogSecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource ButtonBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource SmallButtonText}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="18,7"/>
            <Setter Property="MinWidth" Value="96"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}" CornerRadius="5"
                                BorderBrush="{DynamicResource ButtonBorder}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="{DynamicResource ButtonHoverBg}"/>
                                <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="{DynamicResource ButtonPressedBg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Accent preset dot shown in the header -->
        <Style x:Key="AccentDot" TargetType="RadioButton">
            <Setter Property="Width" Value="18"/>
            <Setter Property="Height" Value="18"/>
            <Setter Property="Margin" Value="0,0,4,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Grid Background="Transparent">
                            <Ellipse x:Name="ring" Width="17" Height="17" Stroke="Transparent" StrokeThickness="1.5"/>
                            <Ellipse x:Name="dot" Width="10" Height="10" Fill="{TemplateBinding Background}"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ring" Property="Stroke" Value="{DynamicResource TextMuted}"/>
                                <Setter TargetName="dot" Property="Width" Value="12"/>
                                <Setter TargetName="dot" Property="Height" Value="12"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ring" Property="Stroke" Value="{DynamicResource TextPrimary}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Compact pill used for the activity-log filters and toggles -->
        <ControlTemplate x:Key="ChipTemplate" TargetType="ToggleButton">
            <Border x:Name="chip" Background="Transparent" BorderBrush="{DynamicResource Border}" BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter TargetName="chip" Property="Background" Value="{DynamicResource BgCardHover}"/>
                    <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="chip" Property="Background" Value="{DynamicResource Accent}"/>
                    <Setter TargetName="chip" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                    <Setter Property="Foreground" Value="{DynamicResource TextOnAccent}"/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <Style x:Key="FilterChip" TargetType="RadioButton">
            <Setter Property="Template" Value="{StaticResource ChipTemplate}"/>
            <Setter Property="Padding" Value="9,3"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,5,0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        </Style>

        <Style x:Key="FilterToggle" TargetType="ToggleButton">
            <Setter Property="Template" Value="{StaticResource ChipTemplate}"/>
            <Setter Property="Padding" Value="9,3"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{DynamicResource TextSecondary}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="0,0,5,0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
        </Style>

        <!-- Prompt dialog option list (no popup, so it cannot glitch) -->
        <Style x:Key="DialogOptionItem" TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="Margin" Value="0,1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13.5"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="row" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="row" Property="Background" Value="{DynamicResource PopupItemHover}"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="row" Property="Background" Value="{DynamicResource PopupItemSelected}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DialogOptionList" TargetType="ListBox">
            <Setter Property="Background" Value="{DynamicResource InputBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Border}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource DialogOptionItem}"/>
            <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="3">
                            <ScrollViewer Focusable="False" VerticalScrollBarVisibility="Auto">
                                <ItemsPresenter/>
                            </ScrollViewer>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="280"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        
        <!-- Sidebar -->
        <Border Grid.Column="0" Background="{DynamicResource BgSidebar}" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,1,0">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="120"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="60"/>
                </Grid.RowDefinitions>
                
                <!-- Logo Area -->
                <Grid Grid.Row="0" Margin="25,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Width="3" CornerRadius="2" Background="{DynamicResource Accent}" Margin="0,8,14,12"/>
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="Call of Duty MW4" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                        <TextBlock Text="Setup Utility" FontSize="13" Foreground="{DynamicResource Accent}" FontWeight="SemiBold" Margin="0,2,0,0"/>
                        <TextBlock Text="made for luatools &lt;3 &#183; by Lark" FontSize="11" Foreground="{DynamicResource TextMuted}" Margin="0,9,0,0"/>
                    </StackPanel>
                </Grid>

                <!-- Navigation -->
                <StackPanel Grid.Row="1" Margin="0,10,0,0">
                    <TextBlock Text="NAVIGATION" FontSize="11" Foreground="{DynamicResource TextMuted}" Margin="25,0,0,10" FontWeight="Bold"/>
                    
                    <RadioButton x:Name="NavOverview" Style="{StaticResource NavButton}" IsChecked="True" ToolTip="View game status and quick actions">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,15,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Overview" FontSize="14" VerticalAlignment="Center"/>
                        </StackPanel>
                    </RadioButton>

                    <RadioButton x:Name="NavFixes" Style="{StaticResource NavButton}" ToolTip="Manage game fixes and restores">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,15,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Fix Installer" FontSize="14" VerticalAlignment="Center"/>
                        </StackPanel>
                    </RadioButton>

                    <RadioButton x:Name="NavLanguages" Style="{StaticResource NavButton}" ToolTip="Install and switch language packs">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE8D2;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,15,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Languages" FontSize="14" VerticalAlignment="Center"/>
                        </StackPanel>
                    </RadioButton>

                    <RadioButton x:Name="NavDowngrade" Style="{StaticResource NavButton}" ToolTip="Fix 'Invalid game version' errors">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,15,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Downgrade Version" FontSize="14" VerticalAlignment="Center"/>
                        </StackPanel>
                    </RadioButton>

                    <RadioButton x:Name="NavGames" Style="{StaticResource NavButton}" ToolTip="The older Call of Duty games and their community clients">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,15,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Games" FontSize="14" VerticalAlignment="Center"/>
                        </StackPanel>
                    </RadioButton>
                </StackPanel>
                
                <StackPanel Grid.Row="2" VerticalAlignment="Center" Margin="25,0">
                    <Border Height="1" Background="{DynamicResource Border}" Margin="0,0,0,11"/>
                    <Grid>
                        <TextBlock x:Name="VersionText" Text="v1.0.0" FontSize="11" Foreground="{DynamicResource TextMuted}" VerticalAlignment="Center"/>
                        <TextBlock Text="Runs locally" FontSize="11" Foreground="{DynamicResource TextMuted}" Opacity="0.65" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                    </Grid>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Main Content -->
        <Grid Grid.Column="1" Background="{DynamicResource BgDark}">
            <Grid.RowDefinitions>
                <RowDefinition Height="80"/>
                <RowDefinition Height="*" MinHeight="220"/>
                <!-- Grab bar: the activity log can be dragged taller, which matters
                     most during a long downgrade. -->
                <RowDefinition Height="5"/>
                <RowDefinition Height="216" MinHeight="90"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <Border Grid.Row="0" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,1" Background="{DynamicResource BgDark}">
                <Grid Margin="40,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*" MinWidth="140"/>
                        <ColumnDefinition Width="Auto" MaxWidth="660"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="HeaderTitle" Grid.Column="0" Text="Overview" FontSize="28" FontWeight="Light" VerticalAlignment="Center" Foreground="{DynamicResource TextPrimary}" TextTrimming="CharacterEllipsis" Margin="0,0,24,0"/>
                    
                    <!-- Accent presets, motion and theme controls + status pill -->
                    <StackPanel Grid.Column="1" HorizontalAlignment="Right" Orientation="Horizontal" VerticalAlignment="Center">
                        <!-- Presets sit in one pill so they read as a single control -->
                        <Border Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource Border}" BorderThickness="1"
                                CornerRadius="15" Padding="9,5" Margin="0,0,10,0" VerticalAlignment="Center"
                                ToolTip="Accent colour: click a dot to recolour the whole utility">
                            <StackPanel x:Name="AccentDots" Orientation="Horizontal" VerticalAlignment="Center">
                                <RadioButton x:Name="AccentSteam" Style="{StaticResource AccentDot}" GroupName="AccentChoice" Background="#00A8FF" IsChecked="True" ToolTip="Accent colour: Steam blue"/>
                                <RadioButton x:Name="AccentTeal" Style="{StaticResource AccentDot}" GroupName="AccentChoice" Background="#12B5A0" ToolTip="Accent colour: Teal"/>
                                <RadioButton x:Name="AccentViolet" Style="{StaticResource AccentDot}" GroupName="AccentChoice" Background="#8B7BFF" ToolTip="Accent colour: Violet"/>
                                <RadioButton x:Name="AccentAmber" Style="{StaticResource AccentDot}" GroupName="AccentChoice" Background="#F2A03D" ToolTip="Accent colour: Amber"/>
                                <RadioButton x:Name="AccentCrimson" Style="{StaticResource AccentDot}" GroupName="AccentChoice" Background="#F2586C" ToolTip="Accent colour: Crimson"/>
                            </StackPanel>
                        </Border>
                        <Button x:Name="BtnMotionToggle" Style="{StaticResource SmallButton}" Width="34" Height="30" Padding="0" Margin="0,0,8,0"
                                VerticalAlignment="Center" ToolTip="Reduce motion: on">
                            <TextBlock x:Name="MotionToggleIcon" Text="&#xE769;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                        </Button>
                        <Button x:Name="BtnThemeToggle" Style="{StaticResource SmallButton}" Width="34" Height="30" Padding="0" Margin="0,0,10,0"
                                VerticalAlignment="Center" ToolTip="Switch to the light theme">
                            <TextBlock x:Name="ThemeToggleIcon" Text="&#xE706;" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" HorizontalAlignment="Center"/>
                        </Button>
                        <Border x:Name="StatusPill" Background="{DynamicResource StatusReadyBg}" CornerRadius="15" Padding="15,6" BorderBrush="{DynamicResource StatusReadyBorder}" BorderThickness="1">
                            <Grid>
                                <!-- Ready Panel -->
                                <StackPanel x:Name="ReadyPanel" Orientation="Horizontal">
                                    <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="{DynamicResource Green}" VerticalAlignment="Center" Margin="0,0,8,0">
                                        <Ellipse.Triggers>
                                            <EventTrigger RoutedEvent="Loaded">
                                                <BeginStoryboard>
                                                    <Storyboard RepeatBehavior="Forever">
                                                        <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1.0" To="0.3" Duration="0:0:1" AutoReverse="True"/>
                                                    </Storyboard>
                                                </BeginStoryboard>
                                            </EventTrigger>
                                        </Ellipse.Triggers>
                                    </Ellipse>
                                    <TextBlock x:Name="StatusText" Text="Ready" FontSize="12" Foreground="{DynamicResource Green}" FontWeight="Bold" MaxWidth="580" TextWrapping="Wrap"/>
                                </StackPanel>
                                
                                <!-- Busy Panel -->
                                <StackPanel x:Name="BusyPanel" Orientation="Horizontal" Visibility="Collapsed">
                                    <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource Accent}" VerticalAlignment="Center" Margin="0,0,8,0" RenderTransformOrigin="0.5,0.5">
                                        <TextBlock.RenderTransform>
                                            <RotateTransform Angle="0"/>
                                        </TextBlock.RenderTransform>
                                        <TextBlock.Triggers>
                                            <EventTrigger RoutedEvent="Loaded">
                                                <BeginStoryboard Storyboard="{StaticResource SpinStoryboard}"/>
                                            </EventTrigger>
                                        </TextBlock.Triggers>
                                    </TextBlock>
                                    <TextBlock x:Name="BusyText" Text="Processing..." FontSize="12" Foreground="{DynamicResource Accent}" FontWeight="Bold" MaxWidth="580" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Pages -->
            <Grid Grid.Row="1" Margin="35,14,35,10">
                
                <!-- PAGE 1: OVERVIEW -->
                <ScrollViewer x:Name="PageOverview" Visibility="Visible" VerticalScrollBarVisibility="Auto" Padding="0" PanningMode="VerticalOnly">
                    <StackPanel>
                        <TextBlock Style="{StaticResource PageIntro}" Text="Check your game folder, then jump straight into the common actions."/>
                        
                        <Border Style="{StaticResource Card}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="GameCardIcon" Grid.Column="0" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="{DynamicResource Green}" VerticalAlignment="Center" Margin="0,0,20,0"/>
                                <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                    <TextBlock x:Name="GameCardTitle" Text="Checking for the game..." FontSize="18" FontWeight="Bold" Foreground="{DynamicResource TextPrimary}"/>
                                    <TextBlock x:Name="GamePathText" Text="Scanning Steam libraries..." FontSize="14" Foreground="{DynamicResource TextSecondary}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                                <Button x:Name="BtnChooseFolder" Grid.Column="2" Content="Change folder" Style="{StaticResource SmallButton}"
                                        VerticalAlignment="Center" Margin="20,0,0,0"
                                        ToolTip="Pick the Call of Duty HQ folder yourself; it is remembered for later sessions"/>
                            </Grid>
                        </Border>

                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="20"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <Button x:Name="BtnQuickFix" Grid.Column="0" Style="{StaticResource ActionButton}" ToolTip="Downloads the latest fix and replaces matching files">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#xE896;" Style="{StaticResource ActionIcon}"/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Install Fix" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Install or restore game files" FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </StackPanel>
                            </Button>

                            <Button x:Name="BtnQuickLang" Grid.Column="2" Style="{StaticResource ActionButton}" ToolTip="Install new languages or switch active preset">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#xE8D2;" Style="{StaticResource ActionIcon}"/>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Languages" FontSize="18" FontWeight="Bold"/>
                                        <TextBlock Text="Install and switch language" FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                    </StackPanel>
                                </StackPanel>
                            </Button>
                        </Grid>

                        <Button x:Name="BtnLaunchBat" Style="{StaticResource PlayButton}" ToolTip="Launches !start_sp26.bat from your game folder">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE768;" Style="{StaticResource PlayIcon}"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Play" Style="{StaticResource PlayTitle}"/>
                                    <TextBlock Text="Launches !start_sp26.bat from your game folder." Style="{StaticResource PlaySubtitle}"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>

                        <Border Style="{StaticResource HintCard}">
                            <TextBlock Style="{StaticResource HintText}" Text="Downloads are staged in your temp folder and cleaned up afterwards. Nothing is overwritten until working files have been copied into a timestamped 'og files' backup."/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- PAGE 2: FIXES -->
                <ScrollViewer x:Name="PageFixes" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="0" PanningMode="VerticalOnly">
                    <StackPanel>
                        <TextBlock Style="{StaticResource PageIntro}" Text="Install the fix, or roll it back from the backups kept in your game folder."/>
                        <Button x:Name="BtnInstallFix" Style="{StaticResource ActionButton}" ToolTip="Applies the fix and creates a backup of originals">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE896;" Style="{StaticResource ActionIcon}"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Install Fix / Restore Originals" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Downloads the latest fix and applies it to your game folder. Existing files are backed up first." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Button x:Name="BtnRemoveFix" Style="{StaticResource DangerButton}" ToolTip="Restores game files from the backup folder">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="{DynamicResource Red}" VerticalAlignment="Center" Margin="0,0,20,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Remove Fix" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Restores the original files from the oldest backup in 'og files', then deletes 'og files'." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Border Style="{StaticResource HintCard}">
                            <TextBlock Style="{StaticResource HintText}" Text="Replaced files are copied into a timestamped folder named 'og files' inside the game directory. Older backups are never deleted, so you can always go back further."/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- PAGE 3: LANGUAGES -->
                <ScrollViewer x:Name="PageLanguages" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="0" PanningMode="VerticalOnly">
                    <StackPanel>
                        <TextBlock Style="{StaticResource PageIntro}" Text="Add another language, or switch the one the game uses."/>
                        <Button x:Name="BtnInstallLang" Style="{StaticResource ActionButton}" ToolTip="Choose from supported languages and download">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE8D2;" Style="{StaticResource ActionIcon}"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Install Language Pack" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Download a supported language and add it to your game." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Button x:Name="BtnActiveLang" Style="{StaticResource ActionButton}" ToolTip="Switch between already installed language packs">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE8AB;" Style="{StaticResource ActionIcon}"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Active Language Preset" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Switch between English and any language packs you have installed." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Button x:Name="BtnRemoveLang" Style="{StaticResource DangerButton}" ToolTip="Safely uninstall a language pack">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="{DynamicResource Red}" VerticalAlignment="Center" Margin="0,0,20,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Remove Language Pack" FontSize="18" FontWeight="Bold"/>
                                    <TextBlock Text="Uninstall a pack safely; files shared with other packs are kept." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Border Style="{StaticResource HintCard}">
                            <TextBlock Style="{StaticResource HintText}" Text="You can keep several packs installed at once. Identical shared files are only restored after the last pack that uses them is removed."/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <!-- PAGE 4: DOWNGRADE -->
                <ScrollViewer x:Name="PageDowngrade" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="0" PanningMode="VerticalOnly">
                    <StackPanel>
                        <TextBlock Style="{StaticResource PageIntro}" Text="Use these when the game reports 'Invalid game version'."/>

                        <!-- Shown by the elevated worker instance, so a downgrade that runs
                             after the UAC relaunch is visibly running instead of invisible. -->
                        <Border x:Name="DowngradeRunBanner" Visibility="Collapsed" CornerRadius="10" Padding="18,15" Margin="0,0,0,18"
                                Background="{DynamicResource StatusBusyBg}" BorderBrush="{DynamicResource StatusBusyBorder}" BorderThickness="1">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="20"
                                           Foreground="{DynamicResource Accent}" VerticalAlignment="Top" Margin="0,2,16,0"/>
                                <StackPanel Grid.Column="1">
                                    <TextBlock x:Name="DowngradeRunTitle" Text="Downgrade running" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource Accent}"/>
                                    <TextBlock x:Name="DowngradeRunDetail" FontSize="12.5" Foreground="{DynamicResource TextSecondary}" TextWrapping="Wrap" Margin="0,5,0,0"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Button x:Name="BtnDowngradeNormal" Style="{StaticResource ActionButton}" ToolTip="Safely injects Lua locks and forces validation">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="{DynamicResource Green}" VerticalAlignment="Center" Margin="0,0,20,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Normal Downgrade (Recommended)" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource Green}"/>
                                    <TextBlock Text="Injects the Lua lock and downgrade manifests, then asks Steam to validate your files." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>

                        <Button x:Name="BtnDowngradeNuclear" Style="{StaticResource DangerButton}" ToolTip="Wipes Steam files and reinstalls BetterSteamTools">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="{DynamicResource Red}" VerticalAlignment="Center" Margin="0,0,20,0"/>
                                <StackPanel VerticalAlignment="Center">
                                    <TextBlock Text="Nuclear Downgrade (Advanced)" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource Red}"/>
                                    <TextBlock Text="Cleans the Steam folder, reinstalls BetterSteamTools, then forces validation. Use it only if Normal fails." FontSize="13" Foreground="{DynamicResource TextSecondary}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </StackPanel>
                        </Button>
                        <Border Style="{StaticResource HintCard}">
                            <TextBlock Style="{StaticResource HintText}" Text="Both options close and restart Steam, and need administrator rights (accept the UAC prompt if it appears). Try Normal first."/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

                <ScrollViewer x:Name="PageGames" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="0" PanningMode="VerticalOnly">
                    <StackPanel>
                        <TextBlock Style="{StaticResource PageIntro}" Text="The older Call of Duty games you own on Steam, with their community clients. Clients are checked file by file; your own game files are never replaced by downloaded copies."/>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0" Text="Player name" FontSize="13" Foreground="{DynamicResource TextSecondary}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                <TextBox x:Name="PlayerNameBox" Grid.Column="1" MaxLength="16" FontSize="13" Padding="8,5" VerticalContentAlignment="Center"
                                         Background="{DynamicResource InputBg}" Foreground="{DynamicResource TextPrimary}" BorderBrush="{DynamicResource Border}" CaretBrush="{DynamicResource TextPrimary}"
                                         ToolTip="Passed to the clients that take a name (16 characters at most)"/>
                                <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="12,0,0,0">
                                    <Button x:Name="BtnSavePlayerName" Style="{StaticResource SmallButton}" Content="Save name" Margin="0,0,8,0"/>
                                    <Button x:Name="BtnGamesRefresh" Style="{StaticResource SmallButton}" Content="Refresh" Margin="0,0,8,0" ToolTip="Look for the games again"/>
                                    <Button x:Name="BtnGamesCheckUpdates" Style="{StaticResource SmallButton}" Content="Check all for updates" Margin="0,0,8,0" ToolTip="Ask each installed client's source whether files changed, and whether a newer version of this utility is out"/>
                                    <Button x:Name="BtnGamesAutoUpdate" Style="{StaticResource SmallButton}" Content="Auto-update: off" ToolTip="When on, installed clients are checked and updated when this page opens and before Play"/>
                                </StackPanel>
                            </Grid>
                        </Border>
                        <StackPanel x:Name="GamesList"/>
                        <Border Style="{StaticResource HintCard}">
                            <TextBlock Style="{StaticResource HintText}" Text="Plutonium games need a free Plutonium account (use Plutonium login once). Black Ops 4 and HorizonMW are set up with their official launchers. The research behind this page is in docs/cb-launcher."/>
                        </Border>
                    </StackPanel>
                </ScrollViewer>

            </Grid>

            <GridSplitter Grid.Row="2" Height="5" HorizontalAlignment="Stretch" VerticalAlignment="Center"
                          Background="{DynamicResource Border}" ResizeBehavior="PreviousAndNext" ResizeDirection="Rows"
                          Cursor="SizeNS" ToolTip="Drag to resize the activity log"/>

            <!-- Activity Log & Progress Bar -->
            <Border Grid.Row="3" Background="{DynamicResource BgCardHover}" BorderBrush="{DynamicResource Border}" BorderThickness="0,1,0,0">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="40"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Background="{DynamicResource BgSidebar}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="40,0,16,0">
                            <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource TextMuted}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <TextBlock Text="ACTIVITY LOG" FontSize="11" Foreground="{DynamicResource TextMuted}" FontWeight="Bold" VerticalAlignment="Center"/>
                        </StackPanel>

                        <!-- Native Progress Bar -->
                        <ProgressBar x:Name="MainProgressBar" Grid.Column="1" Height="6" Margin="0,0,16,0" VerticalAlignment="Center" Visibility="Collapsed" BorderThickness="0" Background="{DynamicResource BgCard}" Foreground="{DynamicResource Accent}"/>

                        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,20,0">
                            <RadioButton x:Name="LogFilterAll" Content="All" Style="{StaticResource FilterChip}" GroupName="LogFilterChoice" IsChecked="True" ToolTip="Show every log line"/>
                            <RadioButton x:Name="LogFilterWarn" Content="Warnings" Style="{StaticResource FilterChip}" GroupName="LogFilterChoice" ToolTip="Show warnings and errors only"/>
                            <RadioButton x:Name="LogFilterError" Content="Errors" Style="{StaticResource FilterChip}" GroupName="LogFilterChoice" ToolTip="Show errors only"/>
                            <ToggleButton x:Name="BtnAutoScroll" Content="Auto-scroll" Style="{StaticResource FilterToggle}" IsChecked="True" Margin="8,0,0,0" ToolTip="Keep the log scrolled to the newest line"/>
                            <Border Width="1" Height="16" Background="{DynamicResource Border}" Margin="10,0,10,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnSaveLog" Content="Save" Style="{StaticResource LogLinkButton}" Margin="0,0,12,0" ToolTip="Save the activity log to a text file"/>
                            <Button x:Name="BtnCopyLog" Content="Copy" Style="{StaticResource LogLinkButton}" Margin="0,0,12,0" ToolTip="Copy the activity log to the clipboard"/>
                            <Button x:Name="BtnClearLog" Content="Clear" Style="{StaticResource LogLinkButton}" ToolTip="Clear the activity log"/>
                        </StackPanel>
                    </Grid>
                    <RichTextBox x:Name="OutputBox" Grid.Row="1" Background="Transparent" Foreground="{DynamicResource TextSecondary}" 
                                 FontFamily="Consolas" FontSize="12.5" BorderThickness="0" 
                                 IsReadOnly="True" VerticalScrollBarVisibility="Auto" Padding="40,12,20,12"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

# ==========================================
# GUI OVERRIDES & LOGIC
# ==========================================
$global:OutputBox = $null
$global:StatusText = $null
$global:ProgressBar = $null
$global:StatusDot = $null
$global:StatusPill = $null
$global:BusyText = $null
$global:MainWindow = $null
$global:AvailableOptions = @()

# Renders an ErrorRecord exactly like a real PowerShell console does
# (message, "At <file>:<line> char:<n>", the offending source line, the caret
# underline, CategoryInfo and FullyQualifiedErrorId), then appends the details a
# console hides: the exception type chain and the PowerShell call stack.
function Format-ErrorRecord {
    param([Parameter(Mandatory = $true)] $ErrorRecord)

    if ($null -eq $ErrorRecord) { return '' }
    if ($ErrorRecord -isnot [System.Management.Automation.ErrorRecord]) { return [string]$ErrorRecord }

    $sb = [System.Text.StringBuilder]::new()
    $exception = $ErrorRecord.Exception
    $message = if ($exception) { $exception.Message } else { [string]$ErrorRecord }
    [void]$sb.AppendLine($message)

    $invocation = $ErrorRecord.InvocationInfo
    if ($invocation -and $invocation.PositionMessage) { [void]$sb.AppendLine($invocation.PositionMessage.TrimEnd()) }

    [void]$sb.AppendLine(('    + CategoryInfo          : {0}' -f $ErrorRecord.CategoryInfo))
    [void]$sb.AppendLine(('    + FullyQualifiedErrorId : {0}' -f $ErrorRecord.FullyQualifiedErrorId))

    $level = 0
    $current = $exception
    while ($null -ne $current) {
        $label = if ($level -eq 0) { 'Exception' } else { 'InnerException ' + $level }
        [void]$sb.AppendLine(('    + {0}: {1}' -f $label.PadRight(20), $current.GetType().FullName))
        if ($level -gt 0) { [void]$sb.AppendLine(('      {0}' -f $current.Message)) }
        $current = $current.InnerException
        $level++
    }

    if ($ErrorRecord.ScriptStackTrace) {
        [void]$sb.AppendLine('    + ScriptStackTrace    :')
        foreach ($frame in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) { [void]$sb.AppendLine("        $frame") }
    } elseif ($exception -and $exception.StackTrace) {
        [void]$sb.AppendLine('    + StackTrace          :')
        foreach ($frame in ($exception.StackTrace -split "`r?`n")) { [void]$sb.AppendLine("        $($frame.Trim())") }
    }

    return $sb.ToString().TrimEnd()
}

# Severity comes from the colour the caller already passes (Red = error,
# Yellow = warning, Green = success), so every existing call site keeps working
# and the filters have something to filter on without touching the log text.
function Get-LogSeverity {
    param([string]$Color, [string]$Text)
    $severity = 'info'
    $key = if ($Color) { $Color.ToUpperInvariant() } else { '' }
    if ($LogColorAliases.ContainsKey($key)) {
        switch ($LogColorAliases[$key]) {
            'Red'    { $severity = 'error' }
            'Yellow' { $severity = 'warn' }
            'Green'  { $severity = 'ok' }
        }
    }
    if ($Text -match '^\s*\[(ERROR|FAIL|FAILED|UNHANDLED)') { $severity = 'error' }
    elseif ($Text -match '^\s*\[(WARN|CANCEL)') { $severity = 'warn' }
    elseif ($Text -match '^\s*\[(OK|DONE)') { if ($severity -eq 'info') { $severity = 'ok' } }
    return $severity
}

# Which severities the active filter chip lets through.
function Test-LogFilterVisible {
    param([string]$Severity)
    switch ($global:LogFilter) {
        'warn'  { return ($Severity -eq 'warn' -or $Severity -eq 'error') }
        'error' { return ($Severity -eq 'error') }
        default { return $true }
    }
}

# While an action runs, its work happens on the UI thread, so WPF only repaints
# when something gives the dispatcher a turn. This is that turn: a throttled empty
# dispatch at Background priority, which lets render, layout and input through.
# Without it the activity log shows nothing until the whole operation is finished.
function Invoke-UiPump {
    param([switch]$Force)
    if ($null -eq $global:MainWindow) { return }
    if ($global:IsUiPumping -or $global:SuppressUiPump) { return }
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $global:LastUiPumpUtc).TotalMilliseconds -lt 80) { return }
    $global:LastUiPumpUtc = $now
    $global:IsUiPumping = $true
    try {
        $global:MainWindow.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {
    } finally {
        $global:IsUiPumping = $false
    }
}

# Appends one entry to the activity log. Each physical line becomes its own
# paragraph so multi-line error blocks keep their original layout (no re-wrapping).
# Entries are also kept in $global:LogEntries so the filters can rebuild the view,
# and so Save/Copy always produce the complete transcript.
function Add-LogEntry {
    param([string]$Text = '', [string]$Color = '#A0A0B0', [switch]$NoNewline)
    if ($null -eq $global:OutputBox) { return }
    $resolved = Resolve-ThemeColor $Color
    $brush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($resolved)
    $severity = Get-LogSeverity -Color $Color -Text $Text

    if ($NoNewline) {
        # Append to the last line, the way a console keeps a "....." progress
        # line on one row. Nothing is added when the log is empty.
        if ($global:LogEntries.Count -gt 0) {
            $last = $global:LogEntries[$global:LogEntries.Count - 1]
            $run = [System.Windows.Documents.Run]::new($Text)
            $run.Foreground = $brush
            $last.Paragraph.Inlines.Add($run)
            $last.Text += $Text
            if ($global:LogAutoScroll) { $global:OutputBox.ScrollToEnd() }
            Invoke-UiPump
        } else {
            Add-LogEntry -Text $Text -Color $Color
        }
        return
    }

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $stampBrush = Get-ThemeBrush 'TextMuted'
    $firstLine = $true
    foreach ($line in ($Text -split "`r?`n")) {
        $lineText = if ([string]::IsNullOrEmpty($line)) { ' ' } else { $line }
        $para = [System.Windows.Documents.Paragraph]::new()
        $para.Margin = [System.Windows.Thickness]::new(0)
        # Continuation lines get the same width of blank space so blocks stay aligned.
        $stampRun = [System.Windows.Documents.Run]::new($(if ($firstLine) { "[$stamp] " } else { '           ' }))
        $stampRun.Foreground = $stampBrush
        $para.Inlines.Add($stampRun)
        $run = [System.Windows.Documents.Run]::new($lineText)
        $run.Foreground = $brush
        $para.Inlines.Add($run)
        $entryStamp = if ($firstLine) { $stamp } else { '' }
        $global:LogEntries.Add([pscustomobject]@{ Paragraph = $para; Severity = $severity; Text = $lineText; Stamp = $entryStamp })
        if (Test-LogFilterVisible $severity) { $global:OutputBox.Document.Blocks.Add($para) }
        $firstLine = $false
    }

    # Keep the transcript bounded: drop the oldest lines once the cap is passed.
    $overflow = $global:LogEntries.Count - [int]$global:LogMaxLines
    if ($overflow -gt 0) {
        for ($n = 0; $n -lt $overflow; $n++) {
            $old = $global:LogEntries[0]
            if ($null -ne $old -and $null -ne $old.Paragraph) { [void]$global:OutputBox.Document.Blocks.Remove($old.Paragraph) }
            $global:LogEntries.RemoveAt(0)
        }
        $global:LogTrimmed = $true
    }

    if ($global:LogAutoScroll) { $global:OutputBox.ScrollToEnd() }
    # Give WPF a turn so this line is on screen while the action is still running.
    Invoke-UiPump
}

# Rebuilds the visible log from the stored entries, honouring the filter chip.
function Update-LogView {
    if ($null -eq $global:OutputBox) { return }
    $global:OutputBox.Document.Blocks.Clear()
    foreach ($entry in $global:LogEntries) {
        if (Test-LogFilterVisible $entry.Severity) { $global:OutputBox.Document.Blocks.Add($entry.Paragraph) }
    }
    if ($global:LogAutoScroll) { $global:OutputBox.ScrollToEnd() }
}

function Clear-Log {
    if ($null -ne $global:LogEntries) { $global:LogEntries.Clear() }
    if ($null -ne $global:OutputBox) { $global:OutputBox.Document.Blocks.Clear() }
}

# Full transcript (not just the filtered view) with timestamps, for Copy and Save.
function Get-LogPlainText {
    $lines = foreach ($entry in $global:LogEntries) {
        if ($entry.Stamp) { "[$($entry.Stamp)] $($entry.Text)" } else { "           $($entry.Text)" }
    }
    return (($lines -join "`r`n").TrimEnd())
}

function Test-IsElevated {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Header written above the transcript by Save, so a bug report that arrives as one
# file answers the first round of questions (version, Windows, PowerShell, rights,
# Steam paths, which folder is in use) without a conversation.
function Get-DiagnosticsHeader {
    $lines = [System.Collections.Generic.List[string]]::new()
    # One aligned "Key: value" row; the value is the part a support thread needs.
    $add = {
        param([string]$Key, [string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { $Value = 'unknown' }
        $lines.Add(('{0}: {1}' -f $Key.PadRight(21), $Value))
    }

    # --- system -------------------------------------------------------------
    $osName = 'unknown'
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = ('{0} {1} (build {2}.{3})' -f $currentVersion.ProductName, $currentVersion.DisplayVersion, $currentVersion.CurrentBuild, $currentVersion.UBR).Trim()
        # On Windows 11 the registry still reports ProductName "Windows 10"; the
        # build number is the reliable signal.
        if ([int]$currentVersion.CurrentBuild -ge 22000) { $osName = $osName -replace '^Windows 10', 'Windows 11' }
    } catch {
        try { $osName = [System.Environment]::OSVersion.VersionString } catch { }
    }

    $psVersion = ''
    try {
        $psVersion = 'PowerShell ' + $PSVersionTable.PSVersion.ToString()
        if ($PSVersionTable.ContainsKey('PSEdition')) { $psVersion += ' (' + [string]$PSVersionTable.PSEdition + ')' }
    } catch { $psVersion = 'PowerShell unknown' }

    # --- paths --------------------------------------------------------------
    $steamLibraries = ''
    try { $steamLibraries = (@(Get-SteamLibraries) -join '; ') } catch { }
    $detected = ''
    try { $detected = (@(Find-CallOfDutyHQ) -join '; ') } catch { }
    $gameFolder = $global:SessionGameFolder
    if ([string]::IsNullOrWhiteSpace($gameFolder)) { try { $gameFolder = Get-SavedGameFolder } catch { } }

    # --- run mode -----------------------------------------------------------
    $mode = 'interactive (GUI launched normally)'
    if ($global:RequestedDowngradeMethod) { $mode = 'administrator downgrade run (' + [string]$global:RequestedDowngradeMethod + ')' }
    if ([string]::IsNullOrWhiteSpace($global:ScriptPath)) { $mode += ', started from irm | iex' }
    if (Test-SandboxMode) { $mode += ', SANDBOX: ' + [string]$global:SandboxRoot }

    $lines.Add('Call of Duty MW4 Setup Utility - diagnostics')
    $lines.Add(('Saved: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    $lines.Add('')
    $lines.Add('--- Utility ---')
    & $add 'Version' ('v' + [string]$global:AppVersion)
    & $add 'Run mode' $mode
    & $add 'Elevated' $(if (Test-IsElevated) { 'Yes' } else { 'No' })
    & $add 'Theme / accent' ('{0} / {1}' -f $global:ThemeName, $global:AccentName)
    & $add 'Reduce motion' $(if ($global:ReduceMotion) { 'On' } else { 'Off' })
    & $add 'Page / status' ('{0} / {1}' -f $titles[[int]$global:CurrentPage], $global:StatusState)
    $lines.Add('')
    $lines.Add('--- System ---')
    & $add 'Windows' $osName
    & $add 'PowerShell' $psVersion
    & $add 'Architecture' ([string]$env:PROCESSOR_ARCHITECTURE)
    $lines.Add('')
    $lines.Add('--- Paths ---')
    & $add 'Game folder in use' ([string]$gameFolder)
    & $add 'Game folder detected' $detected
    & $add 'Steam libraries' $steamLibraries
    & $add 'Settings file' ([string]$SettingsFile)
    $lines.Add('')
    $logCount = [int]$global:LogEntries.Count
    $logNote = ('{0} line(s)' -f $logCount)
    if ($global:LogTrimmed) { $logNote += (' - older lines dropped, the log keeps the last ' + [string]$global:LogMaxLines + ' line(s)') }
    & $add 'Log' $logNote

    return (($lines -join "`r`n").TrimEnd())
}

# Everything Save writes: the diagnostics header, a separator, then the transcript.
# Kept as one function so the header cannot drift out of the saved file.
function Get-ReportText {
    $header = ''
    try { $header = (Get-DiagnosticsHeader) + "`r`n`r`n" + ('-' * 72) + "`r`n`r`n" } catch { $header = '' }
    return $header + (Get-LogPlainText) + "`r`n"
}

# Single place that styles the status pill, so every code path stays consistent.
function Set-StatusVisual {
    param([string]$State = 'Ready')
    $global:StatusState = $State
    $suffix = switch ($State) {
        'Processing' { 'Busy' }
        'Failed'     { 'Failed' }
        'Cancelled'  { 'Cancelled' }
        default      { 'Ready' }
    }
    $textColorKey = switch ($suffix) {
        'Busy'      { 'Accent' }
        'Failed'    { 'Red' }
        'Cancelled' { 'Yellow' }
        default     { 'Green' }
    }
    $brush = Get-ThemeBrush $textColorKey
    if ($null -ne $global:StatusText) {
        $global:StatusText.Text = $State
        $global:StatusText.Foreground = $brush
    }
    if ($null -ne $global:StatusDot) { $global:StatusDot.Fill = $brush }
    if ($null -ne $global:BusyText) { $global:BusyText.Text = 'Processing...' }
    if ($null -ne $global:StatusPill) {
        $global:StatusPill.Background = Get-ThemeBrush "Status${suffix}Bg"
        $global:StatusPill.BorderBrush = Get-ThemeBrush "Status${suffix}Border"
    }
}

function Write-Host {
    param(
        [Parameter(Position=0, ValueFromPipeline=$true)] [object]$Object,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$NoNewline
    )
    if ($null -eq $global:OutputBox) { Microsoft.PowerShell.Utility\Write-Host $Object -ForegroundColor $ForegroundColor -NoNewline:$NoNewline; return }
    $text = if ($null -eq $Object) { '' } else { [string]$Object }
    
    if ($text -match '^\s*\[(\d+)\]\s*(.*)') {
        $global:AvailableOptions += $text.Trim()
    }
    
    $color = "#A0A0B0"
    switch ($ForegroundColor) {
        'Red'     { $color = "#FF4D4D" }
        'Yellow'  { $color = "#FFD700" }
        'Green'   { $color = "#4EC9B0" }
        'Cyan'    { $color = "#00A8FF" }
        'Magenta' { $color = "#C586C0" }
        'White'   { $color = "#FFFFFF" }
        'DarkGray'{ $color = "#606070" }
        'DarkYellow' { $color = "#B5CEA8" }
    }
    
    if ($NoNewline) {
        # Same line in the log, exactly like a console (e.g. "....." progress dots).
        Add-LogEntry -Text $text -Color $color -NoNewline
    } else {
        Add-LogEntry -Text $text -Color $color
    }
}

# Write-Warning normally goes to a console window that does not exist in the GUI,
# so its output was being lost entirely. Route it into the activity log instead.
function Write-Warning {
    param([Parameter(Position=0, ValueFromPipeline=$true)] [object]$Message)
    if ($null -eq $global:OutputBox) { Microsoft.PowerShell.Utility\Write-Warning -Message $Message; return }
    $text = if ($Message -is [System.Management.Automation.ErrorRecord]) { Format-ErrorRecord $Message } else { [string]$Message }
    $lines = @($text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $prefix = if ($i -eq 0) { '[WARN] ' } else { '       ' }
        Add-LogEntry -Text ($prefix + $lines[$i]) -Color '#FFD700'
    }
}

function Write-Progress {
    param($Activity, $Status, $PercentComplete, [switch]$Completed)
    if ($null -ne $global:StatusText) {
        # Replaced PushFrame with a safe UI update to prevent crashes
        $global:StatusText.Dispatcher.Invoke([Action]{
            if ($Completed) {
                $global:ProgressBar.Visibility = "Collapsed"
                $global:ProgressBar.Value = 0
                if ($null -ne $global:BusyText) { $global:BusyText.Text = "Processing..." }
            } else {
                $global:ProgressBar.Visibility = "Visible"
                if ($null -eq $PercentComplete) { $PercentComplete = 0 }
                $global:ProgressBar.Value = $PercentComplete
                if ($Status -and $null -ne $global:BusyText) { $global:BusyText.Text = "$Activity : $Status" }
            }
        }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

function Read-Host {
    param([string]$Prompt)
    
    # Keep the question in the activity log so a copied log reads like a transcript.
    if ($null -ne $global:OutputBox) {
        $promptLines = @($Prompt -split "`r?`n")
        Add-LogEntry -Text ('? ' + $promptLines[0]) -Color '#606070'
        for ($i = 1; $i -lt $promptLines.Count; $i++) { Add-LogEntry -Text ('  ' + $promptLines[$i]) -Color '#606070' }
    }

    $themeBrush = { param([string]$Key) Get-ThemeBrush $Key }

    $listStyle      = if ($null -ne $global:MainWindow) { $global:MainWindow.TryFindResource('DialogOptionList') } else { $null }
    $primaryStyle   = if ($null -ne $global:MainWindow) { $global:MainWindow.TryFindResource('DialogPrimaryButton') } else { $null }
    $secondaryStyle = if ($null -ne $global:MainWindow) { $global:MainWindow.TryFindResource('DialogSecondaryButton') } else { $null }

    $win = New-Object System.Windows.Window
    $win.Title = "Action Required"
    # Long prompts (folder paths, backup listings) get a wider dialog so text stays readable.
    $win.Width = if ($Prompt.Length -gt 70 -or $Prompt -match "`n") { 640 } else { 560 }
    $win.MinWidth = 480
    $win.MaxWidth = 760
    $win.MinHeight = 190
    $win.MaxHeight = 680
    $win.SizeToContent = "Height"
    $win.ResizeMode = "NoResize"
    $win.ShowInTaskbar = $false
    $win.FontFamily = "Segoe UI"
    $win.UseLayoutRounding = $true
    $win.Background = & $themeBrush 'PopupBg'
    # The dialog is a separate window, so it does not see the main window's
    # brushes: copy the live palette (theme + accent) in, otherwise every
    # DynamicResource inside it falls back to the default white control colours.
    if ($null -ne $global:MainWindow) {
        foreach ($key in @($ThemePalettes[$global:ThemeName].Keys)) {
            $brush = $global:MainWindow.Resources[$key]
            if ($null -ne $brush) { $win.Resources[$key] = $brush }
        }
    }
    $win.WindowStyle = "ToolWindow"
    if (($global:MainWindow -is [System.Windows.Window]) -and $global:MainWindow.IsVisible) {
        $win.Owner = $global:MainWindow
        $win.WindowStartupLocation = "CenterOwner"
    } else {
        $win.WindowStartupLocation = "CenterScreen"
    }
    
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = "28,24,28,22"
    foreach ($rowIndex in 1..4) {
        $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    }

    # Short accent bar instead of a flat dialog header.
    $accentBar = New-Object System.Windows.Controls.Border
    $accentBar.Width = 44; $accentBar.Height = 3; $accentBar.CornerRadius = "2"
    $accentBar.Background = & $themeBrush 'Accent'
    $accentBar.HorizontalAlignment = "Left"; $accentBar.Margin = "0,0,0,16"
    [System.Windows.Controls.Grid]::SetRow($accentBar, 0)
    $null = $grid.Children.Add($accentBar)
    
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Prompt
    $lbl.Foreground = & $themeBrush 'TextPrimary'
    $lbl.FontSize = 15; $lbl.LineHeight = 22; $lbl.TextWrapping = "Wrap"; $lbl.Margin = "0,0,0,18"
    [System.Windows.Controls.Grid]::SetRow($lbl, 1)
    $null = $grid.Children.Add($lbl)

    # Footer: keyboard hint on the left, action buttons on the right.
    $footer = New-Object System.Windows.Controls.Grid
    $footer.Margin = "0,22,0,0"
    $footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $footer.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "*" }))
    [System.Windows.Controls.Grid]::SetRow($footer, 3)
    $null = $grid.Children.Add($footer)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.FontSize = 11.5
    $hint.Foreground = & $themeBrush 'TextMuted'
    $hint.VerticalAlignment = "Center"
    $hint.TextWrapping = "Wrap"
    $hint.MaxWidth = 240
    $hint.Margin = "0,0,16,0"
    [System.Windows.Controls.Grid]::SetColumn($hint, 0)
    $null = $footer.Children.Add($hint)
    
    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = "Horizontal"
    $buttonPanel.HorizontalAlignment = "Right"
    $buttonPanel.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($buttonPanel, 1)
    $null = $footer.Children.Add($buttonPanel)
    
    if ($Prompt -match '\[Y/n\]' -or $Prompt -match '\[y/N\]') {
        # -cmatch, not -match: -match is case-insensitive, so '[Y/n]' also matched
        # '[y/N]' and made Yes the default button even on destructive prompts.
        $isDefaultYes = $Prompt -cmatch '\[Y/n\]'
        # Say what Enter actually does: on [y/N] prompts the safe answer is default.
        $hint.Text = if ($isDefaultYes) { 'Tip: Enter confirms Yes. Esc cancels.' } else { 'Tip: Enter keeps the safe answer (No). Esc also cancels.' }
        # The default button is the one drawn in the accent colour, so on a
        # destructive [y/N] prompt No is highlighted and Yes is the quieter option.
        if (-not $isDefaultYes) { $primaryStyle, $secondaryStyle = $secondaryStyle, $primaryStyle }
        
        $btnYes = New-Object System.Windows.Controls.Button
        $btnYes.Content = "Yes"; $btnYes.Margin = "0,0,10,0"
        $btnYes.IsDefault = $isDefaultYes
        $btnYes.Add_Click({ $win.DialogResult = $true; $win.Close() })
        if ($null -ne $primaryStyle) { $btnYes.Style = $primaryStyle }
        else {
            $btnYes.Padding = "15,5"; $btnYes.MinWidth = 90
            $btnYes.Background = & $themeBrush 'Accent'; $btnYes.Foreground = & $themeBrush 'TextOnAccent'
            $btnYes.BorderThickness = 0; $btnYes.Cursor = "Hand"
        }
        
        $btnNo = New-Object System.Windows.Controls.Button
        $btnNo.Content = "No"
        $btnNo.IsDefault = (-not $isDefaultYes)
        $btnNo.Add_Click({ $win.DialogResult = $false; $win.Close() })
        if ($null -ne $secondaryStyle) { $btnNo.Style = $secondaryStyle }
        else {
            $btnNo.Padding = "15,5"; $btnNo.MinWidth = 90
            $btnNo.Background = & $themeBrush 'ButtonBg'; $btnNo.Foreground = & $themeBrush 'TextPrimary'
            $btnNo.BorderThickness = 0; $btnNo.Cursor = "Hand"
        }
        # Escape (or the window's close button) always answers "No": dismissing a
        # prompt must never silently confirm an action.
        $btnNo.IsCancel = $true
        
        $buttonPanel.Children.Add($btnYes) | Out-Null
        $buttonPanel.Children.Add($btnNo) | Out-Null
        
        $win.Content = $grid
        $win.Add_SourceInitialized({ Enable-DarkTitleBar -TargetWindow $win -Dark:($global:ThemeName -eq 'dark') -CaptionKey 'PopupBg' })
        $res = $win.ShowDialog()
        $answer = if ($res -eq $true) { "y" } else { "n" }
        Add-LogEntry -Text ('> ' + $(if ($answer -eq 'y') { 'Yes' } else { 'No' })) -Color '#A0A0B0'
        return $answer
    } else {
        $global:DialogResult = ""
        $inputControl = $null
        $inputHost = $null
        $listControl = $null
        $freeTextBox = $null
        if ($global:AvailableOptions.Count -gt 0) {
            # A plain list instead of a ComboBox: the dropdown popup inside a modal
            # dialog was painting itself detached from its box (and could not be
            # clicked), so the options are now always on screen and scroll instead.
            $listControl = New-Object System.Windows.Controls.ListBox
            if ($null -ne $listStyle) { $listControl.Style = $listStyle }
            $listControl.MinHeight = 40
            $listControl.MaxHeight = 300
            $listControl.SelectionMode = "Single"
            foreach ($opt in $global:AvailableOptions) { $null = $listControl.Items.Add($opt) }
            $listControl.SelectedIndex = 0
            $global:AvailableOptions = @() # Reset

            $inputHost = New-Object System.Windows.Controls.StackPanel
            $null = $inputHost.Children.Add($listControl)
            $inputControl = $listControl

            # Prompts that also accept free text (e.g. a custom folder path) keep a box.
            if ($Prompt -match '(?i)path') {
                $freeTextBox = New-Object System.Windows.Controls.TextBox
                $freeTextBox.Background = & $themeBrush 'InputBg'
                $freeTextBox.Foreground = & $themeBrush 'TextPrimary'
                $freeTextBox.CaretBrush = & $themeBrush 'TextPrimary'
                $freeTextBox.BorderBrush = & $themeBrush 'Border'
                $freeTextBox.BorderThickness = "1"
                $freeTextBox.Padding = "12,8"; $freeTextBox.FontSize = 13.5
                $freeTextBox.MinHeight = 38
                $freeTextBox.Margin = "0,10,0,0"
                $freeTextBox.VerticalContentAlignment = "Center"
                $freeTextBox.ToolTip = "Type a path instead of picking one from the list"
                $null = $inputHost.Children.Add($freeTextBox)
                $inputControl = $freeTextBox
            }
            $hint.Text = "Pick an option, then press Enter (or double-click it)."
        } else {
            $inputControl = New-Object System.Windows.Controls.TextBox
            $inputControl.Background = & $themeBrush 'InputBg'
            $inputControl.Foreground = & $themeBrush 'TextPrimary'
            $inputControl.CaretBrush = & $themeBrush 'TextPrimary'
            $inputControl.BorderBrush = & $themeBrush 'Border'
            $inputControl.Padding = "12,9"; $inputControl.FontSize = 14
            $inputControl.MinHeight = 40
            $inputControl.VerticalContentAlignment = "Center"
            $inputHost = $inputControl
            $hint.Text = "Type a value, then press Enter."
        }
        [System.Windows.Controls.Grid]::SetRow($inputHost, 2)
        $null = $grid.Children.Add($inputHost)
        
        # Selection mapping is unchanged: a numbered line answers with its number,
        # anything typed by hand is returned verbatim.
        $submitAnswer = {
            $answerText = ''
            if ($null -ne $freeTextBox) { $answerText = ([string]$freeTextBox.Text).Trim() }
            if ([string]::IsNullOrWhiteSpace($answerText) -and $null -ne $listControl) {
                $answerText = [string]$listControl.SelectedItem
            }
            if ($answerText -match '^\s*\[(\d+)\]') { $global:DialogResult = $Matches[1] }
            else { $global:DialogResult = $answerText }
            $win.Close()
        }
        if ($null -ne $listControl) { $listControl.Add_MouseDoubleClick({ param($sender, $e) & $submitAnswer }) }

        $btnSubmit = New-Object System.Windows.Controls.Button
        $btnSubmit.Content = "Submit"; $btnSubmit.Margin = "0,0,10,0"
        $btnSubmit.IsDefault = $true
        $btnSubmit.Add_Click($submitAnswer)
        if ($null -ne $primaryStyle) { $btnSubmit.Style = $primaryStyle }
        else {
            $btnSubmit.Padding = "15,5"; $btnSubmit.MinWidth = 90
            $btnSubmit.Background = & $themeBrush 'Accent'; $btnSubmit.Foreground = & $themeBrush 'TextOnAccent'
            $btnSubmit.BorderThickness = 0; $btnSubmit.Cursor = "Hand"
        }
        
        $btnCancel = New-Object System.Windows.Controls.Button
        $btnCancel.Content = "Cancel"
        $btnCancel.IsCancel = $true
        $btnCancel.Add_Click({ $global:DialogResult = ""; $win.Close() })
        if ($null -ne $secondaryStyle) { $btnCancel.Style = $secondaryStyle }
        else {
            $btnCancel.Padding = "15,5"; $btnCancel.MinWidth = 90
            $btnCancel.Background = & $themeBrush 'ButtonBg'; $btnCancel.Foreground = & $themeBrush 'TextPrimary'
            $btnCancel.BorderThickness = 0; $btnCancel.Cursor = "Hand"
        }
        
        $buttonPanel.Children.Add($btnSubmit) | Out-Null
        $buttonPanel.Children.Add($btnCancel) | Out-Null
        
        $win.Content = $grid
        $win.Add_SourceInitialized({ Enable-DarkTitleBar -TargetWindow $win -Dark:($global:ThemeName -eq 'dark') -CaptionKey 'PopupBg' })
        $win.Add_Loaded({ $inputControl.Focus() | Out-Null })
        $win.ShowDialog() | Out-Null
        if ([string]::IsNullOrWhiteSpace($global:DialogResult)) {
            Add-LogEntry -Text '> (cancelled)' -Color '#A0A0B0'
        } else {
            Add-LogEntry -Text ('> ' + $global:DialogResult) -Color '#A0A0B0'
        }
        return $global:DialogResult
    }
}

# ==========================================
# WINDOW CHROME
# ==========================================
# Purely cosmetic: ask DWM to draw a title bar that matches the current theme.
# Unsupported Windows versions simply keep their normal frame.
function Enable-DarkTitleBar {
    param(
        [System.Windows.Window]$TargetWindow,
        [bool]$Dark = $true,
        [string]$CaptionKey = 'BgDark'
    )
    if ($null -eq $TargetWindow) { return }
    try {
        if (-not ('CodebuffTitleBar' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodebuffTitleBar {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    public static void Apply(IntPtr handle, int useDark, int caption, int text) {
        if (handle == IntPtr.Zero) { return; }
        int value = useDark;
        // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 2004+), 19 = older builds.
        if (DwmSetWindowAttribute(handle, 20, ref value, sizeof(int)) != 0) {
            DwmSetWindowAttribute(handle, 19, ref value, sizeof(int));
        }
        // Windows 11 only: paint the caption in the app's own colours instead of
        // the Windows accent. Unsupported builds simply ignore these.
        DwmSetWindowAttribute(handle, 35, ref caption, sizeof(int));
        DwmSetWindowAttribute(handle, 36, ref text, sizeof(int));
        int border = caption;
        DwmSetWindowAttribute(handle, 34, ref border, sizeof(int));
    }
}
'@ -ErrorAction Stop
        }
        $captionColor = ConvertTo-ColorRef (Get-ThemeColor $CaptionKey)
        $textColor = ConvertTo-ColorRef (Get-ThemeColor 'TextPrimary')
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($TargetWindow)
        [CodebuffTitleBar]::Apply($helper.Handle, $(if ($Dark) { 1 } else { 0 }), $captionColor, $textColor)
    } catch { }
}

# "#RRGGBB" -> Win32 COLORREF (0x00BBGGRR), the format DWM expects.
function ConvertTo-ColorRef {
    param([string]$Color)
    if ($Color -match '^#?([0-9A-Fa-f]{6})$') {
        $hex = $Matches[1]
        $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
        $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
        $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
        return [int](($b -shl 16) -bor ($g -shl 8) -bor $r)
    }
    return 0
}

# ==========================================
# WPF SETUP & EVENT HANDLERS
# ==========================================
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$global:OutputBox = $window.FindName("OutputBox")
$global:StatusText = $window.FindName("StatusText")
$global:ProgressBar = $window.FindName("MainProgressBar")
$global:StatusDot = $window.FindName("StatusDot")
$global:StatusPill = $window.FindName("StatusPill")
$global:BusyText = $window.FindName("BusyText")
$global:MainWindow = $window
# No UI pumping until the window has loaded. A pump is a nested dispatcher frame,
# and it runs whatever is already queued - including the administrator window's
# downgrade, which is queued to start once the window is on screen. A log line
# written before ShowDialog used to pump, so the whole downgrade ran before its
# window ever appeared and only the closing message box was seen. Loaded has a
# higher priority than that queued work, so the work still starts afterwards and
# still updates the log live.
$global:SuppressUiPump = $true
$window.Add_Loaded({ $global:SuppressUiPump = $false })
# One source of truth for the version: the sidebar reads it from $AppVersion.
$window.FindName('VersionText').Text = 'v' + $AppVersion
$window.Add_SourceInitialized({ Enable-DarkTitleBar -TargetWindow $window -Dark:($global:ThemeName -eq 'dark') })

# Log lines keep the brush they were written with, so recolour them when the
# theme changes; otherwise old text stays pale on the new background.
function Update-LogTheme {
    if ($null -eq $global:OutputBox) { return }
    $keys = @($LogColorAliases.Values | Select-Object -Unique)
    $reverse = @{}
    foreach ($palette in $ThemePalettes.Values) {
        foreach ($key in $keys) {
            if ($palette.ContainsKey($key)) { $reverse[([string]$palette[$key]).ToUpperInvariant()] = $key }
        }
    }
    foreach ($hex in $LogColorAliases.Keys) { $reverse[$hex.ToUpperInvariant()] = $LogColorAliases[$hex] }
    # Recolour every stored entry, not just the visible ones, so lines hidden by a
    # filter come back in the right colour when the filter is relaxed again.
    $allParagraphs = @(foreach ($entry in $global:LogEntries) { $entry.Paragraph })
    if ($allParagraphs.Count -eq 0) { $allParagraphs = @($global:OutputBox.Document.Blocks) }
    foreach ($paragraph in $allParagraphs) {
        if ($paragraph -isnot [System.Windows.Documents.Paragraph]) { continue }
        foreach ($inline in @($paragraph.Inlines)) {
            if ($inline -isnot [System.Windows.Documents.Run]) { continue }
            $brush = $inline.Foreground
            if ($brush -isnot [System.Windows.Media.SolidColorBrush]) { continue }
            $hex = ('#' + $brush.Color.R.ToString('X2') + $brush.Color.G.ToString('X2') + $brush.Color.B.ToString('X2')).ToUpperInvariant()
            if ($reverse.ContainsKey($hex)) { $inline.Foreground = Get-ThemeBrush $reverse[$hex] }
        }
    }
}

# Swaps the window's brush resources. Everything else (styles, pages, log,
# dialogs) resolves colours through these keys, so the whole UI follows along.
function Apply-Theme {
    param([string]$Name = 'dark')
    if (-not $ThemePalettes.ContainsKey($Name)) { $Name = 'dark' }
    $global:ThemeName = $Name
    $palette = $ThemePalettes[$Name]
    if ($null -eq $global:MainWindow) { return }
    foreach ($key in $palette.Keys) {
        $global:MainWindow.Resources[$key] = [System.Windows.Media.BrushConverter]::new().ConvertFromString([string]$palette[$key])
    }
    # The accent sits on top of the theme, so it is re-applied after every swap.
    Apply-Accent -Name $global:AccentName
    # Repaint the pieces that are set from code rather than through a binding.
    if ($null -ne $global:GameCardState) {
        Set-GameFolderCard -Title $global:GameCardState.Title -Detail $global:GameCardState.Detail -Icon $global:GameCardState.Icon -ColorKey $global:GameCardState.ColorKey
    }
    if ($null -ne $global:StatusState) { Set-StatusVisual -State $global:StatusState }
    Update-LogTheme
    Update-HeaderChrome
    Enable-DarkTitleBar -TargetWindow $global:MainWindow -Dark:($Name -eq 'dark')
}

# Layers the chosen accent preset on top of the active theme.
function Apply-Accent {
    param([string]$Name = 'Steam')
    if (-not $AccentPresets.Contains($Name)) { $Name = 'Steam' }
    $global:AccentName = $Name
    if ($null -eq $global:MainWindow) { return }
    $preset = $AccentPresets[$Name]
    $triplet = if ($global:ThemeName -eq 'light') { $preset.Light } else { $preset.Dark }
    $keys = @('Accent', 'AccentHover', 'AccentPressed')
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $global:MainWindow.Resources[$keys[$i]] = [System.Windows.Media.BrushConverter]::new().ConvertFromString([string]$triplet[$i])
    }
    Update-HeaderChrome
}

# Keeps the header buttons (accent dots, motion, theme) showing the live state.
function Update-HeaderChrome {
    if ($null -eq $global:MainWindow) { return }
    $dots = [ordered]@{ AccentSteam = 'Steam'; AccentTeal = 'Teal'; AccentViolet = 'Violet'; AccentAmber = 'Amber'; AccentCrimson = 'Crimson' }
    foreach ($dotName in $dots.Keys) {
        $control = $global:MainWindow.FindName($dotName)
        if ($null -ne $control) { $control.IsChecked = ($dots[$dotName] -eq $global:AccentName) }
    }
    $motionIcon = $global:MainWindow.FindName('MotionToggleIcon')
    if ($null -ne $motionIcon) { $motionIcon.Text = if ($global:ReduceMotion) { [string][char]0xE768 } else { [string][char]0xE769 } }
    $motionButton = $global:MainWindow.FindName('BtnMotionToggle')
    if ($null -ne $motionButton) {
        $motionButton.ToolTip = if ($global:ReduceMotion) { 'Reduce motion: on (animations are off)' } else { 'Reduce motion: off (click to calm animations)' }
    }
    $toggleIcon = $global:MainWindow.FindName('ThemeToggleIcon')
    if ($null -ne $toggleIcon) { $toggleIcon.Text = if ($global:ThemeName -eq 'dark') { [string][char]0xE706 } else { [string][char]0xE708 } }
    $toggle = $global:MainWindow.FindName('BtnThemeToggle')
    if ($null -ne $toggle) { $toggle.ToolTip = if ($global:ThemeName -eq 'dark') { 'Switch to the light theme' } else { 'Switch to the dark theme' } }
}

# Reduce-motion: swaps the animated button styles for still ones and stops the
# status pulse. The page transition checks $global:ReduceMotion directly.
function Set-MotionPreference {
    param([bool]$Reduce)
    $global:ReduceMotion = $Reduce
    if ($null -eq $global:MainWindow) { return }
    $cardButtons = @('BtnQuickFix', 'BtnQuickLang', 'BtnInstallFix', 'BtnInstallLang', 'BtnActiveLang', 'BtnDowngradeNormal')
    $dangerButtons = @('BtnRemoveFix', 'BtnRemoveLang', 'BtnDowngradeNuclear')
    $playButtons = @('BtnLaunchBat')
    $cardStyle = $global:MainWindow.TryFindResource($(if ($Reduce) { 'ActionButtonMotionless' } else { 'ActionButton' }))
    $dangerStyle = $global:MainWindow.TryFindResource($(if ($Reduce) { 'DangerButtonMotionless' } else { 'DangerButton' }))
    $playStyle = $global:MainWindow.TryFindResource($(if ($Reduce) { 'PlayButtonMotionless' } else { 'PlayButton' }))
    foreach ($name in $cardButtons) {
        $button = $global:MainWindow.FindName($name)
        if ($null -ne $button -and $null -ne $cardStyle) { $button.Style = $cardStyle }
    }
    foreach ($name in $playButtons) {
        $button = $global:MainWindow.FindName($name)
        if ($null -ne $button -and $null -ne $playStyle) { $button.Style = $playStyle }
    }
    foreach ($name in $dangerButtons) {
        $button = $global:MainWindow.FindName($name)
        if ($null -ne $button -and $null -ne $dangerStyle) { $button.Style = $dangerStyle }
    }
    $dot = $global:StatusDot
    if ($null -ne $dot) {
        if ($Reduce) {
            if ($null -eq $global:StatusPulseTriggers) { $global:StatusPulseTriggers = @($dot.Triggers) }
            $dot.Triggers.Clear()
            $dot.Opacity = 1
            $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        } elseif ($null -ne $global:StatusPulseTriggers) {
            $dot.Triggers.Clear()
            foreach ($trigger in $global:StatusPulseTriggers) { $dot.Triggers.Add($trigger) }
        }
    }
    Update-HeaderChrome
}

# Restores the previous window size/position, clamped to the visible desktop.
function Restore-WindowGeometry {
    param($Settings)
    try {
        $width = [double]$Settings.WindowWidth
        $height = [double]$Settings.WindowHeight
        if ($width -ge $window.MinWidth -and $height -ge $window.MinHeight) {
            $window.Width = [Math]::Min($width, [double][System.Windows.SystemParameters]::VirtualScreenWidth)
            $window.Height = [Math]::Min($height, [double][System.Windows.SystemParameters]::VirtualScreenHeight)
        }
        $left = [double]$Settings.WindowLeft
        $top = [double]$Settings.WindowTop
        $virtualRight = [System.Windows.SystemParameters]::VirtualScreenLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $virtualBottom = [System.Windows.SystemParameters]::VirtualScreenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        if ($left -ge [System.Windows.SystemParameters]::VirtualScreenLeft -and $top -ge [System.Windows.SystemParameters]::VirtualScreenTop -and
            $left -lt ($virtualRight - 120) -and $top -lt ($virtualBottom - 120)) {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = $left
            $window.Top = $top
        }
        if ([bool]$Settings.WindowMaximized) { $window.WindowState = 'Maximized' }
    } catch { }
}

$startupSettings = Get-AppSettings
$global:AccentName = if ($AccentPresets.Contains([string]$startupSettings.Accent)) { [string]$startupSettings.Accent } else { 'Steam' }
$global:ReduceMotion = [bool]$startupSettings.ReduceMotion
Apply-Theme -Name ([string]$startupSettings.Theme)
Set-MotionPreference -Reduce $global:ReduceMotion
Restore-WindowGeometry -Settings $startupSettings

# Any exception that escapes an event handler (and therefore never reaches
# Run-Action's catch) is logged with full detail instead of vanishing silently
# or tearing down the window.
$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    $record = [System.Management.Automation.ErrorRecord]::new(
        $e.Exception,
        'UnhandledGuiException',
        [System.Management.Automation.ErrorCategory]::NotSpecified,
        $null)
    $separator = '=' * 72
    Add-LogEntry -Text '' -Color '#FF4D4D'
    Add-LogEntry -Text $separator -Color '#FF4D4D'
    Add-LogEntry -Text 'UNHANDLED ERROR' -Color '#FF4D4D'
    Add-LogEntry -Text $separator -Color '#FF4D4D'
    Add-LogEntry -Text (Format-ErrorRecord $record) -Color '#FF4D4D'
    Add-LogEntry -Text $separator -Color '#FF4D4D'
    $global:ProgressBar.Visibility = "Collapsed"
    $window.FindName("ReadyPanel").Visibility = "Visible"
    $window.FindName("BusyPanel").Visibility = "Collapsed"
    Set-StatusVisual -State 'Failed'
    $global:IsProcessing = $false
})

# Updates the Overview card so the automatic/saved/manual folder state is always visible.
function Set-GameFolderCard {
    param(
        [string]$Title,
        [string]$Detail,
        [string]$Icon = [string][char]0xE73E,
        [string]$ColorKey = 'Green'
    )
    # Remembered so a theme switch can repaint the card without losing its state.
    $global:GameCardState = @{ Title = $Title; Detail = $Detail; Icon = $Icon; ColorKey = $ColorKey }
    if ($null -eq $global:MainWindow) { return }
    $mainWindow = $global:MainWindow
    $mainWindow.FindName('GameCardTitle').Text = $Title
    $pathBlock = $mainWindow.FindName('GamePathText')
    $pathBlock.Text = $Detail
    $pathBlock.Foreground = Get-ThemeBrush 'TextSecondary'
    $iconBlock = $mainWindow.FindName('GameCardIcon')
    $iconBlock.Text = $Icon
    $iconBlock.Foreground = Get-ThemeBrush $ColorKey
}

# Game path detection on startup: a saved folder wins over detection; when nothing
# is found the card explains that the folder can be picked by hand.
$window.Dispatcher.Invoke([action]{
    try {
        $savedFolder = Get-SavedGameFolder
        # A folder passed in at startup (-GameFolder, or the sandbox's game) is the
        # one every action uses, so the card shows that one.
        if ($global:SessionGameFolder -and (Test-Path -LiteralPath $global:SessionGameFolder -PathType Container)) {
            $label = if (Test-SandboxMode) { 'Sandbox game folder' } else { 'Game folder set' }
            Set-GameFolderCard -Title $label -Detail "Using: $($global:SessionGameFolder)" -ColorKey 'Green'
        } elseif ($savedFolder) {
            Set-GameFolderCard -Title 'Game folder set' -Detail "Using your saved folder: $savedFolder" -ColorKey 'Green'
        } else {
            $detected = @(Find-CallOfDutyHQ)
            if ($detected.Count -gt 0) {
                Set-GameFolderCard -Title 'Game detected' -Detail "Detected at: $($detected[0])" -ColorKey 'Green'
            } else {
                Set-GameFolderCard -Title 'Game not detected' -Detail 'Steam could not find Call of Duty HQ. Click "Change folder" to pick it yourself; your choice is remembered next time.' -Icon ([string][char]0xE7BA) -ColorKey 'Yellow'
            }
        }
    } catch {
        Set-GameFolderCard -Title 'Detection failed' -Detail 'See the activity log, then click "Change folder" to pick the game folder.' -Icon ([string][char]0xE7BA) -ColorKey 'Red'
        Add-LogEntry -Text (Format-ErrorRecord $_) -Color '#FF4D4D'
    }
}, "Render")

$window.FindName("BtnClearLog").Add_Click({
    Clear-Log
    Add-LogEntry -Text 'Activity log cleared.' -Color '#606070'
})

$window.FindName("BtnCopyLog").Add_Click({
    $logText = Get-LogPlainText
    if ([string]::IsNullOrWhiteSpace($logText)) { return }
    try {
        [System.Windows.Clipboard]::SetText($logText)
        Add-LogEntry -Text '[OK]   Activity log copied to the clipboard.' -Color '#4EC9B0'
    } catch {
        Add-LogEntry -Text ('[WARN] Could not copy the activity log: ' + $_.Exception.Message) -Color '#FFD700'
    }
})

# Save the whole transcript (all severities, with timestamps) to a text file.
$window.FindName('BtnSaveLog').Add_Click({
    $logText = Get-LogPlainText
    if ([string]::IsNullOrWhiteSpace($logText)) {
        Add-LogEntry -Text 'Nothing to save yet: the activity log is empty.' -Color '#606070'
        return
    }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Title = 'Save activity log'
    $dialog.Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = 'codhq-utility-log-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt'
    if ($dialog.ShowDialog() -ne $true) {
        Add-LogEntry -Text 'Saving the log was cancelled.' -Color '#606070'
        return
    }
    try {
        [IO.File]::WriteAllText($dialog.FileName, (Get-ReportText), [Text.UTF8Encoding]::new($true))
        Add-LogEntry -Text ('[OK]   Activity log saved to ' + $dialog.FileName + ' (with a diagnostics header)') -Color '#4EC9B0'
    } catch {
        Add-LogEntry -Text ('[WARN] Could not save the log: ' + $_.Exception.Message) -Color '#FFD700'
    }
})

# Filter chips + auto-scroll toggle.
$window.FindName('LogFilterAll').Add_Click({ $global:LogFilter = 'all'; Update-LogView })
$window.FindName('LogFilterWarn').Add_Click({ $global:LogFilter = 'warn'; Update-LogView })
$window.FindName('LogFilterError').Add_Click({ $global:LogFilter = 'error'; Update-LogView })
$window.FindName('BtnAutoScroll').Add_Click({
    $global:LogAutoScroll = [bool]$window.FindName('BtnAutoScroll').IsChecked
    if ($global:LogAutoScroll) { $global:OutputBox.ScrollToEnd() }
})

# Manual folder choice: available on the Overview card, always saved for later runs.
$window.FindName('BtnChooseFolder').Add_Click({
    if ($global:IsProcessing) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the Call of Duty HQ game folder'
    $dialog.ShowNewFolderButton = $false
    $current = Get-SavedGameFolder
    if (-not $current) {
        $detected = @(Find-CallOfDutyHQ)
        if ($detected.Count -gt 0) { $current = $detected[0] }
    }
    if ($current -and (Test-Path -LiteralPath $current -PathType Container)) { $dialog.SelectedPath = $current }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Add-LogEntry -Text 'Folder selection cancelled. The previous folder is still in use.' -Color '#606070'
        return
    }
    $folder = [IO.Path]::GetFullPath($dialog.SelectedPath).TrimEnd('\')
    # Warn (never block) when the picked folder has none of the usual game markers.
    $layout = Test-GameFolder -Folder $folder
    if (-not $layout.LooksValid) {
        $missing = ($layout.Missing -join ', ')
        $answer = Read-Host "This folder doesn't look like Call of Duty HQ:`n$folder`n`nNone of these were found: $missing`n`nUse it anyway? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Add-LogEntry -Text 'Folder was not changed. The previous folder is still in use.' -Color '#606070'
            return
        }
    }
    if (Save-GameFolder -Folder $folder) {
        Set-GameFolderCard -Title 'Game folder set' -Detail "Saved at: $folder" -ColorKey 'Green'
        Add-LogEntry -Text ('[OK]   Game folder saved: ' + $folder) -Color '#4EC9B0'
        Add-LogEntry -Text '       Every action uses this folder automatically from now on.' -Color '#606070'
    } else {
        # Saving can fail (permissions, read-only profile); still honor the pick now.
        $global:SessionGameFolder = $folder
        Set-GameFolderCard -Title 'Folder not saved' -Detail "Saved settings could not be written. Using this folder for the current session: $folder" -Icon ([string][char]0xE7BA) -ColorKey 'Yellow'
    }
})

$navButtons = @("NavOverview", "NavFixes", "NavLanguages", "NavDowngrade", "NavGames")
$pages = @("PageOverview", "PageFixes", "PageLanguages", "PageDowngrade", "PageGames")
$titles = @("Overview", "Fix Installer", "Languages", "Downgrade Version", "Games")

# Single navigation helper, also used to restore the last opened page.
# Navigation is never blocked: the pages are just views, and a guard here could
# latch on a failed action and leave the whole sidebar dead.
function Show-Page {
    param([int]$Index, [switch]$Force)
    if ($Index -lt 0 -or $Index -ge $pages.Count) { return }
    for ($n = 0; $n -lt $navButtons.Count; $n++) { $window.FindName($navButtons[$n]).IsChecked = ($n -eq $Index) }
    for ($n = 0; $n -lt $pages.Count; $n++) { $window.FindName($pages[$n]).Visibility = if ($n -eq $Index) { 'Visible' } else { 'Collapsed' } }
    $window.FindName('HeaderTitle').Text = $titles[$Index]
    $global:CurrentPage = $Index

    # Fade + slide the incoming page in, unless reduce-motion is on or the window
    # is not visible yet (the startup page restore runs before ShowDialog, and an
    # animation that never ticks would leave the page stuck half transparent).
    $target = $window.FindName($pages[$Index])
    if ($null -eq $target) { return }
    if ($global:ReduceMotion -or -not $window.IsVisible) {
        $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $target.Opacity = 1
        $target.RenderTransform = [System.Windows.Media.Transform]::Identity
        return
    }
    $slide = [System.Windows.Media.TranslateTransform]::new(0, 0)
    $target.RenderTransform = $slide
    $target.Opacity = 1
    $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
    # FillBehavior.Stop leaves the base values (opacity 1, offset 0) in charge once
    # the animation ends, so nothing can latch at a half-faded value.
    $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0.15, 1.0, $duration)
    $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $rise = [System.Windows.Media.Animation.DoubleAnimation]::new(10.0, 0.0, $duration)
    $rise.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $slide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
}

# The page index travels on the control's Tag, and the handler below switches the
# view inline using only global state. GetNewClosure() cannot be used here: a
# closure runs in its own module where the script's functions (Show-Page) are not
# visible, which made every sidebar click fail with
# "The term 'Show-Page' is not recognized". Calling no functions at all makes the
# click path immune to that class of scope problem.
$global:UiNavState = @{ Buttons = $navButtons; Pages = $pages; Titles = $titles }
for ($i = 0; $i -lt $navButtons.Count; $i++) {
    $navButton = $window.FindName($navButtons[$i])
    $navButton.Tag = $i
    $navButton.Add_Click({
        param($sender, $e)
        $state = $global:UiNavState
        $main = $global:MainWindow
        if ($null -eq $state -or $null -eq $main) { return }
        $index = [int]$sender.Tag
        if ($index -lt 0 -or $index -ge $state.Pages.Count) { return }
        for ($n = 0; $n -lt $state.Buttons.Count; $n++) { $main.FindName($state.Buttons[$n]).IsChecked = ($n -eq $index) }
        for ($n = 0; $n -lt $state.Pages.Count; $n++) { $main.FindName($state.Pages[$n]).Visibility = $(if ($n -eq $index) { 'Visible' } else { 'Collapsed' }) }
        $main.FindName('HeaderTitle').Text = $state.Titles[$index]
        $global:CurrentPage = $index

        # Fade + slide the incoming page, unless reduce-motion is on.
        if (-not $global:ReduceMotion -and $main.IsVisible) {
            $target = $main.FindName($state.Pages[$index])
            if ($null -ne $target) {
                $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
                $slide = [System.Windows.Media.TranslateTransform]::new(0, 0)
                $target.RenderTransform = $slide
                $target.Opacity = 1
                $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0.15, 1.0, $duration)
                $fade.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                $rise = [System.Windows.Media.Animation.DoubleAnimation]::new(10.0, 0.0, $duration)
                $rise.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
                $slide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
            }
        }
    })
}

# Theme toggle lives in the header; the choice is persisted with the other settings.
$window.FindName('BtnThemeToggle').Add_Click({
    $next = if ($global:ThemeName -eq 'dark') { 'light' } else { 'dark' }
    Apply-Theme -Name $next
    $null = Save-ThemeChoice $next
    Add-LogEntry -Text ('[OK]   Switched to the ' + $next + ' theme.') -Color '#4EC9B0'
})

# Accent presets: one click recolours the UI in both themes and is remembered.
# Same Tag trick as the sidebar: no closures, so the script's functions resolve.
$accentDots = [ordered]@{ AccentSteam = 'Steam'; AccentTeal = 'Teal'; AccentViolet = 'Violet'; AccentAmber = 'Amber'; AccentCrimson = 'Crimson' }
foreach ($dotName in $accentDots.Keys) {
    $dot = $window.FindName($dotName)
    $dot.Tag = $accentDots[$dotName]
    $dot.Add_Click({
        param($sender, $e)
        $presetName = [string]$sender.Tag
        Apply-Accent -Name $presetName
        $null = Save-AccentChoice $presetName
        Add-LogEntry -Text ('[OK]   Accent colour set to ' + $AccentPresets[$presetName].Label + '.') -Color '#4EC9B0'
    })
}

# Reduce-motion toggle (motion off = static buttons, no page fade, no status pulse).
$window.FindName('BtnMotionToggle').Add_Click({
    Set-MotionPreference -Reduce (-not $global:ReduceMotion)
    $null = Save-MotionChoice $global:ReduceMotion
    $message = if ($global:ReduceMotion) { '[OK]   Reduce motion on: page animations and the status pulse are off.' } else { '[OK]   Reduce motion off: animations are back on.' }
    Add-LogEntry -Text $message -Color '#4EC9B0'
})

# Remember window size/position and the open page for the next launch.
$window.Add_Closing({
    param($sender, $eventArgs)
    # No UI pumping from inside the close notification.
    $global:SuppressUiPump = $true
    try {
        # Closing mid-action would end the message loop while the work carried on
        # invisibly, so the window is held open until the action has finished. The
        # elevation hand-off sets $global:AllowProgrammaticClose for its own Close().
        if ($global:IsProcessing -and -not $global:AllowProgrammaticClose) {
            $eventArgs.Cancel = $true
            Add-LogEntry -Text '[WARN] An operation is running. This window stays open until it finishes (Ctrl+C in a console, or End task in Task Manager, forces it).' -Color '#FFD700'
            return
        }
        # The administrator worker is a short-lived copy of this window: saving from
        # it would overwrite the layout and last page the real window owns, and it
        # always sits on the Downgrade page.
        if (-not $RunDowngradeOnly) {
            try {
                $null = Save-WindowPreferences -Page ([int]$global:CurrentPage) -Width ([double]$window.Width) -Height ([double]$window.Height) `
                    -Left ([double]$window.Left) -Top ([double]$window.Top) -Maximized ($window.WindowState -eq 'Maximized')
            } catch { }
        }
    } finally {
        $global:SuppressUiPump = $false
    }
})

function Run-Action {
    # -Arguments is splatted into the action block, so a caller never has to build
    # a closure to pass a value (closures cannot see the script's own functions).
    param([scriptblock]$Action, [object[]]$Arguments = @())
    if ($global:IsProcessing) { return }
    # While the administrator window works, this one only follows it: running a
    # second action here would compete with the run that is already going.
    if ($null -ne $global:WorkerWatcher) {
        Add-LogEntry -Text '[WARN] The administrator window is still running. This window follows it as soon as it finishes.' -Color '#FFD700'
        return
    }
    $global:IsProcessing = $true
    # Numbered lines an earlier action printed but never asked about must not turn
    # up as options in this action's first prompt.
    $global:AvailableOptions = @()
    $actionFailed = $false
    $actionCancelled = $false
    $actionButtons = @("BtnQuickFix", "BtnQuickLang", "BtnChooseFolder", "BtnLaunchBat", "BtnInstallFix", "BtnRemoveFix",
                       "BtnInstallLang", "BtnActiveLang", "BtnRemoveLang", "BtnDowngradeNormal", "BtnDowngradeNuclear")

    # Everything below runs inside try/finally: a prompt that blows up half way
    # through must never leave the UI stuck in "Processing" with dead buttons.
    try {
    Clear-Log
    $window.FindName("ReadyPanel").Visibility = "Collapsed"
    $window.FindName("BusyPanel").Visibility = "Visible"
    $global:ProgressBar.Value = 0
    $global:ProgressBar.Visibility = "Collapsed"
    Set-StatusVisual -State 'Processing'

    # Disable all action buttons
    foreach ($actionButtonName in $actionButtons) { $window.FindName($actionButtonName).IsEnabled = $false }

    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
    
    try { & $Action @Arguments }
    catch { 
        if ($_.Exception -is [System.OperationCanceledException]) {
            # The user answered "No" or closed a prompt: say so calmly, no error block.
            $actionCancelled = $true
            Add-LogEntry -Text '' -Color '#FFD700'
            Add-LogEntry -Text ('[CANCEL] ' + $_.Exception.Message) -Color '#FFD700'
            Add-LogEntry -Text '' -Color '#FFD700'
        } else {
            # Reproduce the full console error block, plus the call stack a console
            # would not show, instead of only the bare exception message.
            $actionFailed = $true
            $separator = '=' * 72
            Add-LogEntry -Text '' -Color '#FF4D4D'
            Add-LogEntry -Text $separator -Color '#FF4D4D'
            Add-LogEntry -Text 'ACTION FAILED' -Color '#FF4D4D'
            Add-LogEntry -Text $separator -Color '#FF4D4D'
            Add-LogEntry -Text (Format-ErrorRecord $_) -Color '#FF4D4D'
            Add-LogEntry -Text $separator -Color '#FF4D4D'
        }
    }
    
    } finally {
        # Re-enable buttons and settle the status pill, whatever happened above.
        foreach ($actionButtonName in $actionButtons) { $window.FindName($actionButtonName).IsEnabled = $true }
        $global:ProgressBar.Visibility = "Collapsed"
        $window.FindName("ReadyPanel").Visibility = "Visible"
        $window.FindName("BusyPanel").Visibility = "Collapsed"
        if ($actionFailed) { Set-StatusVisual -State 'Failed' }
        elseif ($actionCancelled) { Set-StatusVisual -State 'Cancelled' }
        else { Set-StatusVisual -State 'Ready' }
        $global:IsProcessing = $false
    }
}

# What the administrator run did, written by the worker so the window that comes
# back can report it instead of guessing.
function Write-LastWorkerResult {
    param([string]$Method, [string]$State, [string]$LogPath)
    try {
        $result = @{
            Method     = $Method
            State      = $State
            LogPath    = [string]$LogPath
            FinishedAt = (Get-Date).ToString('o')
        }
        [IO.File]::WriteAllText((Join-Path (Get-HandoffDirectory) 'last-run.json'), ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch { }
}

# Folder shared by the two windows of a downgrade: the one passed with
# -HandoffDirectory (the starting window's own settings folder), otherwise this
# account's settings folder, exactly as before.
function Get-HandoffDirectory {
    $handoff = [string]$global:HandoffDirectory
    if (-not [string]::IsNullOrWhiteSpace($handoff)) { return $handoff }
    return $SettingsDirectory
}

# Reports the administrator run's outcome in this window, including where its log
# was saved. A result older than this run is ignored, so a previous session's
# outcome can never be reported as if it were this one.
function Show-LastWorkerResult {
    param([string]$Method = 'Normal', [DateTime]$StartedAt = [DateTime]::MinValue)
    $label = if ($Method -eq 'Nuclear') { 'Nuclear downgrade' } else { 'Normal downgrade' }
    $logsDir = Join-Path (Get-HandoffDirectory) 'logs'

    $result = $null
    try {
        $resultPath = Join-Path (Get-HandoffDirectory) 'last-run.json'
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
    } catch { $result = $null }

    $fresh = $false
    if ($null -ne $result) {
        try { $fresh = ([datetime]$result.FinishedAt) -ge $StartedAt.AddSeconds(-10) } catch { $fresh = $false }
    }
    if (-not $fresh) {
        Add-LogEntry -Text ('[WARN] The administrator window closed without reporting a result. Its log is under ' + $logsDir) -Color '#FFD700'
        Set-StatusVisual -State 'Ready'
        return
    }

    $logPath = [string]$result.LogPath
    $where = if ([string]::IsNullOrWhiteSpace($logPath)) { '' } else { ' Log saved to ' + $logPath + '.' }
    switch ([string]$result.State) {
        'Failed' {
            Add-LogEntry -Text ('[WARN] ' + $label + ' failed.' + $where) -Color '#FFD700'
            Set-StatusVisual -State 'Failed'
        }
        'Cancelled' {
            Add-LogEntry -Text ('[OK]   ' + $label + ' was cancelled; nothing was changed.' + $where) -Color '#FFD700'
            Set-StatusVisual -State 'Cancelled'
        }
        default {
            Add-LogEntry -Text ('[OK]   ' + $label + ' finished.' + $where) -Color '#4EC9B0'
            Set-StatusVisual -State 'Ready'
        }
    }
}

# The administrator window writes this the moment it starts. "Start-Process -Verb
# RunAs -PassThru" does not reliably hand back that window's process: it can return
# the shell's elevation stub, which exits immediately. Watching the stub woke this
# window while the administrator one was still on screen, so two windows sat there.
function Get-WorkerHandshakePath { return (Join-Path (Get-HandoffDirectory) 'worker.json') }

function Clear-WorkerHandshake {
    try {
        $handshakePath = Get-WorkerHandshakePath
        if (Test-Path -LiteralPath $handshakePath -PathType Leaf) { Remove-Item -LiteralPath $handshakePath -Force }
    } catch { }
}

function Write-WorkerHandshake {
    param([string]$Method = 'Normal')
    try {
        $handoffDirectory = Get-HandoffDirectory
        if (-not (Test-Path -LiteralPath $handoffDirectory -PathType Container)) { $null = New-Item -ItemType Directory -Path $handoffDirectory -Force }
        $payload = [ordered]@{ Pid = $PID; Method = $Method; StartedAt = (Get-Date).ToString('o') }
        [IO.File]::WriteAllText((Get-WorkerHandshakePath), ($payload | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    } catch { }
}

# Returns the announced id, or 0 when there is no announcement from this run. A
# leftover file from an earlier run is ignored by its timestamp.
function Get-WorkerHandshakePid {
    param([DateTime]$Since = [DateTime]::MinValue)
    try {
        $handshakePath = Get-WorkerHandshakePath
        if (-not (Test-Path -LiteralPath $handshakePath -PathType Leaf)) { return 0 }
        $info = Get-Content -LiteralPath $handshakePath -Raw | ConvertFrom-Json
        # Without -Since every announcement counts (DateTime.MinValue minus 15
        # seconds would throw and silently report "no worker").
        if ($Since -gt [DateTime]::MinValue.AddSeconds(15) -and [datetime]$info.StartedAt -lt $Since.AddSeconds(-15)) { return 0 }
        return [int]$info.Pid
    } catch { return 0 }
}

# Waits for the administrator window to exit, then brings this window back. The
# replacement cannot be a new process: one started from here would inherit this
# process's token instead of the normal user's, so this window steps aside (it
# minimizes - hiding would end the modal loop and quit the app) and returns.
function Start-WorkerWatcher {
    param([int]$WorkerProcessId, [string]$Method = 'Normal')
    if ($null -ne $global:WorkerWatcher) { $global:WorkerWatcher.Stop(); $global:WorkerWatcher = $null }
    $global:WorkerWatcherPid = $WorkerProcessId
    $global:WorkerWatcherFallbackPid = $WorkerProcessId
    $global:WorkerWatcherAnnounced = $false
    $global:WorkerWatcherMethod = $Method
    $global:WorkerWatcherStartedAt = Get-Date

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    # Only globals: this tick runs long after the function that created it returned.
    $timer.Add_Tick({
        $announcedPid = Get-WorkerHandshakePid -Since $global:WorkerWatcherStartedAt
        if ($announcedPid -gt 0) {
            $global:WorkerWatcherPid = $announcedPid
            $global:WorkerWatcherAnnounced = $true
        } elseif (-not $global:WorkerWatcherAnnounced) {
            $global:WorkerWatcherPid = $global:WorkerWatcherFallbackPid
        }
        $pidToWatch = [int]$global:WorkerWatcherPid
        if ($pidToWatch -le 0) { return }
        $running = $false
        try { $running = [bool](Get-Process -Id $pidToWatch -ErrorAction SilentlyContinue) } catch { $running = $false }
        if ($running) { return }
        # Without an announcement the id may be the elevation stub, so give the real
        # window a few seconds to introduce itself before believing it is gone.
        if (-not $global:WorkerWatcherAnnounced -and ((Get-Date) - $global:WorkerWatcherStartedAt).TotalSeconds -lt 8) { return }
        if ($null -ne $global:WorkerWatcher) { $global:WorkerWatcher.Stop(); $global:WorkerWatcher = $null }
        $mainWindow = $global:MainWindow
        if ($null -eq $mainWindow) { return }
        try {
            $restore = $global:WorkerWatcherRestoreState
            if ($restore -ne 'Maximized') { $restore = 'Normal' }
            $mainWindow.WindowState = $restore
            [void]$mainWindow.Activate()
        } catch { }
        try { Show-LastWorkerResult -Method $global:WorkerWatcherMethod -StartedAt $global:WorkerWatcherStartedAt } catch { }
        Clear-WorkerHandshake
    })
    $global:WorkerWatcher = $timer
    $timer.Start()
}

# Downgrade buttons: run in place when already elevated, otherwise relaunch this
# same file elevated with -RunDowngradeOnly. $global:ScriptPath is captured at
# startup because inside a click handler $MyInvocation.MyCommand.Definition is the
# handler's own code block, not the path of the script.
function Invoke-DowngradeWithElevation {
    param([ValidateSet('Normal', 'Nuclear')][string]$Method)

    # Read-only check first: a downgrade that cannot run must stop here, before the
    # Nuclear question, the UAC prompt, and above all before the fix is reverted.
    $null = Test-SteamDowngradeReadiness -Method $Method

    # Nuclear deletes files from the Steam folder, so it always asks first and
    # states exactly what goes. The confirmation sits here, before elevation, so
    # it is shown once whether the app is already elevated or has to relaunch.
    if ($Method -eq 'Nuclear') {
        $warning = @'
NUCLEAR DOWNGRADE (Advanced) - this is destructive.

It deletes everything inside your Steam folder except:
  appcache, config, steam, steamapps, userdata and steam.exe

Then it closes Steam, starts it so it can rebuild what was removed, closes
it again and runs the BetterSteamTools installer from
https://ps.lua.tools/install-ost.ps1.

After that it runs the normal downgrade: 1938090.lua is replaced with the
version-locked copy, this game's manifests are deleted from depotcache, and
Steam is asked to validate your files.

Steam restarts several times and administrator rights are required. Use this
only when the normal downgrade has failed.

If the fix is still applied, you will be asked to revert it and delete its
"og files" backups before the downgrade starts.

Run the Nuclear downgrade now? [y/N]
'@
        if ((Read-Host $warning) -notmatch '^(y|yes)$') {
            # Not a failure: report it calmly and keep the status pill on Ready.
            Add-LogEntry -Text '[CANCEL] Nuclear downgrade cancelled. Nothing in your Steam folder was touched.' -Color '#FFD700'
            return
        }
        Add-LogEntry -Text '[OK]   Nuclear downgrade confirmed.' -Color '#4EC9B0'
    }

    $isAdmin = Test-IsElevated
    if ($isAdmin) {
        # Called straight, not through Run-Action: this function already runs inside
        # an action, and Run-Action ignores a nested call while one is in progress
        # (that guard is what makes the button do nothing when the app is elevated).
        # Checks, downloads, then reverts the fix and runs the downgrade.
        Invoke-PreparedDowngrade -Method $Method
        return
    }

    # No Clear-Log here: Run-Action cleared the log when this action started, and
    # clearing again would wipe the Nuclear confirmation logged above.
    Add-LogEntry -Text ('[WARN] Administrator privileges are required for the ' + $Method + ' downgrade. Accept the UAC prompt to continue.') -Color '#FFD700'
    $scriptPath = $global:ScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Add-LogEntry -Text '[WARN] Cannot relaunch as administrator: the path of this script is unknown. Start PowerShell as administrator and run the file again.' -Color '#FFD700'
        return
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf) -and (Test-ScriptSourceLooksComplete $global:ScriptSourceText)) {
        # The temp copy was removed while this window was open; write it back from
        # the text loaded at startup so the elevated relaunch has a file to run.
        try { [IO.File]::WriteAllText($scriptPath, $global:ScriptSourceText, [Text.UTF8Encoding]::new($false)) } catch { }
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Add-LogEntry -Text ('[WARN] Cannot relaunch as administrator: the script file is missing: ' + $scriptPath + '. Run the utility again.') -Color '#FFD700'
        return
    }
    try {
        # Any handshake file belongs to an earlier run; the worker writes its own.
        Clear-WorkerHandshake
        # -DowngradeMethod keeps the chosen method across the elevation boundary.
        # -HandoffDirectory and -GameFolder: the administrator may be another account,
        # whose settings folder and saved game folder are not this user's.
        $handoffArguments = ' -HandoffDirectory ' + (ConvertTo-QuotedArgument (Get-HandoffDirectory))
        $folderInUse = $null
        try { $folderInUse = Resolve-GameFolderQuiet } catch { $folderInUse = $null }
        if ($folderInUse) { $handoffArguments += ' -GameFolder ' + (ConvertTo-QuotedArgument $folderInUse) }
        if (Test-SandboxMode) { $handoffArguments += ' -Sandbox ' + (ConvertTo-QuotedArgument $global:SandboxRoot) }
        $elevated = Start-Process powershell.exe -Verb RunAs -PassThru -ArgumentList ("-NoProfile -STA -ExecutionPolicy Bypass -File `"$scriptPath`" -RunDowngradeOnly -DowngradeMethod $Method" + $handoffArguments)
        # The elevated instance is the one that runs the downgrade, and it shows its
        # own window with the live log. This window hides rather than closes, so it
        # can come back with the result once the administrator window is gone.
        Add-LogEntry -Text ('[OK]   Elevated window started. The ' + $Method + ' downgrade runs there; its activity log shows the progress.') -Color '#4EC9B0'
        Add-LogEntry -Text '       This window minimizes and comes back when that run is over.' -Color '#606070'
        Invoke-UiPump -Force
        $workerId = 0
        try { $workerId = [int]$elevated.Id } catch { $workerId = 0 }
        if ($workerId -le 0) {
            Add-LogEntry -Text '[WARN] The administrator window could not be tracked, so this window stays open; the downgrade still runs there.' -Color '#FFD700'
            return
        }
        # Minimize, never Hide(): hiding a window opened with ShowDialog ends the
        # dialog and the process would exit while the downgrade is still running.
        $global:WorkerWatcherRestoreState = $window.WindowState
        $window.WindowState = 'Minimized'
        Add-LogEntry -Text ('       Window minimized (state: ' + [string]$window.WindowState + '). It stays out of the way until the administrator window closes.') -Color '#606070'
        Start-WorkerWatcher -WorkerProcessId $workerId -Method $Method
    } catch {
        # Nothing was handed over, so make sure this window is on screen.
        try { if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal'; [void]$window.Activate() } } catch { }
        Add-LogEntry -Text ('[WARN] Elevation was refused or failed: ' + $_.Exception.Message) -Color '#FFD700'
    }
}

# Every action button shares one handler. The action key travels on the button's
# Tag and the map lives in script scope: same no-closure pattern as the sidebar
# and the accent dots, so no handler depends on the scope it is invoked from.
$global:ActionMap = @{
    'InstallFix'       = { Install-Fix }
    'InstallLanguage'  = { Install-LanguagePack }
    'LaunchBatch'      = { Launch-BatchFile }
    'RemoveFix'        = { Remove-Fix }
    'ActiveLanguage'   = { Set-ActiveLanguagePreset }
    'RemoveLanguage'   = { Remove-LanguagePack }
    'DowngradeNormal'  = { Invoke-DowngradeWithElevation -Method 'Normal' }
    'DowngradeNuclear' = { Invoke-DowngradeWithElevation -Method 'Nuclear' }
}

$actionButtonMap = [ordered]@{
    BtnQuickFix        = 'InstallFix'
    BtnQuickLang       = 'InstallLanguage'
    BtnLaunchBat       = 'LaunchBatch'
    BtnInstallFix      = 'InstallFix'
    BtnRemoveFix       = 'RemoveFix'
    BtnInstallLang     = 'InstallLanguage'
    BtnActiveLang      = 'ActiveLanguage'
    BtnRemoveLang      = 'RemoveLanguage'
    BtnDowngradeNormal = 'DowngradeNormal'
    BtnDowngradeNuclear = 'DowngradeNuclear'
}

foreach ($buttonName in $actionButtonMap.Keys) {
    $actionButton = $window.FindName($buttonName)
    if ($null -eq $actionButton) { continue }
    $actionButton.Tag = $actionButtonMap[$buttonName]
    $actionButton.Add_Click({
        param($sender, $e)
        $map = $global:ActionMap
        if ($null -eq $map) { return }
        $actionKey = [string]$sender.Tag
        if (-not $map.ContainsKey($actionKey)) { return }
        $action = $map[$actionKey]
        if ($null -eq $action) { return }
        Run-Action -Action $action
    })
}

# ==========================================
# GAMES PAGE
# ==========================================
# Update counts from the last "Check all for updates" (key "<game>|<client>").
$global:GameUpdateCounts = @{}

# A small dialog for a secret (the CD key): typed into a password box, never echoed to
# the activity log. Returns '' when cancelled.
function Read-SecretInput {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Title = 'Enter your CD key')
    Add-LogEntry -Text ('? ' + $Prompt) -Color '#606070'
    $dialog = New-Object System.Windows.Window
    $dialog.Title = $Title; $dialog.Width = 520; $dialog.SizeToContent = 'Height'; $dialog.ResizeMode = 'NoResize'
    $dialog.WindowStyle = 'ToolWindow'; $dialog.ShowInTaskbar = $false; $dialog.FontFamily = 'Segoe UI'
    $dialog.Background = Get-ThemeBrush 'PopupBg'
    if (($global:MainWindow -is [System.Windows.Window]) -and $global:MainWindow.IsVisible) { $dialog.Owner = $global:MainWindow; $dialog.WindowStartupLocation = 'CenterOwner' } else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Margin = '24,20,24,18'
    $label = New-Object System.Windows.Controls.TextBlock; $label.Text = $Prompt; $label.TextWrapping = 'Wrap'; $label.FontSize = 14; $label.Margin = '0,0,0,12'; $label.Foreground = Get-ThemeBrush 'TextPrimary'
    $box = New-Object System.Windows.Controls.PasswordBox; $box.FontSize = 14; $box.Padding = '8,6'; $box.MaxLength = 40
    $buttons = New-Object System.Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,16,0,0'
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = 'Save'; $ok.IsDefault = $true; $ok.MinWidth = 90; $ok.Margin = '0,0,10,0'; $ok.Padding = '14,5'
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content = 'Cancel'; $cancel.IsCancel = $true; $cancel.MinWidth = 90; $cancel.Padding = '14,5'
    $style = $global:MainWindow.TryFindResource('DialogPrimaryButton'); if ($style) { $ok.Style = $style }
    $style = $global:MainWindow.TryFindResource('DialogSecondaryButton'); if ($style) { $cancel.Style = $style }
    $global:SecretInputResult = ''
    $ok.Add_Click({ $global:SecretInputResult = $box.Password; $dialog.Close() })
    $cancel.Add_Click({ $global:SecretInputResult = ''; $dialog.Close() })
    $null = $buttons.Children.Add($ok); $null = $buttons.Children.Add($cancel)
    $null = $panel.Children.Add($label); $null = $panel.Children.Add($box); $null = $panel.Children.Add($buttons)
    $dialog.Content = $panel
    $dialog.Add_Loaded({ $null = $box.Focus() })
    $null = $dialog.ShowDialog()
    $value = [string]$global:SecretInputResult; $global:SecretInputResult = ''
    Add-LogEntry -Text $(if ($value) { '> (hidden)' } else { '> (cancelled)' }) -Color '#A0A0B0'
    return $value
}

# Every Games page button runs through here: its Tag says what to do and for which
# game, client or mode. Same no-closure pattern as the other buttons.
$global:GameActionMap = @{
    'steam' = { param($t) $game = Get-CatalogGame -Id $t.Game
        $appId = @($game.SteamAppIds) | Select-Object -First 1
        $url = if ($game.ProjectUrl) { $game.ProjectUrl } else { 'steam://store/' + $appId }
        $web = if ($appId) { 'https://store.steampowered.com/app/' + $appId + '/' } else { $game.ProjectUrl }
        $null = Open-SteamUrl -Url $url -WebFallback $web
        Write-Ok "Opened $url" }
    'folder' = { param($t) $game = Get-CatalogGame -Id $t.Game
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select the $($game.Name) folder"; $dialog.ShowNewFolderButton = [bool]$game.AllowEmptyFolder
        $found = Find-CatalogGame -Game $game; if ($found) { $dialog.SelectedPath = $found.Folder }
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Info 'Folder selection cancelled.'; return }
        $hasGame = Test-CatalogGameFolder -Game $game -Folder $dialog.SelectedPath
        if (-not $hasGame -and -not $game.AllowEmptyFolder) { throw "That folder does not contain $($game.Name): none of $($game.ValidFiles -join ', ') was found there." }
        if (-not $hasGame) { Write-Info "That folder does not have $($game.Name) yet; Install puts its files there." }
        if (Save-CatalogGameFolder -Id $game.Id -Folder $dialog.SelectedPath) { Write-Ok "$($game.Name) folder saved: $($dialog.SelectedPath)" } }
    'install' = { param($t) $null = Install-GameClient -GameId $t.Game -ClientId $t.Client }
    'repair' = { param($t) $game = Get-CatalogGame -Id $t.Game
        $found = Find-CatalogGame -Game $game
        if (-not $found) { throw "$($game.Name) was not found." }
        foreach ($name in (Get-CatalogRepairFiles -Game $game)) {
            $file = Join-Path $found.Folder $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop; Write-Ok "Deleted $name." } else { Write-Info "$name is not there; nothing to delete." }
        }
        Write-Info 'If the black screen stays, start the game once as administrator, or restart the PC (Shield''s FAQ).' }
    'update' = { param($t) $null = Update-GameClient -GameId $t.Game -ClientId $t.Client; $global:GameUpdateCounts.Remove($t.Game + '|' + $t.Client) }
    'remove' = { param($t) $game = Get-CatalogGame -Id $t.Game
        $client = $game.Clients | Where-Object { $_.Id -eq $t.Client } | Select-Object -First 1
        if ((Read-Host "Remove $($client.Name) from $($game.Name)? Its files are deleted and any game file it replaced is put back. [y/N]") -notmatch '^(y|yes)$') { Stop-Cancelled 'Nothing was removed.' }
        Remove-GameClient -GameId $t.Game -ClientId $t.Client }
    'play' = { param($t)
        if ([bool](Get-AppSettings).AutoUpdateClients) {
            $mode = (Get-CatalogGame -Id $t.Game).Modes | Where-Object { $_.Id -eq $t.Mode } | Select-Object -First 1
            $ids = @(@($mode.Clients) | Where-Object { $_ } | Select-Object -Unique)
            if ($ids.Count -gt 0) { $null = Invoke-ClientAutoUpdate -GameId $t.Game -ClientIds $ids }
        }
        $null = Start-CatalogGame -GameId $t.Game -ModeId $t.Mode }
    'exe' = { param($t) $null = Test-GameExecutable -GameId $t.Game }
    'plutologin' = { param($t) Start-PlutoniumLogin }
    'cdkey' = { param($t) $game = Get-CatalogGame -Id $t.Game
        $status = Get-GameCdKeyStatus -GameId $game.Id
        Write-Info "$($game.Name) CD key: $(($status.Values | ForEach-Object { "$($_.Name) $($_.Masked)" }) -join ', ')"
        if ($status.RetailKeyInHklm) { Write-Info 'The game''s own installer already stored a key; it is used as it is.' }
        Write-Host '[1] Enter my CD key'
        Write-Host '[2] Back up the current key'
        Write-Host '[3] Restore a backup'
        Write-Host '[0] Cancel'
        switch (Read-Host 'What would you like to do?') {
            '1' { $key = Read-SecretInput -Prompt "Your $($game.Name) CD key (20 letters and digits, as shown in Steam: right-click the game > Manage > CD Keys)."
                  if (-not $key) { Stop-Cancelled 'No key was entered.' }
                  Set-GameCdKey -GameId $game.Id -Key $key }
            '2' { $null = Backup-GameCdKey -GameId $game.Id }
            '3' { $backups = @(Get-GameCdKeyBackupList -GameId $game.Id)
                  if ($backups.Count -eq 0) { Write-Info 'There are no backups yet.'; return }
                  for ($i = 0; $i -lt $backups.Count; $i++) { Write-Host "[$($i + 1)] $($backups[$i].Name)" }
                  $choice = 0
                  if (-not [int]::TryParse((Read-Host 'Which backup?'), [ref]$choice) -or $choice -lt 1 -or $choice -gt $backups.Count) { Stop-Cancelled 'Nothing was restored.' }
                  Restore-GameCdKey -GameId $game.Id -BackupFile $backups[$choice - 1].FullName }
            default { Stop-Cancelled 'Nothing was changed.' }
        } }
    'checkupdates' = { param($t)
        $global:GameUpdateCounts = @{}
        $checked = 0; $pending = 0
        foreach ($game in Get-GameCatalog) {
            $found = Find-CatalogGame -Game $game
            if (-not $found) { continue }
            foreach ($client in $game.Clients) {
                if (-not (Test-GameClientInstalled -GameFolder $found.Folder -ClientId $client.Id)) { continue }
                try {
                    $count = Get-GameClientUpdateCount -Client $client -GameFolder $found.Folder
                    $global:GameUpdateCounts[$game.Id + '|' + $client.Id] = $count
                    $checked++; if ($count -gt 0) { $pending++ }
                    Write-Info ("{0} - {1}: {2}" -f $game.Name, $client.Name, $(if ($count -gt 0) { "$count file(s) to update" } else { 'up to date' }))
                } catch { Write-Warn "$($game.Name) - $($client.Name): could not check ($($_.Exception.Message))" }
            }
        }
        if ($checked -eq 0) { Write-Info 'No installed clients to check.' } else { Write-Ok "Checked $checked client(s); $pending have updates." }
        $null = Test-AppUpdate }
    'autoupdate' = { param($t) $null = Invoke-ClientAutoUpdate; $null = Test-AppUpdate }
}

# Builds one card per catalogue game from its current state.
function Update-GamesPage {
    $list = $global:MainWindow.FindName('GamesList')
    if ($null -eq $list) { return }
    $list.Children.Clear()
    $cardStyle = $global:MainWindow.TryFindResource('Card')
    $buttonStyle = $global:MainWindow.TryFindResource('SmallButton')
    $text = { param([string]$Value, [string]$Color = 'TextSecondary', [double]$Size = 12.5, [string]$Weight = 'Normal')
        $block = New-Object System.Windows.Controls.TextBlock
        $block.Text = $Value; $block.FontSize = $Size; $block.TextWrapping = 'Wrap'; $block.FontWeight = $Weight
        $block.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Color)
        $block }
    $button = { param([string]$Label, [hashtable]$Tag, [string]$Tip = '', [bool]$Enabled = $true)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Label; $b.Tag = $Tag; $b.Margin = '0,8,8,0'
        if ($buttonStyle) { $b.Style = $buttonStyle }
        if ($Tip) { $b.ToolTip = $Tip }
        $b.IsEnabled = $Enabled
        if (-not $Enabled) { [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true) }
        $b.Add_Click({ param($sender, $e)
            $tag = $sender.Tag
            $action = $global:GameActionMap[[string]$tag.Action]
            if ($null -eq $action) { return }
            Run-Action -Action $action -Arguments @($tag)
            Update-GamesPage })
        $b }
    # One card per game, in release order (oldest first), whatever order the catalogue
    # entries happen to be written in.
    foreach ($game in @(Get-GameCatalog | Sort-Object { [int]$_.Year })) {
        $found = $null
        try { $found = Find-CatalogGame -Game $game } catch { $found = $null }
        $card = New-Object System.Windows.Controls.Border
        if ($cardStyle) { $card.Style = $cardStyle }
        $card.Margin = '0,0,0,12'
        $panel = New-Object System.Windows.Controls.StackPanel
        $header = New-Object System.Windows.Controls.DockPanel
        $state = 'Not found'; $stateColor = 'TextMuted'
        if (-not $game.Available) { $state = 'Not available'; $stateColor = 'Yellow' }
        if ($found) {
            $installed = @($game.Clients | Where-Object { Test-GameClientInstalled -GameFolder $found.Folder -ClientId $_.Id })
            $updates = @($game.Clients | Where-Object { [int]$global:GameUpdateCounts[$game.Id + '|' + $_.Id] -gt 0 })
            if ($updates.Count -gt 0) { $state = 'Update available'; $stateColor = 'Accent' }
            elseif ($installed.Count -gt 0) { $state = 'Client installed'; $stateColor = 'Green' }
            elseif ($game.Available -and (Test-CatalogGameFolder -Game $game -Folder $found.Folder)) { $state = 'Game found'; $stateColor = 'Green' }
            elseif ($game.Available) { $state = 'Folder picked'; $stateColor = 'Accent' }
        }
        $pill = & $text $state $stateColor 12 'SemiBold'
        [System.Windows.Controls.DockPanel]::SetDock($pill, 'Right'); $pill.VerticalAlignment = 'Center'
        $null = $header.Children.Add($pill)
        $null = $header.Children.Add((& $text ("{0}  ({1})" -f $game.Name, $game.Year) 'TextPrimary' 16 'Bold'))
        $null = $panel.Children.Add($header)
        $where = if ($found) { "Folder: $($found.Folder)" } elseif ($game.Detect -in @('folder', 'none')) { 'Not on Steam: pick its folder with Change folder.' } else { 'Not found in your Steam libraries.' }
        $line = & $text $where; $line.Margin = '0,4,0,0'; $null = $panel.Children.Add($line)
        if ($found) {
            foreach ($client in $game.Clients) {
                $isIn = Test-GameClientInstalled -GameFolder $found.Folder -ClientId $client.Id
                $count = $global:GameUpdateCounts[$game.Id + '|' + $client.Id]
                $status = if (-not $isIn) { 'not installed' } elseif ($null -eq $count) { 'installed' } elseif ($count -gt 0) { 'installed, update available' } else { 'installed, up to date' }
                $line = & $text ("{0}: {1}" -f $client.Name, $status) $(if ($isIn) { 'Green' } else { 'TextMuted' }) 12; $line.Margin = '0,3,0,0'; $null = $panel.Children.Add($line)
            }
        }
        if (-not $game.Available) { $line = & $text $game.UnavailableReason 'Yellow' 12; $line.Margin = '0,6,0,0'; $null = $panel.Children.Add($line) }
        elseif ($game.Note) { $line = & $text $game.Note 'TextMuted' 12; $line.Margin = '0,6,0,0'; $null = $panel.Children.Add($line) }
        if ($found -and $game.Available) {
            # Why a Play button is greyed out, in one line, instead of only in a tooltip.
            $blocked = @(foreach ($mode in $game.Modes) {
                $reason = Get-ModeBlocker -Game $game -Mode $mode -GameFolder $found.Folder
                if ($reason) { "$($mode.Label): $reason" }
            })
            if ($blocked.Count -gt 0) {
                $line = & $text ('Not ready: ' + ($blocked -join ' | ')) 'Yellow' 12
                $line.Margin = '0,6,0,0'; $line.TextWrapping = 'Wrap'; $null = $panel.Children.Add($line)
            }
        }

        $buttons = New-Object System.Windows.Controls.WrapPanel
        if (-not $found -and ($game.ProjectUrl -or @($game.SteamAppIds).Count -gt 0)) {
            $null = $buttons.Children.Add((& $button $(if ($game.ProjectUrl) { 'Open project' } else { 'Get on Steam' }) @{ Action = 'steam'; Game = $game.Id }))
        } elseif ($game.ProjectUrl) { $null = $buttons.Children.Add((& $button 'Open project' @{ Action = 'steam'; Game = $game.Id })) }
        $null = $buttons.Children.Add((& $button 'Change folder' @{ Action = 'folder'; Game = $game.Id } 'Pick the game folder yourself'))
        if ($found -and $game.Available) {
            foreach ($client in $game.Clients) {
                if (Test-GameClientInstalled -GameFolder $found.Folder -ClientId $client.Id) {
                    $null = $buttons.Children.Add((& $button "Update $($client.Name)" @{ Action = 'update'; Game = $game.Id; Client = $client.Id }))
                    $null = $buttons.Children.Add((& $button "Remove $($client.Name)" @{ Action = 'remove'; Game = $game.Id; Client = $client.Id }))
                } else {
                    $conflict = @($client.Conflicts | Where-Object { Test-GameClientInstalled -GameFolder $found.Folder -ClientId $_ }) | Select-Object -First 1
                    $need = @($client.Requires | Where-Object { -not (Test-GameClientInstalled -GameFolder $found.Folder -ClientId $_) }) | Select-Object -First 1
                    $tip = if ($conflict) { "Remove $(Get-CatalogClientName $conflict) first: both replace the same files." } elseif ($need) { "Install $(Get-CatalogClientName $need $game) first: this goes on top of it." } elseif ($client.Description) { $client.Description } else { '' }
                    $null = $buttons.Children.Add((& $button "Install $($client.Name)" @{ Action = 'install'; Game = $game.Id; Client = $client.Id } $tip (-not $conflict -and -not $need)))
                }
            }
            if (@($game.Clients | Where-Object { $_.Id -eq 'plutonium' }).Count -gt 0) { $null = $buttons.Children.Add((& $button 'Plutonium login' @{ Action = 'plutologin'; Game = $game.Id } 'Open Plutonium to sign in')) }
            foreach ($mode in $game.Modes) {
                $blocker = Get-ModeBlocker -Game $game -Mode $mode -GameFolder $found.Folder
                $null = $buttons.Children.Add((& $button "Play: $($mode.Label)" @{ Action = 'play'; Game = $game.Id; Mode = $mode.Id } $blocker (-not $blocker)))
            }
            $repairFiles = Get-CatalogRepairFiles -Game $game
            if ($repairFiles.Count -gt 0) { $null = $buttons.Children.Add((& $button 'Repair' @{ Action = 'repair'; Game = $game.Id } ('Fixes a black screen at start: deletes ' + ($repairFiles -join ', ')))) }
        }
        if ($found -and $game.ExeCheck) { $null = $buttons.Children.Add((& $button 'Check game exe' @{ Action = 'exe'; Game = $game.Id } "Check your own $($game.ExeCheck.File)")) }
        if ($game.CdKey) { $null = $buttons.Children.Add((& $button 'CD key' @{ Action = 'cdkey'; Game = $game.Id } 'Your own CD key: view (masked), back up, set or restore')) }
        $null = $panel.Children.Add($buttons)
        $card.Child = $panel
        $null = $list.Children.Add($card)
    }
}

$window.FindName('PlayerNameBox').Text = [string](Get-AppSettings).PlayerName
$window.FindName('BtnSavePlayerName').Add_Click({
    $box = $global:MainWindow.FindName('PlayerNameBox')
    $clean = Get-CleanPlayerName $box.Text
    if (Save-PlayerName $clean) { $box.Text = $clean; Add-LogEntry -Text ('[OK]   Player name saved: ' + $(if ($clean) { $clean } else { '(none)' })) -Color '#4EC9B0' }
})
$window.FindName('BtnGamesRefresh').Add_Click({ Update-GamesPage; Add-LogEntry -Text '[OK]   Games list refreshed.' -Color '#4EC9B0' })
$window.FindName('BtnGamesCheckUpdates').Add_Click({ Run-Action -Action $global:GameActionMap['checkupdates'] -Arguments @(@{}); Update-GamesPage })
# The cards are built when the page is first opened, so detection does not slow startup.
$window.FindName('NavGames').Add_Click({
    if ($global:MainWindow.FindName('GamesList').Children.Count -eq 0) {
        Update-GamesPage
        # The first time the page opens in a session, with Auto-update on.
        if ([bool](Get-AppSettings).AutoUpdateClients -and -not $global:GamesAutoUpdated) {
            $global:GamesAutoUpdated = $true
            Run-Action -Action $global:GameActionMap['autoupdate'] -Arguments @(@{})
            Update-GamesPage
        }
    }
})
function Update-AutoUpdateButton {
    $button = $global:MainWindow.FindName('BtnGamesAutoUpdate')
    if ($null -ne $button) { $button.Content = if ([bool](Get-AppSettings).AutoUpdateClients) { 'Auto-update: on' } else { 'Auto-update: off' } }
}
$window.FindName('BtnGamesAutoUpdate').Add_Click({
    $settings = Get-AppSettings
    $settings.AutoUpdateClients = -not [bool]$settings.AutoUpdateClients
    if (Save-AppSettings -Settings $settings) {
        Update-AutoUpdateButton
        Add-LogEntry -Text ('[OK]   Automatic client updates ' + $(if ($settings.AutoUpdateClients) { 'on: checked when the Games page opens and before Play.' } else { 'off.' })) -Color '#4EC9B0'
    }
})
Update-AutoUpdateButton

# Makes it obvious that this window is the administrator worker, and what it is
# busy with, instead of looking like an ordinary idle session.
function Set-DowngradeRunChrome {
    param([string]$Method = 'Normal')
    try {
        $label = if ($Method -eq 'Nuclear') { 'Nuclear downgrade' } else { 'Normal downgrade' }
        $window.Title = 'Call of Duty MW4 Setup Utility - ' + $label + ' running (Administrator)'
        $banner = $window.FindName('DowngradeRunBanner')
        if ($null -eq $banner) { return }
        $window.FindName('DowngradeRunTitle').Text = $label + ' running'
        $window.FindName('DowngradeRunDetail').Text = if ($Method -eq 'Nuclear') {
            'This is the administrator window. It cleans the Steam folder, reinstalls BetterSteamTools and restarts Steam, so it can take several minutes. Watch the activity log below; do not close this window.'
        } else {
            'This is the administrator window. It closes Steam, writes the version-locked files and asks Steam to validate. Watch the activity log below; do not close this window.'
        }
        $banner.Visibility = 'Visible'
    } catch { }
}

# Finishes the administrator window. The banner reports the result and the log is
# saved automatically, then the window waits for the user to press OK. That press is
# the hand-back: closing this window restores the one that minimized for the UAC
# hand-off, which reports the same outcome. Nothing closes on a timer any more, so a
# finished run cannot vanish while someone is still reading the log.
function Complete-DowngradeRunChrome {
    param([string]$Method = 'Normal', [string]$State = 'Ready')
    try {
        $label = if ($Method -eq 'Nuclear') { 'Nuclear downgrade' } else { 'Normal downgrade' }
        $window.Title = 'Call of Duty MW4 Setup Utility - Administrator'
        if (Test-SandboxMode) { $window.Title += ' [SANDBOX]' }

        $savedPath = $null
        try {
            $logDir = Join-Path (Get-HandoffDirectory) 'logs'
            if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $logDir -Force }
            $savedPath = Join-Path $logDir ('downgrade-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
            [IO.File]::WriteAllText($savedPath, (Get-ReportText), [Text.UTF8Encoding]::new($true))
            # Keep the folder small: only the newest handful of runs are worth keeping.
            $stale = @(Get-ChildItem -LiteralPath $logDir -Filter 'downgrade-*.txt' -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 10)
            foreach ($staleLog in $stale) { try { Remove-Item -LiteralPath $staleLog.FullName -Force -ErrorAction Stop } catch { } }
        } catch { $savedPath = $null }

        $banner = $window.FindName('DowngradeRunBanner')
        if ($null -eq $banner) { return }
        $window.FindName('DowngradeRunTitle').Text = switch ($State) {
            'Failed'    { $label + ' failed' }
            'Cancelled' { $label + ' cancelled' }
            default     { $label + ' finished' }
        }
        $summary = if ($State -eq 'Failed') {
            'The activity log above holds the error and call stack.'
        } elseif ($State -eq 'Cancelled') {
            'Nothing was changed.'
        } else {
            'Every step it took is in the activity log above.'
        }
        if ($savedPath) { $summary += (' Log saved to ' + $savedPath + '.') }
        # Lets the window that comes back report this run instead of guessing.
        Write-LastWorkerResult -Method $Method -State $State -LogPath ([string]$savedPath)

        $banner.Visibility = 'Visible'
        $verb = switch ($State) { 'Failed' { 'failed' } 'Cancelled' { 'cancelled' } default { 'finished' } }
        $window.FindName('DowngradeRunDetail').Text = ($summary + ' Press OK on the message box to close this administrator window.')
        Add-LogEntry -Text ('[OK]   ' + $label + ' ' + $verb + '.') -Color '#4EC9B0'

        # A real dialog, not an inline button: this is the moment the elevated
        # session ends. Its OK closes the window, and closing the window is what
        # wakes the one that minimized for the hand-off.
        $icon = switch ($State) {
            'Failed'    { [System.Windows.MessageBoxImage]::Error }
            'Cancelled' { [System.Windows.MessageBoxImage]::Warning }
            default     { [System.Windows.MessageBoxImage]::Information }
        }
        $prompt = $summary + "`n`nThe window you started from comes back as soon as you close this one."
        # Let the banner and the last log line paint before the dialog covers them.
        try { $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) } catch { }
        [void][System.Windows.MessageBox]::Show($window, $prompt, ($label + ' ' + $verb), [System.Windows.MessageBoxButton]::OK, $icon)
        $global:AllowProgrammaticClose = $true
        $window.Close()
    } catch { }
}

if ($RunDowngradeOnly) {
    # The method travels with the relaunch. It is parked in a global first because
    # the dispatcher block must not depend on the scope it is invoked from.
    $global:RequestedDowngradeMethod = $DowngradeMethod
    # Announce this process so the window that launched it waits for the window, not
    # for whatever handle the elevating shell returned.
    Write-WorkerHandshake -Method $DowngradeMethod
    Show-Page -Index 3 -Force
    Set-DowngradeRunChrome -Method $DowngradeMethod
    # Queued, not Invoked. A Dispatcher.Invoke at Render priority ran the entire
    # downgrade before ShowDialog was reached, so the window only appeared once the
    # work had finished and the run looked silent. InvokeAsync at background
    # priority runs after the window has been laid out and painted.
    $null = $window.Dispatcher.InvokeAsync([Action]{
        $action = {
            param($chosen)
            # Logged inside the action: Run-Action clears the log before it starts.
            Add-LogEntry -Text ('=== ' + $chosen + ' downgrade started in the administrator window ===') -Color '#C586C0'
            Add-LogEntry -Text '    This can take several minutes; the log below updates live.' -Color '#606070'
            # Checked again here (this window may run as another account), then the
            # downloads, and only then is the fix reverted and Steam changed.
            Invoke-PreparedDowngrade -Method $chosen
        }
        $runState = 'Ready'
        try {
            Run-Action -Action $action -Arguments @([string]$global:RequestedDowngradeMethod)
            # Run-Action settles the status pill, so it is the honest result.
            $runState = [string]$global:StatusState
        } catch {
            $runState = 'Failed'
        } finally {
            Complete-DowngradeRunChrome -Method ([string]$global:RequestedDowngradeMethod) -State $runState
        }
    }, [System.Windows.Threading.DispatcherPriority]::Background)
} else {
    Show-Page -Index ([int]$startupSettings.LastPage) -Force
    # Reopened on the Games page: build its cards now (they are otherwise built on the
    # first click of the sidebar entry).
    if ($global:CurrentPage -eq [array]::IndexOf($pages, 'PageGames')) { Update-GamesPage }
    Add-LogEntry -Text 'Ready. Choose an action from the sidebar to begin.' -Color '#606070'
}

# Sandbox mode is impossible to miss: the title says so and the log explains what is
# real (downloads, UAC) and what is fake (Steam, the game, settings).
if (Test-SandboxMode) {
    $window.Title = $window.Title + ' [SANDBOX]'
    Add-LogEntry -Text ('[SANDBOX] Test mode. Steam: ' + (Join-Path $global:SandboxRoot 'Steam') + '  Game: ' + (Join-Path $global:SandboxRoot 'Game')) -Color '#FFD700'
    Add-LogEntry -Text '          Settings, hand-off files and logs stay in the sandbox. Your real Steam and game are not touched; Steam is never closed or started.' -Color '#FFD700'
}

# Handlers created in script scope resolve the script's functions normally, but a
# handler that ends up invoked from an isolated scope cannot (that is what a
# GetNewClosure() scriptblock did to the sidebar). Publishing the shared state and
# the helper functions to the global scope is the cheap safety net, so a handler
# always resolves the same names the script body does.
foreach ($sharedName in @('window', 'ThemePalettes', 'AccentPresets', 'LogColorAliases', 'SettingsFile', 'SettingsDirectory', 'AppId',
                          'pages', 'navButtons', 'titles', 'ZipUrl', 'ZipFileName', 'LuaDownloadUrl', 'ZipDownloadUrl', 'ReleaseTag',
                          'SourceFileName', 'TargetFileName', 'SteamConfigSubPath', 'AppManifestFile', 'codDepotIds')) {
    $sharedValue = Get-Variable -Name $sharedName -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $sharedValue) { Set-Variable -Name $sharedName -Value $sharedValue -Scope Global -Force }
}
# A scope-qualified Set-Item ("Function:\global:Name") does NOT create the
# function globally - it lands in the current scope - so each definition is
# re-declared with an explicit "function global:" prefix, which is the form the
# language routes to the global scope.
foreach ($helper in @(Get-ChildItem -Path Function:)) {
    try {
        $declaration = 'function global:' + $helper.Name + " {`n" + $helper.Definition + "`n}"
        . ([scriptblock]::Create($declaration))
    } catch { }
}

$window.ShowDialog() | Out-Null

# The window is closed: its temp copy is no longer needed. An administrator window
# still running from it has already loaded the script, so deleting it is safe. That
# administrator window never deletes it itself, because the window that started it
# may need it for another downgrade.
if (-not $RunDowngradeOnly -and (Test-IsTempScriptCopy -Path $global:ScriptPath)) {
    Remove-Item -LiteralPath $global:ScriptPath -Force -ErrorAction SilentlyContinue
}
