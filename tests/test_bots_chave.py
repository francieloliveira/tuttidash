"""bots-chave: modo automático pela %, modos forçados, ficheiro gestor (que vence
tudo exceto PAUSE.manual) e PAUSE.manual (que vence tudo)."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
CHAVE = RAIZ / "tools" / "bots-chave"


class BotsChaveTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        (self.home / ".transcentia/tools").mkdir(parents=True)
        shutil.copy(RAIZ / "tools" / "cfg", self.home / ".transcentia/tools/cfg")
        self.bots = self.home / ".transcentia/bots"
        self.bots.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def rodar(self, pct, forcado=None, limite=90):
        cfg = {"version": 1, "bots_chave": {"limite_pct": limite}}
        if forcado is not None:
            cfg["bots_chave"]["modo_forcado"] = forcado
        arq = self.home / "Library/Application Support/Lanekeeper/config.json"
        arq.parent.mkdir(parents=True, exist_ok=True)
        arq.write_text(json.dumps(cfg))
        env = {k: v for k, v in os.environ.items() if k != "TRANSCENTIA_GASTO_CONFIG"}
        env.update(HOME=str(self.home), BOTS_CHAVE_PCT=str(pct))
        # A chave só roda com o app aberto; o teste simula o app com o PID vivo.
        (self.home / ".transcentia/lanes").mkdir(parents=True, exist_ok=True)
        (self.home / ".transcentia/lanes/app.pid").write_text(f"{os.getpid()} teste\n")
        subprocess.run([str(CHAVE)], env=env, check=True)
        return json.loads((self.bots / "modo.json").read_text())

    @property
    def pause(self):
        return (self.bots / "PAUSE").exists()

    def escrever_gestor(self, valor):
        (self.bots / "gestor").write_text(valor + "\n")

    def test_gestor_opencode_vence_porcentagem_baixa(self):
        self.escrever_gestor("opencode")
        m = self.rodar(10, "auto")
        self.assertEqual(m["modo"], "opencode")
        self.assertEqual(m["gestor"], "opencode")
        self.assertTrue(self.pause)

    def test_gestor_vigia_vence_forcado_grokbot(self):
        (self.bots / "PAUSE").touch()
        self.escrever_gestor("vigia")
        m = self.rodar(10, "grokbot")
        self.assertEqual(m["modo"], "vigia")
        self.assertFalse(self.pause)

    def test_gestor_grokbot_vence_porcentagem_alta(self):
        self.escrever_gestor("grokbot")
        m = self.rodar(95, "auto")
        self.assertEqual(m["modo"], "grokbot")
        self.assertTrue(self.pause)

    def test_gestor_humano_com_nome_mantem_pause(self):
        self.escrever_gestor("humano:dono")
        m = self.rodar(10, "auto")
        self.assertEqual(m["modo"], "humano:dono")
        self.assertTrue(self.pause)

    def test_gestor_desconhecido_cai_no_auto(self):
        self.escrever_gestor("xyz")
        self.assertEqual(self.rodar(50, "auto")["modo"], "grokbot")
        self.assertTrue(self.pause)

    def test_gestor_vazio_cai_no_auto(self):
        (self.bots / "gestor").write_text("\n")
        self.assertEqual(self.rodar(50, "auto")["modo"], "grokbot")

    def test_pause_manual_vence_gestor(self):
        (self.bots / "PAUSE.manual").touch()
        self.escrever_gestor("opencode")
        self.assertEqual(self.rodar(10, "auto")["modo"], "manual")
        self.assertFalse(self.pause)

    def test_auto_pela_porcentagem(self):
        self.assertEqual(self.rodar(50, "auto")["modo"], "grokbot"); self.assertTrue(self.pause)
        self.assertEqual(self.rodar(95, "auto")["modo"], "vigia"); self.assertFalse(self.pause)
        self.assertEqual(self.rodar(50)["modo"], "grokbot")  # sem chave = auto

    def test_forcado_vigia_ignora_porcentagem(self):
        (self.bots / "PAUSE").touch()
        m = self.rodar(10, "vigia")
        self.assertEqual(m["modo"], "vigia"); self.assertEqual(m["modo_forcado"], "vigia")
        self.assertFalse(self.pause)
        self.rodar(10, "vigia"); self.assertFalse(self.pause)

    def test_forcado_grokbot_ignora_porcentagem(self):
        m = self.rodar(99, "grokbot")
        self.assertEqual(m["modo"], "grokbot"); self.assertTrue(self.pause)
        self.rodar("falha", "grokbot"); self.assertTrue(self.pause)

    def test_valor_desconhecido_vira_auto(self):
        self.assertEqual(self.rodar(95, "xyz")["modo"], "vigia")

    def test_pause_manual_vence_tudo(self):
        (self.bots / "PAUSE.manual").touch()
        for f in ("vigia", "grokbot", "auto"):
            self.assertEqual(self.rodar(10, f)["modo"], "manual")
            self.assertFalse(self.pause)


if __name__ == "__main__":
    unittest.main()
