#!/usr/bin/python3 -I
"""Comando `bancada` da lane (FRA-618): acesso controlado ao hardware na USB.

A lane roda no sandbox estrito (FRA-598). No modo bancada ela ganha só este
comando, que o Claude Code executa fora do sandbox (`excludedCommands` com o
caminho absoluto do bundle). Por isso tudo é conferido aqui:

* o diretório atual tem de estar dentro das worktrees de um projeto com
  `bancada.ativo` no cadastro;
* porta só `/dev/cu.usbmodem*` ou `/dev/cu.usbserial*`, e só um dispositivo de
  caractere de verdade;
* firmware só `.bin` regular dentro do worktree, sem symlink no caminho, em
  endereço alinhado a 4 KB;
* serial com tempo e tamanho limitados, saída no stdout (nada é gravado no repo);
* `esptool` com versão fixa, pelo `uv` de um caminho fixo.

Cada uso vai para `~/Library/Logs/TranscentIA/bancada.log` (fora do worktree).
Uso:
  bancada portas
  bancada chip [--porta P] [--chip C]
  bancada gravar [--porta P] [--chip C] ENDERECO ARQUIVO [ENDERECO ARQUIVO ...]
  bancada serial [--porta P] [--baud N] SEGUNDOS
"""
from __future__ import annotations

import datetime as dt
import glob
import json
import os
import re
import select
import stat
import subprocess
import sys
import termios
import time
from pathlib import Path

PADROES_PORTA = ("/dev/cu.usbmodem*", "/dev/cu.usbserial*")
BAUDS = {9600: termios.B9600, 57600: termios.B57600, 115200: termios.B115200,
         230400: termios.B230400}
SERIAL_MAX_S = 120
SERIAL_MAX_BYTES = 64 * 1024
FIRMWARE_MAX = 16 * 1024 * 1024
MAX_SEGMENTOS = 4
ENDERECO_MAX = 0x1000000
ESPTOOL = "esptool==4.8.1"
ESPTOOL_TIMEOUT_S = 300
SAIDA_MAX = 32 * 1024
CHIPS = {"auto", "esp32", "esp32s2", "esp32s3", "esp32c3", "esp32c6", "esp32h2"}
UV_CANDIDATOS = (Path.home() / ".local/bin/uv", Path("/opt/homebrew/bin/uv"), Path("/usr/local/bin/uv"))
LOG = Path.home() / "Library/Logs/TranscentIA/bancada.log"

USO = __doc__.split("Uso:\n", 1)[1]


class Recusa(Exception):
    """Pedido fora das regras. Sai 77, sem tocar no hardware."""


# --- Projeto e worktree ------------------------------------------------------
def _ativar_modulos() -> None:
    """`gasto_lanes/` ao lado do controle (bundle ou repo). Nunca `~/.transcentia`."""
    pasta = (Path(__file__).resolve().parent.parent / "gasto_lanes").resolve()
    if ".transcentia" in str(pasta) or not (pasta / "projetos.py").is_file():
        raise SystemExit("bancada: projetos.py não está no bundle; recusado")
    sys.path[:] = [str(pasta), *[p for p in sys.path if p and ".transcentia" not in p]]


def _dentro(caminho: Path, raiz: Path) -> bool:
    return caminho != raiz and str(caminho).startswith(str(raiz) + os.sep)


def worktree_do_card(cwd: Path, projetos: list) -> Path:
    """Worktree (filho direto das worktrees do projeto) que contém `cwd`.

    Só projetos ativos com bancada ligada no cadastro. Fora disso, recusa.
    """
    atual = Path(os.path.realpath(cwd))
    for p in projetos:
        if not (getattr(p, "ativo", False) and getattr(p, "bancada", False)):
            continue
        if not str(p.worktrees):
            continue
        raiz = Path(os.path.realpath(p.worktrees))
        if str(raiz) in ("/", str(Path.home())) or not _dentro(atual, raiz):
            continue
        return raiz / atual.relative_to(raiz).parts[0]
    raise Recusa("o diretório atual não é worktree de um projeto com bancada ligada")


# --- Portas ------------------------------------------------------------------
def portas(padroes=PADROES_PORTA) -> list[str]:
    """Portas USB serial presentes: dispositivo de caractere, sem symlink."""
    achadas = []
    for padrao in padroes:
        for caminho in glob.glob(padrao):
            try:
                st = os.lstat(caminho)
            except OSError:
                continue
            if stat.S_ISCHR(st.st_mode):
                achadas.append(caminho)
    return sorted(set(achadas))


