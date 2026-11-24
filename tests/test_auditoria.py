"""Filtros da trilha de auditoria."""
import datetime as dt
import unittest

from gasto_lanes import auditoria


def ev(ts, projeto, card, etapa, status="", motivo="", pr=""):
    return {"schema": 1, "ts": ts, "projeto": projeto, "card": card, "lane": "claude",
            "etapa": etapa, "status": status, "motivo": motivo, "pr": pr}


class Auditoria(unittest.TestCase):
    def setUp(self):
        self.ev = [
            ev("2026-11-20T10:00:00", "p1", "FRA-1", "claim"),
            ev("2026-11-20T10:30:00", "p1", "FRA-1", "finalize", "lane:falhou", "teste"),
            ev("2026-11-21T11:00:00", "p2", "FRA-2", "merge", "mergeado", "", "#9"),
        ]

    def test_filtra_projeto_card_etapa(self):
        self.assertEqual(len(auditoria.filtrar(self.ev, projeto="p1")), 2)
        self.assertEqual(len(auditoria.filtrar(self.ev, card="fra-2")), 1)
        self.assertEqual(len(auditoria.filtrar(self.ev, etapa="finalize")), 1)

    def test_filtra_data(self):
        achados = auditoria.filtrar(self.ev, desde=dt.date(2026, 11, 21))
        self.assertEqual([e["card"] for e in achados], ["FRA-2"])

    def test_linhas_trazem_motivo_e_pr(self):
        texto = "\n".join(auditoria.linhas(self.ev))
        self.assertIn("teste", texto)
        self.assertIn("#9", texto)


if __name__ == "__main__":
    unittest.main()
