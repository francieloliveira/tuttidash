import json
import os
import unittest

from gasto_lanes import ledger as L
from gasto_lanes.estado import read_state
from tests.helpers import ESTADO, LOGS, Sandbox, snapshot


class Ledger(unittest.TestCase):
    def setUp(self):
        self.sb = Sandbox()
        self.running = read_state(self.sb.estado)["logs_em_andamento"]

    def tearDown(self):
        self.sb.cleanup()

    def collect(self):
        return L.collect(self.sb.logs, self.sb.ledger, read_state(self.sb.estado)["logs_em_andamento"])

    def test_primeira_coleta(self):
        s = self.collect()
        self.assertEqual(s["novas"], 7)
        self.assertEqual(s["ignorados"], ["notas.jsonl"])
        self.assertTrue(s["gravou"])
        lines = self.sb.ledger.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 7)
        ids = [json.loads(x)["id"] for x in lines]
        self.assertEqual(ids[0], "FRA-248-claude-20260927-230000")   # ordenado por início

    def test_idempotente(self):
        self.collect()
        before = snapshot(self.sb.tools)
        # em andamento é sempre relido, mas se nada mudou o arquivo não é regravado
        s = self.collect()
        self.assertEqual(s["novas"] + s["atualizadas"], 0)
        self.assertFalse(s["gravou"])
        self.assertEqual(snapshot(self.sb.tools), before)

    def test_log_que_cresceu_e_relido(self):
        self.collect()
        f = self.sb.logs / "FRA-253-claude-20261005-200000.jsonl"
        st = f.stat()
        with f.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"type": "result", "subtype": "success", "is_error": False,
                                 "num_turns": 9, "duration_ms": 900_000, "total_cost_usd": 1.25,
                                 "usage": {"input_tokens": 1, "output_tokens": 2}}) + "\n")
        os.utime(f, (st.st_atime, st.st_mtime + 600))
        s = self.collect()
        self.assertEqual(s["atualizadas"], 1)
        r = L.load(self.sb.ledger)["FRA-253-claude-20261005-200000"]
        self.assertEqual(r["status"], "ok")
        self.assertAlmostEqual(r["custo_usd"], 1.25)
        self.assertEqual(len(L.load(self.sb.ledger)), 7)   # não duplicou

    def test_em_andamento_vira_morta_quando_estado_some(self):
        self.collect()
        (self.sb.estado / "lane-claude.json").unlink()
        s = self.collect()
        self.assertEqual(s["atualizadas"], 1)
        self.assertEqual(L.load(self.sb.ledger)["FRA-253-claude-20261005-200000"]["status"], "morta")

    def test_log_apagado_continua_no_ledger(self):
        self.collect()
        (self.sb.logs / "FRA-250-claude-20261003-101500.jsonl").unlink()
        self.collect()
        self.assertIn("FRA-250-claude-20261003-101500", L.load(self.sb.ledger))

    def test_somente_leitura_nos_logs_e_estado(self):
        logs_antes, estado_antes = snapshot(self.sb.logs), snapshot(self.sb.estado)
        self.collect()
        self.collect()
        self.assertEqual(snapshot(self.sb.logs), logs_antes)
        self.assertEqual(snapshot(self.sb.estado), estado_antes)
        self.assertFalse((self.sb.estado / "PAUSE").exists())

    def test_fixtures_do_repo_intactas(self):
        # roda direto sobre as fixtures versionadas (sem cópia) e confere que nada mudou
        antes = snapshot(LOGS.parent)
        L.collect(LOGS, self.sb.ledger, read_state(ESTADO)["logs_em_andamento"])
        self.assertEqual(snapshot(LOGS.parent), antes)

    def test_pasta_de_logs_inexistente(self):
        s = L.collect(self.sb.root / "nao-existe", self.sb.ledger, set())
        self.assertFalse(s["logs_dir_existe"])
        self.assertFalse(self.sb.ledger.exists())   # não cria ledger vazio


if __name__ == "__main__":
    unittest.main()
