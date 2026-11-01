"""FRA-609: nome de lane no lanes_ctl. `../../x` não apaga arquivo; heartbeat forjado não habilita."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
import lanes_ctl as c


class LanesCtlSeguro(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.antes = (c.D, c.ENABLED, c.HEARTBEAT, c.USER_OFF)
        c.D = self.tmp
        c.ENABLED = self.tmp / "enabled"
        c.HEARTBEAT = self.tmp / "heartbeat.json"
        c.USER_OFF = self.tmp / "disabled-by-user"
        c.HEARTBEAT.write_text(json.dumps({"implemented": ["claude", "grok", "codex"]}))
        self.addCleanup(lambda: (
            setattr(c, "D", self.antes[0]), setattr(c, "ENABLED", self.antes[1]),
            setattr(c, "HEARTBEAT", self.antes[2]), setattr(c, "USER_OFF", self.antes[3])))

    def test_traversal_nao_apaga_arquivo_fora_da_pasta(self):
        pasta = self.tmp / "raiz" / "a" / "b"
        c.USER_OFF = pasta / "disabled-by-user"
        c.USER_OFF.mkdir(parents=True)
        vitima = self.tmp / "raiz" / "a" / "x"
        vitima.write_text("fica")
        self.assertEqual((c.USER_OFF / "../../x").resolve(), vitima.resolve())
        c.HEARTBEAT.write_text(json.dumps({"implemented": ["../../x", "claude"]}))
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "../../x"]), 1)
        self.assertEqual(vitima.read_text(), "fica")
        self.assertFalse(c.ENABLED.exists())
        self.assertFalse(list(c.USER_OFF.iterdir()))

    def test_disable_de_nome_invalido_nao_muda_enabled(self):
        c.ENABLED.write_text("claude grok\n")
        antes = c.ENABLED.read_text()
        self.assertEqual(c.main(["lanes_ctl.py", "disable", "../../x"]), 1)
        self.assertEqual(c.ENABLED.read_text(), antes)
        self.assertEqual(c.main(["lanes_ctl.py", "disable", "naolane"]), 1)
        self.assertEqual(c.ENABLED.read_text(), antes)

    def test_heartbeat_forjado_nao_abre_nome_de_fora(self):
        c.HEARTBEAT.write_text(json.dumps({"implemented": ["../../x", "naolane", "claude"]}))
        c.USER_OFF.mkdir()
        (c.USER_OFF / "claude").write_text("")
        (c.USER_OFF / "grok").write_text("")
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "../../x"]), 1)
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "naolane"]), 1)
        self.assertFalse(c.ENABLED.exists())
        self.assertTrue((c.USER_OFF / "claude").is_file())
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "claude"]), 0)
        self.assertEqual(set(c.ENABLED.read_text().split()), {"claude"})
        self.assertEqual(sorted(p.name for p in c.USER_OFF.iterdir()), ["grok"])
