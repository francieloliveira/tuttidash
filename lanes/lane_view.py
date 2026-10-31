#!/usr/bin/env python3
"""Formata o stream-json do agente para leitura humana na janela da lane.

Mostra, além das chamadas de ferramenta: o **raciocínio** do agente (blocos
`thinking`) e o **diff de cada edição**, para acompanhar a lane sem abrir o log
bruto. No fim, o total de arquivos tocados e de linhas somadas/tiradas.

Ajustes no TuttiDash (Ajustes > Painel), lidos a cada evento — mudar o ajuste
vale na hora, sem reiniciar a lane:
  lane_view.pensamento         mostra o raciocínio do agente          [sim]
  lane_view.pensamento_linhas  linhas de raciocínio por bloco         [14]
  lane_view.diff               mostra o diff de cada edição           [sim]
  lane_view.diff_linhas        linhas de diff por edição              [14]

As variáveis de ambiente LANE_VIEW_PENSA, LANE_VIEW_PENSA_LINHAS, LANE_VIEW_DIFF e
LANE_VIEW_DIFF_LINHAS continuam valendo e passam na frente do TuttiDash (uso pontual).
"""
from __future__ import annotations

import difflib
import json
import os
import runpy
import shutil
import sys
import textwrap

DIM, BOLD, RESET = "\033[2m", "\033[1m", "\033[0m"
VERDE, VERMELHO, CIANO = "\033[32m", "\033[31m", "\033[36m"

# Ferramentas equivalentes nas duas lanes (Claude Code e Grok Build).
EDITA = {"search_replace", "Edit", "str_replace", "str_replace_editor"}
ESCREVE = {"write", "Write", "create_file"}
LE = {"read_file", "Read"}


def largura(padrao: int = 100) -> int:
    try:
        return max(40, shutil.get_terminal_size().columns)
    except OSError:
        return padrao


def _caminho_cfg() -> str:
    """`tools/cfg` do checkout, ou a cópia instalada. O cfg usa o resolvedor único."""
    local = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "cfg"))
    if os.path.isfile(local):
        return local
    return os.path.expanduser("~/.transcentia/tools/cfg")


CFG = _caminho_cfg()
_CFG: dict = {}
DESLIGADO = ("0", "false", "nao", "não", "off", "")


def cfg_get(chave: str, padrao):
    """Valor no TuttiDash. O `get` do cfg relê o arquivo a cada chamada, então
    o ajuste vale na hora. Sem cfg (ou com cfg quebrado), fica o padrão."""
    if "get" not in _CFG:
        try:
            _CFG["get"] = runpy.run_path(CFG)["get"] if os.path.exists(CFG) else None
        except Exception:
            _CFG["get"] = None
    obter = _CFG["get"]
    if obter is None:
        return padrao
    try:
        return obter(chave, padrao)
    except Exception:
        return padrao


def opcao(chave: str, env: str, padrao: int) -> int:
    """Quantas linhas mostrar. O ambiente passa na frente do TuttiDash."""
    bruto = os.environ.get(env)
    if bruto is None:
        bruto = cfg_get(chave, padrao)
    try:
        return max(0, int(bruto))
    except (TypeError, ValueError):
        return padrao


def ligado(chave: str, env: str) -> bool:
    """Liga/desliga uma parte da janela. O ambiente passa na frente do TuttiDash."""
    bruto = os.environ.get(env)
    if bruto is None:
        bruto = cfg_get(chave, True)
    if isinstance(bruto, bool):
        return bruto
    return str(bruto).strip().lower() not in DESLIGADO


def short(v, n: int = 140) -> str:
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def cortar(texto: str, cols: int) -> str:
    """Corta pelo comprimento visível; a linha do diff não quebra."""
    return texto if len(texto) <= cols else texto[: cols - 1] + "…"


def nome_curto(caminho) -> str:
    if not isinstance(caminho, str):
        return short(caminho, 60)
    return caminho.rsplit("/", 1)[-1]


def linhas_pensamento(texto: str, cols: int, max_linhas: int) -> list[str]:
    """Raciocínio do agente: apagado, recuado e limitado a `max_linhas`."""
    texto = (texto or "").strip()
    if not texto or max_linhas == 0:
        return []
    envolvido: list[str] = []
    for paragrafo in texto.splitlines():
        if not paragrafo.strip():
            continue
        envolvido += textwrap.wrap(paragrafo.strip(), width=max(20, cols - 4)) or [""]
    sobra = len(envolvido) - max_linhas
    if sobra > 0:
        envolvido = envolvido[:max_linhas] + [f"… mais {sobra} linha{'s' if sobra > 1 else ''}"]
    return [f"{DIM}  {linha}{RESET}" for linha in envolvido]


def contagem(antigo: str, novo: str) -> tuple[int, int]:
    """Linhas somadas e tiradas entre dois textos."""
    mais = menos = 0
    for linha in difflib.unified_diff((antigo or "").splitlines(), (novo or "").splitlines(), lineterm="", n=0):
        if linha.startswith("+++") or linha.startswith("---") or linha.startswith("@@"):
            continue
        if linha.startswith("+"):
            mais += 1
        elif linha.startswith("-"):
            menos += 1
    return mais, menos


