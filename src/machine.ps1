# ---------------------------------------------------------------------------
#  machine.ps1 - the full install, used from an administrator PowerShell window.
#  A Windows service (ATVCompanion) runs the same watcher for every account,
#  also at the sign-in screen. It runs as Windows' built-in low-privilege
#  Local Service account, never as SYSTEM or an administrator, with its own
#  identity (NT SERVICE\ATVCompanion) for file permissions.
# ---------------------------------------------------------------------------

$ServiceExePath         = Join-Path $MachineDir 'ATVCompanionService.exe'
$ServiceCodePath        = Join-Path $MachineDir 'ATVCompanionService.cs'
$ServiceAccount         = 'NT AUTHORITY\LocalService'
$ServiceIdentity        = "NT SERVICE\$ServiceName"
$MachineAdbServerPort   = 15038   # the service's own adb server, separate from limited installs
$LocalServiceAndroidDir = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\.android'   # where the service's adb key lives

function Get-CscPath {
    # The C# compiler that ships with Windows (.NET Framework 4), or $null.
    foreach ($framework in 'Framework64', 'Framework') {
        $csc = Join-Path $env:SystemRoot "Microsoft.NET\$framework\v4.0.30319\csc.exe"
        if (Test-Path -LiteralPath $csc) { return $csc }
    }
    return $null
}

function Test-MachineInstalled { return $null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) }

