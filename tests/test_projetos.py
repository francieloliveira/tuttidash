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


if __name__ == "__main__":
    unittest.main()