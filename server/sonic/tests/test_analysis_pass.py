import os
import unittest
from types import SimpleNamespace

from sonic import service
from sonic.service import Service


def fake_analyse(job):
    """Dies the way a decoder crash kills a worker, for the track called "bad"."""
    if job[0] == "bad":
        os._exit(134)
    return {"id": job[0], "duration": 1.0}


def fake_init(_model_path):
    pass


class FakeStore:
    def __init__(self, ids):
        self.jobs = [(track_id, f"/music/{track_id}.flac", 100.0) for track_id in ids]
        self.saved = {}

    def pending(self):
        return self.jobs

    def save(self, result):
        self.saved[result["id"]] = result.get("error", "ok")


class AnalysisPass(unittest.TestCase):
    def setUp(self):
        self.patched = (service.analyse, service.init_worker)
        service.analyse, service.init_worker = fake_analyse, fake_init

    def tearDown(self):
        service.analyse, service.init_worker = self.patched

    def run_pass(self, ids):
        fake = SimpleNamespace(
            config=SimpleNamespace(workers=2, model="model.pb"),
            store=FakeStore(ids), analysing=False, refresh_index=lambda: None,
        )
        fake._pool = lambda workers: Service._pool(fake, workers)
        fake._run = lambda pool, jobs, total: Service._run(fake, pool, jobs, total)
        Service.analyse_pending(fake)
        return fake.store.saved

    def test_one_track_that_crashes_does_not_stop_the_rest(self):
        ids = [f"t{index}" for index in range(9)]
        ids.insert(3, "bad")
        saved = self.run_pass(ids)
        self.assertEqual(saved.pop("bad"), "crashed the decoder")
        self.assertEqual(saved, {track_id: "ok" for track_id in ids if track_id != "bad"})

    def test_a_pass_with_nothing_wrong(self):
        self.assertEqual(self.run_pass(["a", "b", "c"]), {"a": "ok", "b": "ok", "c": "ok"})


if __name__ == "__main__":
    unittest.main()
