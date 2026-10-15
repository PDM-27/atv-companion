<#
  ATV Companion - watcher
  Puts the TV in standby when this PC sleeps, shuts down or turns its display off,
  and wakes the TV when the PC wakes, turns its display back on, or starts.

  Limited install: started at sign-in by the "ATVCompanion" entry in Task Manager >
  Startup apps, and runs while you are signed in.
  Full install (-Service): started by the ATVCompanion Windows service, which passes it
  Windows' power events (see ATVCompanionService.cs), and runs at all times.
#>
param([switch]$Background, [switch]$Service)

#BUILD-INLINE core.ps1
. (Join-Path $PSScriptRoot 'core.ps1')
#BUILD-END
. Set-InstallMode -Machine:$Service

# Windows starts the limited-install watcher with a console window. With Windows Terminal as
# the default terminal, "-WindowStyle Hidden" only minimizes that window, and it would
# sit in the taskbar for as long as we run. So start a copy of ourselves with no window
# at all, and exit.
if (-not $Service -and -not $Background) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WindowsPowerShell
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Background' -f $PSCommandPath
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    return
}

# If ATV Companion is installed for the whole PC (full install), its service does the job for everyone.
if (-not $Service -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Log "The full install (Windows service) is on this PC, so this limited-install watcher isn't needed. Exiting."
    return
}

# Only one watcher per signed-in user (or one service watcher).
$createdNew = $false
$mutexName = if ($Service) { 'Global\ATVCompanion.Service' } else { 'Local\ATVCompanion.Watcher' }
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    try {
        if (-not $mutex.WaitOne(0)) { Write-Log 'Another watcher is already running. Exiting.'; return }
    } catch [System.Threading.AbandonedMutexException] {
        $null = $_  # the previous watcher was stopped; the mutex is ours now
    }
}

Add-Type -AssemblyName System.Windows.Forms
# (A "double-quoted" here-string, because the installer embeds this whole file in a 'single-quoted' one.)
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
namespace ATVCompanion {
    // Just for me: receives Windows' "display turned off / on / dimmed" notifications.
    public class DisplayWatch : NativeWindow {
        [DllImport("user32.dll")]
        static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, int flags);
        static Guid ConsoleDisplayState = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        const int WM_POWERBROADCAST = 0x0218, PBT_POWERSETTINGCHANGE = 0x8013;
        public event Action<int> StateChanged;
        public DisplayWatch() {
            CreateHandle(new CreateParams());
            RegisterPowerSettingNotification(Handle, ref ConsoleDisplayState, 0);
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt64() == PBT_POWERSETTINGCHANGE && StateChanged != null) {
                // POWERBROADCAST_SETTING = GUID (16 bytes), data length (4), data: 0 off, 1 on, 2 dimmed
                StateChanged(Marshal.ReadInt32(m.LParam, 20));
            }
            base.WndProc(ref m);
        }
    }
    // Full install: the service host writes "<number> <event>" lines to our input. Raise each one
    // on this (the watcher's) thread, like a window message, and report "done <number>" after.
    public class ServiceEvents {
        readonly Control marshal = new Control();
        public event Action<int, string> Received;
        public ServiceEvents() {
            GC.KeepAlive(marshal.Handle);   // creates the hidden window now, on this thread
            Thread reader = new Thread(Read);
            reader.IsBackground = true;
            reader.Start();
        }
        void Read() {
            string line;
            while ((line = Console.In.ReadLine()) != null) {
                int space = line.IndexOf(' ');
                int number;
                if (space < 1 || !int.TryParse(line.Substring(0, space), out number)) continue;
                string text = line.Substring(space + 1);
                marshal.BeginInvoke(new Action(delegate { Raise(number, text); }));
            }
            marshal.BeginInvoke(new Action(delegate { Raise(0, "stop"); }));   // the service host is gone
        }
        void Raise(int number, string text) {
            if (Received != null) Received(number, text);
        }
        public static void Done(int number) {
            if (number <= 0) return;
            Console.Out.WriteLine("done " + number);
            Console.Out.Flush();
        }
    }
    public static class UserInput {
        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        // Seconds since the last keyboard or mouse input (in this sign-in session).
        public static double IdleSeconds() {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            GetLastInputInfo(ref info);
            return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
        }
    }
    public static class Clock {
        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        [DllImport("kernel32.dll")] static extern bool QueryUnbiasedInterruptTime(out ulong time);
        // Total milliseconds this PC has spent asleep (or hibernating) since it started. It only
        // grows while the PC sleeps, so a jump shows an action was frozen by a sleep.
        public static long SleptMs() {
            ulong awake;
            QueryUnbiasedInterruptTime(out awake);   // 100 ns units, sleep not counted
            return (long)GetTickCount64() - (long)(awake / 10000);
        }
    }
    public static class ShutdownOrder {
        [DllImport("kernel32.dll")] static extern bool SetProcessShutdownParameters(uint level, uint flags);
        // Ask Windows to tell this process about a shutdown before it closes other apps
        // (0x3FF = first in the range reserved for applications), so that adb's server
        // is still running when the watcher sends the TV its SLEEP key.
        public static bool NotifyFirst() { return SetProcessShutdownParameters(0x3FF, 0); }
    }
}
"@

