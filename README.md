# Music

A native SwiftUI music client for [Navidrome](https://www.navidrome.org/),
built for one iPhone and nothing else.

Written from scratch. There is no WebKit here: no web view, no CSS, no
JavaScript. Scrolling, gestures, swipe-back and the tab bar are the system's,
and playback is `AVQueuePlayer`, so gapless, background audio and the lock
screen work the way they do in any other iOS app.

Play counts, ratings and playlists live on the Navidrome server and are read and
written over the Subsonic API, so a desktop client stays in sync with this one
automatically -- neither app owns that state.

## Building

There is no Mac in this loop. GitHub Actions compiles on a macOS runner and
publishes an unsigned `.ipa`; it is signed and installed on-device with
[xtool](https://github.com/xtool-org/xtool):

```sh
gh release download latest -p Music.ipa -D dist --clobber
xtool install dist/Music.ipa
```

Every push to `main` replaces the `latest` prerelease, so that command never
needs a run id. The build is also uploaded as a workflow artifact, but the
artifact API has returned 503 for hours at a time, which is why the release is
the documented path.

A free Apple developer certificate expires after 7 days, so re-running
`xtool install` is the weekly refresh.

## Linux

The same app runs on the Linux desktop: every screen of the phone, built with
GTK 4 and libadwaita over the phone's own `App/Core`. Playback is FFmpeg into
PulseAudio or PipeWire, with Rubber Band for tempo, so gapless, crossfades,
beat-matched transitions and the equalizer behave as they do on the phone.
Plexamp's visualisers are its shaders in OpenGL. The desktop's media keys and
panel controls work through MPRIS. The sign-in is kept in the app's own folder,
in a file only you can read, not in KWallet or GNOME Keyring.

It needs Swift 6, GTK 4 with libadwaita 1.6 or newer, and the development
files for libepoxy, FFmpeg, PulseAudio and Rubber Band. Then:

```sh
Linux/install.sh
```

That builds in release and installs `~/.local/bin/music`, a launcher entry
and the icon; `PREFIX` installs elsewhere, and `--uninstall` takes it out
again. `music-update` (or `Linux/install.sh --update`) pulls the latest,
rebuilds, and restarts the app if it is open; it quits it gracefully first, so
the queue, settings and downloads carry over, and it backs the settings up to
`~/.config/music.plist.bak` before it starts. If a package is missing, the script names it and prints the install
command for Fedora, Debian and Ubuntu, and Arch. With Fedora's `swift-lang`
the Swift runtime stays shared, so the machine running it needs
`swift-lang-runtime`; a Swift.org toolchain links the runtime in.

Settings live in `~/.config/music.plist`, and the library cache, downloads
and queue in `~/.local/share/com.milescoviello.Music`.

For development, `swift build` and `swift run music` work as usual. Linux
only adds the `#if os(Linux)` targets in `Package.swift`; the iOS logic tests
still build and run the same way on macOS.

## Playing on the computer from the phone

The phone can play to the Linux app the way one Plexamp plays to another. In
the phone's player, the computer button beside AirPlay opens **Play On**, which
lists this iPhone and every computer on the Wi-Fi with Music open. Choose one
and the whole app drives it: albums and playlists started on the phone play
there, and the player, the queue, lyrics and the mini player show what it is
playing. The volume row moves the computer's volume, and says where the music
is. Choosing it while music plays on the phone asks whether to move that music
over, at the same second. Choosing This iPhone again asks whether to bring the
music back. The phone always starts out playing to itself after a launch.

The first time, the computer shows a six-digit code, in its window and as a
notification, to type in on the phone. After that the phone keeps the token in
its Keychain. On the computer, **Settings → Remote Control** turns this on or
off (it starts on), renames the computer as phones see it, shows its address,
and lists the paired phones with Forget.

Both apps must be signed in to the same Navidrome server, since the phone sends
songs by their ids. The computer advertises itself over mDNS through Avahi as
`_music-remote._tcp` and listens on TCP port 47823 (any free port if that one is
taken). It answers only loopback, private, link-local and Tailscale addresses.
Where mDNS doesn't cross the network, or Avahi isn't running, use **Add by
Address** on the phone with the address the computer's settings show. On a
network that keeps devices apart (a campus or hotel Wi-Fi), use the computer's
Tailscale address (100.x) with Tailscale on in both. A firewall that blocks
incoming connections needs 47823/tcp opened, plus mDNS (5353/udp) for the
computer to be found. Traffic is plain HTTP on the LAN, like the server's own.

The protocol is written down at the top of `App/Core/RemoteControl.swift`. It
is plain enough to drive from a terminal, which pairs the way the phone does:

```sh
curl -X POST -d '{"device": "Terminal"}' http://desktop:47823/v1/pair/request
curl -X POST -d '{"device": "Terminal", "code": "123456"}' http://desktop:47823/v1/pair/confirm
TOKEN=...   # from the reply
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -d '{"action": "seek", "seconds": 42}' http://desktop:47823/v1/command
curl -N -H "Authorization: Bearer $TOKEN" http://desktop:47823/v1/events
```

## Layout

```
App/Core        Subsonic client, models, session, Keychain
App/Features    One directory per screen
Linux/Sources   The Linux app: GTK bindings, audio engine, desktop services, screens,
                and the remote-player server (Linux/Sources/MusicLogic/Remote)
Linux/Modules   C module maps for GTK, epoxy, FFmpeg, PulseAudio, Rubber Band
```

`Linux/Sources/MusicLogic/Core` is a link to `App/Core`: the Linux build
compiles the phone's core as it is, apart from the few Apple-only files that
`Linux/Sources/MusicLogic/Platform` replaces with same-named Linux versions.

`Music.xcodeproj` uses a file-system synchronized group, so new Swift files
under `App/` are picked up without editing the project file.