def escolher_porta(pedida: str | None, disponiveis: list[str]) -> str:
    if pedida is not None:
        if pedida not in disponiveis:
            raise Recusa(f"porta fora da lista: {pedida}")
        return pedida
    if len(disponiveis) == 1:
        return disponiveis[0]
    if not disponiveis:
        raise Recusa("nenhuma porta USB serial encontrada")
    raise Recusa("mais de uma porta; diga qual com --porta")


# --- Firmware ----------------------------------------------------------------
def endereco(texto: str) -> int:
    if not re.fullmatch(r"0x[0-9a-fA-F]{1,7}", texto or ""):
        raise Recusa(f"endereço inválido: {texto!r} (use hexadecimal, ex.: 0x0)")
    valor = int(texto, 16)
    if valor >= ENDERECO_MAX or valor % 0x1000:
        raise Recusa(f"endereço fora do limite ou não alinhado a 4 KB: {texto}")
    return valor


def firmware_no_worktree(rel: str, cwd: Path, wt: Path) -> Path:
    """`.bin` regular dentro do worktree, sem symlink em nenhum trecho do caminho."""
    if not rel or "\0" in rel or rel.startswith("-"):
        raise Recusa("arquivo de firmware inválido")
    alvo = Path(rel) if os.path.isabs(rel) else Path(cwd) / rel
    alvo = Path(os.path.abspath(alvo))
    raiz = Path(os.path.realpath(wt))
    if not _dentro(alvo, raiz):
        raise Recusa(f"firmware fora do worktree: {rel}")
    trecho = raiz
    for parte in alvo.relative_to(raiz).parts:
        trecho = trecho / parte
        if os.path.islink(trecho):
            raise Recusa(f"symlink no caminho do firmware: {rel}")
    try:
        st = os.lstat(alvo)
    except OSError:
        raise Recusa(f"firmware não existe: {rel}") from None
    if not stat.S_ISREG(st.st_mode) or alvo.suffix.lower() != ".bin":
        raise Recusa(f"firmware tem de ser um arquivo .bin regular: {rel}")
    if st.st_size == 0 or st.st_size > FIRMWARE_MAX:
        raise Recusa(f"firmware vazio ou maior que {FIRMWARE_MAX // (1024 * 1024)} MB: {rel}")
    return alvo


def segmentos(args: list[str], cwd: Path, wt: Path) -> list[tuple[str, Path]]:
    if not args or len(args) % 2 or len(args) // 2 > MAX_SEGMENTOS:
        raise Recusa(f"use ENDERECO ARQUIVO, de 1 a {MAX_SEGMENTOS} pares")
    pares = []
    for i in range(0, len(args), 2):
        valor = endereco(args[i])
        pares.append((f"0x{valor:x}", firmware_no_worktree(args[i + 1], cwd, wt)))
    return pares


# --- esptool -----------------------------------------------------------------
def uv_fixo(candidatos=UV_CANDIDATOS) -> Path:
    for c in candidatos:
        if c.is_file() and os.access(c, os.X_OK) and ".transcentia" not in str(c.resolve()):
            return c
    raise Recusa("uv não encontrado (instale: https://docs.astral.sh/uv/)")


def comando_esptool(uv: Path, chip: str, porta: str, args: list[str]) -> list[str]:
    if chip not in CHIPS:
        raise Recusa(f"chip fora da lista: {chip}")
    return [str(uv), "tool", "run", "--from", ESPTOOL, "esptool",
            "--chip", chip, "--port", porta, *args]


def rodar(argv: list[str], timeout: int = ESPTOOL_TIMEOUT_S) -> int:
    env = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}
    try:
        proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"bancada: esptool passou de {timeout} s; interrompido", file=sys.stderr)
        return 124
    saida = (proc.stdout + proc.stderr)[-SAIDA_MAX:]
    sys.stdout.write(saida)
    return proc.returncode


