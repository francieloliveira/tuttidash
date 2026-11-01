#!/usr/bin/env python3
"""Âncora de integridade do plano de controle (FRA-616).

O manifesto não mora no bundle: o lançador só confia no arquivo de sistema,
dono root, fora de ~/.transcentia. No Mac o caminho real é
/private/var/db/tuttidash/controle.sha256 (/var é symlink).

Gera o texto. Não executa o dispatcher nem o vigia.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

MAGIA = "tuttidash-controle-v1"
EQUIPE = "3QA76CY27W"
REQUISITO = (
    'anchor apple generic and certificate leaf[subject.OU] = "3QA76CY27W" '
    "and certificate leaf[field.1.2.840.113635.100.6.1.12]"
)
CAMINHO_ANCORA = (
    "/private/var/db/tuttidash/controle.sha256"
    if sys.platform == "darwin"
    else "/var/db/tuttidash/controle.sha256"
)
LIMITE = 8 * 1024 * 1024

# Mesma árvore que apps/notch-mac/build.sh copia para Contents/Resources/controle.
COPIAS = (
    ("lanes/dispatcher.py", "lanes/dispatcher.py", 0o755),
    ("lanes/permissao.py", "lanes/permissao.py", 0o644),
    ("lanes/lane_view.py", "lanes/lane_view.py", 0o755),
    ("lanes/lanes_window.py", "lanes/lanes_window.py", 0o755),
    ("lanes/lanes_ctl.py", "lanes/lanes_ctl.py", 0o755),
    ("lanes/run_lane.sh", "lanes/run_lane.sh", 0o755),
    ("bots/watch.py", "bots/watch.py", 0o755),
    ("bots/caixa_leitura.py", "bots/caixa_leitura.py", 0o644),
    ("bots/git-leitura", "bots/git-leitura", 0o755),
    ("tools/bots-chave", "tools/bots-chave", 0o755),
    ("tools/lanes.command", "tools/lanes.command", 0o755),
    ("tools/script-controle.sh", "tools/script-controle.sh", 0o644),
    ("gasto_lanes/catalogo.py", "gasto_lanes/catalogo.py", 0o644),
    ("gasto_lanes/projetos.py", "gasto_lanes/projetos.py", 0o644),
    ("gasto_lanes/privacidade.py", "gasto_lanes/privacidade.py", 0o644),
    ("gasto_lanes/linear_ids.py", "gasto_lanes/linear_ids.py", 0o644),
    ("gasto_lanes/fila.py", "gasto_lanes/fila.py", 0o644),
    ("gasto_lanes/config.py", "gasto_lanes/config.py", 0o644),
    ("gasto_lanes/proxy_linear.py", "gasto_lanes/proxy_linear.py", 0o644),
    ("gasto_lanes/revisao_ia.py", "gasto_lanes/revisao_ia.py", 0o644),
)
PRIVADO = (
    "apps/notch-mac/Privado/python/gasto_privado.py",
    "gasto_lanes/gasto_privado.py",
    0o644,
)


def _ignorar(rel: str) -> bool:
    partes = rel.split("/")
    if any(p == "__pycache__" or p.startswith(".") for p in partes):
        return True
    return rel.endswith(".pyc")


def listar(controle: Path) -> dict[str, bytes]:
    base = controle.resolve()
    achados: dict[str, bytes] = {}
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__" and not d.startswith("."))
        for nome in sorted(filenames):
            caminho = Path(dirpath) / nome
            rel = caminho.relative_to(base).as_posix()
            if _ignorar(rel):
                continue
            if caminho.is_symlink() or not caminho.is_file():
                raise SystemExit(f"recuso symlink ou não-arquivo: {rel}")
            dados = caminho.read_bytes()
            if len(dados) > LIMITE:
                raise SystemExit(f"arquivo grande demais: {rel}")
            achados[rel] = dados
    if not achados:
        raise SystemExit(f"controle vazio: {controle}")
    return achados


def manifesto_de(arquivos: dict[str, bytes]) -> str:
    linhas = [MAGIA, f"team {EQUIPE}"]
    for rel in sorted(arquivos):
        digest = hashlib.sha256(arquivos[rel]).hexdigest()
        linhas.append(f"{digest} {rel}")
    return "\n".join(linhas) + "\n"


def gerar(controle: Path, destino: Path) -> None:
    texto = manifesto_de(listar(controle))
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(texto)
    destino.chmod(0o644)


def preparar(repo: Path, controle: Path) -> None:
    if controle.exists():
        shutil.rmtree(controle)
    for origem, rel, modo in COPIAS:
        src = repo / origem
        if not src.is_file():
            raise SystemExit(f"ausente no repo: {origem}")
        dst = controle / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        dst.chmod(modo)
    src_priv = repo / PRIVADO[0]
    if src_priv.is_file():
        dst = controle / PRIVADO[1]
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src_priv, dst)
        dst.chmod(PRIVADO[2])


def _recusa_destino(destino: Path) -> None:
    texto = destino.as_posix()
    if ".transcentia" in texto or "/Contents/" in texto or not texto.startswith("/"):
        raise SystemExit(f"destino recusado: {destino}")
    if destino.as_posix() != CAMINHO_ANCORA:
        raise SystemExit(f"destino fora da âncora: {destino}")


def _sem_symlink(caminho: Path) -> None:
    atual = Path("/")
    for parte in caminho.parts[1:]:
        atual = atual / parte
        if atual.is_symlink():
            raise SystemExit(f"symlink na âncora: {atual}")


def gravar(origem: Path) -> None:
    """Chamado como root. Não segue symlink e não grava em lugar nenhum mais."""
    if os.geteuid() != 0:
        raise SystemExit("gravar exige root")
    destino = Path(CAMINHO_ANCORA)
    _recusa_destino(destino)
    _sem_symlink(destino.parent)
    if destino.is_symlink():
        raise SystemExit("âncora é symlink")
    dados = origem.read_bytes()
    if not dados.startswith(MAGIA.encode() + b"\n"):
        raise SystemExit("manifesto sem a magia")
    if f"team {EQUIPE}\n".encode() not in dados.splitlines(keepends=True)[1:2]:
        raise SystemExit("manifesto sem a equipe")
    pasta = Path(CAMINHO_ANCORA).parent
    pasta.mkdir(parents=True, exist_ok=True)
    # Escrita direta, sem passar por um caminho que o agente escolha.
    fd = os.open(CAMINHO_ANCORA, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o444)
    try:
        os.write(fd, dados)
    finally:
        os.close(fd)
    os.chmod(CAMINHO_ANCORA, 0o444)
    os.chown(CAMINHO_ANCORA, 0, 0)
    os.chown(pasta, 0, 0)
    os.chmod(pasta, 0o755)
    st = os.lstat(CAMINHO_ANCORA)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
        raise SystemExit("âncora não ficou regular e de root")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("âncora gravável pelo grupo")


def instalar(origem: Path) -> int:
    if os.environ.get("TUTTIDASH_SEM_ANCORA") == "1":
        print("AVISO: âncora de integridade não instalada (TUTTIDASH_SEM_ANCORA).")
        return 0
    if os.geteuid() == 0:
        gravar(origem)
        print(f"âncora instalada: {CAMINHO_ANCORA}")
        return 0
    if shutil.which("sudo") is None:
        print(f"AVISO: sem sudo; a âncora não foi para {CAMINHO_ANCORA}")
        return 0
    r = subprocess.run(
        ["sudo", "-n", sys.executable, str(Path(__file__).resolve()), "gravar", str(origem)],
        check=False,
    )
    if r.returncode != 0:
        print(f"AVISO: a âncora não foi instalada em {CAMINHO_ANCORA}")
        print("O launchd aborta até este arquivo existir, dono root, modo 0444.")
        return 0
    print(f"âncora instalada: {CAMINHO_ANCORA}")
    return 0


def instalar_repo(repo: Path) -> int:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="td-ancora-") as bruto:
        controle = Path(bruto) / "controle"
        preparar(repo, controle)
        destino = Path(bruto) / "controle.sha256"
        gerar(controle, destino)
        return instalar(destino)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "uso: integridade-controle.py gerar <controle> <saida>"
            " | preparar <repo> <controle> | instalar <manifesto>"
            " | instalar-repo <repo> | gravar <manifesto>",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    if cmd == "gerar" and len(argv) == 4:
        gerar(Path(argv[2]), Path(argv[3]))
        return 0
    if cmd == "preparar" and len(argv) == 4:
        preparar(Path(argv[2]), Path(argv[3]))
        return 0
    if cmd == "instalar" and len(argv) == 3:
        return instalar(Path(argv[2]))
    if cmd == "instalar-repo" and len(argv) == 3:
        return instalar_repo(Path(argv[2]))
    if cmd == "gravar" and len(argv) == 3:
        gravar(Path(argv[2]))
        return 0
    print("uso inválido", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
