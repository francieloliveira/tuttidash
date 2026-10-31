#!/usr/bin/env python3
"""Proxy local do Linear (FRA-607).

O token do dispatcher e do vigia fica só na memória deste processo. Os scripts
pedem uma operação pelo socket e recebem o `data` do GraphQL. A resposta, o
auditório e o argv não levam o token.

Escopo mínimo é a allowlist daqui: consulta fora dela é negada e registrada em
`linear-proxy-audit.log`. A chave é dedicada ao TuttiDash. Rotação: Linear ›
Settings › API, colar a nova em Ajustes › Contas e revogar a antiga. O item
`linear-transcentia-lanes` do `security` não é mais gravado.

Quem sobe o processo é o app: `python3 proxy_linear.py --servir`, com o token
na primeira linha da entrada padrão.
"""
from __future__ import annotations

import json
import os
import socket
import threading
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

LINEAR_API = "https://api.linear.app/graphql"
#: Nome antigo do item que o `security` lia. Não gravar de novo.
SERVICO_SECURITY_APOSENTADO = "linear-transcentia-lanes"
NOME_SOCKET = "linear-proxy.sock"
NOME_AUDITORIA = "linear-proxy-audit.log"
NOME_PID = "linear-proxy.pid"

#: Campos do card que o vigia pede. O teste do vigia olha este texto.
ISSUE_FIELDS = """id identifier title description url priority sortOrder startedAt createdAt updatedAt dueDate estimate
      branchName assignee{ id name } parent{ identifier }
      state{ id name type } labels{ nodes{ id name parent{ name } } } project{ id name }
      comments(first:30, orderBy: createdAt){ nodes{ id body createdAt } }
      inverseRelations(first:30){ nodes{ type issue{ identifier state{ type } } } }"""


class ErroProxy(RuntimeError):
    """Falha do proxy ou do Linear. A mensagem não inclui o token."""


class Negado(ErroProxy):
    def __init__(self, op: str):
        self.op = op
        super().__init__(f"Linear: operação negada ({op})")


class Operacao:
    def __init__(self, consulta: str, chaves: tuple = (), aninhado: Optional[dict] = None,
                 exigir: Optional[dict] = None):
        self.consulta = consulta
        self.chaves = frozenset(chaves)
        self.aninhado = aninhado or {}
        self.exigir = exigir or {}

    def variaveis(self, brutas: dict, nome: str) -> dict:
        if set(brutas) - self.chaves:
            raise Negado(nome)
        saida = {}
        for chave in self.chaves:
            if chave not in brutas:
                continue
            valor = brutas[chave]
            if chave in self.aninhado:
                permitidas = self.aninhado[chave]
                if not isinstance(valor, dict) or not valor or set(valor) - permitidas:
                    raise Negado(nome)
                if any(k not in valor for k in self.exigir.get(chave, ())):
                    raise Negado(nome)
            saida[chave] = valor
        return saida


def _q_issue() -> str:
    return f"query($id:String!){{ issue(id:$id){{ {ISSUE_FIELDS} }} }}"


def _q_issues_projeto() -> str:
    flt = "project:{ id:{ eq:$p } }, state:{ type:{ nin:[\"completed\",\"canceled\"] } }"
    return f"""query($p:ID!, $after:String){{ issues(first:100, after:$after, filter:{{ {flt} }})
          {{ pageInfo{{ hasNextPage endCursor }} nodes{{ {ISSUE_FIELDS} }} }} }}"""


def _q_cancelados() -> str:
    flt = ("project:{ id:{ eq:$p } }, state:{ type:{ eq:\"canceled\" } }, "
           "updatedAt:{ gt:\"-P7D\" }")
    return f"""query($p:ID!){{ issues(first:50, filter:{{ {flt} }}){{ nodes{{ {ISSUE_FIELDS} }} }} }}"""


