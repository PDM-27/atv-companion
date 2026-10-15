# History and lessons learned

## Goal

The user's TCL QM7K TV is used as a PC monitor over HDMI 2.1 (full 48 Gbps,
4K high refresh). They want it to follow the PC's power state the way a
monitor does: off when the PC sleeps or shuts down, on when it wakes. TCL has
no LG/Samsung-style network power API.

## Approaches evaluated

1. **HDMI-CEC.** PC GPUs (NVIDIA included) don't drive the CEC line. The
   Pulse-Eight USB-CEC adapter works but limits passthrough to 4K60. Workaround:
   keep the main HDMI 2.1 cable direct, and run a second GPU output through the
   adapter into a spare TV input (CEC only, no picture). Not purchased. It
   remains the only answer for TVs that drop off the network in standby, so it
   belongs in the FAQ.
2. **IR blaster** (USB-UIRT + EventGhost). Viable, not pursued.
3. **Android TV Remote Protocol v2** (Python `androidtvremote2`, the protocol
   the Google TV phone app uses). Pairing and connecting worked.
   KEYCODE_SLEEP / KEYCODE_WAKEUP were accepted but the TV did nothing.
   Abandoned.
   - The menu paths suggested in the chat for network standby ("Quick Start",
     "Screenless Service", "Standby Mode", "Networked Standby" under
     System → Power & Energy, or under Network & Internet) **do not exist on
     this TV's firmware**, even after signing into Google. Don't present those
     paths as fact in user docs.
4. **ADB over the network.** Chosen. Works.

## ADB prototype evolution

- **One-shot state-aware script.** Reads `adb shell dumpsys power`, parses
  `mWakefulness=Awake|Asleep|Dozing`, then acts only if needed. Worked manually.
- **Task Scheduler wiring** (triggers on Kernel-Power 42 and 107,
  Power-Troubleshooter 1, User32 1074). First error: "The request is not
  supported" (from "Run whether user is logged on or not" plus "Do not store
  password"). After switching to "Run only when user is logged on", tasks still
  could not be saved under any account, including the only admin account.
  Abandoned.
- **Watcher v1.** Long-running PowerShell process with a WinForms message pump
  (`[System.Windows.Forms.Application]::Run()`), subscribing to
  `[Microsoft.Win32.SystemEvents]::PowerModeChanged` (Suspend/Resume) and
  `SessionEnding`. Two bugs:
  - *PC sleep did nothing.* The suspend handler reconnected and made several
    ADB round trips; Windows tore the network down before the key was sent.
  - *PC wake turned the TV OFF.* After resume the state read came back as
    not-Awake/Unknown, the code fell through to KEYCODE_POWER, and toggled an
    already-on TV off.
- **v2 fixes.** POWER only when the opposite state is confirmed; Unknown means
  do nothing on wake; a keep-alive `adb connect` every 120 s keeps the
  connection warm; the suspend path became a single KEYCODE_SLEEP (223) with
  no state read. Result: the TV sleeps almost instantly when the PC sleeps.
  Wake worked but took about 5 s because of a fixed 5 s resume delay.
- **v3.** Removed the fixed delay. On resume, retry `adb connect` every
  250 ms (later 100 ms) and send KEYCODE_WAKEUP (224) on first contact, then
  verify; POWER fallback only if still confirmed Asleep/Dozing. Wake now takes
  about 3 s after the PC's fans spin up, on Wi-Fi.
- **Final prototype** = `reference/tv-power-sync.ps1`: v3 logic without
  logging, PollMs 100, wake timeout 10 s, keep-alive 120 s. Launched at login by
  `reference/start-tv-sync.vbs` placed in the user's Startup folder.

## Confirmed on the developer's hardware

- KEYCODE_SLEEP (223) over ADB puts this TV into standby. (The v2+ suspend
  path sends only 223 and works.)
- PC sleep → TV sleeps. PC wake → TV wakes in about 3 s on Wi-Fi. So this TV
  stays reachable over ADB while in standby.
- `SystemEvents` handlers fire correctly in `powershell.exe` 5.1 (STA) with
  `Application.Run()` pumping messages on the main thread. Keep that
  structure; don't move to `Register-ObjectEvent` or background runspaces
  without testing.

**Not individually confirmed:**

- Whether 224 alone wakes the TV, or the POWER fallback does the work.
- Whether shutdown (`SessionEnding`) reliably sleeps the TV in the final
  version.

Check both during testing.

## Latency notes

- The floor is: PC resume + network usable + one ADB round trip. Nothing can
  be sent while the PC is asleep; the watcher is frozen too.
- Wi-Fi re-association is the main cost. Ethernet should get close to 1 s.
  The Wi-Fi adapter has no Power Management tab; suggested instead: power plan
  → Wireless Adapter Settings → Power Saving Mode → Maximum Performance.
  "Idle Power Down Restriction" (adapter Advanced tab) is a minor factor.
- Polling faster than ~100 ms gains nothing: each poll spawns `adb.exe`, and
  the network takes hundreds of ms to seconds to return.
- Modern Standby (S0) is a motherboard firmware capability, often worse on
  desktops. Not worth chasing.

