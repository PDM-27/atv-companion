# ---------------------------------------------------------------------------
#  core.ps1 - shared by the watcher and the install / change-tv / uninstall
#  scripts. build.ps1 copies this file into each published script, so every
#  published file is self-contained.
# ---------------------------------------------------------------------------

# ---- Fixed names. NEVER change these: any future uninstaller relies on them.
# (The sign-in entry's name is fixed too; see setup.ps1.)
$AppName        = 'ATV Companion'
$AppVersion     = '1.0.0'
$UserDir        = Join-Path $env:LOCALAPPDATA 'ATVCompanion'   # just for me: program and settings
$MachineDir     = Join-Path $env:ProgramFiles 'ATVCompanion'   # full install: program (only admins can change it)
$MachineDataDir = Join-Path $env:ProgramData 'ATVCompanion'    # full install: settings and log
$ServiceName    = 'ATVCompanion'                               # full install: the Windows service
# ----------------------------------------------------------------------------

$LogMaxBytes          = 256KB
$WindowsPowerShell    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TvAdbPort            = 5555

function Set-InstallMode {
    # Points every path at the limited install (default) or the full install (-Machine).
    # Dot-source it (". Set-InstallMode -Machine") so the paths are set in the caller's scope.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
        Justification = 'Dot-sourced on purpose: the assignments set variables in the calling scope.')]
    param([switch]$Machine)
    $InstallDir       = if ($Machine) { $MachineDir } else { $UserDir }
    $DataDir          = if ($Machine) { $MachineDataDir } else { $UserDir }
    $ConfigPath       = Join-Path $DataDir 'config.json'
    $LogPath          = Join-Path $DataDir 'log.txt'
    $LogOldPath       = Join-Path $DataDir 'log.old.txt'
    $AdbServerLogPath = Join-Path $DataDir 'adb-server.log'
    $AdbPath          = Join-Path $InstallDir 'platform-tools\adb.exe'
    $WatcherPath      = Join-Path $InstallDir 'watcher.ps1'
}
. Set-InstallMode

# Settings with their defaults. Older config files get any missing ones filled in.
$ConfigDefaults = [ordered]@{
    configVersion         = 1
    appVersion            = $AppVersion
    tvIp                  = ''
    tvName                = ''
    tvMac                 = ''      # used to find the TV again if its IP address changes
    gatewayMac            = ''      # the home router; we only search for the TV on that network
    pcApp                 = ''      # what the TV reports while showing this PC (app and input)
    pcInput               = ''
    adbServerPort         = 15037   # our own adb server port, so we never clash with other adb tools
    followDisplay         = $true   # TV off/on when Windows turns the display off/on
    leaveTvAloneWhenInUse = $true   # don't turn the TV off while it shows something else
    keepTvReachable       = $true   # keep the TV's 'Stay awake' setting on (see Set-TvStayAwake)
    createdAndroidDir     = $false  # true only if WE created %USERPROFILE%\.android
}

function Write-Log {
    # Appends a timestamped line to log.txt. Keeps at most ~2 x 256 KB. Never throws.
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $DataDir)) { return }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt $LogMaxBytes) {
            Move-Item -LiteralPath $LogPath -Destination $LogOldPath -Force
        }
        Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message) -Encoding UTF8
    } catch {
        $null = $_  # logging must never break anything
    }
}

function Read-Config {
    # Returns the settings object, or $null if there is no readable config file.
    param([string]$Path = $ConfigPath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $config) { return $null }
    foreach ($key in $ConfigDefaults.Keys) {
        if (-not $config.PSObject.Properties[$key]) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $ConfigDefaults[$key]
        }
    }
    return $config
}

function Save-Config {
    # Writes to a temporary file first, then swaps it in, so a half-written file is never read.
    param([Parameter(Mandatory)]$Config, [string]$Path = $ConfigPath)
    $temp = "$Path.tmp"
    $Config | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Test-IPv4 {
    # True for a normal dotted IPv4 address such as 192.168.1.20.
    param([string]$Text)
    $octet = '(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
    if ($Text -notmatch "^$octet(\.$octet){3}$") { return $false }
    $first = [int]($Text.Split('.')[0])
    return ($first -ge 1 -and $first -le 223 -and $first -ne 127)
}

# ---- adb ------------------------------------------------------------------

function Invoke-Adb {
    # Runs our own adb.exe against our own adb server port, with a time limit.
    # Returns ExitCode, Output (stdout and stderr together) and TimedOut.
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$ServerPort = $ConfigDefaults.adbServerPort, [int]$TimeoutMs = 5000)
    if (-not (Test-Path -LiteralPath $AdbPath)) {
        return [pscustomobject]@{ ExitCode = -1; Output = 'adb.exe is missing'; TimedOut = $false }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AdbPath
    $psi.Arguments = (@('-P', $ServerPort) + $Arguments) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['ANDROID_ADB_LOG_PATH'] = $AdbServerLogPath  # keep adb's own log in our folder
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill() } catch { $null = $_ }
        return [pscustomobject]@{ ExitCode = -1; Output = 'timed out'; TimedOut = $true }
    }
    [void]$stdout.Wait(1000); [void]$stderr.Wait(1000)
    $text = ''
    if ($stdout.IsCompleted) { $text += $stdout.Result }
    if ($stderr.IsCompleted) { $text += "`n" + $stderr.Result }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $text.Trim(); TimedOut = $false }
}

