# Plexamp parity — spec and status

The `revamp` branch brings this client to feature parity with Plexamp 4.13.2. The
behaviour below was read from Plexamp itself (the Electron build's JS bundle and its
native `treble` audio engine), not guessed. Nothing of Plexamp's code is copied here —
only what it does, with its constants. The decompiled bundle is on the `148` host at
`~/plexamp-decomp` (see its README for the module map).

Run the logic tests on Linux with `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift test`,
or plain `swift test` on macOS. Every rule below that is arithmetic rather than UI lives
in a Foundation-only file listed in `Package.swift` and has tests.

**Nothing here has been run on a phone yet.** CI compiles every commit and runs the logic
tests; the things most worth checking by hand are listed at the end.

## What is done

### Sound (A)

| Plexamp | Here | Where |
|---|---|---|
| Loudness Leveling, preamp +6…0 (default +4), limiter | Same rule: album gain → track gain, preamp, peak cap without limiter | `DSP.swift`, `AudioTap.swift` |
| 10-band EQ, presets, custom curves | Same bands (31.25 Hz…16 kHz, 1 octave), presets, saved curves, legacy 5-band migration | `DSP.swift`, `AudioSettings.swift`, `EqualizerView` |
| Sweet Fades | Fade every transition except album order; overlap = outro tail + intro build at loudness + 2 dB, capped 15 s, measured from the files | `TrackShape.swift`, `TrackShapeStore.swift`, `QueuePlayerOutput.swift` |
| Streaming quality Wi-Fi / cellular | Maximum, 320…128 (+96, 64 on cellular); converts only what is above the ceiling | `StreamingPolicy.swift` |
| Cache ahead (only next…40 tracks), cache size, Delete Caches | Same choices; Wi-Fi 15 / cellular 5; 1 GB default; LRU, never evicts what is about to play | `StreamCache.swift`, `StreamCacheIndex.swift` |
| Prefer Downloaded Media | Always / On Cellular / Never (offline always plays a download) | `StreamingPolicy.swift` |

Defaults differ from Plexamp in three places, each to keep what the app already did:
cellular streams the original (Plexamp: 128 kbps), downloads are always preferred
(Plexamp: on cellular), and the cache is 1 GB (Plexamp: 512 MB — fifteen lossless tracks
ahead is already half that).

### Queue and player (B)

| Plexamp | Here |
|---|---|
| Play Next / Add to Up Next / Add to Queue | Same three insert points, in every song, album, playlist and selection menu; Up Next only once something was added (`PlaybackQueue.swift`) |
| Earlier tab, Clear Play Queue, Save as Playlist | Queue screen tabs and menu; Clear keeps the current track |
| Autoplay carousel | Plexamp's choices per context, defaults, 30/20 track sizes, remembered per context, added 30 s before the end, Album Direction setting (`Autoplay.swift`, `QueueExtenders.swift`) |
| Guest DJs | Stretch, Gemini, Twofer, Freeze, Contempo, Groupie with Plexamp's filters and insertion rules (`GuestDJ.swift`, `QueueExtenders.swift`). Friendgänger needs shared servers — not applicable |
| Quick skip | 10/15/30/45 s, default 10 back / 30 forward, off by default |
| Playback speed | 0.5–2× in tenths, from the player menu |
| Sleep timer | 5/10/15/30 min, 1 hour, end of track, end of album (only when Up Next is one album) |
| Show Similar Tracks | Navidrome's similar songs, titled Related Tracks |
| Show Full Player, Keep Screen On | Experience settings |
| Seekbar style (Smooth / Bars / Line) | Smooth and Bars draw the track's loudness outline, measured from the file once it is local (`TrackShape.envelope`) |
| Player background (Flat / Smooth / Ultrablur) | Artwork average colour flat or as a gradient, or the blurred artwork |
| Playback speed on the lock screen | Rate reported, so the lock-screen scrubber keeps up |

### Radio (C)

| Plexamp | Here |
|---|---|
| Library Radio, Deep Cuts, Time Travel, Random Album, decade and genre stations | Assembled from random songs, album lists and play counts; endless — topped up five tracks before the end (`Stations.swift`, `StationService.swift`) |
| Track / album / playlist / artist radio | All endless stations now, drifting with what has played |
| Artist / Album Mix Builder | Search, pick up to 8, play a station of them; similar-artist suggestions |
| Sonic Adventure | Path built from both ends' similar songs (no sonic map in Navidrome — the screen says so) |

### Home and library (D)

| Plexamp | Here |
|---|---|
| Customisable home | Show/hide/reorder shelves, reset (`HomeLayout.swift`, `HomeEditorView`) |
| Hubs | Made for You, Recent Plays (things started — albums, playlists, artists, stations; `RecentPlays.swift`), Stations, Recently Played, On This Day, Recently Added, Favourites, Most Played, Most Played in (month), More in a Genre, Best of Last Year, Haven't Played Lately, Forgotten Favourites |
| Library categories | Tracks (empty `search3`, paged), Compilations, Soundtracks, Live, Singles & EPs, Record Labels, Moods (from the whole album list: `LibraryIndex.swift`, `LibraryFacets.swift`), Folders (`getIndexes` / `getMusicDirectory`) |
| Artist page | Popular, releases by type, Appears On, Similar Artists, biography when present |
| Album page | Codec badge, label, release date, genres, review when present, More by artist |
| Charts (Aural Fixations) | Week/month/season/year/decade/all time, Plexamp's young-period rule, hemisphere seasons, top 10/25/50/100, from local play history (`Charts.swift`, `ChartsView`) |
| Search Top Result | Exact > prefix, artist > album > song; playlists matched locally (`SearchRanking.swift`) |

