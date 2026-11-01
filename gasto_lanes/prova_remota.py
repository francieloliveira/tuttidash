"""Prova remota (FRA-610).

O script e a lista de comandos saem do commit da base do PR. O head é só o
código sob prova: este módulo não executa script de lá. O check `prova-remota`
fica no SHA completo do head. Quem espera esse check é o dispatcher (FRA-611).

A prova cobre o merge. Não cobre o acesso da lane ao home.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

NOME_DO_CHECK = "prova-remota"
SCRIPT_REL = "scripts/prova-remota.sh"
MODULO_REL = "gasto_lanes/prova_remota.py"
PUBLICACAO_REL = "tools/checar-publicacao.sh"
WORKFLOW_REL = ".github/workflows/prova-remota.yml"
VAR_BASE = "PROVA_BASE_SHA"
VAR_HEAD = "PROVA_HEAD_SHA"

_SHA = re.compile(r"^[0-9a-f]{40}$")
_TOKENS = (
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "ACTIONS_RUNTIME_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_URL",
)
_AMBIENTE_FORA = (
    "PYTHONPATH",
    "PYTHONSTARTUP",
    "PYTHONINSPECT",
    "BASH_ENV",
    "ENV",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "CDPATH",
)


class ProvaTrocada(Exception):
    """A prova ia usar script, módulo ou SHA que não é o da base."""


def _sha_completo(sha: str) -> None:
    if not _SHA.fullmatch(sha or ""):
        raise ProvaTrocada("SHA incompleto")


def _dentro(raiz: Path, caminho: Path) -> bool:
    raiz_r = raiz.resolve()
    cam = caminho.resolve()
    return cam == raiz_r or raiz_r in cam.parents


def _sobrepoe(a: Path, b: Path) -> bool:
    return _dentro(a, b) or _dentro(b, a)


def _caminho_valido(rel: str) -> None:
    if rel.startswith("/") or ".." in Path(rel).parts:
        raise ProvaTrocada("caminho inválido")


def blob_do_commit(repo: Path, sha: str, rel: str) -> bytes:
    """Bytes do arquivo `rel` no commit `sha` (40 hex), sem olhar a árvore de trabalho."""
    _sha_completo(sha)
    _caminho_valido(rel)
    proc = subprocess.run(
        ["git", "-C", str(repo), "cat-file", "-p", f"{sha}:{rel}"],
        check=False,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise ProvaTrocada(f"ausente no commit: {rel}")
    return proc.stdout


def escolher_script(repo: Path, base_sha: str, head_sha: str) -> bytes:
    """Blob de `scripts/prova-remota.sh` no commit da base.

    `head_sha` tem de ser completo. A árvore desse commit não é lida: um PR
    que troca o script ou o workflow continua recebendo o blob da base.
    """
    _sha_completo(base_sha)
    _sha_completo(head_sha)
    return blob_do_commit(repo, base_sha, SCRIPT_REL)


def _sha_do_checkout(raiz: Path) -> str:
    proc = subprocess.run(
        ["git", "-C", str(raiz), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise ProvaTrocada("checkout sem commit")
    sha = proc.stdout.strip()
    _sha_completo(sha)
    return sha


def _conferir_anuncio(sha_base: str, sha_head: str, env: dict[str, str]) -> None:
    for nome, real in ((VAR_BASE, sha_base), (VAR_HEAD, sha_head)):
        anunciado = env.get(nome, "")
        _sha_completo(anunciado)
        if anunciado != real:
            raise ProvaTrocada(f"{nome} não é o checkout")


def _arquivo_do_commit(base: Path, rel: str) -> Path:
    _caminho_valido(rel)
    bruto = base / rel
    if bruto.is_symlink():
        raise ProvaTrocada(f"symlink na base: {rel}")
    if not bruto.is_file():
        raise ProvaTrocada(f"ausente na base: {rel}")
    if not _dentro(base, bruto):
        raise ProvaTrocada(f"fora da base: {rel}")
    proc = subprocess.run(
        ["git", "-C", str(base), "diff", "--quiet", "HEAD", "--", rel],
        check=False,
    )
    if proc.returncode == 1:
        raise ProvaTrocada(f"diverge do commit da base: {rel}")
    if proc.returncode != 0:
        raise ProvaTrocada(f"não conferi o commit da base: {rel}")
    return bruto.resolve()


def caminho_publicacao(base: Path) -> str:
    return str((base / PUBLICACAO_REL).resolve())


def comandos_da_base(base: Path) -> list[tuple[list[str], str | None]]:
    """Comandos fixos da base. O segundo item é o cwd relativo ao head."""
    return [
        (["bash", caminho_publicacao(base)], None),
        (["python3", "-m", "unittest", "discover", "-s", "tests", "-t", "."], None),
        (["python3", "-m", "unittest", "lanes.test_lanes"], None),
        (["swift", "test"], "apps/notch-mac"),
    ]


def _conferir_argv(argv: list[str], base: Path, head: Path, path: str) -> None:
    if not argv or argv[0] not in {"bash", "sh", "python3", "python", "swift"}:
        raise ProvaTrocada("programa fora da lista")
    achado = shutil.which(argv[0], path=path)
    if achado is not None and os.path.isabs(achado) and _dentro(head, Path(achado)):
        raise ProvaTrocada("interpretador dentro do head")
    if argv[0] in {"bash", "sh"}:
        obtidos = [a for a in argv[1:] if not a.startswith("-")]
        if obtidos != [caminho_publicacao(base)]:
            raise ProvaTrocada("bash só roda a conferência da base")
    elif argv[0] in {"python3", "python"}:
        if "-m" not in argv[1:] and "-c" not in argv[1:]:
            raise ProvaTrocada("python só roda -m ou -c")
    elif argv[1:] != ["test"]:
        raise ProvaTrocada("swift só roda test")
    for arg in argv[1:]:
        if ".." in Path(arg).parts:
            raise ProvaTrocada("argumento inválido")
        if arg.startswith("/") and _dentro(head, Path(arg)):
            raise ProvaTrocada("argumento dentro do head")


def _ambiente_limpo(env: dict[str, str], head: Path) -> dict[str, str]:
    limpo = dict(env)
    for chave in _TOKENS + _AMBIENTE_FORA:
        limpo.pop(chave, None)
    partes = []
    for parte in limpo.get("PATH", "").split(os.pathsep):
        if not parte:
            continue
        if os.path.isabs(parte) and _dentro(head, Path(parte)):
            continue
        partes.append(parte)
    limpo["PATH"] = os.pathsep.join(partes)
    limpo["PYTHONDONTWRITEBYTECODE"] = "1"
    limpo["PYTHONNOUSERSITE"] = "1"
    return limpo


def _cwd(head: Path, rel: str | None) -> Path:
    if rel is not None and ".." in Path(rel).parts:
        raise ProvaTrocada("cwd inválido")
    cwd = head if rel is None else head / rel
    if not _dentro(head, cwd):
        raise ProvaTrocada("cwd fora do head")
    return cwd


def rodar(
    base: Path,
    head: Path,
    comandos: list[tuple[list[str], str | None]] | None = None,
    ambiente: dict[str, str] | None = None,
) -> int:
    """Roda a prova da base sobre o checkout do head. Não executa script do head."""
    base = base.resolve()
    head = head.resolve()
    if _sobrepoe(base, head):
        raise ProvaTrocada("base e head se sobrepõem")
    env = ambiente if ambiente is not None else dict(os.environ)
    sha_base = _sha_do_checkout(base)
    sha_head = _sha_do_checkout(head)
    _conferir_anuncio(sha_base, sha_head, env)
    _arquivo_do_commit(base, SCRIPT_REL)
    _arquivo_do_commit(base, MODULO_REL)
    lista = comandos_da_base(base) if comandos is None else list(comandos)
    if comandos is None:
        _arquivo_do_commit(base, PUBLICACAO_REL)
    limpo = _ambiente_limpo(env, head)
    print(f"{NOME_DO_CHECK} base={sha_base} head={sha_head}", flush=True)
    for argv, rel in lista:
        _conferir_argv(argv, base, head, limpo.get("PATH", ""))
        cwd = _cwd(head, rel)
        if not cwd.is_dir():
            print(f"prova-remota: pasta ausente {cwd}", file=sys.stderr)
            return 1
        print(f"prova-remota: {' '.join(argv)}", flush=True)
        try:
            proc = subprocess.run(argv, cwd=cwd, env=limpo, check=False)
        except FileNotFoundError:
            print(f"prova-remota: interpretador ausente: {argv[0]}", file=sys.stderr)
            return 127
        if proc.returncode != 0:
            print(f"prova-remota: falhou com código {proc.returncode}", file=sys.stderr)
            return proc.returncode
    return 0


def garantir_origem(base: Path, modulo: Path | None = None) -> None:
    """O arquivo em execução tem de ser o módulo dentro do checkout da base."""
    base_r = base.resolve()
    bruto = base_r / MODULO_REL
    if bruto.is_symlink():
        raise ProvaTrocada("symlink na base: " + MODULO_REL)
    modulo_r = (modulo or Path(__file__)).resolve()
    if modulo_r != bruto.resolve() or not _dentro(base_r, modulo_r):
        raise ProvaTrocada("módulo em execução não é o da base")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Prova remota a partir do commit da base.")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args(argv)
    try:
        base = Path(args.base)
        head = Path(args.head)
        garantir_origem(base)
        return rodar(base, head)
    except ProvaTrocada as exc:
        print(f"prova-remota: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