def linhas_diff(antigo: str, novo: str, cols: int, max_linhas: int) -> list[str]:
    """Diff compacto de uma edição, com uma linha de contexto."""
    if max_linhas == 0:
        return []
    saida: list[str] = []
    for linha in difflib.unified_diff((antigo or "").splitlines(), (novo or "").splitlines(), lineterm="", n=1):
        if linha.startswith("+++") or linha.startswith("---"):
            continue
        if linha.startswith("@@"):
            continue
        if linha.startswith("+"):
            saida.append(f"{VERDE}  {cortar(linha, cols - 2)}{RESET}")
        elif linha.startswith("-"):
            saida.append(f"{VERMELHO}  {cortar(linha, cols - 2)}{RESET}")
        else:
            saida.append(f"{DIM}  {cortar(linha, cols - 2)}{RESET}")
    sobra = len(saida) - max_linhas
    if sobra > 0:
        saida = saida[:max_linhas] + [f"{DIM}  … mais {sobra} linha{'s' if sobra > 1 else ''} nesta edição{RESET}"]
    return saida


def arquivo_do(inp: dict) -> str:
    for chave in ("file_path", "target_file", "path", "notebook_path"):
        if isinstance(inp.get(chave), str):
            return inp[chave]
    return ""


def bloco_ferramenta(nome: str, inp: dict, estado: dict, cols: int) -> list[str]:
    """Cabeçalho da chamada + diff, quando a ferramenta muda arquivo."""
    diff_linhas = (opcao("lane_view.diff_linhas", "LANE_VIEW_DIFF_LINHAS", 14)
                   if ligado("lane_view.diff", "LANE_VIEW_DIFF") else 0)
    caminho = arquivo_do(inp)

    if nome in EDITA and ("old_string" in inp or "new_string" in inp):
        antigo, novo = inp.get("old_string", "") or "", inp.get("new_string", "") or ""
    elif nome in ESCREVE and "content" in inp:
        antigo, novo = "", inp.get("content", "") or ""
    else:
        arg = inp.get("command") or caminho or inp.get("pattern") or inp
        if nome in LE and caminho:
            arg = nome_curto(caminho)
        return [f"{BOLD}▸ {nome}{RESET} {DIM}{short(arg)}{RESET}"]

    mais, menos = contagem(antigo, novo)
    anterior = estado.setdefault("arquivos", {}).setdefault(caminho or nome, [0, 0])
    anterior[0] += mais
    anterior[1] += menos
    marca = f"{VERDE}+{mais}{RESET} {VERMELHO}−{menos}{RESET}"
    titulo = f"{BOLD}▸ {nome}{RESET} {CIANO}{nome_curto(caminho) or '?'}{RESET} {marca}"
    return [titulo] + linhas_diff(antigo, novo, cols, diff_linhas)


def formatar(ev: dict, estado: dict, cols: int) -> list[str]:
    """Uma linha de evento do stream → linhas prontas para a tela."""
    tipo = ev.get("type")
    if tipo == "system" and ev.get("subtype") == "init":
        return [f"{DIM}modelo {ev.get('model')} · ferramentas {len(ev.get('tools', []))}{RESET}"]

    if tipo == "assistant":
        saida: list[str] = []
        pensa = (opcao("lane_view.pensamento_linhas", "LANE_VIEW_PENSA_LINHAS", 14)
                 if ligado("lane_view.pensamento", "LANE_VIEW_PENSA") else 0)
        for bloco in ev.get("message", {}).get("content", []) or []:
            kind = bloco.get("type")
            if kind == "text" and (bloco.get("text") or "").strip():
                saida.append("\n" + bloco["text"].strip())
            elif kind == "thinking":
                corpo = linhas_pensamento(bloco.get("thinking") or "", cols, pensa)
                if corpo:
                    saida.append(f"{DIM}· pensando{RESET}")
                    saida += corpo
            elif kind == "redacted_thinking" and pensa:
                saida.append(f"{DIM}· pensando (reservado){RESET}")
            elif kind == "tool_use":
                saida += bloco_ferramenta(bloco.get("name") or "?", bloco.get("input") or {}, estado, cols)
        return saida

    if tipo == "user":
        conteudo = ev.get("message", {}).get("content")
        return [
            f"  {DIM}✗ {short(b.get('content'))}{RESET}"
            for b in (conteudo if isinstance(conteudo, list) else [])
            if b.get("type") == "tool_result" and b.get("is_error")
        ]

    if tipo == "result":
        custo = ev.get("total_cost_usd")
        turnos = ev.get("num_turns")
        segundos = (ev.get("duration_ms") or 0) / 1000
        linha = (f"\n{BOLD}fim: {ev.get('subtype')}{RESET} · {turnos} turnos · {segundos:.0f}s"
                 + (f" · US$ {custo:.2f}" if isinstance(custo, (int, float)) else ""))
        arquivos = estado.get("arquivos") or {}
        if arquivos:
            mais = sum(v[0] for v in arquivos.values())
            menos = sum(v[1] for v in arquivos.values())
            linha += (f"\n{BOLD}editou {len(arquivos)} arquivo{'s' if len(arquivos) > 1 else ''}{RESET}"
                      f" · {VERDE}+{mais}{RESET} {VERMELHO}−{menos}{RESET}")
        return [linha]

    return []


def principal(entrada=sys.stdin, saida=sys.stdout) -> int:
    estado: dict = {}
    for bruto in entrada:
        bruto = bruto.strip()
        if not bruto:
            continue
        try:
            ev = json.loads(bruto)
        except ValueError:
            print(bruto, file=saida, flush=True)
            continue
        for linha in formatar(ev, estado, largura()):
            print(linha, file=saida, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(principal())
