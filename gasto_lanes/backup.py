"""Backup do estado do TuttiDash: exporta, confere e restaura.

O arquivo é um `.tar.gz` com um `manifest.json` e checksums SHA-256. Por padrão
entram o estado das lanes, o ledger e os eventos; `config.json` só entra se for
pedido (`incluir_config`). Provas (`provas/`) e sockets/locks ficam de fora:
são volumosos/efêmeros e não restauram um card.

A restauração recusa arquivo sem manifesto válido, caminho com `..`/absoluto,
symlink e destino já ocupado sem `forcar=True`.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import shutil
import tarfile
import tempfile
from pathlib import Path

VERSAO = 1
NOME_MANIFESTO = "manifest.json"
LIMITE_ARQUIVO = 20 * 1024 * 1024
PULAR_PASTAS = {"provas", "proof-proc", "logs", "stale-proof"}
PULAR_NOMES = {"dispatcher.lock", "watch.lock", "fila.lock", "linear-proxy.sock",
               "app.pid", "linear-proxy.pid", "watch.lock"}


def _sha256(caminho: Path) -> str:
    h = hashlib.sha256()
    with caminho.open("rb") as fh:
        for bloco in iter(lambda: fh.read(1 << 16), b""):
            h.update(bloco)
    return h.hexdigest()


def _seguro(rel: str) -> bool:
    p = Path(rel)
    return bool(rel) and not p.is_absolute() and ".." not in p.parts and not rel.startswith("/")


def _arquivos_estado(state_dir: Path, incluir_provas: bool = False):
    for p in sorted(state_dir.rglob("*")):
        if p.is_symlink() or not p.is_file():
            continue
        try:
            rel = p.relative_to(state_dir).as_posix()
            st = p.stat()
        except OSError:
            continue
        if st.st_size > LIMITE_ARQUIVO:
            continue
        partes = p.relative_to(state_dir).parts
        if partes and partes[0] in PULAR_PASTAS and not incluir_provas:
            continue
        if p.name in PULAR_NOMES or p.name.endswith(".sock"):
            continue
        if not (p.suffix in (".json", ".jsonl") or p.name in ("enabled", "disabled-by-user",
                                                               "last_mode", "last_decision.sha")):
            continue
        yield rel, p


def exportar(destino, *, state_dir, ledger=None, config=None, incluir_config: bool = False,
             incluir_provas: bool = False) -> dict:
    """Cria o arquivo e devolve o manifesto. Levanta OSError/ValueError em falha."""
    destino = Path(destino)
    state_dir = Path(state_dir)
    if not state_dir.is_dir():
        raise ValueError(f"pasta de estado não existe: {state_dir}")
    destino.parent.mkdir(parents=True, exist_ok=True)
    entradas = []
    with tempfile.TemporaryDirectory(prefix="tuttidash-backup-") as bruto:
        tmp = Path(bruto)
        (tmp / "state").mkdir()
        for rel, origem in _arquivos_estado(state_dir, incluir_provas):
            alvo = tmp / "state" / rel
            alvo.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(origem, alvo)
            entradas.append({"caminho": f"state/{rel}", "sha256": _sha256(alvo),
                             "tamanho": alvo.stat().st_size})
        if ledger is not None:
            led = Path(ledger)
            if led.is_file():
                shutil.copyfile(led, tmp / "ledger.jsonl")
                entradas.append({"caminho": "ledger.jsonl", "sha256": _sha256(tmp / "ledger.jsonl"),
                                 "tamanho": (tmp / "ledger.jsonl").stat().st_size})
        if incluir_config and config is not None:
            cfg = Path(config)
            if cfg.is_file():
                shutil.copyfile(cfg, tmp / "config.json")
                entradas.append({"caminho": "config.json", "sha256": _sha256(tmp / "config.json"),
                                 "tamanho": (tmp / "config.json").stat().st_size})
        manifesto = {
            "versao": VERSAO,
            "criado_em": dt.datetime.now().replace(microsecond=0).isoformat(),
            "inclui_config": bool(incluir_config and config is not None and Path(config).is_file()),
            "arquivos": entradas,
        }
        (tmp / NOME_MANIFESTO).write_text(json.dumps(manifesto, ensure_ascii=False, indent=1), encoding="utf-8")
        with tarfile.open(destino, "w:gz") as tar:
            tar.add(tmp / NOME_MANIFESTO, arcname=NOME_MANIFESTO)
            for e in entradas:
                tar.add(tmp / e["caminho"], arcname=e["caminho"])
    return manifesto


def _ler_manifesto(tar: tarfile.TarFile) -> dict:
    try:
        membro = tar.getmember(NOME_MANIFESTO)
    except KeyError:
        raise ValueError("manifesto ausente") from None
    if not membro.isfile():
        raise ValueError("manifesto não é arquivo")
    fh = tar.extractfile(membro)
    if fh is None:
        raise ValueError("manifesto ilegível")
    try:
        dados = json.loads(fh.read().decode("utf-8"))
    except (ValueError, UnicodeError):
        raise ValueError("manifesto ilegível") from None
    if not isinstance(dados, dict) or dados.get("versao") != VERSAO or not isinstance(dados.get("arquivos"), list):
        raise ValueError("manifesto com schema desconhecido")
    return dados


def verificar(arquivo) -> dict:
    """Confere manifesto, caminhos e checksums sem extrair. Não levanta."""
    erros = []
    try:
        with tarfile.open(Path(arquivo), "r:gz") as tar:
            manifesto = _ler_manifesto(tar)
            nomes = {m.name for m in tar.getmembers()}
            for m in tar.getmembers():
                if m.issym() or m.islnk():
                    erros.append(f"symlink/hardlink recusado: {m.name}")
                if not _seguro(m.name):
                    erros.append(f"caminho recusado: {m.name}")
            for e in manifesto["arquivos"]:
                nome = str(e.get("caminho") or "")
                if not _seguro(nome):
                    erros.append(f"caminho do manifesto recusado: {nome}")
                    continue
                if nome not in nomes:
                    erros.append(f"arquivo do manifesto ausente: {nome}")
                    continue
                membro = tar.getmember(nome)
                if not membro.isfile():
                    erros.append(f"não é arquivo: {nome}")
                    continue
                fh = tar.extractfile(membro)
                h = hashlib.sha256()
                while bloco := fh.read(1 << 16) if fh else b"":
                    h.update(bloco)
                if h.hexdigest() != e.get("sha256"):
                    erros.append(f"checksum não confere: {nome}")
    except (OSError, tarfile.TarError, ValueError) as exc:
        erros.append(str(exc))
    return {"ok": not erros, "erros": erros}


def _extrair_para_tmp(arquivo, tmp: Path) -> dict:
    """Extrai para `tmp` depois de verificar. Devolve manifesto."""
    conferido = verificar(arquivo)
    if not conferido["ok"]:
        raise ValueError("backup inválido: " + "; ".join(conferido["erros"]))
    with tarfile.open(Path(arquivo), "r:gz") as tar:
        manifesto = _ler_manifesto(tar)
        for m in tar.getmembers():
            if not m.isfile() or not _seguro(m.name):
                continue
            fh = tar.extractfile(m)
            if fh is None:
                continue
            alvo = tmp / m.name
            alvo.parent.mkdir(parents=True, exist_ok=True)
            with alvo.open("wb") as out:
                shutil.copyfileobj(fh, out)
    return manifesto


def restaurar(arquivo, *, state_dir, ledger=None, config=None, forcar: bool = False) -> dict:
    """Restaura o backup. Sem `forcar`, recusa destino com estado/lanes existente."""
    state_dir = Path(state_dir)
    ledger = Path(ledger) if ledger is not None else None
    config = Path(config) if config is not None else None
    if not forcar:
        if state_dir.exists() and any(state_dir.glob("lane-*.json")):
            raise ValueError(f"já há lane-*.json em {state_dir}; use --forcar para substituir")
        if ledger is not None and ledger.exists():
            raise ValueError(f"ledger já existe: {ledger}; use --forcar para substituir")
    with tempfile.TemporaryDirectory(prefix="tuttidash-restore-") as bruto:
        tmp = Path(bruto)
        manifesto = _extrair_para_tmp(arquivo, tmp)
        restaurados = []
        for e in manifesto["arquivos"]:
            nome = e["caminho"]
            origem = tmp / nome
            if not origem.is_file():
                continue
            if nome.startswith("state/"):
                rel = nome[len("state/"):]
                alvo = state_dir / rel
                alvo.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origem, alvo)
                try:
                    alvo.chmod(0o600)
                except OSError:
                    pass
                restaurados.append(str(alvo))
            elif nome == "ledger.jsonl" and ledger is not None:
                ledger.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origem, ledger)
                restaurados.append(str(ledger))
            elif nome == "config.json" and config is not None:
                config.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(origem, config)
                try:
                    config.chmod(0o600)
                except OSError:
                    pass
                restaurados.append(str(config))
        return {"restaurados": restaurados, "manifesto": manifesto}
