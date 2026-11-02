#!/usr/bin/env python3
"""Lane ACP: o "agente" que o `run_lane.sh` executa (PRD lanes-acp).

    acp_runner.py --lane L --agente A [--modelo M] --worktree W --settings S

Lê o prompt no stdin, abre o agente do manifesto assinado (`agents.d/<A>.json`,
bloco `acp`), fala ACP com ele e escreve no stdout eventos no formato que o
`lane_view.py` e o ledger já leem (`system/init`, `assistant`, `user`,
`result`). Sai com 0 quando o agente termina o turno (`end_turn`).

Garantias:
- comando e configuração do agente só do manifesto do bundle (FRA-614); a lane
  escolhe só o modelo;
- o manifesto obriga o agente a perguntar (`acp.config`); cada pergunta passa
  por `politica_acp.decidir` com as regras do `claude-settings.json` assinado;
- privacidade conferida no modelo efetivo da sessão (`configOptions`), não só no
  pedido; modelo diferente do pedido fecha a lane.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Optional


def _ativar_modulos() -> Path:
    """Mesmo critério do dispatcher: `gasto_lanes/` do bundle ou do repo, nunca `~/.transcentia`."""
    aqui = Path(__file__).resolve().parent
    pasta = (aqui.parent / "gasto_lanes").resolve()
    if ".transcentia" in str(pasta) or not (pasta / "catalogo.py").is_file():
        sys.exit("catalogo não está no bundle; import recusado")
    resto = [p for p in sys.path if p not in (str(aqui), str(pasta)) and ".transcentia" not in p and p != ""]
    sys.path[:] = [str(aqui), str(pasta), *resto]
    return pasta


SAIDA_OK, SAIDA_ERRO, SAIDA_FECHADA, SAIDA_TEMPO = 0, 1, 3, 124


class Emissor:
    """JSONL no stdout, no formato do stream do Claude (o que o visor e o ledger leem)."""

    def __init__(self, saida=None):
        self.saida = saida or sys.stdout
        self.trava = threading.Lock()
        self.texto = ""
        self.pensa = ""
        self.ferramentas = 0
        self.custo: Optional[float] = None
        self.moeda: Optional[str] = None

    def escrever(self, ev: dict) -> None:
        with self.trava:
            self.saida.write(json.dumps(ev, ensure_ascii=False) + "\n")
            self.saida.flush()

    def _despejar(self) -> None:
        blocos = []
        if self.pensa.strip():
            blocos.append({"type": "thinking", "thinking": self.pensa})
        if self.texto.strip():
            blocos.append({"type": "text", "text": self.texto})
        self.texto = self.pensa = ""
        if blocos:
            self.escrever({"type": "assistant", "message": {"content": blocos}})

    def update(self, u: dict) -> None:
        t = u.get("sessionUpdate")
        if t == "agent_message_chunk":
            self.texto += ((u.get("content") or {}).get("text") or "")
        elif t == "agent_thought_chunk":
            self.pensa += ((u.get("content") or {}).get("text") or "")
        elif t == "tool_call":
            self._despejar()
            self.ferramentas += 1
            entrada = u.get("rawInput") if isinstance(u.get("rawInput"), dict) else {"title": u.get("title")}
            self.escrever({"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": u.get("toolCallId"),
                 "name": u.get("kind") or u.get("title") or "?", "input": entrada}]}})
        elif t == "tool_call_update" and u.get("status") == "failed":
            self.escrever({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": u.get("toolCallId"), "is_error": True,
                 "content": json.dumps(u.get("content") or u.get("rawOutput") or "falhou",
                                       ensure_ascii=False)[:500]}]}})
        elif t == "usage_update":
            c = u.get("cost") or {}
            if isinstance(c.get("amount"), (int, float)) and not isinstance(c.get("amount"), bool):
                self.custo, self.moeda = float(c["amount"]), c.get("currency")

    def fim(self, sessao: Optional[str], parada: str, uso: Optional[dict], inicio: float,
            erro: Optional[str] = None) -> None:
        self._despejar()
        ok = erro is None and parada == "end_turn"
        ev = {"type": "result", "subtype": "success" if ok else "error_during_execution",
              "is_error": not ok, "session_id": sessao, "stop_reason": parada,
              "num_turns": 1, "duration_ms": int((time.monotonic() - inicio) * 1000),
              "errors": [erro] if erro else ([parada] if not ok else [])}
        if uso:
            ev["usage"] = {"input_tokens": uso.get("inputTokens"), "output_tokens": uso.get("outputTokens"),
                           "cache_read_input_tokens": uso.get("cachedReadTokens"),
                           "cache_creation_input_tokens": uso.get("cachedWriteTokens")}
        if self.custo and self.custo > 0 and (self.moeda or "USD") == "USD":
            ev["total_cost_usd"] = self.custo
        self.escrever(ev)


def regras(settings: Path) -> tuple:
    p = json.loads(settings.read_text(encoding="utf-8")).get("permissions") or {}
    return tuple(p.get("allow") or ()), tuple(p.get("deny") or ())


def ambiente(acp: dict, modelo: str, base: Optional[dict] = None) -> dict:
    """Ambiente do agente: a config "perguntar" do manifesto, com o modelo da lane."""
    env = dict(os.environ if base is None else base)
    var = acp.get("ambiente_config")
    if var:
        cfg = json.loads(json.dumps(acp.get("config") or {}))
        if modelo and acp.get("chave_modelo"):
            cfg[acp["chave_modelo"]] = modelo
        env[var] = json.dumps(cfg, ensure_ascii=False)
    return env


def executar(args, catalogo_mod, privacidade_mod, politica, acp_mod, entrada=None, saida=None) -> int:
    inicio = time.monotonic()
    emissor = Emissor(saida)
    dados = catalogo_mod.catalogo().get(args.agente) or {}
    acp = dados.get("acp")
    if not acp or not acp.get("comando"):
        emissor.fim(None, "refusal", None, inicio, f"agente {args.agente} sem bloco acp no manifesto")
        return SAIDA_FECHADA
    worktree = str(Path(args.worktree).resolve())
    allow, deny = regras(Path(args.settings))
    texto = (entrada or sys.stdin).read()

    def permitir(params: dict) -> dict:
        tc = params.get("toolCall") or {}
        decisao, motivo = politica.decidir(tc, worktree, allow, deny)
        emissor.escrever({"type": "acp_permissao", "decisao": decisao, "motivo": motivo,
                          "kind": tc.get("kind"), "title": (tc.get("title") or "")[:200]})
        return politica.resposta(params, decisao)

    cli = acp_mod.ClienteACP(list(acp["comando"]), cwd=worktree, env=ambiente(acp, args.modelo),
                             ao_permitir=permitir, ao_evento=emissor.update, stderr=sys.stderr)
    sessao = None
    try:
        cli.abrir()
        cli.iniciar()
        nova = cli.nova_sessao(worktree)
        sessao = nova["sessionId"]
        opcao = acp.get("opcao_modelo") or "model"
        efetivo = acp_mod.modelo_da_sessao(nova, opcao)
        if args.modelo and efetivo != args.modelo:
            r = cli.definir_opcao(sessao, opcao, args.modelo)
            efetivo = acp_mod.modelo_da_sessao(r, opcao) or efetivo
        if args.modelo and efetivo != args.modelo:
            emissor.fim(sessao, "refusal", None, inicio,
                        f"modelo efetivo {efetivo!r} diferente do pedido {args.modelo!r}")
            return SAIDA_FECHADA
        if dados.get("privacidade") == "opencode":
            if privacidade_mod is None or not efetivo:
                emissor.fim(sessao, "refusal", None, inicio, "privacidade sem conferência: lane fechada")
                return SAIDA_FECHADA
            pode, motivo = privacidade_mod.pode_receber_codigo(efetivo)
            if not pode:
                emissor.fim(sessao, "refusal", None, inicio, f"privacidade: {motivo}")
                return SAIDA_FECHADA
        emissor.escrever({"type": "system", "subtype": "init", "session_id": sessao,
                          "model": efetivo, "tools": [], "transporte": "acp", "lane": args.lane,
                          "agente": args.agente})
        try:
            r = cli.prompt(sessao, texto, espera=args.espera)
        except acp_mod.ErroACP as exc:
            if "sem resposta" in str(exc):
                cli.cancelar(sessao)
                emissor.fim(sessao, "cancelled", None, inicio, f"tempo esgotado ({args.espera:.0f}s)")
                return SAIDA_TEMPO
            raise
        parada = r.get("stopReason") or "end_turn"
        emissor.fim(sessao, parada, r.get("usage"), inicio)
        return SAIDA_OK if parada == "end_turn" else SAIDA_ERRO
    except acp_mod.ErroACP as exc:
        emissor.fim(sessao, "refusal", None, inicio, str(exc))
        return SAIDA_ERRO
    finally:
        cli.fechar()


def analisar(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lane", required=True)
    ap.add_argument("--agente", required=True)
    ap.add_argument("--modelo", default="")
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--settings", required=True)
    ap.add_argument("--espera", type=float, default=3600.0)
    return ap.parse_args(argv)


def main(argv=None) -> int:
    args = analisar(argv)
    _ativar_modulos()
    import acp as acp_mod  # noqa: E402
    import catalogo  # noqa: E402
    import politica_acp  # noqa: E402
    try:
        import privacidade  # noqa: E402
    except ModuleNotFoundError:  # sem o módulo, lanes com privacidade ficam fechadas
        privacidade = None
    return executar(args, catalogo, privacidade, politica_acp, acp_mod)


if __name__ == "__main__":
    sys.exit(main())
