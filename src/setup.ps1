# ---------------------------------------------------------------------------
#  setup.ps1 - shared by install.ps1, change-tv.ps1 and uninstall.ps1, and the
#  limited-install mode (normal PowerShell window, no admin). The full install is
#  in machine.ps1. build.ps1 copies these files into each published script.
# ---------------------------------------------------------------------------

# ---- Fixed names. NEVER change these: any future uninstaller relies on them.
$RunKeyPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'ATVCompanion'
# ----------------------------------------------------------------------------

$RepoUrl             = 'https://github.com/PDM-27/atv-companion'
$ReleaseUrl          = "$RepoUrl/releases/latest/download"
$PlatformToolsUrl    = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$AdbFiles            = 'adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll', 'NOTICE.txt', 'source.properties'
$StartupApprovedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

# ---- Console helpers ------------------------------------------------------------

function Write-Step { param([string]$Text) Write-Host "  $Text" }
function Write-Ok { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Problem {
    # Every problem message says what happened and what to do next.
    param([string]$What, [string]$Next)
    Write-Host ''
    Write-Host "  $What" -ForegroundColor Yellow
    if ($Next) { Write-Host "  $Next" }
    Write-Host ''
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = "$(Read-Host "  $Question $hint")".Trim().ToLower()
        if ($answer -eq '') { return $Default }
        if ($answer -in 'y', 'yes') { return $true }
        if ($answer -in 'n', 'no') { return $false }
    }
}

function Confirm-Install {
    # Says what is about to happen, shows Google's terms for adb, and asks once.
    param([string]$Heading, [string[]]$Lines, [bool]$Default = $true)
    Write-Host ''
    if ($Heading) { Write-Host "  $Heading" -ForegroundColor Yellow }
    foreach ($line in $Lines) { Write-Step $line }
    Write-Host ''
    Write-Step "It downloads adb (Android platform-tools) from Google; continuing means you accept Google's"
    Write-Step 'terms: https://developer.android.com/studio/terms'
    $agreed = Read-YesNo 'Continue?' $Default
    if (-not $agreed) { Write-Step 'Cancelled. Nothing was changed.' }
    Write-Host ''
    return $agreed
}

function Read-InstalledChoice {
    # "Already installed" menu. Returns 1 (change TV), 2 (reinstall), 3 (uninstall) or 4 (cancel).
    param($Config, [string]$Where)
    $tvText = if ($Config -and $Config.tvIp) { ", using the TV at $($Config.tvIp)" } else { '' }
    Write-Host ''
    Write-Host "  $AppName is already installed $Where$tvText. What would you like to do?"
    Write-Host '    1) Change TV'
    Write-Host '    2) Reinstall or update (keep settings)'
    Write-Host '    3) Uninstall'
    Write-Host '    4) Cancel'
    do { $choice = "$(Read-Host '  Choose 1-4')".Trim() } while ($choice -notin '1', '2', '3', '4')
    if ($choice -eq '4') { Write-Step 'Cancelled. Nothing was changed.' }
    return $choice
}

function Write-CommandList {
    param([switch]$Machine)
    Write-Host ''
    $window = if ($Machine) { 'PowerShell opened as administrator' } else { 'a normal PowerShell window' }
    Write-Step "To change the TV or uninstall later, run one of these in $($window):"
    Write-Host "  Change TV:  irm $ReleaseUrl/change-tv.ps1 | iex"
    Write-Host "  Uninstall:  irm $ReleaseUrl/uninstall.ps1 | iex"
    Write-Host "  Help:       $RepoUrl#faq"
    Write-Host ''
}

