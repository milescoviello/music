"""Translations for the desktop's lyrics: the queue and the cache, without a model."""

import tempfile
import time
import unittest
from pathlib import Path

from sonic.words import Translations, numbered_lines


class FakeTranslations(Translations):
    """The model upper-cases; the draft, when there is one, adds "~"."""

    def __init__(self, data_dir, fail=False, drafts=False):
        self.fail = fail
        self.drafts = drafts
        self.calls = 0
        super().__init__(data_dir, "http://unused", "unused")

    def draft(self, language, lines):
        return [f"~{line}" for line in lines] if self.drafts else None

    @staticmethod
    def quiet():
        return True

    def _translate(self, language, lines):
        self.calls += 1
        if self.fail:
            raise ValueError("no model")
        return [line.upper() for line in lines]


class TranslationQueue(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)

    def settled(self, translations, language, lines):
        deadline = time.time() + 5
        while time.time() < deadline:
            status, body = translations.answer(language, lines)
            if status != 202:
                return status, body
            time.sleep(0.02)
        self.fail("still translating")

    def test_a_song_is_translated_once_then_kept(self):
        translations = FakeTranslations(self.dir)
        self.assertEqual(translations.answer("ja", ["kimi", "boku"])[0], 202)
        self.assertEqual(self.settled(translations, "ja", ["kimi", "boku"]), (200, {"lines": ["KIMI", "BOKU"]}))
        # Asked again after a restart: from disk, not translated again.
        again = FakeTranslations(self.dir)
        self.assertEqual(again.answer("ja", ["kimi", "boku"]), (200, {"lines": ["KIMI", "BOKU"]}))
        self.assertEqual(translations.calls + again.calls, 1)

    def test_a_failure_is_said_and_not_retried_at_once(self):
        translations = FakeTranslations(self.dir, fail=True)
        translations.answer("ja", ["kimi"])
        status, body = self.settled(translations, "ja", ["kimi"])
        self.assertEqual(status, 503)
        self.assertIn("no model", body["error"])
        self.assertEqual(translations.calls, 1)

    def test_a_draft_answers_at_once_and_the_model_replaces_it(self):
        translations = FakeTranslations(self.dir, drafts=True)
        self.assertEqual(translations.answer("ja", ["kimi"]), (200, {"lines": ["~kimi"], "draft": True}))
        deadline = time.time() + 5
        while time.time() < deadline and translations.answer("ja", ["kimi"])[1].get("draft"):
            time.sleep(0.02)
        self.assertEqual(translations.answer("ja", ["kimi"]), (200, {"lines": ["KIMI"]}))

    def test_the_models_numbered_lines_are_read_in_order(self):
        self.assertEqual(numbered_lines("1. I called\n2) your name\n", 2), ["I called", "your name"])
        self.assertEqual(numbered_lines("Here you go:\n1. one\n2. two\n3. three", 3), ["one", "two", "three"])
        self.assertIsNone(numbered_lines("1. one\n3. three", 3))

    def test_nonsense_is_refused(self):
        translations = FakeTranslations(self.dir)
        self.assertEqual(translations.answer("ja", [])[0], 400)
        self.assertEqual(translations.answer("ja", ["a"] * 401)[0], 400)


if __name__ == "__main__":
    unittest.main()