function Stop-TvService {
    # Stops the service (which stops its watcher) and the service's adb server.
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch { $null = $_ }
    }
    Get-Process -Name adb -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($MachineDir, [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Install-TvService {
    # Builds the service program from its source with the C# compiler that ships with Windows
    # (the source stays next to it, so anyone can read what runs), then creates or updates the service.
    Set-Content -LiteralPath $ServiceCodePath -Value $ServiceSource -Encoding UTF8
    $output = & (Get-CscPath) /nologo /target:exe /optimize+ "/out:$ServiceExePath" $ServiceCodePath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Couldn't build the service program: $($output -join ' ')" }
    $binary = '"{0}"' -f $ServiceExePath
    if (-not (Test-MachineInstalled)) {
        New-Service -Name $ServiceName -BinaryPathName $binary -DisplayName $AppName -StartupType Automatic `
            -Description "Keeps the TV in step with this PC (sleep, wake, display, shutdown). $RepoUrl" | Out-Null
    }
    # Run as Windows' built-in low-privilege Local Service account, never SYSTEM.
    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{ PathName = $binary; StartName = $ServiceAccount; StartPassword = '' }
    if ($result.ReturnValue -ne 0) { throw "Couldn't configure the service (error $($result.ReturnValue))." }
    # Give it its own identity for file permissions, and have Windows restart it if it ever crashes.
    [void](& sc.exe sidtype $ServiceName unrestricted)
    [void](& sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000)
    # Program folder: the service may read it. Settings folder: only administrators and the
    # service itself may change it; other accounts may read it.
    [void](& icacls.exe $MachineDir /grant "$($ServiceIdentity):(OI)(CI)RX")
    New-Item -ItemType Directory -Force -Path $MachineDataDir | Out-Null
    [void](& icacls.exe $MachineDataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "$($ServiceIdentity):(OI)(CI)M" '*S-1-5-32-545:(OI)(CI)RX')
}

function Request-ServiceAuthorization {
    # Full install: the service connects to the TV with its own adb key. Save the TV, restart the
    # service so it connects, and wait up to 90 s for Allow on the TV.
    param([Parameter(Mandatory)]$Config)
    Save-Config $Config
    Restart-Service -Name $ServiceName -Force   # (also starts it)
    Write-Step 'Connecting...'
    $asked = $false; $reached = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 90) {
        $state = Get-TvAdbState $Config   # asks the service's adb server; never starts one of our own
        if ($state -eq 'device') { return $true }
        if ($state -eq 'unauthorized') {
            $reached = $true
            if (-not $asked) { Write-AllowPrompt $Config.tvIp; $asked = $true }
        } elseif (-not $reached -and $timer.Elapsed.TotalSeconds -gt 30) {
            break   # the service couldn't reach the TV for 30 seconds
        }
        Start-Sleep -Seconds 1
    }
    Write-NoPermission $reached $Config.tvIp
    return $false
}

function Uninstall-MachineInstall {
    # Removes the full install: service, program and settings folders, and the service's
    # adb key if we created it. Safe on a partial install, and safe twice. Returns $true on success.
    . Set-InstallMode -Machine
    $config = Read-Config
    Write-Step 'Removing the full install (Windows service)...'
    Stop-TvService
    if (Test-MachineInstalled) { [void](& sc.exe delete $ServiceName) }
    $ok = $true
    foreach ($folder in $MachineDir, $MachineDataDir) {
        if (-not (Remove-Folder $folder)) {
            Write-Problem "Couldn't delete $folder (a file is still in use)." 'Restart the PC and run the uninstall command again.'
            $ok = $false
        }
    }
    if ($config -and $config.createdAndroidDir) { Remove-AndroidKey -Path $LocalServiceAndroidDir }
    return $ok
}

function Invoke-MachineInstall {
    . Set-InstallMode -Machine
    $config = $null
    if (Test-MachineInstalled) {
        $config = Read-Config
        switch (Read-InstalledChoice $config '(full install)') {
            '1' { Invoke-MachineChangeTv; return }
            '3' { Invoke-Uninstall; return }
            '4' { return }
        }
        if (-not (Confirm-Install -Lines 'Reinstalling and keeping your settings.')) { return }
    } else {
        $lines = "Installs $AppName for the whole PC: it works for every Windows account and even at the",
                 'sign-in screen, so your Android TV acts like a real monitor. It runs as a Windows service',
                 "under the low-privilege Local Service account, not as an administrator."
        if (Test-UserInstallPresent) { $lines += 'It replaces the limited install on this account.' }
        if (-not (Confirm-Install -Lines $lines)) { return }
    }

    $androidDirExisted = Test-Path -LiteralPath $LocalServiceAndroidDir
    Stop-TvService
    New-Item -ItemType Directory -Force -Path $MachineDir | Out-Null
    Write-Host '  Downloading adb from Google...' -NoNewline
    Install-Adb
    Write-Host ' OK' -ForegroundColor Green
    Set-Content -LiteralPath $WatcherPath -Value $WatcherSource -Encoding UTF8
    Write-Host '  Setting up the Windows service...' -NoNewline
    Install-TvService
    Write-Host ' OK' -ForegroundColor Green

    if ($config -and $config.tvIp) {
        Write-Step "Keeping your settings (TV $($config.tvIp))."
        $config.appVersion = $AppVersion
        Save-Config $config
        Start-Service -Name $ServiceName
    } else {
        $config = New-Object PSObject -Property $ConfigDefaults
        $config.adbServerPort = $MachineAdbServerPort
        $config.createdAndroidDir = -not $androidDirExisted
        $config = Set-TvConfig $config -Machine
        if (-not $config) {
            [void](Uninstall-MachineInstall)
            Write-Step 'Nothing was left behind. Run the install command again when you are ready.'
            return
        }
        Save-Config $config
    }

    # The service now does the job for every account, so this account's limited install isn't needed.
    if (Test-UserInstallPresent) { [void](Uninstall-UserInstall) }
    Write-Log "Installed $AppVersion, full install (TV $($config.tvIp))"
    Write-Host ''
    Write-Ok 'Done. Your TV now follows this PC, for every account and at the sign-in screen.'
    Write-CommandList -Machine
}

function Invoke-MachineChangeTv {
    . Set-InstallMode -Machine
    $old = Read-Config
    if (-not $old) {
        Write-Problem "The full install is incomplete." 'Run the install command again in this window and choose "Reinstall".'
        return
    }
    $config = Set-TvConfig (Read-Config) -Machine
    if (-not $config) {
        Save-Config $old   # put the previous TV back
        Restart-Service -Name $ServiceName -Force
        Write-Step 'Nothing changed; still using the TV at the old address.'
        return
    }
    Save-Config $config
    Write-Log "TV changed to $($config.tvIp)"
    Write-Host ''
    Write-Ok "Done. $AppName now controls the TV at $($config.tvIp)."
}
