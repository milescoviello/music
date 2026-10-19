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

## Layout

```
App/Core        Subsonic client, models, session, Keychain
App/Features    One directory per screen
Linux/Sources   The Linux app: GTK bindings, audio engine, desktop services, screens
Linux/Modules   C module maps for GTK, epoxy, FFmpeg, PulseAudio, Rubber Band
```

`Linux/Sources/MusicLogic/Core` is a link to `App/Core`: the Linux build
compiles the phone's core as it is, apart from the few Apple-only files that
`Linux/Sources/MusicLogic/Platform` replaces with same-named Linux versions.

`Music.xcodeproj` uses a file-system synchronized group, so new Swift files
under `App/` are picked up without editing the project file.
