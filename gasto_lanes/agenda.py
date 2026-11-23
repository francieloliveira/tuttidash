"""Agenda dos projetos: quem o dispatcher trabalha neste ciclo.

O cadastro já aceita vários projetos, mas `projetos.padrao()` devolve um só.
Enquanto a mudança do norte não é aprovada, a agenda fica desligada
(`agenda.multiprojeto: false`) e o dispatcher continua no projeto padrão.
Ligada, ela faz um rodízio justo:

- projeto com lane em andamento continua sendo o escolhido até a lane fechar;
- sem lane em andamento, o próximo da lista é o seguinte depois do último usado;
- `prioridade` (maior primeiro) decide a ordem inicial, mas o rodízio impede
  que um projeto de prioridade alta deixe os outros parados para sempre.

O módulo é puro (não fala com Linear, git nem tmux) e só grava o último escolhido
em um JSON pequeno, para o rodízio sobreviver a reinício do dispatcher.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable, Optional


def habilitado(valor) -> bool:
    """Lê `agenda.multiprojeto` sem transformar a string "false" em True.

    O `_cfg` do dispatcher converte pelo tipo do padrão; um booleano lido como
    texto precisa da mesma régua aqui.
    """
    if isinstance(valor, bool):
        return valor
    if isinstance(valor, (int, float)) and not isinstance(valor, bool):
        return valor != 0
    if isinstance(valor, str):
        return valor.strip().lower() in ("1", "true", "sim", "on", "ligado")
    return False


def _indice(projetos: list, projeto_id: str) -> int:
    for i, p in enumerate(projetos):
        if getattr(p, "id", "") == projeto_id:
            return i
    return -1


def ordenar(projetos: Iterable) -> list:
    """Projetos ativos na ordem inicial: maior `prioridade` primeiro, depois a lista.

    A ordem da lista é a ordem de preferência que o dono já usa no cadastro.
    """
    todos = list(projetos)
    posicao = {getattr(p, "id", ""): i for i, p in enumerate(todos)}
    ativos = [p for p in todos if getattr(p, "ativo", False)]
    return sorted(ativos, key=lambda p: (-int(getattr(p, "prioridade", 0) or 0),
                                         posicao.get(getattr(p, "id", ""), len(todos))))


def escolher(projetos: Iterable, ultimo_id: str = "", ocupados=()) -> Optional[object]:
    """Próximo projeto do ciclo, ou None se não há projeto ativo.

    `ocupados` são ids de projetos com lane em andamento. Eles vencem o rodízio:
    trocar de projeto no meio de uma lane usaria o worktree/estado errado.
    Id ocupado que saiu do cadastro devolve None: não se inventa um projeto sem
    repo/worktrees; o chamador registra e cai no padrão.
    """
    todos = list(projetos)
    if not todos:
        return None
    ocupados = {str(x) for x in ocupados or () if str(x)}
    if ocupados:
        # Ordem do cadastro, não a ordem de prioridade: a lane em andamento manda.
        for p in todos:
            if getattr(p, "id", "") in ocupados:
                return p
        return None
    ativos = ordenar(todos)
    if not ativos:
        return None
    if len(ativos) == 1:
        return ativos[0]
    i = _indice(ativos, str(ultimo_id or ""))
    return ativos[(i + 1) % len(ativos)] if i >= 0 else ativos[0]


def ler_ultimo(caminho) -> str:
    """Id do último projeto escolhido. Arquivo ausente/ilegível = ""."""
    try:
        dados = json.loads(Path(caminho).read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return ""
    if not isinstance(dados, dict):
        return ""
    valor = dados.get("ultimo")
    return valor.strip() if isinstance(valor, str) else ""


def gravar_ultimo(caminho, projeto_id: str) -> None:
    """Grava o último projeto de forma atômica e privada. Falha não derruba o ciclo."""
    p = Path(caminho)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"ultimo": str(projeto_id or "")}, ensure_ascii=False) + "\n",
                       encoding="utf-8")
        try:
            tmp.chmod(0o600)
        except OSError:
            pass
        tmp.replace(p)
    except OSError:
        pass


def distribuir(projetos: Iterable, vagas: int, *, max_global: int = 0) -> list:
    """Distribui `vagas` de lane entre os projetos ativos, em rodízio.

    Cada projeto ativo pode receber até `max_lanes` (0 = sem limite próprio).
    `max_global` (0 = sem limite) corta o total. A ordem inicial é a de
    `ordenar`; a distribuição alterna para não concentrar tudo no primeiro.
    Devolve ids de projeto, um por vaga. Não executa nada.
    """
    try:
        n = max(0, int(vagas or 0))
    except (TypeError, ValueError):
        return []
    if n <= 0:
        return []
    if max_global and max_global > 0:
        n = min(n, int(max_global))
    ordem = ordenar(projetos)
    if not ordem:
        return []
    limite = {}
    for p in ordem:
        try:
            m = int(getattr(p, "max_lanes", 0) or 0)
        except (TypeError, ValueError):
            m = 0
        limite[getattr(p, "id", "")] = m if m > 0 else n
    usados = {pid: 0 for pid in limite}
    saida = []
    i = 0
    tentativas = 0
    while len(saida) < n and tentativas < n * max(1, len(ordem)) * 2:
        p = ordem[i % len(ordem)]
        pid = getattr(p, "id", "")
        if usados[pid] < limite.get(pid, 0):
            saida.append(pid)
            usados[pid] += 1
        i += 1
        tentativas += 1
    return saida
