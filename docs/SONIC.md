# Sonic analysis — how Plex does it, and ours

Plexamp's "sonic" features — Sonically Similar tracks, albums and artists, Sonic
Adventure, the sonic Guest DJs, track radio — all stand on one thing the Plex server
computes per track. This is what it is, found by taking Plex Media Server 1.4x apart on
the 148 host (working files in `148:~/plexamp-decomp/plex-sonic`, not in this repo), and
how `server/sonic` rebuilds it.

## The sonic vector

- **Model:** `Plex Media Server/Resources/Music.tflite` (3.1 MB). Input `model/Placeholder`
  `[1, 187, 96]` float32, output `model/Sigmoid` `[1, 50]`. Those are the tensor names
  and shapes of the open MusiCNN tagger: 187 frames × 96 mel bands is three seconds of
  16 kHz audio, and the 50 outputs are tag probabilities. It is a TFLite conversion of
  Essentia's public **msd-musicnn-1** (Million Song Dataset tags): a third of its 1-D
  weight tensors appear byte for byte in that model's graph and none in the MagnaTagATune
  one, and the public model through the same recipe reproduces Plex's stored vectors.
- **Input features:** Essentia's `TensorflowInputMusiCNN` — 512-sample frames, 256 hop,
  Hann, power spectrum, 96 Slaney mel bands to 8 kHz with unit-triangle normalisation,
  `log10(1 + 10000·x)`. Plex links Essentia: its binary carries the algorithm and
  parameter names (`MelBands`, `slaneyMel`, `lowMelFrequencyBound`…).
- **Audio:** decoded mono and resampled to 16 kHz with Essentia's best-quality resampler.
- **Per track:** the model on back-to-back (non-overlapping) 187-frame windows from the
  start, the last partial window dropped, and the 50 outputs averaged.
- **Verified:** that recipe reproduces the vectors Plex stored at cosine similarity
  0.99987 and 0.99900 on the two tracks checked. (With Essentia's default "medium"
  resampler it is 0.994–0.999; the resampler was the difference.)

## Where Plex keeps them

`Plug-in Support/Databases/Music Analysis <section>/`:

- `Track.tree`, `Album.tree`, `Artist.tree` — Spotify Annoy indexes, **angular** metric,
  **f = 50**: 212-byte nodes of `int32 n_descendants`, a 4-byte union (`children[0]`, or
  for items the vector's squared norm), `int32 children[1]`, then 50 float32. The first
  *n* nodes are the items; split nodes follow, roots last.
- `Mapping.db` — SQLite `mappings(id, external_id, metadata_type)`: Plex metadata id ↔
  tree item index, for tracks (10), albums (9) and artists (8).
- Each analysed track's `extra_data` carries `ms:musicAnalysisVersion=1`.

Neighbours are cosine distance in that space; Plexamp's DJ Gemini, for example, asks for
the ten nearest with `maxDistance=0.175`.

## The seekbar's shape

Plexamp asks the server for `/library/streams/<audio stream>/levels?subsample=128`.
Unsubsampled, that is **BS.1770 momentary loudness every 100 ms** (1,935 readings for a
193.5 s track), floored near −40 LUFS; subsampled, 128 readings that are close to
per-bucket means in dB (within about 0.5 dB — Plex's exact filter was not pinned down,
and at 35 points tall it does not show).

Plexamp turns those into bar heights in its player (`ProcessLoudnessData`): floor −35,
scale to 0–100, square for contrast (×1.5/100), normalise to 90/2.2, `x^1.2 / 2.4`, and
scale so the loudest is 35 points; then linear interpolation to 128 points. That transform
is `SeekbarShape` in `App/Core/SonicClient.swift`, tested.

The app asks our service for `/levels?points=128` for the track playing and the two
behind it (`SeekbarLevelsStore`, `App/Core/SeekbarLevels.swift`), keeps the answers in
memory and in `Caches/Music/Levels`, and for a track the service has not analysed falls
back to the same readings measured from the file once it is on the phone
(`TrackShape.levels`): BS.1770 momentary every 100 ms over the whole track, floored at
−40, averaged in dB over spans `i·n/128 ..< (i+1)·n/128`, rounded to 0.1 dB — the
service buckets identically, so the two sources draw the same.

The same stream also carries Plex's loudness analysis — `ld:gain`, `ld:loudness`,
`ld:lra`, `ld:peak`, and `ld:startRamp` / `ld:endRamp` as `"<loudness> <seconds>;…"`
pairs, which is what Sweet Fades sizes its overlaps from.

## Ours: `server/sonic`

A service on 148 that does the above for every track Navidrome has, keyed by Navidrome's
song, album and artist ids, and serves it to the app on port 8650:

| Endpoint | Plexamp feature |
|---|---|
| `GET /v1/status` | analysed counts |
| `GET /v1/tracks/{id}/levels?points=128` | seekbar shape |
| `GET /v1/tracks/{id}/similar?limit=&exclude_artist=` | Sonically Similar, DJ Gemini, DJ Freeze |
| `GET /v1/tracks/{id}/distant?limit=` | Outside Your Comfort Zone |
| `GET /v1/albums/{id}/similar`, `GET /v1/artists/{id}/similar` | Sonically Similar Albums / Artists |
| `GET /v1/path?from=&to=&steps=` | Sonic Adventure, DJ Stretch |
| `GET /v1/radio?seed=&exclude=&limit=` | track radio, stations |

Beyond Plex, the same pass measures each track's beats, tempo and key
(`/v1/tracks/{id}/rhythm`), for beat-matched crossfades, and serves the model's 50 tags
(`/v1/tracks/{id}/tags`, `/v1/tags/{tag}/tracks`) — the source of the app's mood
stations. Plex's model is MSD MusiCNN, so its outputs are the Million Song Dataset's
Last.fm tags: rock, pop, chill, sad, happy, party, 80s and the rest.

Lists answer `{"items": [{"id": "...", "distance": 0.12}]}`; levels answer
`{"id": "...", "hop": 0.1, "levels": [-39.9, ...]}`. A track not analysed yet is a 404,
which the app treats as "fall back to Navidrome's similar songs".
