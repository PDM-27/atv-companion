<#
  ATV Companion - change TV
  Points an existing ATV Companion install at a different TV (or the same TV at a new address).

  Run it in the same kind of PowerShell window you installed with: as administrator for the
  full install, a normal window for the limited install.
      irm https://github.com/PDM-27/atv-companion/releases/latest/download/change-tv.ps1 | iex

  It only updates ATV Companion's config.json (and restarts the service for the full install).
  Source: https://github.com/PDM-27/atv-companion
#>
& {
#BUILD-INLINE core.ps1
. (Join-Path $PSScriptRoot 'core.ps1')
#BUILD-END
#BUILD-INLINE setup.ps1
. (Join-Path $PSScriptRoot 'setup.ps1')
#BUILD-END
#BUILD-INLINE machine.ps1
. (Join-Path $PSScriptRoot 'machine.ps1')
#BUILD-END

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host "$AppName - change TV" -ForegroundColor Cyan
if (-not (Test-Preflight)) { return }
try {
    Invoke-ChangeTv
} catch {
    Write-Problem "Stopped: $($_.Exception.Message)" "Run the command again. If it keeps happening, see $RepoUrl#faq"
}
}