## Distribution research from the chat

- `irm <url> | iex` runs script text in memory, so execution policy doesn't
  apply to it. This is how Scoop, Chris Titus's WinUtil and Spicetify install.
- `-ExecutionPolicy Bypass` on a `powershell.exe` command line sets the policy
  for that process only and needs no admin. Group Policy (MachinePolicy /
  UserPolicy scope) overrides it; detect that and explain instead of failing
  silently.
- A per-user install needs no admin. Admin is worse: if a standard user
  approves the prompt with a different admin account, the install lands in the
  admin's profile and never runs for the actual user. Scoop refuses to run
  elevated by default for this reason.
- HKCU Run entries appear in Task Manager → Startup apps, where users can see
  and disable them.
- Hidden-window options considered: VBScript launcher (deprecated by
  Microsoft), `conhost.exe --headless` (flagged by the Sigma rule "Powershell
  Executed From Headless ConHost Process"), `powershell.exe -WindowStyle
  Hidden` (brief flash at login). See the Windows Terminal risk in SPEC.md.
- Pin install URLs to releases or tags, not the main branch, so a bad push
  can't break everyone's install.

## Building v1.0 in Claude Code (October 2026)

Everything below was measured on the developer's PC and TV, with the watcher's
log, the TV's own event log (`adb shell logcat -b events`, sleep/screen events)
and the Windows System log lined up against each other.

### Answered open questions

- **KEYCODE_WAKEUP (224) alone wakes this TV.** The POWER fallback has never
  been needed. KEYCODE_SLEEP (223) alone puts it in standby.
- **Shutdown did NOT reliably sleep the TV with the prototype's approach.** See
  "adb.exe can't start during shutdown" below. Fixed.
- **adb keys can't be moved out of `%USERPROFILE%\.android` on Windows.** adb
  reads the profile folder from Windows directly (SHGetFolderPath); setting
  `USERPROFILE`/`HOME` has no effect. The installer records whether it created
  `.android` and uninstall only removes it in that case (and only if no other
  Android tool has put files there).
- `ANDROID_ADB_SERVER_PORT` and `-P` both work for a private adb server port.
  `ANDROID_ADB_LOG_PATH` moves adb's server log (default `%TEMP%\adb.log`).
- adb needs only `adb.exe`, `AdbWinApi.dll` and `AdbWinUsbApi.dll`. adb.exe is
  Authenticode-signed by Google LLC; the installer checks that.

### Hidden window at sign-in (Windows Terminal as default terminal)

Measured by watching for new top-level windows every 15 ms:

- `powershell.exe -WindowStyle Hidden` from the Run key: Windows Terminal shows
  a window for ~0.3 s, then keeps it **minimized in the taskbar for as long as
  the script runs**. A Startup-folder shortcut set to "Minimized" behaves the
  same. `FreeConsole()` inside the script does not close it.
- With the classic console host, all variants flash for ~5 ms.
- Fix used: the Run entry starts the watcher, which immediately starts a copy
  of itself with `CreateNoWindow` (no console window at all) and exits. Result:
  one ~0.3 s Terminal flash at sign-in, nothing left on screen or taskbar.

### Event handling surprises

- **Events arrive in the middle of other events.** Whenever the watcher waits
  for a process or socket on its STA thread, Windows delivers new sent messages
  (power broadcasts) and the handler for the new event runs *nested* inside the
  old one. In an early build both "PC woke up" and "display on" ran their wake
  loops at the same time. The watcher now allows one wake at a time and uses
  counters of suspends/resumes so an action can tell that things changed.
- **Sleep freezes actions halfway.** An action started just before sleep can
  finish after the wake. The first v1.0 build sent a stale SLEEP after the PC
  woke (the TV log shows the TV going off again right after the wake). Actions
  now check the counters before sending keys.
- **"Display off" comes with every manual sleep** (sometimes just before,
  sometimes just after "going to sleep"). Doing the slow display-off check
  (what is the TV showing?) at that moment delayed the fast SLEEP until the
  network was gone. The display-off action now waits 3 s and is cancelled if
  the PC goes to sleep meanwhile.
- No spurious "display on" when this TV goes to standby (no HDMI hot-plug loop).
- `SystemEvents.PowerModeChanged` Resume corresponds to PBT_APMRESUMESUSPEND
  (user present); unattended wakes don't raise it. Windows delivers it ~2 s
  after the system clock is corrected on resume; the TV then wakes ~0.3 s later.

### Shutdown and restart

- **adb.exe can't start during shutdown.** In `SessionEnding`
  (WM_QUERYENDSESSION) new processes fail with exit code `0xC0000142`
  (STATUS_DLL_INIT_FAILED), even though the adb server is still running. Fix:
  the watcher talks to its adb server directly over the local socket, using
  adb's simple text protocol (`host:connect:...`, `host:transport:...`,
  `shell:input keyevent 223`). This is also faster (SLEEP sent in ~80-100 ms
  instead of ~150-190 ms).
- `SetProcessShutdownParameters(0x3FF)` makes Windows notify the watcher
  before it closes other apps, so the adb server is still alive.
- **Restart vs shutdown:** Windows logs event 1074 (type "restart"/"power off",
  reason code; planned codes have bit 0x80000000) just before notifying apps,
  but the record becomes readable ~1 s later. Querying "the last 2 minutes"
  picked up an *earlier* restart record and kept the TV on at shutdown. The
  watcher now only considers records newer than its own start, waits up to
  1.5 s for the record, and treats planned (Windows Update) restarts as
  shutdowns. The type string is localized: only English "restart" is matched;
  otherwise the TV goes to standby.
- A per-user tool can't do anything before sign-in (only services or SYSTEM
  scheduled tasks can). Mitigation in the just-for-me mode: the watcher wakes
  the TV when someone signs in, so a blind PIN entry works after a shutdown.
  The whole-PC mode (a service) is the real fix.

### Distribution

- `irm <url> | iex` returns a plain string in both PowerShell 5.1 and 7 even
  for `application/octet-stream` (how GitHub serves release files). Published
  scripts are ASCII-only with no BOM so encoding never matters.
- Under `irm | iex`, never use `exit` (it closes the user's window) and wrap
  everything in `& { ... }` so nothing leaks into the user's session.
- Defender (signatures 1.459.x) found nothing in the install folder or the
  published scripts, and raised no alerts while they ran.

### Whole-PC mode experiments

- A service running as a dedicated virtual account (`NT SERVICE\<name>`) gets a
  profile in `C:\Windows\ServiceProfiles\<name>`, receives display on/off
  notifications through `RegisterPowerSettingNotification` with its service
  handle, can read the System log (event 1074), can reach the TV, and cannot
  write to Program Files. But **Windows keeps that profile's registry hive
  loaded until the next restart**, even after the service is deleted, so an
  uninstaller can't remove it. Chosen instead: the built-in Local Service
  account (its profile always exists), with `sc sidtype unrestricted` so the
  service still has its own identity `NT SERVICE\TVPowerSync` for file
  permissions. The adb key then lives in
  `C:\Windows\ServiceProfiles\LocalService\.android`.
- Turning the display off from an elevated process made the display state
  flicker off/on three times within 0.6 s: one more reason the watcher waits
  3 s before acting on "display off".

### Rename

- 2026-10-14: renamed from "TV Power Sync" to **ATV Companion** (repo
  `atv-companion`; folders, service and Run value `ATVCompanion`) before the
  first release. Names above in this file are the old ones. "Android" is not
  used as the first word of the name (Google's brand rules); ATV is the common
  shorthand for Android TV.

### Modern Standby (from a sister project's logs, 2026-10-14)

A HDMI-CEC tool by the same developer logged a Dell Latitude 5430 (Modern Standby)
for over a week. What it showed, and what ATV Companion does about it:

- Sleep on Modern Standby is only "display off" (no PBT_APMSUSPEND); waking is only
  "display on" (no resume events). The machine once stopped 4-6 s after the screen went
  off. -> The display-off path no longer waits 3 s: it checks what the TV shows and sends
  SLEEP at once. SLEEP is not a toggle, so sending it again on a suspend is harmless.
- **A TV going to standby drops its HDMI signal and Windows may turn the screen back on
  with nobody there**, so "display on -> WAKEUP" would undo every SLEEP. Not seen on the
  developer's desktop, seen repeatedly on the Dell. -> Limited install: "display on" wakes
  the TV only after keyboard/mouse input (watched for up to 30 min). Full install (a
  service can't see input): a "display on" within 3 s of a display connecting or
  disconnecting is ignored; the service host reports those device events.
- Fast Startup shutdown sends no PRESHUTDOWN, only display off + PBT_APMSUSPEND; standby
  can turn into hibernate 19 min to 4.6 h later with a late PBT_APMSUSPEND. Both go
  through the quick sleep path, which fails quietly when the network is gone.
- A wait can be frozen by sleep and finish minutes later. -> The watcher compares
  Windows' sleep-counting and non-sleep-counting clocks: an event handled only after the
  PC slept is skipped, and a check that spanned a sleep is not acted on.
- Windows repeats display states (Win+L sends "on" to a screen that is on); only changes
  are acted on (already the case).

### "Stay awake" keeps the TV reachable in standby (2026-10-14)

After the TV lost Wi-Fi and was reset, it began dropping off the network about 10 s into
standby, so it could be put to sleep but not woken. Measured over 3 minutes of standby,
checking ping and the ADB port every 2 s:

| Stay awake | Wireless debugging | Reachable in standby |
|---|---|---|
| on | on | all 3 minutes |
| off | off | dropped at ~9-10 s |
| on | off | all 3 minutes (118/118 checks) |
| off (set over ADB) | off | dropped at 10 s |

So the Developer option "Stay awake" (`settings global stay_on_while_plugged_in`, non-zero)
is what keeps it reachable; wireless debugging is irrelevant. KEYCODE_SLEEP still puts the
TV in standby with it on. The reset had turned it off. The installer now turns it on
(value 3) and the watcher's keep-alive puts it back if it is found off
(`keepTvReachable` in config.json opts out).
