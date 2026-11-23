"""Modo headless: sem app, o proxy vivo autoriza dispatcher/vigia."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bots"))
import dispatcher as d  # noqa: E402
import watch as w  # noqa: E402


class Headless(unittest.TestCase):
    def test_dispatcher_usa_proxy_quando_headless(self):
        def cfg(chave, padrao):
            return True if chave == "agenda.headless" else padrao
        with mock.patch.object(d, "_cfg", cfg), mock.patch.object(d, "proxy_vivo", return_value=True):
            self.assertTrue(d.app_aberta())
        with mock.patch.object(d, "_cfg", cfg), mock.patch.object(d, "proxy_vivo", return_value=False), \
             mock.patch.object(d, "APP_PID", Path(tempfile.mkdtemp()) / "nao-existe.pid"):
            self.assertFalse(d.app_aberta())

    def test_vigia_usa_proxy_quando_headless(self):
        def cfg(chave, padrao):
            return True if chave == "agenda.headless" else padrao
        with mock.patch.object(w, "_cfg", cfg), mock.patch.object(w, "proxy_vivo", return_value=True):
            self.assertTrue(w.app_aberta())
        with mock.patch.object(w, "_cfg", cfg), mock.patch.object(w, "proxy_vivo", return_value=False), \
             mock.patch.object(w, "APP_PID", Path(tempfile.mkdtemp()) / "nao-existe.pid"):
            self.assertFalse(w.app_aberta())


if __name__ == "__main__":
    unittest.main()
