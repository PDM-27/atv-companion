# ATV Companion

Make your **Android TV or Google TV** behave like a monitor for your Windows PC:

- the PC sleeps, shuts down or turns its display off → **the TV goes to standby**
- the PC wakes, starts or turns its display back on → **the TV turns on**

No extra hardware, no app on the TV. It talks to the TV over your home network
with ADB (Android Debug Bridge), the standard Android developer connection.

> **Tested on one TV so far** (TCL QM7K, Android TV 14). It should work on most
> TVs with Android TV / Google TV built in, but please
> [tell us how it goes on yours](#help-us-test-other-tvs), good or bad.

---

## Contents

- [Is it for you?](#is-it-for-you)
- [Install](#install)
- [Change TV, update, uninstall](#change-tv-update-uninstall)
- [Is it safe?](#is-it-safe)
- [Good to know](#good-to-know)
- [FAQ and troubleshooting](#faq)
- [Help us test other TVs](#help-us-test-other-tvs)
- [How it works](#how-it-works)

---

## Is it for you?

**You need**
- Windows 10 or 11.
- A TV with **Android TV or Google TV built in**, on the same home network as the PC.
- About two minutes on the TV to turn on USB debugging (below).

**Not for**
- Streaming sticks and boxes (Chromecast with Google TV, NVIDIA Shield, onn, Fire TV...).
  There, Android runs on the stick, not the TV: waking the stick would switch the TV
  to the stick's input instead of your PC.
- TVs that drop off the network in standby (see [limitations](#good-to-know)).

### Honest comparison with HDMI-CEC

HDMI-CEC is the "official" way devices switch each other on and off over the HDMI cable.
PC graphics cards don't support it, so CEC needs an adapter (for example Pulse-Eight's
USB-CEC adapter, which can also limit HDMI passthrough, e.g. to 4K60).

| | ATV Companion | HDMI-CEC adapter |
|---|---|---|
| Extra hardware | **None** | USB-CEC adapter |
| Install | **One command** | Adapter, cabling, driver/app |
| System load | **Very light** (idle, wakes on events) | Light |
| Works when the TV drops Wi-Fi in standby | No | **Yes** |
| Connection | Your home network (Wi-Fi or Ethernet) | **The HDMI cable itself** |
| Speed and reliability | Good, but depends on the network: Wi-Fi needs a few seconds to reconnect after the PC wakes | **More reliable, more direct** |
| What it controls | Standby and wake only | Power, input switching and more |

If you need rock-solid power control or input switching, CEC hardware is the better tool.
If you want something free that just works on a TV that supports it, try this.

---

## Install

### 1. On the TV: turn on USB debugging (once)

Menu names vary by brand and software version. The usual paths:

1. **Turn on Developer options.** Go to **Settings → System → About** and select
   **Android TV OS build** (on some TVs just **Build**) **7 times**, until the TV says you are
   now a developer. It may ask for your TV's PIN.
   - Google TV: it's the same item, under **Settings → System → About**.
   - Older Android TV: sometimes **Settings → Device Preferences → About → Build**.
2. **Turn on USB debugging.** Go back to **Settings → System → Developer options** (older
   Android TV: **Settings → Device Preferences → Developer options**) and turn on
   **USB debugging**. Despite the name, this is what allows debugging over your network.
   Some TVs call it *ADB debugging* or *Network debugging*.
3. Leave **Developer options** on, and if the TV is ever reset, do these steps again.
   (ATV Companion also turns on the developer setting **Stay awake** for you; see the FAQ.)
4. Optional but recommended: in your router, **reserve the TV's IP address** so it doesn't
   change. (If it does change, ATV Companion usually finds the TV again by itself.)

> If your TV offers only **"Wireless debugging"** (the kind that pairs with a code and uses a
> changing port) and no USB/ADB/Network debugging switch, ATV Companion can't connect to it
> yet. Please [let us know](#help-us-test-other-tvs) which TV it is.

During install, the TV asks **"Allow USB debugging?"**: tick **"Always allow from this
computer"** and choose **Allow**.

### 2. On the PC: run one command

**Full install (recommended)**: works for every Windows account and even at the sign-in
screen.

1. Open the Start menu, type **PowerShell**, then choose **Run as administrator**.
2. Paste this and press Enter:

   ```powershell
   irm https://github.com/PDM-27/atv-companion/releases/latest/download/install.ps1 | iex
   ```

3. Answer the questions: press Enter to install, pick your TV from the list, then **on the
   TV choose "Allow" and tick "Always allow from this computer"**. That's it.

**Limited install**: only if you can't use an administrator account, your antivirus blocks
Windows services, or you want it for one account only. Same command, in a **normal**
(not administrator) PowerShell window. It works only for your account and only after you
sign in, so it can't turn the TV on for the sign-in screen.

### Why a PowerShell command?

PowerShell is built into Windows, so there's nothing to download first and nothing
pre-built to trust: the installer is a plain text script you can read. `irm` downloads it
from this project's latest release and `iex` runs it. If you'd rather look first, open the
link in your browser, or download it and run it from the file.

---

## Change TV, update, uninstall

Use the same kind of PowerShell window you installed with (administrator for the full
install, normal for the limited install).

| To | Run |
|---|---|
| Use a different TV, or approve again | `irm https://github.com/PDM-27/atv-companion/releases/latest/download/change-tv.ps1 \| iex` |
| Update or repair | Run the install command again and choose **Reinstall or update** (keeps your settings) |
| Uninstall | `irm https://github.com/PDM-27/atv-companion/releases/latest/download/uninstall.ps1 \| iex` |

Uninstalling removes everything it added. To make the TV forget the PC too: on the TV,
**Developer options → Revoke USB debugging authorizations**, and turn USB debugging off if
nothing else needs it.

---

## Is it safe?

- **Read it first.** Everything is plain PowerShell plus one short C# file (see below).
  The installer explains each step in its header. Source: [`src/`](src).
- **Official source only.** The only official version is this repository and its
  [Releases](../../releases). Anyone can copy and change open-source code, so don't run
  versions of ATV Companion from anywhere else. See [SECURITY.md](SECURITY.md).
- **What it adds to your PC**
  - *Full install:* the `ATV Companion` Windows service, `%ProgramFiles%\ATVCompanion`
    (program) and `%ProgramData%\ATVCompanion` (settings and log). The service runs as
    Windows' low-privilege **Local Service** account, never as an administrator or SYSTEM.
    Windows services must be real programs, so the installer builds a tiny one
    (`ATVCompanionService.cs`, about 200 lines, kept next to it so you can read it) with
    the C# compiler that ships with Windows. Nothing pre-built is downloaded from this project.
  - *Limited install:* `%LOCALAPPDATA%\ATVCompanion` and a startup entry you can see in
    **Task Manager → Startup apps**. No administrator rights at all.
  - Both: Google's **adb** tool, downloaded from Google during install and checked to be
    signed by Google. No scheduled tasks, no browser or system settings changes.
- **TV security.** Network debugging only accepts computers you approved on the TV with
  "Allow". You can revoke them at any time (see above). Leaving USB debugging on does mean
  an approved PC can control the TV; that's what ATV Companion uses.
- **Antivirus.** Windows Defender raised nothing in testing. Scripts that install services
  can look suspicious to some antivirus products; if yours complains, read the script, and
  use the limited install if you prefer.
- **License.** MIT: free to use, change and share, with no warranty (see [LICENSE](LICENSE)).

---

## Good to know

**What it does well**
- Puts the TV in standby within about a tenth of a second of the PC starting to sleep
  or shut down (in testing).
- Turns the TV on as soon as the PC's network is back after a wake: within a second of
  Windows reporting the wake in testing, plus however long Wi-Fi takes to reconnect.
- **Leaves the TV alone** if it's showing something else (an app or another HDMI input)
  when the PC's display turns off.
- Keeps the TV on when **you restart** the PC, so you can see it boot. Automatic restarts
  for Windows updates turn it off.
- Finds the TV again if its IP address changes (same router, same network).

**Limitations**
- **Standby and wake only.** It doesn't switch inputs, change volume, or control anything else.
- **Some TVs won't work.** Some turn off Wi-Fi or network debugging in standby (sometimes
  there's a setting like "Remote start", "Wake on network" or "Quick start" that keeps it
  on). Then the TV turns off with the PC but can't be woken. Nothing on the PC can fix that.
- **It relies on your network**, which is less direct than an HDMI cable: after the PC
  wakes, Wi-Fi needs a few seconds to reconnect before the TV can be told to wake.
- **At power-on**, the TV turns on once Windows has connected to the network (about 15 to
  20 seconds after power-on on Wi-Fi in testing), not the instant the PC starts.
- **Modern Standby PCs** (many laptops): supported, based on measurements from a Modern Standby
  laptop, but not yet tested with ATV Companion itself. Reports welcome.

---

## FAQ

**Why does ATV Companion turn on the TV's "Stay awake" setting?**
Many TVs switch their Wi-Fi off a few seconds into standby, and then nothing can wake them
over the network. On the test TV, the Developer option **Stay awake** keeps the network up:
with it, the TV stayed reachable in standby; without it, it dropped off after 10 seconds. The
TV still goes to standby normally when told to. ATV Companion turns it on at install and puts
it back if a TV update or reset turns it off. Possible side effects: the TV's own "sleep after
no activity" timer may not switch it off by itself, and standby may use a little more power.
To stop this, set `"keepTvReachable": false` in `config.json`.

**The TV turns off but doesn't turn back on.**
Your TV probably drops off the network in standby, even with **Stay awake** on. Look for a setting such as "Remote start",
"Wake on network", "Quick start" or "Networked standby" and turn it on, if your TV has one.
If not, HDMI-CEC hardware is the alternative.

**Waking takes a few seconds.**
That's the PC's Wi-Fi reconnecting after sleep. Ethernet is fastest. On Wi-Fi, setting the
power plan's *Wireless Adapter Settings → Power Saving Mode* to *Maximum Performance* can help.

**The "Allow" question never appeared on the TV.**
Make sure you picked the right device (if several were found) and that USB debugging is on.
Turning USB debugging off and on again usually makes the TV ask again. Then run the change-TV
command.

**The TV turned off while I was watching something on it.**
ATV Companion leaves the TV alone when the PC's display turns off while the TV shows an app
or another input, but it still turns the TV off when the PC itself sleeps or shuts down.

**I have no TV remote and the TV is off at the sign-in screen.**
Use the full install: it turns the TV on at the sign-in screen. With the limited install,
you can sign in "blind" (press a key, type your PIN, press Enter) and the TV turns on right
after. The Google TV app on your phone also works as a remote for most Android TVs.

**Work or school PC?** IT policies may block scripts or services; the installer tells you if
so. Ask whoever manages the PC.

**Can I turn off the display-following, or the "leave alone" check?**
Yes: set `"followDisplay"` or `"leaveTvAloneWhenInUse"` to `false` in `config.json`
(`%ProgramData%\ATVCompanion` for the full install, `%LOCALAPPDATA%\ATVCompanion` for the
limited one). Changes apply right away.

---

## Help us test other TVs

ATV Companion has only been tested on one TV. If you try it, please
[open an issue](../../issues/new/choose), whether it works or not, with your TV model and
the log:

| Install | Log file |
|---|---|
| Full | `C:\ProgramData\ATVCompanion\log.txt` |
| Limited | `%LOCALAPPDATA%\ATVCompanion\log.txt` (paste that into File Explorer's address bar) |

The log shows what happened and when (no personal data apart from your TV's and router's
local network addresses, which you can blank out if you like).

---

## How it works

A small background watcher listens to Windows' power events: sleep, wake, shutdown,
restart, and display off/on. It reacts by sending the TV the standard Android
**sleep** or **wake** key over network ADB. It reads the TV's power state first and only
ever uses the on/off toggle key when the state is confirmed, so it can't accidentally
switch the TV the wrong way. Time-critical steps talk directly to adb's background server
(no programs started), because Windows doesn't allow starting programs during shutdown.

The full install runs the watcher inside a Windows service so it works before anyone
signs in; the limited install runs it as a hidden startup app.

The design history, decisions and measurements are in [docs/HISTORY.md](docs/HISTORY.md)
and [docs/SPEC.md](docs/SPEC.md).

### Development

```powershell
.\tools\check.ps1        # build dist\, run PSScriptAnalyzer and Pester (Windows PowerShell 5.1)
.\tools\serve.ps1        # serve dist\ at http://localhost:8000 to test "irm | iex"
```

`src\` holds the sources; `build.ps1` combines them into the self-contained scripts in
`dist\` that are published with each release. Releases are built by GitHub Actions from
version tags.
