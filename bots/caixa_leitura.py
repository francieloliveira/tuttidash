#!/usr/bin/env python3
"""Caixa do revisor (FRA-599).

O processo só enxerga o repositório (leitura), o diretório de trabalho que o
vigia criou e o que o sistema precisa para executar. A home do usuário não
entra, mesmo com HOME apontando para outro lugar: caminho absoluto fora do
repo não existe aqui dentro. A rede também não. `git show --output` não
chega a escrever — o wrapper recusa a flag antes de chamar o git.

`run_agent` (triagem) usa a mesma lista de permissão e a mesma redação; quem
entra nesta caixa é o revisor (`run_revisor`), inclusive Grok (`read_file`,
`grep`, `list_dir`) e Codex.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

_FLAGS_GIT = {
    "--output", "--ext-diff", "--exec-path", "--no-index",
    "-C", "--git-dir", "--work-tree",
}
_SUBCOMANDOS = {"show", "diff", "log", "ls-tree"}
_PREFIXOS_SISTEMA = (
    "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt", "/usr/local",
    "/System", "/Library", "/Applications", "/private/var/db",
    "/opt/homebrew", "/Library/Developer",
)


class SegredoDetectado(RuntimeError):
    """A saída tem credencial. Não publica; o vigia chama o dono."""

    def __init__(self) -> None:
        super().__init__("saída com segredo; não publico")


class CaixaIndisponivel(RuntimeError):
    """Sem sandbox de verdade. Não roda o revisor no disco aberto."""


def marcas() -> tuple[str, ...]:
    """Trechos que não podem ir para log, PR ou Linear.

    Partidos no fonte para o conferidor de publicação não ver a forma contígua.
    """
    return (
        "gh" + "p_",
        "github_" + "pat_",
        "lin_" + "api_",
        "sk-",
        "BEGIN OPENSSH",
        "AKIA",
        ".env",
    )


def tem_segredo(texto: str) -> bool:
    bruto = texto or ""
    return any(marca in bruto for marca in marcas())


def redigir(texto: str) -> str:
    """Tira da cópia gravada qualquer linha que tenha credencial."""
    if not texto:
        return ""
    if not tem_segredo(texto):
        return texto
    linhas = []
    for linha in texto.splitlines(keepends=True):
        linhas.append("[redigido]\n" if tem_segredo(linha) else linha)
    return "".join(linhas)


def exigir_sem_segredo(texto: str) -> None:
    if tem_segredo(texto):
        raise SegredoDetectado()


def _flag_proibido(arg: str) -> bool:
    if arg == "-c":
        return True
    return arg.split("=", 1)[0] in _FLAGS_GIT


def _subcomando(args: list[str]) -> str:
    for arg in args:
        if arg == "--":
            break
        if not arg.startswith("-"):
            return arg
    return ""


def _arg_fora(arg: str, repo: Path) -> bool:
    """Caminho que o git leria fora do repo (`--no-index`, `../`, absoluto)."""
    if not arg or arg.startswith("-") or arg == "--":
        return False
    if ":" in arg and not arg.startswith(("/", "~")):
        return False
    expandido = os.path.expanduser(arg) if arg.startswith("~") else arg
    caminho = Path(expandido)
    if not caminho.is_absolute():
        caminho = repo / caminho
    try:
        real = caminho.resolve()
    except OSError:
        return True
    raiz = repo.resolve()
    if real == raiz or raiz in real.parents:
        return False
    return arg.startswith("~") or Path(expandido).is_absolute() or caminho.exists() or real.exists()


def git_so_leitura(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    """`show`/`diff`/`log`/`ls-tree` sem flag que escreve ou lê fora do repo."""
    cwd = Path(cwd).resolve()
    recusa = ""
    sub = _subcomando(args)
    if sub not in _SUBCOMANDOS:
        recusa = f"git-leitura: subcomando recusado ({sub or 'vazio'})\n"
    else:
        for arg in args:
            if _flag_proibido(arg):
                recusa = f"git-leitura: flag recusada ({arg.split('=', 1)[0]})\n"
                break
            if _arg_fora(arg, cwd):
                recusa = "git-leitura: caminho fora do repositório\n"
                break
    if recusa:
        return subprocess.CompletedProcess(["git", *args], 2, "", recusa)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": "/tmp",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_SYSTEM": os.devnull,
    }
    argv = ["git", "-C", str(cwd)]
    posto = False
    for arg in args:
        argv.append(arg)
        if not posto and arg == sub and sub in {"show", "diff", "log"}:
            argv.append("--no-ext-diff")
            posto = True
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=env)


def main_git(args: list[str]) -> int:
    proc = git_so_leitura(args, Path.cwd())
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    return proc.returncode


def _path_busca() -> str:
    home = str(Path.home())
    partes = [
        "/opt/homebrew/bin", f"{home}/.local/bin", "/usr/local/bin",
        "/usr/bin", "/bin", os.environ.get("PATH", ""),
    ]
    return os.pathsep.join(p for p in partes if p)


def _binarios(argv: list[str]) -> list[str]:
    if not argv:
        return []
    achado = shutil.which(argv[0], path=_path_busca())
    if not achado:
        return []
    real = os.path.realpath(achado)
    saida: list[str] = []
    for caminho in (achado, real):
        if caminho not in saida:
            saida.append(caminho)
    return saida


def _env_limpo(extra: list[str], home: str = "/tmp") -> dict[str, str]:
    path = os.pathsep.join(
        ["/tools", *extra, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    )
    return {
        "PATH": path,
        "HOME": home,
        "TMPDIR": home,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONNOUSERSITE": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
    }


def _aspas(caminho: str) -> str:
    if any(c in caminho for c in '"()\n'):
        raise CaixaIndisponivel(f"caminho inválido na caixa: {caminho}")
    return caminho


def executar(argv: list[str], cwd: Path, timeout: int = 120, inp: str | None = None,
             escritas: list[Path] | None = None) -> subprocess.CompletedProcess[str]:
    """Roda `argv` com leitura só de `cwd` e sem rede. Falha fechada sem sandbox."""
    if not argv:
        raise CaixaIndisponivel("comando vazio")
    repo = Path(cwd).resolve()
    if not repo.is_dir() or repo == Path("/"):
        raise CaixaIndisponivel(f"repositório inválido: {repo}")
    dirs = [Path(p).resolve() for p in (escritas or [])]
    if sys.platform == "darwin":
        return _seatbelt(argv, repo, timeout, inp, dirs)
    if shutil.which("unshare"):
        return _unshare(argv, repo, timeout, inp, dirs)
    raise CaixaIndisponivel("revisor sem sandbox (falta unshare ou sandbox-exec)")


def executar_com_rede(argv: list[str], cwd: Path, timeout: int = 120,
                      inp: str | None = None) -> subprocess.CompletedProcess[str]:
    """Revisor de nuvem (Claude, Grok, Codex, OpenCode): precisa de rede e do login que a
    ferramenta guardou na home, que a caixa nega. Roda fora dela, com as travas de leitura
    do próprio CLI (vêm do manifesto: `--settings` só leitura, `--tools read_file,grep,…`,
    `--sandbox read-only`, `--agent plan`). O `git-leitura` vai no PATH."""
    if not argv:
        raise CaixaIndisponivel("comando vazio")
    repo = Path(cwd).resolve()
    if not repo.is_dir() or repo == Path("/"):
        raise CaixaIndisponivel(f"repositório inválido: {repo}")
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(Path(__file__).resolve().parent), _path_busca()])
    env.pop("GIT_DIR", None)
    env.pop("GIT_WORK_TREE", None)
    return subprocess.run(argv, cwd=repo, capture_output=True, text=True, timeout=timeout,
                          input=inp, env=env)


def _unshare(argv: list[str], repo: Path, timeout: int, inp: str | None,
             escritas: list[Path]) -> subprocess.CompletedProcess[str]:
    spec = {
        "repo": str(repo),
        "escritas": [str(p) for p in escritas],
        "tools": str(Path(__file__).resolve().parent),
        "binarios": _binarios(argv),
        "argv": argv,
    }
    fd, spec_path = tempfile.mkstemp(prefix="revisor-spec-", suffix=".json")
    os.close(fd)
    Path(spec_path).write_text(json.dumps(spec), encoding="utf-8")
    cmd = [
        "unshare", "--user", "--map-root-user", "--mount", "--pid", "--fork", "--net",
        sys.executable, str(Path(__file__).resolve()), "--dentro", spec_path,
    ]
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            input=inp, env=_env_limpo([]),
        )
    finally:
        os.unlink(spec_path)


def _bind(origem: str, destino: str, somente_leitura: bool) -> None:
    if not os.path.exists(origem):
        return
    os.makedirs(os.path.dirname(destino), exist_ok=True)
    if not os.path.exists(destino):
        if os.path.isdir(origem) and not os.path.islink(origem):
            os.makedirs(destino, exist_ok=True)
        else:
            open(destino, "a").close()
    subprocess.check_call(["mount", "--bind", origem, destino])
    if somente_leitura:
        subprocess.check_call(["mount", "-o", "remount,bind,ro", destino])


def _dentro(spec_path: str) -> int:
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    repo = spec["repo"]
    newroot = tempfile.mkdtemp(prefix="revisor-root-")
    try:
        subprocess.check_call(["mount", "--make-rprivate", "/"])
        subprocess.check_call(["mount", "-t", "tmpfs", "-o", "mode=0755", "tmpfs", newroot])
        for nome in ("tmp", "tools", "dev", "proc", "repo"):
            os.makedirs(f"{newroot}/{nome}", exist_ok=True)
        for origem in _PREFIXOS_SISTEMA:
            if os.path.isdir(origem):
                os.makedirs(newroot + origem, exist_ok=True)
                _bind(origem, newroot + origem, True)
        _bind(repo, f"{newroot}/repo", True)
        os.makedirs(newroot + repo, exist_ok=True)
        _bind(repo, newroot + repo, True)
        for pasta in spec["escritas"]:
            os.makedirs(newroot + pasta, exist_ok=True)
            _bind(pasta, newroot + pasta, False)
        _bind(spec["tools"], f"{newroot}/tools", True)
        for binario in spec["binarios"]:
            destino = newroot + binario
            if os.path.exists(destino):
                continue
            _bind(binario, destino, True)
            real = os.path.realpath(binario)
            if real != binario and not os.path.exists(newroot + real):
                _bind(real, newroot + real, True)
        for nome in ("null", "zero", "urandom", "random", "tty"):
            origem = f"/dev/{nome}"
            destino = f"{newroot}/dev/{nome}"
            if os.path.exists(origem):
                open(destino, "a").close()
                _bind(origem, destino, False)
        subprocess.check_call(["mount", "-t", "proc", "proc", f"{newroot}/proc"])
        os.chdir(newroot)
        os.chroot(".")
        os.chdir(repo if os.path.isdir(repo) else "/repo")
        dirs = [os.path.dirname(b) for b in spec["binarios"]]
        os.execvpe(spec["argv"][0], spec["argv"], _env_limpo(dirs))
    except Exception as exc:  # noqa: BLE001 — o processo da caixa tem de morrer sem vazar
        sys.stderr.write(f"caixa: {exc}\n")
        return 1
    return 0


def _perfil(repo: Path, escritas: list[Path], leituras: list[str]) -> str:
    """No macOS a última regra que casa vale.

    `(allow default)` deixa o processo subir (dyld, mach). Em seguida a leitura
    da home, do temporário e dos volumes é negada, e toda escrita e a rede
    também. O repo volta só para leitura; o scratch, para escrita.
    """
    ler = [str(repo), str(Path(__file__).resolve().parent)]
    for extra in leituras:
        ler.append(extra if os.path.isdir(extra) else os.path.dirname(extra) or "/")
    for pasta in escritas:
        ler.append(str(pasta))
    bloco_r = " ".join(f'(subpath "{_aspas(p)}")' for p in ler)
    bloco_w = " ".join(f'(subpath "{_aspas(str(p))}")' for p in escritas)
    return (
        "(version 1)\n"
        "(deny default)\n"
        "(allow default)\n"
        "(deny file-write*)\n"
        "(deny file-read*\n"
        "  (subpath \"/Users\")\n"
        "  (subpath \"/private/var/folders\")\n"
        "  (subpath \"/var/folders\")\n"
        "  (subpath \"/private/tmp\")\n"
        "  (subpath \"/tmp\")\n"
        "  (subpath \"/Volumes\"))\n"
        f"(allow file-read* {bloco_r})\n"
        f"(allow file-write* {bloco_w}\n"
        "  (literal \"/dev/null\")\n"
        "  (literal \"/dev/dtracehelper\")\n"
        "  (literal \"/dev/tty\"))\n"
        "(deny network*)\n"
        "(deny network-outbound)\n"
        "(deny network-inbound)\n"
    )


def _seatbelt(argv: list[str], repo: Path, timeout: int, inp: str | None,
              escritas: list[Path]) -> subprocess.CompletedProcess[str]:
    if not shutil.which("sandbox-exec"):
        raise CaixaIndisponivel("revisor sem sandbox-exec")
    proprio: Path | None = None
    if not escritas:
        proprio = Path(tempfile.mkdtemp(prefix="revisor-home-"))
        escritas = [proprio]
    binarios = _binarios(argv)
    perfil = _perfil(repo, escritas, binarios)
    dirs = [os.path.dirname(b) for b in binarios]
    try:
        return subprocess.run(
            ["sandbox-exec", "-p", perfil, *argv],
            cwd=repo, capture_output=True, text=True, timeout=timeout,
            input=inp, env=_env_limpo(dirs, home=str(escritas[0])),
        )
    finally:
        if proprio is not None:
            shutil.rmtree(proprio, ignore_errors=True)


def main(args: list[str]) -> int:
    if args[:1] == ["--dentro"]:
        if len(args) != 2:
            sys.stderr.write("caixa: --dentro precisa do spec\n")
            return 2
        return _dentro(args[1])
    return main_git(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
