# music-phone-refresh

Installs the latest build of the app on the iPhone **every time it is plugged in** to
this laptop — a fresh seven-day signature and the newest build, whatever the phone
already had. While the phone stays plugged in, any build published since is installed
too. A failed install is tried again after 30 seconds, then a minute, two, five, and
every ten minutes from then on. Each install shows a desktop notification.

Plugged in means on USB (`lsusb`). `usbmuxd` listing the phone (`idevice_id -l`) only
means it is ready: `usbmuxd` can lose sight of a phone that never left, and seeing it
again is not a new plug-in, so it does not install again. An iPhone also re-enumerates
by itself 20 to 35 seconds after it is plugged in (off USB for 3 to 9 seconds, back with a
new device number), which cuts off an install already under way. So the first install
waits for that re-enumeration, or a minute if there is none, and for `usbmuxd` to have
listed the phone for 15 seconds since. Off USB for 15 seconds, the phone is unplugged.

It reads the rolling `latest` release that every push to `main` publishes, and installs
with `xtool install --usb`, never with a timeout (an interrupted install collides with
the next one), and never alongside another app's `xtool install`, such as the JellyMC
watcher's. If it stalls at *Verifying*, the app is playing music — iOS will not replace
an app holding an audio session.

If the phone is on USB but `usbmuxd` has not listed it for a minute, the notification
says so. That used to happen on most plug-ins until `usbmuxd` was set up as below. A
phone that is locked, or waiting at *Trust This Computer?*, is listed but cannot be
installed on; the notification says to unlock it and tap Trust, and the install is tried
again by itself.

## usbmuxd that does not wedge (`usbmuxd/`)

Gentoo's udev rule starts `usbmuxd --udev` per plug-in, with hotplug off: it finds devices
only when another instance nudges it. An iPhone re-enumerates about twenty seconds after
it is plugged in (a USB disconnect and a new device number, under `apple-mfi-fastcharge`).
The udev-started instance kept a stale entry for the first enumeration, its preflight
failed with lockdown error -8, and it never picked up the second, so neither this
watcher nor JellyMC's could see the phone until `usbmuxd` was killed by hand. The logs
showed that sequence on every wedge (`Cannot find device entry while removing USB
device`, then `lockdown error -8`).

So `usbmuxd` runs as an OpenRC service instead, with hotplug on, under `supervise-daemon`,
and follows every re-enumeration itself. A watchdog under it kills a `usbmuxd` that has
not listed a plugged-in iPhone for 30 seconds, and the supervisor starts a fresh one. It
does this at most three times in a row, so a phone sitting at *Trust This Computer?* is
not interrupted forever. The count starts again when the phone shows up as a new USB
device (plugged in again, or re-enumerated) and after ten quiet minutes.

```sh
sudo install -m755 tools/phone-refresh/usbmuxd/usbmuxd.initd /etc/init.d/usbmuxd
sudo install -m755 tools/phone-refresh/usbmuxd/usbmuxd-watchdog.initd /etc/init.d/usbmuxd-watchdog
sudo install -m755 tools/phone-refresh/usbmuxd/usbmuxd-watchdog /usr/local/sbin/usbmuxd-watchdog
sudo install -m644 tools/phone-refresh/usbmuxd/39-usbmuxd.rules /etc/udev/rules.d/39-usbmuxd.rules
sudo udevadm control --reload-rules
sudo rc-update add usbmuxd default && sudo rc-update add usbmuxd-watchdog default
sudo rc-service usbmuxd start && sudo rc-service usbmuxd-watchdog start
```

The udev override in `/etc/udev/rules.d` keeps the package's rule but drops its two
`RUN` lines, so udev no longer starts or stops `usbmuxd`. It also drops the rule's reset of
the phone's USB configuration to 0 on every add. That reset is for a `usbmuxd` started by
udev after it. A `usbmuxd` that is already running has configured the phone by the time
the rule runs, so the reset unconfigured it again about 10 ms later. `usbmuxd` logged
`Removed device` and never saw the phone come back. For the same reason the watchdog
only kills `usbmuxd` and never replays udev events: replaying them reset the
configuration again. `usbmuxd`'s log is
`/var/log/usbmuxd.log`; the watchdog logs to syslog as `usbmuxd-watchdog`.

## Install

```sh
install -m755 tools/phone-refresh/music-phone-refresh ~/.local/bin/
cat > ~/.config/autostart/music-phone-refresh.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Music phone refresh
Comment=Installs and re-signs the Music app on the iPhone whenever it is plugged in
Exec=/home/miles/.local/bin/music-phone-refresh
Terminal=false
X-KDE-autostart-phase=2
NoDisplay=true
DESKTOP
```

It starts at login; one instance at a time. Log and state:
`~/.local/state/music-phone-refresh/{log.txt,state.json}`.

## Test

```sh
tools/phone-refresh/test-music-phone-refresh      # -v prints each scenario's log and notifications
```

No phone needed. It replays plug-ins against fake `lsusb`, `idevice_id`, `xtool`, `gh`,
`pgrep`, `udevadm` and `notify-send` on a virtual clock, in a scratch home, and checks
for one install per plug-in: a re-enumeration, `usbmuxd` losing the phone for two
minutes, `usbmuxd` not listing it for five, a failed download, a locked phone, *Don't
Trust*, a replug, JellyMC's install running, a new build, an install cut off part way,
and a second watcher started beside the first. `--watcher FILE` runs the same scenarios
against another copy, such as an older one from git.
