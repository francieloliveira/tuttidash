"""Relatório semanal por projeto."""
import datetime as dt
import unittest

from gasto_lanes import semanal


def rec(dia, projeto, custo=None, status="ok"):
    return {"id": f"x-{dia}-{projeto}-{status}", "card": "FRA-1", "lane": "claude",
            "inicio": f"{dia}T10:00:00", "dia": dia, "semana": "2026-W47",
            "status": status, "custo": "estimado" if custo is not None else "desconhecido",
            "custo_usd": custo, "projeto": projeto}


def ev(ts, projeto, etapa, status=""):
    return {"schema": 1, "ts": ts, "projeto": projeto, "card": "FRA-1", "lane": "claude",
            "etapa": etapa, "status": status}


class Semanal(unittest.TestCase):
    def test_por_projeto_e_janela(self):
        hoje = dt.date(2026, 11, 22)
        r = semanal.gerar([
            rec("2026-11-20", "p1", 2.0),
            rec("2026-11-21", "p1", None, "erro"),
            rec("2026-11-21", "p2", 3.0),
            rec("2026-11-01", "p2", 99.0),   # fora da janela
        ], [
            ev("2026-11-20T10:00:00", "p1", "claim"),
            ev("2026-11-20T10:30:00", "p1", "finalize", "In Review"),
            ev("2026-11-21T10:00:00", "p2", "merge"),
            ev("2026-11-01T10:00:00", "p2", "claim"),   # fora
        ], [{"id": "p1", "nome": "Projeto 1"}, {"id": "p2", "nome": "Projeto 2"}], hoje=hoje)
        self.assertEqual(r["semana"], "2026-11-16 a 2026-11-22")
        ps = {p["projeto"]: p for p in r["projetos"]}
        self.assertEqual(ps["p1"]["execucoes"], 2)
        self.assertEqual(ps["p1"]["custo_conhecido_usd"], 2.0)
        self.assertEqual(ps["p1"]["custo_desconhecido"], 1)
        self.assertEqual(ps["p1"]["merges"], 0)
        self.assertEqual(ps["p1"]["duracao_media_min"], 30.0)
        self.assertEqual(ps["p2"]["execucoes"], 1)
        self.assertEqual(ps["p2"]["merges"], 1)
        self.assertNotIn(99.0, [p["custo_conhecido_usd"] for p in r["projetos"]])

    def test_sem_medida(self):
        r = semanal.gerar([], [], [{"id": "p1", "nome": "Um"}], hoje=dt.date(2026, 11, 22))
        self.assertEqual(r["projetos"][0]["execucoes"], 0)
        self.assertIn("sem medida", semanal.texto(r))

    def test_sem_projeto(self):
        r = semanal.gerar([rec("2026-11-22", "", 1.0)], [], [], hoje=dt.date(2026, 11, 22))
        self.assertEqual(r["projetos"][0]["nome"], "sem projeto")


if __name__ == "__main__":
    unittest.main()
