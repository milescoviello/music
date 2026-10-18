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
- Answers on port 8650. Every endpoint is a GET returning JSON; a track not analysed yet
  is a 404.

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
