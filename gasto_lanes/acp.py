"""Cliente mínimo do Agent Client Protocol (ACP) para as lanes.

O agente roda como subprocesso e fala JSON-RPC 2.0, uma mensagem por linha, no
stdin/stdout. Este módulo só faz transporte: aperto de mão, sessão, prompt e os
pedidos que o agente faz ao cliente. A decisão de permissão fica em
`politica_acp.py`; o runner da lane (`lanes/acp_runner.py`) junta os dois.

O cliente não oferece arquivo nem terminal ao agente (`fs` e `terminal` falsos):
o agente usa as ferramentas dele, e cada uma passa por `session/request_permission`
quando o manifesto o obriga a perguntar. Qualquer outro pedido do agente recebe
erro -32601. Versão do protocolo: só a 1 (a que o OpenCode e o Gemini falam).
"""
from __future__ import annotations

import json
import subprocess
import threading
import time
from typing import Callable, Optional

VERSAO_PROTOCOLO = 1


class ErroACP(RuntimeError):
    """Falha de transporte, de versão ou resposta de erro do agente."""

    def __init__(self, mensagem: str, codigo: Optional[int] = None, dados=None):
        super().__init__(mensagem)
        self.codigo = codigo
        self.dados = dados


class ClienteACP:
    """Um agente ACP num subprocesso.

    `ao_permitir(params) -> dict` responde a `session/request_permission` com o
    `outcome` do protocolo. `ao_evento(update)` recebe cada `session/update`.
    Sem `ao_permitir`, toda permissão é cancelada (falha fechada).
    """

    def __init__(self, argv: list, cwd: str, env: Optional[dict] = None,
                 ao_permitir: Optional[Callable[[dict], dict]] = None,
                 ao_evento: Optional[Callable[[dict], None]] = None,
                 stderr=None):
        if not argv:
            raise ErroACP("comando ACP vazio")
        self.argv = list(argv)
        self.cwd = cwd
        self.env = env
        self.ao_permitir = ao_permitir
        self.ao_evento = ao_evento
        self.stderr = stderr
        self.proc: Optional[subprocess.Popen] = None
        self._respostas: dict = {}
        self._cond = threading.Condition()
        self._prox_id = 0
        self._escrita = threading.Lock()
        self._fechou = False
        self.erro_leitura: Optional[str] = None

    # --- transporte -----------------------------------------------------------
    def abrir(self) -> None:
        self.proc = subprocess.Popen(
            self.argv, cwd=self.cwd, env=self.env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.stderr if self.stderr is not None else subprocess.DEVNULL,
            text=True, encoding="utf-8", errors="replace", bufsize=1)
        threading.Thread(target=self._ler, daemon=True).start()

    def _enviar(self, obj: dict) -> None:
        if self.proc is None or self.proc.stdin is None:
            raise ErroACP("agente não está aberto")
        linha = json.dumps(obj, ensure_ascii=False)
        with self._escrita:
            try:
                self.proc.stdin.write(linha + "\n")
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                raise ErroACP(f"o agente fechou a entrada: {exc}") from None

    def _ler(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        try:
            for linha in self.proc.stdout:
                linha = linha.strip()
                if not linha:
                    continue
                try:
                    msg = json.loads(linha)
                except ValueError:
                    continue          # o agente pode logar texto no stdout; ignora
                if isinstance(msg, dict):
                    self._tratar(msg)
        except Exception as exc:  # pragma: no cover - defesa
            self.erro_leitura = str(exc)
        finally:
            with self._cond:
                self._fechou = True
                self._cond.notify_all()

    def _tratar(self, msg: dict) -> None:
        metodo = msg.get("method")
        if metodo is not None and "id" in msg:
            self._pedido_do_agente(msg)
        elif metodo is not None:
            if metodo == "session/update" and self.ao_evento:
                update = (msg.get("params") or {}).get("update") or {}
                try:
                    self.ao_evento(update)
                except Exception:  # pragma: no cover - o visor não derruba a lane
                    pass
        elif "id" in msg:
            with self._cond:
                self._respostas[msg["id"]] = msg
                self._cond.notify_all()

    def _pedido_do_agente(self, msg: dict) -> None:
        metodo, mid = msg["method"], msg["id"]
        if metodo == "session/request_permission":
            try:
                outcome = self.ao_permitir(msg.get("params") or {}) if self.ao_permitir else None
            except Exception:
                outcome = None
            if not isinstance(outcome, dict):
                outcome = {"outcome": "cancelled"}
            self._enviar({"jsonrpc": "2.0", "id": mid, "result": {"outcome": outcome}})
            return
        self._enviar({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": -32601, "message": f"{metodo} não é oferecido pela lane"}})

    def chamar(self, metodo: str, params: dict, espera: float = 60.0) -> dict:
        with self._cond:
            self._prox_id += 1
            mid = self._prox_id
        self._enviar({"jsonrpc": "2.0", "id": mid, "method": metodo, "params": params})
        fim = time.monotonic() + espera
        with self._cond:
            while mid not in self._respostas:
                if self._fechou:
                    raise ErroACP(f"o agente saiu durante {metodo}")
                resta = fim - time.monotonic()
                if resta <= 0:
                    raise ErroACP(f"{metodo} sem resposta em {espera:.0f}s")
                self._cond.wait(resta)
            resp = self._respostas.pop(mid)
        if "error" in resp:
            e = resp["error"] or {}
            raise ErroACP(f"{metodo}: {e.get('message')}", e.get("code"), e.get("data"))
        return resp.get("result") or {}

    # --- protocolo -------------------------------------------------------------
    def iniciar(self, nome: str = "tuttidash-lane", versao: str = "1") -> dict:
        r = self.chamar("initialize", {
            "protocolVersion": VERSAO_PROTOCOLO,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                                   "terminal": False},
            "clientInfo": {"name": nome, "version": versao}})
        v = r.get("protocolVersion")
        if v != VERSAO_PROTOCOLO:
            raise ErroACP(f"o agente negociou a versão {v!r}; a lane só fala a {VERSAO_PROTOCOLO}")
        return r

    def nova_sessao(self, cwd: str) -> dict:
        r = self.chamar("session/new", {"cwd": cwd, "mcpServers": []})
        if not r.get("sessionId"):
            raise ErroACP("session/new sem sessionId")
        return r

    def definir_opcao(self, sessao: str, opcao: str, valor: str) -> dict:
        return self.chamar("session/set_config_option",
                           {"sessionId": sessao, "configId": opcao, "value": valor})

    def prompt(self, sessao: str, texto: str, espera: float) -> dict:
        return self.chamar("session/prompt", {"sessionId": sessao,
                                              "prompt": [{"type": "text", "text": texto}]},
                           espera=espera)

    def cancelar(self, sessao: str) -> None:
        try:
            self._enviar({"jsonrpc": "2.0", "method": "session/cancel",
                          "params": {"sessionId": sessao}})
        except ErroACP:
            pass

    def fechar(self, espera: float = 5.0) -> Optional[int]:
        if self.proc is None:
            return None
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except OSError:
            pass
        try:
            return self._esperar(espera)
        finally:
            try:
                if self.proc.stdout:
                    self.proc.stdout.close()
            except OSError:
                pass

    def _esperar(self, espera: float) -> Optional[int]:
        assert self.proc is not None
        try:
            return self.proc.wait(timeout=espera)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                return self.proc.wait(timeout=espera)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                return self.proc.wait()


def modelo_da_sessao(resposta_sessao: dict, opcao: str = "model") -> Optional[str]:
    """Valor atual da opção de modelo anunciada em `configOptions` (None se não há)."""
    for o in resposta_sessao.get("configOptions") or []:
        if isinstance(o, dict) and o.get("id") == opcao:
            v = o.get("currentValue")
            return v if isinstance(v, str) else None
    return None