$WakeTimeoutMs     = 10000   # keep trying to reach the TV this long after the PC wakes
$PollMs            = 100     # how often to retry while waking
$KeepAliveMs       = 120000  # reconnect this often so the sleep key goes out instantly
$SettleMs          = 1200    # give the TV this long to react before checking its state
$InputWindowS      = 2       # "display on" counts as a person if there was input this recently

# Android key codes. POWER is a toggle: only send it after reading the TV's state.
$KeySleep = 223; $KeyWakeup = 224; $KeyPower = 26

# Windows can deliver a new event while we are still handling another one, and sleep can
# freeze an action halfway and let it finish after the PC wakes. These counters let every
# action notice that things changed, and stop.
$script:Suspends     = 0        # +1 each time the PC goes to sleep or shuts down
$script:Resumes      = 0        # +1 each time the PC wakes up
$script:Waking       = $false   # a wake is in progress
$script:Suspending   = $false   # the quick sleep key is being sent
$script:TvLeftAlone  = $false   # display went off while the TV showed something else
$script:DisplayState = -1       # last display state Windows reported
$script:LastWakeOk   = [datetime]::MinValue
$script:LastRefind   = [datetime]::MinValue
$script:LastSuspendAt = [datetime]::MinValue
$script:Failures     = 0
$script:StartedAt    = Get-Date
$script:SleptMs      = [ATVCompanion.Clock]::SleptMs()   # see Invoke-Safely
$script:EventIsLate  = $false   # this event was handled only after the PC had slept
$script:LastMonitorChange = [datetime]::MinValue   # a display was connected or disconnected
$script:DisplayOnAt  = [datetime]::MinValue
$script:InputWatchStart = [datetime]::MinValue

function Invoke-Safely {
    # Runs one event handler. It must never throw: an error would stop the watcher.
    # It also notes whether the PC has slept since the previous event: if so, this event
    # was waiting while the PC slept (e.g. "going to sleep" handled only after waking).
    param([string]$Name, [scriptblock]$Action)
    $slept = [ATVCompanion.Clock]::SleptMs()
    $script:EventIsLate = ($slept - $script:SleptMs) -gt 2000
    $script:SleptMs = $slept
    try { & $Action } catch { Write-Log "$Name failed: $($_.Exception.Message)" }
}

function Wait-Settle {
    # Gives the TV a moment to react. Returns $false if the PC slept during the wait: what we
    # read afterwards would be about a later moment, so the caller must not act on it.
    $before = [ATVCompanion.Clock]::SleptMs()
    Start-Sleep -Milliseconds $SettleMs
    return ([ATVCompanion.Clock]::SleptMs() - $before) -lt 1000
}