def _fixas() -> dict:
    """Operações do dispatcher e do vigia. A consulta canônica fica aqui, não no script."""
    issue_update = "mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id,input:$i){ success } }"
    campos_issue = frozenset({"stateId", "description"})
    return {
        "viewer": Operacao("query{ viewer{ id } }"),
        "estado_card": Operacao("query($id:String!){ issue(id:$id){ state{ name } } }", ("id",)),
        "candidatos": Operacao("""
query Candidatos($project: ID!, $state: ID!) {
  issues(
    first: 50
    filter: { project: { id: { eq: $project } }, state: { id: { eq: $state } } }
  ) {
    nodes {
      id
      identifier
      title
      priority
      startedAt
      createdAt
      branchName
      url
      labels { nodes { name parent { name } } }
      inverseRelations {
        nodes { type issue { identifier state { type name } } }
      }
      history(last: 15) {
        nodes { createdAt actor { name } botActor { name } toState { id } }
      }
      comments(last: 30) { nodes { id body } }
    }
  }
}
""", ("project", "state")),
        "card": Operacao("""
query Card($id: String!) {
  issue(id: $id) { id identifier title description url branchName state { id name } }
}
""", ("id",)),
        "comentar": Operacao("""
mutation($id: String!, $body: String!) {
  commentCreate(input: { issueId: $id, body: $body }) { success }
}
""", ("id", "body")),
        "mudar_estado": Operacao("""
mutation($id: String!, $state: String!) {
  issueUpdate(id: $id, input: { stateId: $state }) { success }
}
""", ("id", "state")),
        "adicionar_etiqueta": Operacao("""
mutation($id: String!, $label: String!) {
  issueAddLabel(id: $id, labelId: $label) { success }
}
""", ("id", "label")),
        "remover_etiqueta": Operacao("""
mutation($id: String!, $label: String!) {
  issueRemoveLabel(id: $id, labelId: $label) { success }
}
""", ("id", "label")),
        "issue": Operacao(_q_issue(), ("id",)),
        "issues_projeto": Operacao(_q_issues_projeto(), ("p", "after")),
        "cancelados": Operacao(_q_cancelados(), ("p",)),
        "comentar_vigia": Operacao(
            "mutation($i:CommentCreateInput!){ commentCreate(input:$i){ success } }",
            ("i",), {"i": frozenset({"issueId", "body"})}, {"i": ("issueId", "body")}),
        "adicionar_etiqueta_vigia": Operacao(
            "mutation($id:String!,$l:String!){ issueAddLabel(id:$id, labelId:$l){ success } }",
            ("id", "l")),
        "remover_etiqueta_vigia": Operacao(
            "mutation($id:String!,$l:String!){ issueRemoveLabel(id:$id, labelId:$l){ success } }",
            ("id", "l")),
        "atualizar_issue": Operacao(issue_update, ("id", "i"), {"i": campos_issue}),
        "ler_documento": Operacao("query($id:String!){ document(id:$id){ content } }", ("id",)),
        "atualizar_documento": Operacao(
            "mutation($id:String!,$i:DocumentUpdateInput!){ documentUpdate(id:$id,input:$i){ success } }",
            ("id", "i"), {"i": frozenset({"content"})}, {"i": ("content",)}),
        "estados_do_card": Operacao(
            "query($id:String!){ issue(id:$id){ team{ states{ nodes{ id type name } } } } }", ("id",)),
        "estados_time_tipo": Operacao(
            "query($id:String!){ team(id:$id){ states{ nodes{ id type } } } }", ("id",)),
    }


_OPS: Optional[dict] = None
_LOCK_OPS = threading.Lock()


def operacoes() -> dict:
    """Allowlist. As consultas do `linear_ids` entram pelo texto que o módulo já usa."""
    global _OPS
    with _LOCK_OPS:
        if _OPS is None:
            import linear_ids
            ops = _fixas()
            ops["time_do_projeto"] = Operacao(linear_ids.Q_TIME_DO_PROJETO, ("id",))
            ops["estados_do_time"] = Operacao(linear_ids.Q_ESTADOS, ("id",))
            ops["etiquetas"] = Operacao(linear_ids.Q_LABELS, ("after",))
            ops["criar_etiqueta"] = Operacao(
                linear_ids.M_CRIAR_LABEL, ("input",),
                {"input": frozenset({"name", "teamId", "color", "parentId", "isGroup"})},
                {"input": ("name", "teamId")})
            _OPS = ops
        return _OPS


def normalizar(consulta: str) -> str:
    return " ".join(consulta.split())