# --- Serial ------------------------------------------------------------------
def ler_serial(porta: str, segundos: int, baud: int, saida=sys.stdout) -> int:
    fd = os.open(porta, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = 0                                   # iflag
        attrs[1] = 0                                   # oflag
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0                                   # lflag: modo cru
        attrs[4] = attrs[5] = BAUDS[baud]
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        fim = time.monotonic() + segundos
        lidos = 0
        while lidos < SERIAL_MAX_BYTES:
            resta = fim - time.monotonic()
            if resta <= 0:
                break
            pronto, _, _ = select.select([fd], [], [], min(resta, 0.5))
            if not pronto:
                continue
            bloco = os.read(fd, min(4096, SERIAL_MAX_BYTES - lidos))
            if not bloco:
                break
            lidos += len(bloco)
            saida.write(bloco.decode("utf-8", "replace"))
            saida.flush()
        if lidos >= SERIAL_MAX_BYTES:
            saida.write(f"\n[bancada: parou em {SERIAL_MAX_BYTES} bytes]\n")
        return 0
    finally:
        os.close(fd)


def segundos_serial(texto: str) -> int:
    if not re.fullmatch(r"[0-9]{1,3}", texto or ""):
        raise Recusa("SEGUNDOS tem de ser um inteiro")
    valor = int(texto)
    if not 1 <= valor <= SERIAL_MAX_S:
        raise Recusa(f"SEGUNDOS entre 1 e {SERIAL_MAX_S}")
    return valor


# --- Auditoria ---------------------------------------------------------------
def auditar(linha: dict, log: Path = LOG) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.write(fd, (json.dumps(linha, ensure_ascii=False) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


# --- Linha de comando --------------------------------------------------------
def _opcoes(args: list[str], aceitas: set[str]) -> tuple[dict, list[str]]:
    opcoes, resto = {}, []
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            if a not in aceitas or i + 1 >= len(args):
                raise Recusa(f"opção inválida: {a}")
            opcoes[a] = args[i + 1]
            i += 2
            continue
        resto.append(a)
        i += 1
    return opcoes, resto


def executar(argv: list[str], cwd: Path, projetos: list, achar_portas=portas,
             uv=uv_fixo, rodar_cmd=rodar, serial=ler_serial) -> int:
    if not argv:
        raise Recusa("falta o subcomando\n" + USO)
    sub, args = argv[0], argv[1:]
    wt = worktree_do_card(cwd, projetos)
    if sub == "portas":
        if args:
            raise Recusa("`portas` não aceita argumentos")
        lista = achar_portas()
        print("\n".join(lista) if lista else "nenhuma porta USB serial encontrada")
        return 0
    if sub == "chip":
        op, resto = _opcoes(args, {"--porta", "--chip"})
        if resto:
            raise Recusa("`chip` só aceita --porta e --chip")
        porta = escolher_porta(op.get("--porta"), achar_portas())
        return rodar_cmd(comando_esptool(uv(), op.get("--chip", "auto"), porta, ["chip_id"]))
    if sub == "gravar":
        op, resto = _opcoes(args, {"--porta", "--chip"})
        pares = segmentos(resto, cwd, wt)
        porta = escolher_porta(op.get("--porta"), achar_portas())
        flash = ["write_flash"] + [x for e, arq in pares for x in (e, str(arq))]
        return rodar_cmd(comando_esptool(uv(), op.get("--chip", "auto"), porta, flash))
    if sub == "serial":
        op, resto = _opcoes(args, {"--porta", "--baud"})
        if len(resto) != 1:
            raise Recusa("use: serial [--porta P] [--baud N] SEGUNDOS")
        segundos = segundos_serial(resto[0])
        baud_txt = op.get("--baud", "115200")
        if not baud_txt.isdigit() or int(baud_txt) not in BAUDS:
            raise Recusa(f"baud fora da lista: {baud_txt} (aceitos: {sorted(BAUDS)})")
        porta = escolher_porta(op.get("--porta"), achar_portas())
        return serial(porta, segundos, int(baud_txt))
    raise Recusa(f"subcomando desconhecido: {sub}\n" + USO)


def main(argv: list[str]) -> int:
    _ativar_modulos()
    import projetos  # noqa: E402

    cwd = Path.cwd()
    registro = {"at": dt.datetime.now().isoformat(timespec="seconds"), "cwd": str(cwd),
                "argv": argv[:12]}
    try:
        rc = executar(argv, cwd, projetos.projetos())
    except Recusa as exc:
        print(f"bancada: recusado: {exc}", file=sys.stderr)
        rc = 77
        registro["recusa"] = str(exc).splitlines()[0]
    registro["rc"] = rc
    try:
        auditar(registro)
    except OSError as exc:
        print(f"bancada: não gravei a auditoria ({exc})", file=sys.stderr)
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
