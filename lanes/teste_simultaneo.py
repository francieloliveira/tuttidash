#!/usr/bin/env python3
"""Teste de execução simultânea de uma conta (PRD lanes-v2, fase 2, critério 6).

    teste_simultaneo.py <lane> [--espera SEGUNDOS]

Roda o comando real da lane (o mesmo que o dispatcher monta, no peso `baixo`) duas vezes
ao mesmo tempo, cada uma num repositório git temporário, e uma terceira logo depois. Duas
lanes da mesma conta dividem o login e o estado local do CLI (token, banco de sessões,
config); a terceira rodada confere que o login sobreviveu às duas primeiras.

Aprova quando as três saem com código 0 e nenhuma saída fala de banco travado, de outra
instância rodando ou de login perdido. O resultado fica em
`~/.transcentia/lanes/simultaneo-<conta>.json`, com a versão do CLI.

O dispatcher usa o registro assim: conta com lane extra ligada (instância) roda uma lane
por vez até o teste aprovar, e volta a uma por vez se ele reprovar ou passar de 30 dias.
O arquivo mora no home, gravável pelo mesmo usuário: é consistência, não barreira
(como o `sonda-acp-<agente>.json`). O pior que um registro forjado faz é deixar duas
lanes da conta rodarem juntas.

Custo: três respostas curtas ("OK") no modelo do peso `baixo` da lane.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Optional

ESTADO = Path.home() / ".transcentia" / "lanes"
VALIDADE_DIAS = 30
PESO = "baixo"
PROMPT = ("Teste automático do TuttiDash (execução simultânea). Não use nenhuma ferramenta, "
          "não leia nem crie arquivos. Responda só a palavra OK.")
# Sinais de estado partilhado que não aguentou duas execuções, ou de login perdido.
SINAIS = re.compile(
    r"database is locked|SQLITE_BUSY|\bEBUSY\b|resource busy|lock ?file|"
    r"another (?:instance|process)|already running|not logged in|"
    r"please (?:log ?in|sign in)|unauthori[sz]ed|invalid (?:api key|token)|"
    r"token (?:expired|revoked)", re.I)
_PATH = ":".join([str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                  "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin",
                  "/usr/bin", "/bin", "/usr/sbin", "/sbin"])


# --- Registro ------------------------------------------------------------------
def arquivo(conta: str, estado: Path = ESTADO) -> Path:
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", conta or ""):
        raise ValueError(f"conta inválida: {conta!r}")
    return estado / f"simultaneo-{conta}.json"


def ler(conta: str, estado: Path = ESTADO) -> Optional[dict]:
    try:
        d = json.loads(arquivo(conta, estado).read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return None
    return d if isinstance(d, dict) else None


def gravar(conta: str, resultado: dict, estado: Path = ESTADO) -> Path:
    estado.mkdir(parents=True, exist_ok=True)
    destino = arquivo(conta, estado)
    tmp = destino.with_suffix(".json.tmp")
    dados = dict(resultado, conta=conta, quando=dt.datetime.now().isoformat(timespec="seconds"))
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(destino)
    return destino


def situacao(conta: str, estado: Path = ESTADO,
             agora: Optional[dt.datetime] = None) -> tuple:
    """("aprovado" | "reprovado" | "vencido" | "pendente", texto)."""
    r = ler(conta, estado)
    if not r:
        return "pendente", "sem teste de execução simultânea"
    try:
        quando = dt.datetime.fromisoformat(str(r.get("quando")))
    except ValueError:
        return "pendente", "registro do teste ilegível"
    data = quando.strftime("%d/%m %H:%M")
    if r.get("ok") is not True:
        return "reprovado", f"teste de execução simultânea reprovado em {data}: {r.get('motivo') or '?'}"
    if ((agora or dt.datetime.now()) - quando).days > VALIDADE_DIAS:
        return "vencido", f"teste de execução simultânea de {data} venceu ({VALIDADE_DIAS} dias)"
    return "aprovado", f"teste de execução simultânea aprovado em {data}"


# --- Execução --------------------------------------------------------------------
def ambiente(lane: str) -> dict:
    """O mesmo ambiente limpo do `run_lane.sh` (FRA-269): sem .zshrc, PATH explícito."""
    zdot = ESTADO / "zdotdir-limpo"
    zdot.mkdir(parents=True, exist_ok=True)
    env = {"HOME": str(Path.home()), "USER": os.environ.get("USER", ""),
           "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "")),
           "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "LANG": os.environ.get("LANG", "pt_BR.UTF-8"),
           "TERM": "xterm-256color", "PATH": _PATH, "SHELL": "/bin/bash",
           "ZDOTDIR": str(zdot), "LANE": lane}
    if os.environ.get("DEEPSEEK_API_KEY"):
        env["DEEPSEEK_API_KEY"] = os.environ["DEEPSEEK_API_KEY"]
    return env


def repo_temp(base: Path, nome: str) -> Path:
    git = shutil.which("git", path=_PATH) or "/usr/bin/git"
    r = base / nome
    r.mkdir()
    subprocess.run([git, "init", "-q"], cwd=r, check=True)
    subprocess.run([git, "-c", "user.name=TuttiDash", "-c", "user.email=teste@localhost",
                    "commit", "-q", "--allow-empty", "-m", "teste"], cwd=r, check=True)
    return r


def avaliar(rc: Optional[int], saida: str) -> Optional[str]:
    """Motivo da reprovação desta rodada, ou None."""
    if rc is None:
        return "não terminou no tempo"
    m = SINAIS.search(saida or "")
    if m:
        return f"saída fala de '{m.group(0)}'"
    if rc != 0:
        ultima = next((l for l in reversed((saida or "").strip().splitlines()) if l.strip()), "")
        return f"código {rc}" + (f" ({ultima[:160]})" if ultima else "")
    if not re.search(r"\bOK\b", saida or "", re.I):
        return "saiu com código 0 sem responder OK"
    return None


def _rodar(texto: str, cwd: Path, prompt: Path, env: dict) -> subprocess.Popen:
    entrada = open(prompt, "rb")
    try:
        return subprocess.Popen(["/bin/bash", "--noprofile", "--norc", "-c", texto], cwd=cwd,
                                stdin=entrada, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=env)
    finally:
        entrada.close()


def _esperar(p: subprocess.Popen, ate: float) -> tuple:
    try:
        saida, _ = p.communicate(timeout=max(1.0, ate - time.monotonic()))
        return p.returncode, saida.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        p.kill()
        saida, _ = p.communicate()
        return None, saida.decode("utf-8", "replace")


def versao_cli(cli: str) -> str:
    exe = shutil.which(cli, path=_PATH)
    if not exe:
        return ""
    try:
        r = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (r.stdout or r.stderr).strip().splitlines()[0][:120] if (r.stdout or r.stderr).strip() else ""


def executar(lane: str, d, espera: float = 240.0,
             rodar: Callable = _rodar) -> dict:
    """Duas rodadas ao mesmo tempo e uma depois. `d` é o módulo do dispatcher."""
    cli = d.catalogo.cli_da_lane(lane)
    base = Path(tempfile.mkdtemp(prefix="tuttidash-simultaneo-"))
    try:
        run = base / "run"
        run.mkdir()
        prompt = run / "prompt.md"
        prompt.write_text(PROMPT + "\n", encoding="utf-8")
        patch = None
        if cli == "dsh":
            patch = run / "deepseek.yml"
            patch.write_text(d.deepseek_patch(PESO, lane), encoding="utf-8")
        if cli == "grok":
            d.escrever_perfil_sandbox()
        texto = d.texto_do_agente(lane, PESO, prompt, patch)
        env = ambiente(lane)
        rodadas = []
        inicio = time.monotonic()
        juntos = [rodar(texto, repo_temp(base, f"r{i}"), prompt, env) for i in (1, 2)]
        for i, p in enumerate(juntos, 1):
            rc, saida = _esperar(p, inicio + espera)
            rodadas.append({"rodada": f"simultânea {i}", "rc": rc, "motivo": avaliar(rc, saida),
                            "segundos": round(time.monotonic() - inicio, 1)})
        depois = time.monotonic()
        rc, saida = _esperar(rodar(texto, repo_temp(base, "r3"), prompt, env), depois + espera)
        rodadas.append({"rodada": "depois (login continua)", "rc": rc, "motivo": avaliar(rc, saida),
                        "segundos": round(time.monotonic() - depois, 1)})
        falhas = [f"{r['rodada']}: {r['motivo']}" for r in rodadas if r["motivo"]]
        return {"ok": not falhas, "motivo": "; ".join(falhas), "lane": lane, "cli": cli,
                "modelo": d.modelo_da_lane(lane, PESO), "rodadas": rodadas}
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Teste de execução simultânea de uma conta")
    ap.add_argument("lane", help="lane da conta a testar (ex.: claude, opencode-go)")
    ap.add_argument("--espera", type=float, default=240.0)
    args = ap.parse_args(argv)
    aqui = Path(__file__).resolve().parent
    if str(aqui) not in sys.path:
        sys.path.insert(0, str(aqui))
    import dispatcher as d  # noqa: E402 — monta o comando como o dispatcher monta
    if args.lane not in d.LANES:
        print(f"lane desconhecida: {args.lane}", file=sys.stderr)
        return 2
    conta = d.catalogo.conta_da_lane(args.lane)
    resultado = executar(args.lane, d, args.espera)
    resultado["versao"] = versao_cli(resultado["cli"])
    destino = gravar(conta, resultado)
    print(json.dumps({"conta": conta, **resultado, "registro": str(destino)}, ensure_ascii=False, indent=2))
    return 0 if resultado["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
