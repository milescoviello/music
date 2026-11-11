# sonic — Plex's sonic analysis, for Navidrome

The service behind the app's sonic features: Sonically Similar tracks, albums and
artists, Sonic Adventure, the sonic Guest DJs, track radio, mood stations, the seekbar's
loudness shape, and the beats and keys for beat-matched crossfades.

It reimplements what Plex Media Server does — see `docs/SONIC.md` for how that was
found and verified — using only open parts: Essentia and the public MSD MusiCNN model,
which is the network Plex's `Music.tflite` was converted from. Our vectors match the
ones Plex stored for the same files at cosine 0.999–0.9999. Nothing of Plex is used at
runtime.

## What it does

- Reads Navidrome's database (a read-only copy) for every track's id, album, artist and
  file — no credentials, and it works while Navidrome is stopped.
- Analyses each file once, at low priority, in a pool of worker processes: the 50-tag
  MusiCNN vector, BS.1770 momentary loudness every 100 ms, beats, tempo and key.
- Keeps it all in `data/sonic.db` (SQLite), re-reads the library every six hours, and
  analyses whatever is new or changed. A first pass over ~26,000 tracks takes several
  hours; results are served as they land.
- Answers on port 8650. Nearly every endpoint is a GET returning JSON; a track not
  analysed yet is a 404. The writes are the app's Send Logs, shared taste, and which
  video a song gets (below).

| Endpoint | Answers |
|---|---|
| `/v1/status` | tracks, analysed, failed, indexed, analysing |
| `/v1/tracks/{id}/levels?points=128` | `{id, hop, levels}` — loudness in LUFS, bucket means; `points=0` for every reading |
| `/v1/tracks/{id}/rhythm` | `{id, bpm, confidence, beats[], key, scale, keyStrength, duration, loudness}` |
| `/v1/tracks/{id}/similar?limit=&exclude_artist=&max_distance=` | nearest tracks |
| `/v1/tracks/{id}/distant?limit=` | related but not close, unplayed first |
| `/v1/tracks/{id}/tags` | the strongest of the 50 tags |
| `/v1/albums/{id}/similar`, `/v1/artists/{id}/similar` | by the mean of their tracks |
| `/v1/path?from=&to=&steps=` | a sonic adventure between two tracks |
| `/v1/radio?seed=a,b&exclude=x,y&limit=` | around the seeds, two per artist at most |
| `/v1/tags`, `/v1/tags/{tag}/tracks` | mood and genre stations |

Lists are `{"items": [{"id", "distance"}]}`, distances cosine (0 identical). Set
`SONIC_TOKEN` to require an `X-Sonic-Token` header.

### Music videos

For the apps' Song | Video switch and Search's YouTube side (`sonic/video.py`). A song's
video is found by a YouTube search through yt-dlp, scored for the official upload, and
remembered per song by artist and bare title in `data/videos.db`, so both libraries'
copies of a song share it; a pick made by hand replaces it for good.

| Endpoint | Answers |
|---|---|
| `GET /v1/video/search?q=&limit=` | `{"items": [{id, title, channel, duration, verified, views, artist, song}]}` -- `artist`/`song` are the service's reading of the title, for Add to Library |
| `GET /v1/video/match?artist=&title=&duration=&warm=1` | `{video, manual, offset}`; `video` null when there is none. `warm` opens its streams ahead |
| `PUT /v1/video/match` `{artist, title, video}` | the video this song gets from now on |
| `DELETE /v1/video/match?artist=&title=` | back to the automatic pick |
| `GET /v1/video/{id}/master.m3u8` | HLS for AVPlayer: every H.264 height up to 1080p, AAC audio |
| `GET /v1/video/{id}/{itag}.m3u8`, `/v1/video/{id}/{itag}.mp4` | the media playlists, and the relayed bytes (Range) |
| `GET /v1/video/{id}/streams` | the desktop's: the tallest video and the best (Opus) audio, as relayed paths |
| `GET /v1/video/{id}/thumb` | the thumbnail, cached |

There are no ads because none of YouTube's player is involved. YouTube's streams are
fragmented MP4 with their own index (`sidx`), which is all HLS needs: the playlists are
byte ranges of the one file, and the bytes come through the service, since YouTube's
addresses only work from the address that asked for them -- and refuse every request
for the first few seconds (`available_at`), which the relay waits out. Nothing is stored.
yt-dlp is unpinned and kept current at run time (`data/pylib`, see `video.Updater`),
since an old one stops working when YouTube changes; Deno runs its JavaScript challenge.
With `SONIC_TOKEN` set, the media addresses carry it as `?token=`, since a player cannot
add the header.

### Lyrics fixed in the apps

`POST /v1/lyrics/save` `{id, original, synced, lines: [{start, value}], auth: {u, t, s}}`
writes lyrics timed by hand in the apps back where Navidrome found them
(`sonic/lyricsfile.py`), as LRC, in Navidrome's default order: an `.lrc` beside the song
with its name, which most of the library's lyrics are (Navidrome reads those on every
request, so a fix shows at once); else a `.txt`; else the song's own tags -- every lyrics
tag whose words are `original` and whose timing matches `synced` (Vorbis comments, ID3
`USLT`, MP4 `©lyr`). A file beside the song keeps its headers (`[ti:]`, `[ar:]`...) but
not its `[offset:]`, which the app has put into the times.

`auth` is the app's Subsonic sign-in, and the service asks Navidrome
(`SONIC_NAVIDROME_URL`, default `http://127.0.0.1:4533`) whether it is an admin's. A song's
own file is copied beside itself as a hidden `.<name>.sonic-lyrics`, retagged, checked to
carry the same audio as the original (the frame bytes for FLAC and MP3, Essentia's packet
MD5 for anything else), and renamed over it; Navidrome's watcher scans the folder again.
It answers `{ok, changed}`, or an error the app shows: 401/403 for the sign-in or a folder
the NAS won't let it write, 404 for a song or file it can't find, 409 when the file's words
aren't `original`, 422 for a file it can't tag. These are the only writes the service makes
to the music, and why its mounts of it are not read-only.

`POST /v1/logs` takes the plain-text report from the app's Diagnostics → Send Logs and
keeps it as `data/logs/<UTC time>-<source>-<random>.txt`, where `source` is the app's
`X-Log-Source` ("ios", "linux-<host>"). It answers 201 with `{"name"}`. A report is at
most 1 MB (413 beyond), and only the newest 100 are kept, so the folder stays under
about 100 MB whoever sends to it. The newest report is the last name in sort order:

```sh
ls ~/sonic/data/logs | tail -1
```

## Running it

On the 148 host, from a copy of this directory at `~/sonic`:

```sh
docker compose up -d --build     # the model downloads into ./data on first start
docker logs -f sonic             # progress every couple of minutes
curl -s localhost:8650/v1/status
```

Settings are environment variables (`compose.yaml`): `SONIC_NAVIDROME_DB`,
`SONIC_PATH_MAP` (Navidrome's library roots to where the files are mounted),
`SONIC_WORKERS`, `SONIC_RESYNC_HOURS`, `SONIC_PORT`, `SONIC_TOKEN`.

Checking it against Plex, once it has analysed some of the library:

```sh
docker compose exec sonic python -m sonic compare-plex \
  --plex-db /plex/com.plexapp.plugins.library.db --analysis "/plex/Music Analysis 5" "/plex/Music Analysis 7"
```

(with Plex's `Databases` directory mounted read-only at `/plex`).

## Tests

```sh
python3 -m unittest discover -s tests -t .     # needs only NumPy
```
