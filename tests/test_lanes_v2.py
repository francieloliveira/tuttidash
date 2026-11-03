"""Lanes v2, fase 1 (PRD `prd-lanes-v2.md`): Conta → N lanes, para qualquer agente.

Uma instância (`lanes.instancias`) é uma lane a mais de qualquer agente com execução. A
config escolhe só nome, agente, conta, modelo e se está ligada; comando e flags saem do
manifesto assinado. O dispatcher decide o comando pelo CLI da lane, não pelo nome.
"""
import json
import os
import re
import shutil
import subprocess
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

INST = [
    {"nome": "claude-sonnet", "agente": "claude", "ligada": True},
    {"nome": "claude-auto", "agente": "claude"},
    {"nome": "codex-2", "agente": "codex"},
    {"nome": "grok-2", "agente": "grok"},
    {"nome": "opencode-free2", "agente": "opencode"},
    {"nome": "go-kimi", "agente": "opencode-go", "modelo": "opencode-go/kimi-k3"},
    {"nome": "deepseek-2", "agente": "deepseek"},
]
MODELO = {"claude-sonnet": {"modo": "fixo", "fixo": "sonnet"},
          "claude-auto": {"modo": "auto", "porPeso": {"alto": {"modelo": "opus", "esforco": "high"}}}}


class ComConfig(unittest.TestCase):
    dados = {"lanes": {"instancias": INST, "modelo": MODELO}}

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lanes-v2-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cfg = self.tmp / "config.json"
        self.escrever(self.dados)
        p = mock.patch.dict(os.environ, {ENV_CONFIG: str(self.cfg)})
        p.start()
        self.addCleanup(p.stop)
        for nome, valor in (("LANES", C.lanes_por_prioridade()),
                            ("IMPLEMENTED_LANES", C.lanes_implementadas()),
                            ("CONFIG_FILES", [self.cfg])):
            q = mock.patch.object(d, nome, valor)
            q.start()
            self.addCleanup(q.stop)
        c = mock.patch.object(d, "_cache_modelos", return_value={})
        c.start()
        self.addCleanup(c.stop)

    def escrever(self, dados):
        self.cfg.write_text(json.dumps(dados), encoding="utf-8")


class ValidacaoTest(unittest.TestCase):
    def test_qualquer_agente_com_execucao(self):
        inst, avisos = C.validar_instancias(INST)
        self.assertEqual(list(inst), [i["nome"] for i in INST])
        self.assertEqual(avisos, [])
        self.assertTrue(all(i["transporte"] == "cli" for i in inst.values()))

    def test_conta_padrao_vem_do_manifesto(self):
        inst, _ = C.validar_instancias(INST)
        self.assertEqual(inst["claude-sonnet"]["conta"], "claude")
        self.assertEqual(inst["go-kimi"]["conta"], "opencode", "Q1: OpenCode Go é lane da conta OpenCode")

    def test_descartes(self):
        casos = [
            {"nome": "cur", "agente": "cursor"},                      # sem execução
            {"nome": "gem", "agente": "gemini"},                      # sem execução
            {"nome": "cl-acp", "agente": "claude", "transporte": "acp"},   # sem bloco acp
            {"nome": "cl-x", "agente": "claude", "transporte": "ssh"},
            {"nome": "cl-flag", "agente": "claude", "modelo": "--dangerously-skip-permissions"},
            {"nome": "cl-conta", "agente": "claude", "conta": "../../etc"},
            {"nome": "cl-conta2", "agente": "claude", "conta": "fantasma"},
            {"nome": "opencode-go", "agente": "opencode"},           # nome do catálogo
        ]
        inst, avisos = C.validar_instancias(casos)
        self.assertEqual(inst, {})
        self.assertEqual(len(avisos), len(casos), avisos)

    def test_entrada_nao_escolhe_comando(self):
        inst, _ = C.validar_instancias([dict(INST[0], comando=["sh"], cli="sh", flags=["--x"])])
        self.assertEqual(set(inst["claude-sonnet"]),
                         {"nome", "agente", "conta", "modelo", "ligada", "transporte"})


