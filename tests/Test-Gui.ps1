# Starts the real utility and drives its window with Windows UI Automation. Windows
# only, and needs a desktop session (it is not run by CI):
#
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-Gui.ps1
#
# It launches the script the way "irm ... | iex" ends up running it (from a
# %TEMP%\codhq-setup-<guid>.ps1 copy), then checks:
#   - copies left by older runs are cleaned up at startup, recent ones are kept;
#   - every page opens, the theme and accent switch, the log shows the ready line;
#   - closing the window deletes its own temp copy.
# No action button is pressed, so the game and Steam folders are never touched.
# settings.json is backed up first and put back afterwards.

param([int]$TimeoutSeconds = 60)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path '..' 'install.ps1')))
$temp = [IO.Path]::GetTempPath()
$settingsFile = Join-Path $env:LOCALAPPDATA 'CallOfDutyHQ-SetupUtility\settings.json'
$settingsBackup = $null
if (Test-Path -LiteralPath $settingsFile) { $settingsBackup = [IO.File]::ReadAllBytes($settingsFile) }

$failures = [System.Collections.Generic.List[string]]::new()
function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { Write-Output "[PASS] $Name" } else { Write-Output "[FAIL] $Name"; $failures.Add($Name) }
}

$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
function Find-ById {
    param($Root, [string]$Id)
    $Root.FindFirst($TS::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::AutomationIdProperty, $Id))
}
function Invoke-Element {
    param($Element)
    $pattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select(); return }
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle(); return }
    throw "Element $($Element.Current.AutomationId) cannot be clicked."
}
# The sidebar reacts to Click, which UI Automation's Select() does not raise, so the
# sidebar is clicked with the real mouse (the cursor moves while this runs).
if (-not ('CodhqGuiTestMouse' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodhqGuiTestMouse {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); }
}
'@
}
function Click-Element {
    param($Window, $Element)
    [void][CodhqGuiTestMouse]::SetForegroundWindow([IntPtr]$Window.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 150
    $rect = $Element.Current.BoundingRectangle
    [CodhqGuiTestMouse]::Click([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
}
function Get-Text { param($Root, [string]$Id) $e = Find-ById $Root $Id; if ($e) { $e.Current.Name } else { $null } }
function Wait-Until {
    param([scriptblock]$Condition, [int]$Seconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 }
    return [bool](& $Condition)
}

$newName = { 'codhq-setup-' + [guid]::NewGuid().ToString('N') + '.ps1' }
$copy = Join-Path $temp (& $newName)
$stale = Join-Path $temp (& $newName)
$recent = Join-Path $temp (& $newName)
$process = $null
try {
    Copy-Item -LiteralPath $scriptPath -Destination $copy
    Set-Content -LiteralPath $stale -Value '# stale copy'
    (Get-Item -LiteralPath $stale).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Set-Content -LiteralPath $recent -Value '# recent copy'

    $process = Start-Process powershell.exe -PassThru -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$copy`""
    $window = $null
    $found = Wait-Until -Seconds $TimeoutSeconds -Condition {
        $script:window = $AE::RootElement.FindFirst($TS::Children, [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new($AE::ProcessIdProperty, $process.Id),
            [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
        $null -ne $script:window
    }
    Check 'the window opens' $found
    if (-not $found) { throw 'The window never appeared.' }
    Check 'the window title is right' ($window.Current.Name -like 'Call of Duty MW4 Setup Utility*')

    Check 'a copy older than a day is deleted at startup' (Wait-Until { -not (Test-Path -LiteralPath $stale) })
    Check 'a recent copy is kept' (Test-Path -LiteralPath $recent)
    Check 'the running copy is kept' (Test-Path -LiteralPath $copy)

    # Wait for the startup work (game detection, page restore) to finish, otherwise
    # the first click can land before the window is ready for input.
    $readLog = {
        $log = Find-ById $window 'OutputBox'
        $textPattern = $null
        if ($log -and $log.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) { $textPattern.DocumentRange.GetText(-1) } else { '' }
    }
    Check 'the window finishes starting up' (Wait-Until -Seconds $TimeoutSeconds { (& $readLog) -match 'Ready\. Choose an action' })
    Start-Sleep -Milliseconds 500

    $pages = [ordered]@{ NavFixes = 'Fix'; NavLanguages = 'Language'; NavDowngrade = 'Downgrade'; NavOverview = 'Overview' }
    foreach ($nav in $pages.Keys) {
        $button = Find-ById $window $nav
        Check "$nav exists" ($null -ne $button)
        if ($null -eq $button) { continue }
        Click-Element $window $button
        $expected = $pages[$nav]
        Check "$nav opens its page" (Wait-Until -Seconds 5 { (Get-Text $window 'HeaderTitle') -like "*$expected*" })
    }

    $themeBefore = (Find-ById $window 'ThemeToggleIcon').Current.Name
    Invoke-Element (Find-ById $window 'BtnThemeToggle')
    Check 'the theme toggle switches the theme' (Wait-Until -Seconds 5 { (Find-ById $window 'ThemeToggleIcon').Current.Name -ne $themeBefore })
    Invoke-Element (Find-ById $window 'BtnThemeToggle')
    Check 'the theme toggle switches back' (Wait-Until -Seconds 5 { (Find-ById $window 'ThemeToggleIcon').Current.Name -eq $themeBefore })

    Click-Element $window (Find-ById $window 'AccentTeal')
    $accentPattern = (Find-ById $window 'AccentTeal').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    Check 'an accent colour can be picked' ($accentPattern.Current.IsSelected)
    Check 'the picked accent is saved' (Wait-Until -Seconds 5 { try { (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).Accent -eq 'Teal' } catch { $false } })
    Click-Element $window (Find-ById $window 'AccentSteam')

    $log = Find-ById $window 'OutputBox'
    $logText = ''
    $textPattern = $null
    if ($log -and $log.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) { $logText = $textPattern.DocumentRange.GetText(-1) }
    Check 'the activity log shows the ready line' ($logText -match 'Ready\. Choose an action')
    Check 'the activity log has no errors at startup' ($logText -notmatch '\[ERROR\]|Exception')

    $windowPattern = $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    $windowPattern.Close()
    Check 'the app exits when the window is closed' ($process.WaitForExit(15000))
    Check 'closing the window deletes its temp copy' (Wait-Until -Seconds 5 { -not (Test-Path -LiteralPath $copy) })
} catch {
    $failures.Add("unexpected error: $($_.Exception.Message)")
    Write-Output "[FAIL] unexpected error: $($_.Exception.Message)"
} finally {
    if ($process -and -not $process.HasExited) { try { $process.Kill() } catch { } }
    foreach ($leftover in @($copy, $stale, $recent)) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
    if ($null -ne $settingsBackup) { [IO.File]::WriteAllBytes($settingsFile, $settingsBackup) }
    elseif (Test-Path -LiteralPath $settingsFile) { Remove-Item -LiteralPath $settingsFile -Force }
}

if ($failures.Count -gt 0) { Write-Output "$($failures.Count) GUI check(s) failed."; exit 1 }
Write-Output 'All GUI checks passed.'
exit 0
