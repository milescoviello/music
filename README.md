# Music

A music player for a self-hosted [Navidrome](https://www.navidrome.org/) server: an
iPhone app and a Linux desktop app that share one core, and an optional service that
runs next to the server. It aims at what Plexamp does for a Plex library, for a
Navidrome one.

Play counts, ratings, favourites, playlists and the play queue all live on the
Navidrome server and go through the Subsonic API, so any other client on the same
server -- desktop Feishin, say -- stays in step. Neither app keeps that state to itself.

## What it does

- **Browse and play the library**: artists, albums, playlists, genres, decades,
  favourites and folders, with a Home of recently played, recently added and
  forgotten favourites.
- **Search that copes with typos**, missing spaces and one-letter titles, plus search
  by a line of lyrics.
- **Up Next**: Play Next, Add to Up Next and Add to Queue, swipe to remove and drag to
  reorder. **Autoplay** carries on when the queue runs out, and there are stations and
  daily mixes built from what you play.
- **Playback**: gapless albums, crossfades (beat-matched when the tracks' beats are
  known), an equalizer, playback speed, a sleep timer, synced lyrics with translation
  and romanization, and the Plexamp visualizers.
- **Offline**: download albums and playlists. A downloaded playlist follows the server
  when it changes, and a song two downloads share stays until neither needs it.
- **Guest DJs** that slip picks into the queue as it plays, and **listening stats**:
  history, charts, and top artists, albums and songs by week, month and year.
- **Siri and Shortcuts** on the phone: play a playlist, play favourites, shuffle the
  library.
- **Play on the computer from the phone** (see below), the way one Plexamp plays to
  another.
- **Music videos**, YouTube Music's way: a Song | Video switch in the player plays the
  song's official video in place of its track -- with the video's own sound, which is
  lossy, while the Song side stays the library's file -- and stays on from song to song.
  Change Video picks another when the automatic one is wrong, and the pick is kept for
  every device. Search has a YouTube side: play a video, or add the song (and its album)
  to the library through Hermes. No ads: the video plays in the app's own player, through
  `server/sonic`.
- **Sonic features**, with `server/sonic` running: sonically similar tracks, albums and
  artists, Sonic Adventure, sonic radio, the loudness-shaped seekbar, and instant lyric
  search. Without it, the app falls back to what Navidrome offers.

The iPhone app is native SwiftUI with no web view, so scrolling, gestures and the tab bar
are the system's, and playback is `AVQueuePlayer`, so background audio and the lock screen
work as they do in any iOS app. The Linux app is GTK 4 and libadwaita over the same core.

## Parts

| | |
|---|---|
| `App/` | The iPhone app. `App/Core` is shared with Linux. |
| `Linux/` | The Linux app: GTK screens, the audio engine and the desktop services |
| `server/sonic/` | The optional companion service: sonic analysis and lyric search ([README](server/sonic/README.md)) |
| `Tests/` | Logic tests, which run with `swift test` on Linux and macOS |
| `tools/` | The iPhone install-on-plug-in helper, and a one-off Plex to Navidrome import |
| `docs/` | How Plexamp's features work, and how they are matched here |

## Building the iPhone app

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
App/Core        Subsonic client, models, playback, queue, downloads, search, stores
App/Features    One directory per screen
Linux/Sources   The Linux app: GTK bindings, audio engine, desktop services, screens,
                and the remote-player server (Linux/Sources/MusicLogic/Remote)
Linux/Modules   C module maps for GTK, epoxy, FFmpeg, PulseAudio, Rubber Band
server/sonic    The companion service (Python, Essentia), run with Docker Compose
Tests           Logic tests for the Foundation-only parts of App/Core
tools           phone-refresh (installs on plug-in), plex-to-navidrome (import)
```

`Linux/Sources/MusicLogic/Core` is a link to `App/Core`: the Linux build
compiles the phone's core as it is, apart from the few Apple-only files that
`Linux/Sources/MusicLogic/Platform` replaces with same-named Linux versions.

`Music.xcodeproj` uses a file-system synchronized group, so new Swift files
under `App/` are picked up without editing the project file.