function Get-ConfigOrNull {
    $config = Read-Config
    if (-not $config -or -not $config.tvIp) { Write-Log 'No TV is set up (config.json missing or empty).'; return $null }
    return $config
}

function Get-IdleText {
    # " (idle 12.3 s)" for the log. A service can't see keyboard and mouse use, so it says nothing.
    if ($Service) { return '' }
    return ' (idle {0} s)' -f [math]::Round([ATVCompanion.UserInput]::IdleSeconds(), 1)
}

function Update-TvAddress {
    # If the TV stopped answering, look for its MAC address on the network (at most every 10 minutes).
    param($Config)
    if (((Get-Date) - $script:LastRefind).TotalMinutes -lt 10) { return $null }
    $script:LastRefind = Get-Date
    $ip = Find-TvByMac $Config
    if (-not $ip) { Write-Log 'Searched the network for the TV (by its MAC address): not found'; return $null }
    if ($ip -ne $Config.tvIp) {
        Write-Log "Found the TV at a new address: $ip (was $($Config.tvIp))"
        $Config.tvIp = $ip
        Save-Config $Config
        return $Config
    }
    return $null
}

function Invoke-TvSleepFast {
    # PC is going to sleep or shutting down: the network is about to go away, so send
    # one SLEEP key and nothing else. SLEEP is not a toggle, so it's safe to send blind.
    param([string]$Why)
    $script:Suspends++
    $script:LastSuspendAt = Get-Date
    Stop-InputWatch
    if ($script:EventIsLate) { Write-Log "$Why - only handled after the PC had already slept; skipped"; return }
    $resumes = $script:Resumes
    if ($script:TvLeftAlone) { Write-Log "$Why - TV left alone (it was showing something else)"; return }
    $config = Get-ConfigOrNull; if (-not $config) { return }
    $script:Suspending = $true
    try {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        # Straight to our adb server, from this process: during shutdown Windows won't start adb.exe.
        $connect = Invoke-AdbServer -Config $config -Request ('host:connect:' + (Get-TvTarget $config)) -TimeoutMs 1500
        $status = ConvertFrom-AdbConnect $connect.Text
        if ($script:Resumes -ne $resumes) { Write-Log "$Why - cancelled: the PC woke up first"; return }
        # If the PC freezes while this runs, the TV usually has the key already; the result comes after waking.
        $key = Invoke-AdbServer -Config $config -Shell "input keyevent $KeySleep" -TimeoutMs 3000
        $sent = $key.Ok
        $detail = ''
        if (-not $sent -or $status -ne 'Connected') {
            # Keep the adb server's own words in the log, to see why it failed.
            $detail = ' [connect: "{0}"; key: "{1}"]' -f ($connect.Text -replace '\s+', ' '), ($key.Text -replace '\s+', ' ')
        }
        Write-Log "$Why - connect: $status, SLEEP sent: $sent ($($timer.ElapsedMilliseconds) ms)$detail"
    } finally {
        $script:Suspending = $false
    }
}

function Invoke-TvSleepChecked {
    # The display turned off. Look at what the TV shows first (leave it alone if it isn't the
    # PC), then send SLEEP straight away: on Modern Standby PCs no "going to sleep" follows and
    # the PC can stop within seconds. Stops as soon as anything else happens.
    param([string]$Why)
    $suspends = $script:Suspends; $resumes = $script:Resumes
    $changed = { $script:Suspends -ne $suspends -or $script:Resumes -ne $resumes -or $script:DisplayState -ne 0 -or $script:Waking }
    $config = Get-ConfigOrNull; if (-not $config) { return }
    $status = Connect-Tv $config
    if ($status -ne 'Connected') { Write-Log "$Why - TV not reachable ($status)"; return }
    $view = Get-TvView $config
    if (& $changed) { Write-Log "$Why - cancelled: something else happened first"; return }
    if ($config.leaveTvAloneWhenInUse -and (Test-ShowingPc $view $config) -eq 'No') {
        $script:TvLeftAlone = $true
        Write-Log "$Why - TV is showing something else ($($view.App) $($view.Input)); leaving it on"
        return
    }
    if ($view.Power -eq 'Off') { Write-Log "$Why - TV already off"; return }
    [void](Send-TvKey $config $KeySleep)
    if (-not (Wait-Settle)) { Write-Log "$Why - SLEEP sent; the PC slept meanwhile"; return }
    $power = (Get-TvView $config -PowerOnly).Power
    if (& $changed) { Write-Log "$Why - SLEEP sent, then something else happened"; return }
    if ($power -eq 'On') {
        [void](Send-TvKey $config $KeyPower)   # confirmed still on, so POWER turns it off
        Write-Log "$Why - SLEEP ignored; sent POWER"
    } else {
        Write-Log "$Why - TV is off ($power)"
    }
}

