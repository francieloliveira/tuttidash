"""Passo 4 do PRD do norte: mapa (parte gerada) e instalador do norte (tools/instalar-norte)."""
import importlib.machinery
import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import mapa
from gasto_lanes import projetos as P

RAIZ = Path(__file__).resolve().parents[1]


def carregar_instalador():
    caminho = RAIZ / "tools" / "instalar-norte"
    loader = importlib.machinery.SourceFileLoader("instalar_norte", str(caminho))
    spec = importlib.util.spec_from_loader("instalar_norte", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


INST = carregar_instalador()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()

    def escrever(self, rel, texto=""):
        alvo = self.repo / rel
        alvo.parent.mkdir(parents=True, exist_ok=True)
        alvo.write_text(texto, encoding="utf-8")

    def projeto(self, **extra):
        return P.Projeto(id="x", nome="App", repo=str(self.repo), prova="./scripts/testar.sh {suite}", **extra)


class Mapa(Base):
    def arvore(self):
        self.escrever("apps/mac/Sources/Core/a.swift")
        self.escrever("apps/mac/Tests/CoreTests/a.swift")
        self.escrever("lanes/dispatcher.py")
        self.escrever("tests/test_x.py")
        self.escrever("node_modules/lixo/x.js")
        self.escrever(".git/HEAD")
        self.escrever("README.md")

    def test_parte_gerada_lista_modulos_e_prova(self):
        self.arvore()
        t = mapa.parte_gerada(self.repo, "./scripts/testar.sh {suite}", ["GastoCoreTests"])
        self.assertIn("## Módulos", t)
        self.assertIn("- `apps/`", t)
        self.assertIn("  - `apps/mac/`", t)
        self.assertIn("- `lanes/`", t)
        self.assertNotIn("node_modules", t)
        self.assertNotIn(".git", t)
        self.assertNotIn("- `tests/`", t.split("## Prova")[0], "teste fica na seção Prova")
        self.assertIn("- Comando: `./scripts/testar.sh {suite}`", t)
        self.assertIn("- Suíte declarada: `GastoCoreTests`", t)
        self.assertIn("- Testes em `tests/`", t)
        self.assertIn("- Testes em `apps/mac/Tests/`", t)

    def test_deterministica(self):
        self.arvore()
        self.assertEqual(mapa.parte_gerada(self.repo), mapa.parte_gerada(self.repo))

    def test_nao_segue_link(self):
        fora = self.tmp / "fora"
        (fora / "segredo").mkdir(parents=True)
        (self.repo / "atalho").symlink_to(fora)
        self.assertNotIn("atalho", mapa.parte_gerada(self.repo))

    def test_em_repositorio_git_so_entra_o_versionado(self):
        self.escrever("src/a.py")
        self.escrever("rascunho-local/x.txt")
        for args in (["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"],
                     ["config", "user.name", "t"], ["config", "commit.gpgsign", "false"],
                     ["add", "src/a.py"], ["commit", "-q", "-m", "a"]):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True)
        t = mapa.parte_gerada(self.repo)
        self.assertIn("- `src/`", t)
        self.assertNotIn("rascunho-local", t, "pasta fora do git não muda o mapa")
        self.assertIn("- `docs/`", t, "o próprio mapa já conta, para não nascer divergente")

    def test_montar_preserva_a_parte_escrita(self):
        primeiro = mapa.montar(None, "## Módulos\n- `a/`", "App")
        self.assertTrue(primeiro.startswith("# Mapa — App\n"))
        self.assertIn("## Convenções", primeiro)
        escrito = primeiro.replace("- (a escrever", "- Textos em português.\n- (a escrever")
        novo = mapa.montar(escrito, "## Módulos\n- `b/`", "App")
        self.assertIn("- `b/`", novo)
        self.assertNotIn("- `a/`", novo)
        self.assertIn("- Textos em português.", novo)
        self.assertEqual(novo.count(mapa.FIM), 1)

    def test_divergente(self):
        texto = mapa.montar(None, "## Módulos\n- `a/`", "App")
        self.assertFalse(mapa.divergente(texto, "## Módulos\n- `a/`"))
        self.assertTrue(mapa.divergente(texto, "## Módulos\n- `b/`"))
        self.assertTrue(mapa.divergente(None, "x"))
        self.assertTrue(mapa.divergente("sem marcadores", "x"))


