#!/usr/bin/env python3
"""Migração do plano de controle para o bundle (FRA-617).

Aposenta as cópias em ~/.transcentia, aponta o launchd para o
tuttidash-agente do TuttiDash.app e, se a âncora não conferir, devolve
arquivos, plists e serviços ao estado de antes. Não chama `launchctl enable`:
chave desligada continua desligada. Não mexe em PAUSE nem em enabled.
"""
from __future__ import annotations

import importlib.util
import os
import plistlib
import stat
import subprocess
import sys
import time
from pathlib import Path

COPIAS_ANTIGAS = (
    ".transcentia/lanes/dispatcher.py",
    ".transcentia/lanes/lane_view.py",
    ".transcentia/lanes/lanes_window.py",
    ".transcentia/lanes/lanes_ctl.py",
    ".transcentia/lanes/run_lane.sh",
    ".transcentia/lanes/catalogo.py",
    ".transcentia/lanes/fila.py",
    ".transcentia/lanes/projetos.py",
    ".transcentia/lanes/privacidade.py",
    ".transcentia/lanes/linear_ids.py",
    ".transcentia/lanes/config.py",
    ".transcentia/lanes/gasto_privado.py",
    ".transcentia/bots/watch.py",
    ".transcentia/bots/catalogo.py",
    ".transcentia/bots/fila.py",
    ".transcentia/bots/projetos.py",
    ".transcentia/bots/privacidade.py",
    ".transcentia/bots/linear_ids.py",
    ".transcentia/bots/config.py",
    ".transcentia/bots/gasto_privado.py",
    ".transcentia/tools/bots-chave",
)

# label, papel, nome do lançador, intervalo, RunAtLoad, log
JOBS = (
    ("com.transcentia.bots.watch", "vigia", "TuttiDash Vigia", 180, False, "bots-watch.launchd.log"),
    ("com.transcentia.bots.chave", "chave", "TuttiDash Chave", 600, True, "bots-chave.launchd.log"),
    ("com.transcentia.lanes.dispatcher", "dispatcher", "TuttiDash Dispatcher", 60, True, "lanes-dispatcher.launchd.log"),
)

LABEL_NO_APP = {
    "com.transcentia.bots.watch": "app.tuttidash.agente.vigia",
    "com.transcentia.bots.chave": "app.tuttidash.agente.chave",
    "com.transcentia.lanes.dispatcher": "app.tuttidash.agente.dispatcher",
}

LANCADORES_VELHOS = (
    "TranscentIA Bots (vigia)",
    "TranscentIA Chave Bots",
    "TranscentIA Lanes (dispatcher)",
)


def _integridade():
    caminho = Path(__file__).with_name("integridade-controle.py")
    spec = importlib.util.spec_from_file_location("integridade_controle", caminho)
    if spec is None or spec.loader is None:
        raise SystemExit("integridade-controle.py ausente")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _home() -> Path:
    bruto = os.environ.get("HOME", "")
    if not bruto.startswith("/") or ".." in Path(bruto).parts:
        raise SystemExit("HOME recusado")
    return Path(bruto)


def _sob(caminho: str, raiz: str) -> bool:
    if not raiz or not caminho.startswith(raiz):
        return False
    return caminho == raiz or caminho.startswith(raiz + "/")


def _fora_do_agente(caminho: Path, home: Path, controle: Path) -> bool:
    texto = caminho.as_posix()
    if not texto.startswith("/") or ".transcentia" in texto or "/Contents/" in texto or ".." in caminho.parts:
        return False
    if _sob(texto, home.as_posix()) or _sob(texto, controle.as_posix()):
        return False
    return True


def _launchctl(args: list[str]) -> subprocess.CompletedProcess[str]:
    binario = os.environ.get("TUTTIDASH_LAUNCHCTL", "/bin/launchctl")
    return subprocess.run([binario, *args], capture_output=True, text=True)


def _dominio() -> str:
    return f"gui/{os.getuid()}"


