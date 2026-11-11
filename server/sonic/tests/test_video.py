import json
import struct
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from sonic import video
from sonic.http import make_handler


def result(title, channel, duration=240, views=1_000_000, verified=False):
    return {"id": "abcdefghijk", "title": title, "channel": channel, "duration": duration,
            "views": views, "verified": verified}


class Picking(unittest.TestCase):
    """Which search result is the song's own video."""

    def best(self, artist, title, duration, items):
        return max(items, key=lambda item: video.score(item, artist, title, duration))["title"]

    def test_official_video_beats_live_lyric_and_cover(self):
        items = [
            result("Glass Harbor - Low Tide (Live at the Arena)", "Glass Harbor", 300, 9_000_000),
            result("Glass Harbor - Low Tide (Lyrics)", "Lyric Corner", 241, 20_000_000),
            result("Low Tide - Glass Harbor cover", "Someone Else", 238, 50_000),
            result("Glass Harbor - Low Tide (Official Video)", "GlassHarborVEVO", 250, 5_000_000, True),
        ]
        self.assertEqual(self.best("Glass Harbor", "Low Tide", 242, items), "Glass Harbor - Low Tide (Official Video)")

    def test_a_word_in_the_song_title_is_not_a_penalty(self):
        live_song = result("The Lanterns - Live Forever (Official Video)", "The Lanterns")
        other = result("The Lanterns - Live Forever (Live)", "The Lanterns")
        self.assertGreater(video.score(live_song, "The Lanterns", "Live Forever", 240),
                           video.score(other, "The Lanterns", "Live Forever", 240))

    def test_another_song_by_the_artist_does_not_count(self):
        wrong = result("Mira Vale - Paper Moons (Official Video)", "Mira Vale")
        self.assertLess(video.score(wrong, "Mira Vale", "Silver Lines", 200), 15)

    def test_versions_share_a_key(self):
        self.assertEqual(video.song_key("Pale Orchid", "Night Bus (2019 Remaster)"),
                         video.song_key("pale orchid", "Night Bus - Remastered"))
        self.assertNotEqual(video.song_key("Pale Orchid", "Night Bus"), video.song_key("Pale Orchid", "Day Bus"))

    def test_scripts_are_kept(self):
        self.assertEqual(video.norm("ガラスの港"), "ガラスの港")


class Guessing(unittest.TestCase):
    """The artist and song a video is of, for Add to Library."""

    def test_artist_dash_song(self):
        self.assertEqual(video.guess_song(result("Glass Harbor - Low Tide (Official Music Video) [4K]", "x")),
                         ("Glass Harbor", "Low Tide"))

    def test_topic_channel(self):
        self.assertEqual(video.guess_song(result("Low Tide", "Glass Harbor - Topic")), ("Glass Harbor", "Low Tide"))

    def test_vevo_channel(self):
        self.assertEqual(video.guess_song(result("Low Tide (Official Video)", "GlassHarborVEVO")),
                         ("GlassHarbor", "Low Tide"))


def ytm(video_id, title, artist, kind="MUSIC_VIDEO_TYPE_OMV", seconds=240):
    return {"videoId": video_id, "title": title, "videoType": kind, "duration_seconds": seconds,
            "artists": [{"name": artist}]}


class OfficialPick(unittest.TestCase):
    """YouTube Music's own official video, out of its video search."""

    def test_the_artists_official_video_wins_over_uploads(self):
        results = [ytm("AAAAAAAAAAA", "Glass Harbor - Low Tide (Lyrics)", "Lyric Corner", "MUSIC_VIDEO_TYPE_UGC"),
                   ytm("BBBBBBBBBBB", "Paper Moons", "Glass Harbor"),
                   ytm("CCCCCCCCCCC", "Low Tide", "Glass Harbor", seconds=331)]
        pick = video.official_pick(results, "Glass Harbor", "Low Tide", 242)
        self.assertEqual(pick["id"], "CCCCCCCCCCC")          # its full length, intro and all
        self.assertEqual(pick["duration"], 331.0)

    def test_another_artists_official_video_is_not_it(self):
        results = [ytm("AAAAAAAAAAA", "Low Tide (Official Video)", "Someone Else")]
        self.assertIsNone(video.official_pick(results, "Glass Harbor", "Low Tide", 242))

    def test_no_official_video_is_none(self):
        results = [ytm("AAAAAAAAAAA", "Low Tide", "Glass Harbor", "MUSIC_VIDEO_TYPE_UGC")]
        self.assertIsNone(video.official_pick(results, "Glass Harbor", "Low Tide", 242))

    def test_a_title_in_another_script_by_the_artist(self):
        results = [ytm("AAAAAAAAAAA", "ガラスの港", "Glass Harbor", seconds=250)]
        self.assertEqual(video.official_pick(results, "Glass Harbor", "Garasu no Minato", 242)["id"], "AAAAAAAAAAA")
        # Not one far shorter than the song: that is something else.
        short = [ytm("AAAAAAAAAAA", "ガラスの港", "Glass Harbor", seconds=90)]
        self.assertIsNone(video.official_pick(short, "Glass Harbor", "Garasu no Minato", 242))

    def test_a_featured_artist_still_finds_the_main_one(self):
        results = [ytm("AAAAAAAAAAA", "Low Tide", "Glass Harbor")]
        self.assertEqual(video.official_pick(results, "Glass Harbor feat. Mira Vale", "Low Tide", 242)["id"],
                         "AAAAAAAAAAA")


