"""Roteamento de card para repositório (FRA-711)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
import dispatcher as d  # noqa: E402


class RepoDoCard(unittest.TestCase):
    def test_le_repo_slug(self):
        card = {"labels": {"nodes": [{"name": "repo:api"}, {"name": "lane"}]}}
        self.assertEqual(d.repo_do_card(card), "api")

    def test_sem_repo_ou_invalido(self):
        self.assertEqual(d.repo_do_card({}), "")
        self.assertEqual(d.repo_do_card({"labels": {"nodes": [{"name": "repo:"}]}}), "")
        self.assertEqual(d.repo_do_card({"labels": {"nodes": [{"name": "repo:a/b"}]}}), "")

    def test_projeto_do_estado_escolhe_repo(self):
        base = d.projetos.Projeto(id="p1", repo="~/a", repos=[
            {"slug": "app", "repo": "~/a"}, {"slug": "api", "repo": "~/b"}])
        antigo = d.projetos.por_id
        d.projetos.por_id = lambda _i: base
        try:
            p = d.projeto_do_estado({"projeto": "p1", "repo_slug": "api"})
            self.assertEqual(p.repo.name, "b")
        finally:
            d.projetos.por_id = antigo


if __name__ == "__main__":
    unittest.main()
