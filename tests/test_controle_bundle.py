"""FRA-614: settings, MCP e o CLI da próxima lane não seguem a cópia em ~/.transcentia.

O fixture de teste (`tests/fixtures/estado`) não entra no lugar do template de produção.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

RAIZ = Path(__file__).resolve().parents[1]
os.environ.pop("TUTTIDASH_RECURSOS", None)
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
sys.path.insert(0, str(RAIZ / "lanes"))

import catalogo  # noqa: E402
import dispatcher as d  # noqa: E402


def _manifesto(nome, cli, flags):
    return json.dumps({
        "schema": 1, "nome": nome, "rotulo": nome, "cli": cli,
        "ordem": 1, "prioridade": 1, "painel": True, "execucao": "implementada",
        "modelos": {
            "baixo": {"id": "b", "flags": []},
            "medio": {"id": flags[-1] if flags else "", "flags": flags},
            "alto": {"id": "a", "flags": []},
        },
    })


class ControleDoBundle(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.env = os.environ.get("TUTTIDASH_RECURSOS")
        self.state = d.STATE_DIR
        self.instalado = catalogo.DIR_INSTALADO
        self.cfg = list(d.CONFIG_FILES)
        self.addCleanup(self._restaurar)
        d.CONFIG_FILES = [self.tmp / "config-ausente.json"]
        catalogo._resetar_cache()

    def _restaurar(self):
        d.STATE_DIR = self.state
        d.CONFIG_FILES = self.cfg
        catalogo.DIR_INSTALADO = self.instalado
        if self.env is None:
            os.environ.pop("TUTTIDASH_RECURSOS", None)
        else:
            os.environ["TUTTIDASH_RECURSOS"] = self.env
        catalogo._resetar_cache()

    def test_template_de_producao_nao_e_o_fixture(self):
        prod = json.loads((RAIZ / "apps/notch-mac/Resources/claude-settings.json").read_text(encoding="utf-8"))
        fix = json.loads((RAIZ / "tests/fixtures/estado/claude-settings.json").read_text(encoding="utf-8"))
        self.assertNotEqual(prod["permissions"]["allow"], fix["permissions"]["allow"])
        self.assertIn("Edit", prod["permissions"]["allow"])
        self.assertIn("Bash(git commit:*)", prod["permissions"]["allow"])
        self.assertIn("Bash(git push:*)", prod["permissions"]["deny"])
        mcp = json.loads((RAIZ / "apps/notch-mac/Resources/lane-mcp.json").read_text(encoding="utf-8"))
        fixture_mcp = json.loads((RAIZ / "tests/fixtures/estado/lane-mcp.json").read_text(encoding="utf-8"))
        self.assertNotEqual(mcp, fixture_mcp)
        self.assertIn("mcpServers", mcp)

    def test_build_grava_template_0600_sem_fixture(self):
        texto = (RAIZ / "apps/notch-mac/build.sh").read_text(encoding="utf-8")
        self.assertIn('install -m 600 "$HERE/Resources/claude-settings.json"', texto)
        self.assertIn('install -m 600 "$HERE/Resources/lane-mcp.json"', texto)
        self.assertIn('install -m 600 "$AGENTS_D"/*.json', texto)
        self.assertNotIn("fixtures/estado", texto)

    def test_sem_fonte_nao_usa_o_fixture(self):
        d.STATE_DIR = RAIZ / "tests" / "fixtures" / "estado"
        with mock.patch.object(d, "_template_producao", return_value=None), \
                mock.patch.object(catalogo, "recursos_do_bundle", return_value=None):
            with self.assertRaises(FileNotFoundError):
                d.caminho_controle("claude-settings.json")

    def test_env_em_transcentia_nao_vale(self):
        antigo = self.tmp / "home" / ".transcentia" / "lanes"
        antigo.mkdir(parents=True)
        (antigo / "claude-settings.json").write_text(
            '{"permissions":{"allow":["Bash(git push:*)"],"deny":[]}}', encoding="utf-8")
        os.environ["TUTTIDASH_RECURSOS"] = str(antigo)
        self.assertIsNone(catalogo.recursos_do_bundle())
        caminho = d.caminho_controle("claude-settings.json")
        self.assertTrue(str(caminho).endswith("apps/notch-mac/Resources/claude-settings.json"))
        self.assertNotIn(".transcentia", caminho.parts)
        self.assertNotIn("fixtures", caminho.parts)

    def test_copia_antiga_nao_muda_settings_nem_cli(self):
        antigo_lanes = self.tmp / "home" / ".transcentia" / "lanes"
        antigo_agents = self.tmp / "home" / ".transcentia" / "agents.d"
        antigo_lanes.mkdir(parents=True)
        antigo_agents.mkdir(parents=True)
        (antigo_lanes / "claude-settings.json").write_text(json.dumps({
            "permissions": {"allow": ["Bash(git push:*)"], "deny": ["Read"]},
        }), encoding="utf-8")
        (antigo_lanes / "lane-mcp.json").write_text(json.dumps({
            "mcpServers": {"evil": {"command": "evil"}},
        }), encoding="utf-8")
        (antigo_agents / "claude.json").write_text(
            _manifesto("claude", "evil", ["--model", "evil"]), encoding="utf-8")

        bundle = self.tmp / "TuttiDash.app" / "Contents" / "Resources"
        (bundle / "agents.d").mkdir(parents=True)
        (bundle / "claude-settings.json").write_text(json.dumps({
            "permissions": {"allow": ["SoBundle"], "deny": ["SoBundleDeny"]},
        }), encoding="utf-8")
        (bundle / "lane-mcp.json").write_text(json.dumps({
            "mcpServers": {"docs": {"command": "bundle-mcp"}},
        }), encoding="utf-8")
        (bundle / "agents.d" / "claude.json").write_text(
            _manifesto("claude", "claude", ["--model", "bundle-model"]), encoding="utf-8")

        d.STATE_DIR = antigo_lanes
        catalogo.DIR_INSTALADO = antigo_agents
        os.environ["TUTTIDASH_RECURSOS"] = str(bundle)
        catalogo._resetar_cache()

        for pasta in catalogo._diretorios():
            self.assertNotIn(".transcentia", Path(pasta).parts)
        dados = catalogo.catalogo()["claude"]
        self.assertEqual(dados["cli"], "claude")
        self.assertEqual(list(dados["modelos"]["medio"]["flags"]), ["--model", "bundle-model"])

        settings = d.caminho_controle("claude-settings.json")
        mcp = d.caminho_controle("lane-mcp.json")
        self.assertEqual(settings, (bundle / "claude-settings.json").resolve())
        self.assertEqual(mcp, (bundle / "lane-mcp.json").resolve())

        cmd = d.agent_command("claude", "medio")
        self.assertIn(str(settings), cmd)
        self.assertIn(str(mcp), cmd)
        self.assertIn("bundle-model", cmd)
        # O CLI recebe o caminho do JSON; o comando do servidor está dentro do arquivo.
        lido = json.loads(mcp.read_text(encoding="utf-8"))
        self.assertEqual(lido["mcpServers"]["docs"]["command"], "bundle-mcp")
        self.assertNotIn("evil", cmd)
        self.assertNotIn(str(antigo_lanes / "claude-settings.json"), cmd)
        self.assertNotIn(str(antigo_lanes / "lane-mcp.json"), cmd)

        grok = d.agent_command("grok", "medio")
        self.assertEqual(grok[grok.index("--allow") + 1], "SoBundle")
        self.assertEqual(grok[grok.index("--deny") + 1], "SoBundleDeny")
        self.assertNotIn("Bash(git push:*)", grok)


if __name__ == "__main__":
    unittest.main()
