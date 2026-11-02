"""Lanes ACP como instâncias de uma conta (PRD lanes-acp, fase 2).

A config (`lanes.acp`) só escolhe nome, agente, conta e modelo. O comando sai do
manifesto assinado; o dispatcher chama o `acp_runner.py` do bundle. A conta
partilhada entra no limite de lanes simultâneas e na medida.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gasto_lanes import catalogo as C
from gasto_lanes.config import ENV_CONFIG

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "lanes"))

import dispatcher as d  # noqa: E402

INST = [{"nome": "opencode-beam", "agente": "opencode", "modelo": "opencode/beam-free", "ligada": True},
        {"nome": "opencode-ds", "agente": "opencode", "conta": "opencode", "modelo": "opencode/deepseek-v4.1-flash"}]


class ComConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="acp-inst-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cfg = self.tmp / "config.json"
        self.escrever({"lanes": {"acp": INST}})
        antigo = os.environ.get(ENV_CONFIG)
        os.environ[ENV_CONFIG] = str(self.cfg)
        self.addCleanup(lambda: os.environ.pop(ENV_CONFIG, None) if antigo is None
                        else os.environ.__setitem__(ENV_CONFIG, antigo))

    def escrever(self, dados):
        self.cfg.write_text(json.dumps(dados), encoding="utf-8")


class ValidacaoTest(unittest.TestCase):
    def test_validas_e_padroes(self):
        inst, avisos = C.validar_instancias(INST)
        self.assertEqual(list(inst), ["opencode-beam", "opencode-ds"])
        self.assertEqual(inst["opencode-beam"]["conta"], "opencode", "conta padrão = agente")
        self.assertTrue(inst["opencode-beam"]["ligada"])
        self.assertFalse(inst["opencode-ds"]["ligada"], "ligada só com true explícito")
        self.assertEqual(avisos, [])

    def test_descartes(self):
        casos = [
            {"nome": "Opencode", "agente": "opencode"},            # maiúscula
            {"nome": "x", "agente": "opencode"},                   # curto
            {"nome": "a/b", "agente": "opencode"},                 # barra
            {"nome": "claude", "agente": "opencode"},              # colide com o catálogo
            {"nome": "auto", "agente": "opencode"},                # reservado
            {"nome": "sem-acp", "agente": "claude"},               # agente sem bloco acp
            {"nome": "nao-existe", "agente": "fantasma"},
            {"nome": "modelo-ruim", "agente": "opencode", "modelo": "x; rm -rf /"},
            "texto",
        ]
        inst, avisos = C.validar_instancias(casos, transporte="acp")
        self.assertEqual(inst, {})
        self.assertEqual(len(avisos), len(casos))

    def test_nome_repetido(self):
        inst, avisos = C.validar_instancias(INST[:1] * 2)
        self.assertEqual(list(inst), ["opencode-beam"])
        self.assertEqual(len(avisos), 1)

    def test_nao_lista(self):
        self.assertEqual(C.validar_instancias({"nome": "x"})[0], {})
        self.assertEqual(C.validar_instancias(None), ({}, []))

    def test_a_entrada_nao_traz_comando(self):
        inst, _ = C.validar_instancias([dict(INST[0], comando=["sh", "-c", "rm -rf /"], acp={"comando": ["sh"]})])
        self.assertNotIn("comando", inst["opencode-beam"])
        self.assertNotIn("acp", inst["opencode-beam"])


class CatalogoComConfigTest(ComConfig):
    def test_listas(self):
        prio = C.lanes_por_prioridade()
        self.assertEqual(prio[-2:], ("opencode-beam", "opencode-ds"), "instâncias depois do catálogo")
        self.assertIn("opencode-beam", C.lanes_implementadas())
        self.assertNotIn("opencode-beam", C.catalogo(), "o catálogo assinado não muda")

    def test_dados_e_conta(self):
        self.assertIs(C.dados_lane("opencode-beam"), C.catalogo()["opencode"])
        self.assertEqual(C.conta_da_lane("opencode-beam"), "opencode")
        self.assertEqual(C.conta_da_lane("claude"), "claude")
        self.assertEqual(C.dados_lane("nada"), {})

    def test_limite_por_conta(self):
        self.assertIsNone(C.limite_por_conta("opencode"), "sem limite é o padrão")
        self.escrever({"lanes": {"acp": INST, "limite_conta": {"opencode": 2, "x": 0, "y": True}}})
        self.assertEqual(C.limite_por_conta("opencode"), 2)
        self.assertIsNone(C.limite_por_conta("x"))
        self.assertIsNone(C.limite_por_conta("y"))

    def test_modelo_vazio_e_automatico(self):
        self.escrever({"lanes": {"acp": [{"nome": "opencode-auto", "agente": "opencode"}]}})
        self.assertEqual(C.instancia("opencode-auto")["modelo"], C.MODELO_AUTO)
        self.assertEqual(C.nome_sugerido("opencode", C.MODELO_AUTO), "opencode-auto")

    def test_chave_plana(self):
        self.escrever({"lanes.acp": INST[:1]})
        self.assertEqual(list(C.instancias_acp()), ["opencode-beam"])

    def test_sem_config(self):
        os.environ[ENV_CONFIG] = str(self.tmp / "nao-existe.json")
        self.assertEqual(C.instancias_acp(), {})
        self.assertNotIn("opencode-beam", C.lanes_por_prioridade())


class DispatcherTest(ComConfig):
    def setUp(self):
        super().setUp()
        lanes = C.lanes_por_prioridade()
        for nome, valor in (("LANES", lanes), ("IMPLEMENTED_LANES", C.lanes_implementadas())):
            p = mock.patch.object(d, nome, valor)
            p.start()
            self.addCleanup(p.stop)

    def test_comando_chama_o_runner_do_bundle(self):
        cmd = d.agent_command("opencode-beam", "medio", settings=Path("/s.json"))
        self.assertEqual(cmd[0], "/usr/bin/python3")
        self.assertTrue(cmd[1].endswith("/lanes/acp_runner.py"))
        self.assertNotIn(".transcentia", cmd[1])
        i = cmd.index
        self.assertEqual(cmd[i("--agente") + 1], "opencode")
        self.assertEqual(cmd[i("--modelo") + 1], "opencode/beam-free")
        self.assertEqual(cmd[i("--worktree") + 1], ".")
        self.assertEqual(cmd[i("--settings") + 1], "/s.json")
        texto = d.texto_do_agente("opencode-beam", "medio", Path("/run/prompt.md"))
        self.assertNotIn("$(cat", texto, "o prompt vai no stdin, não como argumento")

    def test_comando_padrao_usa_settings_assinado(self):
        with mock.patch.object(d, "caminho_settings", return_value=Path("/bundle/claude-settings.json")):
            cmd = d.agent_command("opencode-beam", "medio")
        self.assertEqual(cmd[cmd.index("--settings") + 1], "/bundle/claude-settings.json")

    def test_runner_fora_do_bundle_fecha(self):
        with mock.patch.object(d, "_AQUI", Path("/nao/existe")):
            with self.assertRaises(RuntimeError):
                d.agent_command("opencode-beam", "medio")

    def test_modelo_e_textos(self):
        self.assertEqual(d.modelo_da_lane("opencode-beam", "alto"), "opencode/beam-free")
        self.assertEqual(d.flags_da_lane("opencode-beam", "baixo"), ["-m", "opencode/beam-free"])
        self.assertEqual(d.aviso_modelo("opencode-beam", "medio"), "modelo fixo")
        self.assertIn("ACP", d.limit_text("opencode-beam", "medio"))
        self.assertTrue(d.limit_text("claude", "medio").startswith("teto US$"))

    def test_privacidade_no_modelo_da_instancia(self):
        priv = mock.Mock()
        priv.pode_receber_codigo.return_value = (False, "treina")
        with mock.patch.object(d, "privacidade", priv):
            self.assertEqual(d.privacy_block("opencode-beam", "medio"), "treina")
        priv.pode_receber_codigo.assert_called_once_with("opencode/beam-free")

    def test_automatico_segue_o_peso_como_o_agente(self):
        self.escrever({"lanes": {"acp": [{"nome": "opencode-auto", "agente": "opencode", "modelo": "auto"}]}})
        for peso in ("baixo", "medio", "alto"):
            self.assertEqual(d.modelo_da_lane("opencode-auto", peso), d.modelo_da_lane("opencode", peso), peso)
        self.assertNotEqual(d.modelo_da_lane("opencode-auto", "baixo"), d.modelo_da_lane("opencode-auto", "alto"))
        cmd = d.agent_command("opencode-auto", "alto", settings=Path("/s.json"))
        self.assertEqual(cmd[cmd.index("--modelo") + 1], d.modelo_da_lane("opencode", "alto"))
        self.assertEqual(d.aviso_modelo("opencode-auto", "medio"), "")
        priv = mock.Mock()
        priv.pode_receber_codigo.return_value = (True, "ok")
        with mock.patch.object(d, "privacidade", priv):
            self.assertIsNone(d.privacy_block("opencode-auto", "medio"))
        priv.pode_receber_codigo.assert_called_once_with(d.modelo_da_lane("opencode", "medio"))

    def test_lanes_ligadas(self):
        with mock.patch.object(d, "ENABLED_FILE", self.tmp / "enabled"):
            self.assertEqual(d.enabled_lanes(), {"opencode-beam"})
            (self.tmp / "enabled").write_text("claude opencode-ds lixo\n")
            self.assertEqual(d.enabled_lanes(), {"claude", "opencode-ds", "opencode-beam"})

    def test_medida_herdada_da_conta(self):
        m = d.medidas_com_contas({"opencode": (40, "5h"), "claude": (10, "5h")})
        self.assertEqual(m["opencode-beam"], (40, "5h"))
        self.assertEqual(m["opencode-ds"], (40, "5h"))
        self.assertNotIn("opencode-beam", d.medidas_com_contas({"claude": (1, "5h")}))

    def test_limite_herdado_da_conta(self):
        with mock.patch.object(d, "lane_limited", side_effect=lambda l: 99.0 if l == "opencode" else None):
            self.assertEqual(d.lane_limited_conta("opencode-beam"), 99.0)
            self.assertIsNone(d.lane_limited_conta("claude"))

    def test_sem_limite_por_padrao(self):
        with mock.patch.object(d, "load_state", return_value={"card": "X-1"}):
            self.assertIsNone(d.bloqueio_por_conta("opencode-beam"), "todas rodam; a cota segura")

    def test_bloqueio_por_conta(self):
        self.escrever({"lanes": {"acp": INST, "limite_conta": {"opencode": 1}}})
        rodando = set()
        with mock.patch.object(d, "load_state", side_effect=lambda l: {"card": "X-1"} if l in rodando else None):
            self.assertIsNone(d.bloqueio_por_conta("opencode-beam"))
            rodando.add("opencode")
            self.assertIn("limite 1", d.bloqueio_por_conta("opencode-beam"))
            self.assertIn("limite 1", d.bloqueio_por_conta("opencode"),
                          "a lane do catálogo também respeita a conta partilhada")
            rodando.clear()
            self.assertIn("limite 1", d.bloqueio_por_conta("opencode-ds", [("opencode-beam", {}, "medio", "")]),
                          "conta o que vai ser assumido no mesmo ciclo")
            self.assertIsNone(d.bloqueio_por_conta("claude"), "conta sem instância não muda")
            self.escrever({"lanes": {"acp": INST, "limite_conta": {"opencode": 2}}})
            rodando.add("opencode")
            self.assertIsNone(d.bloqueio_por_conta("opencode-beam"))

    def test_prompt_especifico_da_lane_acp(self):
        self.assertTrue((RAIZ / "lanes" / "lane-prompt-acp.md").is_file())
        texto = (RAIZ / "lanes" / "lane-prompt-acp.md").read_text(encoding="utf-8")
        for termo in ("comando por vez", ".lane/result.json", "Sem rede"):
            self.assertIn(termo, texto)


class SemInstanciasTest(unittest.TestCase):
    """Critério 7: sem `lanes.acp`, as lanes atuais não mudam."""

    def test_listas_iguais_ao_manifesto(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.dict(os.environ, {ENV_CONFIG: str(tmp / "vazio.json")}):
            prio = C.lanes_por_prioridade()
            esperado = tuple(n for _, n in sorted((dd["prioridade"], n) for n, dd in C.catalogo().items()
                                                  if dd["execucao"] and dd["prioridade"] is not None))
            self.assertEqual(prio, esperado)
            with mock.patch.object(d, "LANES", prio):
                self.assertIsNone(d.bloqueio_por_conta("opencode"))
                self.assertEqual(d.medidas_com_contas({"opencode": (1, "5h")}), {"opencode": (1, "5h")})


if __name__ == "__main__":
    unittest.main()


class NomeSugeridoTest(unittest.TestCase):
    def test_a_partir_do_modelo(self):
        self.assertEqual(C.nome_sugerido("opencode", "opencode/beam-free"), "opencode-beam-free")
        self.assertEqual(C.nome_sugerido("opencode", "opencode-go/DeepSeek V4.1 Flash"), "opencode-deepseek-v4-1-flash")
        self.assertEqual(C.nome_sugerido("opencode", ""), "opencode-lane")

    def test_sempre_valido_e_sem_colisao(self):
        n = C.nome_sugerido("opencode", "opencode/beam-free", usados={"opencode-beam-free"})
        self.assertEqual(n, "opencode-beam-free-2")
        longo = C.nome_sugerido("opencode", "opencode/" + "x" * 80)
        self.assertLessEqual(len(longo), 40)
        for nome in (n, longo, C.nome_sugerido("9", "/!!")):
            self.assertTrue(C.NOME_INSTANCIA.match(nome), nome)
            inst, avisos = C.validar_instancias([{"nome": nome, "agente": "opencode"}])
            self.assertIn(nome, inst, avisos)


class VigiaTest(ComConfig):
    """O vigia enxerga as lanes ACP igual ao dispatcher."""

    def setUp(self):
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location("watch_acp", RAIZ / "bots" / "watch.py")
        self.w = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.w)
        self.w.IMPLEMENTED_LANES = C.lanes_implementadas()
        self.w.LANES_CONHECIDAS = frozenset(self.w.AGENTES_NOMES) | frozenset(self.w.IMPLEMENTED_LANES)
        self.w.LANES_DIR = self.tmp
        self.w.MEDIDA_CACHE = self.tmp / "medida-cache.json"

    def test_lanes_ativas_somam_as_ligadas(self):
        self.assertEqual(self.w.lanes_ativas(), {"opencode-beam"}, "sem arquivo enabled")
        (self.tmp / "enabled").write_text("claude opencode-ds\n")
        self.assertEqual(self.w.lanes_ativas(), {"claude", "opencode-ds", "opencode-beam"})

    def test_lane_acp_ocupada(self):
        (self.tmp / "lane-opencode-beam.json").write_text(json.dumps({"card": "FRA-1"}))
        (self.tmp / "lane-intrusa.json").write_text(json.dumps({"card": "FRA-2"}))
        self.assertEqual(self.w.busy_lanes(), {"opencode-beam"})

    def test_medida_herdada(self):
        import time
        self.w.MEDIDA_CACHE.write_text(json.dumps({"at": time.time(), "m": {"opencode": [30, "5h"]}}))
        m = self.w.medidas_contas()
        self.assertEqual(m["opencode-beam"], [30, "5h"])

    def test_manifesto_da_lane_acp(self):
        self.assertTrue(self.w.esforco_suportado("opencode-beam", "medio"))
