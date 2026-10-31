"""FRA-591: instalação limpa cria ~/.transcentia/lanes e não cobre customização."""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
INSTALADOR = RAIZ / "tools" / "install.sh"
PECAS = (
    "dispatcher.py",
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

    def instalar(self, *args, raiz=None, home=None):
        env = os.environ.copy()
        env["HOME"] = str(home or self.home)
        env.pop("TRANSCENTIA_GASTO_CONFIG", None)
        # O teste prova as lanes. O build do lanepct fica para uma instalação real,
        # quando o swift está no PATH.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return subprocess.run(
            ["bash", str((raiz or RAIZ) / "tools" / "install.sh"), "--sem-launchd", *args],
            cwd=str(raiz or RAIZ),
            env=env,
            capture_output=True,
            text=True,
        )

    def assertOk(self, resultado):
        self.assertEqual(resultado.returncode, 0, resultado.stdout + "\n" + resultado.stderr)

    @staticmethod
    def modo(caminho):
        return stat.S_IMODE(caminho.stat().st_mode)

    def test_instalacao_limpa_cria_dispatcher_runner_view_e_settings(self):
        lanes = self.home / ".transcentia" / "lanes"
        self.assertFalse(lanes.exists())
        self.assertOk(self.instalar())
        for nome in PECAS:
            self.assertTrue((lanes / nome).is_file(), nome)
        # LanesHabilitadas.dispatcherExiste é verdadeiro quando dispatcher.py existe.
        self.assertTrue((lanes / "dispatcher.py").is_file())
        self.assertEqual(self.modo(lanes / "run_lane.sh"), 0o755)
        self.assertEqual(self.modo(lanes / "lane_view.py"), 0o644)
        self.assertEqual(self.modo(lanes / "claude-settings.json"), 0o600)
        self.assertEqual(self.modo(lanes / "lane-mcp.json"), 0o600)
        self.assertEqual((lanes / "run_lane.sh").read_bytes(), (RAIZ / "lanes" / "run_lane.sh").read_bytes())
        self.assertEqual((lanes / "lane_view.py").read_bytes(), (RAIZ / "lanes" / "lane_view.py").read_bytes())
        self.assertEqual(
            (lanes / "claude-settings.json").read_bytes(),
            (RAIZ / "lanes" / "templates" / "claude-settings.json").read_bytes(),
        )
        ajustes = json.loads((lanes / "claude-settings.json").read_text(encoding="utf-8"))
        self.assertIn("Edit", ajustes["permissions"]["allow"])
        self.assertNotEqual(ajustes["permissions"]["allow"], ["Read"])
        mcp = json.loads((lanes / "lane-mcp.json").read_text(encoding="utf-8"))
        self.assertEqual(mcp["mcpServers"], {})
        self.assertNotIn("francieloliveira", (lanes / "lane-mcp.json").read_text(encoding="utf-8"))
        self.assertFalse((lanes / "enabled").exists())
        self.assertFalse((self.home / ".transcentia" / "bots" / "PAUSE").exists())
        segunda = self.instalar()
        self.assertOk(segunda)
        self.assertFalse((lanes / "run_lane.sh.bak").exists())
        self.assertFalse((lanes / "claude-settings.json.bak").exists())

    def test_backup_e_diff_antes_de_substituir_runner_e_view(self):
        self.assertOk(self.instalar())
        lanes = self.home / ".transcentia" / "lanes"
        (lanes / "run_lane.sh").write_text("RUNNER-LOCAL\n", encoding="utf-8")
        (lanes / "lane_view.py").write_text("VIEW-LOCAL\n", encoding="utf-8")
        r = self.instalar()
        self.assertOk(r)
        self.assertEqual((lanes / "run_lane.sh.bak").read_text(encoding="utf-8"), "RUNNER-LOCAL\n")
        self.assertEqual((lanes / "lane_view.py.bak").read_text(encoding="utf-8"), "VIEW-LOCAL\n")
        self.assertEqual((lanes / "run_lane.sh").read_bytes(), (RAIZ / "lanes" / "run_lane.sh").read_bytes())
        self.assertEqual((lanes / "lane_view.py").read_bytes(), (RAIZ / "lanes" / "lane_view.py").read_bytes())
        self.assertEqual(self.modo(lanes / "run_lane.sh"), 0o755)
        self.assertEqual(self.modo(lanes / "lane_view.py"), 0o644)
        self.assertIn("backup:", r.stdout)
        self.assertIn("RUNNER-LOCAL", r.stdout)
        self.assertIn("VIEW-LOCAL", r.stdout)

    def test_nao_sobrescreve_settings_sem_force(self):
        self.assertOk(self.instalar())
        lanes = self.home / ".transcentia" / "lanes"
        custom_ajustes = '{"permissions": {"allow": ["Read"], "deny": ["WebFetch"]}}\n'
        custom_mcp = '{"mcpServers": {"local": {"command": "/usr/bin/python3"}}}\n'
        (lanes / "claude-settings.json").write_text(custom_ajustes, encoding="utf-8")
        (lanes / "lane-mcp.json").write_text(custom_mcp, encoding="utf-8")
        r = self.instalar()
        self.assertOk(r)
        self.assertEqual((lanes / "claude-settings.json").read_text(encoding="utf-8"), custom_ajustes)
        self.assertEqual((lanes / "lane-mcp.json").read_text(encoding="utf-8"), custom_mcp)
        self.assertIn("mantido:", r.stdout)
        self.assertFalse((lanes / "claude-settings.json.bak").exists())
        com_force = self.instalar("--force")
        self.assertOk(com_force)
        self.assertEqual(
            (lanes / "claude-settings.json").read_bytes(),
            (RAIZ / "lanes" / "templates" / "claude-settings.json").read_bytes(),
        )
        self.assertEqual(
            (lanes / "lane-mcp.json").read_bytes(),
            (RAIZ / "lanes" / "templates" / "lane-mcp.json").read_bytes(),
        )
        self.assertEqual((lanes / "claude-settings.json.bak").read_text(encoding="utf-8"), custom_ajustes)
        self.assertEqual((lanes / "lane-mcp.json.bak").read_text(encoding="utf-8"), custom_mcp)
        self.assertEqual(self.modo(lanes / "claude-settings.json"), 0o600)
        self.assertEqual(self.modo(lanes / "lane-mcp.json"), 0o600)
        self.assertIn("backup:", com_force.stdout)

    def test_nao_mexe_em_enabled_nem_em_pause(self):
        self.assertOk(self.instalar())
        lanes = self.home / ".transcentia" / "lanes"
        (lanes / "enabled").write_text("grok\n", encoding="utf-8")
        pause = self.home / ".transcentia" / "bots" / "PAUSE"
        pause.write_text("parado\n", encoding="utf-8")
        self.assertOk(self.instalar())
        self.assertEqual((lanes / "enabled").read_text(encoding="utf-8"), "grok\n")
        self.assertEqual(pause.read_text(encoding="utf-8"), "parado\n")

    def test_falta_de_template_runner_ou_view_falha_com_mensagem(self):
        raiz = Path(self._tmp.name) / "repo"
        (raiz / "tools").mkdir(parents=True)
        (raiz / "lanes").mkdir()
        shutil.copy(INSTALADOR, raiz / "tools" / "install.sh")
        home = Path(self._tmp.name) / "home-vazio"
        home.mkdir()
        r = self.instalar(raiz=raiz, home=home)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ERRO", r.stderr)
        for nome in (
            "lanes/dispatcher.py",
            "lanes/run_lane.sh",
            "lanes/lane_view.py",
            "lanes/templates/claude-settings.json",
            "lanes/templates/lane-mcp.json",
        ):
            self.assertIn(nome, r.stderr)
        self.assertFalse((home / ".transcentia" / "lanes").exists())


if __name__ == "__main__":
    unittest.main()