def consulta(nome: str) -> str:
    """Texto GraphQL da operação. O script manda este texto; o proxy confere a allowlist."""
    return operacoes()[nome].consulta


def operacao_da_consulta(texto: str) -> Optional[str]:
    alvo = normalizar(texto)
    for nome, op in operacoes().items():
        if normalizar(op.consulta) == alvo:
            return nome
    return None


def caminho_socket() -> Path:
    return Path.home() / ".transcentia" / "lanes" / NOME_SOCKET


def caminho_auditoria() -> Path:
    return Path.home() / ".transcentia" / "lanes" / NOME_AUDITORIA


def argv_servidor(python: str, script: str) -> list:
    """Argumentos do processo. O token não entra aqui."""
    return [python, script, "--servir"]


def serializar_pedido(op: str, variaveis: dict) -> str:
    return json.dumps({"op": op, "vars": variaveis}, ensure_ascii=False, separators=(",", ":"))


def redigir(obj, token: str):
    if not token:
        return obj
    if isinstance(obj, str):
        return obj.replace(token, "***")
    if isinstance(obj, dict):
        return {k: redigir(v, token) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redigir(v, token) for v in obj]
    return obj


def op_auditavel(op: str, token: str) -> str:
    texto = op.replace(token, "***") if token else op
    texto = "".join(ch if ch.isprintable() else "?" for ch in texto)
    return texto[:80]


_LOCK_AUDIT = threading.Lock()


