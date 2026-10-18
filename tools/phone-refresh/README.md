# music-phone-refresh

Installs the latest build of the app on the iPhone **every time it is plugged in** to
this laptop — a fresh seven-day signature and the newest build, whatever the phone
already had. While the phone stays plugged in, any build published since is installed
too, and a failed install is retried every ten minutes. Each install shows a desktop
notification.

It reads the rolling `latest` release that every push to `main` publishes, and installs
with `xtool install --usb`, never with a timeout (an interrupted install collides with
the next one). If it stalls at *Verifying*, the app is playing music — iOS will not
replace an app holding an audio session.

If the phone is on USB but `usbmuxd` cannot list it (it wedges), the notification gives
the three root commands that fix it.

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
