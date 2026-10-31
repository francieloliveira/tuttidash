"""Cadastro de projetos que o dispatcher e o vigia enxergam.

Fonte: chave `projetos` no arquivo que `gasto_lanes/config.py` escolhe
(env > TuttiDash > Lanekeeper > TranscentIA Gasto > legado). Só esse arquivo:
se ele não tiver a chave, não se lê o mais antigo (senão o repo sairia de um
e o `linear.*` de outro). Sem a chave, não há projeto: o dispatcher e o vigia
registram «nenhum projeto cadastrado» e não fazem nada (FRA-565).

Formato (lista de objetos):

    "projetos": [
      {"id": "<uuid do projeto no Linear>",
       "nome": "Meu app",
       "ativo": true,
       "padrao": true,
       "github": "dono/meu-app",
       "repo": "~/Developer/meu-app",
       "worktrees": "~/Developer/meu-app-worktrees",
       "prova": "./scripts/testar.sh {suite}",
       "prova_tentativas": 2,
       "suites": ["tests.test_parser"],
       "protegidos": ["docs/contratos/*", "scripts/release.sh"],
       "copiar_para_worktree": ["AGENTS.md"],
       "antes_do_push": "bash tools/checar-publicacao.sh"}
    ]

Regras:
  - `id` é obrigatório: sem ele o projeto é ignorado (e registrado como inválido).
    É o id do projeto no Linear; o time sai dele (FRA-567).
  - `github`: o repositório no GitHub (`dono/repo`, ou o link). O dispatcher só envia
    a branch se o `origin` da pasta for este repositório.
  - `ativo: false` deixa o projeto listado para o app mostrar, sem dispatch.
  - `padrao: true` marca o projeto que o dispatcher trabalha neste ciclo. Sem
    `padrao`, vale o primeiro `ativo` da lista — a ordem da lista é a ordem de
    preferência, então mover um projeto para o topo o coloca na frente.
  - `worktrees` default: `<repo>-worktrees`.
  - `prova` é o comando da prova do dispatcher, com `{suite}` para a suíte que o
    agente pediu em `.lane/result.json`. Default `python3 {suite}`.
  - `prova_tentativas`: 1 (padrão) roda a prova uma vez; 2 repete a segunda vez
    sem `SKIP_PREFLIGHT` (para scripts de prova com um preflight caro).
  - `suites`: suítes padrão quando a lane não lista nenhuma válida no
    `result.json`. Sem a chave, vale `TranscentIATests` (projeto iOS). Cada
    projeto declara a sua; texto velho de outro projeto nunca entra aqui.
  - `copiar_para_worktree`: arquivos que ficam fora do git no `repo` (ex.: um
    `AGENTS.md` gerado na máquina) e que cada worktree de lane precisa. São
    caminhos relativos; o dispatcher copia os que existem e nunca sobrescreve.
    O arquivo precisa estar no `.gitignore` do projeto, senão o agente o commita.
  - `antes_do_push`: comando que roda no worktree antes de cada push da lane (ex.: a
    conferência de publicação de um repositório público). Saiu diferente de 0, nada
    é enviado e o card fica com `lane:falhou`. Vazio = sem conferência.

Somente Python 3 da stdlib.
"""
from __future__ import annotations

import json
import os
import shlex
from pathlib import Path

def _arquivos_padrao(env=None, home=None) -> list:
    """O arquivo do resolvedor único. Import tardio: este módulo também roda solto."""
    try:
        from .config import arquivos_em_uso
    except ImportError:
        from config import arquivos_em_uso
    return arquivos_em_uso(env=env, home=home)


#: Freio de caminho protegido padrão quando o projeto não declara o seu.
#: São globs relativos ao `repo` do projeto: a config dos agentes do projeto.
PROTEGIDOS_PADRAO = [
    ".claude/*",
    ".mcp.json",
]


