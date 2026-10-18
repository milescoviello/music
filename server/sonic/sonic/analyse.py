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
# Above this the whole stereo signal at its own rate would not fit comfortably in memory
# several times over, so a long mix is read at 16 kHz mono and measured from that.
LONG_TRACK_SECONDS = 20 * 60
# Longer than this is a recording of a whole concert or a broadcast; not analysed.
MAX_TRACK_SECONDS = 3 * 3600

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
    reading of the silence before the first window, which is put back here."""
    readings = np.maximum(np.asarray(momentary, dtype=np.float32), LEVEL_FLOOR)
    readings = np.concatenate([[LEVEL_FLOOR], readings]).astype(np.float32)
    count = max(1, int(math.floor(duration / LEVEL_HOP + 1e-6)))
    if len(readings) >= count:
        return readings[:count]
    return np.concatenate([readings, np.full(count - len(readings), LEVEL_FLOOR, np.float32)])


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


def analyse(job: tuple[str, str, float]) -> dict:
    """`(track id, local path, duration from Navidrome)` → the results, or an error."""
    track_id, path, known_duration = job
    try:
        import essentia.standard as es

        if known_duration > MAX_TRACK_SECONDS:
            return {"id": track_id, "error": "too long to analyse"}

        rhythm: dict = {}
        if known_duration > LONG_TRACK_SECONDS:
            mono16 = es.MonoLoader(filename=path, sampleRate=16000, resampleQuality=0)()
            duration = len(mono16) / 16000
            stereo = np.stack([mono16, mono16], axis=1).astype(np.float32)
            momentary, _, integrated, lra = es.LoudnessEBUR128(sampleRate=16000, hopSize=LEVEL_HOP, startAtZero=True)(stereo)
        else:
            audio, rate, channels, *_ = es.AudioLoader(filename=path)()
            duration = len(audio) / rate
            momentary, _, integrated, lra = es.LoudnessEBUR128(sampleRate=rate, hopSize=LEVEL_HOP, startAtZero=True)(audio)
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
