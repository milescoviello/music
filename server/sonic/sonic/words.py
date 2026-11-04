"""Lyrics help for the desktop app, which has none of Apple's language tools.

**Readings.** The phone romanizes Japanese with Apple's tokenizer: each word's reading,
joined with spaces, the particles は, へ and を as sung. The desktop had only a generic
transform, which read kanji as Mandarin (罪 as "zuì", not "tsumi") and ran words
together. Here MeCab (through cutlet, with UniDic Lite) splits the line into the same
kind of tokens, each with its reading, and the app joins them with the phone's own
code, so both say the same.

**Translations.** The phone translates on the device; the desktop asks this. Two
engines. An Argos model per language (OPUS-trained, run by CTranslate2 on the CPU)
answers at once, rough but readable; it is a draft. A local model through Ollama
translates better, but on this server it shares the GPU and the CPU with everything
else, and on 2026-11-04 it managed five tokens in 37 seconds. So the draft is the
answer, and the model replaces it later, when the machine is quiet. Each answer is kept
on disk, keyed by the language and the exact lines; the app keeps only finished ones,
so it shows the better translation the next time it asks.
"""

from __future__ import annotations

import hashlib
import json
import logging
import queue
import re
import threading
import time
import urllib.request
from pathlib import Path

log = logging.getLogger(__name__)

# Lines per request to the model: small enough that one finishes on a slow machine.
CHUNK = 12
FAILURE_MEMORY = 600


class Readings:
    """Japanese lines as tokens: `{"text"}` for what is read as written, `{"text", "reading"}`."""

    def __init__(self) -> None:
        self._cutlet = None
        self._lock = threading.Lock()

    def _tool(self):
        if self._cutlet is None:
            import cutlet  # noqa: PLC0415 — a few hundred MB of dictionary, loaded when first asked

            tool = cutlet.Cutlet()
            # Loanwords as they are sung in Japanese, as the phone reads them, not respelled.
            tool.use_foreign_spelling = False
            self._cutlet = tool
        return self._cutlet

    def tokens(self, lines: list[str]) -> dict:
        with self._lock:  # MeCab's tagger is not safe across threads
            tool = self._tool()
            out = []
            for line in lines:
                tokens: list[dict] = []
                for word in tool.tagger(line):
                    if word.white_space:
                        tokens.append({"text": word.white_space})
                    reading = tool.romaji_word(word)
                    token = {"text": word.surface}
                    if reading and reading != word.surface:
                        token["reading"] = reading.lower()
                    tokens.append(token)
                out.append(tokens)
        return {"lines": out}


class Argos:
    """Argos's OPUS models, one per language into English, fetched the first time a
    language is asked for and kept under `data/argos`. CTranslate2 and SentencePiece run
    them; the rest of Argos (PyTorch, Stanza) is not needed for line-by-line lyrics."""

    INDEX = "https://raw.githubusercontent.com/argosopentech/argospm-index/main/index.json"

    def __init__(self, directory: Path) -> None:
        self.dir = directory
        self.dir.mkdir(parents=True, exist_ok=True)
        self._models: dict[str, tuple] = {}
        self._missing: dict[str, float] = {}
        self._lock = threading.Lock()

    def translate(self, language: str, lines: list[str]) -> list[str] | None:
        """None when there is no model for the language."""
        with self._lock:
            model = self._load(language)
            if model is None:
                return None
            translator, pieces = model
            batch = [pieces.encode(line, out_type=str) for line in lines]
            results = translator.translate_batch(batch, beam_size=4, max_decoding_length=128)
            return [pieces.decode(result.hypotheses[0]).replace("\u2047", "").strip() for result in results]

    def _load(self, language: str):
        if language in self._models:
            return self._models[language]
        missing = self._missing.get(language)
        if missing and time.time() - missing < 6 * 3600:
            return None
        folder = self.dir / f"{language}_en"
        if not (folder / "model").exists() and not self._fetch(language, folder):
            self._missing[language] = time.time()
            return None
        import ctranslate2  # noqa: PLC0415
        import sentencepiece  # noqa: PLC0415

        translator = ctranslate2.Translator(str(folder / "model"), device="cpu", inter_threads=1, intra_threads=2)
        pieces = sentencepiece.SentencePieceProcessor(model_file=str(folder / "sentencepiece.model"))
        self._models[language] = (translator, pieces)
        return self._models[language]

    def _fetch(self, language: str, folder: Path) -> bool:
        import io  # noqa: PLC0415
        import zipfile  # noqa: PLC0415

        def get(url: str, timeout: int):
            # A name of its own: the model host answers Python's default with 403.
            return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "sonic/1"}), timeout=timeout)

        try:
            with get(self.INDEX, 30) as response:
                index = json.load(response)
            package = next((p for p in index if p.get("from_code") == language and p.get("to_code") == "en"), None)
            if package is None:
                return False
            with get(package["links"][0], 300) as response:
                archive = zipfile.ZipFile(io.BytesIO(response.read()))
            root = archive.namelist()[0].split("/")[0]
            folder.mkdir(parents=True, exist_ok=True)
            for name in archive.namelist():
                inner = name[len(root) + 1:]
                if not inner or inner.endswith("/") or inner.startswith("stanza/"):
                    continue
                target = folder / inner
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
            log.info("fetched the %s→en translation model", language)
            return (folder / "model").exists()
        except Exception as error:  # noqa: BLE001
            log.warning("could not fetch a %s→en model: %s", language, error)
            return False