HLS_MASTER = """#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:URI="https://manifest.example/hls_playlist/id/x/itag/233/source/yt/file/index.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="Default",DEFAULT=YES,AUTOSELECT=YES
#EXT-X-MEDIA:URI="https://manifest.example/hls_playlist/id/x/itag/234/source/yt/file/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES,AUTOSELECT=YES
#EXT-X-STREAM-INF:BANDWIDTH=309585,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,FRAME-RATE=25,VIDEO-RANGE=SDR,YT-EXT-ABSOLUTE-LOUDNESS=-17.250,AUDIO="233",CLOSED-CAPTIONS=NONE
https://manifest.example/hls_playlist/id/x/itag/229/source/yt/file/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=394219,CODECS="avc1.4D4015,mp4a.40.2",RESOLUTION=426x240,FRAME-RATE=25,AUDIO="234"
https://manifest.example/hls_playlist/id/x/itag/229/source/yt/sgoap/a/file/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1773415,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=25,AUDIO="234"
https://manifest.example/hls_playlist/id/x/itag/232/source/yt/file/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4515084,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=25,AUDIO="234"
https://manifest.example/hls_playlist/id/x/itag/270/source/yt/file/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4757620,CODECS="vp09.00.40.08,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=25,AUDIO="234"
https://manifest.example/hls_playlist/id/x/itag/616/source/yt/file/index.m3u8
"""


class YouTubesHls(unittest.TestCase):
    """YouTube's own HLS, cut down and pointed at the relay."""

    def test_master_keeps_h264_with_the_better_aac_720p_first(self):
        built = video.hls_master(HLS_MASTER, "?token=t")
        lines = built.playlist.splitlines()
        self.assertIn('URI="h234.m3u8?token=t"', built.playlist)
        self.assertNotIn("vp09", built.playlist)
        self.assertNotIn("mp4a.40.5", built.playlist)
        self.assertNotIn("YT-EXT", built.playlist)
        self.assertEqual([line for line in lines if not line.startswith("#")],
                         ["h232.m3u8?token=t", "h270.m3u8?token=t", "h229.m3u8?token=t"])
        self.assertEqual((built.tallest, built.width, built.height, built.audio), ("270", 1920, 1080, "234"))
        self.assertTrue(built.media["270"].startswith("https://manifest.example/"))

    def test_no_h264_is_none(self):
        only_vp9 = "\n".join(line for line in HLS_MASTER.splitlines() if "avc1" not in line)
        self.assertIsNone(video.hls_master(only_vp9))

    def test_media_playlist_points_every_segment_here(self):
        upstream = ("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:7\n"
                    "#EXTINF:6.44,\nhttps://rr1.example/videoplayback/id/x/itag/270/sq/0/file/seg.ts\n"
                    "#EXTINF:6.08,\nhttps://rr1.example/videoplayback/id/x/itag/270/sq/1/file/seg.ts\n#EXT-X-ENDLIST\n")
        text, segments = video.hls_media(upstream, "https://manifest.example/index.m3u8", "270", "?token=t")
        self.assertEqual([line for line in text.splitlines() if not line.startswith("#")],
                         ["h270/0.ts?token=t", "h270/1.ts?token=t"])
        self.assertIn("#EXTINF:6.44,", text)
        self.assertTrue(text.rstrip().endswith("#EXT-X-ENDLIST"))
        self.assertEqual(segments[1], "https://rr1.example/videoplayback/id/x/itag/270/sq/1/file/seg.ts")


