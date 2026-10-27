import io
import json
import os
import unittest
from unittest import mock

from gasto_lanes import config as C
from gasto_lanes.cli import main
from tests.helpers import Sandbox, snapshot


class CLI(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        cfg = self.sb.root / "config.json"
        cfg.write_text("{}", encoding="utf-8")
        # isola do ambiente real: nenhuma variável TRANSCENTIA_* e config vazia
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

    def test_coletar_duas_vezes(self):
        code, out, _ = self.run_cli("coletar")
        self.assertEqual(code, 0)
        self.assertIn("7 novas", out)
        code, out, _ = self.run_cli("coletar", "--json")
        data = json.loads(out)
        self.assertEqual((data["novas"], data["atualizadas"], data["gravou"]), (0, 0, False))

    def test_relatorio_json(self):
        code, out, _ = self.run_cli("relatorio", "--json", "--hoje", "2026-10-04")
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(set(data["por"]), {"dia", "semana", "card", "lane"})
        self.assertEqual(data["total"]["execucoes_custo_desconhecido"], 4)
        self.assertIsNone(data["teto"])
        self.assertEqual(data["estado"]["lanes"]["claude"]["card"], "FRA-253")

    def test_relatorio_texto_com_filtro(self):
        code, out, _ = self.run_cli("relatorio", "--por", "lane", "--lane", "grok")
        self.assertEqual(code, 0)
        self.assertIn("grok", out)
        self.assertNotIn("claude  ", out)

    def test_relatorio_dimensao_invalida(self):
        code, _, err = self.run_cli("relatorio", "--por", "mes")
        self.assertEqual(code, 2)
        self.assertIn("dimensão inválida", err)

    def test_teto_exit_codes(self):
        cases = (("10", 0), ("3", 3), ("2.5", 4))
        for teto, esperado in cases:
            code, out, _ = self.run_cli("teto", "--teto-semanal", teto, "--hoje", "2026-10-04")
            self.assertEqual(code, esperado, (teto, out))
        code, out, _ = self.run_cli("relatorio", "--teto-semanal", "2.5", "--hoje", "2026-10-04",
                                    "--desde", "2026-10-05")
        self.assertEqual(code, 4)   # teto olha a semana inteira, não o filtro
        self.assertIn("AVISO: teto semanal atingido", out)

    def test_teto_sem_configurar(self):
        code, _, err = self.run_cli("teto")
        self.assertEqual(code, 1)
        self.assertIn("não configurado", err)

    def test_teto_por_variavel_de_ambiente(self):
        with mock.patch.dict(os.environ, {C.ENV["teto_semanal_usd"]: "2.5"}):
            code, _, _ = self.run_cli("teto", "--hoje", "2026-10-04")
        self.assertEqual(code, 4)

    def test_execucoes(self):
        code, out, _ = self.run_cli("execucoes", "--limite", "2", "--json")
        self.assertEqual(code, 0)
        self.assertEqual([r["card"] for r in json.loads(out)], ["FRA-252", "FRA-253"])
        code, out, _ = self.run_cli("execucoes")
        self.assertIn("morta", out)
        self.assertIn("desconhecido", out)

    def test_sem_coletar_usa_so_o_ledger(self):
        code, out, _ = self.run_cli("relatorio", "--sem-coletar", "--json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["total"]["execucoes"], 0)
        self.assertFalse(self.sb.ledger.exists())

    def test_logs_inexistentes_avisa_e_segue(self):
        out, err = io.StringIO(), io.StringIO()
        code = main(["relatorio", "--logs", str(self.sb.root / "nada"), "--estado", str(self.sb.estado),
                     "--ledger", str(self.sb.ledger)], out=out, err=err)
        self.assertEqual(code, 0)
        self.assertIn("pasta de logs não encontrada", err.getvalue())

    def test_config_mostra_origem(self):
        code, out, _ = self.run_cli("config", "--json")
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["origem"]["logs_dir"], "flag")

    def test_nenhum_comando_altera_as_lanes(self):
        logs, estado = snapshot(self.sb.logs), snapshot(self.sb.estado)
        for argv in (("coletar",), ("relatorio",), ("execucoes",),
                     ("teto", "--teto-semanal", "0.01"), ("config",)):
            self.run_cli(*argv)
        self.assertEqual(snapshot(self.sb.logs), logs)
        self.assertEqual(snapshot(self.sb.estado), estado)
        self.assertFalse((self.sb.estado / "PAUSE").exists())

    def test_ledger_na_pasta_das_lanes_recusado(self):
        out, err = io.StringIO(), io.StringIO()
        code = main(["coletar", "--logs", str(self.sb.logs), "--estado", str(self.sb.estado),
                     "--ledger", str(self.sb.logs / "ledger.jsonl")], out=out, err=err)
        self.assertEqual(code, 1)
        self.assertFalse((self.sb.logs / "ledger.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
