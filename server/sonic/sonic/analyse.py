"""One track, analysed: Plex's sonic vector and its loudness levels, from one decode.

The recipe, verified against vectors Plex stored for the same files (cosine 0.999–0.9999):

1. Decode the file at its own rate and channel count.
2. Loudness: BS.1770 momentary loudness (400 ms windows, 100 ms hop) of the stereo signal
   — Plex's `/levels`, which Plexamp's seekbar draws and Sweet Fades reads.
3. Mix to mono and resample to 16 kHz with the best-quality resampler. The resampler
   matters: anything cheaper rolls off below 8 kHz, where the top mel bands are, and
   the vectors drift to cosine 0.95–0.98.
4. MusiCNN over back-to-back 3-second windows (187 frames, no overlap, last partial
   window dropped), and the 50 outputs averaged.

Plex stops there. This also finds each track's beats, tempo and key (Essentia's
multi-feature beat tracker and key extractor, at 44.1 kHz), for crossfades that land the
incoming track's beats on the outgoing one's — something Plexamp does not do.

Essentia is imported inside the worker, so the rest of the service — and its tests — run
without it.
"""

from __future__ import annotations

import math
import os

import numpy as np

LEVEL_FLOOR = -40.0
LEVEL_HOP = 0.1
# Essentia's BS.1770 meter diverges at 96 kHz: an infinite reading a few windows in, and
# every one after it not a number. Measured on 25 of the library's 2,887 such tracks: all
# 96 kHz, while 44.1 and 88.2 kHz files measure cleanly, and the same 96 kHz file
# resampled to 48 kHz reads 0% NaN and −19.2 LUFS. BS.1770 is specified at 48 kHz, so
# anything faster is measured there; nothing a meter of 400 ms windows reads is above it.
LOUDNESS_MAX_RATE = 48000
# Above this the whole stereo signal at its own rate would not fit comfortably in memory
# several times over, so a long mix is read at 16 kHz mono and measured from that.
LONG_TRACK_SECONDS = 20 * 60
# Longer than this is a recording of a whole concert or a broadcast; not analysed.
MAX_TRACK_SECONDS = 3 * 3600

# Codecs Essentia's own FFmpeg was built without, decoded here by libsndfile instead
# (`soundfile`). Essentia does not just refuse one: it frees its decoder twice tearing
# down, and the worker dies -- an Opus file did, on every pass.
FOREIGN_SUFFIXES = {".opus"}

_model = None


def init_worker(model_path: str) -> None:
    """Runs once per worker process: quiet logs, low priority, the model loaded."""
    global _model
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
    try:
        os.nice(10)
    except OSError:
        pass
    import essentia
    essentia.log.infoActive = False
    essentia.log.warningActive = False
    import essentia.standard as es
    _model = es.TensorflowPredictMusiCNN(
        graphFilename=model_path, output="model/Sigmoid", patchHopSize=187, lastPatchMode="discard"
    )


def levels_from_momentary(momentary: np.ndarray, duration: float) -> np.ndarray:
    """Momentary readings in Plex's form: floored at −40, one reading every 100 ms, as many
    as the track has whole tenths of a second.

    Essentia's first reading (with `startAtZero`) is Plex's second: Plex leads with one
    reading of the silence before the first window, which is put back here.

    A reading that is not a finite number is floored too. `np.maximum` alone passes NaN
    straight through, and one NaN in a bucket makes the bucket NaN, which is not JSON."""
    readings = np.asarray(momentary, dtype=np.float32)
    readings = np.maximum(np.where(np.isfinite(readings), readings, LEVEL_FLOOR), LEVEL_FLOOR)
    readings = np.concatenate([[LEVEL_FLOOR], readings]).astype(np.float32)
    count = max(1, int(math.floor(duration / LEVEL_HOP + 1e-6)))
    if len(readings) >= count:
        return readings[:count]
    return np.concatenate([readings, np.full(count - len(readings), LEVEL_FLOOR, np.float32)])


def _loudness(es, audio: np.ndarray, rate: float):
    """BS.1770 momentary and integrated loudness of a stereo signal, at no more than
    `LOUDNESS_MAX_RATE`. Each channel is resampled on its own, into one array, so a long
    96 kHz track costs half its decoded size again rather than twice it."""
    if rate > LOUDNESS_MAX_RATE:
        resample = es.Resample(inputSampleRate=rate, outputSampleRate=LOUDNESS_MAX_RATE, quality=1)
        first = resample(np.ascontiguousarray(audio[:, 0]))
        signal = np.empty((len(first), 2), np.float32)
        signal[:, 0] = first
        del first
        signal[:, 1] = resample(np.ascontiguousarray(audio[:, 1]))[:len(signal)]
        rate = LOUDNESS_MAX_RATE
    else:
        signal = audio
    momentary, _, integrated, lra = es.LoudnessEBUR128(sampleRate=rate, hopSize=LEVEL_HOP, startAtZero=True)(signal)
    return momentary, integrated, lra


