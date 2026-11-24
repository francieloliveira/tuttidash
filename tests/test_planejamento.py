"""Visão de planejamento."""
import datetime as dt
import unittest

from gasto_lanes import planejamento, projetos


class Planejamento(unittest.TestCase):
    def setUp(self):
        self.a = projetos.Projeto(id="a", nome="A", repo="~/a", ativo=True, prioridade=2,
                                  operacao={"max_lanes": 2})
        self.b = projetos.Projeto(id="b", nome="B", repo="~/b", ativo=True)
        self.c = projetos.Projeto(id="c", nome="C", repo="~/c", ativo=False)

    def test_ordem_e_proximo(self):
        r = planejamento.quadro([self.b, self.a, self.c], [], [], hoje=dt.date(2026, 11, 22))
        self.assertEqual(r["ordem"], ["a", "b"])
        self.assertEqual(r["proximo"], "a")
        self.assertEqual(r["projetos"][0]["nome"], "A")
        self.assertEqual(r["projetos"][0]["max_lanes"], 2)

    def test_alertas_sem_sinal(self):
        r = planejamento.quadro([self.a, self.b], [], [], hoje=dt.date(2026, 11, 22))
        self.assertEqual(len(r["alertas"]), 2)
        self.assertIn("sem execução", planejamento.texto(r))

    def test_custo_e_fluxo(self):
        recs = [{"id": "x", "card": "FRA-1", "lane": "claude", "dia": "2026-11-22",
                 "semana": "2026-W47", "status": "ok", "custo": "estimado",
                 "custo_usd": 2.0, "projeto": "a"}]
        evs = [{"schema": 1, "ts": "2026-11-22T10:00:00", "projeto": "a", "card": "FRA-1",
                "lane": "claude", "etapa": "claim"},
               {"schema": 1, "ts": "2026-11-22T10:30:00", "projeto": "a", "card": "FRA-1",
                "lane": "claude", "etapa": "finalize", "status": "In Review"}]
        r = planejamento.quadro([self.a, self.b], recs, evs, hoje=dt.date(2026, 11, 22))
        a = r["projetos"][0]
        self.assertEqual(a["custo_7d_usd"], 2.0)
        self.assertEqual(a["claims"], 1)
        self.assertEqual(a["sinal"], "com sinal")


if __name__ == "__main__":
    unittest.main()
