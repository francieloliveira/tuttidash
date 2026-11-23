"""Retenção de JSONL."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import retencao


class Retencao(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="retencao-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.arq = self.tmp / "eventos.jsonl"
        self.arq.write_text("\n".join([
            json.dumps({"ts": "2026-11-01T10:00:00", "x": 1}),
            json.dumps({"ts": "2026-11-22T10:00:00", "x": 2}),
            "linha invalida",
            json.dumps({"sem_data": True}),
        ]) + "\n", encoding="utf-8")

    def test_planeja(self):
        r = retencao.planejar(self.arq, "ts", 7, hoje=__import__("datetime").date(2026, 11, 22))
        self.assertEqual(r["remover"], 1)
        self.assertEqual(r["manter"], 1)
        self.assertEqual(r["sem_data"], 2)
        self.assertFalse(r["gravou"] if "gravou" in r else False)

    def test_dry_run_nao_muda(self):
        antes = self.arq.read_text(encoding="utf-8")
        r = retencao.podar(self.arq, "ts", 7, aplicar=False)
        self.assertFalse(r["gravou"])
        self.assertEqual(self.arq.read_text(encoding="utf-8"), antes)

    def test_aplica_e_preserva_sem_data(self):
        r = retencao.podar(self.arq, "ts", 7, hoje=__import__("datetime").date(2026, 11, 22),
                           aplicar=True)
        self.assertTrue(r["gravou"])
        texto = self.arq.read_text(encoding="utf-8")
        self.assertIn("2026-11-22", texto)
        self.assertIn("linha invalida", texto)
        self.assertIn("sem_data", texto)
        self.assertNotIn("2026-11-01", texto)

    def test_dias_zero_desliga(self):
        r = retencao.podar(self.arq, "ts", 0, aplicar=True)
        self.assertFalse(r["gravou"])
        self.assertEqual(r["remover"], 0)


if __name__ == "__main__":
    unittest.main()