function ConvertFrom-AdbConnect {
    # Reads the answer to a connect request ("adb connect"). Returns Connected, Unauthorized or Failed.
    param([string]$Text)
    if ($Text -match '(?m)^(already )?connected to ') { return 'Connected' }
    if ($Text -match 'failed to authenticate') { return 'Unauthorized' }
    return 'Failed'
}

function ConvertFrom-AdbState {
    # Reads the answer to a get-state request. Returns device, unauthorized, offline or missing.
    param([string]$Text)
    if ($Text -match '(?m)^device\s*$') { return 'device' }
    if ($Text -match 'unauthorized') { return 'unauthorized' }
    if ($Text -match 'offline') { return 'offline' }
    return 'missing'
}

function ConvertFrom-TvView {
    # Reads the combined output of the dumpsys commands in Get-TvView.
    # Power: On (Awake or Dreaming = screensaver), Off (Asleep or Dozing), or Unknown.
    # App:   the app in front, e.g. com.tcl.tv/com.tcl.player.TVActivity
    # Input: the TV input being shown, e.g. com.tcl.tvinput/.TvPassThroughService/HW15
    param([string]$Text)
    $power = 'Unknown'
    if ($Text -match 'mWakefulness=(\w+)') {
        switch ($Matches[1]) {
            'Awake'    { $power = 'On' }
            'Dreaming' { $power = 'On' }
            'Asleep'   { $power = 'Off' }
            'Dozing'   { $power = 'Off' }
        }
    }
    $app = ''
    if ($Text -match 'mFocusedApp=ActivityRecord\{\S+ u\d+ ([\w.]+/[\w.$]+)') { $app = $Matches[1] }

    # dumpsys tv_input lists sessions as "<token>: ...SessionState@..." followed by "inputId: ...",
    # and names the one on screen as "mainSessionToken: <token>".
    $inputs = @{}; $token = $null; $main = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(\S+): \S*SessionState@') { $token = $Matches[1] }
        elseif ($line -match '^\s*inputId: (\S+)' -and $token) { $inputs[$token] = $Matches[1]; $token = $null }
        elseif ($line -match '^\s*mainSessionToken: (\S+)') { $main = $Matches[1] }
    }
    $tvInput = ''
    if ($main -and $inputs.ContainsKey($main)) { $tvInput = $inputs[$main] }
    elseif ($inputs.Count -eq 1) { $tvInput = @($inputs.Values)[0] }
    # A hardware input ends in HW<id>; the TV lists "id=<id>, ... hdmi_port=<n>" for it.
    $hdmi = ''
    if ($tvInput -match 'HW(\d+)$' -and $Text -match "id=$($Matches[1]),[^}]*hdmi_port=(\d+)") { $hdmi = $Matches[1] }
    return [pscustomobject]@{ Power = $power; App = $app; Input = $tvInput; HdmiPort = $hdmi }
}

function Test-ShowingPc {
    # Is the TV showing this PC? Yes, No, or Unknown (TV can't tell us, or we never learned the PC's input).
    param([Parameter(Mandatory)]$View, [Parameter(Mandatory)]$Config)
    if (-not $Config.pcApp -or $View.Power -ne 'On' -or -not $View.App) { return 'Unknown' }
    if (($View.App -split '/')[0] -ne ($Config.pcApp -split '/')[0]) { return 'No' }
    if ($Config.pcInput -and $View.Input -and $View.Input -ne $Config.pcInput) { return 'No' }
    return 'Yes'
}

function Get-TvTarget { param($Config) return '{0}:{1}' -f $Config.tvIp, $TvAdbPort }