# ---- Checks -------------------------------------------------------------------------

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Preflight {
    # Returns $true if this PC and this PowerShell window can run ATV Companion.
    # -Uninstall skips the checks that only matter for running it; -Machine adds the service's needs.
    param([switch]$Uninstall, [switch]$Machine)
    if ($env:OS -ne 'Windows_NT') {
        Write-Problem "$AppName only works on Windows." ''
        return $false
    }
    if ($Uninstall) { return $true }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Problem 'PowerShell is locked down on this PC (Constrained Language Mode), usually by a work or school policy.' `
            "$AppName can't run here. Ask whoever manages this PC, or use a personal PC."
        return $false
    }
    foreach ($scope in 'MachinePolicy', 'UserPolicy') {
        if ((Get-ExecutionPolicy -Scope $scope) -in 'AllSigned', 'Restricted') {
            Write-Problem 'A Group Policy on this PC blocks PowerShell scripts (usually a work or school PC).' `
                "$AppName's background script would not be allowed to start. Ask whoever manages this PC."
            return $false
        }
    }
    if (-not (Test-Path -LiteralPath $WindowsPowerShell)) {
        Write-Problem 'Windows PowerShell 5.1 (powershell.exe) was not found.' 'It is part of Windows; reinstalling or repairing Windows features may restore it.'
        return $false
    }
    if ($Machine -and -not (Get-CscPath)) {
        Write-Problem "The .NET Framework 4 C# compiler (csc.exe), which is part of Windows, was not found." `
            'Turn on ".NET Framework 4.8 Advanced Services" in Windows Features, or install just for your account from a normal PowerShell window.'
        return $false
    }
    # Older Windows PowerShell setups may not offer TLS 1.2 by default; GitHub and Google need it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    return $true
}

function Test-Installed {
    # Is there a complete install at the current paths (see Set-InstallMode)?
    return ((Test-Path -LiteralPath $AdbPath) -and (Test-Path -LiteralPath $WatcherPath) -and $null -ne (Read-Config))
}

# ---- adb download -----------------------------------------------------------------

function Install-Adb {
    # Downloads Google's platform-tools, keeps only the files adb needs, and checks Google's signature.
    $zip = Join-Path $env:TEMP "atvcompanion-platform-tools-$PID.zip"
    $tools = Split-Path -Parent $AdbPath
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow in Windows PowerShell
    try {
        try { Invoke-WebRequest -Uri $PlatformToolsUrl -OutFile $zip -UseBasicParsing }
        catch { throw "couldn't download adb from Google. Check the internet connection. ($($_.Exception.Message))" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            New-Item -ItemType Directory -Force -Path $tools | Out-Null
            foreach ($name in $AdbFiles) {
                $entry = $archive.GetEntry("platform-tools/$name")
                if (-not $entry) { throw "The download doesn't contain $name." }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $tools $name), $true)
            }
        } finally {
            $archive.Dispose()
        }
        $signature = Get-AuthenticodeSignature -FilePath $AdbPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=Google LLC,') {
            Remove-Item -LiteralPath $tools -Recurse -Force
            throw 'The downloaded adb.exe is not signed by Google.'
        }
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

# ---- Choosing and approving the TV ----------------------------------------------------

function Get-HostName {
    # Network names for a list of IPs (looked up together, 1.5 s limit). Returns @{ ip = name }.
    param([string[]]$Ip)
    $names = @{}
    if (-not $Ip) { return $names }
    $lookups = foreach ($address in $Ip) { [pscustomobject]@{ Ip = $address; Task = [System.Net.Dns]::GetHostEntryAsync($address) } }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($lookups.Task), 1500) } catch { $null = $_ }
    foreach ($lookup in $lookups) {
        if ($lookup.Task.Status -eq 'RanToCompletion' -and $lookup.Task.Result.HostName -ne $lookup.Ip) {
            $names[$lookup.Ip] = $lookup.Task.Result.HostName.Split('.')[0]
        }
    }
    return $names
}

function Select-Tv {
    # Finds TVs with network debugging on and lets the user pick one (or type an IP).
    # Returns Ip and Name, or $null if the user quits.
    Write-Step 'Looking for your TV...'
    $networks = @(Get-HomeNetwork)
    $found = @()
    if ($networks) { $found = @(Find-AdbDevice -Prefix24 $networks.Prefix24 -Exclude $networks.LocalIp) }
    $names = Get-HostName $found
    $label = { param($ip) if ($names[$ip]) { "$ip ($($names[$ip]))" } else { $ip } }
    if ($found.Count -eq 1) {
        Write-Step "Found: $(& $label $found[0])"
        $prompt = 'Press Enter to use it, or type a different IP address'
    } elseif ($found.Count -gt 1) {
        Write-Step 'Found these devices:'
        for ($i = 0; $i -lt $found.Count; $i++) { Write-Step ('  {0}) {1}' -f ($i + 1), (& $label $found[$i])) }
        $prompt = 'Type the number of your TV (or its IP address)'
    } else {
        Write-Problem 'No TV was found on your network.' `
            'Check that the TV is on, on the same network as this PC, and has USB debugging turned on (see the README).'
        $prompt = "Type your TV's IP address (in the TV's network settings)"
    }
    while ($true) {
        $answer = "$(Read-Host "  $prompt, or Q to quit")".Trim()
        if ($answer -eq 'q') { Write-Step 'Cancelled.'; return $null }
        if ($answer -eq '' -and $found.Count -eq 1) { $answer = '1' }
        if ($answer -match '^\d{1,3}$' -and [int]$answer -ge 1 -and [int]$answer -le $found.Count) { $ip = $found[[int]$answer - 1] }
        elseif (Test-IPv4 $answer) { $ip = $answer }
        else { Write-Host '  Please type a number from the list or an IP address (like 192.168.1.50).' -ForegroundColor Yellow; continue }
        return [pscustomobject]@{ Ip = $ip; Name = "$($names[$ip])" }
    }
}

