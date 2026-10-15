// ATV Companion - Windows service host (whole-PC mode only).
//
// A Windows service must be a program that answers the Service Control Manager; a
// PowerShell script can't do that by itself. This program does only that:
//   - starts the watcher script (watcher.ps1 -Service) with Windows PowerShell,
//   - passes it the events Windows sends to services (sleep, wake, display on/off,
//     shutdown) as lines of text on its input,
//   - waits briefly for the watcher to finish the time-critical ones (sleep and
//     shutdown), so the TV gets its key before the PC goes down,
//   - restarts the watcher if it stops unexpectedly.
// All TV logic lives in watcher.ps1. The installer compiles this file on your PC with
// the C# compiler that ships with Windows (.NET Framework 4); nothing pre-built is used.
// It runs as the low-privilege account NT SERVICE\ATVCompanion, not as SYSTEM.

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

static class ATVCompanionService
{
    const string Name = "ATVCompanion";

    // From winsvc.h and winuser.h
    const int SERVICE_WIN32_OWN_PROCESS = 0x10;
    const int SERVICE_STOPPED = 1, SERVICE_START_PENDING = 2, SERVICE_STOP_PENDING = 3, SERVICE_RUNNING = 4;
    const int ACCEPT_STOP = 0x1, ACCEPT_SHUTDOWN = 0x4, ACCEPT_POWEREVENT = 0x40, ACCEPT_PRESHUTDOWN = 0x100;
    const int CONTROL_STOP = 1, CONTROL_INTERROGATE = 4, CONTROL_SHUTDOWN = 5, CONTROL_POWEREVENT = 0xD, CONTROL_PRESHUTDOWN = 0xF;
    const int PBT_APMSUSPEND = 0x4, PBT_APMRESUMESUSPEND = 0x7, PBT_APMRESUMEAUTOMATIC = 0x12, PBT_POWERSETTINGCHANGE = 0x8013;
    const int DEVICE_NOTIFY_SERVICE_HANDLE = 1;
    const int CONTROL_DEVICEEVENT = 0xB, DBT_DEVICEARRIVAL = 0x8000, DBT_DEVICEREMOVECOMPLETE = 0x8004, DBT_DEVTYP_DEVICEINTERFACE = 5;
    static readonly Guid MonitorInterface = new Guid("E6F07B5F-EE97-4A90-B076-33F57BF4EAA7");   // GUID_DEVINTERFACE_MONITOR
    const int NO_ERROR = 0, ERROR_CALL_NOT_IMPLEMENTED = 120;
    static Guid ConsoleDisplayState = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");

    [StructLayout(LayoutKind.Sequential)]
    struct ServiceStatus { public int Type, State, ControlsAccepted, Win32ExitCode, SpecificExitCode, CheckPoint, WaitHint; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TableEntry { public string Name; public MainCallback Main; }

