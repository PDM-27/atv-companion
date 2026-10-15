# Spec

## Target user experience

**On the TV, once (manual; can't be automated):** enable Developer options and
turn on USB debugging.

**On the PC:**

1. Paste the install command into a normal (not admin) PowerShell window.
2. Type the TV's IP address (or pick it from a scan, if that feature is chosen).
3. The installer says "Look at your TV and choose Allow (tick 'Always allow
   from this computer')", waits until the TV authorizes the PC, reads the TV's
   power state to prove the link works, and prints success.
4. Done. The watcher is running now and starts at every login.

**Months later:** a one-line command to change the TV, and a one-line command
to uninstall everything.

Rough shape of the install output:

```
ATV Companion installer
  Checking your system...            OK
  Downloading Android platform-tools from Google...   OK
TV IP address: 192.168.1.x
  Connecting to your TV...
  >> Look at your TV and choose "Allow" (tick "Always allow from this computer")
  Authorized. Your TV is currently ON.
  Starting ATV Companion...          OK

Done. Your TV will now sleep and wake with this PC.
  Change TV:   irm <url>/change-tv.ps1 | iex
  Uninstall:   irm <url>/uninstall.ps1 | iex
```

## Components

- **Install** (bootstrap fetched with `irm | iex`)
- **Change TV**
- **Uninstall**
- **Watcher** (the long-running runtime, started at login)
- **config.json**
- **README** with install/change/uninstall commands, a short "what this does /
  read it first" section, and the FAQ

Packaging is open (see Open decisions): either three separate scripts, or one
script with an `-Action` parameter plus three short one-liners. Either way,
running install when already installed should offer: change TV / reinstall or
update (keep config) / uninstall / cancel.

## Install layout (permanent once v1.0 ships)

```
%LOCALAPPDATA%\ATVCompanion\
    watcher.ps1
    config.json          TV IP, version, adb server port, whether we created ~/.android, ...
    platform-tools\      only the files adb needs (adb.exe, AdbWinApi.dll, AdbWinUsbApi.dll, ...)
    log.txt              only if logging is chosen; size-bounded
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
    value "ATVCompanion"  → powershell.exe ... -File "<install>\watcher.ps1"
```

Confirm final names with the user before v1.0. Never change them afterward.

## Installer steps

1. **Preflight.**
   - Windows only.
   - Not elevated; if elevated, refuse with instructions.
   - `$ExecutionContext.SessionState.LanguageMode` is FullLanguage; if not
     (AppLocker / Constrained Language), explain and stop.
   - Enable TLS 1.2 for older Windows PowerShell 5.1 setups.
   - Check `Get-ExecutionPolicy -List`: if MachinePolicy or UserPolicy would
     block `-ExecutionPolicy Bypass`, explain (work/school PC) and stop.
2. **Existing install?** Offer change TV / reinstall-update / uninstall /
   cancel.
3. **Stop any running watcher** of ours before replacing files.
4. **Download platform-tools** from Google's stable "latest" Windows URL
   (verify it's still current) into a temp folder, extract, and copy only the
   needed files. Decide how to show Google's SDK terms (check what's
   appropriate for a direct download).
5. **Install watcher.ps1**, fetched from the same release/tag as the
   installer, or embedded in it. Either way, no version skew.
6. **Ask for the TV IP.** Validate IPv4. Optional scan (see Open decisions).
7. **Connect and authorize.**
   - `adb connect <ip>:5555` prints "connected" even when the TV hasn't
     authorized the PC yet. Check `adb -s <ip>:5555 get-state` or
     `adb devices` for `device` vs `unauthorized`.
   - While unauthorized, tell the user to look at the TV and press Allow.
   - Time out after about 60 s with a clear retry option.
8. **Confirm** by reading `dumpsys power` → `mWakefulness` and showing it in
   plain words ("Your TV is currently ON").
9. **Save config.**
10. **Register the Run value and start the watcher now**, using the same
    command line, so no reboot is needed.
11. **Print success** with the change-TV and uninstall one-liners and a pointer
    to the FAQ.

## Watcher requirements

- Port the reference logic and keep what's proven:
  - keep-alive `adb connect` every 120 s;
  - suspend: one KEYCODE_SLEEP (223), no state read;
  - resume: poll every 100 ms for up to 10 s, send KEYCODE_WAKEUP (224) on
    first contact, then verify;
  - KEYCODE_POWER only when the opposite state is confirmed.
- Keep the STA + `Application.Run()` + `SystemEvents` structure (see HISTORY).
- Read config at startup, or re-read it on each event so change-TV needs no
  restart.
- Single instance (named mutex), so reinstalling or launching twice can't
  create duplicate watchers.
- Call the bundled `adb.exe` by full path. Run its server on a non-default
  port via `ANDROID_ADB_SERVER_PORT` (verify it's honored) so it doesn't fight
  another adb of a different version (Android Studio, scrcpy) on port 5037.
- Never crash when the TV is unreachable. Never let an exception escape an
  event handler.
- Near-zero CPU while idle.

## Change TV

- Requires an existing install; otherwise say so and point to the install
  command.
- Ask for the new IP, run the same connect/authorize/confirm flow, save
  config, and restart the watcher (or rely on per-event config reload).

## Uninstall

1. Stop the watcher: find `powershell.exe` processes whose command line
   contains our install path (`Get-CimInstance Win32_Process`). Reading the
   command lines of your own processes shouldn't need admin; verify.
2. `adb kill-server` on our port, so adb releases its files.
3. Remove the Run value.
4. Delete the install folder. The uninstaller runs from memory (`irm | iex`),
   so there's no self-delete problem, but make sure no process has the folder
   as its working directory.
5. ADB keys (`%USERPROFILE%\.android`): other Android tools share this folder.
   Delete it only if the installer created it (recorded in config), or keep
   keys inside the install folder if adb supports that (see Known risks).
6. Tell the user they can also clear this PC on the TV (Developer options →
   "Revoke USB debugging authorizations") and turn USB debugging off.
7. Must be safe to run twice, and safe on a partial or older install.

## README / FAQ topics

- What it does and how (ADB over the local network), and "read the script
  before you run it" with links to the source.
- Enabling Developer options and USB debugging. The menu path varies by TV
  model and firmware; give the common Android TV path (Settings → System →
  About → press Build 7 times) and say it may differ.
- Reserve the TV's IP in the router (or use change-TV if it changes).
- Sleep works but wake doesn't: some TVs drop off the network in standby.
  Nothing on the PC can fix that; HDMI-CEC hardware is the alternative.
- Wake is slow: Wi-Fi needs a few seconds to reconnect after sleep; Ethernet
  is fastest.
- The Allow prompt didn't appear on the TV.
- Work or school PC: Group Policy may block it.
- Antivirus warnings, and why the project is plain readable scripts.
- Security: network ADB only works for computers the user has approved on
  the TV; how to revoke.
- How to uninstall.

## Decisions (made with the user, 2026-10-11 and 2026-10-12)

1. Names: repo `atv-companion`, "ATV Companion". Just-for-me mode:
   `%LOCALAPPDATA%\ATVCompanion`, Run value `ATVCompanion`. GitHub account: to be
   set up (no GitHub access from the Claude session yet).
2. License: MIT.
3. URLs: release-asset URLs
   (`https://github.com/<user>/atv-companion/releases/latest/download/<file>.ps1`).
4. Logging: small capped log (`log.txt`, ~256 KB, one rollover `log.old.txt`).
5. Features in v1.0: network scan for TVs; re-find the TV by MAC address (only
   on the home network, identified by the router's MAC, at most every 10 min);
   TV follows the display off/on (on by default); **leave the TV alone** when
   it shows something other than the PC (the PC's app/input is recorded at
   install); wake the TV when someone signs in (not for Remote Desktop); keep
   the TV on for a restart a person started, standby for shutdowns and
   Windows Update restarts.
6. Packaging: three self-contained scripts (install, change-tv, uninstall)
   built from shared sources by `build.ps1`; the watcher is embedded in
   install.ps1. Running install again offers change TV / reinstall / uninstall.
7. Shutdown: TV goes to standby. README documents the phone-remote app,
   signing in "blind", and HDMI-CEC hardware for people without a remote.
8. **Two install modes before the first release** (see "Whole-PC mode").

## Whole-PC mode (admin)

Goal: monitor-like behavior for every account, including the sign-in screen
and boot, for people who use the TV as their only display.

- Chosen by running the install command in an **admin** PowerShell window. A
  normal window installs just-for-me as before (never per-user from an
  elevated window).
- A Windows service `ATVCompanion` runs under the virtual account
  `NT SERVICE\ATVCompanion` (low privilege, never SYSTEM), start type Automatic.
- The service host is a small C# program whose source is in the install
  script, compiled on the PC with the .NET Framework C# compiler that ships
  with Windows. It answers the Service Control Manager, receives power events,
  display on/off (RegisterPowerSettingNotification with the service handle)
  and pre-shutdown, and runs the same watcher logic (PowerShell, in-process).
- Program files in `%ProgramFiles%\ATVCompanion` (admin-only writes); settings
  and log in `%ProgramData%\ATVCompanion` (admins full, the service account
  modify, users read). Its own adb server port (15038), so it never shares a
  server with a just-for-me install.
- The TV approves the *service account's* adb key: the installer starts the
  service, then waits for "Allow" through the service's adb server.
- Change TV and uninstall need an admin window for this mode and say so.
- Behavior: TV wakes when the display turns on (boot / sign-in screen / user
  wake), sleeps on suspend, display off (same "leave alone" rule) and
  pre-shutdown; a restart a person started keeps the TV on; Windows Update
  restarts and unattended wakes don't turn the TV on.
- Installing whole-PC mode removes the current user's just-for-me install (and
  says so); a just-for-me watcher exits if the service exists.

## Original open decisions (kept for reference)

The six open decisions in the original spec (names, license, URL scheme,
logging, optional features, packaging) are answered above.

## Known risks to investigate early

- **Hidden window at login.** On Windows 11 with Windows Terminal as the
  default terminal app, `powershell.exe -WindowStyle Hidden` may leave a
  visible Terminal window instead of a brief flash. Test with both settings
  (Settings → System → For developers → Terminal: "Windows Console Host" and
  "Windows Terminal") and pick a launch method that hides correctly without
  VBScript or `--headless`.
- **ADB key location.** Check `adb --help` (environment variables) and adb's
  source for a way to keep keys out of `%USERPROFILE%\.android`. If there is
  one, store keys in the install folder for a clean uninstall; if not, apply
  the "only delete what we created" rule.
- **Modern Standby PCs.** `PowerModeChanged` may not behave as on S3 machines.
  Consider also listening for console display state changes
  (`RegisterPowerSettingNotification` with `GUID_CONSOLE_DISPLAY_STATE`).
  At minimum, document it.
- **Shutdown timing.** `SessionEnding` allows only a short time. Measure that
  the sleep key actually goes out; consider using the fast single-key path, as
  for suspend.
- **Strict adb output parsing.** Match "connected to" / "already connected
  to" exactly, and use `get-state` for authorization.
- **Antivirus / Defender.** Confirm install and watcher aren't flagged.

## Remove the prototype (on this PC, with the user's OK, before testing)

- Stop running watcher processes: `powershell.exe` whose command line
  contains `tv-power-sync.ps1` or `tv-power-watcher.ps1`.
- From the user's Startup folder (`shell:startup`), delete
  `start-tv-sync.vbs` and/or `start-tv-watcher.vbs`.
- Old folders, if present: `C:\TVSync`, `C:\TVControl`. They hold old scripts,
  logs, and possibly `tv_cert.pem` / `tv_key.pem` from the androidtvremote2
  attempt.
- Optional, ask the user:
  - remove `C:\platform-tools` and its PATH entry (the new installer brings
    its own adb);
  - `pip uninstall androidtvremote2`;
  - revert the CurrentUser execution policy (set to RemoteSigned during
    prototyping; harmless).
- `%USERPROFILE%\.android\adbkey`: leave it, unless the user wants to test the
  true first-run flow. Deleting it means pressing Allow on the TV again, which
  is actually a good test.

## Acceptance criteria

- Fresh Windows 11 user with no adb, normal PowerShell 5.1 window: the
  one-liner installs, asks for the IP, guides authorization, confirms the TV
  state, and starts the watcher. No reboot, no admin prompt.
- Running elevated → clear refusal.
- Running install twice → no duplicate watchers; existing config kept or
  changed on request.
- PC sleep → TV sleeps. PC wake → TV wakes as soon as the network allows.
  An already-on TV is never toggled off by wake; an already-off TV is never
  toggled on by sleep.
- PC shutdown → TV sleeps (verify on hardware).
- Change-TV and uninstall work from fresh one-liners at any later time.
- Uninstall leaves no processes, files, Run value, or `.android` folder that we
  created.
- TV unreachable → no crash; the watcher keeps running.
- Coexists with another adb installed on the PC.
- No VBScript, no `--headless`, no Task Scheduler, no admin.
- PSScriptAnalyzer clean, or each suppression justified.

## Testing

- **Lint:** PSScriptAnalyzer.
- **Unit tests (Pester)** for pure functions: `mWakefulness` parsing, adb
  output parsing, IP validation, config read/write.
- **Real TV from this PC:**
  - run the installer from a local file;
  - then exactly as users will, through `irm | iex` from a local HTTP server
    (for example `python -m http.server` in the repo, then
    `irm http://localhost:8000/install.ps1 | iex`), before anything is
    published;
  - then from GitHub once the user approves publishing.
- **Manual tests by the user:**
  - sleep, wake, shutdown, restart, sign out and back in;
  - TV already off when the PC sleeps; TV already on when the PC wakes;
  - TV unreachable (TV unplugged);
  - change TV; uninstall; reinstall.
- **Optional CI:** GitHub Actions on `windows-latest` running PSScriptAnalyzer
  and Pester (free for public repos).
