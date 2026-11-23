"""Backup, verificação e restauração do estado."""
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import backup


class Backup(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="backup-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.estado = self.tmp / "estado"
        self.estado.mkdir()
        (self.estado / "lane-claude.json").write_text('{"lane":"claude","card":"FRA-1"}', encoding="utf-8")
        (self.estado / "heartbeat.json").write_text('{"at":"2026-11-22 22:00:00"}', encoding="utf-8")
        (self.estado / "eventos.jsonl").write_text('{"schema":1,"projeto":"p1"}\n', encoding="utf-8")
        (self.estado / "enabled").write_text("claude\n", encoding="utf-8")
        (self.estado / "provas").mkdir()
        (self.estado / "provas" / "grande.json").write_text("x", encoding="utf-8")
        (self.estado / "linear-proxy.sock").write_text("", encoding="utf-8")
        self.ledger = self.tmp / "ledger.jsonl"
        self.ledger.write_text('{"id":"a"}\n', encoding="utf-8")
        self.config = self.tmp / "config.json"
        self.config.write_text('{"version":1}', encoding="utf-8")
        self.arq = self.tmp / "backup.tar.gz"

    def test_exporta_verifica_e_restaura(self):
        m = backup.exportar(self.arq, state_dir=self.estado, ledger=self.ledger,
                            config=self.config, incluir_config=True)
        self.assertTrue(self.arq.is_file())
        self.assertTrue(m["inclui_config"])
        nomes = {e["caminho"] for e in m["arquivos"]}
        self.assertIn("ledger.jsonl", nomes)
        self.assertIn("config.json", nomes)
        self.assertIn("state/lane-claude.json", nomes)
        self.assertNotIn("state/provas/grande.json", nomes)
        self.assertNotIn("state/linear-proxy.sock", nomes)
        self.assertTrue(backup.verificar(self.arq)["ok"])

        novo = self.tmp / "novo"
        novo.mkdir()
        r = backup.restaurar(self.arq, state_dir=novo, ledger=self.tmp / "l2.jsonl",
                             config=self.tmp / "c2.json")
        self.assertTrue((novo / "lane-claude.json").is_file())
        self.assertTrue((novo / "eventos.jsonl").is_file())
        self.assertEqual((self.tmp / "l2.jsonl").read_text(), '{"id":"a"}\n')
        self.assertEqual((self.tmp / "c2.json").read_text(), '{"version":1}')
        self.assertGreaterEqual(len(r["restaurados"]), 4)

    def test_sem_config_nao_exporta_config(self):
        m = backup.exportar(self.arq, state_dir=self.estado, ledger=self.ledger)
        self.assertFalse(m["inclui_config"])
        self.assertNotIn("config.json", {e["caminho"] for e in m["arquivos"]})

    def test_recusa_destino_ocupado(self):
        backup.exportar(self.arq, state_dir=self.estado, ledger=self.ledger)
        with self.assertRaises(ValueError):
            backup.restaurar(self.arq, state_dir=self.estado, ledger=self.ledger)
        r = backup.restaurar(self.arq, state_dir=self.estado, ledger=self.ledger, forcar=True)
        self.assertTrue(r["restaurados"])

    def test_checksum_adulterado(self):
        backup.exportar(self.arq, state_dir=self.estado, ledger=self.ledger)
        # Repack trocando o conteúdo de state/heartbeat.json sem atualizar o manifesto.
        with tarfile.open(self.arq, "r:gz") as tar:
            membros = [(m, tar.extractfile(m).read()) for m in tar.getmembers()]
        with tarfile.open(self.arq, "w:gz") as tar:
            for m, dados in membros:
                if m.name == "state/heartbeat.json":
                    dados = b'{"at":"adulterado"}'
                m.size = len(dados)
                import io
                tar.addfile(m, io.BytesIO(dados))
        v = backup.verificar(self.arq)
        self.assertFalse(v["ok"])
        self.assertTrue(any("checksum" in e for e in v["erros"]))


if __name__ == "__main__":
    unittest.main()
