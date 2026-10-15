<#
  Builds, lints (PSScriptAnalyzer) and tests (Pester 5). Used locally and by GitHub Actions.
  -Release also checks that the version and repo URL are ready to publish for tag $env:GITHUB_REF_NAME.
  Modules are taken from .tools\ if present (see README "Development"), else from the normal module path.
#>
param([switch]$Release)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$localModules = Join-Path $root '.tools'
if (Test-Path -LiteralPath $localModules) { $env:PSModulePath = "$localModules;$env:PSModulePath" }

& (Join-Path $root 'build.ps1')

if ($Release) {
    $core = (Get-Content -Raw -LiteralPath (Join-Path $root 'src\core.ps1')) + (Get-Content -Raw -LiteralPath (Join-Path $root 'src\setup.ps1'))
    if ($core -match "RepoUrl\s*=\s*'[^']*OWNER") { throw 'Set $RepoUrl in src\setup.ps1 before releasing.' }
    $version = [regex]::Match($core, "AppVersion\s*=\s*'([^']+)'").Groups[1].Value
    if ($env:GITHUB_REF_NAME -and $env:GITHUB_REF_NAME -ne "v$version") { throw "Tag $env:GITHUB_REF_NAME does not match AppVersion $version." }
}

Import-Module PSScriptAnalyzer
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
# dist\ holds all of src\, built: lint sees each file the way it actually runs.
$targets = @('dist', 'tools', 'tests', 'build.ps1') | ForEach-Object { Join-Path $root $_ }
$issues = @($targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings })
$issues | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 250 | Write-Host
if ($issues) { throw "PSScriptAnalyzer found $($issues.Count) issue(s)." }
Write-Host 'PSScriptAnalyzer: no issues.'

Import-Module Pester -MinimumVersion 5.0
$result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru -Output Detailed
if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed." }
