"""Cadastro de projetos (`gasto_lanes/projetos.py`).

Garante que: sem a chave `projetos` na config não há projeto (FRA-565: nada de
projeto pessoal embutido); com a chave, cada
projeto carrega repo, worktrees, prova e freio; e registro malformado não
derruba o dispatcher.
"""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import instalar
from gasto_lanes import projetos as P

IOS = "aaaaaaaa-0000-4000-8000-000000000001"
NOTCH = "aaaaaaaa-0000-4000-8000-000000000002"


class Base(unittest.TestCase):
    def setUp(self):
        P._resetar_cache()
        self.addCleanup(P._resetar_cache)

    def config(self, dados=None, texto=None, lista=None):
        """Config temporária. `lista` vira a chave `projetos`."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        arq = tmp / "config.json"
        if texto is not None:
            arq.write_text(texto, encoding="utf-8")
        elif lista is not None:
            arq.write_text(json.dumps({"projetos": lista}), encoding="utf-8")
        else:
            arq.write_text(json.dumps(dados or {}), encoding="utf-8")
        return arq

    def usar(self, config) -> list:
        """Aponta o módulo para o cadastro deste teste e devolve a lista."""
        ps = P.ler_registro([config])
        P._CACHE["lista"] = ps
        return ps


class SemCadastro(Base):
    """Sem a chave `projetos`, não há projeto (FRA-565)."""

    def test_sem_cadastro_lista_vazia_e_nenhum(self):
        self.assertEqual(P.ler_registro([self.config()]), [])
        P._CACHE["lista"] = []
        self.assertIs(P.padrao(), P.NENHUM)
        self.assertEqual(P.padrao().id, "")
        self.assertFalse(P.configurado())
        self.assertEqual(P.resumo(), "nenhum projeto cadastrado")

    def test_freio_padrao_e_generico(self):
        self.assertEqual(P.PROTEGIDOS_PADRAO, [".claude/*", ".mcp.json"])
        self.assertEqual(P.Projeto(id="x", repo="~/x").protegidos, [".claude/*", ".mcp.json"])

    def test_config_inexistente_ou_ilegivel_fica_sem_projeto(self):
        inexistente = Path(tempfile.mkdtemp()) / "nao-existe.json"
        self.addCleanup(shutil.rmtree, inexistente.parent, ignore_errors=True)
        self.assertEqual([p.id for p in P.ler_registro([inexistente])], [])
        quebrada = self.config(texto="{ nao é json")
        self.assertEqual([p.id for p in P.ler_registro([quebrada])], [])


class Cadastro(Base):
    def dois(self, **extra):
        return self.config(lista=[
            {"id": IOS, "nome": "App exemplo", "repo": "~/Developer/app-exemplo",
             "prova": "./scripts/testar.sh {suite}", "prova_tentativas": 2},
            {"id": NOTCH, "nome": "TuttiDash", "ativo": True, "padrao": True,
             "repo": "~/Developer/tuttidash", **extra},
        ])

    def test_le_todos_na_ordem_da_lista(self):
        ps = self.usar(self.dois())
        self.assertEqual([p.id for p in ps], [IOS, NOTCH])
        self.assertEqual([p.nome for p in ps], ["App exemplo", "TuttiDash"])

    def test_padrao_marcado_vence_a_ordem(self):
        ps = self.usar(self.dois())
        self.assertEqual(P.padrao(), ps[1])

    def test_sem_padrao_vale_o_primeiro_ativo(self):
        ps = self.usar(self.config(lista=[
            {"id": IOS, "repo": "~/Developer/app-exemplo"},
            {"id": NOTCH, "repo": "~/Developer/tuttidash"},
        ]))
        self.assertFalse(any(p.padrao for p in ps))
        self.assertEqual(P.padrao(), ps[0])

    def test_inativo_nao_entra_nos_ativos(self):
        ps = self.usar(self.config(lista=[
            {"id": IOS, "repo": "~/Developer/app-exemplo", "ativo": False},
            {"id": NOTCH, "repo": "~/Developer/tuttidash", "padrao": True},
        ]))
        self.assertEqual([p.id for p in P.ativos()], [NOTCH])
        self.assertEqual(P.padrao().id, NOTCH)
        self.assertEqual(len(ps), 2, "inativo continua listado para o app mostrar")

    def test_padrao_inativo_nao_vale(self):
        """Marcar `padrao` num projeto desligado não ressuscita o trabalho dele."""
        self.usar(self.config(lista=[
            {"id": IOS, "repo": "~/Developer/app-exemplo", "padrao": True, "ativo": False},
            {"id": NOTCH, "repo": "~/Developer/tuttidash"},
        ]))
        self.assertEqual(P.padrao().id, NOTCH)

    def test_ativo_ausente_presume_ativo(self):
        ps = self.usar(self.config(lista=[
            {"id": NOTCH, "repo": "~/Developer/tuttidash"}]))
        self.assertTrue(ps[0].ativo)

    def test_limites_por_projeto(self):
        p = P.ler_registro([self.config(lista=[{
            "id": NOTCH, "repo": "~/x",
            "operacao": {"budget_usd": {"baixo": 1.5, "alto": "20", "medio": -1, "x": 9},
                          "lane_timeout_min": 30, "proof_timeout_min": "45",
                          "max_lanes": 2, "max_tarefas_por_lane": 1}}])])[0]
        self.assertEqual(p.budget_usd, {"baixo": 1.5, "alto": 20.0})
        self.assertEqual((p.lane_timeout_min, p.proof_timeout_min), (30, 45))
        self.assertEqual((p.max_lanes, p.max_tarefas_por_lane), (2, 1))

    def test_limites_invalidos_herdam(self):
        p = P.Projeto(id="x", repo="~/x", operacao={"budget_usd": "x",
                                                   "lane_timeout_min": -1,
                                                   "proof_timeout_min": "abc"})
        self.assertEqual(p.budget_usd, {})
        self.assertEqual((p.lane_timeout_min, p.proof_timeout_min), (0, 0))

    def test_slug_estavel(self):
        p = P.Projeto(id="5f8bff08-72d9-4293-b1ab-17cef0af2c29", repo="~/x")
        self.assertEqual(p.slug, "5f8bff08-72d9-4293-b1ab-17cef0af2c29")
        self.assertEqual(P.Projeto(id="x/y z", repo="~/x").slug, "xyz")

    def test_multi_repo_modelo_e_copia(self):
        p = P.Projeto(id="x", repo="~/a", github="dono/a", repos=[
            {"slug": "app", "repo": "~/a", "github": "dono/a"},
            {"slug": "api", "repo": "~/b", "github": "dono/b", "prova": "go test {suite}",
             "entrega": {"classe": "servico", "subir": "python3 app.py"}},
        ])
        self.assertEqual([r.slug for r in p.repos], ["app", "api"])
        api = p.com_repositorio("api")
        self.assertEqual(api.repo.name, "b")
        self.assertEqual(api.github, "dono/b")
        self.assertEqual(api.prova, "go test {suite}")
        self.assertEqual(api.instalacao["classe"], "servico")
        self.assertEqual(api.repos, p.repos)
        self.assertEqual(p.com_repositorio("nao"), p)

    def test_planejamento_metadados(self):
        p = P.ler_registro([self.config(lista=[{
            "id": NOTCH, "repo": "~/x",
            "planejamento": {"objetivo": "  entregar  o  app  ", "situacao": "em dia",
                              "inicio": "2026-11-01", "alvo": "2026-12-01",
                              "marcos": [{"nome": " beta ", "data": "2026-11-20", "feito": True},
                                         {"nome": "", "data": "2026-11-21"},
                                         {"nome": "ruim", "data": "2026-13-01"}]}}])])[0]
        self.assertEqual(p.objetivo, "entregar o app")
        self.assertEqual(p.situacao, "em dia")
        self.assertEqual((p.inicio, p.alvo), ("2026-11-01", "2026-12-01"))
        self.assertEqual(p.marcos, [{"nome": "beta", "data": "2026-11-20", "feito": True},
                                    {"nome": "ruim", "data": "", "feito": False}])

    def test_planejamento_invalido_nao_derruba(self):
        p = P.Projeto(id="x", repo="~/x", planejamento={"objetivo": 42, "inicio": "ontem",
                                                        "alvo": "2026-13-01", "marcos": "x"})
        self.assertEqual((p.objetivo, p.inicio, p.alvo, p.marcos), ("", "", "", []))

    def test_prioridade_e_inteiro_nao_negativo(self):
        ps = self.usar(self.config(lista=[
            {"id": IOS, "repo": "~/a", "prioridade": 2},
            {"id": NOTCH, "repo": "~/b", "prioridade": -3},
            {"id": NOTCH + "x", "repo": "~/c", "prioridade": "alta"}]))
        self.assertEqual([p.prioridade for p in ps], [2, 0, 0])

    def test_copiar_para_worktree_e_lido_e_vazio_por_padrao(self):
        ps = self.usar(self.config(lista=[
            {"id": NOTCH, "repo": "~/Developer/tuttidash", "copiar_para_worktree": ["AGENTS.md", " "]},
            {"id": IOS, "repo": "~/Developer/app", "copiar_para_worktree": "AGENTS.md"}]))
        self.assertEqual(ps[0].copiar_para_worktree, ["AGENTS.md"])
        self.assertEqual(ps[1].copiar_para_worktree, [], "texto solto não vale: tem de ser lista")
        self.assertEqual(ps[0].copia().copiar_para_worktree, ["AGENTS.md"])

    def test_github_aceita_link_ou_dono_repo(self):
        n = P.normalizar_github
        self.assertEqual(n("https://github.com/Dono/App"), "dono/app")
        self.assertEqual(n("https://github.com/dono/app.git/"), "dono/app")
        self.assertEqual(n("git@github.com:dono/app.git"), "dono/app")
        self.assertEqual(n("ssh://git@github.com/dono/app.git"), "dono/app")
        self.assertEqual(n("dono/app"), "dono/app")
        for ruim in ("", "dono", "https://gitlab.com/dono/app", "dono/app/extra", "dono / app"):
            self.assertEqual(n(ruim), "", ruim)
        ps = self.usar(self.config(lista=[{"id": NOTCH, "repo": "~/r", "github": "https://github.com/dono/r"}]))
        self.assertEqual(ps[0].github, "dono/r")

    def test_antes_do_push_e_lido_e_vazio_por_padrao(self):
        ps = self.usar(self.config(lista=[
            {"id": NOTCH, "repo": "~/Developer/tuttidash", "antes_do_push": " bash tools/checar-publicacao.sh "},
            {"id": IOS, "repo": "~/Developer/app"}]))
        self.assertEqual(ps[0].antes_do_push, "bash tools/checar-publicacao.sh")
        self.assertEqual(ps[1].antes_do_push, "")

    def test_worktrees_default_deriva_do_repo(self):
        ps = self.usar(self.config(lista=[
            {"id": NOTCH, "repo": "~/Developer/tuttidash"}]))
        self.assertEqual(ps[0].worktrees.name, "tuttidash-worktrees")

    def test_prova_python_roda_uma_vez(self):
        ps = self.usar(self.dois(prova="python3 {suite}"))
        n = ps[1]
        self.assertEqual(n.prova_tentativas, 1)
        self.assertEqual(n.comando_prova("lanes/test_lanes.py"), "python3 lanes/test_lanes.py")

    def test_suite_com_espaco_sai_escapada(self):
        """A suíte é o que entra de fora; a linha do cadastro vai inteira ao shell."""
        p = P.Projeto(id="x", prova="./prova.sh test {suite}")
        self.assertEqual(p.comando_prova("Foo Bar"), "./prova.sh test 'Foo Bar'")

    def test_freio_do_projeto_sobrescreve_o_padrao(self):
        ps = self.usar(self.dois(protegidos=["apps/notch-mac/build/*"]))
        self.assertEqual(ps[1].protegidos, ["apps/notch-mac/build/*"])
        self.assertEqual(ps[0].protegidos, [".claude/*", ".mcp.json"],
                      "o freio de um projeto não vaza para o outro")

    def test_suites_padrao_do_projeto(self):
        ps = self.usar(self.dois(suites=["tests.test_parser"]))
        self.assertEqual(ps[1].suites, ["tests.test_parser"])
        self.assertEqual(ps[0].suites, [],
                      "sem chave, sem padrão: o fallback legado decide")

    def test_suites_que_nao_e_lista_e_ignorado(self):
        ps = self.usar(self.config(lista=[
            {"id": NOTCH, "repo": "~/x", "suites": "texto solto"}]))
        self.assertEqual(ps[0].suites, [])

    def test_por_id(self):
        self.usar(self.dois())
        self.assertEqual(P.por_id(NOTCH).nome, "TuttiDash")
        self.assertIsNone(P.por_id("nao-existe"))


class RegistroMalformado(Base):
    """Nada aqui pode derrubar o dispatcher: pular o que está ruim e seguir."""

    def test_sem_id_ou_sem_repo_e_pulado(self):
        ps = P.ler_registro([self.config(lista=[
            {"nome": "sem id", "repo": "~/x"},
            {"id": NOTCH, "nome": "sem repo"},
            {"id": NOTCH, "repo": "~/Developer/tuttidash"},
        ])])
        self.assertEqual([p.id for p in ps], [NOTCH])

    def test_id_duplicado_cai(self):
        ps = P.ler_registro([self.config(lista=[
            {"id": NOTCH, "repo": "~/Developer/tuttidash"},
            {"id": NOTCH, "repo": "~/outro"},
        ])])
        self.assertEqual(len(ps), 1)
        self.assertEqual(ps[0].repo.name, "tuttidash")

    def test_item_que_nao_e_objeto_nao_derruba(self):
        ps = P.ler_registro([self.config(lista=[
            "texto solto", 42, None,
            {"id": NOTCH, "repo": "~/Developer/tuttidash"},
        ])])
        self.assertEqual([p.id for p in ps], [NOTCH])

    def test_registro_vazio_ou_so_invalido_fica_sem_projeto(self):
        self.assertEqual([p.id for p in P.ler_registro([self.config(lista=[])])], [])
        self.assertEqual([p.id for p in P.ler_registro([self.config(lista=[{"nome": "x"}])])], [])

    def test_protegidos_que_nao_e_lista_e_ignorado(self):
        ps = P.ler_registro([self.config(lista=[
            {"id": NOTCH, "repo": "~/x", "protegidos": "texto solto"}])])
        self.assertEqual(ps[0].protegidos, [".claude/*", ".mcp.json"])

    def test_tentativas_zero_ou_negativa_vira_uma(self):
        ps = P.ler_registro([self.config(lista=[
            {"id": NOTCH, "repo": "~/x", "prova_tentativas": 0}])])
        self.assertEqual(ps[0].prova_tentativas, 1)


class ResumoParaLog(Base):
    def test_marca_padrao_e_inativo(self):
        self.usar(self.config(lista=[
            {"id": IOS, "nome": "App exemplo", "repo": "~/Developer/app-exemplo",
             "padrao": True},
            {"id": NOTCH, "nome": "TuttiDash", "repo": "~/Developer/tuttidash",
             "ativo": False},
        ]))
        r = P.resumo()
        self.assertIn("App exemplo", r)
        self.assertIn("padrão", r)
        self.assertIn("inativo", r)
        self.assertIn("TuttiDash", r)


class Norte(Base):
    """O norte do projeto entra sempre no freio de caminho protegido."""

    NORTE = "docs/produto/caminho.md"

    def test_sem_norte_freio_inalterado(self):
        p = P.ler_registro([self.config(lista=[{"id": NOTCH, "repo": "~/x"}])])[0]
        self.assertEqual(p.norte, "")
        self.assertEqual(p.protegidos, [".claude/*", ".mcp.json"])

    def test_norte_soma_ao_padrao(self):
        p = P.ler_registro([self.config(lista=[{"id": NOTCH, "repo": "~/x", "norte": self.NORTE}])])[0]
        self.assertEqual(p.norte, self.NORTE)
        self.assertEqual(p.protegidos, [".claude/*", ".mcp.json", self.NORTE])

    def test_norte_soma_ao_declarado_sem_trazer_o_padrao(self):
        """O declarado continua substituindo o padrão; o norte vem por cima."""
        p = P.ler_registro([self.config(lista=[
            {"id": NOTCH, "repo": "~/x", "norte": self.NORTE, "protegidos": ["build/*"]}])])[0]
        self.assertEqual(p.protegidos, ["build/*", self.NORTE])

    def test_norte_ja_declarado_nao_duplica(self):
        p = P.ler_registro([self.config(lista=[
            {"id": NOTCH, "repo": "~/x", "norte": self.NORTE, "protegidos": [self.NORTE]}])])[0]
        self.assertEqual(p.protegidos, [self.NORTE])

    def test_copia_nao_duplica_o_norte(self):
        p = P.Projeto(id="x", repo="~/x", norte=self.NORTE)
        self.assertEqual(p.copia().protegidos, p.protegidos)
        self.assertEqual(p.copia(), p)

    def test_norte_invalido_e_ignorado(self):
        for ruim in ["/etc/passwd", "~/caminho.md", "../fora.md", "docs/../x.md", "docs/",
                     "docs//x.md", "./x.md", "a\nb.md", "a\\b.md", 42, None, ""]:
            with self.subTest(ruim=ruim):
                p = P.Projeto(id="x", repo="~/x", norte=ruim)
                self.assertEqual(p.norte, "")
                self.assertEqual(p.protegidos, [".claude/*", ".mcp.json"])

    def test_dispatcher_recusa_lane_que_toca_o_norte(self):
        """O freio do dispatcher compara com fnmatch: o caminho exato do norte casa."""
        import fnmatch
        p = P.Projeto(id="x", repo="~/x", norte=self.NORTE)
        tocados = ["docs/produto/caminho.md", "docs/produto/mapa.md"]
        presos = [c for c in tocados if any(fnmatch.fnmatch(c, g) for g in p.protegidos)]
        self.assertEqual(presos, [self.NORTE])


class Instalacao(Base):
    """O cadastro da instalação (FRA-698): três classes, comandos e flags por projeto."""

    def test_sem_instalacao_o_projeto_nao_instala(self):
        p = P.ler_registro([self.config(lista=[{"id": NOTCH, "repo": "~/x"}])])[0]
        self.assertEqual(p.instalacao, {})
        self.assertEqual(instalar.de_projeto(p).classe, "nenhuma")

    def test_instalacao_vai_e_volta_do_registro(self):
        cfg = {"classe": "artefato", "instalar": ["./scripts/instalar.sh"], "destino": "/Applications/App.app"}
        ps = self.usar(self.config(lista=[{"id": NOTCH, "repo": "~/x", "entrega": cfg}]))
        self.assertEqual(ps[0].instalacao, cfg)

    def test_instalacao_texto_vira_argv_no_de_projeto(self):
        p = P.Projeto(id="x", repo="~/x",
                      instalacao={"classe": "servico", "subir": "python3 servidor.py --porta {porta}"})
        e = instalar.de_projeto(p)
        self.assertEqual(e.classe, "servico")
        self.assertEqual(e.subir, ("python3", "servidor.py", "--porta", "{porta}"))
        self.assertEqual(e.porta, 0)

    def test_instalacao_nula_nao_duplica_a_lista(self):
        p = P.Projeto(id="x", repo="~/x", instalacao=None)
        self.assertEqual(p.instalacao, {})


if __name__ == "__main__":
    unittest.main()
