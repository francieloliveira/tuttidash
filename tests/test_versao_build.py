"""Canal e versão do build (tools/versao-build.sh): main-<sha> só para a main do GitHub, limpa."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "versao-build.sh"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class VersaoDoBuild(unittest.TestCase):
    def setUp(self):
        raiz = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, raiz, True)
        self.origem = raiz / "origem.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origem)], check=True)
        self.wt = raiz / "wt"
        subprocess.run(["git", "clone", "-q", str(self.origem), str(self.wt)], check=True, capture_output=True)
        git(self.wt, "config", "user.email", "t@example.com")
        git(self.wt, "config", "user.name", "t")
        git(self.wt, "checkout", "-q", "-b", "main")
        (self.wt / "a.txt").write_text("a\n")
        git(self.wt, "add", "a.txt")
        git(self.wt, "commit", "-q", "-m", "i")
        git(self.wt, "push", "-q", "origin", "main")
        git(self.wt, "fetch", "-q", "origin")
        self.sha = git(self.wt, "rev-parse", "--short=7", "HEAD")

    def versao(self, pasta=None):
        return subprocess.run(["bash", str(SCRIPT), str(pasta or self.wt)], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_main_limpa(self):
        self.assertEqual(self.versao(), f"main main-{self.sha}")

    def test_main_com_mudanca_e_alpha(self):
        (self.wt / "a.txt").write_text("mexido\n")
        self.assertEqual(self.versao(), f"alpha branch-main-{self.sha}-sujo")

    def test_branch_e_alpha_sem_o_prefixo(self):
        git(self.wt, "checkout", "-q", "-b", "dono/caixa-do-dono")
        (self.wt / "b.txt").write_text("b\n")
        git(self.wt, "add", "b.txt")
        git(self.wt, "commit", "-q", "-m", "b")
        sha = git(self.wt, "rev-parse", "--short=7", "HEAD")
        self.assertEqual(self.versao(), f"alpha branch-caixa-do-dono-{sha}")

    def test_main_destacada_igual_a_origem_e_main(self):
        git(self.wt, "checkout", "-q", "--detach", "origin/main")
        self.assertEqual(self.versao(), f"main main-{self.sha}")

    def test_sem_git(self):
        self.assertEqual(self.versao(tempfile.mkdtemp()), "alpha dev")


if __name__ == "__main__":
    unittest.main()