# ---- Talking to our adb server directly -------------------------------------------
# adb.exe is only a messenger: it connects to the adb server on a local port and sends
# short text requests. We send the same requests from this process. That is faster, and it
# keeps working during shutdown, when Windows no longer lets new programs (adb.exe) start.
# adb.exe is still used to start the server itself.

function ConvertTo-AdbRequest {
    # adb's request format: the text's length as 4 hex digits, then the text.
    param([string]$Text)
    return ('{0:X4}{1}' -f $Text.Length, $Text)
}

function Read-AdbData {
    param([Parameter(Mandatory)]$Stream, [int]$Count)
    $buffer = New-Object byte[] $Count
    $got = 0
    while ($got -lt $Count) {
        $read = $Stream.Read($buffer, $got, $Count - $got)
        if ($read -le 0) { throw 'the adb server closed the connection' }
        $got += $read
    }
    return [System.Text.Encoding]::UTF8.GetString($buffer)
}

function Send-AdbRequest {
    # Sends one request. The server answers OKAY, or FAIL plus its reason (which we throw).
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes((ConvertTo-AdbRequest $Text))
    $Stream.Write($bytes, 0, $bytes.Length)
    if ((Read-AdbData $Stream 4) -ne 'OKAY') {
        throw (Read-AdbData $Stream ([Convert]::ToInt32((Read-AdbData $Stream 4), 16)))
    }
}

function Invoke-AdbServer {
    # Sends -Request to our adb server and returns its answer, or with -Shell switches to the TV
    # and runs that command there, returning its output. Never throws. Returns:
    #   Ok (it worked), Text (answer, output, or the reason it failed), ServerDown (no adb server).
    param([Parameter(Mandatory)]$Config, [string]$Request, [string]$Shell, [int]$TimeoutMs = 5000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.SendTimeout = $TimeoutMs
        $client.ReceiveTimeout = $TimeoutMs
        try {
            $client.Connect('127.0.0.1', [int]$Config.adbServerPort)
        } catch {
            return [pscustomobject]@{ Ok = $false; Text = 'the adb server is not running'; ServerDown = $true }
        }
        $stream = $client.GetStream()
        if ($Shell) {
            Send-AdbRequest $stream ('host:transport:' + (Get-TvTarget $Config))
            Send-AdbRequest $stream "shell:$Shell"
            $output = (New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)).ReadToEnd()   # until the command ends
            return [pscustomobject]@{ Ok = $true; Text = $output; ServerDown = $false }
        }
        Send-AdbRequest $stream $Request
        $answer = Read-AdbData $stream ([Convert]::ToInt32((Read-AdbData $stream 4), 16))
        return [pscustomobject]@{ Ok = $true; Text = $answer; ServerDown = $false }
    } catch {
        return [pscustomobject]@{ Ok = $false; Text = "$($_.Exception.Message)"; ServerDown = $false }
    } finally {
        $client.Close()
    }
}

function Start-AdbServer {
    # Starts our adb server (adb.exe) if it isn't running yet.
    param([Parameter(Mandatory)]$Config)
    return Invoke-Adb -Arguments @('start-server') -ServerPort $Config.adbServerPort -TimeoutMs 15000
}

function Connect-Tv {
    # Returns Connected, Unauthorized or Failed.
    param([Parameter(Mandatory)]$Config, [int]$TimeoutMs = 4000)
    $request = 'host:connect:' + (Get-TvTarget $Config)
    $result = Invoke-AdbServer -Config $Config -Request $request -TimeoutMs $TimeoutMs
    if ($result.ServerDown) {
        [void](Start-AdbServer $Config)
        $result = Invoke-AdbServer -Config $Config -Request $request -TimeoutMs $TimeoutMs
    }
    return ConvertFrom-AdbConnect $result.Text
}

function Disconnect-Tv {
    # Drops the adb connection to the TV, e.g. one that died while the PC slept.
    param([Parameter(Mandatory)]$Config)
    [void](Invoke-AdbServer -Config $Config -Request ('host:disconnect:' + (Get-TvTarget $Config)) -TimeoutMs 2000)
}

function Get-TvAdbState {
    # device (ready), unauthorized (waiting for Allow on the TV), offline or missing.
    param([Parameter(Mandatory)]$Config)
    $result = Invoke-AdbServer -Config $Config -Request ('host-serial:' + (Get-TvTarget $Config) + ':get-state')
    return ConvertFrom-AdbState $result.Text
}

function Send-TvKey {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$KeyCode, [int]$TimeoutMs = 5000)
    return (Invoke-AdbServer -Config $Config -Shell "input keyevent $KeyCode" -TimeoutMs $TimeoutMs).Ok
}