def _caminho(home: Path, rel: str) -> Path:
    if ".." in rel.split("/"):
        raise SystemExit(f"relativo recusado: {rel}")
    return home.joinpath(*rel.split("/"))


def _curto(rel: str) -> str:
    prefixo = ".transcentia/"
    return rel[len(prefixo):] if rel.startswith(prefixo) else rel


def _agente() -> str | None:
    bruto = os.environ.get("TUTTIDASH_AGENTE", "")
    candidatos = []
    if bruto:
        candidatos.append(Path(bruto))
    candidatos.append(Path("/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"))
    candidatos.append(Path.home() / "Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente")
    for cand in candidatos:
        texto = cand.as_posix()
        if ".transcentia" in texto or ".." in cand.parts or not texto.startswith("/"):
            continue
        if cand.is_file() and os.access(cand, os.X_OK):
            return texto
    return None


def _controle() -> Path | None:
    bruto = os.environ.get("TUTTIDASH_CONTROLE", "")
    candidatos = []
    if bruto:
        candidatos.append(Path(bruto))
    agente = _agente()
    if agente:
        candidatos.append(Path(agente).resolve().parents[1] / "Resources" / "controle")
    candidatos.append(Path("/Applications/TuttiDash.app/Contents/Resources/controle"))
    candidatos.append(Path.home() / "Applications/TuttiDash.app/Contents/Resources/controle")
    for cand in candidatos:
        texto = cand.as_posix()
        if ".transcentia" in texto or ".." in cand.parts:
            continue
        if cand.is_dir() and not cand.is_symlink():
            return cand
    return None


def _ancora(mod) -> Path | None:
    bruto = os.environ.get("TUTTIDASH_INTEGRIDADE_ARQUIVO", "")
    if bruto:
        return Path(bruto)
    return Path(mod.CAMINHO_ANCORA)


def verificar() -> str | None:
    """None quando a âncora confere. Senão, o código curto da divergência."""
    if os.environ.get("TUTTIDASH_SEM_ANCORA") == "1":
        return None
    mod = _integridade()
    controle = _controle()
    if controle is None:
        return "arvore"
    ancora = _ancora(mod)
    if ancora is None or not _fora_do_agente(ancora, _home(), controle):
        return "alcance"
    if ancora.is_symlink() or not ancora.is_file():
        return "ancora"
    st = ancora.lstat()
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return "ancora"
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return "ancora"
    if "TUTTIDASH_INTEGRIDADE_ARQUIVO" not in os.environ:
        if st.st_uid != 0 or ancora.as_posix() != mod.CAMINHO_ANCORA:
            return "ancora"
    try:
        arquivos = mod.listar(controle)
    except SystemExit:
        return "arvore"
    try:
        texto = ancora.read_text()
    except OSError:
        return "ancora"
    if texto != mod.manifesto_de(arquivos):
        return "hash"
    return None


def _foto_arquivo(path: Path):
    if path.is_symlink():
        return ("symlink", os.readlink(path), 0)
    if not path.is_file():
        return None
    modo = stat.S_IMODE(path.lstat().st_mode)
    return ("file", path.read_bytes(), modo)


def _restaurar_arquivo(path: Path, foto) -> None:
    if path.is_symlink() or path.exists():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    if foto[0] == "symlink":
        os.symlink(foto[1], path)
        return
    path.write_bytes(foto[1])
    path.chmod(foto[2])


def _texto_lancador(label: str, papel: str) -> str:
    return "\n".join([
        "#!/bin/zsh",
        f"# Lançador de {label} (gerado por tuttidash/tools/migrar-controle.py)",
        "# Executa o tuttidash-agente do bundle assinado. Não usa ~/.transcentia.",
        f"papel={papel}",
        "candidatos=()",
        'if [[ -n ${TUTTIDASH_AGENTE:-} && ${TUTTIDASH_AGENTE} != *".transcentia"* ]]; then',
        '  candidatos+=("$TUTTIDASH_AGENTE")',
        "fi",
        "candidatos+=(",
        '  "/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"',
        '  "$HOME/Applications/TuttiDash.app/Contents/MacOS/tuttidash-agente"',
        ")",
        'for agente in "${candidatos[@]}"; do',
        '  [[ "$agente" == *".transcentia"* ]] && continue',
        '  if [[ -x "$agente" ]]; then',
        '    exec "$agente" "$papel"',
        "  fi",
        "done",
        'echo "tuttidash: tuttidash-agente não está no bundle assinado" >&2',
        "exit 70",
        "",
    ])


