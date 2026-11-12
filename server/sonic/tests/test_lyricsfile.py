import io
import json
import os
import struct
import tempfile
import unittest
from pathlib import Path

from sonic.lyricsfile import Line, Refused, _audio_checksum, ask_scan, check_admin, lrc, request, words, write

try:
    import mutagen
    import mutagen.flac
    import mutagen.id3
except ImportError:  # the analysis needs only NumPy; the writing is tested where it runs
    mutagen = None


def flac_file(path: Path, comments: list[tuple[str, str]], audio: bytes = b"\x00" * 64) -> None:
    """A FLAC file mutagen reads: a real STREAMINFO, Vorbis comments, and bytes standing in
    for the audio, which these tests never decode."""
    # 4096-sample blocks, 44.1 kHz, 2 channels, 16 bits, 44100 samples.
    info = struct.pack(">HH", 4096, 4096) + b"\x00\x00\x00" * 2
    packed = (44100 << 44) | ((2 - 1) << 41) | ((16 - 1) << 36) | 44100
    info += packed.to_bytes(8, "big") + b"\x00" * 16
    vendor = b"test"
    body = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(comments))
    for key, value in comments:
        entry = f"{key}={value}".encode()
        body += struct.pack("<I", len(entry)) + entry
    blocks = bytes([0]) + len(info).to_bytes(3, "big") + info
    blocks += bytes([0x80 | 4]) + len(body).to_bytes(3, "big") + body
    path.write_bytes(b"fLaC" + blocks + audio)


def mp3_file(path: Path, lyrics: str, version: int = 3) -> None:
    """MPEG frames of silence after an ID3 tag holding `lyrics` as USLT."""
    frame = b"\xff\xfb\x90\x64" + b"\x00" * 413          # 128 kbps, 44.1 kHz: 417 bytes
    path.write_bytes(frame * 8)
    tags = mutagen.id3.ID3()
    tags.add(mutagen.id3.USLT(encoding=3, lang="eng", desc="", text=lyrics))
    tags.add(mutagen.id3.TIT2(encoding=3, text="Glass Harbor"))
    tags.save(path, v2_version=version)


def same_audio(_path: str) -> str:
    return "unchanged"


SYNCED = "[00:01.00]First light\n[00:04.50]Over the harbor\n[00:09.00]"
FIXED = [Line(1500, "First light"), Line(5000, "Over the harbor"), Line(9500, "")]


class Lrc(unittest.TestCase):
    def test_hundredths_and_minutes(self):
        self.assertEqual(lrc([Line(0, "a"), Line(61_234, "b"), Line(3_725_000, "c")]),
                         "[00:00.00]a\n[01:01.23]b\n[62:05.00]c")

    def test_a_line_stays_one_line(self):
        self.assertEqual(lrc([Line(1000, "two\nlines  here")]), "[00:01.00]two lines here")

    def test_blank_lines_keep_their_time(self):
        self.assertEqual(lrc([Line(9000, "")]), "[00:09.00]")


class Words(unittest.TestCase):
    def test_timed(self):
        self.assertEqual(words(SYNCED), (["First light", "Over the harbor"], True))

    def test_plain_without_blanks(self):
        self.assertEqual(words("First light\n\n  Over the   harbor \r\n"), (["First light", "Over the harbor"], False))

    def test_headers_are_not_lines(self):
        text = "[ar: The Lanterns]\n[ti: Glass Harbor]\n[offset:+200]\n[00:01.00]First light"
        self.assertEqual(words(text), (["First light"], True))

    def test_a_line_stamped_twice_is_two_lines_in_time_order(self):
        text = "[00:05.00][00:20.00]Chorus\n[00:10.00]Verse"
        self.assertEqual(words(text), (["Chorus", "Verse", "Chorus"], True))

    def test_three_digit_and_colon_fractions(self):
        self.assertEqual(words("[00:02:500]b\n[00:01.250]a"), (["a", "b"], True))

    def test_a_bracketed_section_name_is_a_line(self):
        self.assertEqual(words("[Chorus]\nFirst light"), (["[Chorus]", "First light"], False))


