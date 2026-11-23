"""Resumo do fluxo a partir dos eventos."""
import unittest

from gasto_lanes import fluxo


def ev(t, projeto, card, lane, etapa, status=""):
    return {"schema": 1, "ts": t, "projeto": projeto, "card": card, "lane": lane,
            "etapa": etapa, "status": status}


class Fluxo(unittest.TestCase):
    def test_conta_e_mede_claim_ate_finalize(self):
        r = fluxo.resumo([
            ev("2026-11-22T20:00:00", "p1", "FRA-1", "claude", "claim"),
            ev("2026-11-22T20:30:00", "p1", "FRA-1", "claude", "finalize", "In Review (url)"),
            ev("2026-11-22T21:00:00", "p1", "FRA-1", "claude", "merge"),
            ev("2026-11-22T20:00:00", "p2", "FRA-2", "grok", "claim"),
            ev("2026-11-22T20:10:00", "p2", "FRA-2", "grok", "finalize", "lane:falhou (teste)"),
        ])
        p1 = r["projetos"][0]
        self.assertEqual((p1["claims"], p1["finalizes"], p1["merges"]), (1, 1, 1))
        self.assertEqual(p1["duracao_media_min"], 30.0)
        p2 = r["projetos"][1]
        self.assertEqual(p2["falhas"], 1)
        self.assertEqual(p2["duracao_media_min"], 10.0)
        self.assertEqual(r["abertos_total"], 0)

    def test_sem_par_nao_inventa_duracao(self):
        r = fluxo.resumo([
            ev("2026-11-22T20:00:00", "p1", "FRA-1", "claude", "claim"),
            ev("2026-11-22T20:00:00", "p2", "FRA-2", "grok", "finalize", "In Review"),
        ])
        p1, p2 = r["projetos"]
        self.assertEqual(p1["claims"], 1)
        self.assertIsNone(p1["duracao_media_min"])
        self.assertEqual(p1["abertos"], 1)
        self.assertIsNone(p2["duracao_media_min"])
        self.assertEqual(r["abertos_total"], 1)

    def test_evento_ruim_e_ignorado(self):
        r = fluxo.resumo([None, {}, {"projeto": "p1"}, "x"])
        self.assertEqual(r["projetos"], [])

    def test_texto(self):
        r = fluxo.resumo([ev("2026-11-22T20:00:00", "p1", "FRA-1", "claude", "claim"),
                          ev("2026-11-22T20:30:00", "p1", "FRA-1", "claude", "finalize")])
        t = fluxo.texto(r)
        self.assertIn("p1: 1 claims", t)
        self.assertIn("30,0 min", t)


if __name__ == "__main__":
    unittest.main()