def _ler_plist(path: Path):
    if not path.is_file() or path.is_symlink():
        return None
    try:
        return plistlib.loads(path.read_bytes())
    except Exception:
        return None


def _desligada(label: str, plist_obj, texto: str) -> bool:
    if f'"{label}" => disabled' in texto or f'"{label}" => true' in texto:
        return True
    return bool(plist_obj and plist_obj.get("Disabled") is True)


def _plist_novo(home: Path, label: str, papel: str, intervalo: int, run_at_load: bool,
                log_name: str, programa: list[str], antigo) -> bytes:
    log = home / "Library" / "Logs" / "TranscentIA" / log_name
    dados = {
        "Label": label,
        "ProgramArguments": programa,
        "RunAtLoad": bool(antigo.get("RunAtLoad")) if isinstance(antigo, dict) and "RunAtLoad" in antigo else run_at_load,
        "StartInterval": int(antigo["StartInterval"]) if isinstance(antigo, dict) and isinstance(antigo.get("StartInterval"), int) else intervalo,
        "AssociatedBundleIdentifiers": ["app.tuttidash.mac"],
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
    }
    if isinstance(antigo, dict) and antigo.get("Disabled") is True:
        dados["Disabled"] = True
    return plistlib.dumps(dados, fmt=plistlib.FMT_XML)