def _expandir(valor: str) -> Path:
    """Expande ~ e $VAR do valor (o `cfg` grava com caminho já expandido, mas o
    cadastro é escrito à mão e `~` é o que a pessoa digita)."""
    s = os.path.expandvars(valor)
    if s == "~" or s.startswith("~/"):
        s = str(Path.home()) + s[1:]
    return Path(s).expanduser()


class Projeto:
    """Um projeto que o dispatcher pode trabalhar."""

    __slots__ = ("id", "nome", "ativo", "padrao", "repo", "github", "worktrees",
                 "prova", "prova_tentativas", "suites", "protegidos", "copiar_para_worktree", "antes_do_push")

    def __init__(self, id: str, nome: str = "", ativo: bool = True, padrao: bool = False,
                 repo: str = "", worktrees: str = "", github: str = "", prova: str = "python3 {suite}",
                 prova_tentativas: int = 1, suites=None, protegidos=None, copiar_para_worktree=None,
                 antes_do_push: str = ""):
        self.id = id
        self.nome = nome or id
        self.ativo = ativo
        self.padrao = padrao
        self.repo = _expandir(repo) if repo else Path("")
        self.github = normalizar_github(github)
        self.worktrees = _expandir(worktrees) if worktrees else (
            Path(str(self.repo) + "-worktrees") if repo else Path(""))
        self.prova = prova or "python3 {suite}"
        self.prova_tentativas = max(1, int(prova_tentativas or 1))
        self.suites = [str(s) for s in (suites or []) if str(s).strip()]
        self.protegidos = list(protegidos) if protegidos else list(PROTEGIDOS_PADRAO)
        self.copiar_para_worktree = [str(c) for c in (copiar_para_worktree or []) if str(c).strip()]
        self.antes_do_push = str(antes_do_push or "").strip()

    def comando_prova(self, suite: str) -> str:
        """Comando completo da prova de uma suíte, já com o placeholder trocado.

        O `prova` do cadastro é uma **linha de comando** (programa + argumentos),
        então sai sem aspas: quem a executa é o shell. O que entra de fora é a
        suíte, e só ela é escapada."""
        return self.prova.replace("{suite}", shlex.quote(suite))

    def __repr__(self) -> str:  # pragma: no cover - só para log
        return f"Projeto({self.nome!r}, repo={self.repo}, padrao={self.padrao})"

    def __eq__(self, outro) -> bool:
        return isinstance(outro, Projeto) and all(
            getattr(self, s) == getattr(outro, s) for s in Projeto.__slots__)

    def copia(self) -> "Projeto":
        return Projeto(**{s: getattr(self, s) for s in Projeto.__slots__})


def normalizar_github(valor) -> str:
    """`dono/repo` a partir do link (https, ssh ou git@) ou do próprio `dono/repo`.
    Vazio quando não dá para ler. Minúsculas: o GitHub não diferencia."""
    s = str(valor or "").strip()
    if not s:
        return ""
    for prefixo in ("https://github.com/", "http://github.com/", "ssh://git@github.com/",
                    "git@github.com:", "github.com/"):
        if s.lower().startswith(prefixo):
            s = s[len(prefixo):]
            break
    s = s.strip("/")
    if s.lower().endswith(".git"):
        s = s[:-4]
    partes = [p for p in s.split("/") if p]
    if len(partes) != 2 or any(c.isspace() for c in s):
        return ""
    return f"{partes[0]}/{partes[1]}".lower()


def _do_registro(bruto: dict) -> list:
    """Lista crua da chave `projetos` -> projetos válidos. Ilegíveis são pulados."""
    saida = []
    vistos = set()
    for item in bruto:
        if not isinstance(item, dict):
            continue
        pid = str(item.get("id") or "").strip()
        repo = str(item.get("repo") or "").strip()
        if not pid or not repo or pid in vistos:
            continue          # sem id ou sem repo não dá para trabalhar; duplicado não faz sentido
        vistos.add(pid)
        ativos = item.get("ativo")
        prot = item.get("protegidos")
        copiar = item.get("copiar_para_worktree")
        saida.append(Projeto(
            id=pid,
            nome=str(item.get("nome") or pid),
            ativo=True if ativos is None else bool(ativos),
            padrao=bool(item.get("padrao")),
            repo=repo,
            github=str(item.get("github") or ""),
            worktrees=str(item.get("worktrees") or ""),
            prova=str(item.get("prova") or "python3 {suite}"),
            prova_tentativas=item.get("prova_tentativas") or 1,
            suites=item.get("suites") if isinstance(item.get("suites"), list) else None,
            protegidos=prot if isinstance(prot, list) else None,
            copiar_para_worktree=copiar if isinstance(copiar, list) else None,
            antes_do_push=str(item.get("antes_do_push") or "")))
    return saida


