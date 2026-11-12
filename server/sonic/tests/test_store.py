import tempfile
import unittest
from pathlib import Path

import numpy as np

from sonic.config import ANALYSIS_VERSION
from sonic.library import LibraryTrack
from sonic.store import Store


def track(track_id):
    return LibraryTrack(id=track_id, path=f"/music/{track_id}.flac", album_id="a", artist_id="x",
                        track_artist_id="x", title=track_id, artist="x", album="a", duration=1.0,
                        year=0, plays=0, fingerprint="f")


def result(track_id, levels):
    return {"id": track_id, "vector": np.zeros(50, np.float32).tobytes(),
            "levels": np.array(levels, np.float16).tobytes(), "loudness": None, "lra": None,
            "duration": 1.0, "bpm": 120.0, "beats": np.array([0.5], np.float32).tobytes()}


class RequeueTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = Store(Path(folder.name) / "sonic.db")
        self.store.sync([track("clean"), track("broken"), track("waiting")])
        self.store.save(result("clean", [-40, -12, -9]))
        self.store.save(result("broken", [-40, np.inf, np.nan]))

    def test_only_unreadable_levels_are_queued_again(self):
        self.assertEqual([job[0] for job in self.store.pending()], ["waiting"])
        self.assertEqual(self.store.requeue_unreadable_levels(), 1)
        self.assertEqual(sorted(job[0] for job in self.store.pending()), ["broken", "waiting"])

    def test_the_rest_of_the_analysis_is_served_meanwhile(self):
        self.store.requeue_unreadable_levels()
        self.assertEqual(self.store.counts()["analysed"], 2)
        self.assertIsNotNone(self.store.rhythm("broken"))
        self.assertIn("broken", [row[0] for row in self.store.rows()])

    def test_analysed_again_it_is_done(self):
        self.store.requeue_unreadable_levels()
        self.store.save(result("broken", [-40, -11, -8]))
        self.assertEqual([job[0] for job in self.store.pending()], ["waiting"])
        self.assertEqual(self.store.requeue_unreadable_levels(), 0)
        self.assertEqual(ANALYSIS_VERSION, 1)  # version 0 must stay older than any analysis


if __name__ == "__main__":
    unittest.main()


class FingerprintTests(unittest.TestCase):
    """A retag rewrites the file but not the audio: the analysis stays. New audio is analysed."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = Store(Path(folder.name) / "sonic.db")

    def synced(self, fingerprint):
        from dataclasses import replace
        self.store.sync([replace(track("s1"), fingerprint=fingerprint)])

    def test_same_audio_keeps_its_analysis(self):
        from sonic.library import audio_fingerprint
        self.synced(audio_fingerprint("flac", 44100, 16, 2, 201.6))
        self.store.save(result("s1", [-40, -12, -9]))
        self.synced(audio_fingerprint("FLAC", 44100, 16, 2, 201.6004))
        self.assertEqual(self.store.pending(), [])

    def test_new_audio_is_analysed_again(self):
        from sonic.library import audio_fingerprint
        self.synced(audio_fingerprint("flac", 96000, 24, 2, 324.0))
        self.store.save(result("s1", [-40, -12, -9]))
        self.synced(audio_fingerprint("flac", 44100, 16, 2, 325.16))
        self.assertEqual([job[0] for job in self.store.pending()], ["s1"])

    def test_an_old_style_fingerprint_moves_over_without_analysing(self):
        from sonic.library import audio_fingerprint
        self.synced("41923515:2026-11-01T10:00:00Z")
        self.store.save(result("s1", [-40, -12, -9]))
        self.synced(audio_fingerprint("flac", 44100, 16, 2, 325.16))
        self.assertEqual(self.store.pending(), [])
        self.synced(audio_fingerprint("flac", 48000, 24, 2, 325.16))
        self.assertEqual([job[0] for job in self.store.pending()], ["s1"])
