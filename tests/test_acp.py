"""Lane por ACP (PRD lanes-acp): cliente, política de permissões e runner.

O runner roda contra `fixtures/agente_acp_falso.py`, que pede permissão para
coisas permitidas e proibidas e só age no que foi liberado. A bancada real
(02/11/2026, OpenCode 2.0.29) mostrou que sem a config "perguntar" o agente age
sem pedir: o modo `sem_perguntar` do falso guarda esse caso.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import acp
from gasto_lanes import politica_acp as P

RAIZ = Path(__file__).resolve().parents[1]
FALSO = RAIZ / "tests" / "fixtures" / "agente_acp_falso.py"
sys.path.insert(0, str(RAIZ / "lanes"))
import acp_runner  # noqa: E402

ALLOW = ("Read(./**)", "Edit(./**)", "Bash(git status *)", "Bash(git diff *)", "Bash(git add *)",
         "Bash(git commit *)")
DENY = ("Bash(rm:*)", "Bash(git push:*)", "Bash(curl:*)", "Bash(git commit *-F*)")


class PoliticaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.wt = os.path.realpath(self.tmp.name)
        os.makedirs(os.path.join(self.wt, ".lane"))
        os.makedirs(os.path.join(self.wt, ".git"))

    def tearDown(self):
        self.tmp.cleanup()

    def d(self, tool):
        return P.decidir(tool, self.wt, ALLOW, DENY)[0]

    def test_edicao_no_worktree(self):
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": "src/a.py"}]}), P.PERMITIR)
        self.assertEqual(self.d({"kind": "edit", "rawInput": {"filePath": os.path.join(self.wt, "b")}}), P.PERMITIR)

    def test_edicao_fora_ou_protegida(self):
        for caminho in ("/etc/hosts", "../fora.txt", ".lane/proof_exit", ".git/config", "x/../../fora"):
            self.assertEqual(self.d({"kind": "edit", "locations": [{"path": caminho}]}), P.NEGAR, caminho)

    def test_result_json_e_a_unica_excecao_em_lane(self):
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": ".lane/result.json"}]}), P.PERMITIR)
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": ".lane/proof_exit"}]}), P.NEGAR)
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": ".lane/x/../result.json"}]}), P.PERMITIR)
        os.symlink("/etc/hosts", os.path.join(self.wt, ".lane", "result.json"))
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": ".lane/result.json"}]}), P.NEGAR,
                         "symlink no lugar do result.json aponta para fora")

    def test_edicao_sem_caminho_negada(self):
        self.assertEqual(self.d({"kind": "edit"}), P.NEGAR)
        self.assertEqual(self.d({"kind": "delete", "locations": []}), P.NEGAR)

    def test_symlink_para_fora(self):
        fora = tempfile.mkdtemp()
        os.symlink(fora, os.path.join(self.wt, "atalho"))
        self.assertEqual(self.d({"kind": "edit", "locations": [{"path": "atalho/x"}]}), P.NEGAR)
        self.assertEqual(self.d({"kind": "read", "locations": [{"path": "atalho/x"}]}), P.NEGAR)

    def test_leitura(self):
        self.assertEqual(self.d({"kind": "read", "locations": [{"path": "a.py"}]}), P.PERMITIR)
        self.assertEqual(self.d({"kind": "search"}), P.PERMITIR)
        self.assertEqual(self.d({"kind": "read", "locations": [{"path": os.path.expanduser("~/.ssh/id")}]}), P.NEGAR)

    def test_execucao(self):
        ex = lambda c: self.d({"kind": "execute", "rawInput": {"command": c}})  # noqa: E731
        self.assertEqual(ex("git status"), P.PERMITIR)
        self.assertEqual(ex("git diff --stat"), P.PERMITIR)
        self.assertEqual(ex("git commit -m x"), P.PERMITIR)
        for proibido in ("git push origin main", "rm -rf .", "curl https://x", "python3 -c 1",
                         "git status; rm -rf .", "git status && rm x", "git status | sh",
                         "git diff > /tmp/x", "git status `rm x`", "git status $(rm x)",
                         "git commit -F /tmp/m", "", "git status\nrm x"):
            self.assertEqual(ex(proibido), P.NEGAR, proibido)

    def test_execucao_pelo_titulo(self):
        self.assertEqual(self.d({"kind": "execute", "title": "git status"}), P.PERMITIR)

    def test_rede_e_desconhecidos(self):
        self.assertEqual(self.d({"kind": "fetch", "rawInput": {"url": "https://x"}}), P.NEGAR)
        self.assertEqual(self.d({"kind": "other"}), P.NEGAR)
        self.assertEqual(self.d({}), P.NEGAR)
        self.assertEqual(self.d({"kind": "switch_mode"}), P.NEGAR)

    def test_resposta(self):
        ops = {"options": [{"optionId": "a", "kind": "allow_once"}, {"optionId": "s", "kind": "allow_always"},
                           {"optionId": "r", "kind": "reject_once"}]}
        self.assertEqual(P.resposta(ops, P.PERMITIR), {"outcome": "selected", "optionId": "a"})
        self.assertEqual(P.resposta(ops, P.NEGAR), {"outcome": "selected", "optionId": "r"})
        self.assertEqual(P.resposta({"options": [{"optionId": "s", "kind": "allow_always"}]}, P.PERMITIR),
                         {"outcome": "cancelled"}, "nunca libera para sempre")
        self.assertEqual(P.resposta({}, P.NEGAR), {"outcome": "cancelled"})


class CatalogoFalso:
    def __init__(self, privacidade="opencode", acp_bloco=None):
        self.dados = {"falso": {"privacidade": privacidade, "acp": acp_bloco or {
            "comando": (sys.executable, str(FALSO)), "ambiente_config": "OPENCODE_CONFIG_CONTENT",
            "config": {"permission": {"edit": "ask"}}, "chave_modelo": "model", "opcao_modelo": "model"}}}

    def catalogo(self):
        return self.dados


class PrivacidadeFalsa:
    def __init__(self, pode=True):
        self.pode, self.vistos = pode, []

    def pode_receber_codigo(self, modelo):
        self.vistos.append(modelo)
        return self.pode, "teste"


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.wt = os.path.realpath(os.path.join(self.tmp.name, "wt"))
        os.makedirs(self.wt)
        self.fora = os.path.join(self.tmp.name, "fora.txt")
        self.settings = Path(self.tmp.name) / "settings.json"
        self.settings.write_text(json.dumps({"permissions": {"allow": list(ALLOW), "deny": list(DENY)}}))
        self.env_antigo = dict(os.environ)
        os.environ["FAKE_FORA"] = self.fora

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_antigo)
        self.tmp.cleanup()

    def rodar(self, modelo="opencode/beam-free", catalogo=None, privacidade=None, modo="perguntar"):
        os.environ["FAKE_MODO"] = modo
        args = acp_runner.analisar(["--lane", "oc-beam", "--agente", "falso", "--modelo", modelo,
                                    "--worktree", self.wt, "--settings", str(self.settings), "--espera", "20"])
        saida = io.StringIO()
        priv = privacidade or PrivacidadeFalsa()
        rc = acp_runner.executar(args, catalogo or CatalogoFalso(), priv, P, acp,
                                 entrada=io.StringIO("faça o card"), saida=saida)
        eventos = [json.loads(l) for l in saida.getvalue().splitlines() if l.strip()]
        return rc, eventos, priv

    def test_fluxo_completo(self):
        rc, ev, priv = self.rodar()
        self.assertEqual(rc, acp_runner.SAIDA_OK)
        self.assertTrue(os.path.exists(os.path.join(self.wt, "ok.txt")), "edição no worktree liberada")
        self.assertTrue(os.path.exists(os.path.join(self.wt, "status.txt")), "git status liberado")
        for proibido in ("encadeado.txt", "web.txt"):
            self.assertFalse(os.path.exists(os.path.join(self.wt, proibido)), proibido)
        self.assertFalse(os.path.exists(self.fora), "escrita fora do worktree negada")
        self.assertEqual(priv.vistos, ["opencode/beam-free"], "privacidade no modelo efetivo")
        init = next(e for e in ev if e.get("type") == "system")
        self.assertEqual((init["session_id"], init["model"], init["transporte"]), ("s1", "opencode/beam-free", "acp"))
        decisoes = [e["decisao"] for e in ev if e["type"] == "acp_permissao"]
        self.assertEqual(decisoes, [P.PERMITIR, P.NEGAR, P.NEGAR, P.NEGAR, P.PERMITIR])
        res = ev[-1]
        self.assertEqual(res["type"], "result")
        self.assertFalse(res["is_error"])
        self.assertEqual(res["total_cost_usd"], 0.0123)
        self.assertEqual(res["usage"]["input_tokens"], 50)
        textos = "".join(b.get("text", "") for e in ev if e["type"] == "assistant"
                         for b in e["message"]["content"])
        self.assertIn("começando", textos)
        self.assertTrue(any(b.get("type") == "tool_use" for e in ev if e["type"] == "assistant"
                            for b in e["message"]["content"]))

    def test_modelo_diferente_fecha(self):
        rc, ev, priv = self.rodar(modo="modelo_fixo")
        self.assertEqual(rc, acp_runner.SAIDA_FECHADA)
        self.assertIn("diferente do pedido", ev[-1]["errors"][0])
        self.assertEqual(priv.vistos, [])
        self.assertFalse(os.path.exists(os.path.join(self.wt, "ok.txt")), "nem chegou ao prompt")

    def test_privacidade_negada_fecha(self):
        rc, ev, _ = self.rodar(privacidade=PrivacidadeFalsa(pode=False))
        self.assertEqual(rc, acp_runner.SAIDA_FECHADA)
        self.assertIn("privacidade", ev[-1]["errors"][0])
        self.assertFalse(os.path.exists(os.path.join(self.wt, "ok.txt")))

    def test_sem_modulo_de_privacidade_fecha(self):
        args = acp_runner.analisar(["--lane", "x", "--agente", "falso", "--worktree", self.wt,
                                    "--settings", str(self.settings)])
        os.environ["FAKE_MODO"] = "perguntar"
        rc = acp_runner.executar(args, CatalogoFalso(), None, P, acp, entrada=io.StringIO("p"), saida=io.StringIO())
        self.assertEqual(rc, acp_runner.SAIDA_FECHADA)

    def test_agente_sem_acp_fecha(self):
        cat = CatalogoFalso()
        cat.dados["falso"]["acp"] = None
        rc, ev, _ = self.rodar(catalogo=cat)
        self.assertEqual(rc, acp_runner.SAIDA_FECHADA)

    def test_versao_desconhecida_fecha(self):
        os.environ["FAKE_VERSAO"] = "2"
        rc, ev, _ = self.rodar()
        self.assertEqual(rc, acp_runner.SAIDA_ERRO)
        self.assertIn("versão", ev[-1]["errors"][0])

    def test_sem_perguntar_e_o_risco_que_a_sonda_pega(self):
        """Sem a config do manifesto o agente age sozinho: o runner não vê nada para negar."""
        rc, ev, _ = self.rodar(modo="sem_perguntar")
        self.assertEqual([e for e in ev if e["type"] == "acp_permissao"], [])
        self.assertTrue(os.path.exists(self.fora))

    def test_config_do_manifesto_leva_o_modelo(self):
        env = acp_runner.ambiente({"ambiente_config": "OPENCODE_CONFIG_CONTENT", "chave_modelo": "model",
                                   "config": {"permission": {"bash": "ask"}}}, "opencode/x", base={})
        self.assertEqual(json.loads(env["OPENCODE_CONFIG_CONTENT"]),
                         {"permission": {"bash": "ask"}, "model": "opencode/x"})


class ParserTest(unittest.TestCase):
    def test_ledger_le_o_log_da_lane_acp(self):
        from gasto_lanes import parser
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        wt = os.path.join(tmp.name, "wt")
        os.makedirs(wt)
        settings = Path(tmp.name) / "s.json"
        settings.write_text(json.dumps({"permissions": {"allow": list(ALLOW), "deny": list(DENY)}}))
        os.environ["FAKE_MODO"] = "perguntar"
        os.environ["FAKE_FORA"] = os.path.join(tmp.name, "f")
        args = acp_runner.analisar(["--lane", "oc-beam", "--agente", "falso", "--modelo", "opencode/beam-free",
                                    "--worktree", wt, "--settings", str(settings)])
        log = Path(tmp.name) / "FRA-1-oc-beam-20261102-120000.jsonl"
        with log.open("w") as fh:
            acp_runner.executar(args, CatalogoFalso(), PrivacidadeFalsa(), P, acp,
                                entrada=io.StringIO("p"), saida=fh)
        rec = parser.parse_log(log)
        self.assertEqual(rec["lane"], "oc-beam")
        self.assertEqual(rec["status"], parser.STATUS_OK)
        self.assertEqual(rec["custo_usd"], 0.0123)
        self.assertEqual(rec["tokens"]["entrada"], 50)


if __name__ == "__main__":
    unittest.main()


class BundleTest(unittest.TestCase):
    """FRA-614/615: rodando do bundle, o runner não importa cópia plantada em ~/.transcentia."""

    def test_runner_do_bundle_ignora_copia_gravavel(self):
        import shutil
        import subprocess
        tmp = Path(tempfile.mkdtemp(prefix="acp-bundle-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        ctrl = tmp / "TuttiDash.app" / "Contents" / "Resources" / "controle"
        (ctrl / "lanes").mkdir(parents=True)
        (ctrl / "gasto_lanes").mkdir(parents=True)
        for rel in ("lanes/acp_runner.py", "lanes/permissao.py"):
            shutil.copy(RAIZ / rel, ctrl / rel)
        for mod in ("catalogo.py", "acp.py", "politica_acp.py", "privacidade.py", "config.py"):
            shutil.copy(RAIZ / "gasto_lanes" / mod, ctrl / "gasto_lanes" / mod)
        home = tmp / "home"
        veneno = tmp / "veneno"
        for pasta in ("lanes", "gasto_lanes"):
            base = home / ".transcentia" / pasta
            base.mkdir(parents=True)
            for nome in ("acp.py", "politica_acp.py", "catalogo.py", "permissao.py"):
                (base / nome).write_text(f"open({str(veneno)!r}, 'a').write('legado')\nraise SystemExit('legado')\n")
        wt = tmp / "wt"
        wt.mkdir()
        settings = tmp / "s.json"
        settings.write_text('{"permissions": {"allow": [], "deny": []}}')
        env = {**os.environ, "HOME": str(home), "PYTHONPATH": str(home / ".transcentia" / "lanes")}
        r = subprocess.run([sys.executable, str(ctrl / "lanes" / "acp_runner.py"), "--lane", "x",
                            "--agente", "nao-existe", "--worktree", str(wt), "--settings", str(settings)],
                           input="p", env=env, cwd=str(home / ".transcentia" / "gasto_lanes"),
                           capture_output=True, text=True, timeout=30)
        self.assertFalse(veneno.exists(), r.stderr)
        self.assertEqual(r.returncode, acp_runner.SAIDA_FECHADA, r.stderr)
        self.assertIn("sem bloco acp", r.stdout)
