"""Eventos de fluxo: formato, append, filtros e tolerância a lixo."""
import datetime as dt
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import eventos


class Eventos(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="eventos-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.arquivo = self.tmp / "eventos.jsonl"

    def test_registra_e_le(self):
        quando = dt.datetime(2026, 11, 22, 22, 0, 0)
        self.assertTrue(eventos.registrar(self.arquivo, projeto="p1", card="fra-1", lane="claude",
                                          etapa="claim", status="iniciado", sha="abc", quando=quando))
        ev = eventos.ler(self.arquivo)
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0]["schema"], 1)
        self.assertEqual(ev[0]["projeto"], "p1")
        self.assertEqual(ev[0]["card"], "FRA-1")
        self.assertEqual(ev[0]["ts"], "2026-11-22T22:00:00")
        self.assertEqual(ev[0]["sha"], "abc")

    def test_filtros_e_limite(self):
        for i, projeto in enumerate(("p1", "p2", "p1")):
            eventos.registrar(self.arquivo, projeto=projeto, card=f"FRA-{i}", lane="claude",
                              etapa="claim")
        self.assertEqual([e["card"] for e in eventos.ler(self.arquivo, projeto="p1")], ["FRA-0", "FRA-2"])
        self.assertEqual([e["card"] for e in eventos.ler(self.arquivo, card="FRA-1")], ["FRA-1"])
        self.assertEqual([e["card"] for e in eventos.ler(self.arquivo, limite=1)], ["FRA-2"])

    def test_sem_chave_nao_grava(self):
        self.assertFalse(eventos.registrar(self.arquivo, projeto="", card="FRA-1", lane="claude",
                                           etapa="claim"))
        self.assertFalse(eventos.registrar(self.arquivo, projeto="p1", card="FRA-1", lane="",
                                           etapa="claim"))
        self.assertFalse(self.arquivo.exists())

    def test_limpa_texto_e_nao_grava_segredo(self):
        eventos.registrar(self.arquivo, projeto="p1", card="FRA-1", lane="claude", etapa="claim",
                          motivo="linha 1\nlinha 2", sha="x" * 100)
        ev = eventos.ler(self.arquivo)[0]
        self.assertEqual(ev["motivo"], "linha 1 linha 2")
        self.assertEqual(len(ev["sha"]), 64)

    def test_arquivo_ausente_ou_ilegivel(self):
        self.assertEqual(eventos.ler(self.tmp / "nao.jsonl"), [])
        self.arquivo.write_text("nao json\n{}\n", encoding="utf-8")
        self.assertEqual(eventos.ler(self.arquivo), [])


if __name__ == "__main__":
    unittest.main()
