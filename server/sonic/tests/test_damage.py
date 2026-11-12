import struct
import tempfile
import unittest
from pathlib import Path

from sonic.damage import BLOCK, zero_runs


def flac(path: Path, padding: int, audio: bytes) -> None:
    info = struct.pack(">HH", 4096, 4096) + b"\x00" * 6 + ((44100 << 44) | (1 << 41) | (15 << 36)).to_bytes(8, "big") + b"\x00" * 16
    blocks = bytes([0]) + len(info).to_bytes(3, "big") + info
    blocks += bytes([0x80 | 1]) + padding.to_bytes(3, "big") + bytes(padding)
    path.write_bytes(b"fLaC" + blocks + audio)


class Damage(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())

    def test_zeros_where_the_audio_should_be(self):
        path = self.folder / "cut.flac"
        flac(path, 4096, b"\xff\xf8" + bytes(3 * (1 << 20)) + b"\xff\xf8audio" * 1000)
        first, total = zero_runs(str(path))
        self.assertGreaterEqual(first, 0)
        self.assertGreaterEqual(total, 2 * (1 << 20))

    def test_padding_is_not_damage(self):
        path = self.folder / "padded.flac"
        flac(path, 3 * (1 << 20) - 100, b"\xff\xf8audio" * 50_000)
        self.assertEqual(zero_runs(str(path)), (-1, 0))

    def test_short_runs_are_not_damage(self):
        path = self.folder / "quiet.flac"
        flac(path, 100, (b"\xff\xf8" + bytes(BLOCK * 3)) * 20)
        self.assertEqual(zero_runs(str(path)), (-1, 0))


if __name__ == "__main__":
    unittest.main()
