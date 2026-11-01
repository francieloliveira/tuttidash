"""Revisão de IA no runner limpo (FRA-612).

O revisor roda no GitHub Actions (`pull_request`, `contents: read`, sem secret
do dono). Recebe o diff e o contexto do PR. Não recebe o home. Não tem Bash,
Read global, `security` nem `gh`. A saída é redigida antes de comentar. Se
houver segredo, o comentário não sai e quem chama o dono é o vigia.

O script que vale é o blob da base. Este módulo não executa script do head.
Não cria ruleset: a proteção da `main` é que exige o check `revisao-ia`.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

NOME_DO_CHECK = "revisao-ia"
SCRIPT_REL = "scripts/revisao-ia.sh"
MODULO_REL = "gasto_lanes/revisao_ia.py"
WORKFLOW_REL = ".github/workflows/revisao-ia.yml"
TAG = "[Revisor]"
MARCA_INICIO = "REVISAO_IA_COMENTARIO_INICIO"
MARCA_FIM = "REVISAO_IA_COMENTARIO_FIM"
VAR_BASE = "REVISAO_BASE_SHA"
VAR_HEAD = "REVISAO_HEAD_SHA"

FERRAMENTAS_PERMITIDAS = frozenset({"ler_diff", "ler_pr"})
FERRAMENTAS_NEGADAS = frozenset({"Bash", "Read", "security", "gh", "Write"})

_SHA = re.compile(r"^[0-9a-f]{40}$")
_TOKENS = (
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "ACTIONS_RUNTIME_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_URL",
    "SSH_AUTH_SOCK",
)
_FALHA = {"FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ERROR", "ACTION_REQUIRED", "STALE"}
_ESPERA = {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "EXPECTED", ""}
_LIMITE_DIFF = 100_000
_LIMITE_ARQUIVO = 64_000


class RevisaoRecusada(Exception):
    """A revisão ia ler o home, executar o head ou publicar segredo."""


def _padroes() -> list[re.Pattern[str]]:
    """Padrões de segredo. Os literais ficam partidos para não irem inteiros ao git."""
    partes = (
        "-----BEGIN " + "[A-Z ]*PRIVATE KEY",
        "gh" + "p_[A-Za-z0-9]{20,}",
        "github_" + "pat_[A-Za-z0-9_]{20,}",
        "sk-" + "ant-[A-Za-z0-9-]{10,}",
        "sk-" + "proj-[A-Za-z0-9-]{10,}",
        "xa" + "i-[A-Za-z0-9]{20,}",
        "lin_" + "api_[A-Za-z0-9]{10,}",
        "AKIA" + "[0-9A-Z]{16}",
    )
    return [re.compile(p) for p in partes]


def sha_completo(sha: str) -> bool:
    return _SHA.fullmatch(sha or "") is not None


def detectar_segredo(texto: str) -> bool:
    if not texto:
        return False
    return any(p.search(texto) for p in _padroes())


def redigir(texto: str) -> str:
    saida = texto or ""
    for padrao in _padroes():
        saida = padrao.sub("[redigido]", saida)
    return saida


def _dentro(raiz: Path, caminho: Path) -> bool:
    raiz_r = raiz.resolve()
    cam = caminho.resolve()
    return cam == raiz_r or raiz_r in cam.parents


def _sobrepoe(a: Path, b: Path) -> bool:
    return _dentro(a, b) or _dentro(b, a)


def normalizar_rollup(bruto) -> list:
    if isinstance(bruto, dict):
        bruto = bruto.get("nodes") or bruto.get("contexts") or []
    return list(bruto) if isinstance(bruto, list) else []


def _sha_do_item(item: dict) -> str:
    for chave in ("sha", "headSha", "head_sha", "headRefOid"):
        valor = item.get(chave)
        if isinstance(valor, str) and valor.strip():
            return valor.strip().lower()
    return ""


def _conta(item: dict, esperado: str) -> bool:
    if not isinstance(item, dict):
        return False
    nome = str(item.get("name") or item.get("context") or "").strip()
    if nome != NOME_DO_CHECK:
        return False
    visto = _sha_do_item(item)
    if visto:
        return visto == esperado and sha_completo(visto)
    return True


def _veredito_item(item: dict) -> str:
    conclusao = str(item.get("conclusion") or "").strip().upper()
    status = str(item.get("status") or "").strip().upper()
    estado = str(item.get("state") or "").strip().upper()
    if conclusao in _FALHA or status in _FALHA or estado in _FALHA:
        return "vermelho"
    if conclusao == "SUCCESS" or estado == "SUCCESS":
        return "verde"
    if status in _ESPERA or conclusao in _ESPERA or estado in _ESPERA:
        return "pendente"
    return "pendente"


def veredito_check(sha: str, head_sha: str, checks) -> str:
    """`verde`, `vermelho` ou `pendente` para o check no SHA completo.

    SHA incompleto ou diferente do head não autoriza merge. Check de outro
    SHA não conta. Sem item deste SHA, o check ainda não chegou.
    """
    esperado = (sha or "").strip().lower()
    head = (head_sha or "").strip().lower()
    if not sha_completo(esperado) or esperado != head:
        return "vermelho"
    itens = [i for i in normalizar_rollup(checks) if _conta(i, esperado)]
    if not itens:
        return "pendente"
    vereditos = [_veredito_item(i) for i in itens]
    if "vermelho" in vereditos:
        return "vermelho"
    if "pendente" in vereditos or "verde" not in vereditos:
        return "pendente"
    return "verde"


def autoriza_merge(sha: str, head_sha: str, checks) -> bool:
    """O merge só segue com `revisao-ia` verde neste SHA. Check vermelho bloqueia."""
    return veredito_check(sha, head_sha, checks) == "verde"


def ambiente_do_revisor(home: Path) -> dict[str, str]:
    """Ambiente do processo revisor: home vazio, sem token e sem socket de ssh."""
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "LANG": "C.UTF-8",
    }


class Sandbox:
    """Ferramentas do revisor. Bash, Read global, security, gh e Write não existem."""

    def __init__(self, contexto: Path):
        self.contexto = contexto.resolve()
        self.negacoes: list[str] = []
        self.permitidas = set(FERRAMENTAS_PERMITIDAS)
        self.negadas = set(FERRAMENTAS_NEGADAS)

    def chamar(self, ferramenta: str, *_args: str) -> str:
        if ferramenta not in self.permitidas:
            self.negacoes.append(ferramenta)
            return "negado"
        if ferramenta == "ler_diff":
            return self._ler("diff.patch")
        if ferramenta == "ler_pr":
            return self._ler("pr.json")
        self.negacoes.append(ferramenta)
        return "negado"

    def _ler(self, nome: str) -> str:
        if nome not in {"diff.patch", "pr.json"} or "/" in nome or ".." in nome:
            self.negacoes.append("Read")
            return "negado"
        alvo = self.contexto / nome
        if alvo.is_symlink() or not alvo.is_file() or not _dentro(self.contexto, alvo):
            self.negacoes.append("Read")
            return "negado"
        return alvo.read_text(encoding="utf-8", errors="replace")


def montar_prompt(sandbox: Sandbox) -> str:
    diff = sandbox.chamar("ler_diff")
    pr = sandbox.chamar("ler_pr")
    return (
        "Você é o revisor no runner limpo. Você só tem o diff e o contexto do PR. "
        "Não tem Bash, não tem Read global, não tem security e não tem gh.\n\n"
        f"{pr}\n\n{diff}\n"
    )


def modelo_padrao(prompt: str, sandbox: Sandbox) -> str:
    """Revisão sem modelo externo: não copia o diff, não copia segredo e não lê o home."""
    if not {"Bash", "Read", "security", "gh", "Write"} <= sandbox.negadas:
        raise RevisaoRecusada("o revisor ganhou ferramenta")
    if sandbox.permitidas & {"Bash", "Read", "security", "gh", "Write"}:
        raise RevisaoRecusada("o revisor ganhou ferramenta")
    pedido_home = "leia" in prompt.lower() and ".ssh" in prompt
    linhas = [
        "O revisor leu o diff e o contexto do PR.",
        "O home não entrou. Sem Bash, sem Read global, sem security e sem gh.",
    ]
    if pedido_home:
        linhas.append("Pedido para ler ~/.ssh: recusado. Nada do home foi lido.")
    linhas.append(f"Trechos de diff: {prompt.count(chr(10) + '--- ')}.")
    linhas.append("Próximo passo: conferir o diff no PR.")
    return "\n".join(linhas)


def revisar(contexto: Path, modelo=None) -> str:
    sandbox = Sandbox(contexto)
    fn = modelo or modelo_padrao
    saida = fn(montar_prompt(sandbox), sandbox)
    return saida if isinstance(saida, str) else ""


def preparar_comentario(saida: str, sha: str) -> str:
    if not sha_completo(sha):
        raise RevisaoRecusada("SHA incompleto")
    texto = (saida or "").strip()
    if texto.startswith(TAG) and sha in texto:
        return texto if texto.endswith("\n") else texto + "\n"
    primeira = texto.splitlines()[0] if texto else ""
    veredito = "APROVADO" if "REVISOR: APROVADO" in primeira else "AJUSTES"
    if texto.startswith(TAG):
        texto = "\n".join(texto.splitlines()[1:]).strip()
    return f"{TAG} REVISOR: {veredito} · head `{sha}`\n\n{texto}\n"


def decidir_publicacao(saida: str, sha: str) -> dict:
    """Redige antes de comentar. Segredo: não publica e pede o dono."""
    if detectar_segredo(saida):
        return {"acao": "dono", "corpo": ""}
    try:
        corpo = redigir(preparar_comentario(saida, sha))
    except RevisaoRecusada:
        return {"acao": "dono", "corpo": ""}
    if detectar_segredo(corpo) or TAG not in corpo or sha not in corpo:
        return {"acao": "dono", "corpo": ""}
    return {"acao": "comentar", "corpo": corpo}


def comentario_deste_sha(corpo: str, sha: str) -> bool:
    return bool(corpo) and sha_completo(sha) and TAG in corpo and sha in corpo


def extrair_comentario(log: str) -> str:
    """Tira o comentário do log. Linha do Actions vem com prefixo separado por tab."""
    if not log or MARCA_INICIO not in log or MARCA_FIM not in log:
        return ""
    linhas: list[str] = []
    dentro = False
    for bruta in log.splitlines():
        linha = bruta.split("\t")[-1] if "\t" in bruta else bruta
        if linha.strip() == MARCA_INICIO:
            dentro = True
            continue
        if linha.strip() == MARCA_FIM:
            break
        if dentro:
            linhas.append(linha)
    return "\n".join(linhas).strip()


def acao_da_revisao(sha: str, head_sha: str, checks, log: str, comentarios: list[str]) -> dict:
    """O que publicar. Corpo vazio quando o comentário não sai."""
    veredito = veredito_check(sha, head_sha, checks)
    if veredito == "vermelho":
        return {"acao": "dono", "corpo": ""}
    if veredito != "verde":
        return {"acao": "esperar", "corpo": ""}
    if any(comentario_deste_sha(c, sha) for c in comentarios):
        return {"acao": "esperar", "corpo": ""}
    extraido = extrair_comentario(log or "")
    if not extraido:
        return {"acao": "esperar", "corpo": ""}
    return decidir_publicacao(extraido, sha)


def _arquivos(raiz: Path) -> dict[str, Path]:
    saida: dict[str, Path] = {}
    for dirpath, dirnames, filenames in os.walk(raiz):
        atual = Path(dirpath)
        dirnames[:] = sorted(
            d for d in dirnames if d != ".git" and not (atual / d).is_symlink()
        )
        for nome in sorted(filenames):
            caminho = atual / nome
            if caminho.is_symlink():
                saida[caminho.relative_to(raiz).as_posix()] = caminho
                continue
            if not caminho.is_file():
                continue
            saida[caminho.relative_to(raiz).as_posix()] = caminho
    return saida


def _texto_arquivo(caminho: Path) -> str:
    if caminho.is_symlink():
        return "symlink " + os.readlink(caminho)
    bruto = caminho.read_bytes()[:_LIMITE_ARQUIVO]
    if b"\0" in bruto:
        return "binário"
    return bruto.decode("utf-8", errors="replace")


def diff_de_arvores(base: Path, head: Path) -> str:
    """Diff dos dois checkouts. Não segue symlink e não executa arquivo."""
    base_arq = _arquivos(base)
    head_arq = _arquivos(head)
    blocos: list[str] = []
    for rel in sorted(set(base_arq) | set(head_arq)):
        antigo = _texto_arquivo(base_arq[rel]).splitlines(keepends=True) if rel in base_arq else []
        novo = _texto_arquivo(head_arq[rel]).splitlines(keepends=True) if rel in head_arq else []
        if antigo == novo:
            continue
        pedacos = difflib.unified_diff(antigo, novo, fromfile="a/" + rel, tofile="b/" + rel, n=1)
        bloco = "".join(pedacos)
        if bloco:
            blocos.append(bloco)
        if sum(len(b) for b in blocos) >= _LIMITE_DIFF:
            blocos.append("\ndiff -- truncado\n")
            break
    return "".join(blocos)[:_LIMITE_DIFF]


def _ler_evento(evento: Path | None, sha_head: str, sha_base: str) -> dict:
    pr: dict = {}
    if evento is not None and evento.is_file() and not evento.is_symlink():
        try:
            ev = json.loads(evento.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RevisaoRecusada("evento ilegível") from exc
        bruto = ev.get("pull_request") if isinstance(ev, dict) else None
        if isinstance(bruto, dict):
            head = bruto.get("head") if isinstance(bruto.get("head"), dict) else {}
            base = bruto.get("base") if isinstance(bruto.get("base"), dict) else {}
            anunciado = str(head.get("sha") or "")
            if anunciado and anunciado != sha_head:
                raise RevisaoRecusada("SHA do evento não é o checkout")
            pr = {
                "numero": bruto.get("number"),
                "titulo": str(bruto.get("title") or "")[:500],
                "corpo": str(bruto.get("body") or "")[:6000],
                "sha": sha_head,
                "base": str(base.get("sha") or sha_base),
                "branch": str(head.get("ref") or "")[:200],
            }
    if not pr:
        pr = {"numero": None, "titulo": "", "corpo": "", "sha": sha_head, "base": sha_base, "branch": ""}
    pr["sha"] = sha_head
    return pr


def preparar_contexto(base: Path, head: Path, meta: dict) -> Path:
    ctx = Path(tempfile.mkdtemp(prefix="revisao-ia-"))
    (ctx / "diff.patch").write_text(diff_de_arvores(base, head), encoding="utf-8")
    (ctx / "pr.json").write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    return ctx


def _sha_do_checkout(raiz: Path) -> str:
    proc = subprocess.run(
        ["git", "-C", str(raiz), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RevisaoRecusada("checkout sem commit")
    sha = proc.stdout.strip()
    if not sha_completo(sha):
        raise RevisaoRecusada("SHA incompleto")
    return sha


def garantir_origem(base: Path, modulo: Path | None = None) -> None:
    base_r = base.resolve()
    bruto = base_r / MODULO_REL
    if bruto.is_symlink():
        raise RevisaoRecusada("symlink na base: " + MODULO_REL)
    modulo_r = (modulo or Path(__file__)).resolve()
    if modulo_r != bruto.resolve() or not _dentro(base_r, modulo_r):
        raise RevisaoRecusada("módulo em execução não é o da base")


def emitir(decisao: dict) -> int:
    acao = decisao.get("acao")
    if acao == "dono":
        print("revisao-ia: segredo detectado; comentário não publicado", file=sys.stderr)
        return 3
    if acao == "comentar":
        corpo = decisao.get("corpo") or ""
        if detectar_segredo(corpo):
            print("revisao-ia: segredo detectado; comentário não publicado", file=sys.stderr)
            return 3
        sys.stdout.write(MARCA_INICIO + "\n" + corpo.rstrip() + "\n" + MARCA_FIM + "\n")
        return 0
    print("revisao-ia: decisão desconhecida", file=sys.stderr)
    return 2


def rodar(base: Path, head: Path, evento: Path | None = None, modelo=None) -> int:
    base = base.resolve()
    head = head.resolve()
    if _sobrepoe(base, head):
        raise RevisaoRecusada("base e head se sobrepõem")
    sha_base = _sha_do_checkout(base)
    sha_head = _sha_do_checkout(head)
    meta = _ler_evento(evento, sha_head, sha_base)
    ctx = preparar_contexto(base, head, meta)
    try:
        saida = revisar(ctx, modelo=modelo)
        return emitir(decidir_publicacao(saida, sha_head))
    finally:
        shutil.rmtree(ctx, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Revisão de IA a partir do commit da base.")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--evento", default="")
    parser.add_argument("--bootstrap", action="store_true")
    args = parser.parse_args(argv)
    try:
        base = Path(args.base)
        head = Path(args.head)
        evento = Path(args.evento) if args.evento else None
        if not args.bootstrap:
            garantir_origem(base)
        return rodar(base, head, evento)
    except RevisaoRecusada as exc:
        print(f"revisao-ia: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