function Set-TvStayAwake {
    # Many TVs turn their Wi-Fi off a few seconds into standby, so they can't be woken over the
    # network. The Developer option "Stay awake" (stay on while plugged in) keeps it on; the
    # TV still goes to standby when told to. Turns it on if it is off. Returns $true if it
    # changed something, $false if it was already on, $null if the TV couldn't be asked.
    param([Parameter(Mandatory)]$Config)
    $now = Invoke-AdbServer -Config $Config -Shell 'settings get global stay_on_while_plugged_in'
    if (-not $now.Ok -or $now.Text.Trim() -notmatch '^\d+$') { return $null }
    if ([int]$now.Text.Trim() -ne 0) { return $false }
    $set = Invoke-AdbServer -Config $Config -Shell 'settings put global stay_on_while_plugged_in 3'   # 3 = AC and USB power
    if ($set.Ok) { return $true } else { return $null }
}

function Get-TvView {
    # One round trip to the TV: power state, plus (unless -PowerOnly) what it is showing.
    param([Parameter(Mandatory)]$Config, [switch]$PowerOnly)
    $command = 'dumpsys power | grep mWakefulness='
    if (-not $PowerOnly) {
        $command += "; dumpsys window | grep mFocusedApp=; dumpsys tv_input | grep -E 'SessionState@|inputId:|mainSessionToken|hdmi_port='"
    }
    return ConvertFrom-TvView (Invoke-AdbServer -Config $Config -Shell $command).Text
}

# ---- Finding TVs on the local network ----------------------------------------

function Get-HomeNetwork {
    # The PC's physical network connections (Wi-Fi / Ethernet) that have a router.
    # VPN and virtual adapters are skipped. Returns LocalIp, Prefix24 (e.g. 192.168.1), GatewayIp, GatewayMac.
    $result = @()
    foreach ($adapter in (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        $route = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        $address = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $route -or -not $address) { continue }
        $gatewayMac = (Get-NetNeighbor -IPAddress $route.NextHop -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).LinkLayerAddress
        $result += [pscustomobject]@{
            LocalIp    = $address.IPAddress
            Prefix24   = ($address.IPAddress.Split('.')[0..2] -join '.')
            GatewayIp  = $route.NextHop
            GatewayMac = "$gatewayMac"
        }
    }
    return $result
}

function Get-MacAddress {
    # The MAC address Windows has on record for an IP on the local network, or ''.
    param([string]$Ip)
    $mac = (Get-NetNeighbor -IPAddress $Ip -ErrorAction SilentlyContinue | Where-Object LinkLayerAddress -notmatch '^(00-){5}00$' | Select-Object -First 1).LinkLayerAddress
    return "$mac"
}

function Find-AdbDevice {
    # Tries TCP port 5555 (network ADB) on every address of the given /24 networks at once.
    # Takes about 1.5 seconds. Returns the addresses that answered.
    param([Parameter(Mandatory)][string[]]$Prefix24, [string[]]$Exclude = @(), [int]$TimeoutMs = 1500)
    $attempts = foreach ($prefix in ($Prefix24 | Select-Object -Unique)) {
        foreach ($n in 1..254) {
            $ip = "$prefix.$n"
            if ($Exclude -contains $ip) { continue }
            $client = New-Object System.Net.Sockets.TcpClient
            [pscustomobject]@{ Ip = $ip; Client = $client; Task = $client.ConnectAsync($ip, $TvAdbPort) }
        }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($attempts.Task), $TimeoutMs) } catch { $null = $_ }  # refused = expected
    $found = @($attempts | Where-Object { $_.Task.Status -eq 'RanToCompletion' -and $_.Client.Connected } | ForEach-Object Ip)
    foreach ($a in $attempts) { $a.Client.Close() }
    return $found
}

function Find-TvByMac {
    # Looks for the TV's MAC address on the home network (only if we are on the same router as at install).
    # Returns the TV's current IP, or $null.
    param([Parameter(Mandatory)]$Config)
    if (-not $Config.tvMac) { return $null }
    $networks = @(Get-HomeNetwork | Where-Object { -not $Config.gatewayMac -or $_.GatewayMac -eq $Config.gatewayMac })
    if (-not $networks) { return $null }
    foreach ($ip in (Find-AdbDevice -Prefix24 $networks.Prefix24 -Exclude $networks.LocalIp)) {
        if ((Get-MacAddress $ip) -eq $Config.tvMac) { return $ip }
    }
    return $null
}
