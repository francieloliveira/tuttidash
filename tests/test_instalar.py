"""FRA-602: instalar.sh por argv, ref validada e worktree dentro de uma raiz segura.

Não chama o vigia de verdade nem o tmux. O script só vê um cadastro temporário
quando o teste passa TUTTIDASH_INSTALAR_CONFIG; sem isso, repo de teste não
bate com o cadastro da máquina e o clean não roda.
"""
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import projetos as P

_spec = importlib.util.spec_from_file_location(
    "watch_instalar", Path(__file__).resolve().parents[1] / "bots" / "watch.py")
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)

SCRIPT = Path(__file__).resolve().parents[1] / "bots" / "instalar.sh"
ID = "aaaaaaaa-0000-4000-8000-000000000602"


def git(cwd, *args):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"git {args} em {cwd}: {r.stderr.strip()}")
    return r


def repo_com_main(tmp: Path) -> Path:
    tmp.mkdir(parents=True, exist_ok=True)
    origem = tmp / "origem.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origem)], check=True)
    repo = tmp / "repo"
    subprocess.run(["git", "clone", "-q", str(origem), str(repo)], check=True, capture_output=True)
    git(repo, "config", "user.email", "t@example.com")
    git(repo, "config", "user.name", "t")
    git(repo, "checkout", "-q", "-B", "main")
    (repo / "a.txt").write_text("a\n", encoding="utf-8")
    git(repo, "add", "a.txt")
    git(repo, "commit", "-q", "-m", "i")
    git(repo, "push", "-q", "origin", "main")
    git(repo, "fetch", "-q", "origin")
    return repo


def repo_simples(pasta: Path) -> Path:
    pasta.mkdir(parents=True, exist_ok=True)
    git(pasta, "init", "-q", "-b", "main")
    git(pasta, "config", "user.email", "t@example.com")
    git(pasta, "config", "user.name", "t")
    (pasta / "a.txt").write_text("a\n", encoding="utf-8")
    git(pasta, "add", "a.txt")
    git(pasta, "commit", "-q", "-m", "i")
    return pasta


def projeto(repo: Path, worktrees: Path) -> P.Projeto:
    return P.Projeto(id=ID, nome="t", repo=str(repo), worktrees=str(worktrees), padrao=True)


class InstalarArgv(unittest.TestCase):
    def test_lista_e_argv_sem_aviso(self):
        argv, aviso = watch.instalar_argv(["./scripts/instalar-no-iphone.sh", "a b"])
        self.assertEqual(argv, ["./scripts/instalar-no-iphone.sh", "a b"])
        self.assertEqual(aviso, "")

    def test_texto_antigo_parte_sem_executar_e_avisa_migracao(self):
        argv, aviso = watch.instalar_argv("echo $(touch /tmp/fra-602-pwn)")
        self.assertEqual(argv, ["echo", "$(touch", "/tmp/fra-602-pwn)"])
        self.assertNotIn("bash", argv)
        self.assertIn("migre para uma lista", aviso)
        self.assertIn("shlex.split", aviso)

    def test_aspas_no_texto_viram_um_argumento(self):
        argv, aviso = watch.instalar_argv('./x.sh "a b"')
        self.assertEqual(argv, ["./x.sh", "a b"])
        self.assertIn("migre para uma lista", aviso)

    def test_texto_vazio_nao_instala_e_nao_avisa(self):
        self.assertEqual(watch.instalar_argv(""), ([], ""))
        self.assertEqual(watch.instalar_argv("   "), ([], ""))
        self.assertEqual(watch.instalar_argv([]), ([], ""))

    def test_lista_ou_tipo_invalido_desliga(self):
        argv, aviso = watch.instalar_argv(["./x.sh", 1])
        self.assertEqual(argv, [])
        self.assertIn("lista", aviso)
        argv, aviso = watch.instalar_argv({"cmd": "./x.sh"})
        self.assertEqual(argv, [])
        self.assertIn("lista de argv", aviso)
        argv, aviso = watch.instalar_argv('./x.sh "aspas sem fechar')
        self.assertEqual(argv, [])
        self.assertIn("ilegível", aviso)


