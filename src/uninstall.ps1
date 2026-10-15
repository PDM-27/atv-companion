<#
  ATV Companion - uninstaller
  Removes ATV Companion completely. Safe to run more than once, and on old or partial installs.

      irm https://github.com/PDM-27/atv-companion/releases/latest/download/uninstall.ps1 | iex

  In a normal PowerShell window it removes your limited install: the running watcher, its
  adb server, the "ATVCompanion" sign-in entry, %LOCALAPPDATA%\ATVCompanion, and
  %USERPROFILE%\.android only if the installer created it and no other Android tool uses it.
  In an administrator window it also removes the full install: the "ATV Companion" service,
  %ProgramFiles%\ATVCompanion, %ProgramData%\ATVCompanion, and the service's adb key if the
  installer created it. Source: https://github.com/PDM-27/atv-companion
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
Write-Host "$AppName uninstaller" -ForegroundColor Cyan
if (-not (Test-Preflight -Uninstall)) { return }
try {
    if (Read-YesNo "Remove $AppName from this PC?") { Invoke-Uninstall } else { Write-Step 'Cancelled. Nothing was changed.' }
} catch {
    Write-Problem "Stopped: $($_.Exception.Message)" "Run the command again. If it keeps happening, see $RepoUrl#faq"
}
}