function Invoke-TvWake {
    # PC woke up or started, display turned on, or someone signed in: reach the TV as soon as
    # the network allows, send WAKEUP (not a toggle), then check. POWER only if the TV is
    # confirmed still off.
    param([string]$Why, [int]$TimeoutMs = $WakeTimeoutMs)
    if ($script:Waking) { Write-Log "$Why - already waking the TV"; return }
    if (((Get-Date) - $script:LastWakeOk).TotalSeconds -lt 5) { return }   # done moments ago
    $config = Get-ConfigOrNull; if (-not $config) { return }
    $script:Waking = $true
    try {
        $suspends = $script:Suspends
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $trace = New-Object System.Collections.Generic.List[string]   # what happened when, for the log
        $sent = $false
        while (-not $sent -and $timer.ElapsedMilliseconds -lt $TimeoutMs -and $script:Suspends -eq $suspends) {
            $status = Connect-Tv $config -TimeoutMs 2000
            if ($status -eq 'Connected') {
                $sent = Send-TvKey $config $KeyWakeup -TimeoutMs 2000
                if (-not $sent) {
                    if ((Get-TvAdbState $config) -eq 'unauthorized') {
                        $status = 'Unauthorized'   # waiting for "Allow" on the TV: keep this connection
                    } else {
                        # The connection from before the PC slept is dead: drop it so the next try reconnects.
                        $status = 'SendFailed'
                        Disconnect-Tv $config
                    }
                }
            }
            if ($trace.Count -eq 0 -or -not $trace[$trace.Count - 1].StartsWith($status)) { $trace.Add("$status@$($timer.ElapsedMilliseconds)") }
            if (-not $sent) { Start-Sleep -Milliseconds $(if ($status -eq 'Unauthorized') { 2000 } else { $PollMs }) }
        }
        if ($script:Suspends -ne $suspends) { Write-Log "$Why - cancelled: the PC went back to sleep"; return }
        if (-not $sent) {
            $moved = Update-TvAddress $config
            if ($moved -and (Connect-Tv $moved) -eq 'Connected') { $config = $moved; $sent = Send-TvKey $config $KeyWakeup }
        }
        if (-not $sent) { Write-Log "$Why - could not reach the TV [$($trace -join ' ')]"; return }
        Write-Log "$Why - WAKEUP sent after $($timer.ElapsedMilliseconds) ms [$($trace -join ' ')]"
        if (-not (Wait-Settle)) { Write-Log "$Why - the PC slept meanwhile; not checking"; return }
        $power = (Get-TvView $config -PowerOnly).Power
        if ($script:Suspends -ne $suspends) { return }
        if ($power -eq 'Off') {
            [void](Send-TvKey $config $KeyPower)   # confirmed still off, so POWER turns it on
            Write-Log "$Why - WAKEUP ignored; sent POWER"
        } else {
            Write-Log "$Why - TV power: $power"
        }
        $script:LastWakeOk = Get-Date
    } finally {
        $script:Waking = $false
    }
}

function Invoke-PcResume {
    # The PC woke up with someone there (keyboard, mouse or power button).
    param([string]$Why)
    $script:Resumes++
    Stop-InputWatch
    $script:TvLeftAlone = $false
    Invoke-TvWake $Why
}

