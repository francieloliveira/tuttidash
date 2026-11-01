"""FRA-591: instalação limpa não cria ~/.transcentia/lanes e não copia runner, view nem settings."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
NAO_COPIAR = (
    "run_lane.sh",
    "lane_view.py",
    "claude-settings.json",
    "lane-mcp.json",
)


class InstalacaoLanesTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name) / "home"
        self.home.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def instalar(self, *args, home=None):
        env = os.environ.copy()
        env["HOME"] = str(home or self.home)
        env.pop("TRANSCENTIA_GASTO_CONFIG", None)
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return subprocess.run(
            ["bash", str(RAIZ / "tools" / "install.sh"), "--sem-launchd", *args],
            cwd=str(RAIZ),
            env=env,
            capture_output=True,
            text=True,
        )

    def assertOk(self, resultado):
        self.assertEqual(resultado.returncode, 0, resultado.stdout + "\n" + resultado.stderr)

    def test_instalacao_limpa_nao_cria_lanes_nem_copia_runner_view_settings(self):
        lanes = self.home / ".transcentia" / "lanes"
        self.assertFalse(lanes.exists())
        self.assertOk(self.instalar())
        self.assertFalse(lanes.exists())
        self.assertFalse(lanes.is_dir())
        raiz_estado = self.home / ".transcentia"
        for nome in NAO_COPIAR:
            self.assertEqual(list(raiz_estado.rglob(nome)), [], nome)
        self.assertTrue((self.home / ".transcentia" / "tools" / "cfg").is_file())

    def test_pasta_existente_nao_copia_runner_view_nem_settings(self):
        lanes = self.home / ".transcentia" / "lanes"
        lanes.mkdir(parents=True)
        (lanes / "run_lane.sh").write_text("RUNNER-LOCAL\n", encoding="utf-8")
        (lanes / "lane_view.py").write_text("VIEW-LOCAL\n", encoding="utf-8")
        (lanes / "claude-settings.json").write_text('{"local": true}\n', encoding="utf-8")
        (lanes / "lane-mcp.json").write_text('{"mcpServers": {"local": {}}}\n', encoding="utf-8")
        self.assertOk(self.instalar())
        self.assertEqual((lanes / "run_lane.sh").read_text(encoding="utf-8"), "RUNNER-LOCAL\n")
        self.assertEqual((lanes / "lane_view.py").read_text(encoding="utf-8"), "VIEW-LOCAL\n")
        self.assertEqual((lanes / "claude-settings.json").read_text(encoding="utf-8"), '{"local": true}\n')
        self.assertEqual((lanes / "lane-mcp.json").read_text(encoding="utf-8"), '{"mcpServers": {"local": {}}}\n')
        self.assertFalse((lanes / "run_lane.sh.bak").exists())
        self.assertFalse((lanes / "lane_view.py.bak").exists())
        self.assertFalse((lanes / "claude-settings.json.bak").exists())
        self.assertFalse((lanes / "lane-mcp.json.bak").exists())
        # FRA-613: o dispatcher roda do bundle assinado; o install não o copia.
        self.assertFalse((lanes / "dispatcher.py").exists())
        # FRA-615: os módulos ficam no bundle; a pasta gravável não os recebe.
        self.assertFalse((lanes / "config.py").exists())

    def test_pasta_existente_vazia_nao_ganha_runner_view_nem_settings(self):
        lanes = self.home / ".transcentia" / "lanes"
        lanes.mkdir(parents=True)
        self.assertOk(self.instalar())
        for nome in NAO_COPIAR:
            self.assertFalse((lanes / nome).exists(), nome)
        self.assertFalse((lanes / "dispatcher.py").exists())
        self.assertFalse((lanes / "config.py").exists())