def auditar(arquivo: Path, op: str, token: str, motivo: str) -> None:
    linha = json.dumps({
        "ts": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "decisao": "negado",
        "motivo": motivo,
        "op": op_auditavel(op, token),
    }, ensure_ascii=False) + "\n"
    arquivo.parent.mkdir(parents=True, exist_ok=True)
    with _LOCK_AUDIT:
        fd = os.open(arquivo, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
        try:
            os.write(fd, linha.encode("utf-8"))
        finally:
            os.close(fd)


def consultar_http(texto: str, variaveis: dict, token: str) -> dict:
    corpo = json.dumps({"query": texto, "variables": variaveis}).encode()
    req = urllib.request.Request(
        LINEAR_API, data=corpo, method="POST",
        headers={"Content-Type": "application/json", "Authorization": token},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detalhe = f"HTTP {exc.code}"
        try:
            bruto = json.loads(exc.read())
            detalhe = str(bruto["errors"][0]["message"])
        except (OSError, ValueError, KeyError, IndexError, TypeError):
            pass
        raise ErroProxy(redigir(f"Linear HTTP {exc.code}: {detalhe}", token)) from None
    except urllib.error.URLError:
        raise ErroProxy("Linear: rede indisponível") from None
    if not isinstance(data, dict):
        raise ErroProxy("Linear: resposta inválida")
    if data.get("errors"):
        msg = ""
        erros = data["errors"]
        if isinstance(erros, list) and erros and isinstance(erros[0], dict):
            msg = str(erros[0].get("message") or "")
        raise ErroProxy(redigir(f"Linear: {msg or 'erro'}", token))
    saida = data.get("data")
    if not isinstance(saida, dict):
        raise ErroProxy("Linear: resposta sem data")
    return saida


def atender(pedido: dict, *, token: str, consultar: Callable, auditoria: Path) -> dict:
    op = pedido.get("op")
    if not isinstance(op, str) or not op:
        op = "sem-op"
    spec = operacoes().get(op)
    if spec is None:
        auditar(auditoria, op, token, "fora da allowlist")
        return {"ok": False, "erro": "negado", "op": op_auditavel(op, token)}
    brutas = pedido.get("vars")
    if brutas is None:
        brutas = {}
    if not isinstance(brutas, dict):
        auditar(auditoria, op, token, "variavel fora do escopo")
        return {"ok": False, "erro": "negado", "op": op}
    try:
        variaveis = spec.variaveis(brutas, op)
    except Negado:
        auditar(auditoria, op, token, "variavel fora do escopo")
        return {"ok": False, "erro": "negado", "op": op}
    try:
        data = consultar(spec.consulta, variaveis, token)
    except ErroProxy as exc:
        return {"ok": False, "erro": redigir(str(exc), token)}
    if not isinstance(data, dict):
        return {"ok": False, "erro": "resposta do Linear sem data"}
    return {"ok": True, "data": redigir(data, token)}


def pedir(op: str, variaveis: Optional[dict] = None, socket_path: Optional[Path] = None) -> dict:
    """Uma operação no proxy. Devolve o `data`. Não devolve o token."""
    caminho = Path(socket_path) if socket_path is not None else caminho_socket()
    cru = serializar_pedido(op, variaveis or {})
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(25)
    try:
        try:
            conn.connect(str(caminho))
        except OSError:
            raise ErroProxy("proxy do Linear indisponível") from None
        conn.sendall((cru + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf and len(buf) < 8_000_000:
            pedaco = conn.recv(65536)
            if not pedaco:
                break
            buf += pedaco
    finally:
        conn.close()
    try:
        resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise ErroProxy("proxy do Linear respondeu mal") from None
    if not isinstance(resp, dict) or not resp.get("ok"):
        if isinstance(resp, dict) and resp.get("erro") == "negado":
            raise Negado(str(resp.get("op") or op))
        erro = resp.get("erro") if isinstance(resp, dict) else "proxy do Linear"
        raise ErroProxy(str(erro or "proxy do Linear"))
    data = resp.get("data")
    if not isinstance(data, dict):
        raise ErroProxy("resposta do proxy sem data")
    return data


def executar_consulta(query: str, variables: Optional[dict] = None, socket_path: Optional[Path] = None) -> dict:
    """Caminho dos scripts. Consulta que não está na allowlist é negada e auditada."""
    op = operacao_da_consulta(query)
    if op is None:
        return pedir("consulta-desconhecida", {}, socket_path=socket_path)
    return pedir(op, variables or {}, socket_path=socket_path)


def _atender_conexao(conn: socket.socket, token: str, consultar: Callable, auditoria: Path) -> None:
    try:
        conn.settimeout(25)
        buf = b""
        while b"\n" not in buf and len(buf) < 2_000_000:
            pedaco = conn.recv(65536)
            if not pedaco:
                break
            buf += pedaco
        try:
            pedido = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            pedido = {"op": "json-invalido"}
        if not isinstance(pedido, dict):
            pedido = {"op": "json-invalido"}
        resp = atender(pedido, token=token, consultar=consultar, auditoria=auditoria)
        conn.sendall((json.dumps(redigir(resp, token), ensure_ascii=False) + "\n").encode("utf-8"))
    except OSError:
        pass
    finally:
        conn.close()


def servir(token: str, caminho: Path, auditoria: Path, consultar: Callable = consultar_http,
           parar: Optional[threading.Event] = None, gravar_pid: bool = False,
           pronto: Optional[threading.Event] = None) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(caminho.parent, 0o700)
    except OSError:
        pass
    if caminho.exists() or caminho.is_socket():
        caminho.unlink()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(caminho))
    os.chmod(caminho, 0o600)
    srv.listen(16)
    srv.settimeout(0.2)
    if gravar_pid:
        pid = caminho.parent / NOME_PID
        pid.write_text(str(os.getpid()), encoding="utf-8")
        os.chmod(pid, 0o600)
    if pronto is not None:
        pronto.set()
    try:
        while parar is None or not parar.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            threading.Thread(target=_atender_conexao, args=(conn, token, consultar, auditoria),
                             daemon=True).start()
    finally:
        srv.close()
        if caminho.exists() or caminho.is_socket():
            caminho.unlink(missing_ok=True)


def main(argv: Optional[list] = None) -> int:
    import sys
    args = list(sys.argv[1:] if argv is None else argv)
    if args != ["--servir"]:
        sys.stderr.write("uso: proxy_linear.py --servir\n")
        return 2
    linha = sys.stdin.readline()
    if linha.endswith("\n"):
        linha = linha[:-1]
    if linha.endswith("\r"):
        linha = linha[:-1]
    token = linha.strip()
    if not token:
        sys.stderr.write("proxy do Linear sem token\n")
        return 2
    pasta = Path.home() / ".transcentia" / "lanes"
    servir(token, pasta / NOME_SOCKET, pasta / NOME_AUDITORIA, gravar_pid=True)
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
