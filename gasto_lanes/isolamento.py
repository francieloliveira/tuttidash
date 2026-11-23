"""Isolamento lógico por projeto (FRA-719).

O escopo decidido é: mesma conta do macOS, sem serviço separado. A lane de um
projeto só aponta para worktree/log/claim daquele projeto; não há troca de
projeto no meio do card. Isto audita essa fronteira — não é sandbox de SO nem
bloqueia `~/.ssh`/`gh`, que continuam compartilhados pela conta do Mac.
"""
from __future__ import annotations

import json
from pathlib import Path


def _resolvido_sob(caminho, raiz: Path):
    try:
        p = Path(str(caminho)).resolve()
        r = raiz.resolve()
        p.relative_to(r)
        return p
    except (OSError, ValueError):
        return None


def _primeira_linha(caminho: Path) -> str:
    try:
        with caminho.open("r", encoding="utf-8", errors="replace") as fh:
            return fh.readline(4096)
    except OSError:
        return ""


def revisar(state_dir, projetos, *, log_dir=None) -> list:
    achados = []
    sd = Path(state_dir)
    por_id = {getattr(p, "id", ""): p for p in projetos if getattr(p, "id", "")}
    padrao = next((p for p in projetos if getattr(p, "padrao", False)), None)

    def item(nivel, caminho, mensagem):
        achados.append({"nivel": nivel, "caminho": str(caminho), "mensagem": mensagem})

    for arq in sorted(sd.glob("lane-*.json")):
        try:
            st = json.loads(arq.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError):
            item("erro", arq, "estado ilegível")
            continue
        if not isinstance(st, dict):
            item("erro", arq, "estado não é objeto")
            continue
        dono = str(st.get("projeto") or "")
        if dono:
            p = por_id.get(dono)
            if p is None:
                item("erro", arq, f"projeto {dono} não está no cadastro")
                continue
        else:
            p = padrao
            if p is None:
                item("aviso", arq, "estado sem projeto e sem projeto padrão")
                continue
        raiz = Path(getattr(p, "worktrees", ""))
        wt = st.get("worktree")
        if not wt or _resolvido_sob(wt, raiz) is None:
            item("erro", arq, f"worktree fora de {raiz}")
        elif Path(str(wt)).is_symlink():
            item("erro", arq, "worktree é symlink")
        log = st.get("log")
        if not log:
            item("erro", arq, "estado sem log")
        else:
            logp = Path(str(log))
            if log_dir is not None and _resolvido_sob(logp, Path(log_dir)) is None:
                item("erro", logp, "log fora da pasta de logs")
            else:
                primeira = _primeira_linha(logp)
                if '"tutti_projeto"' in primeira:
                    try:
                        cab = json.loads(primeira)
                        if str(cab.get("projeto") or "") != str(getattr(p, "id", "")):
                            item("erro", logp, "log de outro projeto")
                    except ValueError:
                        item("aviso", logp, "cabeçalho de projeto ilegível")
                elif primeira.strip():
                    item("aviso", logp, "log sem cabeçalho de projeto")

    for arq in sorted(sd.glob("claim-*.json")):
        try:
            claim = json.loads(arq.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError):
            item("erro", arq, "claim ilegível")
            continue
        dono = str((claim or {}).get("projeto") or "") if isinstance(claim, dict) else ""
        if dono and dono not in por_id:
            item("erro", arq, f"claim de projeto {dono} fora do cadastro")

    for p in projetos:
        raiz = Path(getattr(p, "worktrees", ""))
        if not str(raiz):
            continue
        if raiz.is_symlink():
            item("erro", raiz, "pasta de worktrees é symlink")
        elif not raiz.exists():
            item("aviso", raiz, "pasta de worktrees não existe")
    return achados


def resumo(achados: list) -> dict:
    c = {"ok": 0, "aviso": 0, "erro": 0}
    for a in achados:
        if a["nivel"] in c:
            c[a["nivel"]] += 1
    return {"ok": c["ok"], "avisos": c["aviso"], "erros": c["erro"], "achados": achados}


def texto(achados: list) -> str:
    r = resumo(achados)
    linhas = [f"Isolamento por projeto: {r['avisos']} avisos, {r['erros']} erros"]
    for a in achados:
        linhas.append(f"{a['nivel']:5} {a['caminho']}: {a['mensagem']}")
    return "\n".join(linhas)
