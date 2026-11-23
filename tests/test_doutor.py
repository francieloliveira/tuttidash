"""Diagnóstico do portfólio."""
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import doutor, projetos


class Config:
    def __init__(self, tmp):
        self.stateDir = tmp / "estado"
        self.logsDir = tmp / "logs"
        self.ledger = tmp / "ledger.jsonl"
        self.arquivoConfig = tmp / "config.json"


class Doutor(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="doutor-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.cfg = Config(self.tmp)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        (self.repo / ".git").mkdir()
        self.norte = self.repo / "docs" / "caminho.md"
        self.norte.parent.mkdir(parents=True)
        self.norte.write_text("norte", encoding="utf-8")
        self.cfg.stateDir.mkdir()
        self.cfg.logsDir.mkdir()
        self.cfg.ledger.write_text("", encoding="utf-8")

    def p(self, **kw):
        base = dict(id="p1", nome="Projeto", repo=str(self.repo), worktrees=str(self.tmp / "wt"),
                    norte="docs/caminho.md", ativo=True)
        base.update(kw)
        return projetos.Projeto(**base)

    def test_repo_ok(self):
        achados = doutor.checar(self.cfg, [self.p()], socket_linear=self.tmp / "sock", gh="/bin/gh")
        self.assertEqual(doutor.resumo(achados)["erros"], 0)

    def test_repo_ausente_e_erro(self):
        achados = doutor.checar(self.cfg, [self.p(repo=str(self.tmp / "sumiu"))],
                                socket_linear=self.tmp / "sock", gh="/bin/gh")
        self.assertEqual(doutor.resumo(achados)["erros"], 1)
        self.assertIn("não existe", doutor.texto(achados))

    def test_projeto_inativo_e_aviso(self):
        achados = doutor.checar(self.cfg, [self.p(ativo=False)], socket_linear=self.tmp / "sock", gh="/bin/gh")
        self.assertTrue(any(a["nivel"] == "aviso" and "inativo" in a["mensagem"] for a in achados))

    def test_sem_gh_e_erro(self):
        achados = doutor.checar(self.cfg, [], socket_linear=self.tmp / "sock", gh="")
        self.assertTrue(any(a["nivel"] == "erro" and "gh" in a["mensagem"] for a in achados))


if __name__ == "__main__":
    unittest.main()