class CatalogoTest(ComConfig):
    def test_listas_e_perfis(self):
        prio = C.lanes_por_prioridade()
        self.assertEqual(prio[-len(INST):], tuple(i["nome"] for i in INST))
        self.assertEqual(C.perfil_da_lane("claude-sonnet"), "claude")
        self.assertEqual(C.perfil_da_lane("claude"), "claude")
        self.assertEqual(C.cli_da_lane("go-kimi"), "opencode")
        self.assertEqual(C.cli_da_lane("deepseek-2"), "dsh")
        self.assertEqual(C.cli_da_lane("opencode-go"), "opencode")
        self.assertEqual(C.conta_da_lane("opencode-go"), "opencode")
        self.assertEqual(C.conta_da_lane("codex-2"), "codex")
        self.assertEqual(C.transporte_da_lane("claude-sonnet"), "cli")

    def test_chave_acp_continua_valendo(self):
        self.escrever({"lanes": {"instancias": INST[:1],
                                 "acp": [{"nome": "opencode-1", "agente": "opencode", "ligada": True},
                                         {"nome": "claude-sonnet", "agente": "opencode"}]}})
        inst = C.instancias()
        self.assertEqual(list(inst), ["claude-sonnet", "opencode-1"], "nome repetido fica com o primeiro")
        self.assertEqual(inst["opencode-1"]["transporte"], "acp")
        self.assertEqual(inst["claude-sonnet"]["agente"], "claude")

    def test_limite_por_conta_nova_chave(self):
        self.escrever({"lanes": {"instancias": INST, "limite_conta": {"claude": 2},
                                 "acp_limite_conta": {"opencode": 1}}})
        self.assertEqual(C.limite_por_conta("claude"), 2)
        self.assertIsNone(C.limite_por_conta("opencode"),
                          "a chave do piloto (padrão antigo 1) não limita mais a conta")
        self.assertIsNone(C.limite_por_conta("codex"))

    def test_gravar_ligada(self):
        self.assertTrue(C.gravar_ligada("claude-auto", True, self.cfg))
        self.assertIn("claude-auto", C.instancias_ligadas())
        self.assertTrue(C.gravar_ligada("claude-sonnet", False, self.cfg))
        self.assertNotIn("claude-sonnet", C.instancias_ligadas())
        self.assertFalse(C.gravar_ligada("nao-existe", True, self.cfg))
        self.assertEqual(json.loads(self.cfg.read_text())["lanes"]["modelo"], MODELO, "o resto fica")


class ComandoTest(ComConfig):
    def test_claude_fixo(self):
        with mock.patch.object(d, "caminho_settings", return_value=Path("/b/s.json")), \
                mock.patch.object(d, "caminho_controle", return_value=Path("/b/mcp.json")):
            cmd = d.agent_command("claude-sonnet", "alto")
            base = d.agent_command("claude", "alto")
        self.assertEqual(cmd[:2], ["claude", "-p"])
        self.assertEqual(cmd[cmd.index("--model") + 1], "sonnet")
        self.assertEqual(d.aviso_modelo("claude-sonnet", "baixo"), "modelo fixo")
        tirar = lambda c: [x for x in c if x not in ("sonnet", "opus") and not x.startswith(("medium", "high", "xhigh"))]
        self.assertEqual(tirar(cmd[:cmd.index("--model")]), tirar(base[:base.index("--model")]),
                         "mesmo comando do agente, só o modelo muda")

    def test_claude_por_peso(self):
        self.assertEqual(d.modelo_da_lane("claude-auto", "alto"), "opus")
        self.assertEqual(d.modelo_da_lane("claude-auto", "baixo"), C.modelo_de_effort("claude", "baixo"))

    def test_opencode_e_go(self):
        cmd = d.agent_command("opencode-free2", "medio")
        self.assertEqual(cmd[:4], ["opencode", "run", "--format", "json"])
        self.assertEqual(cmd[-1], C.modelo_de_effort("opencode", "medio"))
        self.assertEqual(d.agent_command("go-kimi", "baixo")[-1], "opencode-go/kimi-k3")
        for lane in ("opencode-free2", "go-kimi", "opencode", "opencode-go"):
            texto = d.texto_do_agente(lane, "medio", Path("/run/prompt.md"))
            self.assertTrue(texto.endswith('-- "$(cat /run/prompt.md)"'), lane)

    def test_codex_grok_dsh(self):
        self.assertEqual(d.agent_command("codex-2", "medio")[:3], ["codex", "exec", "--json"])
        with mock.patch.object(d, "lane_permissions", return_value={"allow": [], "deny": []}):
            self.assertEqual(d.agent_command("grok-2", "medio", prompt=Path("/run/p.md"))[0], "grok")
        cmd = d.agent_command("deepseek-2", "medio", patch=Path("/run/d.yml"))
        self.assertEqual(cmd[0], "dsh")
        self.assertIn("deepseek", d.deepseek_patch("medio", "deepseek-2"))
        self.assertEqual(d.limit_text("deepseek-2", "medio"), "sem teto de gasto no CLI")
        self.assertTrue(d.limit_text("grok-2", "medio").startswith("limite"))
        self.assertTrue(d.limit_text("claude-sonnet", "medio").startswith("teto US$"))

    def test_acp_continua_no_runner(self):
        self.escrever({"lanes": {"acp": [{"nome": "opencode-1", "agente": "opencode"}]}})
        cmd = d.agent_command("opencode-1", "medio", settings=Path("/s.json"))
        self.assertTrue(cmd[1].endswith("/lanes/acp_runner.py"))

    def test_lane_desconhecida(self):
        with self.assertRaises(NotImplementedError):
            d.agent_command("cursor", "medio")

    def test_risco_alto_herda_do_agente(self):
        self.assertTrue(d.risco_alto("claude-sonnet"))
        self.assertTrue(d.risco_alto("grok-2"))
        self.assertFalse(d.risco_alto("codex-2"))

    def test_bancada_so_no_cli_claude(self):
        card = {"labels": {"nodes": [{"name": d.ETIQUETA_BANCADA}]}}
        with mock.patch.object(d, "projeto", return_value=mock.Mock(bancada=True)):
            self.assertTrue(d.bancada_ativa("claude-sonnet", card))
            self.assertFalse(d.bancada_ativa("codex-2", card))