# ---- Is a person there? -------------------------------------------------------
# A TV going to standby drops its HDMI signal, and on some PCs Windows answers by turning
# the screen back on with nobody there. Waking the TV on every "display on" would undo
# every SLEEP. So "display on" only wakes the TV when a person is there:
#  - limited install: there was keyboard or mouse input (if not yet, watch for it);
#  - full install (a service can't see input): the screen didn't come on together with a
#    display connecting or disconnecting, which is what the TV's own signal looks like.

function Start-InputWatch {
    $script:InputWatchStart = Get-Date
    $inputTimer.Interval = 250
    $inputTimer.Start()
}

function Stop-InputWatch { $inputTimer.Stop() }

function Invoke-InputCheck {
    # Every 250 ms for 15 s, then every 5 s for up to 30 minutes, while the screen stays on.
    if ($script:DisplayState -ne 1) { Stop-InputWatch; return }
    $watched = ((Get-Date) - $script:InputWatchStart).TotalSeconds
    if ([ATVCompanion.UserInput]::IdleSeconds() -lt 1.5) {
        Stop-InputWatch
        $script:TvLeftAlone = $false
        Invoke-TvWake 'Display on (keyboard or mouse used)'
    } elseif ($watched -gt 1800) {
        Stop-InputWatch
    } elseif ($watched -gt 15) {
        $inputTimer.Interval = 5000
    }
}

function Confirm-DisplayOn {
    # Full install, 1.5 s after "display on": wake the TV unless a display connected or
    # disconnected around the same moment.
    if ($script:DisplayState -ne 1) { return }
    if (($script:LastMonitorChange - $script:DisplayOnAt).TotalSeconds -gt -3) {
        Write-Log 'Display on together with a display connecting or disconnecting (likely the TV''s own signal) - TV left as it is'
        return
    }
    $script:TvLeftAlone = $false
    Invoke-TvWake 'Display on'
}

function Test-AfterUpdateRestart {
    # Full install, when the watcher starts: did Windows just restart by itself (a planned
    # restart, e.g. for updates at night)? Then nobody is there, so the TV stays off.
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if (((Get-Date) - $boot).TotalMinutes -gt 10) { return $false }   # the service was restarted later, not at boot
    $last = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074; EndTime = $boot } -MaxEvents 1 -ErrorAction SilentlyContinue
    if (-not $last) { return $false }
    return (([Convert]::ToUInt32("$($last.Properties[3].Value)", 16) -band 0x80000000) -ne 0)
}

function Invoke-DisplayChange {
    param([int]$State)
    $previous = $script:DisplayState
    $script:DisplayState = $State
    if ($previous -eq $State) { return }
    if ($previous -eq -1) {
        # Windows reports the current state right after the watcher starts. For the full-install
        # service that means the PC has just started (or the service was restarted): turn
        # the TV on, unless Windows restarted by itself for updates.
        if ($Service -and $State -eq 1) {
            if (Test-AfterUpdateRestart) { Write-Log 'PC started after an automatic (planned) restart - TV left as it is' }
            else { Invoke-TvWake 'PC started' -TimeoutMs 60000 }
        }
        return
    }
    $config = Get-ConfigOrNull; if (-not $config -or -not $config.followDisplay) { return }
    switch ($State) {
        0 {
            # The display also goes off when the PC sleeps, sometimes just after "going to sleep" arrives.
            if ($script:Suspending -or ((Get-Date) - $script:LastSuspendAt).TotalSeconds -lt 10) {
                Write-Log 'Display off (PC going to sleep)'
                return
            }
            Write-Log "Display off$(Get-IdleText)"
            Stop-InputWatch
            Invoke-TvSleepChecked 'Display off'
        }
        1 {
            if ($Service) {
                $script:DisplayOnAt = Get-Date
                $displayOnTimer.Stop(); $displayOnTimer.Start()   # decides in 1.5 s: Confirm-DisplayOn
            } elseif ([ATVCompanion.UserInput]::IdleSeconds() -lt $InputWindowS) {
                $script:TvLeftAlone = $false
                Invoke-TvWake "Display on$(Get-IdleText)"
            } else {
                Write-Log "Display on$(Get-IdleText) without keyboard or mouse use - waiting for input"
                Start-InputWatch
            }
        }
        default { }   # 2 = dimmed: nothing to do
    }
}

