========================================================================
 Quest VD Wired Watchdog
========================================================================

A small resident script that automatically restores the Quest 3 wired
connection provided by Quest VD Wired when it drops.

On its own, Quest VD Wired does not come back after the headset is
powered off and on again - you have to click "Diagnose and fix" from its
tray menu every time. This script removes that chore.

NOTE: This is an unofficial companion tool. It is not affiliated with,
      endorsed by, or sponsored by Meta, Virtual Desktop, Genymobile,
      or the Quest VD Wired project.


------------------------------------------------------------------------
 What it handles
------------------------------------------------------------------------

  Headset powered off -> on ....... reconnects automatically
  Headset sleep -> wake ........... reconnects automatically
  Cable unplugged / loose contact .. detects recovery and reconnects
  While the cable is unplugged ..... waits, does nothing; after 15 s it
                                     shows a Windows notification
  Asleep with USB still plugged in . waits, does nothing

A system tray icon shows both that the watchdog is running and whether
the link is up.


------------------------------------------------------------------------
 Requirements
------------------------------------------------------------------------

  - Windows 10 / 11
  - Quest VD Wired (install it separately)
      https://github.com/kkoemets/quest-vd-wired
  - Meta Quest 3 with Developer Mode and USB debugging enabled
  - A USB 3 data cable

Runs on the PowerShell 5.1 that ships with Windows. Nothing else to
install.


------------------------------------------------------------------------
 Setup
------------------------------------------------------------------------

  1. Set up Quest VD Wired first and confirm you can connect manually
     at least once.

  2. Right-click the ZIP -> Properties -> tick "Unblock" -> OK,
     BEFORE extracting. Files from a downloaded ZIP are marked by
     Windows and may trigger a security warning otherwise.

  3. Extract the quest-vd-wired-watchdog folder into the Quest VD Wired
     folder.

       quest-vd-wired-v4.1.4-windows-x64\   <- Quest VD Wired folder
       |- quest-vd-wired.exe
       `- quest-vd-wired-watchdog\          <- extract here
          |- install.cmd
          |- uninstall.cmd
          |- run_debug.cmd
          |- watchdog.ps1
          |- README.txt
          |- README_EN.txt
          `- LICENSE.txt

  4. Open the quest-vd-wired-watchdog folder and double-click install.cmd

That is all. It does three things at once:

  - Detects the paths to adb.exe and quest-vd-wired.exe and writes
    watchdog.config.json
  - Registers itself in the Windows Startup folder
  - Starts running immediately

A round icon in the system tray means it worked.

If Quest VD Wired is installed somewhere else, auto-detection will fail.
Put the real path into questVdWiredPath in watchdog.config.json
(see "Configuration" below).


------------------------------------------------------------------------
 Updating
------------------------------------------------------------------------

* Updating the watchdog

  Extract the new ZIP over the old one and run install.cmd. The running
  old watchdog is stopped and replaced automatically.
  watchdog.config.json is kept.

* Updating Quest VD Wired itself

  Each Quest VD Wired version usually lives in its own folder
  (e.g. quest-vd-wired-v4.1.4-windows-x64 -> quest-vd-wired-v4.1.34-windows-x64).

    1. Extract the watchdog ZIP again into the new Quest VD Wired folder
    2. Run install.cmd in that folder

  The watchdog running from the old folder is stopped and the autostart
  entry is switched to the new folder. If the old Quest VD Wired is still
  running, it is replaced with the new one once the headset is awake.

  Do not copy watchdog.config.json from the old folder. It contains the
  path to the old quest-vd-wired.exe, so the old version would keep
  being started.


------------------------------------------------------------------------
 Files
------------------------------------------------------------------------

  install.cmd .......... start now + register autostart
                         run this once, when setting up

  uninstall.cmd ........ stop + remove the autostart entry
                         run this only when you want to stop using it

  run_debug.cmd ........ run in the foreground to watch the log
                         does NOT register autostart; for troubleshooting

  watchdog.ps1 ......... the script itself

  README.txt ........... Japanese documentation
  README_EN.txt ........ this file
  LICENSE.txt .......... license

  watchdog.config.json is generated on first run
  (it is not part of the distribution)


------------------------------------------------------------------------
 System tray
------------------------------------------------------------------------

A round icon appears next to the clock. If you cannot see it, click the
"^" arrow and drag the icon into the visible area.

  Green ... connected
  Yellow .. headset not detected over USB (unplugged / loose cable /
            powered off). The headset is not charging in this state.
  Grey .... USB connected but the headset is asleep

If the icon stays yellow for 15 seconds, a Windows notification is shown
(once per disconnection). Another one tells you when USB is back.
  Red ..... disconnection detected / recovering / more than one USB device

Hover for details. Right-click for:

  - Open log
  - Open config file
  - Reconnect now   ... skip the detection delay and restart immediately
  - Exit            ... stop the watchdog (autostart entry is kept)


