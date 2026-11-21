"""Instalação por projeto: serviço, artefato instalável e nenhuma.

O TuttiDash não sabe instalar "um tipo de projeto": sabe conversar com **três
classes de instalação** declaradas no cadastro (`projetos[].entrega`; a chave
do config.json continua `entrega`, o código chama de instalação):

  - `servico`  — há um processo que fica de pé (comando, porta, saúde, URL);
  - `artefato` — há um pacote produzido e instalado num destino (empacotar,
                 validar, instalar; a versão é lida do artefato instalado);
  - `nenhuma`  — não se instala; a versão é o commit/tag no git.

Formato (todos os campos opcionais; sem `entrega` = `nenhuma`):

    "entrega": {
      "classe": "servico",
      "subir": ["python3", "servidor.py", "--porta", "{porta}"],
      "parar": [],
      "porta": 8000,
      "saude": "http://127.0.0.1:{porta}/saude",
      "url": "http://127.0.0.1:{porta}/",
      "versao": []
    }

Comandos são **argv** (lista) e rodam sem shell. Texto também é aceito, por
compatibilidade com o cadastro escrito à mão: é partido com `shlex.split` e
executado sem shell, nunca por `shell=True`. Os marcadores `{porta}`,
`{artefato}`, `{destino}`, `{pid}`, `{log}`, `{ref}`, `{worktree}`, `{head}` e
`{repo}` são trocados em cada argumento.

Instalar uma versão (`instalar --ref <branch|tag|sha>`): o comando roda num
worktree isolado, `<worktrees>/instalar-<ref>`, atualizado em `origin/<ref>`
(ou na tag/SHA pedidos). Assim dá para instalar qualquer branch sem mexer no
checkout principal nem nas lanes; `empacotar` e `validar` rodam antes, no mesmo
worktree, quando o projeto os declara. A lista de versões fica em `refs`
(branches remotas + tags, com `git fetch`).

Estado por projeto em `~/.transcentia/instalacoes/<id>.json`, escrito de forma
atômica. O log de cada execução fica em `~/.transcentia/instalacoes/logs/`.

Trava: enquanto houver lane com card no projeto, `empacotar`, `validar`,
`instalar`, `subir` e `parar` são recusados, com o motivo no estado. A lane é
reconhecida por `lane-<nome>.json` com `projeto` igual ao do cadastro; arquivo
antigo sem `projeto` conta para o projeto padrão (é nele que o dispatcher
trabalhava quando o campo não existia).

Somente Python 3 da stdlib.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

try:                                          # módulo importado como `gasto_lanes.instalar`
    from . import projetos as _projetos
except ImportError:                           # script solto (`tools/instalar.py`)
    import projetos as _projetos  # type: ignore

CLASSES = ("nenhuma", "servico", "artefato")
ACOES = ("empacotar", "validar", "instalar", "subir", "parar")
CAMPOS_CMD = ("empacotar", "validar", "instalar", "subir", "parar", "versao")

# PATH fixo: o app chama isto fora do terminal, sem o ambiente do shell.
AMBIENTE = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
# `instalar` pode esperar lane terminar (o comando do projeto decide, até ~2 h:
# `tools/reinstalar-app.sh` espera 120 min). Matar a espera deixaria o PAUSE criado.
TIMEOUT = {"empacotar": 3600, "validar": 900, "instalar": 9000}
ESPERA_SAUDE_S = 20
ESPERA_PARAR_S = 8
LINHAS_LOG = 40


class ErroInstalacao(Exception):
    """Recusa com motivo legível. Quem chama mostra o texto; nada fica calado."""


@dataclass
class Instalacao:
    classe: str = "nenhuma"
    classe_declarada: str = "nenhuma"
    empacotar: tuple = ()
    validar: tuple = ()
    instalar: tuple = ()
    subir: tuple = ()
    parar: tuple = ()
    versao: tuple = ()
    porta: int = 0
    saude: str = ""
    url: str = ""
    artefato: str = ""
    destino: str = ""
    requer_admin: bool = False
    erros: tuple = field(default=())

    @property
    def configurada(self) -> bool:
        return self.classe != "nenhuma"


# --------------------------------------------------------------------------
# Cadastro


def _cmd(bruto, campo: str, erros: list) -> tuple:
    """Comando do cadastro -> argv. Lista é argv; texto é partido com shlex, sem shell."""
    if bruto is None or bruto == "" or bruto == []:
        return ()
    if isinstance(bruto, list):
        partes = []
        for item in bruto:
            if not isinstance(item, str) or not item.strip():
                erros.append(f"{campo}: a lista só aceita textos não vazios")
                return ()
            partes.append(item)
        return tuple(partes)
    if isinstance(bruto, str):
        try:
            partes = shlex.split(bruto)
        except ValueError as exc:
            erros.append(f"{campo}: comando ilegível ({exc})")
            return ()
        return tuple(partes)
    erros.append(f"{campo}: use uma lista de argv ou uma linha de comando")
    return ()


def _texto(bruto) -> str:
    return bruto.strip() if isinstance(bruto, str) else ""


def _porta(bruto, erros: list) -> int:
    if bruto is None or bruto == "":
        return 0
    try:
        n = int(bruto)
    except (TypeError, ValueError):
        erros.append("porta: use um número inteiro")
        return 0
    if not 0 < n < 65536:
        erros.append("porta: use um número entre 1 e 65535")
        return 0
    return n


def de_projeto(projeto) -> Instalacao:
    """`projetos[].entrega` -> `Instalacao`, com os erros de cadastro em `erros`."""
    bruto = getattr(projeto, "instalacao", {})
    if not isinstance(bruto, dict) or not bruto:
        return Instalacao()
    erros: list = []
    declarada = str(bruto.get("classe") or "nenhuma").strip().lower()
    if declarada not in CLASSES:
        erros.append(f"classe desconhecida: «{declarada}» (use servico, artefato ou nenhuma)")
        classe = "nenhuma"
    else:
        classe = declarada
    e = Instalacao(classe=classe, classe_declarada=declarada,
                porta=_porta(bruto.get("porta"), erros),
                saude=_texto(bruto.get("saude")),
                url=_texto(bruto.get("url")),
                artefato=os.path.expanduser(_texto(bruto.get("artefato"))),
                destino=os.path.expanduser(_texto(bruto.get("destino"))),
                requer_admin=bruto.get("requer_admin") is True,
                erros=tuple(erros))
    for campo in CAMPOS_CMD:
        setattr(e, campo, _cmd(bruto.get(campo), campo, erros))
    e.erros = tuple(erros)
    return e


# --------------------------------------------------------------------------
# Estado


def pasta_estado(home=None) -> Path:
    base = Path(home) if home else Path.home()
    return base / ".transcentia" / "instalacoes"


def _arquivo_estado(projeto, home=None) -> Path:
    return pasta_estado(home) / f"{projeto.id}.json"


def _ler_estado(projeto, home=None) -> dict:
    try:
        dados = json.loads(_arquivo_estado(projeto, home).read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return {}
    return dados if isinstance(dados, dict) else {}


def _gravar_estado(projeto, dados: dict, home=None) -> None:
    pasta = pasta_estado(home)
    pasta.mkdir(parents=True, exist_ok=True)
    alvo = _arquivo_estado(projeto, home)
    tmp = alvo.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(dados, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, alvo)


@contextmanager
def _serializado(projeto, home=None):
    """Uma ação por projeto por vez: o clique duplo não sobe dois processos."""
    pasta = pasta_estado(home)
    pasta.mkdir(parents=True, exist_ok=True)
    trava = pasta / f"{projeto.id}.lock"
    with trava.open("w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def _agora() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _vivo(pid) -> bool:
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    # Filho desta execução já terminado fica como zumbi até ser colhido, e o
    # `kill(pid, 0)` continua respondendo. `waitpid` sem bloquear resolve.
    try:
        colhido, _status = os.waitpid(pid, os.WNOHANG)
    except (ChildProcessError, OSError):
        return True
    return colhido != pid


def _sinal(pid: int, sig: int) -> None:
    """Sinal no grupo do processo (start_new_session faz pid == pgid)."""
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def _repo(projeto) -> Path:
    pasta = Path(str(getattr(projeto, "repo", ""))).expanduser()
    if not str(pasta) or not pasta.is_dir():
        raise ErroInstalacao(f"a pasta do projeto não existe: {pasta or '(vazia)'}")
    return pasta


def _expandir(partes, e: Instalacao, pid=None, log: Path | None = None, extras=None) -> list:
    trocas = {
        "{porta}": str(e.porta or ""),
        "{artefato}": e.artefato or "",
        "{destino}": e.destino or "",
        "{pid}": str(pid or ""),
        "{log}": str(log or ""),
    }
    if extras:
        trocas.update(extras)
    saida = []
    for parte in partes:
        for chave, valor in trocas.items():
            parte = parte.replace(chave, valor)
        saida.append(parte)
    return saida


def _endereco(valor: str, e: Instalacao) -> str:
    return valor.replace("{porta}", str(e.porta or ""))


def _novo_log(projeto, acao: str, home=None) -> Path:
    pasta = pasta_estado(home) / "logs"
    pasta.mkdir(parents=True, exist_ok=True)
    carimbo = datetime.now().strftime("%Y%m%d-%H%M%S")
    return pasta / f"{projeto.id}-{acao}-{carimbo}.log"


def _cabecalho(log: Path, acao: str, argv: list) -> None:
    with log.open("a", encoding="utf-8") as fh:
        fh.write(f"# {_agora()} · {acao}: {' '.join(shlex.quote(x) for x in argv)}\n")


def _rodar(projeto, e: Instalacao, acao: str, argv: tuple, home=None,
           cwd=None, extras=None, env_extra=None) -> tuple:
    """Roda um comando de instalação e devolve (codigo, log, saida). Sem shell."""
    if not argv:
        raise ErroInstalacao(f"{acao}: o cadastro não tem comando para isso")
    log = _novo_log(projeto, acao, home)
    partes = _expandir(argv, e, log=log, extras=extras)
    _cabecalho(log, acao, partes)
    with log.open("a", encoding="utf-8") as fh:
        try:
            ambiente = dict(AMBIENTE)
            if env_extra:
                ambiente.update(env_extra)
            r = subprocess.run(partes, cwd=str(cwd or _repo(projeto)), env=ambiente,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=TIMEOUT.get(acao, 600))
        except FileNotFoundError:
            fh.write("[instalar] programa não encontrado\n")
            return 127, log, "programa não encontrado"
        except subprocess.TimeoutExpired as exc:
            saida = (exc.output or b"").decode("utf-8", "replace") if isinstance(exc.output, bytes) else ""
            fh.write(saida)
            fh.write(f"\n[instalar] tempo esgotado ({TIMEOUT.get(acao, 600)} s)\n")
            return 124, log, "tempo esgotado"
        texto = r.stdout.decode("utf-8", "replace") if isinstance(r.stdout, bytes) else str(r.stdout or "")
        fh.write(texto)
        if texto and not texto.endswith("\n"):
            fh.write("\n")
        fh.write(f"[instalar] fim código {r.returncode}\n")
    return r.returncode, log, texto


def _ultimas_linhas(log, limite: int = LINHAS_LOG) -> list:
    try:
        linhas = Path(log).read_text(encoding="utf-8", errors="replace").splitlines()
    except (OSError, TypeError):
        return []
    return linhas[-limite:]


def _saude(endereco: str) -> tuple:
    """(ok, versao, erro) do health check. Sem endereço, (None, '', '')."""
    if not endereco:
        return None, "", ""
    try:
        with urllib.request.urlopen(endereco, timeout=2) as r:
            corpo = r.read(20000)
            ok = 200 <= getattr(r, "status", 0) < 300
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return False, "", str(exc)
    if not ok:
        return False, "", f"health check respondeu {getattr(r, 'status', '?')}"
    versao = ""
    try:
        dados = json.loads(corpo.decode("utf-8", "replace"))
        if isinstance(dados, dict):
            for chave in ("versao", "version", "commit", "sha"):
                if isinstance(dados.get(chave), (str, int, float)):
                    versao = str(dados[chave])
                    break
    except (ValueError, UnicodeError):
        pass
    return True, versao, ""


def _versao_do_app(caminho: str) -> str:
    if not caminho.endswith(".app"):
        return ""
    plist = Path(caminho) / "Contents" / "Info.plist"
    if not plist.is_file():
        return ""
    for chave in ("CFBundleShortVersionString", "CFBundleVersion"):
        try:
            r = subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print :{chave}", str(plist)],
                               capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    return ""


def _versao(projeto, e: Instalacao, caminho: str = "") -> str:
    if e.versao:
        try:
            codigo, _log, saida = _rodar(projeto, e, "versao", e.versao)
        except ErroInstalacao:
            return ""
        if codigo == 0:
            linhas = [l.strip() for l in saida.splitlines() if l.strip()]
            if linhas:
                return linhas[-1]
    for alvo in (caminho, e.destino, e.artefato):
        v = _versao_do_app(alvo)
        if v:
            return v
    return ""


def _versao_git(projeto) -> str:
    try:
        r = subprocess.run(["/usr/bin/git", "-C", str(_repo(projeto)), "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, timeout=10, env=AMBIENTE)
    except (OSError, subprocess.SubprocessError, ErroInstalacao):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


# --------------------------------------------------------------------------
# Versões (branches, tags e SHAs)

# Caracteres que o nome da ref não pode ter: o fluxo não abre shell, mas estes
# também atrapalham git, log e nome de pasta. `git check-ref-format` é a
# autoridade para branch; aqui é só a barreira barata antes dele.
_REF_PROIBIDOS = ("$", ";", "`", "|", "&", ">", "<", "\n", "\r", "\t", " ")


def _git(projeto, *args, cwd=None, timeout=60):
    return subprocess.run(["/usr/bin/git", "-C", str(cwd or _repo(projeto)), *args],
                          capture_output=True, text=True, timeout=timeout, env=AMBIENTE)


def validar_ref(ref: str) -> str:
    """Nome de branch/tag/SHA aceitável. Recusa antes de tocar no git."""
    nome = (ref or "").strip()
    if not nome:
        raise ErroInstalacao("--ref: diga a branch, a tag ou o SHA")
    if len(nome) > 200:
        raise ErroInstalacao("--ref: nome longo demais (mais de 200 caracteres)")
    if nome.startswith("-"):
        raise ErroInstalacao(f"--ref: «{nome}» não pode começar com -")
    for proibido in _REF_PROIBIDOS:
        if proibido in nome:
            raise ErroInstalacao(f"--ref: «{nome}» tem caractere recusado ({proibido!r})")
    return nome


def refs(projeto, fetch=True) -> dict:
    """Versões que a tela oferece: branches remotas + tags (mais recente primeiro).

    `fetch` atualiza `origin` antes de listar; sem rede a lista vem do que já
    está no repositório e o motivo fica em `erro` — a tela mostra os dois.
    """
    aviso = ""
    if fetch:
        try:
            r = _git(projeto, "fetch", "-q", "--prune", "origin", timeout=120)
        except (OSError, subprocess.SubprocessError) as exc:
            r = None
            aviso = f"git fetch falhou: {exc}"
        if r is not None and r.returncode != 0:
            aviso = "git fetch falhou: " + (r.stderr.strip()[-300:] or f"código {r.returncode}")

    def lista(*refns, sort="-committerdate"):
        try:
            r = _git(projeto, "for-each-ref", f"--sort={sort}",
                     "--format=%(refname:short)", *refns, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return []
        if r.returncode != 0:
            return []
        return [linha.strip() for linha in r.stdout.splitlines() if linha.strip()]

    branches = []
    for nome in lista("refs/remotes/origin"):
        if nome in ("origin", "origin/HEAD") or nome.endswith("/HEAD"):
            continue
        branches.append(nome[len("origin/"):] if nome.startswith("origin/") else nome)
    # main sempre na lista: é o caminho normal de instalar, mesmo se o fetch falhar.
    branches = sorted(set(branches) | {"main"}, key=lambda n: (n != "main", n.lower()))
    tags = lista("refs/tags", sort="-creatordate")
    return {"ok": True, "projeto": projeto.id, "branches": branches,
            "tags": sorted(set(tags), key=str.lower), "erro": aviso}


def _commit_da_ref(projeto, ref: str) -> str:
    """SHA do commit da branch remota, da tag ou do SHA passado. Recusa o resto."""
    for candidato in (f"refs/remotes/origin/{ref}", f"refs/tags/{ref}", ref):
        try:
            r = _git(projeto, "rev-parse", "--verify", "--quiet", f"{candidato}^{{commit}}", timeout=30)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    raise ErroInstalacao(f"versão não encontrada no projeto: «{ref}» "
                         "(confira a branch em origin ou o nome da tag)")


def _slug_da_ref(ref: str) -> str:
    limpo = "".join(c if (c.isalnum() or c in "._-") else "-" for c in ref)
    limpo = "-".join(parte for parte in limpo.split("-") if parte)[:60].strip(".-")
    return limpo or "versao"


def _preparar_ref(projeto, ref: str) -> tuple:
    """Worktree isolado da versão pedida. Devolve (pasta, commit).

    O worktree é `<worktrees>/instalar-<ref>`; repo e pasta passam pelo mesmo
    `checar_alvo_instalar` das lanes antes de qualquer reset/clean. O checkout
    principal não é tocado.
    """
    nome = validar_ref(ref)
    try:
        r = _git(projeto, "fetch", "-q", "--prune", "origin", timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ErroInstalacao(f"git fetch falhou: {exc}") from exc
    if r.returncode != 0:
        raise ErroInstalacao("git fetch falhou: " + (r.stderr.strip()[-300:] or f"código {r.returncode}"))
    commit = _commit_da_ref(projeto, nome)
    if not str(getattr(projeto, "worktrees", "") or ""):
        raise ErroInstalacao("o projeto não declara pasta de worktrees")
    alvo = Path(str(projeto.worktrees)) / f"instalar-{_slug_da_ref(nome)}"
    codigo, texto = _projetos.checar_alvo_instalar(str(_repo(projeto)), str(alvo), cadastro=projeto)
    if codigo != 0:
        raise ErroInstalacao(texto or "worktree recusado")
    linhas = [linha for linha in texto.splitlines() if linha.strip()]
    if len(linhas) != 2:
        raise ErroInstalacao("repo ou worktree recusados: resposta inesperada do cadastro")
    wt = Path(linhas[1])
    if not wt.is_dir():
        r = _git(projeto, "worktree", "add", "-q", "--detach", str(wt), commit, timeout=300)
        if r.returncode != 0:
            raise ErroInstalacao("git worktree add falhou: " + (r.stderr.strip()[-300:] or f"código {r.returncode}"))
        return wt, commit
    # Pasta que já existe: só pode ser worktree deste repositório.
    r = _git(projeto, "rev-parse", "--show-toplevel", cwd=wt, timeout=30)
    if r.returncode != 0 or Path(r.stdout.strip()) != wt:
        raise ErroInstalacao(f"a pasta {wt} existe e não é worktree deste repositório")
    for passo in (("checkout", "-q", "--detach", commit),
                  ("reset", "-q", "--hard"),
                  ("clean", "-qfd", "-x", "-e", ".lane")):
        r = _git(projeto, *passo, cwd=wt, timeout=300)
        if r.returncode != 0:
            raise ErroInstalacao(f"git {passo[0]} falhou em {wt}: "
                                 + (r.stderr.strip()[-300:] or f"código {r.returncode}"))
    return wt, commit


# --------------------------------------------------------------------------
# Trava


def _lane_do_projeto(projeto, home=None) -> list:
    """Lanes com card no projeto. Arquivo antigo sem `projeto` conta para o padrão."""
    try:
        padrao = _projetos.padrao().id
    except Exception:  # noqa: BLE001 — sem cadastro legível: nenhuma lane casa
        padrao = ""
    achadas = []
    base = Path(home) if home else Path.home()
    for arq in sorted(base.joinpath(".transcentia", "lanes").glob("lane-*.json")):
        try:
            st = json.loads(arq.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError):
            continue
        if not isinstance(st, dict):
            continue
        dono = str(st.get("projeto") or "")
        if dono == projeto.id or (not dono and projeto.id == padrao):
            achadas.append(arq.stem.replace("lane-", "", 1))
    return achadas


def _exigir_livre(projeto, home=None) -> None:
    lanes = _lane_do_projeto(projeto, home)
    if lanes:
        raise ErroInstalacao(f"lane rodando no projeto: {', '.join(lanes)}; espere ela terminar")


def bloqueio(projeto, home=None) -> str:
    """Motivo para não agir agora (vazio = livre). O vigia usa antes de abrir a sessão."""
    lanes = _lane_do_projeto(projeto, home)
    return f"lane rodando no projeto: {', '.join(lanes)}" if lanes else ""


def _exigir(e: Instalacao, acao: str) -> None:
    if e.erros:
        raise ErroInstalacao("cadastro da entrega: " + "; ".join(e.erros))
    if e.classe != "artefato" and acao in ("empacotar", "validar", "instalar"):
        if e.classe == "nenhuma":
            raise ErroInstalacao("este projeto não se instala (entrega: nenhuma)")
        raise ErroInstalacao(f"{acao} é ação de artefato; este projeto entrega um serviço")
    if e.classe != "servico" and acao in ("subir", "parar"):
        if e.classe == "nenhuma":
            raise ErroInstalacao("este projeto não se instala (entrega: nenhuma)")
        raise ErroInstalacao(f"{acao} é ação de serviço; este projeto entrega um artefato")
    if acao == "subir" and not e.subir:
        raise ErroInstalacao("subir: o cadastro não tem comando para subir")
    if acao == "empacotar" and not e.empacotar:
        raise ErroInstalacao("empacotar: o cadastro não tem comando para empacotar")
    if acao == "instalar" and not e.instalar:
        raise ErroInstalacao("instalar: o cadastro não tem comando para instalar")
    if acao == "instalar" and not e.destino:
        raise ErroInstalacao("instalar: o cadastro não tem destino")


# --------------------------------------------------------------------------
# Estado público


def estado(projeto, home=None) -> dict:
    """Retrato honesto do projeto: classe, situação, versão, trava e último erro."""
    e = de_projeto(projeto)
    st = _ler_estado(projeto, home)
    base = {
        "projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
        "classe": e.classe, "classe_declarada": e.classe_declarada,
        "situacao": "sem leitura", "versao": "", "pid": None, "porta": e.porta or None,
        "url": _endereco(e.url, e), "artefato": e.artefato, "destino": e.destino,
        "inicio": "", "em": "", "erro": "", "log": "", "bloqueio": "",
        "ref": "", "head": "", "worktree": "", "acoes": [],
    }
    if e.erros:
        base["situacao"] = "cadastro inválido"
        base["erro"] = "; ".join(e.erros)
        base["bloqueio"] = base["erro"]
        return base
    if e.classe == "nenhuma":
        base["situacao"] = "nenhuma"
        base["versao"] = _versao_git(projeto)
        base["erro"] = ""
        return base

    # O que está gravado é ponto de partida; a realidade confere por cima.
    for chave in ("situacao", "versao", "pid", "porta", "url", "artefato", "destino",
                  "inicio", "em", "erro", "log", "ref", "head", "worktree"):
        if chave in st:
            base[chave] = st[chave]
    base["classe"] = e.classe
    base["porta"] = st.get("porta") or (e.porta or None)
    base["url"] = _endereco(e.url, e) or str(st.get("url") or "")
    base["artefato"] = e.artefato or str(st.get("artefato") or "")
    base["destino"] = e.destino or str(st.get("destino") or "")

    lanes = _lane_do_projeto(projeto, home)
    if lanes:
        base["bloqueio"] = f"lane rodando no projeto: {', '.join(lanes)}"
    base["acoes"] = _acoes_de(e)

    if e.classe == "servico":
        pid = base.get("pid")
        if pid and _vivo(pid):
            ok, versao, erro = _saude(_endereco(e.saude, e))
            if ok is False:
                base["situacao"] = "sem resposta"
                base["erro"] = erro
            else:
                base["situacao"] = "rodando"
                base["erro"] = ""
                if versao:
                    base["versao"] = versao
        elif base.get("situacao") == "rodando":
            base["situacao"] = "parado"
            base["pid"] = None
            base["erro"] = "o processo não está mais de pé"
        elif not pid and base.get("situacao") in ("", "sem leitura"):
            base["situacao"] = "parado"
            base["pid"] = None
    elif e.classe == "artefato":
        destino = e.destino
        if destino and not Path(destino).exists() and base.get("situacao") == "instalado":
            base["situacao"] = "não instalado"
            base["erro"] = f"o destino sumiu: {destino}"
        if destino and Path(destino).exists():
            versao = _versao(projeto, e, destino)
            if versao:
                base["versao"] = versao
    return base


def _acoes_de(e: Instalacao) -> list:
    if e.classe == "servico":
        return (["subir"] if e.subir else []) + ["parar"]
    if e.classe == "artefato":
        return (["empacotar"] if e.empacotar else []) + (["validar"] if e.validar else []) + \
               (["instalar"] if e.instalar else [])
    return []


def listar(home=None) -> list:
    return [estado(p, home=home) for p in _projetos.projetos()]


# --------------------------------------------------------------------------
# Ações


def _resposta(ok: bool, texto: str, st: dict) -> dict:
    return {"ok": bool(ok), "texto": texto, "estado": st}


def _falhar(projeto, e: Instalacao, st_ant: dict, log, acao: str, motivo: str, home=None) -> dict:
    """Falha não apaga o que já estava instalado/rodando: só registra o erro."""
    novo = dict(st_ant)
    novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                 "classe": e.classe, "erro": motivo, "em": _agora(), "log": str(log or ""),
                 "ultima_acao": acao})
    novo.setdefault("situacao", "falhou")
    if not novo.get("situacao") or novo.get("situacao") in ("sem leitura",):
        novo["situacao"] = "falhou"
    _gravar_estado(projeto, novo, home)
    return _resposta(False, motivo, estado(projeto, home))


def subir(projeto, home=None) -> dict:
    e = de_projeto(projeto)
    with _serializado(projeto, home):
        _exigir(e, "subir")
        _exigir_livre(projeto, home)
        st_ant = _ler_estado(projeto, home)
        if _vivo(st_ant.get("pid")):
            return _resposta(True, "já está rodando (nada duplicado)", estado(projeto, home))
        log = _novo_log(projeto, "subir", home)
        partes = _expandir(e.subir, e, log=log)
        _cabecalho(log, "subir", partes)
        fh = log.open("a", encoding="utf-8")
        try:
            proc = subprocess.Popen(partes, cwd=str(_repo(projeto)), env=AMBIENTE,
                                    stdout=fh, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as exc:
            fh.close()
            return _falhar(projeto, e, st_ant, log, "subir", f"não consegui subir: {exc}", home)
        limite = time.time() + ESPERA_SAUDE_S
        versao = ""
        while time.time() < limite:
            if proc.poll() is not None:
                fh.write(f"[entrega] o processo saiu com código {proc.returncode}\n")
                fh.close()
                linhas = "\n".join(_ultimas_linhas(log))
                return _falhar(projeto, e, st_ant, log, "subir",
                               "o processo saiu antes de responder" + (f"\n{linhas}" if linhas else ""), home)
            if e.saude:
                ok, versao, _erro = _saude(_endereco(e.saude, e))
                if ok:
                    break
            elif time.time() > limite - ESPERA_SAUDE_S + 1:
                break
            time.sleep(0.4)
        else:
            fh.write("[entrega] saúde não respondeu a tempo\n")
            fh.close()
            if proc.poll() is None:
                _sinal(proc.pid, signal.SIGTERM)
            return _falhar(projeto, e, st_ant, log, "subir",
                           f"o serviço não respondeu em {ESPERA_SAUDE_S} s", home)
        if not versao:
            versao = _versao(projeto, e)
        novo = dict(st_ant)
        novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                     "classe": e.classe, "situacao": "rodando", "pid": proc.pid,
                     "porta": e.porta or None, "url": _endereco(e.url, e),
                     "inicio": _agora(), "em": _agora(), "versao": versao,
                     "log": str(log), "erro": "", "ultima_acao": "subir"})
        _gravar_estado(projeto, novo, home)
        fh.close()
        return _resposta(True, f"no ar (pid {proc.pid})", estado(projeto, home))


def parar(projeto, home=None) -> dict:
    e = de_projeto(projeto)
    with _serializado(projeto, home):
        _exigir(e, "parar")
        _exigir_livre(projeto, home)
        st_ant = _ler_estado(projeto, home)
        pid = st_ant.get("pid")
        log = ""
        erro = ""
        if e.parar:
            codigo, log, _saida = _rodar(projeto, e, "parar", e.parar, home)
            if codigo != 0:
                erro = f"o comando de parar saiu {codigo}; tentei encerrar o processo"
        if _vivo(pid):
            _sinal(int(pid), signal.SIGTERM)
            limite = time.time() + ESPERA_PARAR_S
            while time.time() < limite and _vivo(pid):
                time.sleep(0.2)
            if _vivo(pid):
                _sinal(int(pid), signal.SIGKILL)
                time.sleep(0.2)
            if _vivo(pid):
                return _falhar(projeto, e, st_ant, log, "parar",
                               erro or f"o processo {pid} não terminou", home)
        novo = dict(st_ant)
        novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                     "classe": e.classe, "situacao": "parado", "pid": None,
                     "em": _agora(), "erro": erro, "ultima_acao": "parar"})
        if log:
            novo["log"] = str(log)
        _gravar_estado(projeto, novo, home)
        return _resposta(True, "parado", estado(projeto, home))


def empacotar(projeto, home=None) -> dict:
    e = de_projeto(projeto)
    with _serializado(projeto, home):
        _exigir(e, "empacotar")
        _exigir_livre(projeto, home)
        st_ant = _ler_estado(projeto, home)
        codigo, log, saida = _rodar(projeto, e, "empacotar", e.empacotar, home)
        if codigo != 0:
            return _falhar(projeto, e, st_ant, log, "empacotar",
                           f"empacotar saiu {codigo}" + (f": {saida.strip()[-400:]}" if saida.strip() else ""), home)
        if e.artefato and not Path(e.artefato).exists():
            return _falhar(projeto, e, st_ant, log, "empacotar",
                           f"o artefato não existe depois do empacotar: {e.artefato}", home)
        novo = dict(st_ant)
        novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                     "classe": e.classe, "situacao": "empacotado", "artefato": e.artefato,
                     "versao": _versao(projeto, e, e.artefato), "em": _agora(),
                     "log": str(log), "erro": "", "ultima_acao": "empacotar"})
        _gravar_estado(projeto, novo, home)
        return _resposta(True, "empacotado", estado(projeto, home))


def validar(projeto, home=None) -> dict:
    e = de_projeto(projeto)
    with _serializado(projeto, home):
        _exigir(e, "validar")
        _exigir_livre(projeto, home)
        st_ant = _ler_estado(projeto, home)
        codigo, log, saida = _rodar(projeto, e, "validar", e.validar, home)
        if codigo != 0:
            return _falhar(projeto, e, st_ant, log, "validar",
                           f"validar saiu {codigo}" + (f": {saida.strip()[-400:]}" if saida.strip() else ""), home)
        novo = dict(st_ant)
        novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                     "classe": e.classe, "validado_em": _agora(), "em": _agora(),
                     "log": str(log), "erro": "", "ultima_acao": "validar"})
        novo.setdefault("situacao", "validado")
        _gravar_estado(projeto, novo, home)
        return _resposta(True, "válido", estado(projeto, home))


def instalar(projeto, home=None, ref="") -> dict:
    """Instala o artefato. Com `ref`, builda a versão num worktree isolado.

    `ref` aceita branch (de `origin`), tag ou SHA. Nesse modo `empacotar` e
    `validar` rodam antes, no mesmo worktree, para o pacote sair da versão
    pedida — nunca do checkout principal.
    """
    e = de_projeto(projeto)
    with _serializado(projeto, home):
        _exigir(e, "instalar")
        _exigir_livre(projeto, home)
        st_ant = _ler_estado(projeto, home)
        cwd = None
        extras = {}
        env_extra = {}
        versao_ref = ""
        if ref:
            versao_ref = validar_ref(ref)
            wt, commit = _preparar_ref(projeto, versao_ref)
            cwd = wt
            extras = {"{ref}": versao_ref, "{worktree}": str(wt), "{head}": commit,
                      "{repo}": str(_repo(projeto))}
            # Dados locais do build (.env, profile) vivem no checkout principal, não no
            # worktree: o comando recebe onde achar, sem tocar nesses arquivos.
            env_extra = {"TUTTIDASH_REPO_MAIN": str(_repo(projeto)),
                         "TUTTIDASH_REF": versao_ref,
                         "TUTTIDASH_WORKTREE": str(wt)}
            if e.empacotar:
                codigo, log, saida = _rodar(projeto, e, "empacotar", e.empacotar, home,
                                            cwd=wt, extras=extras, env_extra=env_extra)
                if codigo != 0:
                    return _falhar(projeto, e, st_ant, log, "empacotar",
                                   f"empacotar saiu {codigo}" +
                                   (f": {saida.strip()[-400:]}" if saida.strip() else ""), home)
                if e.artefato and not Path(e.artefato).exists():
                    return _falhar(projeto, e, st_ant, log, "empacotar",
                                   f"o artefato não existe depois do empacotar: {e.artefato}", home)
        if e.validar:
            codigo, log, saida = _rodar(projeto, e, "validar", e.validar, home,
                                        cwd=cwd, extras=extras, env_extra=env_extra)
            if codigo != 0:
                return _falhar(projeto, e, st_ant, log, "validar",
                               f"validar saiu {codigo}" + (f": {saida.strip()[-400:]}" if saida.strip() else ""), home)
        codigo, log, saida = _rodar(projeto, e, "instalar", e.instalar, home,
                                    cwd=cwd, extras=extras, env_extra=env_extra)
        if codigo != 0:
            return _falhar(projeto, e, st_ant, log, "instalar",
                           f"instalar saiu {codigo}" + (f": {saida.strip()[-400:]}" if saida.strip() else ""), home)
        if not Path(e.destino).exists():
            return _falhar(projeto, e, st_ant, log, "instalar",
                           f"o destino não existe depois de instalar: {e.destino}", home)
        novo = dict(st_ant)
        novo.update({"projeto": projeto.id, "nome": getattr(projeto, "nome", projeto.id),
                     "classe": e.classe, "situacao": "instalado", "destino": e.destino,
                     "versao": _versao(projeto, e, e.destino), "em": _agora(),
                     "log": str(log), "erro": "", "ultima_acao": "instalar"})
        if ref:
            novo.update({"ref": versao_ref, "head": commit, "worktree": str(cwd)})
            texto = f"instalado {e.destino} a partir de {versao_ref} ({commit[:12]})"
        else:
            for chave in ("ref", "head", "worktree"):
                novo.pop(chave, None)
            texto = f"instalado em {e.destino}"
        _gravar_estado(projeto, novo, home)
        return _resposta(True, texto, estado(projeto, home))


# --------------------------------------------------------------------------
# CLI

_FUNCOES = {"subir": subir, "parar": parar, "empacotar": empacotar,
            "validar": validar, "instalar": instalar}


def _achar_projeto(chave: str = ""):
    if chave:
        p = _projetos.por_id(chave)
        if p is None:
            p = next((x for x in _projetos.projetos() if x.nome == chave), None)
        if p is None:
            raise ErroInstalacao(f"projeto não está no cadastro: {chave}")
        return p
    p = _projetos.padrao()
    if not p.id:
        raise ErroInstalacao("nenhum projeto cadastrado")
    return p


def _humano(res: dict) -> str:
    st = res.get("estado") or {}
    linhas = [f"{st.get('nome', '')}: {st.get('situacao', '')}"]
    for chave, rotulo in (("versao", "versão"), ("ref", "instalado de"), ("head", "commit"),
                          ("pid", "pid"), ("porta", "porta"),
                          ("url", "url"), ("artefato", "artefato"), ("destino", "destino"),
                          ("bloqueio", "trava"), ("erro", "erro")):
        valor = st.get(chave)
        if valor not in (None, "", 0):
            linhas.append(f"  {rotulo}: {valor}")
    if res.get("texto"):
        linhas.insert(0, res["texto"])
    return "\n".join(linhas)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="instalar",
        description="Instalar por projeto do TuttiDash: serviço, artefato instalável ou nenhuma.")
    parser.add_argument("acao", choices=("estado", "listar", "refs") + ACOES)
    parser.add_argument("--projeto", default="", help="id ou nome do projeto (padrão: o do cadastro)")
    parser.add_argument("--ref", default="",
                        help="branch/tag/SHA a instalar (só em `instalar`; worktree isolado)")
    parser.add_argument("--json", action="store_true", help="saída JSON")
    args = parser.parse_args(argv)
    try:
        if args.acao == "listar":
            dados = listar()
            saida = {"ok": True, "projetos": dados}
        elif args.acao == "estado":
            dados = estado(_achar_projeto(args.projeto))
            saida = {"ok": True, "estado": dados}
        elif args.acao == "refs":
            if args.ref:
                raise ErroInstalacao("--ref vale só para instalar; `refs` lista as versões")
            dados = refs(_achar_projeto(args.projeto))
            saida = dados
        else:
            if args.ref and args.acao != "instalar":
                raise ErroInstalacao(f"--ref vale só para instalar, não para {args.acao}")
            p = _achar_projeto(args.projeto)
            if args.acao == "instalar":
                dados = instalar(p, ref=args.ref)
            else:
                dados = _FUNCOES[args.acao](p)
            saida = dados
    except ErroInstalacao as exc:
        saida = {"ok": False, "texto": str(exc)}
        if args.json:
            print(json.dumps(saida, ensure_ascii=False))
        else:
            print(str(exc), file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 — nada para calado
        saida = {"ok": False, "texto": f"erro inesperado: {exc}"}
        if args.json:
            print(json.dumps(saida, ensure_ascii=False))
        else:
            print(saida["texto"], file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(saida, ensure_ascii=False))
    elif args.acao == "listar":
        for st in saida["projetos"]:
            print(f"{st['nome']}: {st['situacao']}" + (f" · versão {st['versao']}" if st.get("versao") else ""))
    elif args.acao == "estado":
        print(_humano({"estado": saida["estado"]}))
    elif args.acao == "refs":
        print("branches: " + (", ".join(saida["branches"]) or "nenhuma") +
              "\ntags: " + (", ".join(saida["tags"]) or "nenhuma"))
        if saida.get("erro"):
            print(f"aviso: {saida['erro']}")
    else:
        print(_humano(saida))
    return 0 if saida.get("ok", True) else 1


if __name__ == "__main__":
    raise SystemExit(main())