def aplicar(sem_launchd: bool) -> int:
    home = _home()
    dominio = _dominio()
    agente = _agente()
    pasta_lanc = home / "Library" / "Application Support" / "AgentesLocais"
    pasta_plist = home / "Library" / "LaunchAgents"
    pasta_lanc.mkdir(parents=True, exist_ok=True)
    pasta_plist.mkdir(parents=True, exist_ok=True)
    (home / "Library" / "Logs" / "TranscentIA").mkdir(parents=True, exist_ok=True)

    texto_disabled = ""
    if not sem_launchd:
        saida = _launchctl(["print-disabled", dominio])
        texto_disabled = saida.stdout or ""

    fotos = {}
    for rel in COPIAS_ANTIGAS:
        path = _caminho(home, rel)
        foto = _foto_arquivo(path)
        if foto is not None:
            fotos[rel] = foto

    plists_antes = {}
    objs = {}
    carregados = {}
    desligados = {}
    for label, _papel, _nome, _intervalo, _run, _log in JOBS:
        caminho = pasta_plist / f"{label}.plist"
        bruto = caminho.read_bytes() if caminho.is_file() and not caminho.is_symlink() else None
        plists_antes[label] = bruto
        obj = _ler_plist(caminho)
        objs[label] = obj
        desligados[label] = _desligada(label, obj, texto_disabled)
        if sem_launchd:
            carregados[label] = False
        else:
            carregados[label] = _launchctl(["print", f"{dominio}/{label}"]).returncode == 0

    lanc_antes = {}
    for _label, _papel, nome, _intervalo, _run, _log in JOBS:
        caminho = pasta_lanc / nome
        lanc_antes[nome] = caminho.read_bytes() if caminho.is_file() and not caminho.is_symlink() else None
    for nome in LANCADORES_VELHOS:
        caminho = pasta_lanc / nome
        lanc_antes[nome] = caminho.read_bytes() if caminho.is_file() and not caminho.is_symlink() else None

    stamp = f"{time.strftime('%Y%m%d%H%M%S')}-{os.getpid()}"
    aposentados = home / ".transcentia" / "aposentados" / stamp

    def desfazer(motivo: str) -> int:
        for rel, foto in fotos.items():
            _restaurar_arquivo(_caminho(home, rel), foto)
        if aposentados.exists():
            for filho in sorted(aposentados.rglob("*"), reverse=True):
                if filho.is_file() or filho.is_symlink():
                    filho.unlink()
                elif filho.is_dir():
                    filho.rmdir()
            if aposentados.exists():
                aposentados.rmdir()
        for label, bruto in plists_antes.items():
            caminho = pasta_plist / f"{label}.plist"
            if bruto is None:
                if caminho.exists() or caminho.is_symlink():
                    caminho.unlink()
            else:
                caminho.write_bytes(bruto)
                caminho.chmod(0o644)
        for nome, bruto in lanc_antes.items():
            caminho = pasta_lanc / nome
            if bruto is None:
                if caminho.exists() or caminho.is_symlink():
                    caminho.unlink()
            else:
                caminho.write_bytes(bruto)
                caminho.chmod(0o755)
        if not sem_launchd:
            for label, _papel, _nome, _intervalo, _run, _log in JOBS:
                _launchctl(["bootout", f"{dominio}/{label}"])
                if carregados[label] and not desligados[label] and plists_antes[label] is not None:
                    _launchctl(["bootstrap", dominio, str(pasta_plist / f"{label}.plist")])
        print(f"ROLLBACK: verificação falhou ({motivo}); estado anterior restaurado")
        return 1

    try:
        for rel, foto in fotos.items():
            path = _caminho(home, rel)
            print(f"AVISO: cópia antiga aposentada: {path}")
            if foto[0] == "symlink":
                path.unlink()
                continue
            destino = aposentados / _curto(rel)
            destino.parent.mkdir(parents=True, exist_ok=True)
            path.rename(destino)
            destino.chmod(0o644)
        if fotos:
            aviso = aposentados / "AVISO.txt"
            aviso.parent.mkdir(parents=True, exist_ok=True)
            aviso.write_text(
                "Cópias antigas do plano de controle. O launchd usa o TuttiDash.app.\n"
                "Chaves que estavam desligadas não foram religadas.\n"
            )
            aviso.chmod(0o644)
    except OSError as exc:
        return desfazer(f"aposentar: {exc}")

    for nome in LANCADORES_VELHOS:
        velho = pasta_lanc / nome
        if velho.exists() or velho.is_symlink():
            velho.unlink()

    programas = {}
    for label, papel, nome, intervalo, run_at_load, log_name in JOBS:
        lancador = pasta_lanc / nome
        lancador.write_text(_texto_lancador(label, papel))
        lancador.chmod(0o755)
        if agente:
            programas[label] = [agente, papel]
        else:
            programas[label] = [str(lancador)]
        caminho = pasta_plist / f"{label}.plist"
        caminho.write_bytes(_plist_novo(
            home, label, papel, intervalo, run_at_load, log_name, programas[label], objs[label]))
        caminho.chmod(0o644)

    if not sem_launchd:
        for label, _papel, _nome, _intervalo, _run, _log in JOBS:
            novo = LABEL_NO_APP[label]
            no_app = _launchctl(["print", f"{dominio}/{novo}"]).returncode == 0
            if desligados[label]:
                if carregados[label]:
                    _launchctl(["bootout", f"{dominio}/{label}"])
                continue
            if no_app:
                if carregados[label]:
                    _launchctl(["bootout", f"{dominio}/{label}"])
                continue
            tinha = plists_antes[label] is not None
            if carregados[label] or not tinha:
                _launchctl(["bootout", f"{dominio}/{label}"])
                plist = pasta_plist / f"{label}.plist"
                subiu = _launchctl(["bootstrap", dominio, str(plist)])
                if subiu.returncode != 0 and _launchctl(["print", f"{dominio}/{label}"]).returncode != 0:
                    return desfazer(f"bootstrap {label}")

    motivo = verificar()
    if motivo:
        return desfazer(motivo)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] != "aplicar":
        print("uso: migrar-controle.py aplicar [--sem-launchd]", file=sys.stderr)
        return 2
    sem = "--sem-launchd" in argv[2:]
    return aplicar(sem)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
