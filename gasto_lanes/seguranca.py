"""Auditoria de permissões do estado do TuttiDash.

Não isola a lane do usuário (isso é a fase 5 do norte), mas mostra o que hoje
está legível por outros usuários/symlinks: pasta de estado, lane-*.json,
claim-*.json, config, ledger e eventos. `corrigir=True` aplica 0700/0600.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path

ALVO_DIR = 0o700
ALVO_ARQ = 0o600


def _modo(caminho: Path) -> int:
    try:
        return stat.S_IMODE(caminho.stat().st_mode)
    except OSError:
        return -1


def revisar(state_dir, *, config=None, ledger=None, corrigir: bool = False) -> list:
    achados = []

    def item(nivel, caminho, mensagem):
        achados.append({"nivel": nivel, "caminho": str(caminho), "mensagem": mensagem})

    pastas = [Path(state_dir)]
    if config is not None:
        pastas.append(Path(config).parent)
    for pasta in pastas:
        if not pasta.exists():
            item("aviso", pasta, "pasta não existe")
            continue
        modo = _modo(pasta)
        if modo < 0:
            item("erro", pasta, "não consegui ler a permissão")
        elif modo & 0o077:
            if corrigir:
                try:
                    pasta.chmod(ALVO_DIR)
                    item("ok", pasta, f"permissão {modo:03o} corrigida para 700")
                except OSError as exc:
                    item("erro", pasta, f"permissão {modo:03o}; não corrigi ({exc})")
            else:
                item("erro", pasta, f"permissão {modo:03o}; outros usuários podem entrar (use corrigir)")
        else:
            item("ok", pasta, f"permissão {modo:03o}")

    alvos = []
    sd = Path(state_dir)
    if sd.is_dir():
        alvos += list(sd.glob("lane-*.json")) + list(sd.glob("claim-*.json"))
        for nome in ("eventos.jsonl", "heartbeat.json", "enabled"):
            p = sd / nome
            if p.exists():
                alvos.append(p)
    for p in (Path(config) if config else None, Path(ledger) if ledger else None):
        if p is not None and p.exists():
            alvos.append(p)
    for p in alvos:
        if p.is_symlink():
            item("erro", p, "symlink: o estado não pode apontar para fora")
            continue
        modo = _modo(p)
        if modo < 0:
            item("erro", p, "não consegui ler a permissão")
        elif modo & 0o077:
            if corrigir:
                try:
                    p.chmod(ALVO_ARQ)
                    item("ok", p, f"permissão {modo:03o} corrigida para 600")
                except OSError as exc:
                    item("erro", p, f"permissão {modo:03o}; não corrigi ({exc})")
            else:
                item("erro", p, f"permissão {modo:03o}; legível por outros (use corrigir)")
        else:
            item("ok", p, f"permissão {modo:03o}")
    return achados


def resumo(achados: list) -> dict:
    c = {"ok": 0, "aviso": 0, "erro": 0}
    for a in achados:
        if a["nivel"] in c:
            c[a["nivel"]] += 1
    return {"ok": c["ok"], "avisos": c["aviso"], "erros": c["erro"], "achados": achados}


def texto(achados: list) -> str:
    r = resumo(achados)
    linhas = [f"Segurança do estado: {r['ok']} ok, {r['avisos']} avisos, {r['erros']} erros"]
    for a in achados:
        linhas.append(f"{a['nivel']:5} {a['caminho']}: {a['mensagem']}")
    return "\n".join(linhas)