class SemNomeFixoTest(unittest.TestCase):
    """Seção 4 do PRD: nenhum ramo decide pelo nome da lane (`lane == "claude"`)."""
    PADRAO = re.compile(r"""(\blane|\[["']lane["']\])\s*(==|!=)\s*["'](claude|codex|grok|opencode|opencode-go|deepseek)["']"""
                        r"""|\$LANE"\s*=\s*"(claude|codex|grok|opencode|deepseek)""")

    def test_dispatcher_e_runner(self):
        for rel in ("lanes/dispatcher.py", "lanes/run_lane.sh"):
            texto = (RAIZ / rel).read_text(encoding="utf-8")
            achados = [l.strip() for l in texto.splitlines() if self.PADRAO.search(l)]
            self.assertEqual(achados, [], rel)


@unittest.skipUnless(Path("/bin/bash").exists(), "sem bash")
class RunLaneCliTest(unittest.TestCase):
    def test_cli_desconhecido_recusa(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "cmd").write_text("true\n")
        r = subprocess.run(["/bin/bash", str(RAIZ / "lanes/run_lane.sh"), "x-1", str(tmp), "C-1",
                            str(tmp / "log"), str(tmp / "cmd"), str(tmp), "sh"],
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 1)
        self.assertIn("cli desconhecido", r.stderr)


import datetime as dt  # noqa: E402

import teste_simultaneo as TS  # noqa: E402

TRAVA = ('if mkdir "$TRAVA" 2>/dev/null; then sleep 1; rmdir "$TRAVA"; echo OK; '
         'else echo "Error: database is locked"; exit 1; fi')