class Instalador(Base):
    NORTE = "# Norte — App\n\n## §1 Objetivo\n\nUm app.\n"

    def test_grava_norte_mapa_e_referencias(self):
        self.escrever("src/a.py")
        escritos, avisos = INST.gravar(self.projeto(), self.repo, self.NORTE)
        self.assertEqual(sorted(escritos), sorted(["docs/produto/caminho.md", "AGENTS.md", "CLAUDE.md",
                                                   "docs/produto/mapa.md"]))
        self.assertEqual(avisos, [])
        self.assertEqual((self.repo / "docs/produto/caminho.md").read_text(), self.NORTE)
        for rel in ("AGENTS.md", "CLAUDE.md"):
            self.assertIn("docs/produto/caminho.md", (self.repo / rel).read_text())
        self.assertIn("- `src/`", (self.repo / "docs/produto/mapa.md").read_text())

    def test_referencia_acrescenta_sem_reescrever_e_sem_duplicar(self):
        self.escrever("CLAUDE.md", "# Regras\n\nUse português.\n")
        self.escrever("AGENTS.md", "Leia docs/produto/caminho.md antes.\n")
        escritos, _ = INST.gravar(self.projeto(), self.repo, self.NORTE)
        self.assertIn("CLAUDE.md", escritos)
        self.assertNotIn("AGENTS.md", escritos)
        claude = (self.repo / "CLAUDE.md").read_text()
        self.assertTrue(claude.startswith("# Regras\n\nUse português.\n"))
        self.assertIn("## Norte", claude)
        self.assertEqual((self.repo / "AGENTS.md").read_text(), "Leia docs/produto/caminho.md antes.\n")

    def test_agents_ignorado_vira_aviso(self):
        escritos, avisos = INST.gravar(self.projeto(), self.repo, self.NORTE, ignorado=lambda rel: rel == "AGENTS.md")
        self.assertNotIn("AGENTS.md", escritos)
        self.assertFalse((self.repo / "AGENTS.md").exists())
        self.assertTrue(any("copiar_para_worktree" in a for a in avisos))

    def test_norte_existente_recusa_sem_escrever(self):
        self.escrever("docs/produto/caminho.md", "norte antigo")
        with self.assertRaises(SystemExit):
            INST.gravar(self.projeto(), self.repo, self.NORTE)
        self.assertEqual((self.repo / "docs/produto/caminho.md").read_text(), "norte antigo")
        self.assertFalse((self.repo / "CLAUDE.md").exists())

    def test_norte_vazio_recusa(self):
        with self.assertRaises(SystemExit):
            INST.gravar(self.projeto(), self.repo, "  \n")

    def test_so_mapa_nao_toca_norte_nem_referencias(self):
        self.escrever("src/a.py")
        escritos, _ = INST.gravar(self.projeto(), self.repo, None)
        self.assertEqual(escritos, ["docs/produto/mapa.md"])
        escritos, _ = INST.gravar(self.projeto(), self.repo, None)
        self.assertEqual(escritos, [], "mapa em dia não reescreve")

    def test_saida_gera_mapa_a_partir_do_repo_do_projeto(self):
        self.escrever("src/a.py")
        saida = self.tmp / "saida"
        saida.mkdir()
        INST.gravar(self.projeto(), saida, self.NORTE, fonte=self.repo)
        self.assertIn("- `src/`", (saida / "docs/produto/mapa.md").read_text())

    def test_pr_em_modo_importar_nao_escreve(self):
        origem = self.tmp / "origem"
        subprocess.run(["git", "init", "-q", "-b", "main", str(origem)], check=True)
        for k, v in (("user.email", "t@example.com"), ("user.name", "t"), ("commit.gpgsign", "false")):
            subprocess.run(["git", "-C", str(origem), "config", k, v], check=True)
        (origem / "docs/produto").mkdir(parents=True)
        (origem / "docs/produto/caminho.md").write_text("norte")
        subprocess.run(["git", "-C", str(origem), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(origem), "commit", "-q", "-m", "n"], check=True)
        clone = self.tmp / "clone"
        subprocess.run(["git", "clone", "-q", str(origem), str(clone)], check=True)
        p = P.Projeto(id="x", nome="App", repo=str(clone), github="dono/app",
                      worktrees=str(self.tmp / "wts"))
        r = INST.abrir_pr(p, self.NORTE)
        self.assertIn("modo importar", r)
        self.assertFalse((self.tmp / "wts").exists(), "nenhum worktree criado")


if __name__ == "__main__":
    unittest.main()
