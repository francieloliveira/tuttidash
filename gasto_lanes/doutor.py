"""Diagnóstico do portfólio: caminhos, repositórios, estado e dependências.

Só leitura. Não cria, não corrige e não fala com Linear/GitHub. A ideia é o dono
descobrir o que está quebrado antes de culpar a lane: config ausente, pasta do
projeto que sumiu, worktree sem pasta, proxy do Linear fechado etc.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

NIVEL_ERRO = "erro"
NIVEL_AVISO = "aviso"
NIVEL_OK = "ok"


def _item(nivel: str, mensagem: str, projeto: str = "") -> dict:
    return {"nivel": nivel, "projeto": projeto, "mensagem": mensagem}


def _git(pasta: Path) -> bool:
    return (pasta / ".git").exists() or (pasta / ".git").is_file()


def checar(config, projetos, *, home: Path | None = None,
           socket_linear: Path | None = None, gh: str | None = None) -> list:
    """Lista de achados. `config` é `Configuracao` (app) ou objeto com os mesmos campos."""
    home = Path(home) if home else Path.home()
    out = []
    cfg = getattr(config, "arquivoConfig", None) or getattr(config, "arquivo_config", None)
    if cfg is not None:
        if Path(cfg).is_file():
            out.append(_item(NIVEL_OK, f"config: {cfg}"))
        else:
            out.append(_item(NIVEL_AVISO, f"config ainda não existe: {cfg}"))
    for nome in ("stateDir", "logsDir", "ledger"):
        valor = getattr(config, nome, None)
        if valor is None:
            continue
        caminho = Path(valor)
        if nome == "ledger":
            if caminho.is_file():
                out.append(_item(NIVEL_OK, f"ledger: {caminho}"))
            else:
                out.append(_item(NIVEL_AVISO, f"ledger ainda não existe: {caminho}"))
        elif caminho.is_dir():
            out.append(_item(NIVEL_OK, f"{nome}: {caminho}"))
        else:
            out.append(_item(NIVEL_AVISO, f"{nome} não existe: {caminho}"))

    estado = Path(getattr(config, "stateDir", home / ".transcentia" / "lanes"))
    eventos = estado / "eventos.jsonl"
    if not eventos.exists():
        out.append(_item(NIVEL_AVISO, "eventos.jsonl ainda não existe (nenhum claim/finalize registrado)"))
    socket_path = Path(socket_linear) if socket_linear else estado / "linear-proxy.sock"
    if socket_path.exists():
        out.append(_item(NIVEL_OK, "proxy do Linear está no socket"))
    else:
        out.append(_item(NIVEL_AVISO, "proxy do Linear não está no socket (app fechado ou proxy parado)"))
    if gh is None:
        gh = shutil.which("gh") or ""
    out.append(_item(NIVEL_OK, f"gh: {gh}") if gh else _item(NIVEL_ERRO, "gh não encontrado no PATH"))

    for p in projetos or ():
        pid = getattr(p, "id", "") or ""
        nome = getattr(p, "nome", "") or pid
        repo = Path(getattr(p, "repo", "") or "")
        if not getattr(p, "ativo", True):
            out.append(_item(NIVEL_AVISO, f"{nome}: projeto inativo, nenhuma lane pega card", pid))
            continue
        if not repo.is_dir():
            out.append(_item(NIVEL_ERRO, f"{nome}: pasta do repo não existe ({repo})", pid))
            continue
        out.append(_item(NIVEL_OK, f"{nome}: repo {repo}", pid))
        if _git(repo):
            out.append(_item(NIVEL_OK, f"{nome}: git encontrado", pid))
        else:
            out.append(_item(NIVEL_ERRO, f"{nome}: {repo} não é repositório git", pid))
        wt = Path(str(getattr(p, "worktrees", "") or "") or (str(repo) + "-worktrees"))
        if wt.exists():
            out.append(_item(NIVEL_OK, f"{nome}: worktrees {wt}", pid))
        else:
            out.append(_item(NIVEL_AVISO, f"{nome}: pasta de worktrees ainda não existe ({wt})", pid))
        norte = str(getattr(p, "norte", "") or "")
        if norte:
            if (repo / norte).is_file():
                out.append(_item(NIVEL_OK, f"{nome}: norte {norte}", pid))
            else:
                out.append(_item(NIVEL_AVISO, f"{nome}: norte configurado não existe ({norte})", pid))
    return out


def resumo(achados: list) -> dict:
    contagem = {NIVEL_OK: 0, NIVEL_AVISO: 0, NIVEL_ERRO: 0}
    for a in achados:
        if a.get("nivel") in contagem:
            contagem[a["nivel"]] += 1
    return {"ok": contagem[NIVEL_OK], "avisos": contagem[NIVEL_AVISO],
            "erros": contagem[NIVEL_ERRO], "achados": achados}


def texto(achados: list) -> str:
    r = resumo(achados)
    linhas = [f"Diagnóstico: {r['ok']} ok, {r['avisos']} avisos, {r['erros']} erros"]
    for a in achados:
        prefixo = {"erro": "ERRO", "aviso": "aviso", "ok": "ok"}.get(a.get("nivel"), "?")
        alvo = f"[{a['projeto']}] " if a.get("projeto") else ""
        linhas.append(f"{prefixo:5} {alvo}{a.get('mensagem', '')}")
    return "\n".join(linhas)
