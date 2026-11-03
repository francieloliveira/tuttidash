"""Política de permissões das lanes ACP: decide cada `session/request_permission`.

As regras são as mesmas das outras lanes (`claude-settings.json` do bundle
assinado, `permissions.allow`/`deny`), lidas pelo runner e passadas para cá.
Tudo que não está explicitamente liberado é negado (falha fechada):

- ler, buscar e pensar: dentro do worktree.
- editar, apagar e mover: só com caminho, e todos dentro do worktree, fora de
  `.git` e `.lane` (estado da lane, que o painel lê).
- executar: o comando inteiro precisa casar uma regra `Bash(...)` do allow e
  nenhuma do deny. Encadeamento, redirecionamento e substituição (`;`, `&`, `|`,
  `<`, `>`, crase, `$(`) são negados antes, porque `git status; rm -rf x`
  casaria `Bash(git status *)`.
- web (`fetch`), `other` e qualquer tipo desconhecido: negado.

O ACP não é barreira de segurança sozinho: só passa por aqui o que o agente
pergunta. Por isso o manifesto obriga o agente a perguntar e a sonda confere.
"""
from __future__ import annotations

import os
import re
from typing import Iterable, Optional

try:
    from lanes.permissao import bash_casa
except ImportError:  # cópia instalada: permissao.py ao lado
    from permissao import bash_casa  # type: ignore

PERMITIR, NEGAR = "permitir", "negar"
PROTEGIDOS = (".git", ".lane")
_OPERADORES = re.compile(r"[;&|<>`\n\r]|\$\(")
_LEITURA = {"read", "search", "think"}
_ESCRITA = {"edit", "delete", "move"}
_CHAVES_CAMINHO = ("path", "filePath", "file_path", "filepath", "file",
                   "oldPath", "newPath", "old_path", "new_path", "source", "destination")


def _regras_bash(regras: Iterable[str]) -> list:
    saida = []
    for r in regras or ():
        if isinstance(r, str) and r.startswith("Bash(") and r.endswith(")"):
            saida.append(r[5:-1])
    return saida


def caminhos(tool_call: dict) -> list:
    """Caminhos citados no pedido: `locations` e as chaves comuns de `rawInput`."""
    vistos = []
    for loc in tool_call.get("locations") or []:
        if isinstance(loc, dict) and isinstance(loc.get("path"), str):
            vistos.append(loc["path"])
    bruto = tool_call.get("rawInput")
    if isinstance(bruto, dict):
        for k in _CHAVES_CAMINHO:
            v = bruto.get(k)
            if isinstance(v, str) and v:
                vistos.append(v)
    return list(dict.fromkeys(vistos))


def comando(tool_call: dict) -> str:
    bruto = tool_call.get("rawInput")
    if isinstance(bruto, dict):
        for k in ("command", "cmd"):
            v = bruto.get(k)
            if isinstance(v, str):
                return v.strip()
            if isinstance(v, list) and all(isinstance(x, str) for x in v):
                return " ".join(v).strip()
    return ""


#: Único arquivo de `.lane` que o agente grava: o resultado que o dispatcher lê.
RESULTADO = os.path.join(".lane", "result.json")


def dentro(caminho: str, worktree: str) -> bool:
    """O caminho (resolvido, com symlink) fica dentro do worktree e fora de `.git`/`.lane`.

    Exceção: `.lane/result.json`, que o prompt da lane manda gravar."""
    raiz = os.path.realpath(worktree)
    alvo = caminho if os.path.isabs(caminho) else os.path.join(raiz, caminho)
    alvo = os.path.realpath(alvo)
    if alvo != raiz and not alvo.startswith(raiz + os.sep):
        return False
    rel = os.path.relpath(alvo, raiz)
    if rel == RESULTADO:
        return True
    return not any(parte in PROTEGIDOS for parte in rel.split(os.sep))


def decidir(tool_call: dict, worktree: str, allow: Iterable[str] = (),
            deny: Iterable[str] = ()) -> tuple:
    """(PERMITIR|NEGAR, motivo)."""
    tipo = tool_call.get("kind") or "other"
    paths = caminhos(tool_call)
    fora = [p for p in paths if not dentro(p, worktree)]
    if tipo in _LEITURA:
        if fora:
            return NEGAR, f"{tipo} fora do worktree: {fora[0]}"
        return PERMITIR, f"{tipo} no worktree"
    if tipo in _ESCRITA:
        if not paths:
            return NEGAR, f"{tipo} sem caminho"
        if fora:
            return NEGAR, f"{tipo} fora do worktree ou em .git/.lane: {fora[0]}"
        return PERMITIR, f"{tipo} no worktree"
    if tipo == "execute":
        cmd = comando(tool_call) or (tool_call.get("title") or "").strip()
        if not cmd:
            return NEGAR, "comando vazio"
        if _OPERADORES.search(cmd):
            return NEGAR, f"comando com encadeamento ou redirecionamento: {cmd[:80]}"
        if any(bash_casa(p, cmd) for p in _regras_bash(deny)):
            return NEGAR, f"comando no deny: {cmd[:80]}"
        if any(bash_casa(p, cmd) for p in _regras_bash(allow)):
            return PERMITIR, f"comando no allow: {cmd[:80]}"
        return NEGAR, f"comando fora do allow: {cmd[:80]}"
    if tipo == "fetch":
        return NEGAR, "rede é negada nas lanes"
    return NEGAR, f"tipo de ferramenta não liberado: {tipo}"


def resposta(params: dict, decisao: str) -> dict:
    """`outcome` do protocolo: a opção `allow_once`/`reject_once`. Sem opção certa, cancela."""
    opcoes = [o for o in params.get("options") or [] if isinstance(o, dict)]
    quer = ("allow_once",) if decisao == PERMITIR else ("reject_once", "reject_always")
    for q in quer:
        o: Optional[dict] = next((x for x in opcoes if x.get("kind") == q), None)
        if o and o.get("optionId"):
            return {"outcome": "selected", "optionId": o["optionId"]}
    return {"outcome": "cancelled"}
