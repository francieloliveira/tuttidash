"""Webhook de notificação, com servidor local."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from gasto_lanes import integracoes


class Servidor(BaseHTTPRequestHandler):
    corpo = b""

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        type(self).corpo = self.rfile.read(n)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


class Webhook(unittest.TestCase):
    def setUp(self):
        self.httpd = HTTPServer(("127.0.0.1", 0), Servidor)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}/hook"

    def test_envia_texto(self):
        r = integracoes.enviar(self.url, "oi")
        self.assertTrue(r["ok"])
        self.assertEqual(json.loads(Servidor.corpo), {"text": "oi"})

    def test_url_vazia_nao_envia(self):
        self.assertFalse(integracoes.enviar("", "oi")["ok"])

    def test_webhook_so_http(self):
        self.assertEqual(integracoes.webhook(lambda k, d: "ftp://x"), "")
        self.assertEqual(integracoes.webhook(lambda k, d: self.url), self.url)

    def test_erro_nao_vaza_webhook(self):
        r = integracoes.enviar("http://127.0.0.1:1/hook", "oi", timeout=1)
        self.assertFalse(r["ok"])
        self.assertNotIn("127.0.0.1:1", r["erro"])


if __name__ == "__main__":
    unittest.main()