def _rhythm(es, mono: np.ndarray, rate: float) -> dict:
    """Beats (seconds), tempo and key. Both extractors are built for 44.1 kHz, so other
    rates are resampled first. A failure here costs the beats, never the analysis."""
    try:
        signal = mono if rate == 44100 else es.Resample(inputSampleRate=rate, outputSampleRate=44100, quality=0)(mono)
        bpm, beats, confidence, _, _ = es.RhythmExtractor2013(method="multifeature")(signal)
        key, scale, strength = es.KeyExtractor()(signal)
        return {
            "bpm": float(bpm) if np.isfinite(bpm) else None,
            "beat_confidence": float(confidence) if np.isfinite(confidence) else None,
            "beats": np.asarray(beats, dtype=np.float32).tobytes(),
            "key": str(key),
            "scale": str(scale),
            "key_strength": float(strength) if np.isfinite(strength) else None,
        }
    except Exception:  # noqa: BLE001
        return {}


def _decode_elsewhere(path: str) -> tuple[np.ndarray, float, int]:
    """What `AudioLoader` gives -- stereo float samples, the rate, the file's channel
    count -- through libsndfile, for a codec Essentia cannot read."""
    import soundfile

    data, rate = soundfile.read(path, dtype="float32", always_2d=True)
    channels = data.shape[1]
    if channels == 1:
        data = np.repeat(data, 2, axis=1)
    elif channels > 2:
        # Front left and right: what a stereo fold-down keeps most of.
        data = data[:, :2]
    return np.ascontiguousarray(data), float(rate), min(channels, 2)


def analyse(job: tuple[str, str, float]) -> dict:
    """`(track id, local path, duration from Navidrome)` → the results, or an error."""
    track_id, path, known_duration = job
    try:
        import essentia.standard as es

        if known_duration > MAX_TRACK_SECONDS:
            return {"id": track_id, "error": "too long to analyse"}

        rhythm: dict = {}
        foreign = os.path.splitext(path)[1].lower() in FOREIGN_SUFFIXES
        if known_duration > LONG_TRACK_SECONDS:
            if foreign:
                audio, rate, channels = _decode_elsewhere(path)
                mono16 = es.Resample(inputSampleRate=rate, outputSampleRate=16000, quality=0)(
                    es.MonoMixer()(audio, channels))
                del audio
            else:
                mono16 = es.MonoLoader(filename=path, sampleRate=16000, resampleQuality=0)()
            duration = len(mono16) / 16000
            stereo = np.stack([mono16, mono16], axis=1).astype(np.float32)
            momentary, _, integrated, lra = es.LoudnessEBUR128(sampleRate=16000, hopSize=LEVEL_HOP, startAtZero=True)(stereo)
        else:
            if foreign:
                audio, rate, channels = _decode_elsewhere(path)
            else:
                audio, rate, channels, *_ = es.AudioLoader(filename=path)()
            duration = len(audio) / rate
            momentary, integrated, lra = _loudness(es, audio, rate)
            mono = es.MonoMixer()(audio, channels)
            mono16 = es.Resample(inputSampleRate=rate, outputSampleRate=16000, quality=0)(mono)
            rhythm = _rhythm(es, mono, rate)
            del audio, mono

        vector = None
        # One whole window is 187 frames of 256 samples plus the frame itself.
        if len(mono16) >= 187 * 256 + 512:
            predictions = _model(mono16)
            if len(predictions):
                vector = np.asarray(predictions, dtype=np.float32).mean(axis=0)

        return {
            "id": track_id,
            "vector": None if vector is None else vector.astype(np.float32).tobytes(),
            "levels": levels_from_momentary(momentary, duration).astype(np.float16).tobytes(),
            "loudness": float(integrated) if np.isfinite(integrated) else None,
            "lra": float(lra) if np.isfinite(lra) else None,
            "duration": float(duration),
            **rhythm,
        }
    except Exception as error:  # noqa: BLE001 — any file can be broken in any way
        return {"id": track_id, "error": f"{type(error).__name__}: {error}"[:300]}
