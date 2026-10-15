<#
  ATV Companion - installer
  Makes a Google TV / Android TV turn off and on with this PC, like a monitor.

  Full install (recommended) - open PowerShell as administrator and run:
      irm https://github.com/PDM-27/atv-companion/releases/latest/download/install.ps1 | iex
    1. Downloads Google's adb (Android platform-tools) into %ProgramFiles%\ATVCompanion,
       next to the watcher script
    2. Builds the small service program from its source (ATVCompanionService.cs, inside
       this script) with the C# compiler that ships with Windows
    3. Creates the "ATV Companion" Windows service, running as the low-privilege Local
       Service account; settings and log go to %ProgramData%\ATVCompanion
    4. Asks which TV to use, and has you approve the service on the TV
    Works for every Windows account, and at the sign-in screen.

  Limited install - the same command in a normal PowerShell window (no admin rights):
    1. Downloads adb into %LOCALAPPDATA%\ATVCompanion, next to the watcher script
    2. Asks which TV to use, and has you approve this PC on the TV
    3. Adds "ATVCompanion" to your sign-in apps (Task Manager > Startup apps) and starts it
    Works only for your account, and only after you sign in.

  No scheduled tasks, nothing else. Read the full source and README at
  https://github.com/PDM-27/atv-companion
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
#BUILD-EMBED watcher.ps1 $WatcherSource
$WatcherSource = $null   # build.ps1 puts the built watcher here
#BUILD-END
#BUILD-EMBED service.cs $ServiceSource
$ServiceSource = $null   # build.ps1 puts the service program's source here
#BUILD-END

$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host "$AppName $AppVersion installer" -ForegroundColor Cyan
if (-not $WatcherSource) { throw 'This is the source file. Run build.ps1 and use dist\install.ps1.' }
try {
    if (Test-Admin) {
        if (Test-Preflight -Machine) { Invoke-MachineInstall }
    } else {
        if (Test-Preflight) { Invoke-UserInstall }
    }
} catch {
    Write-Problem "Installation stopped: $($_.Exception.Message)" "Run the install command again. If it keeps happening, see $RepoUrl#faq"
}
}