class AlvoInstalar(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.wts = self.tmp / "wts"
        self.wts.mkdir()
        self.cadastro = projeto(self.repo, self.wts)

    def test_filho_aceito_devolve_caminhos_resolvidos(self):
        wt = self.wts / "install-main"
        codigo, texto = P.checar_alvo_instalar(self.repo, wt, cadastro=self.cadastro)
        self.assertEqual(codigo, 0)
        linhas = texto.splitlines()
        self.assertEqual(Path(linhas[0]), self.repo.resolve())
        self.assertEqual(Path(linhas[1]), wt.resolve())

    def test_home_e_barra_sao_recusados(self):
        for ruim in (Path.home(), Path("/")):
            codigo, msg = P.checar_alvo_instalar(self.repo, ruim, cadastro=self.cadastro)
            self.assertNotEqual(codigo, 0, msg)
            self.assertIn("recusad", msg)

    def test_worktrees_na_barra_ou_no_home_nao_autoriza_o_filho(self):
        for raiz in (Path("/"), Path.home()):
            cad = projeto(self.repo, raiz)
            codigo, msg = P.checar_alvo_instalar(self.repo, raiz / "install-main", cadastro=cad)
            self.assertNotEqual(codigo, 0, msg)
            self.assertIn("recusad", msg)

    def test_repo_diferente_do_cadastro(self):
        codigo, msg = P.checar_alvo_instalar(self.tmp / "outro", self.wts / "install-main",
                                             cadastro=self.cadastro)
        self.assertNotEqual(codigo, 0)
        self.assertIn("repo não é o do projeto", msg)

    def test_igual_a_raiz_e_relativo_e_symlink_para_fora(self):
        codigo, msg = P.checar_alvo_instalar(self.repo, self.wts, cadastro=self.cadastro)
        self.assertNotEqual(codigo, 0)
        self.assertIn("fora", msg)
        codigo, msg = P.checar_alvo_instalar("repo", "wts/install-main", cadastro=self.cadastro)
        self.assertNotEqual(codigo, 0)
        self.assertIn("relativo", msg)
        fora = self.tmp / "fora"
        fora.mkdir()
        link = self.wts / "atalho"
        link.symlink_to(fora, target_is_directory=True)
        codigo, msg = P.checar_alvo_instalar(self.repo, link / "install-main", cadastro=self.cadastro)
        self.assertNotEqual(codigo, 0)
        self.assertIn("fora", msg)

    def test_override_nao_afrouxa_a_barra(self):
        arq = self.tmp / "cfg.json"
        arq.write_text(json.dumps({"projetos": [
            {"id": ID, "repo": "/", "worktrees": "/", "padrao": True}]}), encoding="utf-8")
        antigo = os.environ.get("TUTTIDASH_INSTALAR_CONFIG")
        os.environ["TUTTIDASH_INSTALAR_CONFIG"] = str(arq)
        self.addCleanup(self._restaurar_override, antigo)
        codigo, msg = P.checar_alvo_instalar("/", "/install-main")
        self.assertNotEqual(codigo, 0)
        self.assertIn("recusad", msg)
        os.environ["TUTTIDASH_INSTALAR_CONFIG"] = "relativo.json"
        codigo, msg = P.checar_alvo_instalar(self.repo, self.wts / "install-main")
        self.assertNotEqual(codigo, 0)
        self.assertIn("nenhum projeto", msg)

    def _restaurar_override(self, antigo):
        if antigo is None:
            os.environ.pop("TUTTIDASH_INSTALAR_CONFIG", None)
        else:
            os.environ["TUTTIDASH_INSTALAR_CONFIG"] = antigo


class InstalarSh(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = os.environ.copy()
        self.env.pop("TUTTIDASH_INSTALAR_CONFIG", None)
        self.env.pop("SKIP_PREFLIGHT", None)

    def cadastro(self, repo: Path, worktrees: Path) -> None:
        arq = self.tmp / "cadastro.json"
        arq.write_text(json.dumps({"projetos": [{
            "id": ID, "nome": "t", "padrao": True, "ativo": True,
            "repo": str(repo), "worktrees": str(worktrees)}]}), encoding="utf-8")
        self.env["TUTTIDASH_INSTALAR_CONFIG"] = str(arq)

    def rodar(self, ref, repo, wt, programa, *args):
        log = self.tmp / "logs" / "instalar.log"
        r = subprocess.run(
            ["bash", str(SCRIPT), ref, str(log), str(repo), str(wt), programa, *args],
            capture_output=True, text=True, env=self.env, timeout=60)
        texto = log.read_text(encoding="utf-8") if log.exists() else ""
        return r, texto

    def test_script_nao_chama_bash_c_e_valida_a_ref(self):
        texto = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("bash -c", texto)
        self.assertIn("git check-ref-format --branch", texto)
        self.assertIn("*'$'*", texto)
        self.assertIn("*';'*", texto)

    def test_ref_com_dolar_e_ponto_e_virgula_nao_executa(self):
        repo = repo_com_main(self.tmp / "git")
        wts = self.tmp / "wts"
        wt = repo_simples(wts / "install-main")
        precioso = wt / "nao-apagar.txt"
        precioso.write_text("fica\n", encoding="utf-8")
        pwn = self.tmp / "pwn"
        marcador = self.tmp / "rodou"
        self.cadastro(repo, wts)
        # Sem espaço: o check-ref-format deixa `$` e `;` passarem. O `$(>arquivo)`
        # criaria o arquivo se a ref fosse reavaliada pelo shell.
        ref = f"branch:x$(>{pwn});y"
        r, texto = self.rodar(ref, repo, wt, "/usr/bin/touch", str(marcador))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ref recusada", texto)
        self.assertIn("check-ref-format", texto)
        self.assertFalse(pwn.exists(), "a ref com $() não pode executar")
        self.assertFalse(marcador.exists(), "o comando não roda se a ref foi recusada")
        self.assertTrue(precioso.exists(), "git clean não roda quando a ref é recusada")
        self.assertEqual(precioso.read_text(encoding="utf-8"), "fica\n")

    def test_wt_fora_da_raiz_nao_sofre_clean(self):
        repo = repo_com_main(self.tmp / "git")
        wts = self.tmp / "wts"
        wts.mkdir()
        fora = repo_simples(self.tmp / "fora")
        precioso = fora / "nao-apagar.txt"
        precioso.write_text("fica\n", encoding="utf-8")
        marcador = self.tmp / "rodou"
        self.cadastro(repo, wts)
        r, texto = self.rodar("main", repo, fora, "/usr/bin/touch", str(marcador))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("recusad", texto)
        self.assertNotIn("ref recusada", texto)
        self.assertFalse(marcador.exists())
        self.assertTrue(precioso.exists(), "worktree fora da raiz não sofre git clean")
        self.assertEqual(precioso.read_text(encoding="utf-8"), "fica\n")

    def test_wt_igual_a_raiz_nao_sofre_clean(self):
        repo = repo_com_main(self.tmp / "git")
        wts = repo_simples(self.tmp / "wts")
        precioso = wts / "nao-apagar.txt"
        precioso.write_text("fica\n", encoding="utf-8")
        marcador = self.tmp / "rodou"
        self.cadastro(repo, wts)
        r, texto = self.rodar("main", repo, wts, "/usr/bin/touch", str(marcador))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("recusad", texto)
        self.assertFalse(marcador.exists())
        self.assertTrue(precioso.exists(), "a raiz das worktrees não sofre git clean")

    def test_argv_roda_sem_shell_dentro_do_worktree_valido(self):
        base = self.tmp / "git"
        repo = repo_com_main(base)
        wts = self.tmp / "wts"
        wts.mkdir()
        wt = wts / "install-main"
        saida = self.tmp / "args.txt"
        pwn = self.tmp / "pwn-argv"
        carga = f"$(touch {pwn});"
        self.cadastro(repo, wts)
        codigo = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])"
        r, texto = self.rodar("main", repo, wt, "/usr/bin/python3", "-c", codigo, str(saida), carga)
        self.assertEqual(r.returncode, 0, texto + r.stderr)
        self.assertEqual(saida.read_text(encoding="utf-8"), carga)
        self.assertFalse(pwn.exists(), "o argumento com $() chega literal, sem shell")
        self.assertTrue((wt / "a.txt").is_file(), "o worktree ficou na main")
        self.assertIn("[instalar] head ", texto)
        self.assertNotIn("bash -c", texto)
        self.assertNotIn("repetindo com o preflight normal", texto)


class StartInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.chamadas = []
        nomes = ["_cfg", "sh", "tmux_alive", "projeto", "LOG_FILE"]
        antes = {n: getattr(watch, n) for n in nomes}
        self.addCleanup(lambda: [setattr(watch, n, v) for n, v in antes.items()])
        watch.LOG_FILE = self.tmp / "vigia.log"
        watch.tmux_alive = lambda s: False
        watch.sh = lambda args, **k: self.chamadas.append(args) or ""

    def test_argv_vai_citado_para_o_tmux_sem_bash_c(self):
        repo = self.tmp / "repo"
        wts = self.tmp / "wts"
        repo.mkdir()
        wts.mkdir()
        watch.projeto = lambda: projeto(repo, wts)
        watch._cfg = lambda k, p: ["./scripts/instalar-no-iphone.sh", "a b"] if k == "watch.instalar_comando" else p
        st = {"installs": {}}
        self.assertTrue(watch.start_install("main", "main", None, st, []))
        self.assertEqual(len(self.chamadas), 1)
        cmdline = self.chamadas[0][-1]
        self.assertNotIn("bash -c", cmdline)
        self.assertIn(shlex.quote("./scripts/instalar-no-iphone.sh"), cmdline)
        self.assertIn(shlex.quote("a b"), cmdline)
        self.assertIn("install-main", cmdline)
        self.assertEqual(st["installs"]["atual"]["ref"], "main")

    def test_home_nao_abre_tmux(self):
        repo = self.tmp / "repo"
        repo.mkdir()
        watch.projeto = lambda: projeto(repo, Path.home())
        watch._cfg = lambda k, p: ["./x.sh"] if k == "watch.instalar_comando" else p
        st = {"installs": {}}
        self.assertFalse(watch.start_install("main", "main", None, st, []))
        self.assertEqual(self.chamadas, [])
        self.assertNotIn("atual", st["installs"])
        self.assertIn("recusada", watch.LOG_FILE.read_text(encoding="utf-8"))

    def test_texto_antigo_avisa_e_ainda_passa_argv(self):
        repo = self.tmp / "repo"
        wts = self.tmp / "wts"
        repo.mkdir()
        wts.mkdir()
        watch.projeto = lambda: projeto(repo, wts)
        watch._cfg = lambda k, p: './x.sh "a b"' if k == "watch.instalar_comando" else p
        self.assertTrue(watch.start_install("branch:feature/ok", "t", None, {"installs": {}}, []))
        log = watch.LOG_FILE.read_text(encoding="utf-8")
        self.assertIn("migre para uma lista", log)
        cmdline = self.chamadas[0][-1]
        self.assertIn(shlex.quote("./x.sh"), cmdline)
        self.assertIn(shlex.quote("a b"), cmdline)
        self.assertIn("branch:feature/ok", cmdline)
        self.assertNotIn("bash -c", cmdline)


if __name__ == "__main__":
    unittest.main()