function Test-UserRestart {
    # Windows logs event 1074 when a shutdown or restart starts. Keep the TV on only if it is
    # a restart that a person started (not a planned one, such as Windows Update at night)
    # and, just for me, someone used the PC in the last 5 minutes. In any doubt, standby.
    # (Only the English word "restart" is recognised; on other languages the TV goes to standby.)
    # The service hears about shutdown only after everyone is signed out, so it looks further back.
    $since = (Get-Date).AddSeconds($(if ($Service) { -300 } else { -30 }))
    if ($since -lt $script:StartedAt) { $since = $script:StartedAt }   # never an older session's restart
    $shutdown = $null
    for ($try = 0; $try -lt 6 -and -not $shutdown; $try++) {
        # The record can take a moment to become readable.
        $shutdown = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue
        if (-not $shutdown) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $shutdown) { Write-Log 'Shutdown record not found - treating it as a shutdown'; return $false }
    $planned = ([Convert]::ToUInt32("$($shutdown.Properties[3].Value)", 16) -band 0x80000000) -ne 0
    $kind = "$($shutdown.Properties[4].Value)"
    Write-Log "Shutdown record: $kind, reason code $($shutdown.Properties[3].Value)"
    $someoneThere = $Service -or [ATVCompanion.UserInput]::IdleSeconds() -lt 300
    return ($kind -eq 'restart' -and -not $planned -and $someoneThere)
}

function Test-AdbServerRunning {
    return [bool](Get-Process -Name adb -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) })
}

function Invoke-SessionEnd {
    param($Reason)
    Write-Log "Session ending ($Reason) - adb server running: $(Test-AdbServerRunning)"
    if ("$Reason" -ne 'SystemShutdown') { Write-Log 'Signing out - TV left as it is'; return }
    if (Test-UserRestart) { Write-Log 'PC restarting - TV left on'; return }
    Invoke-TvSleepFast 'PC shutting down'
}

function Invoke-KeepAlive {
    $config = Get-ConfigOrNull; if (-not $config) { return }
    $status = Connect-Tv $config
    if ($status -eq 'Connected') {
        if ($script:Failures -gt 0) { Write-Log 'Keep-alive: TV reachable again' }
        $script:Failures = 0
        # A TV reset or update can turn "Stay awake" off again, and then the TV drops off
        # the network in standby and can't be woken. Put it back.
        if ($config.keepTvReachable -and (Set-TvStayAwake $config) -eq $true) {
            Write-Log 'Turned the TV''s "Stay awake" setting back on (keeps it reachable in standby)'
        }
        return
    }
    $script:Failures++
    if ($script:Failures -eq 1) { Write-Log "Keep-alive: TV not reachable ($status)" }
    if ($status -eq 'Unauthorized') { Write-Log 'The TV does not trust this PC (yet). Press Allow on the TV, or run the change-TV command.' }
    elseif ($script:Failures -ge 2) { [void](Update-TvAddress $config) }
}

function Invoke-ServiceEvent {
    # full install: one event from the service host (see ATVCompanionService.cs).
    param([string]$Text)
    switch -Regex ($Text) {
        '^suspend$'      { Invoke-TvSleepFast 'PC going to sleep' }
        '^resume user$'  { Invoke-PcResume 'PC woke up' }
        '^resume auto$'  { $script:Resumes++ }   # woke up by itself (e.g. maintenance): wait for the display
        '^display (\d)$' { Invoke-DisplayChange ([int]$Matches[1]) }
        '^monitor (\w+)$' { $script:LastMonitorChange = Get-Date; Write-Log "A display was $($Matches[1])" }
        '^shutdown$'     { Invoke-SessionEnd 'SystemShutdown' }
        '^stop$'         { Write-Log 'Service stopping'; [System.Windows.Forms.Application]::ExitThread() }
    }
}

