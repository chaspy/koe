"""paste_bench helpers on synthetic data and a local fake server only."""

from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
import wave

import paste_bench as b


def clip(path, seconds, rate=16000):
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(b'\0\0' * int(seconds * rate))
    return path


class Handler(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        Handler.seen.append((self.path, body))
        self.send_response(200)
        self.end_headers()
        self.wfile.write('本文'.encode())

    def log_message(self, *args):
        pass


class Test(unittest.TestCase):
    def test_trim_cuts_to_target_length(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = b.trim(clip(Path(tmp) / 'a.wav', 5), 3)
            with wave.open(str(wav), 'rb') as audio:
                self.assertEqual(audio.getnframes(), 3 * 16000)

    def test_trim_keeps_shorter_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = b.trim(clip(Path(tmp) / 'a.wav', 2), 3)
            with wave.open(str(wav), 'rb') as audio:
                self.assertEqual(audio.getnframes(), 2 * 16000)

    def test_request_sends_koe_fields_and_returns_time_only(self):
        server = HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                ms = b.request(f'http://127.0.0.1:{server.server_port}', clip(Path(tmp) / 'a.wav', 1))
            self.assertIsInstance(ms, float)
            path, body = Handler.seen[-1]
            self.assertEqual(path, '/inference')
            self.assertIn(b'name="audio_ctx"\r\n\r\n0\r\n', body)
            self.assertIn(b'name="temperature"\r\n\r\n0.0\r\n', body)
        finally:
            server.shutdown()


if __name__ == '__main__':
    unittest.main()