class Translations:
    def __init__(self, data_dir: Path, ollama: str, model: str) -> None:
        self.dir = data_dir / "translations"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.argos = Argos(data_dir / "argos")
        self.ollama = ollama.rstrip("/")
        self.model = model
        self._queue: queue.Queue = queue.Queue()
        self._pending: set[str] = set()
        self._failed: dict[str, tuple[float, str]] = {}
        self._lock = threading.Lock()
        threading.Thread(target=self._work, name="translations", daemon=True).start()

    @staticmethod
    def key(language: str, lines: list[str]) -> str:
        return hashlib.sha1(json.dumps([language, lines], ensure_ascii=False).encode()).hexdigest()

    def answer(self, language: str, lines: list[str]) -> tuple[int, dict]:
        """200 with one English line per line (`"draft": true` while it is Argos's), 202
        while a language Argos has no model for is being done, 503 when that failed."""
        if not lines or len(lines) > 400 or not all(isinstance(line, str) for line in lines):
            return 400, {"error": "between 1 and 400 lines of text"}
        key = self.key(language, lines)
        final = self.dir / f"{key}.json"
        draft = self.dir / f"{key}.draft.json"
        if final.exists():
            return 200, {"lines": json.loads(final.read_text())}
        if draft.exists():
            self._enqueue(key, language, lines)
            return 200, {"lines": json.loads(draft.read_text()), "draft": True}
        try:
            english = self.draft(language, lines)
        except Exception as error:  # noqa: BLE001
            log.warning("draft translation failed: %s", error)
            english = None
        if english is not None:
            draft.write_text(json.dumps(english, ensure_ascii=False))
            self._enqueue(key, language, lines)
            return 200, {"lines": english, "draft": True}
        with self._lock:
            failed = self._failed.get(key)
            if failed and time.time() - failed[0] < FAILURE_MEMORY:
                return 503, {"error": failed[1]}
        self._enqueue(key, language, lines)
        return 202, {"status": "translating"}

    def draft(self, language: str, lines: list[str]) -> list[str] | None:
        return self.argos.translate(language, lines)

    def _enqueue(self, key: str, language: str, lines: list[str]) -> None:
        with self._lock:
            failed = self._failed.get(key)
            if key in self._pending or (failed and time.time() - failed[0] < FAILURE_MEMORY):
                return
            self._pending.add(key)
            self._queue.put((key, language, lines))

    def _work(self) -> None:
        while True:
            key, language, lines = self._queue.get()
            # Only when the machine has room: on a busy one the model runs on the CPU at
            # a word every few seconds, and takes cores from everything else.
            while not self.quiet():
                time.sleep(60)
            started = time.time()
            try:
                english: list[str] = []
                for start in range(0, len(lines), CHUNK):
                    english += self._translate(language, lines[start:start + CHUNK])
                (self.dir / f"{key}.json").write_text(json.dumps(english, ensure_ascii=False))
                (self.dir / f"{key}.draft.json").unlink(missing_ok=True)
                log.info("translated %d %s lines in %.0f s", len(lines), language, time.time() - started)
            except Exception as error:  # noqa: BLE001 — anything at all is a failed translation
                log.warning("could not translate %d %s lines: %s", len(lines), language, error)
                with self._lock:
                    self._failed[key] = (time.time(), str(error))
            finally:
                with self._lock:
                    self._pending.discard(key)

    @staticmethod
    def quiet() -> bool:
        import os  # noqa: PLC0415

        return os.getloadavg()[0] < (os.cpu_count() or 4) / 2

    def _translate(self, language: str, lines: list[str]) -> list[str]:
        # Numbered lines rather than JSON: in Ollama's JSON mode the model can pad with
        # whitespace until it runs out of tokens, and ten lines took over ten minutes.
        numbered = "\n".join(f"{index + 1}. {line}" for index, line in enumerate(lines))
        prompt = (
            f"Translate these numbered song lyric lines ({language}) into natural English. Keep each "
            f"line's meaning and tone, and add nothing. A line already in English stays as it is. "
            f"Answer with exactly {len(lines)} numbered lines, in the same order, and nothing else.\n\n{numbered}"
        )
        body = {
            "model": self.model,
            "stream": False,
            "think": False,
            "keep_alive": "2m",
            "options": {"temperature": 0.2, "num_predict": 48 * len(lines), "num_thread": 4},
            "messages": [{"role": "user", "content": prompt}],
        }
        request = urllib.request.Request(
            f"{self.ollama}/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=300) as response:
            reply = json.load(response)
        english = numbered_lines(reply["message"]["content"], len(lines))
        if english is None:
            raise ValueError(f"the model did not answer with {len(lines)} lines")
        return english


def numbered_lines(text: str, count: int) -> list[str] | None:
    """`1. …` to `count. …`, each once, in order; None if the answer is not that."""
    found: dict[int, str] = {}
    for raw in text.splitlines():
        match = re.match(r"^\s*(\d+)[.):]\s*(.*)$", raw)
        if match and 1 <= int(match[1]) <= count and int(match[1]) not in found:
            found[int(match[1])] = match[2].strip()
    if len(found) != count:
        return None
    return [found[number] for number in range(1, count + 1)]