    delegate void MainCallback(int argc, IntPtr argv);
    delegate int ControlCallback(int control, int eventType, IntPtr eventData, IntPtr context);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool StartServiceCtrlDispatcherW(TableEntry[] table);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr RegisterServiceCtrlHandlerExW(string name, ControlCallback callback, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool SetServiceStatus(IntPtr handle, ref ServiceStatus status);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, int flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterDeviceNotificationW(IntPtr recipient, ref DeviceInterfaceFilter filter, int flags);

    [StructLayout(LayoutKind.Sequential)]
    struct DeviceInterfaceFilter { public int Size, DeviceType, Reserved; public Guid ClassGuid; public short Name; }

    // Kept in fields so the garbage collector never frees callbacks Windows still holds.
    static readonly MainCallback mainCallback = ServiceMain;
    static readonly ControlCallback controlCallback = OnControl;

    static IntPtr statusHandle;
    static ServiceStatus status;
    static readonly ManualResetEvent stopping = new ManualResetEvent(false);
    static readonly object inputLock = new object();
    static Process watcher;
    static int sequence;       // number of the last event sent to the watcher
    static int lastDone;       // number of the last event the watcher finished
    static readonly AutoResetEvent doneSignal = new AutoResetEvent(false);

    static int Main()
    {
        TableEntry[] table = { new TableEntry { Name = Name, Main = mainCallback }, new TableEntry() };
        if (!StartServiceCtrlDispatcherW(table))
        {
            Console.Error.WriteLine("This is the ATV Companion Windows service. Windows starts it; it can't be run directly.");
            return 1;
        }
        return 0;
    }

    static void ServiceMain(int argc, IntPtr argv)
    {
        statusHandle = RegisterServiceCtrlHandlerExW(Name, controlCallback, IntPtr.Zero);
        status.Type = SERVICE_WIN32_OWN_PROCESS;
        SetState(SERVICE_START_PENDING, 0, 10000);
        StartWatcher();
        // Display on/off notifications. Windows sends the current state right away.
        RegisterPowerSettingNotification(statusHandle, ref ConsoleDisplayState, DEVICE_NOTIFY_SERVICE_HANDLE);
        // Displays connecting or disconnecting. A TV that drops its HDMI signal in standby can
        // make Windows turn the screen on; the watcher uses these to tell that from a person.
        DeviceInterfaceFilter monitors = new DeviceInterfaceFilter();
        monitors.Size = Marshal.SizeOf(monitors);
        monitors.DeviceType = DBT_DEVTYP_DEVICEINTERFACE;
        monitors.ClassGuid = MonitorInterface;
        RegisterDeviceNotificationW(statusHandle, ref monitors, DEVICE_NOTIFY_SERVICE_HANDLE);
        SetState(SERVICE_RUNNING, ACCEPT_STOP | ACCEPT_SHUTDOWN | ACCEPT_POWEREVENT | ACCEPT_PRESHUTDOWN, 0);

        while (true)
        {
            watcher.WaitForExit();
            if (stopping.WaitOne(0)) break;
            // The watcher stopped by itself: wait a little, then start it again.
            if (stopping.WaitOne(10000)) break;
            StartWatcher();
        }
        SetState(SERVICE_STOPPED, 0, 0);
    }

    static void StartWatcher()
    {
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        ProcessStartInfo start = new ProcessStartInfo(
            Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(folder, "watcher.ps1") + "\" -Service");
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.WorkingDirectory = folder;
        lock (inputLock) { watcher = Process.Start(start); }
        Thread reader = new Thread(ReadDone);
        reader.IsBackground = true;
        reader.Start(watcher);
    }

    // The watcher writes "done <number>" when it has finished handling an event.
    static void ReadDone(object process)
    {
        StreamReader output = ((Process)process).StandardOutput;
        string line;
        while ((line = output.ReadLine()) != null)
        {
            int number;
            if (line.StartsWith("done ") && int.TryParse(line.Substring(5), out number))
            {
                Interlocked.Exchange(ref lastDone, number);
                doneSignal.Set();
            }
        }
    }

    // Sends "<number> <event>" to the watcher, and optionally waits until it is done with it.
    static void Send(string message, int waitMs)
    {
        int number;
        lock (inputLock)
        {
            if (watcher == null || watcher.HasExited) return;
            number = ++sequence;
            try
            {
                watcher.StandardInput.WriteLine(number + " " + message);
                watcher.StandardInput.Flush();
            }
            catch (IOException) { return; }
        }
        Stopwatch waited = Stopwatch.StartNew();
        while (waitMs > 0 && Thread.VolatileRead(ref lastDone) < number && waited.ElapsedMilliseconds < waitMs)
        {
            doneSignal.WaitOne(100);
        }
    }

    static int OnControl(int control, int eventType, IntPtr eventData, IntPtr context)
    {
        switch (control)
        {
            case CONTROL_POWEREVENT:
                if (eventType == PBT_APMSUSPEND) Send("suspend", 2000);         // let the SLEEP key go out first
                else if (eventType == PBT_APMRESUMESUSPEND) Send("resume user", 0);
                else if (eventType == PBT_APMRESUMEAUTOMATIC) Send("resume auto", 0);
                else if (eventType == PBT_POWERSETTINGCHANGE)
                {
                    // POWERBROADCAST_SETTING: GUID (16 bytes), data length (4), data: 0 off, 1 on, 2 dimmed
                    Send("display " + Marshal.ReadInt32(eventData, 20), 0);
                }
                return NO_ERROR;
            case CONTROL_PRESHUTDOWN:
            case CONTROL_SHUTDOWN:
                SetState(SERVICE_STOP_PENDING, 0, 15000);
                ThreadPool.QueueUserWorkItem(delegate
                {
                    Send("shutdown", 10000);   // the watcher decides restart or shutdown, and sends SLEEP
                    Stop();
                });
                return NO_ERROR;
            case CONTROL_STOP:
                SetState(SERVICE_STOP_PENDING, 0, 10000);
                ThreadPool.QueueUserWorkItem(delegate { Stop(); });
                return NO_ERROR;
            case CONTROL_DEVICEEVENT:
                if (eventType == DBT_DEVICEARRIVAL) Send("monitor connected", 0);
                else if (eventType == DBT_DEVICEREMOVECOMPLETE) Send("monitor disconnected", 0);
                return NO_ERROR;
            case CONTROL_INTERROGATE:
                return NO_ERROR;
        }
        return ERROR_CALL_NOT_IMPLEMENTED;
    }

    static void Stop()
    {
        if (stopping.WaitOne(0)) return;
        stopping.Set();
        Send("stop", 5000);
        try { if (!watcher.WaitForExit(2000)) watcher.Kill(); } catch (InvalidOperationException) { }
    }

    static void SetState(int state, int accepted, int waitHint)
    {
        status.State = state;
        status.ControlsAccepted = accepted;
        status.WaitHint = waitHint;
        status.CheckPoint = (state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING) ? status.CheckPoint + 1 : 0;
        SetServiceStatus(statusHandle, ref status);
    }
}