### Settings (E)

Plexamp's groups: **Playback** (Loudness Leveling, Sweet Fades, EQ, Autoplay),
**Experience** (player, quick skip, home screen), **Streaming & Caching** (quality,
caching, prefer downloads), then Downloads, Offline & Library, Requests, Diagnostics.

## Not done, and why

- **Sonic analysis** — Plexamp's "sonically similar", Sonic Adventure's map, and the sonic
  DJs use Plex's per-track audio analysis. Navidrome has none; everything sonic here is
  built from `getSimilarSongs2` (artist similarity via the server's agents) and says so.
- **Degrees of Separation, Include External Media** — need Plex's artist graph and
  TIDAL/shared servers.
- **Half-star ratings** — Navidrome stores whole stars.
- **Styles** — Navidrome has genres and moods but no separate styles.
- **CarPlay** — needs Apple's CarPlay audio entitlement, which a free developer
  certificate cannot carry.
- **Font size, grid size, side-by-side layout** — Dynamic Type covers the first; the app is
  portrait-only with a fixed two-column grid.
- **Remote control / casting, Sonic Sage (AI), lyrics editing** — out of scope.

## Plexamp facts (verified, for reference)

- **Settings defaults:** leveling on, preamp +4 dB, limiter on, Sweet Fades on, EQ off;
  quick skip 10/30 s (10/15/30/45); streaming Wi-Fi Maximum, cellular 128 kbps; cache
  ahead Wi-Fi 15, cellular 5 (only next/5/10/15/20/25/40); cache 512 MB (512 MB…128 GB);
  prefer downloaded media on cellular (always/on cellular/never); chart list 25
  (10/25/50/100); hemisphere north; autoplay on, album mode Next Album, other mode
  Similar Artists.
- **Sweet Fades:** fade every transition except album tracks in order. Overlap = outgoing
  end ramp + incoming start ramp, threshold = loudness + 2 dB (`-16 - gain`), each and
  total capped 15 s.
- **Autoplay:** active when repeat is off, fewer than 30 up next, not a station. "Ends
  with album" = last two queue tracks share an album. Album choices: Silence, Next/Previous
  Album, Similar Album, Artist Mix, Artist Radio, Track Radio, Similar Artists, Decade,
  Library Radio; otherwise Silence, Similar Artists, Track Radio, Decade, Library Radio.
  Adds 30 tracks, 20 for radio. Computed 3 s after the queue's end changes.
- **Guest DJs:** filters — not queued (id or title with its last bracket removed), rating
  unset or ≥ 5/10, 90 s–10 min, not generated before. Per-track DJs act once on each
  non-generated track, inserting after it (Stretch 3, Gemini 1, Twofer 1). Pool DJs
  (Freeze 75 radio, Contempo 50 from album year ±2 without compilations, Groupie 50 by
  artist) insert two at a time whenever the next two are not both theirs, and clear
  themselves when the pool is empty.
- **Sleep timer:** off, 5, 10, 15, 30 min, 1 hour, end of track, end of album (visible
  only when every Up Next item has one parent).
- **Queue inserts:** Play Next (`next=1`), Add to Up Next (after last added; visible only
  with a last-added item), Add to Queue (`end=1`, visible under 2000 items). Clear Play
  Queue deletes all items but the current one.
- **Charts:** current period unless under 15 % (week), 20 % (month), 8 % (season, year)
  or 10 % (decade) elapsed, then the previous one. ISO weeks; seasons start Dec/Mar/Jun/Sep,
  named by hemisphere.

## Worth checking on the phone first

1. **Crossfades** — fade start timing, equal-power curve, that album order stays gapless,
   and that a cached track's measured overlap sounds right (try a long fade-out).
2. **Tap attach delay** — first track starts within a moment, not after the 1.5 s fallback.
3. **Stream cache** — Settings → Streaming & Caching shows "In Use" growing while playing;
   a skipped-to track starts instantly from cache; airplane mode mid-queue keeps playing.
4. **Autoplay** — carousel appears at the end of Up Next after ~3 s; the selected option
   is appended ~30 s before the last track ends.
5. **Guest DJ** — pick DJ Gemini from the player menu, watch picks (✦) appear after tracks.
6. **Stations** — Home → Stations, play Time Travel; it should top itself up forever.
7. **AirPlay** — the processing tap and two players with AirPlay 2.
8. **Seekbar** — once a track is cached (Wi-Fi), the Smooth seekbar should show its
   loudness outline within a second or two; scrubbing along it should seek on release.
9. **Tracks and Folders** — both depend on how this Navidrome version answers an empty
   `search3` and `getIndexes`; each screen says so if it gets nothing.
