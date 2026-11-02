# Loads the functions and configuration of install.ps1 into the caller's scope
# without running it: no bootstrap relaunch, no console hiding, no window. Dot-source
# it from a test file ( . "$PSScriptRoot\Import-InstallScript.ps1" ).
#
# The GUI replacements for Write-Host, Write-Warning, Write-Progress and Read-Host
# are left out, so tests get the normal cmdlets and can mock them.

$InstallScriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path '..' 'install.ps1')))

$parseTokens = $null
$parseErrors = $null
$installAst = [System.Management.Automation.Language.Parser]::ParseFile($InstallScriptPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "install.ps1 does not parse: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))" }

$guiOverrides = @('Write-Host', 'Write-Warning', 'Write-Progress', 'Read-Host')
foreach ($statement in $installAst.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $guiOverrides -notcontains $statement.Name) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

# $SettingsDirectory is built from LOCALAPPDATA and work folders from TEMP, which
# Linux does not set.
if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { $env:LOCALAPPDATA = [IO.Path]::GetTempPath() }
if ([string]::IsNullOrEmpty($env:TEMP)) { $env:TEMP = [IO.Path]::GetTempPath().TrimEnd('/', '\') }

# Top-level configuration the functions read. Evaluated after the functions, because
# $LanguagePacks calls ConvertFrom-UnicodeEscape.
$configNames = @(
    'AppVersion', 'ScriptRawUrl', 'AppId', 'ReleaseTag', 'ZipFileName', 'ZipUrl', 'LuaDownloadUrl', 'ZipDownloadUrl',
    'TargetFileName', 'SourceFileName', 'SteamConfigSubPath', 'AppManifestFile', 'SettingsDirectory', 'SettingsFile',
    'ThemePalettes', 'AccentPresets', 'codDepotIds', 'LogColorAliases', 'LanguagePacks'
)
foreach ($statement in $installAst.EndBlock.Statements) {
    if ($statement -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
    $left = $statement.Left
    if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
    if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and $configNames -contains $left.VariablePath.UserPath) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

# Never let a test touch the real settings of someone running the suite on their PC.
$SettingsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('codhq-tests-settings-' + [guid]::NewGuid().ToString('N'))
$SettingsFile = Join-Path $SettingsDirectory 'settings.json'

# Pure ASCII without a byte-order mark is a hard requirement (see the README), so the
# raw bytes are exposed for the tests that check it.
$InstallScriptBytes = [IO.File]::ReadAllBytes($InstallScriptPath)