class SimultaneoRegistroTest(unittest.TestCase):
    """Fase 2: o registro por conta e a leitura que o dispatcher faz dele."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="simultaneo-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_situacoes(self):
        self.assertEqual(TS.situacao("claude", self.tmp)[0], "pendente")
        TS.gravar("claude", {"ok": True}, self.tmp)
        self.assertEqual(TS.situacao("claude", self.tmp)[0], "aprovado")
        futuro = dt.datetime.now() + dt.timedelta(days=TS.VALIDADE_DIAS + 1)
        self.assertEqual(TS.situacao("claude", self.tmp, futuro)[0], "vencido")
        TS.gravar("claude", {"ok": False, "motivo": "simultânea 2: saída fala de 'database is locked'"}, self.tmp)
        estado, texto = TS.situacao("claude", self.tmp)
        self.assertEqual(estado, "reprovado")
        self.assertIn("database is locked", texto)
        self.assertEqual(oct(TS.arquivo("claude", self.tmp).stat().st_mode & 0o777), "0o600")

    def test_conta_invalida(self):
        with self.assertRaises(ValueError):
            TS.arquivo("../x", self.tmp)

    def test_avaliar(self):
        self.assertIsNone(TS.avaliar(0, '{"type":"result","result":"OK"}'))
        self.assertEqual(TS.avaliar(None, ""), "não terminou no tempo")
        self.assertIn("database is locked", TS.avaliar(0, "Error: database is locked"))
        self.assertIn("Not logged in", TS.avaliar(1, "Not logged in. Run login."))
        self.assertTrue(TS.avaliar(2, "falhou\n").startswith("código 2"))
        self.assertEqual(TS.avaliar(0, ""), "saiu com código 0 sem responder OK")


class SimultaneoExecucaoTest(ComConfig):
    """A execução de verdade, com um CLI falso que trava um recurso partilhado."""

    def rodar_com(self, script):
        trava = self.tmp / "trava"
        with mock.patch.object(d, "texto_do_agente", return_value=script), \
                mock.patch.dict(os.environ, {"TRAVA_DIR": str(trava)}), \
                mock.patch.object(TS, "ambiente", return_value={"PATH": "/usr/bin:/bin",
                                                                 "TRAVA": str(trava),
                                                                 "HOME": str(self.tmp)}):
            return TS.executar("codex-2", d, espera=30)

    def test_aprova_quando_aguenta(self):
        r = self.rodar_com("cat >/dev/null; echo OK")
        self.assertTrue(r["ok"], r)
        self.assertEqual([x["rodada"] for x in r["rodadas"]],
                         ["simultânea 1", "simultânea 2", "depois (login continua)"])
        self.assertEqual(r["cli"], "codex")

    def test_reprova_com_recurso_travado(self):
        r = self.rodar_com(TRAVA)
        self.assertFalse(r["ok"])
        self.assertIn("database is locked", r["motivo"])

    def test_reprova_quando_a_terceira_perde_o_login(self):
        marca = self.tmp / "rodou"
        script = (f'if [ -e {marca}2 ]; then echo "not logged in"; exit 1; fi; '
                  f'if [ -e {marca} ]; then touch {marca}2; else touch {marca}; fi; echo OK')
        r = self.rodar_com(script)
        self.assertFalse(r["ok"])
        self.assertIn("depois", r["motivo"])


class SimultaneoDispatcherTest(ComConfig):
    dados = {"lanes": {"instancias": [{"nome": "claude-sonnet", "agente": "claude", "ligada": True}]}}

    def setUp(self):
        super().setUp()
        for nome, valor in (("STATE_DIR", self.tmp), ("ENABLED_FILE", self.tmp / "enabled")):
            q = mock.patch.object(d, nome, valor)
            q.start()
            self.addCleanup(q.stop)
        (self.tmp / "enabled").write_text("claude opencode opencode-go\n")
        self.rodando = set()
        q = mock.patch.object(d, "load_state", side_effect=lambda l: {"card": "X-1"} if l in self.rodando else None)
        q.start()
        self.addCleanup(q.stop)

    def test_extra_sem_teste_roda_uma_por_vez(self):
        self.assertIsNone(d.bloqueio_por_conta("claude-sonnet"), "nada rodando")
        self.rodando.add("claude")
        motivo = d.bloqueio_por_conta("claude-sonnet")
        self.assertIn("limite 1", motivo)
        self.assertIn("teste_simultaneo.py", motivo)

    def test_teste_aprovado_libera(self):
        TS.gravar("claude", {"ok": True}, self.tmp)
        self.rodando.add("claude")
        self.assertIsNone(d.bloqueio_por_conta("claude-sonnet"))

    def test_teste_reprovado_trava_ate_o_par_do_catalogo(self):
        self.rodando.add("opencode")
        self.assertIsNone(d.bloqueio_por_conta("opencode-go"), "o par do catálogo já rodava junto")
        TS.gravar("opencode", {"ok": False, "motivo": "simultânea 2: código 1"}, self.tmp)
        self.assertIn("reprovado", d.bloqueio_por_conta("opencode-go"))

    def test_extra_desligada_nao_trava(self):
        self.escrever({"lanes": {"instancias": [{"nome": "claude-sonnet", "agente": "claude"}]}})
        self.rodando.add("claude")
        self.assertIsNone(d.bloqueio_por_conta("claude-sonnet"))

    def test_limite_explicito_menor_vence(self):
        self.escrever({"lanes": {"instancias": [{"nome": "claude-sonnet", "agente": "claude", "ligada": True},
                                                {"nome": "claude-3", "agente": "claude", "ligada": True}],
                                 "limite_conta": {"claude": 2}}})
        TS.gravar("claude", {"ok": True}, self.tmp)
        with mock.patch.object(d, "LANES", C.lanes_por_prioridade()):
            self.rodando.update({"claude", "claude-sonnet"})
            self.assertIn("limite 2", d.bloqueio_por_conta("claude-3"))


if __name__ == "__main__":
    unittest.main()
