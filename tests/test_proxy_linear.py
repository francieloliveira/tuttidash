"""FRA-607: o token do Linear não sai pelo `security`; o script fala com o proxy.

O item `linear-transcentia-lanes` não é mais lido pelos scripts. Operação fora da
allowlist é negada e registrada, sem o token no auditório nem na resposta.
"""
import importlib.util
import json
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
sys.path.insert(0, str(RAIZ / "lanes"))

import proxy_linear  # noqa: E402
import dispatcher  # noqa: E402

_spec = importlib.util.spec_from_file_location("watch_fra607", RAIZ / "bots" / "watch.py")
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)


class ProxyLinearTests(unittest.TestCase):
    def servidor(self, token, consultar):
        pasta = Path(tempfile.mkdtemp(prefix="px", dir="/tmp"))
        self.addCleanup(shutil.rmtree, pasta, True)
        caminho = pasta / "s.sock"
        auditoria = pasta / "audit.log"
        parar = threading.Event()
        pronto = threading.Event()
        thread = threading.Thread(
            target=proxy_linear.servir,
            kwargs={"token": token, "caminho": caminho, "auditoria": auditoria,
                    "consultar": consultar, "parar": parar, "pronto": pronto},
            daemon=True)
        thread.start()
        self.assertTrue(pronto.wait(3), "proxy não subiu")
        self.addCleanup(self._parar, parar, thread)
        return caminho, auditoria

    @staticmethod
    def _parar(parar, thread):
        parar.set()
        thread.join(2)

    def test_scripts_nao_leem_o_token_pelo_security(self):
        for rel in ("lanes/dispatcher.py", "bots/watch.py"):
            texto = (RAIZ / rel).read_text(encoding="utf-8")
            self.assertNotIn("find-generic-password", texto, rel)
            self.assertNotIn("add-generic-password", texto, rel)
            self.assertNotIn("/usr/bin/security", texto, rel)
            self.assertNotIn("linear-transcentia-lanes", texto, rel)
            self.assertIn("proxy_linear.executar_consulta", texto, rel)
        app = (RAIZ / "apps/notch-mac/Sources/GastoCore/Linear.swift").read_text(encoding="utf-8")
        self.assertNotIn("add-generic-password", app)
        self.assertIn("kSecUseDataProtectionKeychain", (RAIZ / "apps/notch-mac/Sources/GastoCore/Cofre.swift").read_text(encoding="utf-8"))

    def test_argv_do_servidor_nao_tem_token(self):
        segredo = "lin_api_segredo_teste"
        args = proxy_linear.argv_servidor("/usr/bin/python3", "proxy_linear.py")
        self.assertEqual(args, ["/usr/bin/python3", "proxy_linear.py", "--servir"])
        self.assertNotIn(segredo, " ".join(args))
        pedido = proxy_linear.serializar_pedido("viewer", {})
        self.assertEqual(json.loads(pedido), {"op": "viewer", "vars": {}})
        self.assertNotIn(segredo, pedido)

    def test_script_faz_a_operacao_pelo_proxy_sem_receber_o_token(self):
        token = "lin_api_segredo_teste"
        visto = {}

        def consultar(texto, variaveis, tok):
            visto["tok"] = tok
            visto["q"] = texto
            visto["v"] = variaveis
            return {"viewer": {"id": "abc", "eco": tok}}

        caminho, _ = self.servidor(token, consultar)
        original = proxy_linear.caminho_socket
        proxy_linear.caminho_socket = lambda: caminho
        try:
            dados_dispatcher = dispatcher.linear(proxy_linear.consulta("viewer"), {})
            dados_vigia = watch.linear(proxy_linear.consulta("viewer"), {})
        finally:
            proxy_linear.caminho_socket = original
        self.assertEqual(visto["tok"], token)
        self.assertEqual(proxy_linear.normalizar(visto["q"]), proxy_linear.normalizar(proxy_linear.consulta("viewer")))
        self.assertEqual(visto["v"], {})
        for dados in (dados_dispatcher, dados_vigia):
            self.assertEqual(dados["viewer"]["id"], "abc")
            self.assertEqual(dados["viewer"]["eco"], "***")
            self.assertNotIn(token, json.dumps(dados))

    def test_fora_da_allowlist_e_negada_e_auditada(self):
        token = "lin_api_segredo_teste"
        chamadas = []

        def consultar(texto, variaveis, tok):
            chamadas.append(texto)
            return {"vazio": True}

        caminho, auditoria = self.servidor(token, consultar)
        with self.assertRaises(proxy_linear.Negado) as ctx:
            proxy_linear.pedir("ler_token", {"token": token}, socket_path=caminho)
        self.assertIn("ler_token", str(ctx.exception))
        self.assertEqual(chamadas, [])
        texto = auditoria.read_text(encoding="utf-8")
        self.assertIn("ler_token", texto)
        self.assertIn("negado", texto)
        self.assertIn("fora da allowlist", texto)
        self.assertNotIn(token, texto)

    def test_consulta_desconhecida_nao_leva_o_segredo_ao_audit(self):
        token = "lin_api_segredo_teste"
        chamadas = []
        caminho, auditoria = self.servidor(token, lambda *a: chamadas.append(a) or {})
        original = proxy_linear.caminho_socket
        proxy_linear.caminho_socket = lambda: caminho
        try:
            with self.assertRaises(RuntimeError):
                dispatcher.linear(f'query {{ secret(token: "{token}") }}', {"token": token})
        finally:
            proxy_linear.caminho_socket = original
        self.assertEqual(chamadas, [])
        texto = auditoria.read_text(encoding="utf-8")
        self.assertIn("consulta-desconhecida", texto)
        self.assertIn("negado", texto)
        self.assertNotIn(token, texto)

    def test_campo_fora_do_escopo_e_negado(self):
        token = "lin_api_segredo_teste"
        chamadas = []
        caminho, auditoria = self.servidor(token, lambda *a: chamadas.append(a) or {})
        with self.assertRaises(proxy_linear.Negado):
            proxy_linear.pedir("atualizar_issue", {"id": "i", "i": {"title": "x", "token": token}},
                               socket_path=caminho)
        self.assertEqual(chamadas, [])
        texto = auditoria.read_text(encoding="utf-8")
        self.assertIn("atualizar_issue", texto)
        self.assertIn("variavel fora do escopo", texto)
        self.assertNotIn(token, texto)

    def test_consultas_do_dispatcher_e_do_vigia_estao_na_allowlist(self):
        import re
        nomes = set()
        for rel in ("lanes/dispatcher.py", "bots/watch.py", "gasto_lanes/linear_ids.py"):
            texto = (RAIZ / rel).read_text(encoding="utf-8")
            if rel.endswith("linear_ids.py"):
                continue
            nomes.update(re.findall(r'proxy_linear\.consulta\("([a-z0-9_]+)"\)', texto))
            self.assertIsNone(re.search(r'linear\(\s*[f]?["\']', texto), rel)
        for nome in nomes:
            self.assertIn(nome, proxy_linear.operacoes(), nome)
        for constante in ("Q_TIME_DO_PROJETO", "Q_ESTADOS", "Q_LABELS", "M_CRIAR_LABEL"):
            self.assertIsNotNone(proxy_linear.operacao_da_consulta(getattr(__import__("linear_ids"), constante)))

    def test_atualizacao_permitida_so_leva_os_campos_do_escopo(self):
        token = "lin_api_segredo_teste"
        visto = {}

        def consultar(texto, variaveis, tok):
            visto["v"] = variaveis
            return {"issueUpdate": {"success": True}}

        caminho, _ = self.servidor(token, consultar)
        dados = proxy_linear.pedir("atualizar_issue", {"id": "abc", "i": {"stateId": "st"}}, socket_path=caminho)
        self.assertEqual(dados, {"issueUpdate": {"success": True}})
        self.assertEqual(visto["v"], {"id": "abc", "i": {"stateId": "st"}})
        self.assertNotIn(token, json.dumps(dados))
