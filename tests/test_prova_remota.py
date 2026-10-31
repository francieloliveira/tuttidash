"""FRA-610. A prova remota usa o script da base e não o do head."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import gasto_lanes.prova_remota as prova

RAIZ = Path(__file__).resolve().parents[1]
SCRIPT = RAIZ / "scripts" / "prova-remota.sh"
WORKFLOW = RAIZ / ".github" / "workflows" / "prova-remota.yml"
MODULO = RAIZ / "gasto_lanes" / "prova_remota.py"
CHECKOUT = "11d5960a326750d5838078e36cf38b85af677262"
UNIDADE = [(["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."], None)]


def git(cwd, *args):
    proc = subprocess.run(["git", *args], cwd=cwd, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        raise AssertionError(proc.stderr or proc.stdout)
    return proc.stdout.strip()


def iniciar(repo: Path) -> None:
    subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
    git(repo, "config", "user.email", "prova@example.com")
    git(repo, "config", "user.name", "prova")
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "config", "core.autocrlf", "false")


def escrever(repo: Path, rel: str, texto: str) -> None:
    caminho = repo / rel
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(texto)


def commitar(repo: Path, mensagem: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", mensagem)
    return git(repo, "rev-parse", "HEAD")


class SelecaoDaBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(self._limpar)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        iniciar(self.repo)
        escrever(self.repo, prova.SCRIPT_REL, "#!/bin/bash\necho script-da-base\nexit 0\n")
        escrever(self.repo, prova.MODULO_REL, "# módulo da base\n")
        escrever(
            self.repo,
            prova.WORKFLOW_REL,
            "name: prova-remota\non:\n  pull_request:\njobs:\n  prova-remota:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo base\n",
        )
        escrever(self.repo, "tests/__init__.py", "")
        escrever(
            self.repo,
            "tests/test_vermelho.py",
            "import unittest\n\nclass Verde(unittest.TestCase):\n    def test_passa(self):\n        self.assertEqual(1, 1)\n",
        )
        self.base_sha = commitar(self.repo, "base")
        escrever(
            self.repo,
            prova.SCRIPT_REL,
            "#!/bin/bash\nraiz=$(cd \"$(dirname \"$0\")/..\" && pwd)\ntouch \"$raiz/SENTINEL\"\necho script-do-head\nexit 0\n",
        )
        escrever(
            self.repo,
            prova.WORKFLOW_REL,
            "name: prova-remota\non:\n  pull_request:\njobs:\n  prova-remota:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo swapped\n",
        )
        escrever(
            self.repo,
            "tests/test_vermelho.py",
            "import unittest\n\nclass Vermelho(unittest.TestCase):\n    def test_falha(self):\n        self.fail('vermelho')\n",
        )
        self.head_sha = commitar(self.repo, "head")
        self.base = self.tmp / "base"
        self.head = self.tmp / "head"
        subprocess.run(
            ["git", "-C", str(self.repo), "worktree", "add", "--detach", str(self.base), self.base_sha],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(self.repo), "worktree", "add", "--detach", str(self.head), self.head_sha],
            check=True,
            capture_output=True,
        )

    def _limpar(self):
        for extra in (getattr(self, "base", None), getattr(self, "head", None)):
            if extra is not None and extra.exists():
                subprocess.run(
                    ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(extra)],
                    check=False,
                    capture_output=True,
                )
        shutil.rmtree(self.tmp, ignore_errors=True)

    def ambiente(self, **extra):
        env = os.environ.copy()
        env[prova.VAR_BASE] = self.base_sha
        env[prova.VAR_HEAD] = self.head_sha
        env.update(extra)
        return env

    def provar(self, comandos=None, ambiente=None):
        return prova.rodar(
            self.base,
            self.head,
            comandos=UNIDADE if comandos is None else comandos,
            ambiente=self.ambiente() if ambiente is None else ambiente,
        )

    def test_alterar_workflow_e_script_nao_troca_a_prova_e_teste_vermelho_falha(self):
        base_script = prova.blob_do_commit(self.repo, self.base_sha, prova.SCRIPT_REL)
        head_script = prova.blob_do_commit(self.repo, self.head_sha, prova.SCRIPT_REL)
        base_wf = prova.blob_do_commit(self.repo, self.base_sha, prova.WORKFLOW_REL)
        head_wf = prova.blob_do_commit(self.repo, self.head_sha, prova.WORKFLOW_REL)
        self.assertNotEqual(base_script, head_script)
        self.assertNotEqual(base_wf, head_wf)
        self.assertIn(b"swapped", head_wf)
        self.assertNotIn(b"swapped", base_wf)
        self.assertEqual(prova.escolher_script(self.repo, self.base_sha, self.head_sha), base_script)
        self.assertIn(b"script-da-base", base_script)
        self.assertNotIn(b"SENTINEL", base_script)

        # O script do head, se fosse a prova, sairia 0 e deixaria o marcador.
        proc = subprocess.run(["bash", str(self.head / prova.SCRIPT_REL)], check=False)
        self.assertEqual(proc.returncode, 0)
        self.assertTrue((self.head / "SENTINEL").is_file())
        (self.head / "SENTINEL").unlink()

        blob = prova.escolher_script(self.repo, self.base_sha, self.head_sha)
        rodado = subprocess.run(["bash", "-s"], input=blob, check=False, capture_output=True)
        self.assertEqual(rodado.returncode, 0)
        self.assertIn(b"script-da-base", rodado.stdout)
        self.assertFalse((self.head / "SENTINEL").exists())

        direto = subprocess.run(
            ["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."],
            cwd=self.head,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(direto.returncode, 0)
        self.assertIn("vermelho", direto.stderr + direto.stdout)
        self.assertNotEqual(self.provar(), 0)
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_teste_verde_passa_sem_rodar_o_script_do_head(self):
        escrever(
            self.head,
            "tests/test_vermelho.py",
            "import unittest\n\nclass Verde(unittest.TestCase):\n    def test_passa(self):\n        self.assertEqual(1, 1)\n",
        )
        proc = subprocess.run(["bash", str(self.head / prova.SCRIPT_REL)], check=False)
        self.assertEqual(proc.returncode, 0)
        (self.head / "SENTINEL").unlink()
        self.assertEqual(self.provar(), 0)
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_sha_curto_nao_escolhe(self):
        with self.assertRaises(prova.ProvaTrocada):
            prova.escolher_script(self.repo, self.base_sha[:7], self.head_sha)
        with self.assertRaises(prova.ProvaTrocada):
            prova.escolher_script(self.repo, self.base_sha, self.head_sha[:7])

    def test_sha_anunciado_diferente_nao_roda(self):
        with self.assertRaises(prova.ProvaTrocada):
            self.provar(ambiente=self.ambiente(**{prova.VAR_HEAD: "0" * 40}))
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_script_sujo_nao_roda(self):
        with (self.base / prova.SCRIPT_REL).open("a") as arquivo:
            arquivo.write("echo trocado\n")
        with self.assertRaises(prova.ProvaTrocada):
            self.provar()
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_symlink_para_o_head_nao_roda(self):
        alvo = self.base / prova.SCRIPT_REL
        alvo.unlink()
        alvo.symlink_to(self.head / prova.SCRIPT_REL)
        with self.assertRaises(prova.ProvaTrocada):
            self.provar()
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_nao_repassa_token(self):
        env = self.ambiente(GITHUB_TOKEN="token-de-teste")
        destino = self.tmp / "token.txt"
        comando = [(
            ["python3", "-c", "import os,pathlib,sys; pathlib.Path(sys.argv[1]).write_text('sim' if 'GITHUB_TOKEN' in os.environ else 'nao')", str(destino)],
            None,
        )]
        self.assertEqual(self.provar(comandos=comando, ambiente=env), 0)
        self.assertEqual(destino.read_text(), "nao")

    def test_tira_o_head_do_path(self):
        env = self.ambiente()
        env["PATH"] = str(self.head) + os.pathsep + env.get("PATH", "")
        destino = self.tmp / "path.txt"
        comando = [(
            ["python3", "-c", "import os,pathlib,sys; pathlib.Path(sys.argv[1]).write_text(os.environ.get('PATH',''))", str(destino)],
            None,
        )]
        self.assertEqual(self.provar(comandos=comando, ambiente=env), 0)
        self.assertNotIn(str(self.head), destino.read_text())

    def test_recusa_bash_do_script_do_head(self):
        comando = [(["bash", str(self.head / prova.SCRIPT_REL)], None)]
        with self.assertRaises(prova.ProvaTrocada):
            self.provar(comandos=comando)
        self.assertFalse((self.head / "SENTINEL").exists())


class EntradaDoScript(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.base = self.tmp / "base"
        self.head = self.tmp / "head"
        self.base.mkdir()
        self.head.mkdir()
        iniciar(self.base)
        iniciar(self.head)
        escrever(self.base, prova.SCRIPT_REL, SCRIPT.read_text())
        escrever(
            self.base,
            prova.MODULO_REL,
            "import os, pathlib, sys\n"
            "if 'GITHUB_TOKEN' in os.environ:\n"
            "    raise SystemExit(3)\n"
            "base = pathlib.Path(sys.argv[sys.argv.index('--base') + 1])\n"
            "(base / 'RODOU').write_text('ok\\n')\n"
            "raise SystemExit(0)\n",
        )
        self.base_sha = commitar(self.base, "base")
        escrever(
            self.head,
            prova.SCRIPT_REL,
            "#!/bin/bash\nraiz=$(cd \"$(dirname \"$0\")/..\" && pwd)\ntouch \"$raiz/SENTINEL\"\nexit 0\n",
        )
        escrever(
            self.head,
            prova.MODULO_REL,
            "import pathlib, sys\n"
            "head = pathlib.Path(sys.argv[sys.argv.index('--head') + 1])\n"
            "(head / 'SENTINEL').write_text('head\\n')\n"
            "raise SystemExit(0)\n",
        )
        self.head_sha = commitar(self.head, "head")

    def ambiente(self, **extra):
        env = os.environ.copy()
        env[prova.VAR_BASE] = self.base_sha
        env[prova.VAR_HEAD] = self.head_sha
        env["GITHUB_TOKEN"] = "token-de-teste"
        env.update(extra)
        return env

    def rodar_shell(self, env=None):
        return subprocess.run(
            ["bash", str(self.base / prova.SCRIPT_REL), str(self.base), str(self.head)],
            check=False,
            capture_output=True,
            text=True,
            env=self.ambiente() if env is None else env,
        )

    def test_entrada_executa_o_modulo_da_base(self):
        proc = self.rodar_shell()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual((self.base / "RODOU").read_text(), "ok\n")
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_modulo_sujo_nao_roda(self):
        with (self.base / prova.MODULO_REL).open("a") as arquivo:
            arquivo.write("# sujo\n")
        proc = self.rodar_shell()
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("diverge", proc.stderr)
        self.assertFalse((self.head / "SENTINEL").exists())
        self.assertFalse((self.base / "RODOU").exists())

    def test_symlink_do_modulo_nao_roda(self):
        modulo = self.base / prova.MODULO_REL
        modulo.unlink()
        modulo.symlink_to(self.head / prova.MODULO_REL)
        proc = self.rodar_shell()
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("symlink", proc.stderr)
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_sha_incompleto(self):
        proc = self.rodar_shell(env=self.ambiente(**{prova.VAR_HEAD: "abc"}))
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("incompleto", proc.stderr)
        self.assertFalse((self.head / "SENTINEL").exists())

    def test_recusa_sobrepor(self):
        proc = subprocess.run(
            ["bash", str(SCRIPT), str(RAIZ), str(RAIZ)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("head dentro da base", proc.stderr)


class ContratoDoWorkflow(unittest.TestCase):
    def test_workflow_e_pull_request_sem_secrets(self):
        texto = WORKFLOW.read_text()
        proibido = "pull_request_" + "target"
        self.assertNotIn(proibido, texto)
        self.assertIn("pull_request:", texto)
        self.assertIn("branches: [main]", texto)
        self.assertEqual(texto.count("permissions:"), 1)
        self.assertEqual(texto.count("contents: read"), 1)
        self.assertNotIn("contents: write", texto)
        self.assertNotIn("secrets.", texto)
        self.assertNotIn("head/scripts", texto)
        self.assertEqual(texto.count(f"actions/checkout@{CHECKOUT}"), 2)
        self.assertEqual(texto.count("persist-credentials: false"), 2)
        self.assertIn("github.event.pull_request.base.sha", texto)
        self.assertIn("github.event.pull_request.head.sha", texto)
        self.assertIn("head.repo.full_name", texto)
        self.assertIn('cat-file -e "${PROVA_BASE_SHA}:scripts/prova-remota.sh"', texto)
        self.assertIn('cat-file -p "${PROVA_BASE_SHA}:scripts/prova-remota.sh"', texto)
        self.assertLess(
            texto.index('cat-file -e "${PROVA_BASE_SHA}:scripts/prova-remota.sh"'),
            texto.index('cat-file -p "${PROVA_BASE_SHA}:scripts/prova-remota.sh"'),
        )
        self.assertIn("bash -s --", texto)
        self.assertIn('bash "$GITHUB_WORKSPACE/base/tools/checar-publicacao.sh"', texto)
        self.assertIn(f"name: {prova.NOME_DO_CHECK}", texto)
        self.assertIn("runs-on: macos-15", texto)

    def test_outros_workflows_nao_usam_o_evento_de_alvo(self):
        proibido = "pull_request_" + "target"
        for caminho in (RAIZ / ".github" / "workflows").glob("*.yml"):
            self.assertNotIn(proibido, caminho.read_text(), caminho.name)

    def test_script_real_nao_chama_script_do_head(self):
        texto = SCRIPT.read_text()
        self.assertIn("gasto_lanes/prova_remota.py", texto)
        self.assertIn("PROVA_BASE_SHA", texto)
        self.assertIn("PROVA_HEAD_SHA", texto)
        self.assertIn("unset GITHUB_TOKEN", texto)
        self.assertNotIn("head/scripts", texto)
        self.assertNotIn("pull_request_" + "target", texto)

    def test_comandos_da_base_sao_fechados(self):
        base = self._dir()
        self.assertEqual(
            prova.comandos_da_base(base),
            [
                (["bash", str((base / "tools" / "checar-publicacao.sh").resolve())], None),
                (["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."], None),
                (["python3", "-m", "unittest", "lanes.test_lanes"], None),
                (["swift", "test"], "apps/notch-mac"),
            ],
        )

    def test_main_nao_aceita_trocar_comando(self):
        with self.assertRaises(SystemExit) as ctx:
            prova.main(["--base", "x", "--head", "y", "--comandos", "exit 0"])
        self.assertEqual(ctx.exception.code, 2)

    def test_main_recusa_head_igual_a_base(self):
        self.assertEqual(prova.main(["--base", str(RAIZ), "--head", str(RAIZ)]), 2)

    def test_main_recusa_modulo_fora_da_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "base"
            head = Path(tmp) / "head"
            base.mkdir()
            head.mkdir()
            proc = subprocess.run(
                [sys.executable, str(MODULO), "--base", str(base), "--head", str(head)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("módulo", proc.stderr)

    def _dir(self):
        caminho = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, caminho, True)
        return caminho


if __name__ == "__main__":
    unittest.main()
