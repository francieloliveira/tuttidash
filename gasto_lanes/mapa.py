"""Mapa do projeto (`docs/produto/mapa.md`): a parte factual que vai no prompt das histórias.

Duas partes no mesmo arquivo:

- **gerada**, entre `<!-- gerado:inicio -->` e `<!-- gerado:fim -->`: Módulos e Prova.
  Montada aqui, sem modelo, a partir da árvore do repositório e do cadastro do projeto.
  Mesma árvore e mesmo cadastro → mesmo texto. Nenhuma lane escreve nela.
- **escrita**: o resto do arquivo (convenções, notas). Revisada em PR normal; esta função
  nunca a altera.

Somente Python 3 da stdlib.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

INICIO = "<!-- gerado:inicio — não editar à mão; o TuttiDash regenera -->"
FIM = "<!-- gerado:fim -->"
_MARCA_INICIO = "<!-- gerado:inicio"
CAMINHO = "docs/produto/mapa.md"

#: Pastas que não descrevem o projeto (geradas, dependências, caches).
IGNORADAS = {
    ".git", "node_modules", "build", ".build", "DerivedData", "Pods", "dist", "venv", ".venv",
    "__pycache__", ".swiftpm", ".gradle", "target", ".idea", ".vscode", ".claude",
}
#: Pastas de teste reconhecidas pelo nome.
_TESTE = {"test", "tests", "__tests__", "spec", "specs"}
#: Teto da parte gerada, em caracteres (ela vai inteira no prompt).
TETO = 6000


def _ignorado(partes: tuple[str, ...]) -> bool:
    return any(x in IGNORADAS or (x.startswith(".") and x != ".github") for x in partes)


def _eh_teste(nome: str) -> bool:
    return nome.lower() in _TESTE or nome.endswith("Tests")


def _pastas_git(repo: Path) -> set[str] | None:
    """Pastas que têm arquivo versionado (`git ls-files`). None se não for repositório git."""
    try:
        r = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode:
        return None
    pastas: set[str] = set()
    for arq in r.stdout.decode("utf-8", "replace").split("\0"):
        partes = arq.split("/")[:-1]
        for i in range(1, len(partes) + 1):
            pastas.add("/".join(partes[:i]))
    return pastas


def _pastas_disco(repo: Path, profundidade: int = 5) -> set[str]:
    """Reserva para pasta fora do git: varre o disco sem seguir link."""
    pastas: set[str] = set()

    def varrer(pasta: Path, rel: str, nivel: int) -> None:
        if nivel > profundidade:
            return
        try:
            itens = list(pasta.iterdir())
        except OSError:
            return
        for p in itens:
            if p.is_symlink() or not p.is_dir():
                continue
            caminho = f"{rel}{p.name}"
            pastas.add(caminho)
            varrer(p, caminho + "/", nivel + 1)

    varrer(repo, "", 1)
    return pastas


def arvore(repo: Path, extras=()) -> list[str]:
    """Pastas do projeto, em ordem, sem as ignoradas. `extras`: arquivos que vão entrar
    no mesmo commit (ex.: o próprio mapa), para a lista já nascer em dia."""
    pastas = _pastas_git(repo)
    if pastas is None:
        pastas = _pastas_disco(repo)
    for arq in extras:
        partes = arq.split("/")[:-1]
        for i in range(1, len(partes) + 1):
            pastas.add("/".join(partes[:i]))
    return sorted((p for p in pastas if p and not _ignorado(tuple(p.split("/")))), key=str.lower)


def modulos(pastas: list[str], profundidade: int = 2, por_pasta: int = 15) -> list[str]:
    """Pastas até `profundidade` níveis (as de teste ficam na seção Prova)."""
    linhas: list[str] = []

    def filhas(pai: str) -> list[str]:
        nivel = 0 if not pai else pai.count("/") + 1
        return [p for p in pastas if p.count("/") == nivel and (not pai or p.startswith(pai + "/"))
                and not _eh_teste(p.rsplit("/", 1)[-1])]

    def varrer(pai: str, nivel: int) -> None:
        lista = filhas(pai)
        for p in lista[:por_pasta]:
            linhas.append(f"{'  ' * (nivel - 1)}- `{p}/`")
            if nivel < profundidade:
                varrer(p, nivel + 1)
        if len(lista) > por_pasta:
            linhas.append(f"{'  ' * (nivel - 1)}- … +{len(lista) - por_pasta} pastas")

    varrer("", 1)
    return linhas


def pastas_de_teste(pastas: list[str], profundidade: int = 4) -> list[str]:
    """Primeira pasta de teste de cada ramo (não lista as de dentro dela)."""
    achadas: list[str] = []
    for p in pastas:
        partes = p.split("/")
        if len(partes) > profundidade or not _eh_teste(partes[-1]):
            continue
        if any(_eh_teste(x) for x in partes[:-1]):
            continue
        achadas.append(p + "/")
    return achadas


def parte_gerada(repo: Path, prova: str = "", suites=None, extras=(CAMINHO,)) -> str:
    """Texto entre os marcadores (sem eles). Determinístico: num repositório git, só o que
    está versionado (pasta local solta não muda o mapa)."""
    pastas = arvore(repo, extras)
    linhas = ["## Módulos", *(modulos(pastas) or ["- (repositório sem pastas)"]), "", "## Prova"]
    if prova.strip():
        linhas.append(f"- Comando: `{prova.strip()}`")
    for s in suites or []:
        linhas.append(f"- Suíte declarada: `{s}`")
    testes = pastas_de_teste(pastas)
    linhas += [f"- Testes em `{t}`" for t in testes] or ["- (nenhuma pasta de teste encontrada)"]
    texto = "\n".join(linhas)
    if len(texto) > TETO:
        texto = texto[: TETO - 12].rsplit("\n", 1)[0] + "\n- […cortado]"
    return texto


def montar(atual: str | None, gerada: str, nome: str) -> str:
    """Mapa com a parte gerada nova. A parte escrita do `atual` fica como estava.

    Sem arquivo (ou sem os marcadores): cria o modelo com a parte escrita vazia para o dono."""
    bloco = f"{INICIO}\n{gerada}\n{FIM}"
    if atual and _MARCA_INICIO in atual and FIM in atual:
        antes = atual[: atual.index(_MARCA_INICIO)]
        depois = atual[atual.index(FIM, atual.index(_MARCA_INICIO)) + len(FIM):]
        return antes + bloco + depois
    escrita = atual.strip() if atual and atual.strip() else (
        "## Convenções\n"
        "- (a escrever: linguagem dos textos, onde fica a lógica testável, padrão de testes)")
    return f"# Mapa — {nome}\n\n{bloco}\n\n{escrita}\n"


def divergente(atual: str | None, gerada: str) -> bool:
    """A parte gerada do arquivo não é a que a árvore de hoje produz."""
    if not atual or _MARCA_INICIO not in atual or FIM not in atual:
        return True
    ini = atual.index("\n", atual.index(_MARCA_INICIO)) + 1
    fim = atual.index(FIM, ini)
    return atual[ini:fim].strip() != gerada.strip()


if __name__ == "__main__":  # conferência à mão: python3 gasto_lanes/mapa.py <repo>
    import sys
    raiz = Path(sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    print(parte_gerada(raiz))
