import io
import json
import os
import unittest
from unittest import mock

from gasto_lanes import config as C
from gasto_lanes import report as R
from gasto_lanes.cli import main
from gasto_lanes.estado import is_lane_state, read_state
from tests.helpers import ESTADO, Sandbox

ESTADO_OK = {"lane": "grok", "card": "FRA-300", "issue_id": "x", "title": "t", "url": "u", "branch": "b",
             "worktree": "/w", "effort": "baixo", "started": 1.0, "started_at": "2026-10-05 21:00:00",
             "log": "/Users/x/Library/Logs/TranscentIA/lanes/FRA-300-grok-20261005-210000.jsonl",
             "session": "lane-grok"}


class EstadoDasLanes(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()

    def tearDown(self):
        self.sb.cleanup()

    def write(self, name, data):
        text = data if isinstance(data, str) else json.dumps(data)
        (self.sb.estado / name).write_text(text, encoding="utf-8")

    def test_fixture_real_so_lane_claude_conta(self):
        # a fixture tem lane-mcp.json, lane-prompt*.md, claude-settings.json, enabled, last_mode
        st = read_state(ESTADO)
        self.assertEqual(sorted(st["lanes"]), ["claude"])
        self.assertEqual(st["logs_em_andamento"], {"FRA-253-claude-20261005-200000.jsonl"})

    def test_lane_mcp_json_ignorado(self):
        mcp = json.loads((ESTADO / "lane-mcp.json").read_text(encoding="utf-8"))
        self.assertIn("mcpServers", mcp)
        self.assertFalse(is_lane_state("lane-mcp.json", mcp))

    def test_forma_do_estado(self):
        self.assertTrue(is_lane_state("lane-grok.json", ESTADO_OK))
        self.assertFalse(is_lane_state("lane-claude.json", ESTADO_OK))           # lane != nome do arquivo
        self.assertFalse(is_lane_state("lane-grok.json", {**ESTADO_OK, "card": None}))
        self.assertFalse(is_lane_state("lane-grok.json", {**ESTADO_OK, "log": ""}))
        sem_lane = {k: v for k, v in ESTADO_OK.items() if k != "lane"}
        self.assertFalse(is_lane_state("lane-grok.json", sem_lane))
        self.assertFalse(is_lane_state("lane-grok.json", ["lista"]))
        self.assertFalse(is_lane_state("lane-Grok X.json", ESTADO_OK))

    def test_varios_invalidos_em_silencio(self):
        self.write("lane-grok.json", {**ESTADO_OK, "lane": "claude"})   # forma errada
        self.write("lane-quebrado.json", "{nao e json")
        self.write("lane-lista.json", "[1, 2]")
        st = read_state(self.sb.estado)
        self.assertEqual(sorted(st["lanes"]), ["claude"])

    def test_estado_grok_valido_entra(self):
        self.write("lane-grok.json", ESTADO_OK)
        st = read_state(self.sb.estado)
        self.assertEqual(sorted(st["lanes"]), ["claude", "grok"])
        self.assertIn("FRA-300-grok-20261005-210000.jsonl", st["logs_em_andamento"])

    def test_texto_nunca_imprime_none(self):
        sem_inicio = {k: v for k, v in ESTADO_OK.items() if k not in ("started_at",)}
        self.write("lane-grok.json", sem_inicio)
        self.write("heartbeat.json", {"at": "2026-10-05 21:30:00", "dry_run": False, "enabled": None})
        linhas = R.estado_txt(read_state(self.sb.estado))
        self.assertIn("lane:grok ocupada com FRA-300", linhas)
        self.assertTrue(all("None" not in ln for ln in linhas), linhas)
        # estado montado à mão com campos vazios também não vaza None
        linhas = R.estado_txt({"heartbeat": {"at": None}, "lanes": {"mcp": {"card": None},
                                                                     "x": {"card": "FRA-1", "started_at": None}}})
        self.assertEqual(linhas, ["lane:x ocupada com FRA-1"])


class RelatorioSemNone(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        cfg = self.sb.root / "config.json"
        cfg.write_text("{}", encoding="utf-8")
        env = {k: v for k, v in os.environ.items() if not k.startswith("TRANSCENTIA_")}
        env[C.ENV_CONFIG] = str(cfg)
        self._env = mock.patch.dict(os.environ, env, clear=True)
        self._env.start()

    def tearDown(self):
        self._env.stop()
        self.sb.cleanup()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        code = main(list(argv[:1]) + self.sb.args() + list(argv[1:]), out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def test_relatorio_com_lane_mcp_json(self):
        self.assertTrue((self.sb.estado / "lane-mcp.json").exists())
        for argv in (("relatorio",), ("relatorio", "--teto-semanal", "1", "--hoje", "2026-10-04"),
                     ("execucoes",), ("teto", "--teto-semanal", "1"), ("coletar",)):
            code, out, err = self.run_cli(*argv)
            self.assertNotIn("None", out, argv)
            self.assertNotIn("None", err, argv)
        code, out, _ = self.run_cli("relatorio")
        self.assertNotIn("lane:mcp", out)
        self.assertIn("lane:claude ocupada com FRA-253 desde 2026-10-05 20:00:00", out)
        code, out, _ = self.run_cli("relatorio", "--json")
        self.assertEqual(sorted(json.loads(out)["estado"]["lanes"]), ["claude"])


if __name__ == "__main__":
    unittest.main()
