"""FRA-620: prova-remota no Linux (modelo em tools/prova-remota-linux e o instalador)."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
MODELO = RAIZ / "tools" / "prova-remota-linux"
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
import projetos  # noqa: E402

# Pelo caminho: o TuttiDash tem o próprio gasto_lanes/prova_remota.py (FRA-610).
_spec_modelo = importlib.util.spec_from_file_location("prova_remota_linux", MODELO / "prova_remota.py")
p = importlib.util.module_from_spec(_spec_modelo)
_spec_modelo.loader.exec_module(p)

_carregador = importlib.machinery.SourceFileLoader("instalar_prova_remota", str(RAIZ / "tools" / "instalar-prova-remota"))
_spec = importlib.util.spec_from_loader("instalar_prova_remota", _carregador)
instalar = importlib.util.module_from_spec(_spec)
_carregador.exec_module(instalar)

APP = {"pastas_do_app": ["TranscentIA", "TranscentIATests/", "TranscentIA.xcodeproj"]}


class Classificar(unittest.TestCase):
    def test_python_scripts_docs_e_dados_ficam_verdes(self):
        r = p.classificar(["tools/poc/csi.py", "tools/poc/README.md", "scripts/x.sh",
                           "docs/a.html", "ml/config.yaml", "tools/poc/docker/mosquitto.conf",
                           ".gitignore"], APP)
        self.assertTrue(r["verde"], r["motivos"])
        self.assertEqual((r["py"], r["sh"]), (["tools/poc/csi.py"], ["scripts/x.sh"]))

    def test_pastas_do_app_vem_do_config(self):
        for nome in ("TranscentIA/Home.swift", "TranscentIA/dados.json", "TranscentIATests/x.py",
                     "TranscentIA.xcodeproj/project.pbxproj"):
            with self.subTest(nome=nome):
                r = p.classificar(["tools/a.py", nome], APP)
                self.assertFalse(r["verde"])
                self.assertIn("mexe no app", r["motivos"][0])
        # sem a pasta no config, um .json do app passaria: o config é que decide
        self.assertTrue(p.classificar(["TranscentIA/dados.json"], {})["verde"])

    def test_tipos_fora_da_lista_ficam_vermelhos_mesmo_sem_config(self):
        for nome in ("Fonte.swift", "a/Info.plist", "x/index.ts", "m.mlmodel", "Doc.docx", "Makefile"):
            with self.subTest(nome=nome):
                self.assertFalse(p.classificar([nome], {})["verde"])

    def test_a_propria_prova_fica_vermelha(self):
        for nome in (".github/workflows/prova-remota.yml", ".github/prova-remota/config.json",
                     ".github/prova-remota/prova_remota.py"):
            with self.subTest(nome=nome):
                self.assertIn("própria prova", p.classificar([nome], APP)["motivos"][0])

    def test_vazio_e_caminho_estranho(self):
        for nomes in ([], [""], ["../fora.py"], ["/etc/x.txt"]):
            with self.subTest(nomes=nomes):
                self.assertFalse(p.classificar(nomes, APP)["verde"])

    def test_config_com_traversal_e_ignorado(self):
        self.assertEqual(p.pastas_do_app({"pastas_do_app": ["../x", " App/ ", ""]}), ("App/",))


class Executar(unittest.TestCase):
    def test_compila_roda_testes_e_falha_quando_quebra(self):
        with tempfile.TemporaryDirectory() as d:
            antes = os.getcwd()
            os.chdir(d)
            self.addCleanup(os.chdir, antes)
            os.makedirs("tools/poc/sub")
            Path("tools/poc/mod.py").write_text("def soma(a, b):\n    return a + b\n")
            Path("tools/poc/test_mod.py").write_text(
                "import unittest\nimport mod\n\nclass T(unittest.TestCase):\n"
                "    def test_soma(self):\n        self.assertEqual(mod.soma(1, 2), 3)\n")
            Path("tools/poc/sub/run.sh").write_text("echo ok\n")
            self.assertEqual(p.pastas_com_testes(["tools/poc/sub/run.sh"]), ["tools/poc"])
            dados = p.classificar(["tools/poc/mod.py", "tools/poc/sub/run.sh"], {})
            self.assertEqual(p.executar(dados), 0)
            Path("tools/poc/mod.py").write_text("def soma(a, b)\n")
            self.assertEqual(p.executar(dados), 1)


class Instalador(unittest.TestCase):
    def setUp(self):
        projetos._resetar_cache()
        self.addCleanup(projetos._resetar_cache)
        projetos._CACHE["lista"] = [projetos.Projeto(
            id="abc", nome="Meu App", repo="/tmp/x",
            pastas_do_app=["App/", "App.xcodeproj", "../fora"])]

    def test_grava_os_quatro_arquivos_com_as_pastas_do_cadastro(self):
        with tempfile.TemporaryDirectory() as d:
            escritos = instalar.gravar(instalar.achar_projeto("Meu App"), Path(d))
            self.assertEqual(sorted(escritos), sorted([
                ".github/workflows/prova-remota.yml", ".github/prova-remota/prova-remota.sh",
                ".github/prova-remota/prova_remota.py", ".github/prova-remota/config.json"]))
            cfg = json.loads(Path(d, ".github/prova-remota/config.json").read_text())
            self.assertEqual(cfg["pastas_do_app"], ["App", "App.xcodeproj"])
            self.assertEqual(Path(d, ".github/prova-remota/prova_remota.py").read_bytes(),
                             (MODELO / "prova_remota.py").read_bytes())
            self.assertTrue(os.access(Path(d, ".github/prova-remota/prova-remota.sh"), os.X_OK))
            self.assertEqual(instalar.achar_projeto("abc").nome, "Meu App")
            with self.assertRaises(SystemExit):
                instalar.achar_projeto("outro")

    def test_cadastro_le_pastas_do_app(self):
        item = {"id": "x", "repo": "/tmp/x", "prova_remota": {"pastas_do_app": ["App/", 3]}}
        self.assertEqual(projetos._do_registro([item])[0].pastas_do_app, ["App"])
        self.assertEqual(projetos._do_registro([{"id": "y", "repo": "/tmp/y"}])[0].pastas_do_app, [])


class Workflow(unittest.TestCase):
    def test_modelo_seguro(self):
        texto = (MODELO / "prova-remota.yml").read_text()
        self.assertIn("pull_request:", texto)
        self.assertNotIn("pull_request_target", texto)
        self.assertIn("contents: read", texto)
        self.assertIn("persist-credentials: false", texto)
        self.assertRegex(texto, r"actions/checkout@[0-9a-f]{40}")
        self.assertNotIn("secrets.", texto)
        sh = (MODELO / "prova-remota.sh").read_text()
        for trecho in ("--network none", "--read-only", ":/src:ro", "--cap-drop ALL", "@sha256:"):
            self.assertIn(trecho, sh)


@unittest.skipUnless(shutil.which("docker") and subprocess.run(
    ["docker", "info"], capture_output=True).returncode == 0, "sem Docker ligado")
class ProvaDePontaAPonta(unittest.TestCase):
    """Repositório de teste: base com a prova instalada, head com só Python ou com o app."""

    def _repo(self, tmp: Path, muda) -> tuple[Path, Path, str, str]:
        origem = tmp / "origem"
        origem.mkdir()
        g = lambda *a: subprocess.run(["git", *a], cwd=origem, check=True, capture_output=True, text=True).stdout.strip()
        g("init", "-q", "-b", "main")
        projetos._CACHE["lista"] = [projetos.Projeto(id="t", nome="T", repo="/tmp/t", pastas_do_app=["App"])]
        instalar.gravar(instalar.achar_projeto("t"), origem)
        g("add", "-A")
        g("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        base_sha = g("rev-parse", "HEAD")
        muda(origem)
        g("add", "-A")
        g("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "head")
        head_sha = g("rev-parse", "HEAD")
        for nome, sha in (("base", base_sha), ("head", head_sha)):
            subprocess.run(["git", "clone", "-q", str(origem), str(tmp / nome)], check=True)
            subprocess.run(["git", "checkout", "-q", sha], cwd=tmp / nome, check=True)
        return tmp / "base", tmp / "head", base_sha, head_sha

    def _prova(self, muda) -> int:
        projetos._resetar_cache()
        self.addCleanup(projetos._resetar_cache)
        with tempfile.TemporaryDirectory() as d:
            base, head, bs, hs = self._repo(Path(d), muda)
            script = subprocess.run(["git", "cat-file", "-p", f"{bs}:.github/prova-remota/prova-remota.sh"],
                                    cwd=base, check=True, capture_output=True).stdout
            env = dict(os.environ, PROVA_BASE_SHA=bs, PROVA_HEAD_SHA=hs)
            return subprocess.run(["bash", "-s", "--", str(base), str(head)], input=script,
                                  env=env, capture_output=True).returncode

    def test_so_python_verde_e_app_vermelho(self):
        def python(o):
            (o / "tools").mkdir()
            (o / "tools/mod.py").write_text("def f():\n    return 1\n")
            (o / "tools/test_mod.py").write_text(
                "import unittest\nimport mod\nclass T(unittest.TestCase):\n"
                "    def test_f(self):\n        self.assertEqual(mod.f(), 1)\n")

        def app(o):
            (o / "App").mkdir()
            (o / "App/A.swift").write_text("struct A {}\n")
        self.assertEqual(self._prova(python), 0)
        self.assertEqual(self._prova(app), 1)


if __name__ == "__main__":
    unittest.main()
