"""FRA-630 (01/11/2026): branch do Linear com `×` prendeu a lane claude por 17 h.

Causa raiz em duas partes:
1. o claim gravava o `branchName` do Linear sem validar; o `branch_valida` (só ASCII)
   recusava o próprio estado do dispatcher em todo ciclo;
2. o caminho de estado recusado retornava antes de todos os freios e só logava, sem
   avisar ninguém, para sempre.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "lanes"))

import dispatcher as d  # noqa: E402

FRA630 = "dono/fra-630-tese-adrspike-de-cruzamento-ambiente-×-watch-hipoteses"


class BranchSeguraTest(unittest.TestCase):
    def test_caso_real_fra_630(self):
        self.assertFalse(d.branch_valida(FRA630), "a causa: o Linear gera nome que o dispatcher recusa")
        n = d.branch_segura(FRA630, "FRA-630")
        self.assertEqual(n, "dono/fra-630-tese-adrspike-de-cruzamento-ambiente-x-watch-hipoteses")
        self.assertTrue(d.branch_valida(n))

    def test_nome_valido_nao_muda(self):
        for n in ("dono/fra-1-ok", "claude/lanes-acp", "fra-2"):
            self.assertEqual(d.branch_segura(n, "FRA-2"), n)

    def test_sempre_valida_idempotente_e_com_o_card(self):
        for bruto in ("ação/ç", "..//x.lock", "", "   ", "a:b?c*d[e]", "feat/emoji-🚀-x", "~^ :", "-x-/", "x//y", None):
            n = d.branch_segura(bruto, "FRA-77")
            self.assertTrue(d.branch_valida(n), (bruto, n))
            self.assertEqual(d.branch_segura(n, "FRA-77"), n, "retomada chega ao mesmo nome")
            self.assertIn("fra-77", n.lower(), (bruto, n))

    def test_estado_com_nome_seguro_passa_na_validacao(self):
        self.assertTrue(d.branch_valida(d.branch_segura(FRA630, "FRA-630")))


class WorktreeAntigoTest(unittest.TestCase):
    """Retomada de um card claimado antes da correção: o worktree tem o nome do Linear."""

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def test_renomeia_a_branch_do_worktree(self):
        tmp = Path(tempfile.mkdtemp(prefix="fra630-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        repo, wts = tmp / "repo", tmp / "wts"
        repo.mkdir()
        wts.mkdir()
        self.git("init", "-q", "-b", "main", cwd=repo)
        self.git("config", "user.email", "t@t", cwd=repo)
        self.git("config", "user.name", "t", cwd=repo)
        (repo / "a").write_text("a")
        self.git("add", ".", cwd=repo)
        self.git("commit", "-qm", "a", cwd=repo)
        self.git("worktree", "add", "-q", "-b", FRA630, str(wts / "fra-630"), "main", cwd=repo)
        seguro = d.branch_segura(FRA630, "FRA-630")
        with mock.patch.object(d, "projeto_repo", return_value=repo), \
                mock.patch.object(d, "projeto_worktrees", return_value=wts), \
                mock.patch.object(d, "copiar_para_worktree", return_value=[]), \
                mock.patch.object(d, "projeto", return_value=mock.Mock(copiar_para_worktree=[])):
            wt = d.prepare_worktree(seguro, "FRA-630")
        self.assertEqual(self.git("branch", "--show-current", cwd=wt), seguro)

    def test_nao_renomeia_branch_de_outro_card(self):
        tmp = Path(tempfile.mkdtemp(prefix="fra630-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        repo, wts = tmp / "repo", tmp / "wts"
        repo.mkdir()
        wts.mkdir()
        self.git("init", "-q", "-b", "main", cwd=repo)
        self.git("config", "user.email", "t@t", cwd=repo)
        self.git("config", "user.name", "t", cwd=repo)
        (repo / "a").write_text("a")
        self.git("add", ".", cwd=repo)
        self.git("commit", "-qm", "a", cwd=repo)
        self.git("worktree", "add", "-q", "-b", "outra/coisa", str(wts / "fra-630"), "main", cwd=repo)
        with mock.patch.object(d, "projeto_repo", return_value=repo), \
                mock.patch.object(d, "projeto_worktrees", return_value=wts), \
                mock.patch.object(d, "copiar_para_worktree", return_value=[]), \
                mock.patch.object(d, "projeto", return_value=mock.Mock(copiar_para_worktree=[])):
            wt = d.prepare_worktree(d.branch_segura(FRA630, "FRA-630"), "FRA-630")
        self.assertEqual(self.git("branch", "--show-current", cwd=wt), "outra/coisa")


class EstadoRecusadoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="recusa-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.logs = []
        self.linear = mock.Mock(return_value={})
        self.label = mock.Mock(return_value=True)
        for alvo, valor in (("STATE_DIR", self.tmp), ("log", self.logs.append), ("linear", self.linear),
                            ("aplicar_label", self.label),
                            ("ler_claim", lambda lane: {"card": "FRA-630", "issue_id": "abcdef0123456789"})):
            p = mock.patch.object(d, alvo, valor)
            p.start()
            self.addCleanup(p.stop)
        self.st = {"lane": "claude", "card": "FRA-630"}

    def test_loga_uma_vez_por_hora_e_avisa_o_dono_uma_vez(self):
        t0 = 1_000_000.0
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0)
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0 + 60)
        self.assertEqual(len([l for l in self.logs if "estado recusado" in l]), 1, "sem log a cada minuto")
        self.linear.assert_not_called()
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0 + 16 * 60)
        self.assertEqual(self.linear.call_count, 1)
        corpo = self.linear.call_args[0][1]["body"]
        self.assertIn("branch inválida", corpo)
        self.assertIn("Nada foi fechado, morto ou movido", corpo)
        self.label.assert_called_once()
        self.assertTrue(any(l.startswith("ALERTA lane:claude") for l in self.logs))
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0 + 30 * 60)
        self.assertEqual(self.linear.call_count, 1, "avisa uma vez só")
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0 + 61 * 60)
        self.assertEqual(len([l for l in self.logs if "estado recusado" in l and "ALERTA" not in l]), 2)

    def test_motivo_novo_recomeca(self):
        t0 = 1_000_000.0
        d.avisar_estado_recusado("claude", self.st, "branch inválida", agora=t0)
        reg = d.avisar_estado_recusado("claude", self.st, "sem claim gravado", agora=t0 + 20 * 60)
        self.assertEqual(reg["desde"], t0 + 20 * 60)
        self.linear.assert_not_called()

    def test_claim_de_outro_card_nao_vai_ao_linear(self):
        with mock.patch.object(d, "ler_claim", lambda lane: {"card": "FRA-1", "issue_id": "0a1b2c3d-4e5f"}):
            d.avisar_estado_recusado("claude", self.st, "x", agora=0)
            reg = d.avisar_estado_recusado("claude", self.st, "x", agora=20 * 60)
        self.linear.assert_not_called()
        self.assertTrue(reg["avisado"], "fica no log e no painel")

    def test_sem_linear_tenta_de_novo(self):
        self.linear.side_effect = RuntimeError("proxy fora")
        d.avisar_estado_recusado("claude", self.st, "x", agora=0)
        reg = d.avisar_estado_recusado("claude", self.st, "x", agora=20 * 60)
        self.assertFalse(reg["avisado"])

    def test_estado_valido_e_soltar_limpam(self):
        d.avisar_estado_recusado("claude", self.st, "x", agora=0)
        self.assertTrue(d._arquivo_recusa("claude").exists())
        with mock.patch.object(d, "apagar_claim", lambda lane: None):
            d.soltar_lane("claude")
        self.assertFalse(d._arquivo_recusa("claude").exists())

    def test_watch_recusado_nao_mexe_em_nada(self):
        with mock.patch.object(d, "motivo_recusa_estado", return_value="branch inválida"), \
                mock.patch.object(d, "kill_lane_tree") as mata, mock.patch.object(d, "soltar_lane") as solta:
            d.watch("claude", self.st)
        mata.assert_not_called()
        solta.assert_not_called()
        self.assertTrue(d._arquivo_recusa("claude").exists())


if __name__ == "__main__":
    unittest.main()
