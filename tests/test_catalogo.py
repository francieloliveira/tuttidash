"""Catálogo de agentes (`gasto_lanes/catalogo.py`) e os manifests em `agents.d/`.

A lista de CLIs/lanes mora nos manifests. Este arquivo garante que:
  - todos os manifests são válidos e coerentes entre si;
  - o fallback embutido no Python é idêntico ao disco (paridade automática);
  - as visões derivadas (lanes do painel, implementadas, experimentais, rotação)
    saem do manifesto, e não de listas espalhadas pelo código.
"""
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import agentes as A
from gasto_lanes import catalogo as C

RAIZ = Path(__file__).resolve().parents[1]
AGENTS_D = RAIZ / "agents.d"


class ManifestoTest(unittest.TestCase):
    def setUp(self):
        self.arquivos = sorted(AGENTS_D.glob("*.json"))
        self.brutos = {json.loads(f.read_text(encoding="utf-8"))["nome"]:
                       json.loads(f.read_text(encoding="utf-8")) for f in self.arquivos}

    def test_tem_manifestos(self):
        self.assertTrue(self.arquivos, "agents.d/ está vazio")

    def test_nome_do_arquivo_bate_com_o_campo_nome(self):
        for f in self.arquivos:
            with self.subTest(arquivo=f.name):
                self.assertEqual(json.loads(f.read_text(encoding="utf-8"))["nome"],
                                 f.stem, "o arquivo precisa se chamar <nome>.json")

    def test_nomes_unicos(self):
        self.assertEqual(len(self.arquivos), len(self.brutos))

    def test_campos_obrigatorios(self):
        for nome, b in self.brutos.items():
            with self.subTest(agente=nome):
                self.assertEqual(b["schema"], C.SCHEMA_ATUAL)
                self.assertTrue(b["rotulo"])
                self.assertTrue(b["sigla"])
                self.assertIn(b["custo"], ("estimado", "informado"))
                for c in ("base", "gradiente", "claro"):
                    self.assertRegex(b["cor"][c], r"^#[0-9A-Fa-f]{6}$")
                self.assertIn("tipo", b["uso"])

    def test_ordem_e_prioridade_sem_repeticar(self):
        """`ordem` = exibição no painel; `prioridade` = rotação do dispatcher.

        São·eixos diferentes de propósito (codex aparece antes de grok no painel
        mas por último na rotação), então só importa que não repitam nem falte.
        """
        ordens = [b["ordem"] for b in self.brutos.values()]
        self.assertEqual(len(ordens), len(set(ordens)), "ordem repetida")
        lanes = {b["nome"] for b in self.brutos.values() if b.get("execucao")}
        prios = [b["prioridade"] for b in self.brutos.values() if b.get("execucao")]
        self.assertEqual(len(prios), len(set(prios)), "prioridade repetida entre lanes")
        self.assertEqual({b["nome"] for b in self.brutos.values()
                          if b.get("prioridade") is not None}, lanes,
                         "toda lane de execução precisa de prioridade, e só elas")

    def test_modelos_tem_os_tres_niveis(self):
        for nome, b in self.brutos.items():
            if not b.get("execucao"):
                continue
            with self.subTest(agente=nome):
                self.assertEqual(set(b["modelos"]), {"baixo", "medio", "alto"})

    def test_copilot_e_conta_de_uso_opt_in(self):
        bruto = self.brutos["copilot"]
        self.assertTrue(bruto["optIn"])
        self.assertFalse(bruto["painel"])
        self.assertIsNone(bruto.get("execucao"))
        self.assertIsNone(bruto.get("cli"))
        disco = C.ler_diretorio(AGENTS_D)["copilot"]
        self.assertTrue(disco["optIn"])
        self.assertFalse(disco["painel"])
        self.assertIsNone(disco["execucao"])
        self.assertNotIn("copilot", C.lanes_painel())
        self.assertNotIn("copilot", C.lanes_implementadas())

    def test_cli_existe_para_toda_lane(self):
        for nome, b in self.brutos.items():
            if b.get("execucao"):
                with self.subTest(agente=nome):
                    self.assertTrue(b["cli"], f"{nome}: lane sem CLI")
                    self.assertTrue(b["resume"], f"{nome}: lane sem --resume")


class LeitorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def escrever(self, nome, texto):
        (self.tmp / f"{nome}.json").write_text(texto, encoding="utf-8")

    def bom(self, nome="x", **extra):
        base = {"schema": 1, "nome": nome, "rotulo": "X", "sigla": "XX", "cli": "x",
                "ordem": 1, "painel": True, "execucao": "implementada",
                "cor": {"base": "#112233", "gradiente": "#112233", "claro": "#112233"},
                "custo": "estimado", "resume": "x", "pesoFontes": ["quota"]}
        base.update(extra)
        return json.dumps(base, ensure_ascii=False)

    def test_pasta_inexistente(self):
        with self.assertRaises(C.ErroCatalogo):
            C.ler_diretorio(self.tmp / "nao-existe")

    def test_pasta_vazia(self):
        with self.assertRaises(C.ErroCatalogo):
            C.ler_diretorio(self.tmp)

    def test_manifesto_ruim_nao_derruba_os_outros(self):
        self.escrever("a", self.bom("a"))
        self.escrever("b", "{ isso nao e json")
        self.escrever("c", json.dumps({"schema": 99, "nome": "c", "rotulo": "C"}))
        self.escrever("d", json.dumps({"schema": 1, "rotulo": "sem nome"}))
        self.assertEqual(list(C.ler_diretorio(self.tmp)), ["a"])

    def test_ordem_de_chamada(self):
        self.escrever("z", self.bom("z", ordem=2))
        self.escrever("a", self.bom("a", ordem=1))
        self.assertEqual(list(C.ler_diretorio(self.tmp)), ["a", "z"])

    def test_campos_normalizados(self):
        self.escrever("x", self.bom("x", uso={"tipo": "x", "fonte": "f", "credencial": "c"},
                                   modelos={"alto": {"id": "m", "flags": ["-m", "m"]}}))
        d = C.ler_diretorio(self.tmp)["x"]
        self.assertEqual(d["custo"], "estimado")
        self.assertEqual(d["peso"], ("quota",))
        self.assertEqual(d["execucao"], "implementada")
        self.assertEqual(d["uso"]["credencial"], "c")
        self.assertEqual(d["modelos"]["alto"]["flags"], ("-m", "m"))


class ParidadeTest(unittest.TestCase):
    """O que está no disco e o fallback embutido precisam ser o mesmo catálogo."""

    def setUp(self):
        C._resetar_cache()
        self.addCleanup(C._resetar_cache)
        self.disco = C.ler_diretorio(AGENTS_D)
        self.embutido = C.EMBUTIDOS

    def test_embutido_igual_ao_disco(self):
        self.assertEqual(list(self.embutido), list(self.disco))
        for nome, d in self.disco.items():
            with self.subTest(agente=nome):
                self.assertEqual(self.embutido[nome], d)

    def test_catalogo_padrao_usa_o_disco(self):
        self.assertEqual(list(C.catalogo()), list(self.disco))

    def test_views_derivadas(self):
        self.assertEqual(C.lanes_painel(),
                         tuple(n for n, d in self.disco.items() if d["painel"]))
        self.assertEqual(C.lanes_implementadas(),
                         tuple(n for n, d in self.disco.items()
                               if d["execucao"] == "implementada"))
        self.assertEqual({d["execucao"] for d in self.disco.values()} - {None}, {"implementada"})
        self.assertEqual(C.lanes_por_prioridade(),
                         tuple(n for _, n in sorted(
                             (d["prioridade"], n) for n, d in self.disco.items()
                             if d["execucao"] and d["prioridade"] is not None)))

    def test_tipos_de_conta_sem_repetir(self):
        self.assertEqual(len(set(C.tipos_conta())), len(C.tipos_conta()))

    def test_manifesto_nao_traz_id_do_linear(self):
        """FRA-565: os ids das etiquetas saem do manifesto (vêm de linear_ids)."""
        for nome, d in C.catalogo().items():
            with self.subTest(agente=nome):
                self.assertNotIn("label", d)
                self.assertEqual(C.label_de(nome), nome)


class AgentesTest(unittest.TestCase):
    """`gasto_lanes.agentes` mantém a API antiga em cima do catálogo."""

    def setUp(self):
        C._resetar_cache()
        self.addCleanup(C._resetar_cache)
        self.catalogo = C.catalogo()

    def test_conhecidos(self):
        self.assertEqual(tuple(A.AGENTES), tuple(self.catalogo))
        self.assertEqual(A.conhecidos(), tuple(self.catalogo))

    def test_custo(self):
        for nome, d in self.catalogo.items():
            with self.subTest(agente=nome):
                self.assertEqual(A.custo_para(nome), d["custo"])
        self.assertEqual(A.custo_para("desconhecido"), A.CUSTO_PADRAO_FALLBACK)

    def test_cli_e_resume(self):
        for nome, d in self.catalogo.items():
            with self.subTest(agente=nome):
                self.assertEqual(A.cli_para(nome), d["cli"] or "claude")
                self.assertEqual(A.resume_para(nome), d["resume"] or "claude")
        self.assertEqual(A.cli_para("nao-existe"), "claude")
        self.assertEqual(A.resume_para("nao-existe"), "claude")

    def test_peso(self):
        for nome, d in self.catalogo.items():
            with self.subTest(agente=nome):
                self.assertEqual(A.peso_fontes(nome), d["peso"])
        self.assertEqual(A.peso_fontes("nao-existe"), ("quota", "gasto"))


class ExecucaoRealTest(unittest.TestCase):
    """FRA-614: a cópia em ~/.transcentia/agents.d não manda no catálogo."""

    def tearDown(self):
        C._resetar_cache()

    def test_nao_le_copia_gravavel(self):
        antes = os.environ.pop("TUTTIDASH_RECURSOS", None)

        def restaurar():
            if antes is None:
                os.environ.pop("TUTTIDASH_RECURSOS", None)
            else:
                os.environ["TUTTIDASH_RECURSOS"] = antes
            C._resetar_cache()

        self.addCleanup(restaurar)
        C._resetar_cache()
        vistos = [Path(p) for p in C._diretorios()]
        for pasta in vistos:
            self.assertNotIn(".transcentia", pasta.parts, str(pasta))
        self.assertIn(AGENTS_D.resolve(), [p.resolve() for p in vistos])


if __name__ == "__main__":
    unittest.main()