# Checks that the window layout in install.ps1 loads in WPF, and that every control
# the script looks up by name exists in it. Windows only, and WPF needs an STA thread:
#
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-Xaml.ps1
#
# Nothing is shown on screen: the window is created but never opened.

$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run this with -STA: WPF needs an STA thread.' }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path '..' 'install.ps1')))
$scriptText = [IO.File]::ReadAllText($scriptPath)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

$xamlAssignment = $ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -match '\$xaml$'
} | Select-Object -First 1
if ($null -eq $xamlAssignment) { throw 'Could not find the $xaml assignment in install.ps1.' }
. ([scriptblock]::Create($xamlAssignment.Extent.Text))

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
Write-Output "Window layout loaded: '$($window.Title)'"

# Names the script looks up: FindName('X') calls, plus the button/page name lists it
# loops over (Btn*, Nav*, Page*, LogFilter*). Only the code is scanned, not the XAML
# itself, whose style keys and group names look the same but are not controls.
$codeText = $scriptText.Remove($xamlAssignment.Extent.StartOffset, $xamlAssignment.Extent.EndOffset - $xamlAssignment.Extent.StartOffset)
$names = [System.Collections.Generic.SortedSet[string]]::new()
foreach ($match in [regex]::Matches($codeText, 'FindName\(\s*[''"](\w+)[''"]\s*\)')) { [void]$names.Add($match.Groups[1].Value) }
foreach ($match in [regex]::Matches($codeText, '[''"]((?:Btn|Nav|Page|LogFilter)[A-Z]\w*)[''"]')) { [void]$names.Add($match.Groups[1].Value) }
foreach ($match in [regex]::Matches($codeText, '\b(Accent(?:Steam|Teal|Violet|Amber|Crimson))\s*=')) { [void]$names.Add($match.Groups[1].Value) }

$missing = @($names | Where-Object { $null -eq $window.FindName($_) })
Write-Output "Checked $($names.Count) control names."
if ($missing.Count -gt 0) {
    foreach ($name in $missing) {
        $message = "The script looks up a control that is not in the window layout: $name"
        if ($env:GITHUB_ACTIONS -eq 'true') { Write-Output "::error file=install.ps1,title=Missing control::$message" } else { Write-Output $message }
    }
    exit 1
}
Write-Output 'Every control the script uses exists.'
exit 0
