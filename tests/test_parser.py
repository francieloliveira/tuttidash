import unittest

from gasto_lanes import parser as p
from tests.helpers import Sandbox


class Nome(unittest.TestCase):
    def test_nome_valido(self):
        m = p.parse_name("FRA-259-grok-20261004-153012.jsonl")
        self.assertEqual(m["card"], "FRA-259")
        self.assertEqual(m["lane"], "grok")
        self.assertEqual(m["inicio"], "2026-10-04T15:30:12")
        self.assertEqual(m["dia"], "2026-10-04")
        self.assertEqual(m["semana"], "2026-W40")

    def test_nomes_invalidos(self):
        for n in ("notas.jsonl", "FRA-259-grok.jsonl", "FRA-259-grok-20261004-153012.json",
                  "FRA-259-grok-20261399-153012.jsonl", "lanes-dispatcher.log"):
            self.assertIsNone(p.parse_name(n), n)

    def test_virada_de_semana_iso(self):
        self.assertEqual(p.parse_name("A-1-claude-20260927-235959.jsonl")["semana"], "2026-W39")
        self.assertEqual(p.parse_name("A-1-claude-20260928-000000.jsonl")["semana"], "2026-W40")


class Execucoes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sb = Sandbox()
        running = {"FRA-253-claude-20261005-200000.jsonl"}
        cls.r = {f.name: p.parse_log(f, running) for f in cls.sb.logs.glob("FRA-*.jsonl")}

    @classmethod
    def tearDownClass(cls):
        cls.sb.cleanup()

    def test_claude_ok_custo_estimado(self):
        r = self.r["FRA-250-claude-20261003-101500.jsonl"]
        self.assertEqual(r["status"], p.STATUS_OK)
        self.assertAlmostEqual(r["custo_usd"], 2.3141)
        self.assertEqual(r["custo"], p.CUSTO_ESTIMADO)
        self.assertEqual(r["turnos"], 42)
        self.assertEqual(r["duracao_ms"], 1_500_000)
        self.assertEqual(r["tokens"], {"entrada": 120, "saida": 30_000, "cache_leitura": 1_200_000,
                                       "cache_criacao": 45_000, "total": 1_275_120})
        self.assertEqual(r["modelo"], "claude-opus-4-1")
        self.assertIsNone(r["duracao_estimada_ms"])

    def test_grok_api_key_custo_informado(self):
        r = self.r["FRA-259-grok-20261004-153012.jsonl"]
        self.assertEqual(r["status"], p.STATUS_OK)
        self.assertEqual(r["custo"], p.CUSTO_INFORMADO)
        self.assertAlmostEqual(r["custo_usd"], 0.48)
        self.assertEqual(r["auth"], "user")

    def test_grok_oauth_custo_zero_vira_desconhecido(self):
        r = self.r["FRA-260-grok-20261004-180000.jsonl"]
        self.assertEqual(r["status"], p.STATUS_OK)
        self.assertIsNone(r["custo_usd"])
        self.assertEqual(r["custo"], p.CUSTO_DESCONHECIDO)
        self.assertEqual(r["turnos"], 22)
        self.assertIsNotNone(r["tokens"])

    def test_morta_sem_result(self):
        r = self.r["FRA-251-claude-20261005-090000.jsonl"]
        self.assertEqual(r["status"], p.STATUS_MORTA)
        self.assertIsNone(r["custo_usd"])
        self.assertEqual(r["custo"], p.CUSTO_DESCONHECIDO)
        self.assertIsNone(r["turnos"])
        self.assertIsNone(r["tokens"])
        # mensagem repetida (msg_b1 em duas linhas) conta uma vez só
        self.assertEqual(r["parcial"]["respostas"], 2)
        self.assertEqual(r["parcial"]["tokens"]["total"], 2605 + 3205)
        self.assertEqual(r["linhas_invalidas"], 1)  # "Terminated: 15" do stderr
        self.assertEqual(r["duracao_estimada_ms"], 90 * 60 * 1000)

    def test_cancelado_e_erro_com_custo_desconhecido(self):
        r = self.r["FRA-252-grok-20261005-140000.jsonl"]
        self.assertEqual(r["status"], p.STATUS_CANCELADA)   # FRA-528: cancelada não é falha
        self.assertEqual(r["subtipo"], "error_during_execution")
        self.assertIn("cancelled", r["erros"])
        self.assertIsNone(r["custo_usd"])
        self.assertIsNone(r["tokens"])        # usage todo zero = desconhecido
        self.assertIsNone(r["duracao_ms"])    # duration_ms 0 = desconhecido
        self.assertEqual(r["duracao_estimada_ms"], 2 * 60 * 1000)

    def test_erro_com_custo_conhecido(self):
        r = self.r["FRA-248-claude-20260927-230000.jsonl"]
        self.assertEqual(r["status"], p.STATUS_ERRO)
        self.assertAlmostEqual(r["custo_usd"], 3.02)

    def test_em_andamento(self):
        r = self.r["FRA-253-claude-20261005-200000.jsonl"]
        self.assertEqual(r["status"], p.STATUS_ANDAMENTO)
        self.assertIsNone(r["custo_usd"])

    def test_custo_parcial_ou_incompleto_e_desconhecido(self):
        for extra in ({"cost_is_partial": True}, {"usage_is_incomplete": True}):
            self.assertEqual(p.classify_cost("grok", {"total_cost_usd": 1.0, **extra}, "user"),
                             (None, p.CUSTO_DESCONHECIDO))
        self.assertEqual(p.classify_cost("claude", None, None), (None, p.CUSTO_DESCONHECIDO))
        self.assertEqual(p.classify_cost("claude", {"total_cost_usd": "1"}, None), (None, p.CUSTO_DESCONHECIDO))

    def test_tipo_custo_por_agente(self):
        for lane in ("claude", "codex", "opencode"):
            self.assertEqual(p.classify_cost(lane, {"total_cost_usd": 1.5}, None),
                             (1.5, p.CUSTO_ESTIMADO))
        for lane in ("grok", "cursor", "agente_novo"):
            self.assertEqual(p.classify_cost(lane, {"total_cost_usd": 1.5}, None),
                             (1.5, p.CUSTO_INFORMADO))


if __name__ == "__main__":
    unittest.main()