class Requests(unittest.TestCase):
    def body(self, **change):
        body = {"id": "abc", "original": ["First light"], "synced": False,
                "lines": [{"start": 0, "value": "First light"}], "auth": {"u": "miles", "t": "x", "s": "y"}}
        body.update(change)
        return body

    def test_a_good_one(self):
        fix = request(self.body())
        self.assertEqual((fix.track_id, fix.lines, fix.auth["u"]), ("abc", [Line(0, "First light")], "miles"))

    def test_lines_out_of_order(self):
        with self.assertRaises(Refused) as caught:
            request(self.body(lines=[{"start": 2000, "value": "b"}, {"start": 1000, "value": "a"}]))
        self.assertEqual(caught.exception.status, 400)

    def test_a_line_without_a_time(self):
        for start in (-1, 1.5, True):
            with self.assertRaises(Refused):
                request(self.body(lines=[{"start": start, "value": "a"}]))
        with self.assertRaises(Refused):
            request(self.body(lines=[{"start": 0, "value": "a"}, {"value": "b"}]))

    def test_words_alone(self):
        fix = request(self.body(lines=[{"value": "First light"}, {"start": None, "value": "Over the harbor"}]))
        self.assertEqual(fix.lines, [Line(None, "First light"), Line(None, "Over the harbor")])
        self.assertEqual(lrc(fix.lines), "First light\nOver the harbor")

    def test_no_sign_in(self):
        with self.assertRaises(Refused) as caught:
            request(self.body(auth={"u": "miles"}))
        self.assertEqual(caught.exception.status, 401)


class Admins(unittest.TestCase):
    @staticmethod
    def server(answer):
        asked = []

        def open_url(url, timeout):
            asked.append(url)
            return io.BytesIO(json.dumps({"subsonic-response": answer}).encode())
        return open_url, asked

    def test_an_admin(self):
        open_url, asked = self.server({"status": "ok", "user": {"username": "miles", "adminRole": True}})
        check_admin("http://nd:4533/", {"u": "miles", "t": "tok", "s": "salt"}, open_url)
        self.assertTrue(asked[0].startswith("http://nd:4533/rest/getUser.view?"))
        self.assertIn("username=miles", asked[0])
        self.assertIn("t=tok", asked[0])

    def test_not_an_admin(self):
        open_url, _ = self.server({"status": "ok", "user": {"adminRole": False}})
        with self.assertRaises(Refused) as caught:
            check_admin("http://nd", {"u": "guest", "t": "t", "s": "s"}, open_url)
        self.assertEqual(caught.exception.status, 403)

    def test_a_wrong_password(self):
        open_url, _ = self.server({"status": "failed", "error": {"code": 40}})
        with self.assertRaises(Refused) as caught:
            check_admin("http://nd", {"u": "miles", "t": "t", "s": "s"}, open_url)
        self.assertEqual(caught.exception.status, 401)


class Scans(unittest.TestCase):
    def test_asks_for_a_quick_scan(self):
        asked = []

        def open_url(url, timeout):
            asked.append(url)
            return io.BytesIO(b"{}")
        ask_scan("http://nd:4533", {"u": "miles", "t": "tok", "s": "salt"}, open_url)
        self.assertTrue(asked[0].startswith("http://nd:4533/rest/startScan.view?"))
        self.assertNotIn("fullScan", asked[0])

    def test_a_server_that_does_not_answer_is_not_an_error(self):
        def open_url(url, timeout):
            raise OSError("refused")
        ask_scan("http://nd", {"u": "miles", "t": "t", "s": "s"}, open_url)


