# Plexamp parity — spec and roadmap

The `revamp` branch brings this client to feature parity with Plexamp 4.13.2. The
behaviour below was read from Plexamp itself (the Electron build's JS bundle and its
native `treble` audio engine), not guessed. Nothing of Plexamp's code is copied here —
only what it does, with its constants.

## Done (on this branch, CI green)

| Commit | What |
|---|---|
| OpenSubsonic fields | `replayGain`, release types, labels, moods, play dates, artist/album info endpoints |
| Audio chain as arithmetic | `DSP.swift`: Loudness Leveling, 10-band EQ, limiter, BS.1770 meter, Sweet Fades overlap rule — all tested |
| Chain on every track | Processing tap runs the chain on streamed *and* downloaded tracks; two `AVQueuePlayer`s give Sweet Fades crossfades; `EngineOutput` removed; Playback + Equalizer screens |
| Stream cache bookkeeping | `StreamCacheIndex.swift`: variant rules + LRU eviction, tested (not wired yet) |

Run the logic tests on Linux with `LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift test`,
or plain `swift test` on macOS.

## Plexamp facts (verified)

- **Settings defaults:** leveling on, preamp +4 dB (options +6…0), limiter on, Sweet Fades
  on, EQ off; EQ bands 31.25/62.5/125/250/500/1k/2k/4k/8k/16k Hz; quick skip back 10 s /
  forward 30 s (10/15/30/45); streaming Wi-Fi = original, cellular = 128 kbps; cache ahead
  Wi-Fi 15 tracks, cellular 5 (only next/5/10/15/20/25/40); cache 512 MB; prefer downloaded
  media = on cellular; chart list 25 (10/25/50/100); rating: one star / five stars / half stars.
- **Loudness Leveling:** album gain + preamp; nothing applied when a track has no gain.
- **Sweet Fades:** fade every transition except album tracks in order. Overlap = outgoing
  end ramp + incoming start ramp, threshold = loudness + 2 dB, each and total capped 15 s.
- **Autoplay** (when repeat off and < 30 up next): choices carousel at the end of Up Next —
  album ended: Silence, Next/Previous Album, Similar Album, Artist Mix, Artist Radio, Track
  Radio, Similar Artists, Decade, Library Radio; otherwise: Silence, Similar Artists, Track
  Radio, Decade, Library Radio. Selection remembered separately for the two cases. Adds 30
  tracks (20 for radio) when the queue ends. Never for station queues.
- **Guest DJs.** Shared filters: not already in the queue (by id or cleaned title), rating
  unset or ≥ 2.5 stars, 90 s–10 min, not already generated.
  - Once per track, inserted after it: **Stretch** (short sonic path current→next, 3
    tracks), **Gemini** (most similar track by another artist), **Twofer** (another track by
    the same artist).
  - Pool, two at a time, keeping the next two generated: **Freeze** (track radio, 75),
    **Contempo** (album years ±2, no compilations, 50), **Groupie** (same artist, 50).
  - Friendgänger needs shared servers — not applicable.
- **Sleep timer:** off, 5/10/15/30 min, 1 hour, end of track, end of album (only offered
  when everything up next is one album).
- **Queue inserts:** Play Next (after current), Add to Up Next (after the last added item;
  only once something was added), Add to Queue (end). Queue has an Earlier/history tab;
  menu has Save Play Queue as Playlist, Clear Play Queue, Show Similar Tracks.
- **Home hubs:** Now Playing, Mixes for You, Recent Plays (things you started), Recently
  Played, Recently Added, Most Played in (month), On This Day (anniversary releases), More
  in (genre), More from (label), Top Albums from (period), Haven't Played In, Stations
  (+ Artist/Album Mix Builder), History. Editable: reorder, hide, display as
  Block/Carousel/Grid/List, item limit, title, reset order.
- **Library:** Artists, Albums, Tracks, Playlists, Compilations, Soundtracks, Folders,
  Genres, Moods, Styles, Record Labels.
- **Artist page:** Popular tracks, albums by release type, Appears On, sonically similar,
  similar artists, bio. **Album page:** discs, review, similar albums, popular badges,
  codec badges.
- **Charts (Aural Fixations):** Top Tracks/Albums/Artists for week/month/season/year/
  decade/all-time, prev/next; shows the previous period when the current one is under
  15/20/8/8/10 % elapsed; seasons follow the hemisphere setting. Best Of = released that
  year, by play count.

## Next, in order

1. **A4 — stream cache:** downloader using `StreamCacheIndex` (cache ahead per network,
   size cap), measure intro/outro ramps (`LoudnessMeter`) of local files and feed them to
   `PlaybackController.transitionOverlap` instead of the 3 s fallback; streaming quality per
   network (`stream.view?format=mp3&maxBitRate=`); Prefer Downloaded Media; settings screen.
2. **B — queue & player:** the three insert points + history tab + clear/save queue;
   Autoplay; Guest DJs; quick skip, playback speed (output already has `rate`), sleep
   options, seekbar/background styles, Similar Tracks sheet, rating system setting.
3. **C — radio:** stations (Library, Deep Cuts, Time Travel, Random Album, decade, genre),
   endless refill, Artist/Album Mix Builders, Sonic Adventure approximation, degrees of
   separation.
4. **D — home & library:** customisable hubs, Tracks/Compilations/Folders/Labels/Moods,
   artist page by release type + Appears On + bio, album page, charts, search.
5. **E — settings reorganised** into Plexamp's groups.

Navidrome has no sonic analysis, so "sonically similar" maps to `getSimilarSongs2` and the
DJs that need sonic data are approximations; say so where they appear.