def fragmented_mp4(segments, timescale=1000, moov=b"\0" * 40):
    """ftyp, moov and a version-0 sidx, then the fragments' bytes."""
    ftyp = struct.pack(">I4s", 16, b"ftyp") + b"dash\0\0\0\0"
    moov_box = struct.pack(">I4s", 8 + len(moov), b"moov") + moov
    body = struct.pack(">BxxxII", 0, 1, timescale) + struct.pack(">II", 0, 0) + struct.pack(">HH", 0, len(segments))
    for size, duration in segments:
        body += struct.pack(">III", size, duration, 0x90000000)
    sidx = struct.pack(">I4s", 8 + len(body), b"sidx") + body
    return ftyp + moov_box + sidx, len(ftyp) + len(moov_box)


class Index(unittest.TestCase):
    """HLS playlists out of a fragmented MP4's own index."""

    def test_reads_every_fragment(self):
        data, header = fragmented_mp4([(1000, 5000), (2000, 4000), (1500, 6000)])
        index = video.parse_index(data + b"\0" * 64)
        self.assertEqual(index.init_end, header)
        self.assertEqual([(size, seconds) for _, size, seconds in index.segments], [(1000, 5.0), (2000, 4.0), (1500, 6.0)])
        self.assertEqual(index.segments[0][0], len(data))           # straight after the index
        self.assertEqual(index.segments[1][0], len(data) + 1000)
        self.assertAlmostEqual(index.duration, 15.0)

    def test_not_enough_bytes_yet(self):
        data, _ = fragmented_mp4([(1000, 5000)] * 50)
        self.assertIsNone(video.parse_index(data[:-20]))

    def test_media_playlist_is_byte_ranges_of_one_file(self):
        data, header = fragmented_mp4([(1000, 5000), (2000, 7500)])
        text = video.media_playlist(video.parse_index(data), "137.mp4")
        self.assertIn(f'#EXT-X-MAP:URI="137.mp4",BYTERANGE="{header}@0"', text)
        self.assertIn("#EXT-X-TARGETDURATION:8", text)
        self.assertIn(f"#EXT-X-BYTERANGE:2000@{len(data) + 1000}", text)
        self.assertTrue(text.rstrip().endswith("#EXT-X-ENDLIST"))

    def test_master_names_codecs_and_audio(self):
        text = video.master_playlist(
            [{"itag": "137", "codec": "avc1.640028", "width": 1920, "height": 1080, "fps": 24, "peak": 2e6, "average": 1e6}],
            {"itag": "140", "codec": "mp4a.40.2", "peak": 1.3e5, "average": 1.2e5}, "?token=t")
        self.assertIn('URI="140.m3u8?token=t"', text)
        self.assertIn('CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080', text)
        self.assertIn("BANDWIDTH=2130000,", text)
        self.assertIn("137.m3u8?token=t", text)


class Choosing(unittest.TestCase):
    """A pick made by hand, over HTTP."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        videos = video.Videos.__new__(video.Videos)        # no yt-dlp, no threads
        videos.picks = video.Picks(Path(folder.name) / "videos.db")
        videos.auto_pick = lambda artist, title, duration: None
        service = SimpleNamespace(config=SimpleNamespace(token="", data_dir=Path(folder.name)), videos=videos)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.base = f"http://127.0.0.1:{server.server_address[1]}"

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method,
                                         headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.loads(error.read())

    def test_hand_pick_is_kept_then_reset(self):
        status, body = self.call("GET", "/v1/video/match?artist=Glass%20Harbor&title=Low%20Tide")
        self.assertEqual((status, body["video"]), (200, None))
        chosen = {"id": "AAAAAAAAAAA", "title": "Low Tide", "channel": "Glass Harbor", "duration": 241}
        status, body = self.call("PUT", "/v1/video/match", {"artist": "Glass Harbor", "title": "Low Tide", "video": chosen})
        self.assertEqual(status, 200)
        self.assertTrue(body["manual"])
        # The other library's copy, titled as a remaster, gets the same video.
        status, body = self.call("GET", "/v1/video/match?artist=glass%20harbor&title=Low%20Tide%20(Remastered)")
        self.assertEqual(body["video"]["id"], "AAAAAAAAAAA")
        self.call("DELETE", "/v1/video/match?artist=Glass%20Harbor&title=Low%20Tide")
        status, body = self.call("GET", "/v1/video/match?artist=Glass%20Harbor&title=Low%20Tide")
        self.assertIsNone(body["video"])

    def test_rejects_what_is_not_a_video_id(self):
        status, _ = self.call("PUT", "/v1/video/match",
                              {"artist": "A", "title": "B", "video": {"id": "../../etc", "title": "", "channel": ""}})
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
