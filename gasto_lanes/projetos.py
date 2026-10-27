"""Cadastro de projetos que o dispatcher e o vigia enxergam.

Fonte: chave `projetos` na config do TuttiDash
(`~/.transcentia/tools/config.json` e
`~/Library/Application Support/Lanekeeper/config.json`, nessa ordem — a primeira
que tiver a chave ganha). Sem a chave, não há projeto: o dispatcher e o vigia
registram «nenhum projeto cadastrado» e não fazem nada (FRA-565).

Formato (lista de objetos):

    "projetos": [
      {"id": "<uuid do projeto no Linear>",
       "nome": "Meu app",
       "ativo": true,
       "padrao": true,
       "repo": "~/Developer/meu-app",
       "worktrees": "~/Developer/meu-app-worktrees",
       "prova": "./scripts/testar.sh {suite}",
       "prova_tentativas": 2,
       "protegidos": ["docs/contratos/*", "scripts/release.sh"],
       "copiar_para_worktree": ["AGENTS.md"]}
    ]

Regras:
  - `id` é obrigatório: sem ele o projeto é ignorado (e registrado como inválido).
  - `ativo: false` deixa o projeto listado para o app mostrar, sem dispatch.
  - `padrao: true` marca o projeto que o dispatcher trabalha neste ciclo. Sem
    `padrao`, vale o primeiro `ativo` da lista — a ordem da lista é a ordem de
    preferência, então mover um projeto para o topo o coloca na frente.
  - `worktrees` default: `<repo>-worktrees`.
  - `prova` é o comando da prova do dispatcher, com `{suite}` para a suíte que o
    agente pediu em `.lane/result.json`. Default `python3 {suite}`.
  - `prova_tentativas`: 1 (padrão) roda a prova uma vez; 2 repete a segunda vez
    sem `SKIP_PREFLIGHT` (para scripts de prova com um preflight caro).
  - `copiar_para_worktree`: arquivos que ficam fora do git no `repo` (ex.: um
    `AGENTS.md` gerado na máquina) e que cada worktree de lane precisa. São
    caminhos relativos; o dispatcher copia os que existem e nunca sobrescreve.
    O arquivo precisa estar no `.gitignore` do projeto, senão o agente o commita.

Somente Python 3 da stdlib.
"""
from __future__ import annotations

import json
import os
import shlex
from pathlib import Path

#: Onde a config do TuttiDash mora, na ordem de precedência do `cfg`.
CONFIG_FILES = [
    Path.home() / "Library/Application Support/TuttiDash/config.json",
    Path.home() / "Library/Application Support/Lanekeeper/config.json",
    Path.home() / ".transcentia/tools/config.json",
]

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

    __slots__ = ("id", "nome", "ativo", "padrao", "repo", "worktrees",
                 "prova", "prova_tentativas", "protegidos", "copiar_para_worktree")

    def __init__(self, id: str, nome: str = "", ativo: bool = True, padrao: bool = False,
                 repo: str = "", worktrees: str = "", prova: str = "python3 {suite}",
                 prova_tentativas: int = 1, protegidos=None, copiar_para_worktree=None):
        self.id = id
        self.nome = nome or id
        self.ativo = ativo
        self.padrao = padrao
        self.repo = _expandir(repo) if repo else Path("")
        self.worktrees = _expandir(worktrees) if worktrees else (
            Path(str(self.repo) + "-worktrees") if repo else Path(""))
        self.prova = prova or "python3 {suite}"
        self.prova_tentativas = max(1, int(prova_tentativas or 1))
        self.protegidos = list(protegidos) if protegidos else list(PROTEGIDOS_PADRAO)
        self.copiar_para_worktree = [str(c) for c in (copiar_para_worktree or []) if str(c).strip()]

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
            worktrees=str(item.get("worktrees") or ""),
            prova=str(item.get("prova") or "python3 {suite}"),
            prova_tentativas=item.get("prova_tentativas") or 1,
            protegidos=prot if isinstance(prot, list) else None,
            copiar_para_worktree=copiar if isinstance(copiar, list) else None))
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


def ler_registro(config_files=None) -> list:
    """Projetos declarados na config, ou lista vazia se não houver.

    A primeira config que tiver a chave `projetos` com algum projeto válido ganha.
    """
    for cfg in (config_files or CONFIG_FILES):
        try:
            dados = json.loads(Path(cfg).read_text(encoding="utf-8"))
        except (OSError, ValueError):
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
    print("padrão:", padrao().id)