"""Auditoria de permissões do estado."""
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import seguranca


class Seguranca(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="seg-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.estado = self.tmp / "estado"
        self.estado.mkdir()
        self.estado.chmod(0o700)
        self.lane = self.estado / "lane-claude.json"
        self.lane.write_text("{}", encoding="utf-8")
        self.lane.chmod(0o600)
        self.cfg = self.tmp / "config.json"
        self.cfg.write_text("{}", encoding="utf-8")
        self.cfg.chmod(0o600)

    def test_estado_correto(self):
        achados = seguranca.revisar(self.estado, config=self.cfg)
        self.assertEqual(seguranca.resumo(achados)["erros"], 0)

    def test_arquivo_legivel_por_outros_e_erro(self):
        self.lane.chmod(0o644)
        achados = seguranca.revisar(self.estado, config=self.cfg)
        self.assertEqual(seguranca.resumo(achados)["erros"], 1)

    def test_corrigir(self):
        self.lane.chmod(0o644)
        achados = seguranca.revisar(self.estado, config=self.cfg, corrigir=True)
        self.assertEqual(seguranca.resumo(achados)["erros"], 0)
        self.assertEqual(seguranca._modo(self.lane), 0o600)

    def test_symlink_e_erro(self):
        alvo = self.tmp / "fora.json"
        alvo.write_text("{}", encoding="utf-8")
        self.lane.unlink()
        self.lane.symlink_to(alvo)
        self.assertEqual(seguranca.resumo(seguranca.revisar(self.estado))["erros"], 1)


if __name__ == "__main__":
    unittest.main()