@unittest.skipIf(mutagen is None, "mutagen is not installed")
class Writing(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())

    def tearDown(self):
        for item in self.folder.iterdir():
            item.unlink()
        self.folder.rmdir()

    def test_flac_tag_rewritten_in_place(self):
        path = self.folder / "song.flac"
        flac_file(path, [("TITLE", "Glass Harbor"), ("Lyrics", SYNCED), ("ARTIST", "The Lanterns")])
        changed = write(str(path), ["First light", "Over the harbor"], True, FIXED)
        self.assertEqual(changed, ["LYRICS"])
        tags = mutagen.flac.FLAC(path).tags
        # Same name, same case, same place among the others.
        self.assertEqual([key for key, _ in tags], ["TITLE", "Lyrics", "ARTIST"])
        self.assertEqual(tags["lyrics"], [lrc(FIXED)])
        self.assertEqual(list(self.folder.iterdir()), [path])

    def test_flac_audio_bytes_untouched(self):
        path = self.folder / "song.flac"
        audio = bytes(range(256)) * 4
        flac_file(path, [("LYRICS", "First light")], audio)
        write(str(path), ["First light"], False, [Line(1000, "First light")])
        self.assertTrue(path.read_bytes().endswith(audio))

    def test_only_the_set_on_screen(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", SYNCED), ("UNSYNCEDLYRICS", "First light\nOver the harbor"),
                         ("LYRICS", "[00:01.00]Primera luz")])
        changed = write(str(path), ["First light", "Over the harbor"], False, FIXED, checksum=same_audio)
        self.assertEqual(changed, ["UNSYNCEDLYRICS"])
        tags = mutagen.flac.FLAC(path).tags
        self.assertEqual(tags["lyrics"], [SYNCED, "[00:01.00]Primera luz"])
        self.assertEqual(tags["unsyncedlyrics"], [lrc(FIXED)])

    def test_words_that_changed_are_refused(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "Something else entirely")])
        before = path.read_bytes()
        with self.assertRaises(Refused) as caught:
            write(str(path), ["First light"], False, [Line(0, "First light")], checksum=same_audio)
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.folder.iterdir()), [path])

    def test_audio_that_would_change_is_refused(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "First light")])
        before = path.read_bytes()
        answers = iter(["before", "after"])
        with self.assertRaises(Refused) as caught:
            write(str(path), ["First light"], False, [Line(0, "First light")], checksum=lambda _: next(answers))
        self.assertEqual(caught.exception.status, 500)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.folder.iterdir()), [path])

    def test_mp3_keeps_its_id3_version(self):
        path = self.folder / "song.mp3"
        mp3_file(path, "First light\nOver the harbor", version=3)
        changed = write(str(path), ["First light", "Over the harbor"], False, FIXED)
        self.assertEqual(changed, ["USLT:eng"])
        tags = mutagen.id3.ID3(path)
        self.assertEqual(tags.version[:2], (2, 3))
        self.assertEqual(tags.getall("USLT")[0].text, lrc(FIXED))
        self.assertEqual(str(tags["TIT2"]), "Glass Harbor")

    def test_the_checksum_is_the_audio_alone(self):
        for make in (lambda path, text: flac_file(path, [("LYRICS", text)], bytes(range(200))),
                     lambda path, text: mp3_file(path, text)):
            path = self.folder / "song"
            make(path, "short")
            first = _audio_checksum(str(path))
            make(path, "a much longer set of words " * 40)
            self.assertEqual(_audio_checksum(str(path)), first)
            data = bytearray(path.read_bytes())
            data[-200] ^= 1
            path.write_bytes(bytes(data))
            self.assertNotEqual(_audio_checksum(str(path)), first)
            path.unlink()

    def test_an_lrc_beside_the_song_comes_first(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "First light\nOver the harbor")])
        before = path.read_bytes()
        sidecar = self.folder / "song.lrc"
        sidecar.write_text("\ufeff[ti:Glass Harbor]\n[ar:The Lanterns]\n[offset:+300]\n" + SYNCED + "\n",
                           encoding="utf-8")
        changed = write(str(path), ["First light", "Over the harbor"], True, FIXED, checksum=same_audio)
        self.assertEqual(changed, [".lrc beside the song"])
        # The headers stay, all but the offset, which the app put into the times.
        self.assertEqual(sidecar.read_text(encoding="utf-8"),
                         "[ti:Glass Harbor]\n[ar:The Lanterns]\n" + lrc(FIXED) + "\n")
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(sorted(item.name for item in self.folder.iterdir()), ["song.flac", "song.lrc"])

    def test_an_empty_lrc_is_passed_over(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "First light")])
        (self.folder / "song.lrc").write_text("[ti:Glass Harbor]\n")
        self.assertEqual(write(str(path), ["First light"], False, [Line(0, "First light")]), ["LYRICS"])
        self.assertEqual((self.folder / "song.lrc").read_text(), "[ti:Glass Harbor]\n")

    def test_an_lrc_with_other_words_is_refused(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "First light")])
        (self.folder / "song.lrc").write_text("[00:01.00]Pale orchid")
        with self.assertRaises(Refused) as caught:
            write(str(path), ["First light"], False, [Line(0, "First light")], checksum=same_audio)
        self.assertEqual(caught.exception.status, 409)

    def test_a_folder_that_cannot_be_written(self):
        path = self.folder / "song.flac"
        flac_file(path, [("LYRICS", "First light")])
        (self.folder / "song.lrc").write_text("First light")
        os.chmod(self.folder, 0o555)
        try:
            if os.access(self.folder, os.W_OK):
                self.skipTest("running as root")
            with self.assertRaises(Refused) as caught:
                write(str(path), ["First light"], False, [Line(0, "First light")], checksum=same_audio)
            self.assertEqual(caught.exception.status, 403)
        finally:
            os.chmod(self.folder, 0o755)

    def test_no_file(self):
        with self.assertRaises(Refused) as caught:
            write(str(self.folder / "gone.flac"), ["a"], False, [Line(0, "a")], checksum=same_audio)
        self.assertEqual(caught.exception.status, 404)


if __name__ == "__main__":
    unittest.main()
