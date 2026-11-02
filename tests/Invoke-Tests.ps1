# Runs the Pester tests for install.ps1. Works in Windows PowerShell 5.1 and in
# PowerShell 7, on Windows or Linux:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
#
# Needs Pester 5 (Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
# -SkipPublisherCheck). Exits 1 when a test fails. Under GitHub Actions every
# failure is also written as an annotation, so it shows up on the run summary.

param([string]$Output = 'Detailed')

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'install.Tests.ps1'
$config.Run.PassThru = $true
$config.Output.Verbosity = $Output
$result = Invoke-Pester -Configuration $config

$shell = "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
if ($env:GITHUB_ACTIONS -eq 'true') {
    foreach ($test in $result.Failed) {
        $message = if ($test.ErrorRecord.Count -gt 0) { [string]$test.ErrorRecord[0].Exception.Message } else { 'failed' }
        # Workflow commands are one line; encode line breaks the way Actions expects.
        $message = $message.Replace('%', '%25').Replace("`r", '').Replace("`n", '%0A')
        $line = if ($test.ScriptBlock) { $test.ScriptBlock.StartPosition.StartLine } else { 1 }
        Write-Output "::error file=tests/install.Tests.ps1,line=$line,title=$shell - $($test.ExpandedPath)::$message"
    }
}

Write-Output "$shell - passed: $($result.PassedCount), failed: $($result.FailedCount), skipped: $($result.SkippedCount)"
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