#: Sem cadastro: um projeto vazio, inativo, só para quem chama ter o que ler.
#: `configurado()` diz se há projeto de verdade.
NENHUM = Projeto(id="", nome="nenhum projeto cadastrado", ativo=False, padrao=True)


_CACHE: dict = {}


def _resetar_cache() -> None:
    """Limpa o catálogo em memória.

    O dispatcher e o vigia chamam `recarregar()` no começo de cada ciclo: assim a
    config é lida uma vez por ciclo em vez de uma vez por chamada, e mexer na
    config vale no ciclo seguinte.
    """
    _CACHE.clear()


recarregar = _resetar_cache


def ler_registro(config_files=None, env=None, home=None) -> list:
    """Projetos declarados na config, ou lista vazia se não houver.

    Sem ``config_files``, lê só o arquivo do resolvedor. Uma lista explícita
    (os testes) percorre na ordem e fica com a primeira que tiver projeto válido.
    """
    if config_files is None:
        config_files = _arquivos_padrao(env=env, home=home)
    for cfg in config_files:
        try:
            dados = json.loads(Path(cfg).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(dados, dict):
            continue
        bruto = dados.get("projetos")
        if not isinstance(bruto, list):
            continue
        projetos = _do_registro(bruto)
        if projetos:
            return projetos
    return []


def projetos() -> list:
    """Todos os projetos declarados (inclusive inativos), na ordem da lista."""
    if "lista" not in _CACHE:
        _CACHE["lista"] = ler_registro()
    return _CACHE["lista"]


def ativos() -> list:
    """Projetos com `ativo: true`."""
    return [p for p in projetos() if p.ativo]


def padrao() -> Projeto:
    """O projeto que o dispatcher trabalha: o marcado `padrao`, ou o primeiro ativo.

    Nunca devolve None: sem projeto ativo, devolve `NENHUM` (id vazio) para o
    dispatcher registrar por que não fez nada, em vez de quebrar.
    """
    ativos_ = ativos()
    if not ativos_:
        return NENHUM
    for p in ativos_:
        if p.padrao:
            return p
    return ativos_[0]


def configurado() -> bool:
    """Há um projeto ativo com id e repo para trabalhar."""
    return bool(padrao().id)


def por_id(pid: str) -> Projeto | None:
    for p in projetos():
        if p.id == pid:
            return p
    return None


def resumo() -> str:
    """Uma linha por projeto, para o log do dispatcher."""
    linhas = []
    for p in projetos():
        marcas = []
        if p.padrao:
            marcas.append("padrão")
        if not p.ativo:
            marcas.append("inativo")
        sufixo = f" [{', '.join(marcas)}]" if marcas else ""
        linhas.append(f"{p.nome} ({p.id[:8]}…){sufixo} → {p.repo}")
    return "; ".join(linhas) if linhas else "nenhum projeto cadastrado"


if __name__ == "__main__":  # conferência à mão: python3 -m gasto_lanes.projetos
    for p in projetos():
        print(f"{p.nome}: ativo={p.ativo} padrao={p.padrao}")
        print(f"  repo      {p.repo}")
        print(f"  worktrees {p.worktrees}")
        print(f"  prova     {p.prova} (tentativas={p.prova_tentativas})")
        print(f"  suites    {p.suites or ['TranscentIATests']}")
    print("padrão:", padrao().id)