"""Isolamento lógico por projeto."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import isolamento
from gasto_lanes.projetos import Projeto


class Isolamento(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="iso-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.estado = self.tmp / "estado"
        self.estado.mkdir()
        self.logs = self.tmp / "logs"
        self.logs.mkdir()
        self.wt_a = self.tmp / "a-worktrees" / "FRA-1"
        self.wt_b = self.tmp / "b-worktrees" / "FRA-2"
        self.wt_a.mkdir(parents=True)
        self.wt_b.mkdir(parents=True)
        self.a = Projeto(id="a", repo=str(self.tmp / "a"), nome="A")
        self.b = Projeto(id="b", repo=str(self.tmp / "b"), nome="B")

    def _estado(self, lane, projeto, wt, log, card="FRA-1"):
        cab = {"type": "tutti_projeto", "projeto": projeto, "nome": projeto}
        Path(log).write_text(json.dumps(cab) + "\n", encoding="utf-8")
        (self.estado / f"lane-{lane}.json").write_text(json.dumps({
            "lane": lane, "card": card, "projeto": projeto, "worktree": str(wt),
            "log": str(log), "session": f"lane-{lane}"}), encoding="utf-8")

    def test_projeto_certo(self):
        log = self.logs / "a-FRA-1.jsonl"
        self._estado("claude", "a", self.wt_a, log)
        achados = isolamento.revisar(self.estado, [self.a, self.b], log_dir=self.logs)
        self.assertEqual(isolamento.resumo(achados)["erros"], 0)

    def test_worktree_de_outro_projeto(self):
        log = self.logs / "a-FRA-1.jsonl"
        self._estado("claude", "a", self.wt_b, log)
        achados = isolamento.revisar(self.estado, [self.a, self.b], log_dir=self.logs)
        self.assertTrue(any("worktree fora" in a["mensagem"] for a in achados))

    def test_log_de_outro_projeto(self):
        log = self.logs / "b-FRA-2.jsonl"
        Path(log).write_text(json.dumps({"type": "tutti_projeto", "projeto": "b"}) + "\n")
        (self.estado / "lane-claude.json").write_text(json.dumps({
            "lane": "claude", "card": "FRA-1", "projeto": "a",
            "worktree": str(self.wt_a), "log": str(log)}), encoding="utf-8")
        achados = isolamento.revisar(self.estado, [self.a, self.b], log_dir=self.logs)
        self.assertTrue(any("log de outro projeto" in a["mensagem"] for a in achados))

    def test_projeto_fora_do_cadastro(self):
        log = self.logs / "x.jsonl"
        self._estado("claude", "x", self.wt_a, log)
        achados = isolamento.revisar(self.estado, [self.a], log_dir=self.logs)
        self.assertTrue(any("não está no cadastro" in a["mensagem"] for a in achados))


if __name__ == "__main__":
    unittest.main()