function Write-AllowPrompt {
    param([string]$Ip)
    Write-Host "  >> On the TV ($Ip), choose ""Allow"" and tick ""Always allow from this computer""." -ForegroundColor Cyan
}

function Write-NoPermission {
    param([bool]$Reached, [string]$Ip)
    if (-not $Reached) {
        Write-Problem "No TV answered at $Ip." 'Check that the TV is on and that USB debugging is on, or pick a different device.'
    } else {
        Write-Problem "The TV at $Ip didn't say Allow." `
            "If no question appeared on the TV, it may be a different device, or turn USB debugging off and on again on the TV."
    }
}

function Request-TvAuthorization {
    # Just for me: connects with this account's adb key and waits up to 60 s for Allow on the TV.
    param([Parameter(Mandatory)]$Config)
    Write-Step 'Connecting...'
    [void](Start-AdbServer $Config)
    $asked = $false; $reached = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 60) {
        if ((Connect-Tv $Config) -ne 'Failed') {
            $reached = $true
            $state = Get-TvAdbState $Config
            if ($state -eq 'device') { return $true }
            if ($state -eq 'unauthorized' -and -not $asked) { Write-AllowPrompt $Config.tvIp; $asked = $true }
        } elseif (-not $reached -and $timer.Elapsed.TotalSeconds -gt 10) {
            break   # nothing answered for 10 seconds
        }
        Start-Sleep -Seconds 1
    }
    Disconnect-Tv $Config   # a new attempt then shows the question on the TV again
    Write-NoPermission $reached $Config.tvIp
    return $false
}

function Complete-TvConfig {
    # After the TV said Allow: note which TV input this PC is on (so the TV is left alone while it
    # shows something else), and the TV's and router's MAC addresses (to find the TV if its IP changes).
    param([Parameter(Mandatory)]$Config)
    Write-Ok 'Connected to your TV.'
    if ((Set-TvStayAwake $Config) -eq $true) {
        Write-Step 'Turned on the TV''s "Stay awake" developer setting, so it stays reachable in standby.'
    }
    # Whoever runs the installer is almost always looking at the PC on the TV right now.
    $view = Get-TvView $Config
    if ($view.Power -eq 'On' -and $view.Input) {
        $Config.pcApp = $view.App
        $Config.pcInput = $view.Input
        $where = if ($view.HdmiPort) { "HDMI $($view.HdmiPort)" } else { 'current' }
        Write-Step "This PC is on the TV's $where input. If the TV shows something else (an app or another input), it won't be turned off."
    } else {
        $Config.pcApp = ''
        $Config.pcInput = ''
    }
    $Config.tvMac = Get-MacAddress $Config.tvIp
    $network = Get-HomeNetwork | Where-Object { $Config.tvIp.StartsWith($_.Prefix24 + '.') } | Select-Object -First 1
    $Config.gatewayMac = if ($network) { $network.GatewayMac } else { '' }
    return $Config
}

function Set-TvConfig {
    # Choose the TV and get its permission (going back to the list if that fails), then complete
    # the settings. -Machine: the service connects with its own key. Returns the settings, or $null.
    param([Parameter(Mandatory)]$Config, [switch]$Machine)
    while ($true) {
        $tv = Select-Tv
        if (-not $tv) { return $null }
        $Config.tvIp = $tv.Ip
        $Config.tvName = $tv.Name
        $allowed = if ($Machine) { Request-ServiceAuthorization $Config } else { Request-TvAuthorization $Config }
        if ($allowed) { return Complete-TvConfig $Config }
        if (-not (Read-YesNo 'Try again?')) { return $null }
    }
}

# ---- Just for me: starting, stopping, removing --------------------------------------------

function Get-WatcherProcess {
    # The limited-install watcher: powershell.exe whose command line contains our watcher.ps1 path.
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($WatcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Stop-Watcher {
    # Stops the limited-install watcher and its adb server, so files can be replaced or removed.
    param([int]$ServerPort = $ConfigDefaults.adbServerPort)
    foreach ($process in (Get-WatcherProcess)) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $AdbPath) { [void](Invoke-Adb -Arguments @('kill-server') -ServerPort $ServerPort) }
    Get-Process -Name adb -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-Watcher {
    # Adds the sign-in entry (Task Manager > Startup apps) and starts the watcher now with the same command.
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $WatcherPath
    Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value ('"{0}" {1}' -f $WindowsPowerShell, $arguments)
    Start-Process -FilePath $WindowsPowerShell -ArgumentList $arguments -WorkingDirectory $env:USERPROFILE
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-WatcherProcess | Where-Object { $_.CommandLine -match '-Background' }) { return $true }
    }
    return $false
}

function Test-StartupDisabled {
    # True if the user turned the entry off in Task Manager > Startup apps (first byte 3 = disabled).
    $value = (Get-ItemProperty -Path $StartupApprovedPath -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
    return ($value -and $value[0] -eq 3)
}

function Remove-AndroidKey {
    # Only called if our installer created this .android folder. Leaves it if another Android tool uses it now.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $adbOnly = 'adbkey', 'adbkey.pub', 'adb_known_hosts.pb'
    if (Get-ChildItem -LiteralPath $Path -Force | Where-Object { $adbOnly -notcontains $_.Name }) {
        Write-Step "Kept $Path because other Android tools use it too."
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
        Write-Step "Removed this PC's TV key ($Path)."
    }
}

function Remove-Folder {
    # Deletes a folder, retrying while files are still being released. Returns $true if it is gone.
    param([Parameter(Mandatory)][string]$Path)
    if ("$((Get-Location).Path)".StartsWith($Path, [StringComparison]::OrdinalIgnoreCase)) { Set-Location -LiteralPath $env:USERPROFILE }
    for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $Path); $i++) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) { Start-Sleep -Milliseconds 500 }
    }
    return -not (Test-Path -LiteralPath $Path)
}

function Test-UserInstallPresent {
    $hasRunEntry = $null -ne (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue)
    return ((Test-Path -LiteralPath $UserDir) -or $hasRunEntry)
}

function Uninstall-UserInstall {
    # Removes this account's limited install. Safe on a partial or older install, and safe twice.
    . Set-InstallMode
    $config = Read-Config
    $port = if ($config) { $config.adbServerPort } else { $ConfigDefaults.adbServerPort }
    Write-Step 'Removing the limited install...'
    Stop-Watcher -ServerPort $port
    Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $StartupApprovedPath -Name $RunValueName -ErrorAction SilentlyContinue
    if (-not (Remove-Folder $UserDir)) {
        Write-Problem "Couldn't delete $UserDir (a file is still in use)." 'Restart the PC and run the uninstall command again.'
        return $false
    }
    if ($config -and $config.createdAndroidDir) { Remove-AndroidKey -Path (Join-Path $env:USERPROFILE '.android') }
    return $true
}

# ---- Just for me: install and change TV -------------------------------------------------

function Invoke-UserInstall {
    # The limited install: this account only, no administrator rights needed.
    . Set-InstallMode
    if (Test-MachineInstalled) {
        Write-Ok "$AppName (full install) is already on this PC and works for every account. Nothing to do."
        Write-Step 'To change the TV or uninstall, run the change-TV or uninstall command in PowerShell opened as administrator.'
        return
    }
    $config = $null
    if (Test-Path -LiteralPath $UserDir) {
        $config = Read-Config
        switch (Read-InstalledChoice $config '(limited install)') {
            '1' { Invoke-UserChangeTv; return }
            '3' { Invoke-Uninstall; return }
            '4' { return }
        }
        if (-not (Confirm-Install -Lines 'Reinstalling and keeping your settings.')) { return }
    } else {
        $lines = 'It only works for your Windows account and only after you sign in: the TV will not turn',
                 'on for the sign-in screen. For the full install, open PowerShell as administrator and run',
                 'the same command. Use this one only if you have no administrator rights, your antivirus',
                 'blocks Windows services, or you want it for this account only.'
        if (-not (Confirm-Install -Heading 'WARNING: this is the LIMITED install (no administrator rights).' -Lines $lines -Default $false)) { return }
    }

    $androidDirExisted = Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.android')
    if ($config) { Stop-Watcher -ServerPort $config.adbServerPort } else { Stop-Watcher }
    New-Item -ItemType Directory -Force -Path $UserDir | Out-Null
    Write-Host '  Downloading adb from Google...' -NoNewline
    Install-Adb
    Write-Host ' OK' -ForegroundColor Green
    Set-Content -LiteralPath $WatcherPath -Value $WatcherSource -Encoding UTF8

    if ($config -and $config.tvIp) {
        Write-Step "Keeping your settings (TV $($config.tvIp))."
        $config.appVersion = $AppVersion
    } else {
        $config = New-Object PSObject -Property $ConfigDefaults
        $config.createdAndroidDir = -not $androidDirExisted
        Save-Config $config   # saved now so that an uninstall knows whether we created .android
        $config = Set-TvConfig $config
        if (-not $config) {
            [void](Uninstall-UserInstall)
            Write-Step 'Nothing was left behind. Run the install command again when you are ready.'
            return
        }
    }
    Save-Config $config

    Write-Host '  Starting...' -NoNewline
    if (Start-Watcher) {
        Write-Host ' OK' -ForegroundColor Green
    } else {
        Write-Problem "$AppName didn't start." "Sign out and back in. If it still doesn't work, see $RepoUrl#faq"
    }
    if (Test-StartupDisabled) {
        Write-Problem "$AppName is turned off in Task Manager > Startup apps." 'Turn it on there, or it will not start when you sign in.'
    }
    Write-Log "Installed $AppVersion, limited install (TV $($config.tvIp))"
    Write-Host ''
    Write-Ok 'Done. Your TV now follows this PC while you are signed in.'
    Write-CommandList
}

function Invoke-UserChangeTv {
    . Set-InstallMode
    if (-not (Test-Installed)) {
        Write-Problem "$AppName isn't installed (or the install is incomplete)." "To install it, run in PowerShell opened as administrator:  irm $ReleaseUrl/install.ps1 | iex"
        return
    }
    $config = Set-TvConfig (Read-Config)
    if (-not $config) { Write-Step 'Nothing changed; still using the TV at the old address.'; return }
    Save-Config $config
    Write-Log "TV changed to $($config.tvIp)"
    # A running watcher reads the new settings by itself. Start one if none is running.
    if (-not (Get-WatcherProcess)) { [void](Start-Watcher) }
    Write-Host ''
    Write-Ok "Done. $AppName now controls the TV at $($config.tvIp)."
}

# ---- Commands that work for both installs -------------------------------------------------

function Invoke-ChangeTv {
    $admin = Test-Admin
    if (Test-MachineInstalled) {
        if ($admin) { Invoke-MachineChangeTv }
        else {
            Write-Problem "Changing the TV of the full install needs administrator rights." `
                'Open PowerShell as administrator ("Run as administrator") and run the same command.'
        }
    } elseif (-not (Test-UserInstallPresent)) {
        Write-Problem "$AppName isn't installed." "To install it, run in PowerShell opened as administrator:  irm $ReleaseUrl/install.ps1 | iex"
    } elseif ($admin) {
        Write-Problem 'This is the limited install, which belongs to your account.' 'Run the same command in a normal (not administrator) PowerShell window.'
    } else {
        Invoke-UserChangeTv
    }
}

function Invoke-Uninstall {
    $admin = Test-Admin
    $machine = (Test-MachineInstalled) -or (Test-Path -LiteralPath $MachineDir) -or (Test-Path -LiteralPath $MachineDataDir)
    $user = Test-UserInstallPresent
    if (-not $machine -and -not $user) {
        Write-Ok "$AppName isn't installed. Nothing to remove."
        return
    }
    $removed = $false
    if ($machine) {
        if ($admin) { $removed = Uninstall-MachineInstall }
        else {
            Write-Problem 'Removing the full install needs administrator rights.' `
                'Open PowerShell as administrator ("Run as administrator") and run the same command.'
        }
    }
    if ($user) { $removed = (Uninstall-UserInstall) -or $removed }
    if ($removed) {
        Write-Ok "$AppName has been removed."
        Write-Step 'To make the TV forget this PC too: on the TV, Developer options > Revoke USB debugging authorizations.'
        Write-Host ''
    }
}