# ---- Wire up events and run ----------------------------------------------------

$inputTimer = New-Object System.Windows.Forms.Timer   # limited install: watching for a person
$inputTimer.add_Tick({ Invoke-Safely 'Input check' { Invoke-InputCheck } })

$displayOnTimer = New-Object System.Windows.Forms.Timer   # full install: confirming "display on"
$displayOnTimer.Interval = 1500
$displayOnTimer.add_Tick({
    $displayOnTimer.Stop()
    Invoke-Safely 'Display on' { Confirm-DisplayOn }
})

$keepAlive = New-Object System.Windows.Forms.Timer
$keepAlive.Interval = $KeepAliveMs
$keepAlive.add_Tick({ Invoke-Safely 'Keep-alive' { Invoke-KeepAlive } })
$keepAlive.Start()

$startConfig = Read-Config
$tvText = if ($startConfig -and $startConfig.tvIp) { $startConfig.tvIp } else { 'not set' }

if ($Service) {
    $serviceEvents = New-Object ATVCompanion.ServiceEvents
    $serviceEvents.add_Received({
        param($number, $text)
        $done = $number
        $what = "$text"
        Invoke-Safely "Service event '$what'" { Invoke-ServiceEvent $what }
        [ATVCompanion.ServiceEvents]::Done($done)
    })
    # How long after Windows started did the service start? (Shows whether it beats the sign-in screen.)
    $timing = ''
    try {
        $hostId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $timing = ', service started {0:N0} s and watcher {1:N0} s after Windows' -f ((Get-Process -Id $hostId).StartTime - $boot).TotalSeconds, ((Get-Date) - $boot).TotalSeconds
    } catch { $null = $_ }
    Write-Log "$AppName service watcher $AppVersion started (PID $PID, TV $tvText$timing)"
    if ($startConfig -and $startConfig.tvIp) {
        [void](Start-AdbServer $startConfig)
        Invoke-Safely 'Startup' { Invoke-KeepAlive }
        # The TV is turned on when the first display notification arrives (see Invoke-DisplayChange).
    }
} else {
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged({
        param($s, $e)
        $null = $s
        if ($e.Mode -eq 'Suspend') { Invoke-Safely 'Suspend' { Invoke-TvSleepFast 'PC going to sleep' } }
        elseif ($e.Mode -eq 'Resume') { Invoke-Safely 'Resume' { Invoke-PcResume 'PC woke up' } }
    })
    [Microsoft.Win32.SystemEvents]::add_SessionEnding({
        param($s, $e)
        $null = $s
        $reason = $e.Reason
        Invoke-Safely 'SessionEnding' { Invoke-SessionEnd $reason }
    })
    $display = New-Object ATVCompanion.DisplayWatch
    $display.add_StateChanged({
        param($state)
        $newState = $state
        Invoke-Safely 'Display' { Invoke-DisplayChange $newState }
    })
    $notifiedFirst = [ATVCompanion.ShutdownOrder]::NotifyFirst()
    Write-Log "$AppName watcher $AppVersion started (PID $PID, TV $tvText, first at shutdown: $notifiedFirst)"
    if ($startConfig -and $startConfig.tvIp) {
        [void](Start-AdbServer $startConfig)
        if ([System.Windows.Forms.SystemInformation]::TerminalServerSession) {
            Write-Log 'Remote Desktop session - not waking the TV'
            Invoke-Safely 'Startup' { Invoke-KeepAlive }
        } else {
            # Someone just signed in (or the watcher was just installed or updated): make sure the
            # TV is on. This also lets someone without a TV remote sign in "blind" after a shutdown.
            Invoke-Safely 'Startup' { Invoke-TvWake 'Signed in' -TimeoutMs 30000 }
        }
    }
}
[System.Windows.Forms.Application]::Run()