------------------------------------------------------------------------
 Configuration
------------------------------------------------------------------------

Edit watchdog.config.json. To apply changes, run install.cmd again
(the running watchdog is replaced automatically).

Paths you write by hand are never overwritten by auto-detection. The one
exception is the adb bundled with Quest VD Wired (under
%LOCALAPPDATA%\GnirehtetVD): if an update moves it to a new folder, it is
detected again automatically.

  adbPath            auto      path to adb.exe
  questVdWiredPath   auto      path to quest-vd-wired.exe
  logPath            (below)   where the log is written
  intervalSec        10        polling interval, seconds
  failThreshold      3         consecutive failures before restarting
  settleSec          60        max seconds to wait for recovery
  settlePollSec      2         how often to check during recovery
  cmdTimeoutSec      10        adb command timeout, seconds
  maxRestarts        3         consecutive restart attempts allowed
  giveUpWaitSec      600       cool-down after giving up, seconds
  notifyNoUsbSec     15        notify after this many seconds without USB (0 = off)

  logPath default: %LOCALAPPDATA%\GnirehtetVD\watchdog.log


 * Do not lower failThreshold

   With a marginal USB connection the link can drop for a moment every
   so often. The value 3 exists so that those transient blips do not
   trigger a restart. Setting it to 1 will restart the app repeatedly
   during normal use and make things worse, not better.


------------------------------------------------------------------------
 How it works
------------------------------------------------------------------------

The link is considered alive only when all three conditions hold:

  1. A tun interface exists on the headset
  2. quest-vd-wired.exe is running on the PC
  3. adb reverse mappings are in place

  - Headset not listed by "adb devices"
      -> cable or power problem. Wait, do nothing.

  - Two or more USB devices attached (e.g. a phone)
      -> wait, do nothing. Quest VD Wired itself cannot pick a device
         either. Wireless adb and emulators are not counted.

  - Headset listed but asleep
      -> wait, do nothing. The headset app stops while asleep, so a
         restart would not reconnect anyway.

  - Headset listed but any of the three conditions is missing
      -> restart quest-vd-wired.exe
         (without creating a console window)

If either app is simply not running, the restart happens immediately
instead of waiting for three consecutive failures. An app that is not
running is a definitive failure, not a transient blip like a marginal
cable. This covers the moments right after a PC reboot and right after
the headset is powered back on; both recover within a few seconds.

Checking for the tun interface alone is not enough. If the PC reboots while
the headset stays on, the VPN on the Quest side survives and the tun
interface remains, but on the PC there is neither a host process nor any
adb reverse mapping. The PC-side conditions exist so that this hollow state
is not mistaken for a healthy link.

Nothing is restarted while the link is healthy.


------------------------------------------------------------------------
 Troubleshooting
------------------------------------------------------------------------

* No tray icon appears

  Look for a "startup failed" line in the log
  (%LOCALAPPDATA%\GnirehtetVD\watchdog.log); it says why. You can also
  run run_debug.cmd to see the error. If adb.exe or
  quest-vd-wired.exe could not be located, write the paths directly
  into watchdog.config.json.

* The icon is red and says there is more than one USB device

  Unplug any Android device other than the Quest (a phone, etc.).

* It keeps reconnecting over and over

  Quest VD Wired itself cannot recover. After 3 failed attempts the
  watchdog waits 10 minutes. If the tray icon stays red, use
  "Diagnose and fix" from the Quest VD Wired tray menu.

* I cannot tell whether it is running

  Right-click the tray icon -> Open log. Entries are written only when
  the state changes, so a quiet log means the link is stable.

* The script fails to start after editing

  If you edit watchdog.ps1, save it as UTF-8 WITH BOM. Without the BOM,
  Windows PowerShell 5.1 misreads the encoding and reports a syntax
  error on an unrelated line.


------------------------------------------------------------------------
 Notes for developers
------------------------------------------------------------------------

The following were confirmed by testing. Do not do these if you build
something similar.

* Do not invoke quest-vd-wired.exe with a subcommand

  Running status / repair / start / stop while it is resident tears down
  the live session. status cannot be used as a health check.

* Do not run adb kill-server

  The adb reverse mappings live inside the adb server, so restarting it
  breaks the link.

* Do not use ping as a reachability test

  gnirehtet does not relay ICMP, so ping shows 100% loss even when the
  connection is perfectly fine. Check for the tun interface instead.


------------------------------------------------------------------------
 License
------------------------------------------------------------------------

MIT License (see LICENSE.txt)

This script only launches Quest VD Wired as an external process. It does
not include or redistribute any part of it.

 Related projects

   Quest VD Wired   https://github.com/kkoemets/quest-vd-wired
                    Apache License 2.0

   gnirehtet        https://github.com/Genymobile/gnirehtet
                    Copyright (C) 2017 Genymobile
                    Apache License 2.0
