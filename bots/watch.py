#!/usr/bin/env python3
"""Vigia dos bots (triagem, revisor e gestor) por evento. Espelho das rotinas do gestor na nuvem.

Roda a cada 3 min (launchd com.transcentia.bots.watch, pelo lançador
"~/Library/Application Support/AgentesLocais/TuttiDash Vigia").
Espelho, nunca em paralelo: com ~/.transcentia/bots/PAUSE presente não faz nada
(a chave bots-chave cria/apaga o PAUSE conforme o gasto do Grok Bot).

Eventos (cada tick, nesta ordem; no máximo 1 rodada de IA e 1 merge por tick):
  0. Instalação no aparelho em andamento/terminada -> registra o resultado no card
     (só com `watch.instalar_comando` configurado).
  1. Card em In Review com a prova do dispatcher verde (comentário DONE <sha> = head
     do PR e "→ verde" no corpo) -> merge (um por vez), Done, instala a main no
     aparelho (SKIP_PREFLIGHT=1 primeiro; se falhar, com preflight). PR aguardando
     teste no aparelho não é mergeado: instala a branch atualizada com a main.
  2. PR mergeado cujo card não está Done -> Done (determinístico).
  3. lane:parada / lane:falhou -> a triagem acha a causa; o card volta para a fila
     (remove a label). Na 3ª parada pelo mesmo motivo chama o dono (`linear.owner_label`).
  4. etiqueta do dono -> a triagem confere se a pendência ainda existe; se não, remove a label.
  5. Fila: lane ociosa e fila vazia -> puxa o card pronto mais prioritário do Todo
     (até 2 tarefas ao mesmo tempo, uma por lane; a lane é escolhida pelo dispatcher
     via lanepct-auto, menor %). Menos de 2 cards prontos no Todo -> pede à triagem
     (comentário no Linear).
  6. PR aberto sem revisão [Revisor] no head -> revisão (SOLID + erros conhecidos E1..).

A IA (claude -p) só lê e devolve texto; quem publica, mergeia e instala é este script.
Nunca toca caminhos protegidos — a lista é a do projeto no cadastro (`projetos.py`),
relida a cada uso, e vai no prompt do agente.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path


def _cfg(chave, padrao):
    """Lê ~/.transcentia/tools/cfg (FRA-295); sem cfg ou com erro, devolve o padrão."""
    try:
        import runpy
        v = runpy.run_path(str(Path.home() / ".transcentia/tools/cfg"))["get"](chave, padrao)
        return type(padrao)(v) if padrao is not None and not isinstance(padrao, (list, set, dict)) else v
    except Exception:
        return padrao


HOME = Path.home()
STATE_DIR = HOME / ".transcentia" / "bots"
STATE_FILE = STATE_DIR / "state.json"
PROMPTS_DIR = STATE_DIR / "prompts"
LANES_DIR = HOME / ".transcentia" / "lanes"
LOG_FILE = HOME / "Library" / "Logs" / "TranscentIA" / "bots-watch.log"
RUN_LOG_DIR = HOME / "Library" / "Logs" / "TranscentIA" / "bots"
PATH_ENV = f"/opt/homebrew/bin:{HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LINEAR_API = "https://api.linear.app/graphql"
KEYCHAIN_SERVICE = _cfg("linear.keychain_service", "linear-transcentia-lanes")
# Projeto que o vigia consulta no Linear. Vem do cadastro `projetos`; sem a
# chave na config vale o iOS, como antes. Lido a cada ciclo.
def projeto_linear():
    return projeto().id
# Documentos do Linear (opcionais): sem id, o diário e a lista de erros conhecidos ficam de fora.
DIARY_DOC_ID = _cfg("linear.diary_doc_id", "")
KNOWN_ERRORS_DOC_ID = _cfg("linear.erros_conhecidos_doc_id", "")
# Estados e etiquetas: ids da config, do cache ou da API pelo nome (linear_ids, FRA-565).
STATE_IN_PROGRESS_ID = STATE_TODO_ID = ""
OWNER_LABEL = str(_cfg("linear.owner_label", "needs:dono") or "needs:dono").strip()
LABEL_IDS: dict = {}
STOP_LABELS = ("lane:parada", "lane:falhou")
BLOCKING = {OWNER_LABEL, "lane:falhou", "lane:parada"}
# Assinatura dos comentários: a função de quem escreveu.
TAG_TRIAGEM, TAG_REVISOR, TAG_GESTOR = "[Triagem]", "[Revisor]", "[Gestor]"


def achar_tag(texto: str, tag: str) -> int:
    """Posição da assinatura no texto; -1 se não tiver."""
    return texto.find(tag)


def tem_tag(texto: str, tag: str) -> bool:
    return achar_tag(texto, tag) >= 0


def normalizar_tag(texto: str, tag: str) -> str:
    return texto
# Card ou PR com uma destas labels está aguardando teste no aparelho: não mergeia, instala a branch.
DEVICE_TEST_LABELS = set(_cfg("watch.labels_teste_aparelho", ["teste:aparelho", "needs:teste-aparelho", "teste-no-aparelho"]))
# Caminhos que a lane não pode tocar, anunciados ao agente no prompt (FRA-477).
# Sai do `protegidos` do projeto no cadastro; a leitura é feita na hora, então
# mexer na config muda o freio sem reinstalar o vigia.
def protected() -> tuple:
    return tuple(projeto().protegidos)
MAX_RUNS_PER_TICK = _cfg("watch.max_runs_per_tick", 1)
CLAUDE_BUDGET_USD = _cfg("watch.claude_budget_usd", "4")
CLAUDE_TIMEOUT_S = _cfg("watch.claude_timeout_s", 20 * 60)
MAX_PARALLEL = _cfg("watch.max_tarefas", 2)            # até 2 tarefas ao mesmo tempo, uma por lane
MAX_PARALLEL_POR_AGENTE = _cfg("watch.max_tarefas_por_agente", {})  # ex.: {"codex": 1}
MAX_PER_LANE = _cfg("watch.max_tarefas_por_lane", 2)   # teto por lane ativa: 1 RUN + (N-1) WAIT
READY_TARGET = _cfg("watch.prontos_no_todo", 2)        # 2 cards prontos esperando no Todo
STOPS_TO_CALL = _cfg("watch.paradas_para_chamar", 3)   # chama o dono na 3ª parada pelo mesmo motivo
# Card onde a triagem pede cards novos quando o Todo esvazia; vazio = não pede.
TRIAGEM_PEDIDOS_CARD = _cfg("watch.card_pedidos_triagem", "")
TRIAGEM_PEDIDOS_S = _cfg("watch.pedido_triagem_intervalo_s", 4 * 3600)
# Catálogo de agentes: `catalogo.py` lê os manifests em `agents.d/` (mesmos que o
# Swift e o dispatcher). Este script é instalado sozinho em ~/.transcentia/bots,
# então o `catalogo.py` vai junto (tools/install.sh copia). Adicionar um agente
# novo = 1 arquivo JSON em `agents.d/`, sem tocar neste arquivo.
_AQUI = Path(__file__).resolve().parent
for _cand in (_AQUI, _AQUI.parent / "gasto_lanes"):   # 1º: instalado; 2º: dev no repo
    if (_cand / "catalogo.py").is_file():
        sys.path.insert(0, str(_cand))
        break
try:
    import catalogo  # noqa: E402
    import linear_ids  # noqa: E402
    import projetos  # noqa: E402
except ModuleNotFoundError as _falta:  # pragma: no cover - só sem instalar
    sys.exit(f"{_falta.name} não encontrado ao lado do watch.py — "
             "rode tools/install.sh para instalar o catálogo de agentes e projetos")
try:
    import privacidade  # noqa: E402  privacidade por modelo do OpenCode (21/10/2026)
except ModuleNotFoundError:  # pragma: no cover
    privacidade = None

# --- Projeto em que o vigia trabalha ----------------------------------------
# Vem do cadastro `projetos` da config do TuttiDash, o mesmo que o dispatcher
# lê. Sem a chave não há projeto e o vigia não faz nada (FRA-565).
def projeto():
    """Projeto em que este ciclo trabalha. A config é lida uma vez por ciclo —
    quem chama `recarregar()` no começo dele."""
    return projetos.padrao()


def _slug_git(pasta: Path) -> str:
    """`dono/repo` do remoto `origin`, para o `gh`. Vazio se não der para ler."""
    try:
        url = subprocess.run(["git", "-C", str(pasta), "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", url)
    return m.group(1) if m else ""


def _repos() -> dict:
    """Repositórios que o vigia acompanha (PRs, merges). `watch.repos` na config
    ({"app": {"dir": "~/…", "slug": "dono/repo"}}); sem ela, o repo do projeto ativo (FRA-565)."""
    bruto = _cfg("watch.repos", {})
    if isinstance(bruto, dict) and bruto:
        return {k: {"dir": Path(os.path.expanduser(str(v.get("dir", "")))), "slug": str(v.get("slug", ""))}
                for k, v in bruto.items() if isinstance(v, dict) and v.get("dir")}
    try:
        repo = projeto().repo
    except Exception:  # noqa: BLE001 — sem cadastro: o vigia fica sem repo e não mergeia nada
        return {}
    return {"app": {"dir": repo, "slug": _slug_git(repo)}}


IDS_LINEAR: dict = {}


def _aplicar_ids(ids: dict) -> None:
    global STATE_IN_PROGRESS_ID, STATE_TODO_ID, LABEL_IDS, IDS_LINEAR
    IDS_LINEAR = dict(ids or {})
    estados, labels = ids.get("estados") or {}, ids.get("labels") or {}
    STATE_IN_PROGRESS_ID = estados.get("in_progress", "")
    STATE_TODO_ID = estados.get("todo", "")
    LABEL_IDS = {n: labels.get(n, "") for n in (OWNER_LABEL, "lane:falhou", "lane:parada")}


def garantir_ids() -> None:
    """Começo do tick: resolve pelo nome o que faltar (o dispatcher usa o mesmo cache)."""
    try:
        # lanes: a caixa do dono precisa do id da etiqueta de cada lane (opção «passar à lane X»).
        _aplicar_ids(linear_ids.garantir(_cfg, lambda q, v: linear(q, v), dono=OWNER_LABEL,
                                         lanes=catalogo.lanes_por_prioridade(), project_id=projeto().id, log=log))
    except Exception as exc:  # noqa: BLE001
        log(f"linear: ids não conferidos ({exc})")


REPOS = _repos()
_aplicar_ids(linear_ids.carregar(_cfg, project_id=projetos.padrao().id))


def projeto_repo() -> Path:
    return projeto().repo


def projeto_worktrees() -> Path:
    return projeto().worktrees


#: lane -> dados do manifesto (só o que o vigia precisa: o `cli` do agente).
AGENTES = {nome: {"cli": d["cli"]} for nome, d in catalogo.catalogo().items()}
AGENTES_NOMES = tuple(AGENTES)
# Lanes com execução real (mesma lista do dispatcher, via manifesto).
IMPLEMENTED_LANES = catalogo.lanes_implementadas()
# Conflito entre cards (mesmos arquivos): o mais pesado mergeia primeiro, o outro rebaseia.
EFFORT_WEIGHT = {"baixo": 1, "medio": 2, "alto": 3}
CONFLICT_WAIT_MAX_S = _cfg("watch.conflito_espera_max_s", 6 * 3600)
# Merge só com APROVADO do revisor no head atual (revisão de 29/10, R2). Sem veredito por
# este tempo depois da prova verde, o card ganha needs:dono em vez de mergear sozinho.
REVIEW_WAIT_MAX_S = _cfg("watch.revisao_espera_max_s", 6 * 3600)
# Revisão que falhou (nenhum revisor, erro do CLI) é tentada de novo depois deste tempo (R3).
REVIEW_RETRY_S = _cfg("watch.revisao_nova_tentativa_s", 3600)
FILE_RE = re.compile(r"((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:swift|plist|json|ya?ml|py|sh|xcstrings|strings|entitlements))")
EMPTY_QUEUE_PANEL_S = _cfg("watch.fila_vazia_painel_s", 3600)   # aviso de fila vazia no painel, no máximo 1/h
STOP_ANALYSIS_TRIES = 3          # tentativas de analisar a mesma parada antes de desistir e avisar
AGENT_LIMIT_PAUSE_S = 30 * 60    # conta Claude no limite: vigia não chama IA por 30 min
# Limite MENSAL de gasto não volta em 30 min: o vigia tenta de novo só a cada 6 h e avisa uma vez por pausa.
AGENT_MONTHLY_PAUSE_S = _cfg("watch.pausa_limite_mensal_s", 6 * 3600)
NEEDS_RECHECK_S = _cfg("watch.reconferir_needs_s", 30 * 60)
INSTALL_SESSION = "instalar-aparelho"
INSTALL_SCRIPT = STATE_DIR / "instalar.sh"
# Comando que instala o app no aparelho, rodado no worktree `install-main` do projeto
# (ex.: "./scripts/instalar-no-iphone.sh"). Vazio = o vigia não instala nada (FRA-565).
INSTALL_COMMAND = str(_cfg("watch.instalar_comando", "") or "").strip()


PANEL_LOG = HOME / "Library" / "Logs" / "TranscentIA" / "lanes-dispatcher.log"
FORMAT_RETRIES = 1  # nova tentativa antes de desistir de uma revisão fora do formato


def panel(msg: str) -> None:
    """Linha no log que o painel mostra (mesmo arquivo do dispatcher), para nada parar calado."""
    try:
        PANEL_LOG.parent.mkdir(parents=True, exist_ok=True)
        with PANEL_LOG.open("a") as fh:
            fh.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} vigia: {msg}\n")
    except OSError:
        pass


def format_failure(st: dict, sha: str) -> bool:
    """Conta uma saída fora do formato para o head; True quando esgotou as tentativas (desistir)."""
    n = st.setdefault("formato_falhas", {}).get(sha, 0) + 1
    st["formato_falhas"][sha] = n
    return n > FORMAT_RETRIES


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as fh:
        fh.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")


def sh(args: list[str], cwd: Path | None = None, timeout: int = 120, inp: str | None = None, check: bool = True) -> str:
    env = {**os.environ, "PATH": PATH_ENV}
    out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env, input=inp)
    if check and out.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:3])}… ({out.returncode}): {out.stderr.strip()[:300]}"
                           f" | {out.stdout.strip()[-300:]}")
    return out.stdout


def load_state() -> dict:
    try:
        st = json.loads(STATE_FILE.read_text())
    except Exception:  # noqa: BLE001
        st = {}
    for k in ("reviewed", "alerts", "done_moves", "stops", "needs_checked", "merged", "installs", "formato_falhas", "analise_falhas", "conflitos", "rebases", "bloqueios", "removidas_pelo_vigia", "sem_revisao", "erros_revisao", "caixa_analise", "caixa_desde", "cancelados_limpos"):
        st.setdefault(k, {})
    return st


def save_state(st: dict) -> None:
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=1, ensure_ascii=False))
    tmp.replace(STATE_FILE)


# ---------- Linear ----------
def linear_key() -> str:
    out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError("chave do Linear não encontrada no Keychain")
    return out.stdout.strip()


def linear(query: str, variables: dict) -> dict:
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(LINEAR_API, data=body, method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": linear_key()})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Linear HTTP {exc.code}: {exc.read()[:300]!r}") from None
    if data.get("errors"):
        raise RuntimeError(f"Linear: {data['errors'][0].get('message')}")
    return data["data"]


ISSUE_FIELDS = """id identifier title description url priority sortOrder startedAt branchName
      state{ id name type } labels{ nodes{ id name parent{ name } } } project{ id name }
      comments(first:30, orderBy: createdAt){ nodes{ id body createdAt } }
      inverseRelations(first:30){ nodes{ type issue{ identifier state{ type } } } }"""


def em_ordem(ci: dict | None) -> dict | None:
    """Comentários do mais antigo para o mais novo, como o resto do vigia espera.

    O Linear devolve do mais novo para o mais antigo: `comments(last:30)` trazia os 30
    MAIS ANTIGOS. Card com mais de 30 comentários (FRA-582, 29/10) ficava sem o DONE
    novo, e o PR aprovado não mergeava; a parada mais recente também sumia da triagem.
    Agora a consulta pede os 30 mais novos e aqui eles voltam à ordem cronológica."""
    if ci and ci.get("comments"):
        ci["comments"]["nodes"] = sorted(ci["comments"]["nodes"], key=lambda n: n.get("createdAt") or "")
    return ci


def issue(ident: str) -> dict | None:
    try:
        return em_ordem(linear(f"query($id:String!){{ issue(id:$id){{ {ISSUE_FIELDS} }} }}", {"id": ident})["issue"])
    except RuntimeError as exc:
        log(f"issue {ident}: {exc}")
        return None


def project_issues(state_names: list[str] | None = None) -> list[dict]:
    flt = "project:{ id:{ eq:$p } }, state:{ type:{ nin:[\"completed\",\"canceled\"] } }"
    q = f"""query($p:ID!){{ issues(first:100, filter:{{ {flt} }}){{ nodes{{ {ISSUE_FIELDS} }} }} }}"""
    nodes = [em_ordem(n) for n in linear(q, {"p": projeto_linear()})["issues"]["nodes"]]
    if state_names:
        nodes = [n for n in nodes if n["state"]["name"] in state_names]
    return nodes


def labels_of(ci: dict) -> set[str]:
    return {n["name"] for n in ci["labels"]["nodes"]}


def comment(issue_id: str, body: str) -> None:
    linear("mutation($i:CommentCreateInput!){ commentCreate(input:$i){ success } }",
           {"i": {"issueId": issue_id, "body": body}})


def add_label(issue_id: str, name: str) -> None:
    if not LABEL_IDS.get(name):
        log(f"linear: etiqueta «{name}» sem id; não apliquei")
        return
    linear("mutation($id:String!,$l:String!){ issueAddLabel(id:$id, labelId:$l){ success } }",
           {"id": issue_id, "l": LABEL_IDS[name]})


def remove_label(issue_id: str, name: str) -> None:
    if not LABEL_IDS.get(name):
        return
    linear("mutation($id:String!,$l:String!){ issueRemoveLabel(id:$id, labelId:$l){ success } }",
           {"id": issue_id, "l": LABEL_IDS[name]})


def prepend_description(ci: dict, text: str) -> None:
    linear("mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id,input:$i){ success } }",
           {"id": ci["id"], "i": {"description": text + (ci.get("description") or "")}})


def set_state(issue_id: str, state_id: str) -> None:
    if not state_id:
        log("linear: estado sem id; não mudei o card")
        return
    linear("mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id,input:$i){ success } }",
           {"id": issue_id, "i": {"stateId": state_id}})


def diary_append(lines: list[str]) -> None:
    if not lines or not DIARY_DOC_ID:
        return
    try:
        doc = linear("query($id:String!){ document(id:$id){ content } }", {"id": DIARY_DOC_ID})["document"]
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        block = f"\n\n### {stamp} BRT — vigia dos bots (por evento)\n\n" + "\n".join(f"- {l}" for l in lines)
        linear("mutation($id:String!,$i:DocumentUpdateInput!){ documentUpdate(id:$id,input:$i){ success } }",
               {"id": DIARY_DOC_ID, "i": {"content": (doc.get("content") or "") + block}})
    except RuntimeError as exc:
        log(f"diário: {exc}")


def known_errors() -> str:
    if not KNOWN_ERRORS_DOC_ID:
        return "(sem lista de erros conhecidos: linear.erros_conhecidos_doc_id vazio)"
    try:
        doc = linear("query($id:String!){ document(id:$id){ content } }", {"id": KNOWN_ERRORS_DOC_ID})["document"]
        return (doc.get("content") or "")[:12000]
    except RuntimeError as exc:
        log(f"erros conhecidos: {exc}")
        return "(lista de erros conhecidos indisponível agora)"


def done_state_id(team_issue: dict) -> str | None:
    q = """query($id:String!){ issue(id:$id){ team{ states{ nodes{ id type name } } } } }"""
    nodes = linear(q, {"id": team_issue["id"]})["issue"]["team"]["states"]["nodes"]
    for n in nodes:
        if n["type"] == "completed" and n["name"].lower() == "done":
            return n["id"]
    return next((n["id"] for n in nodes if n["type"] == "completed"), None)


def move_done(ci: dict, why: str, diary: list[str]) -> None:
    sid = done_state_id(ci)
    if sid:
        set_state(ci["id"], sid)
        comment(ci["id"], f"[Triagem] {why}; card movido para Done (vigia dos bots).")
        diary.append(f"Triagem · {ci['identifier']} → Done ({why})")
        log(f"{ci['identifier']} → Done")


# ---------- GitHub ----------
def open_prs(repo: dict) -> list[dict]:
    raw = sh(["gh", "pr", "list", "--state", "open", "--limit", "30", "--json",
              "number,title,headRefOid,headRefName,url,mergeStateStatus,isDraft,body,labels"], cwd=repo["dir"])
    return [p for p in json.loads(raw) if not p.get("isDraft")]


def revisor_ja_revisou(repo: dict, pr: dict) -> bool:
    raw = sh(["gh", "pr", "view", str(pr["number"]), "--json", "comments"], cwd=repo["dir"])
    sha7 = pr["headRefOid"][:7]
    return any(tem_tag(c["body"], TAG_REVISOR) and sha7 in c["body"] for c in json.loads(raw)["comments"])


def veredito_publicado(repo: dict, pr: dict) -> str | None:
    """Veredito do último comentário [Revisor] no PR que cita o head atual; None sem nenhum."""
    raw = sh(["gh", "pr", "view", str(pr["number"]), "--json", "comments"], cwd=repo["dir"])
    sha7 = pr["headRefOid"][:7]
    achados = [c["body"] for c in json.loads(raw)["comments"]
               if tem_tag(c["body"], TAG_REVISOR) and sha7 in c["body"]]
    return veredito_de(achados[-1][achar_tag(achados[-1], TAG_REVISOR):]) if achados else None


def veredito_do_head(repo: dict, pr: dict, st: dict) -> str | None:
    """APROVADO, AJUSTES ou None (sem veredito). `ja-tinha` (estado antigo) é resolvido
    lendo o comentário do revisor no PR."""
    v = st["reviewed"].get(pr["headRefOid"])
    if v in ("APROVADO", "AJUSTES"):
        return v
    if v == "ja-tinha":
        v = veredito_publicado(repo, pr)
        if v:
            st["reviewed"][pr["headRefOid"]] = v
        return v
    return None


def revisao_pode_tentar(st: dict, head: str, agora: float | None = None) -> bool:
    """Head sem revisão, ou com erro mais velho que REVIEW_RETRY_S (R3)."""
    v = st["reviewed"].get(head)
    if v is None:
        return True
    if not str(v).startswith("erro"):
        return False
    agora = time.time() if agora is None else agora
    return agora - float(st.setdefault("erros_revisao", {}).get(head, 0)) >= REVIEW_RETRY_S


def segurar_sem_aprovacao(ci: dict, pr: dict, st: dict, diary: list[str], agora: float | None = None) -> None:
    """PR pronto sem APROVADO: espera; passou de REVIEW_WAIT_MAX_S, chama o dono (uma vez por head)."""
    agora = time.time() if agora is None else agora
    head = pr["headRefOid"]
    desde = st.setdefault("sem_revisao", {}).setdefault(head, agora)
    if agora - desde < REVIEW_WAIT_MAX_S or st["sem_revisao"].get(head + "|avisado"):
        return
    st["sem_revisao"][head + "|avisado"] = agora
    situacao = st["reviewed"].get(head) or "nenhuma revisão ainda"
    add_label(ci["id"], OWNER_LABEL)
    comment(ci["id"], f"[Gestor] PR #{pr['number']} está pronto (prova verde), mas o head `{head[:7]}` "
                      f"está sem APROVADO do revisor há {int((agora - desde) // 3600)} h ({situacao}). "
                      f"Não mergeio sem revisão: revise o PR ou mergeie à mão, e tire `{OWNER_LABEL}`.")
    diary.append(f"Gestor · {ci['identifier']} PR #{pr['number']} sem revisão há "
                 f"{int((agora - desde) // 3600)} h → chamou o dono")


def card_of(title: str, branch: str) -> str | None:
    m = re.search(r"\b(FRA-\d+)\b", title, re.I) or re.search(r"\b(fra-\d+)\b", branch, re.I)
    return m.group(1).upper() if m else None


# ---------- agente ----------
READ_ONLY_SETTINGS = {
    "permissions": {
        "allow": ["Read", "Glob", "Grep", "Bash(git show:*)", "Bash(git diff:*)", "Bash(git log:*)",
                  "Bash(git ls-tree:*)", "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(grep:*)",
                  "Bash(wc:*)", "Bash(ls:*)"],
        "deny": ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Bash(git push:*)",
                 "Bash(git commit:*)", "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git checkout:*)",
                 "Bash(git reset:*)", "Bash(gh:*)", "Bash(rm:*)", "Bash(curl:*)", "Bash(osascript:*)",
                 "Bash(xcodebuild:*)", "Bash(sudo:*)", "Bash(git worktree:*)", "Bash(git clone:*)"],
    }
}


def prompt(name: str) -> str:
    """Prompts versionados em tuttidash/bots/prompts, instalados em ~/.transcentia/bots/prompts."""
    return (PROMPTS_DIR / f"{name}.md").read_text()


LIMIT_FILE = STATE_DIR / "limite-agente"
LIMIT_RE = re.compile(r"(hit your|reached your)[^|\n]{0,60}limit|rate.?limit|usage limit", re.I)
MONTHLY_RE = re.compile(r"monthly (spend|usage|spending) limit", re.I)


def ler_pausa() -> tuple[float, bool]:
    """(até quando, se é o limite mensal). (0, False) sem pausa gravada."""
    try:
        linhas = LIMIT_FILE.read_text().split()
        return float(linhas[0]), "mensal" in linhas[1:]
    except (OSError, ValueError, IndexError):
        return 0.0, False


def agent_paused() -> bool:
    """True enquanto a conta Claude está no limite (sem chamar IA para não gastar ciclos à toa)."""
    until, mensal = ler_pausa()
    if not until:
        return False
    if until > time.time():
        return True
    LIMIT_FILE.unlink(missing_ok=True)
    if mensal:
        log("pausa do limite mensal acabou; o vigia tenta o Claude de novo")
    else:
        panel("conta Claude saiu do limite; vigia volta a analisar paradas e revisar PRs")
    return False


def note_agent_failure(exc: Exception) -> None:
    """Falha do `claude -p` por limite de uso pausa a IA do vigia e avisa no painel."""
    if LIMIT_RE.search(str(exc)) and not agent_paused():
        mensal = bool(MONTHLY_RE.search(str(exc)))
        until = time.time() + (AGENT_MONTHLY_PAUSE_S if mensal else AGENT_LIMIT_PAUSE_S)
        LIMIT_FILE.write_text(f"{until}{' mensal' if mensal else ''}")
        if mensal:
            panel(f"conta Claude sem cota mensal de gasto; vigia tenta de novo às {datetime.fromtimestamp(until):%H:%M} "
                  "(para voltar antes, suba o limite em claude.ai/settings/usage)")
        else:
            panel(f"conta Claude no limite de uso; vigia pausa a IA até {datetime.fromtimestamp(until):%H:%M} "
                  "e tenta de novo (paradas e revisões ficam pendentes, não perdidas)")


def run_agent(text: str, cwd: Path, tag: str, agente: str | None = None, modelo: str = "opus", esforco: str | None = None,
              teto: str | float | None = None) -> str:
    RUN_LOG_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(READ_ONLY_SETTINGS, fh)
        settings = fh.name
    mcp = STATE_DIR / "empty-mcp.json"
    if not mcp.exists():
        mcp.write_text('{"mcpServers":{}}')
    # A análise de parada e de PR é do vigia, Claude headless (GESTAO_IOS §5). As flags do
    # `claude -p` não existem em opencode/codex/grok: a análise de card de opencode saía
    # "Unrecognized flag: -p" e a parada ficava sem análise (FRA-449, 19/10).
    cli = "claude"
    args = [cli, "-p", "--output-format", "text", "--permission-mode", "default",
            "--settings", settings, "--strict-mcp-config", "--mcp-config", str(mcp),
            "--max-budget-usd", str(teto or CLAUDE_BUDGET_USD), "--model", modelo, "--effort", esforco or ("high" if modelo == "opus" else "low")]
    started = time.time()
    try:
        out = sh(args, cwd=cwd, timeout=CLAUDE_TIMEOUT_S, inp=text)
    except Exception as exc:  # noqa: BLE001
        note_agent_failure(exc)
        raise
    finally:
        os.unlink(settings)
    (RUN_LOG_DIR / f"{tag}-{datetime.now():%Y%m%d-%H%M%S}.md").write_text(out)
    log(f"agente {tag} [{modelo}/{args[-1]}]: {int(time.time() - started)} s, {len(out)} chars")
    return out.strip()


def lane_of(ci: dict | None) -> str:
    if not ci:
        return "desconhecida"
    names = labels_of(ci)
    for agente in AGENTES_NOMES:
        if agente in names:
            return agente
    return "manual"


def max_parallel_para(agente: str) -> int:
    """Limite de tarefas simultâneas: por agente se configurado, senão o global."""
    try:
        v = (MAX_PARALLEL_POR_AGENTE or {}).get(agente)
        return int(v) if v else int(MAX_PARALLEL)
    except (TypeError, ValueError):
        return int(MAX_PARALLEL)


def fmt_comments(ci: dict | None, limit: int = 6, cut: int = 1500) -> str:
    if not ci:
        return "(sem card)"
    nodes = ci["comments"]["nodes"][-limit:]
    return "\n\n---\n".join(n["body"][:cut] for n in nodes) or "(sem comentários)"


def lane_log_tail(ident: str) -> tuple[str, str]:
    logs = sorted((HOME / "Library/Logs/TranscentIA/lanes").glob(f"{ident}-*.jsonl"), key=lambda p: p.stat().st_mtime)
    if not logs:
        return "-", "(sem log de lane)"
    return logs[-1].name, logs[-1].read_text(errors="replace")[-6000:]


INSTR_RE = re.compile(r"^INSTRU[ÇC][ÃA]O:\s*(.+)$", re.M | re.I)


def stop_note(ci: dict, text: str, count: int, reason: str) -> str | None:
    """Contramedida FRA-326 (11/10): a instrução da triagem ficava só no comentário e a lane só lê a
    descrição, então parou 3x pelo mesmo E1. Devolve o bloco para o topo da descrição, ou None se
    não há instrução ou ela já está lá."""
    m = INSTR_RE.search(text)
    if not m:
        return None
    instr = m.group(1).strip()
    if not instr or instr in (ci.get("description") or ""):
        return None
    return (f"> ⛔ **Retomada {count} ({reason[:80]}), triagem {datetime.now():%d/%m %H:%M}:** {instr}\n"
            "> (instrução da parada anterior; vale antes de tudo abaixo)\n\n")


def decision(text: str) -> str:
    m = re.search(r"^DECIS[ÃA]O:\s*(\w+)", text, re.M | re.I)
    return m.group(1).lower() if m else "manter"


RETOMADA_RE = re.compile(r"^> ⛔ \*\*Retomada \d+[^\n]*\n> \(instru[çc][ãa]o da parada anterior[^\n]*(?:\n|$)\n*", re.M)


def limpar_retomadas(desc: str) -> tuple[str, list[str]]:
    """Tira da descrição os blocos que o `stop_note` pôs no topo. Devolve (descrição nova,
    blocos tirados). O resto do texto fica como estava."""
    tirados = [m.group(0).rstrip("\n") for m in RETOMADA_RE.finditer(desc or "")]
    return (RETOMADA_RE.sub("", desc or "") if tirados else (desc or "")), tirados


def set_description(ci: dict, text: str) -> None:
    linear("mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id,input:$i){ success } }",
           {"id": ci["id"], "i": {"description": text}})


def expirar_retomadas(issues: list[dict], st: dict, diary: list[str]) -> None:
    """PRD 29/10, mudança 2: a instrução da triagem expira quando o dono libera o card.

    Liberar = `needs:dono` sumiu (dono ou `recheck_needs`), ou `lane:falhou` sumiu sem ter
    sido o vigia (o `voltar_fila` tira a label logo depois de escrever a instrução, e aí ela
    vale). Na liberação o vigia tira os blocos de Retomada da descrição, cita o texto num
    comentário e zera o contador de paradas do card. Sem o zero, a 1ª falha depois da
    liberação já contava como a 4ª e chamava o dono sem triagem (FRA-581, 29/10)."""
    vigiadas = (OWNER_LABEL, "lane:falhou")
    st.setdefault("bloqueios", {})
    st.setdefault("removidas_pelo_vigia", {})
    vistos: set[str] = set()
    for ci in issues:
        ident = ci["identifier"]
        vistos.add(ident)
        atuais = labels_of(ci) & set(vigiadas)
        antes = set(st["bloqueios"].get(ident, []))
        sumiram = antes - atuais
        pelo_vigia = {lb for lb in sumiram if f"{ident}|{lb}" in st["removidas_pelo_vigia"]}
        liberado = OWNER_LABEL in sumiram or ("lane:falhou" in sumiram and "lane:falhou" not in pelo_vigia)
        for lb in sumiram:
            st["removidas_pelo_vigia"].pop(f"{ident}|{lb}", None)
        if atuais:
            st["bloqueios"][ident] = sorted(atuais)
        else:
            st["bloqueios"].pop(ident, None)
        if not liberado:
            continue
        if ident in st["stops"]:
            st["stops"][ident]["motivos"] = {}
        nova, tirados = limpar_retomadas(ci.get("description") or "")
        if not tirados:
            continue
        set_description(ci, nova)
        ci["description"] = nova
        comment(ci["id"], "[Triagem] Card liberado: tirei da descrição a instrução de retomada, "
                          "que valia para a parada anterior. Texto tirado (se ainda valer, cole de volta):\n\n"
                          + "\n\n".join(tirados))
        diary.append(f"Triagem · {ident} liberado → {len(tirados)} instrução(ões) de retomada tirada(s)")
    for ident in list(st["bloqueios"]):
        if ident not in vistos:
            st["bloqueios"].pop(ident, None)
    for chave in list(st["removidas_pelo_vigia"]):
        if chave.split("|", 1)[0] not in vistos:
            st["removidas_pelo_vigia"].pop(chave, None)


# ---------- 0/1. merge + instalação no aparelho ----------
def tmux_alive(session: str) -> bool:
    return subprocess.run(["tmux", "has-session", "-t", session], capture_output=True,
                          env={**os.environ, "PATH": PATH_ENV}).returncode == 0


def start_install(ref: str, tag: str, card_id: str | None, st: dict, diary: list[str]) -> bool:
    """Instala no aparelho numa sessão tmux própria (E14), no worktree `<worktrees>/install-main` do projeto."""
    if not INSTALL_COMMAND:
        return False
    if tmux_alive(INSTALL_SESSION):
        log(f"instalação {tag}: outra instalação em andamento, fica para o próximo tick")
        return False
    out = HOME / "Library/Logs/TranscentIA" / f"device-build-{tag}-{datetime.now():%Y%m%d-%H%M%S}.log"
    p = projeto()
    sh(["tmux", "new-session", "-d", "-s", INSTALL_SESSION,
        " ".join(shlex.quote(x) for x in ["/bin/bash", str(INSTALL_SCRIPT), ref, str(out), str(p.repo),
                                         str(p.worktrees / "install-main"), INSTALL_COMMAND])])
    st["installs"]["atual"] = {"ref": ref, "tag": tag, "card_id": card_id, "log": str(out),
                               "inicio": datetime.now().isoformat(timespec="seconds")}
    diary.append(f"Gestor · instalação no aparelho iniciada ({ref}); log {out.name}")
    log(f"instalação {tag} iniciada ({ref})")
    return True


def check_install(st: dict, diary: list[str]) -> None:
    cur = st["installs"].get("atual")
    if not cur or tmux_alive(INSTALL_SESSION):
        return
    exit_f = Path(cur["log"] + ".exit")
    rc = exit_f.read_text().strip() if exit_f.exists() else "?"
    ok = rc == "0"
    msg = (f"[Gestor] Instalação no aparelho de `{cur['ref']}`: {'instalado' if ok else f'falhou (código {rc})'}. "
           f"Log: `{cur['log']}`")
    if cur.get("card_id"):
        try:
            comment(cur["card_id"], msg)
        except RuntimeError as exc:
            log(f"comentário da instalação: {exc}")
    diary.append(msg.replace("[Gestor] ", "Gestor · "))
    log(msg)
    st["installs"]["ultima"] = dict(cur, rc=rc)
    st["installs"].pop("atual", None)
    # Falha não reinstala sozinha em laço: fica no card/diário para a próxima rodada de merge ou para o gestor.


def proof_passed(ci: dict, pr: dict) -> bool:
    """Prova do dispatcher verde no head atual: comentário DONE <sha> e '→ verde' no corpo do PR."""
    if "→ verde" not in (pr.get("body") or ""):
        return False
    for n in reversed(ci["comments"]["nodes"]):
        m = re.match(r"\s*DONE\s+([0-9a-f]{7,40})", n["body"])
        if m:
            return pr["headRefOid"].startswith(m.group(1))
    return False


def waiting_device_test(ci: dict, pr: dict) -> bool:
    names = labels_of(ci) | {l["name"] for l in pr.get("labels") or []}
    return bool(names & DEVICE_TEST_LABELS)


def merge_ready(st: dict, diary: list[str]) -> None:
    repo = REPOS["app"]
    prs = {card_of(p["title"], p["headRefName"]): p for p in open_prs(repo)}
    for ci in sorted(project_issues(["In Review"]), key=lambda c: c.get("sortOrder") or 0):
        pr = prs.get(ci["identifier"])
        if not pr or labels_of(ci) & BLOCKING:
            continue
        if waiting_device_test(ci, pr):
            key = f"{pr['number']}@{pr['headRefOid'][:7]}"
            if st["installs"].get("branch_feita") != key and start_install(
                    f"branch:{pr['headRefName']}", f"pr{pr['number']}", ci["id"], st, diary):
                st["installs"]["branch_feita"] = key
            continue
        if not proof_passed(ci, pr):
            continue
        veredito = veredito_do_head(repo, pr, st)
        if veredito == "AJUSTES":
            continue  # a revisão pediu ajustes no head atual
        if veredito != "APROVADO":
            segurar_sem_aprovacao(ci, pr, st, diary)
            continue
        if pr.get("mergeStateStatus") not in ("CLEAN", "UNSTABLE", "HAS_HOOKS"):
            log(f"{ci['identifier']} PR #{pr['number']}: merge adiado ({pr.get('mergeStateStatus')})")
            continue
        if hold_for_heavier(ci, pr, st, diary):
            continue
        sh(["gh", "pr", "merge", str(pr["number"]), "--squash", "--match-head-commit", pr["headRefOid"]],
           cwd=repo["dir"], timeout=180)
        st["merged"][str(pr["number"])] = datetime.now().isoformat(timespec="seconds")
        st["done_moves"][f"app#{pr['number']}"] = ci["identifier"]
        move_done(ci, f"PR #{pr['number']} mergeado com a prova do dispatcher verde e revisão APROVADO", diary)
        st["installs"]["pendente_main"] = True
        st["installs"]["card_main"] = ci["id"]
        return  # um merge por vez


def pr_files(pr: dict) -> set[str]:
    raw = sh(["gh", "pr", "view", str(pr["number"]), "--json", "files", "-q", ".files[].path"],
             cwd=REPOS["app"]["dir"], check=False)
    return {l.rsplit("/", 1)[-1] for l in raw.splitlines() if l.strip()}


def hold_for_heavier(ci: dict, pr: dict, st: dict, diary: list[str]) -> bool:
    """True = segurar o merge deste PR: um card mais pesado, ativo e sem bloqueio, mexe nos mesmos
    arquivos e mergeia primeiro. Teto de espera: CONFLICT_WAIT_MAX_S (depois mergeia e o outro rebaseia)."""
    active = [c for c in project_issues(["In Progress", "In Review"])
              if c["id"] != ci["id"] and not (labels_of(c) & BLOCKING)]
    if not active:
        st["conflitos"].pop(ci["identifier"], None)
        return False
    files = pr_files(pr) | card_files(ci)
    hit = heavier_conflict(ci, files, [(c, card_files(c)) for c in active])
    if not hit:
        st["conflitos"].pop(ci["identifier"], None)
        return False
    other, shared = hit
    rec = st["conflitos"].setdefault(ci["identifier"], {"desde": time.time(), "com": other["identifier"]})
    waited = time.time() - rec["desde"]
    if waited > CONFLICT_WAIT_MAX_S:
        if not rec.get("liberado"):
            rec["liberado"] = True
            msg = (f"{ci['identifier']} esperou {int(waited // 3600)} h pelo {other['identifier']} (mais pesado); "
                   f"mergeia agora e o {other['identifier']} rebaseia depois")
            panel(f"conflito: {msg}")
            diary.append(f"Gestor · {msg}")
        return False
    if rec.get("com") != other["identifier"] or not rec.get("avisado"):
        rec.update({"com": other["identifier"], "avisado": True})
        msg = (f"{ci['identifier']} PR #{pr['number']} pronto, mas segura o merge: {other['identifier']} é mais "
               f"pesado e mexe nos mesmos arquivos ({', '.join(sorted(shared)[:6])}). Ordem: "
               f"{other['identifier']} primeiro; este rebaseia na main depois (teto {CONFLICT_WAIT_MAX_S // 3600} h)")
        panel(f"conflito: {msg}")
        comment(ci["id"], f"[Gestor] {msg}.")
        diary.append(f"Gestor · {msg}")
    return True


def rebase_dirty(st: dict, diary: list[str]) -> None:
    """PR em conflito com a main (DIRTY): o vigia junta a main no worktree do card (deixando os
    conflitos marcados, se houver), escreve a rodada de conflito no topo do card e devolve o card
    à fila da mesma lane. A lane resolve, commita, roda a prova e o dispatcher fecha de novo."""
    repo = REPOS["app"]
    running = {json.loads(p.read_text()).get("card") for p in LANES_DIR.glob("lane-*.json")
               if p.stem.split("-", 1)[1] in AGENTES_NOMES}
    for pr in open_prs(repo):
        if pr.get("mergeStateStatus") != "DIRTY":
            continue
        card = card_of(pr["title"], pr["headRefName"])
        key = f"{pr['number']}@{pr['headRefOid'][:7]}"
        if not card or card in running or key in st["rebases"]:
            continue
        ci = issue(card)
        if not ci or ci["state"]["name"] != "In Review" or labels_of(ci) & BLOCKING:
            continue
        wt = projeto_worktrees() / card.lower()
        st["rebases"][key] = datetime.now().isoformat(timespec="seconds")
        if not (wt / ".git").exists():
            msg = f"{card} PR #{pr['number']} em conflito com a main e sem worktree local; precisa do gestor"
            panel(f"conflito: {msg}")
            comment(ci["id"], f"[Gestor] ⚠️ {msg}.")
            continue
        sh(["git", "fetch", "-q", "origin"], cwd=wt, timeout=180)
        head = sh(["git", "rev-parse", "HEAD"], cwd=wt).strip()
        dirty = [l for l in sh(["git", "status", "--porcelain"], cwd=wt).splitlines()
                 if l.strip() and ".lane/" not in l]
        if head != pr["headRefOid"] or dirty:
            msg = (f"{card} PR #{pr['number']} em conflito com a main, mas o worktree não está no head do PR "
                   f"ou tem mudança local; precisa do gestor")
            panel(f"conflito: {msg}")
            comment(ci["id"], f"[Gestor] ⚠️ {msg}.")
            continue
        out = subprocess.run(["git", "merge", "--no-edit", "origin/main"], cwd=wt, capture_output=True,
                             text=True, env={**os.environ, "PATH": PATH_ENV})
        conflicted = sh(["git", "diff", "--name-only", "--diff-filter=U"], cwd=wt, check=False).split()
        what = (f"conflito em {', '.join(conflicted[:8])}" if conflicted
                else "a main entrou sem conflito textual (commit de merge local, ainda não enviado)")
        prepend_description(ci,
            f"## Rodada de conflito (vigia, {datetime.now():%d/%m %H:%M})\n\n"
            f"O PR #{pr['number']} ficou em conflito com a `main` depois do merge de um card mais pesado. "
            f"O vigia já rodou `git merge origin/main` neste worktree: {what}.\n\n"
            "- Faça **só** isto: resolva os marcadores de conflito mantendo o que a `main` trouxe e o que este "
            "card fez, `git add` dos arquivos e `git commit --no-edit`.\n"
            "- Rode a prova do card e escreva `.lane/result.json` com `done`. Não refaça o card.\n\n---\n\n")
        set_state(ci["id"], STATE_IN_PROGRESS_ID)
        comment(ci["id"], f"[Gestor] PR #{pr['number']} em conflito com a main: {what}. Card de volta à fila da "
                          "mesma lane para resolver e provar de novo (instrução no topo da descrição).")
        panel(f"conflito: {card} PR #{pr['number']} DIRTY → main juntada no worktree ({what}); volta à lane")
        diary.append(f"Gestor · {card} PR #{pr['number']} em conflito → rodada de rebase na lane")
        log(f"{card}: rebase preparado (merge rc={out.returncode}, conflitos={len(conflicted)})")
        return  # um por ciclo


def install_main_if_pending(st: dict, diary: list[str]) -> None:
    if st["installs"].get("pendente_main") and start_install("main", "main", st["installs"].get("card_main"), st, diary):
        st["installs"]["pendente_main"] = False


# ---------- 2. mergeado e não Done ----------
def merged_not_done(st: dict, diary: list[str]) -> None:
    for key, repo in REPOS.items():
        raw = sh(["gh", "pr", "list", "--state", "merged", "--limit", "10", "--json", "number,title,headRefName"],
                 cwd=repo["dir"])
        for pr in json.loads(raw):
            card = card_of(pr["title"], pr["headRefName"])
            mark = f"{key}#{pr['number']}"
            if not card or mark in st["done_moves"]:
                continue
            ci = issue(card)
            st["done_moves"][mark] = card
            if ci and ci["state"]["type"] not in ("completed", "canceled"):
                move_done(ci, f"PR #{pr['number']} já está na main", diary)


# ---------- 3. paradas ----------
CAUSA_RE = re.compile(r"causa:\s*`([a-z0-9-]+)`")


def stop_reason(ci: dict, label: str) -> tuple[str, str]:
    """(id do comentário da parada, motivo normalizado).

    Melhoria 1 (21/10/2026): o dispatcher grava `- causa: `x`` no comentário; quando
    existe, o motivo é a causa (estável entre rodadas). Sem ela (comentário antigo),
    o texto do motivo sem números e sem o que vem entre parênteses (lista de suítes,
    códigos), que mudava de rodada para rodada e escondia a parada repetida."""
    for n in reversed(ci["comments"]["nodes"]):
        body = n["body"]
        if body.lstrip().startswith("["):
            continue  # análise da triagem/gestor/revisor cita a label, mas não é a parada
        if label in body or "Motivo:" in body:
            c = CAUSA_RE.search(body)
            if c:
                return n["id"], "causa:" + c.group(1)
            m = re.search(r"Motivo:\**\s*(.+)", body) or re.search(rf"{label}\s*\(([^)]+)\)", body)
            raw = (m.group(1) if m else body.splitlines()[0])[:160]
            raw = re.sub(r"\([^)]*(?:\)|$)", "", raw)
            norm = re.sub(r"\s+", " ", re.sub(r"[0-9]+", "#", raw.lower())).strip()
            return n["id"], norm
    return "sem-comentario", "motivo não registrado"


def analysis_failed(st: dict, cid: str) -> bool:
    """Conta uma falha ao analisar a parada `cid`; True quando esgotou as tentativas."""
    n = st.setdefault("analise_falhas", {}).get(cid, 0) + 1
    st["analise_falhas"][cid] = n
    return n >= STOP_ANALYSIS_TRIES


def modelo_da_analise(st: dict, cid: str, count: int) -> str:
    # Análise progressiva da parada (20/10): haiku, depois sonnet, por fim opus, esforço médio.
    # Sobe um nível a cada falha de análise da mesma parada e a cada parada repetida pelo mesmo motivo.
    nivel = min(2, max(st.get("analise_falhas", {}).get(cid, 0), count - 1))
    return ("haiku", "sonnet", "opus")[nivel]


def handle_stops(ci: dict, label: str, st: dict, diary: list[str]) -> bool:
    """Devolve True se usou uma rodada de IA."""
    cid, reason = stop_reason(ci, label)
    per_card = st["stops"].setdefault(ci["identifier"], {"vistos": [], "motivos": {}})
    if cid in per_card["vistos"]:
        return False
    count = per_card["motivos"].get(reason, 0) + 1

    def seen() -> None:
        per_card["vistos"] = (per_card["vistos"] + [cid])[-20:]
        per_card["motivos"][reason] = count
        st["analise_falhas"].pop(cid, None)
    if count >= STOPS_TO_CALL:
        add_label(ci["id"], OWNER_LABEL)
        comment(ci["id"], f"[Triagem] {count}ª parada pelo mesmo motivo ({reason}). dono, preciso de você neste "
                          f"card: a causa se repete e a fila não resolve sozinha. O card fica com `{label}` e "
                          f"`{OWNER_LABEL}` até a sua decisão.")
        diary.append(f"Triagem · {ci['identifier']} {label} {count}x ({reason}) → chamou o dono")
        seen()
        return False
    # FRA-532 (23/10/2026 20h33): triagem local primeiro, depois opencode free, Claude por último.
    # Conta Claude no limite não segura mais a análise: só pula a etapa do Claude.
    try:
        text, quem = analisar_parada(ci, label, st, cid, count, reason)
        problem = None
    except Exception as exc:  # noqa: BLE001
        problem = str(exc)[:160]
    if problem:
        if analysis_failed(st, cid):
            seen()
            msg = (f"{ci['identifier']} {label}: a triagem não conseguiu analisar a parada "
                   f"{STOP_ANALYSIS_TRIES}x ({problem}); card parado, precisa do gestor")
            panel(msg)
            comment(ci["id"], f"[Gestor] ⚠️ {msg}.")
            diary.append(f"Triagem · {msg}")
        else:
            panel(f"{ci['identifier']} {label}: análise da parada falhou ({problem}); tento de novo no próximo ciclo")
        return True
    seen()
    dec = decision(text)
    comment(ci["id"], text + rodape_analise(quem))
    if dec == "chamar_dono":
        add_label(ci["id"], OWNER_LABEL)
        diary.append(f"Triagem · {ci['identifier']} {label} → precisa do dono")
    else:
        note = stop_note(ci, text, count, reason)
        if note:
            prepend_description(ci, note)
        remove_label(ci["id"], label)
        st.setdefault("removidas_pelo_vigia", {})[f"{ci['identifier']}|{label}"] = datetime.now().isoformat(timespec="seconds")
        diary.append(f"Triagem · {ci['identifier']} {label} ({count}x: {reason}) → de volta à fila"
                     + (" com a instrução no topo da descrição" if note else ""))
    return True


# ---------- 4. etiqueta do dono ----------
SHADOW_NEEDS_LOG = HOME / 'Library' / 'Logs' / 'TranscentIA' / 'shadow-needs.jsonl'
OLLAMA_URL = 'http://localhost:11434/api/generate'
OLLAMA_SHADOW_MODEL = 'qwen2.5-coder:7b'


def local_call(p: str, modelo: str | None = None) -> str:
    body = json.dumps({'model': modelo or OLLAMA_SHADOW_MODEL, 'prompt': p, 'stream': False,
                       'options': {'temperature': 0.1, 'num_ctx': 8192}}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())['response']


def shadow_needs(ci: dict, p: str, principal: str, principal_por: str, etapa: str) -> None:
    """Sombra (FRA-532): roda a próxima etapa da ordem só para comparar; não comenta nem mexe em label.
    Antes o principal era o opencode e o Ollama a sombra; agora é o contrário."""
    rec = {'ts': datetime.now().isoformat(timespec='seconds'), 'card': ci['identifier'],
           'principal': decision(principal), 'principal_por': principal_por, 'sombra_etapa': etapa}
    t0 = time.time()
    try:
        out, por = ETAPAS_NEEDS[etapa](p)
        rec['sombra'] = decision(out)
        rec['sombra_por'] = por
        rec['sombra_formato_ok'] = True
    except Exception as exc:  # noqa: BLE001
        rec['sombra'] = None
        rec['sombra_erro'] = str(exc)[:160]
    rec['sombra_s'] = round(time.time() - t0, 1)
    rec['igual'] = rec.get('sombra') == rec['principal']
    panel(f"sombra needs {ci['identifier']}: {principal_por}={rec['principal']} {etapa}={rec.get('sombra')} "
          f"({rec['sombra_s']} s)")
    try:
        with open(SHADOW_NEEDS_LOG, 'a', encoding='utf-8') as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + chr(10))
    except OSError:
        pass


OPENCODE_NEEDS_MODEL = _cfg("watch.modelo_needs_opencode", "opencode/deepseek-v4.1-flash-free")


def privacidade_ok(agente: str, modelo: str) -> tuple[bool, str]:
    """O modelo deste agente pode receber código/texto de card? Só confere agentes com
    `privacidade` no manifesto (os do OpenCode); fail-closed sem o módulo."""
    if not (catalogo.catalogo().get(agente) or {}).get("privacidade"):
        return True, ""
    if privacidade is None:
        return False, "módulo de privacidade ausente"
    return privacidade.pode_receber_codigo(modelo)


def opencode_call(p: str, modelo: str | None = None, cwd: Path | None = None) -> str:
    # Modelo free do opencode (20/10). Agente plan (só lê), numa pasta vazia ou no repo
    # quando a parada pede leitura do código; devolve o texto a partir de [Triagem], sem o rodapé do CLI.
    modelo = modelo or OPENCODE_NEEDS_MODEL
    ok, motivo = privacidade_ok("opencode", modelo)
    if not ok:
        raise RuntimeError(f"privacidade: {motivo}")
    with tempfile.TemporaryDirectory() as tmp:
        out = sh(["opencode", "run", "-m", modelo, "--agent", "plan", p], cwd=cwd or Path(tmp), timeout=300)
    i = achar_tag(out, TAG_TRIAGEM)
    if i < 0:
        raise RuntimeError("opencode: saída fora do formato")
    linhas = [l for l in out[i:].splitlines() if chr(27) not in l and not l.lstrip().startswith("> ")]
    return normalizar_tag(chr(10).join(linhas).strip(), TAG_TRIAGEM)


# ---------- ordem dos modelos do vigia (FRA-532, decisão de 23/10/2026 20h33) ----------
# Local primeiro (Ollama), depois opencode free, Claude só por último. Cada tarefa tem a
# sua ordem nos Ajustes (`watch.ordem_*`, lista ou texto com vírgulas); etapa desconhecida é ignorada.
ORDEM_PADRAO = {
    "needs": ["ollama", "opencode", "claude"],
    "paradas": ["opencode", "claude"],
    "revisao": ["escolhido", "fallback", "opencode-go", "claude"],
}
ETAPAS_VALIDAS = {"needs": {"ollama", "opencode", "claude"}, "paradas": {"opencode", "claude"}}
ETAPAS_APELIDOS: dict = {}
ANALISES_LOG = HOME / "Library" / "Logs" / "TranscentIA" / "vigia-analises.jsonl"
ESFORCOS = ("alto", "medio", "baixo")


class Pular(Exception):
    """Etapa que não se aplica agora (conta no limite): passa para a próxima sem erro."""


def ordem(tarefa: str) -> list[str]:
    v = _cfg(f"watch.ordem_{tarefa}", None)
    if isinstance(v, str):
        v = v.split(",")
    if not isinstance(v, (list, tuple)):
        v = ORDEM_PADRAO[tarefa]
    validas = ETAPAS_VALIDAS.get(tarefa)
    out: list[str] = []
    for e in v:
        e = str(e).strip().lower()
        e = ETAPAS_APELIDOS.get(e, e)
        if e and e not in out and (validas is None or e in validas):
            out.append(e)
    return out or list(ORDEM_PADRAO[tarefa])


def cfg_bool(chave: str, padrao: bool) -> bool:
    v = _cfg(chave, None)
    if v is None:
        return padrao
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "sim", "yes", "on")
    return bool(v)


def registrar_analise(tarefa: str, card: str, quem: str, tentativas: list[dict]) -> None:
    """Quem fez cada análise: linha no painel (log do dispatcher) e no vigia-analises.jsonl."""
    pulos = [f"{t['etapa']}: {t.get('pulou') or t.get('erro')}" for t in tentativas if not t.get("ok")]
    panel(f"{tarefa} {card}: análise feita por {quem}" + (f" (antes: {'; '.join(pulos)[:200]})" if pulos else ""))
    try:
        ANALISES_LOG.parent.mkdir(parents=True, exist_ok=True)
        with ANALISES_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": datetime.now().isoformat(timespec="seconds"), "tarefa": tarefa, "card": card,
                                 "quem": quem, "tentativas": tentativas}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def rodape_analise(quem: str) -> str:
    return f"\n\n_Análise: {quem}._" if quem else ""


def encadear(tarefa: str, card: str, etapas: list[tuple]) -> tuple[str, str, list[dict]]:
    """Tenta cada (nome, fn) na ordem; fn devolve (texto, quem). Pular passa adiante sem contar erro.
    (texto, quem, tentativas) da primeira que responder; RuntimeError se nenhuma responder."""
    tentativas: list[dict] = []
    for nome, fn in etapas:
        t0 = time.time()
        try:
            texto, quem = fn()
        except Pular as exc:
            tentativas.append({"etapa": nome, "pulou": str(exc)[:160]})
            continue
        except Exception as exc:  # noqa: BLE001
            tentativas.append({"etapa": nome, "erro": str(exc)[:160], "s": round(time.time() - t0, 1)})
            log(f"{tarefa} {card}: {nome} falhou ({str(exc)[:120]}); tento a próxima")
            continue
        tentativas.append({"etapa": nome, "ok": True, "quem": quem, "s": round(time.time() - t0, 1)})
        registrar_analise(tarefa, card, quem, tentativas)
        return texto, quem, tentativas
    resumo = "; ".join(f"{t['etapa']}: {t.get('pulou') or t.get('erro')}" for t in tentativas) or "nenhuma etapa"
    raise RuntimeError(f"nenhum modelo respondeu ({resumo})")


def formato_triagem(out: str, decisoes: set[str]) -> str:
    """Texto a partir de [Triagem] com uma linha DECISAO válida; senão, erro (a próxima etapa tenta)."""
    i = achar_tag(out, TAG_TRIAGEM)
    if i < 0:
        raise RuntimeError("saída fora do formato (sem [Triagem])")
    texto = normalizar_tag(out[i:].strip(), TAG_TRIAGEM)
    m = re.search(r"^DECIS[ÃA]O:\s*(\w+)", texto, re.M | re.I)
    if not m or m.group(1).lower() not in decisoes:
        raise RuntimeError("saída fora do formato (sem DECISAO válida)")
    return texto


def claude_livre() -> None:
    if agent_paused():
        raise Pular("conta Claude no limite de uso")


def esforco_do_card(ci: dict) -> str:
    nomes = labels_of(ci)
    for e in ESFORCOS:
        if e in nomes:
            return e
    e = str(_cfg("lanes.effort_default", "medio") or "medio")
    return e if e in ESFORCOS else "medio"


def modelo_opencode_por_peso(ci: dict) -> str:
    """O mesmo modelo que a lane opencode usaria neste card (FRA-521: Ajustes por peso, senão o manifesto)."""
    e = esforco_do_card(ci)
    conf = _cfg("lanes.modelo.opencode", {}) or {}
    m = ""
    if isinstance(conf, dict):
        if conf.get("modo") == "fixo" and conf.get("fixo"):
            m = str(conf["fixo"])
        else:
            m = str(((conf.get("porPeso") or {}).get(e) or {}).get("modelo") or "")
    if not m:
        m = catalogo.modelo_de_effort("opencode", e) or OPENCODE_NEEDS_MODEL
    return m if "/" in m else "opencode/" + m


# --- etiqueta do dono: Ollama -> opencode -> Claude
def needs_ollama(p: str) -> tuple[str, str]:
    modelo = str(_cfg("watch.modelo_needs_ollama", OLLAMA_SHADOW_MODEL) or OLLAMA_SHADOW_MODEL)
    return formato_triagem(local_call(p, modelo), {"remover_needs", "manter"}), "ollama/" + modelo


def needs_opencode(p: str) -> tuple[str, str]:
    return formato_triagem(opencode_call(p), {"remover_needs", "manter"}), OPENCODE_NEEDS_MODEL


def needs_claude(p: str) -> tuple[str, str]:
    claude_livre()
    out = run_agent(p, REPOS["app"]["dir"], "triagem-pendencia", modelo="haiku")
    return formato_triagem(out, {"remover_needs", "manter"}), "claude/haiku"


ETAPAS_NEEDS = {"ollama": needs_ollama, "opencode": needs_opencode, "claude": needs_claude}


def analisar_needs(ci: dict, p: str) -> tuple[str, str]:
    seq = ordem("needs")
    text, quem, tent = encadear("needs", ci["identifier"], [(e, (lambda f=ETAPAS_NEEDS[e]: f(p))) for e in seq])
    venceu = next(t["etapa"] for t in tent if t.get("ok"))
    resto = [e for e in seq[seq.index(venceu) + 1:] if e != "claude"]
    if resto and cfg_bool("watch.sombra_needs", True):
        shadow_needs(ci, p, text, quem, resto[0])
    return text, quem


# --- paradas: opencode -> Claude (a triagem local saiu em 29/10/2026)
def analisar_parada(ci: dict, label: str, st: dict, cid: str, count: int, reason: str) -> tuple[str, str]:
    log_name, tail = lane_log_tail(ci["identifier"])
    dica: list[str] = []
    decisoes = {"voltar_fila", "chamar_dono"}

    def montar() -> str:
        log_tail = ("\n".join(dica) + "\n\n" if dica else "") + tail
        return prompt("triagem-parada").format(
            label=label, card=ci["identifier"], title=ci["title"], state=ci["state"]["name"], count=count,
            reason=reason, desc=(ci.get("description") or "")[:4000], comments=fmt_comments(ci, 4, 1200),
            log_name=log_name, log_tail=log_tail, known_errors=known_errors())

    def opencode() -> tuple[str, str]:
        modelo = modelo_opencode_por_peso(ci)
        return formato_triagem(opencode_call(montar(), modelo, REPOS["app"]["dir"]), decisoes), modelo

    def claude() -> tuple[str, str]:
        claude_livre()
        modelo = modelo_da_analise(st, cid, count)
        out = run_agent(montar(), REPOS["app"]["dir"], f"triagem-{ci['identifier']}", agente=lane_of(ci),
                        modelo=modelo, esforco="medium")
        return formato_triagem(out, decisoes), f"claude/{modelo}"

    fns = {"opencode": opencode, "claude": claude}
    text, quem, _ = encadear("parada", ci["identifier"], [(e, fns[e]) for e in ordem("paradas")])
    return text, quem


def needs_prompt(ci: dict, log_name: str, tail: str) -> str:
    return prompt('triagem-pendencia').format(
        card=ci['identifier'], title=ci['title'], state=ci['state']['name'],
        desc=(ci.get('description') or '')[:4000], comments=fmt_comments(ci, 6, 1200),
        log_name=log_name, log_tail=tail[-3000:], owner_label=OWNER_LABEL)


# Melhoria 2 (21/10/2026): a reconferência da etiqueta do dono é por EVENTO. Só roda quando
# o card muda (descrição, labels, estado ou comentário de pessoa); comentário de bot não
# conta. `watch.reconferir_needs_max_s` é a rede de segurança: reconfere mesmo sem
# mudança depois desse tempo (0 = nunca). Antes: a cada 30 min, 7 cards, ~150 chamadas/dia.
NEEDS_MAX_S = _cfg("watch.reconferir_needs_max_s", 24 * 3600)
BOT_PREFIXOS = tuple(_cfg("watch.prefixos_bots", ["[Triagem]", "[Gestor]", "[Revisor]", "▶️", "⛔", "⏸️",
                                                   "✋", "⏳", "DONE "]))


def needs_impressao(ci: dict) -> str:
    """Impressão digital do que uma pessoa pode ter mudado no card."""
    humanos = [n["id"] for n in ci["comments"]["nodes"] if not n["body"].lstrip().startswith(BOT_PREFIXOS)]
    base = json.dumps([ci.get("description") or "", sorted(labels_of(ci)),
                       (ci.get("state") or {}).get("name"), humanos[-5:]], ensure_ascii=False)
    return hashlib.sha1(base.encode("utf-8")).hexdigest()[:16]


def needs_deve_reconferir(ci: dict, st: dict, agora: float | None = None) -> tuple[bool, str]:
    agora = agora or time.time()
    imp = needs_impressao(ci)
    ant = st["needs_checked"].get(ci["identifier"])
    if isinstance(ant, dict):
        if ant.get("imp") == imp and (not NEEDS_MAX_S or agora - float(ant.get("at", 0)) < NEEDS_MAX_S):
            return False, imp
        return True, imp
    if isinstance(ant, (int, float)) and agora - ant < NEEDS_RECHECK_S:
        return False, imp  # registro antigo (só horário): respeita o intervalo antigo uma última vez
    return True, imp


def recheck_needs(ci: dict, st: dict, diary: list[str]) -> bool:
    deve, imp = needs_deve_reconferir(ci, st)
    if not deve:
        return False
    st['needs_checked'][ci['identifier']] = {"imp": imp, "at": time.time()}
    log_name, tail = lane_log_tail(ci['identifier'])
    p = needs_prompt(ci, log_name, tail)
    try:
        text, quem = analisar_needs(ci, p)
    except Exception as exc:  # noqa: BLE001
        panel(f"{ci['identifier']} {OWNER_LABEL}: reconferência sem resposta ({str(exc)[:140]}); tento quando o card mudar")
        return True
    an = caixa_da_analise(text)
    st.setdefault("caixa_analise", {})
    if decision(text) == "remover_needs":
        st["caixa_analise"].pop(ci["identifier"], None)
    else:
        st["caixa_analise"][ci["identifier"]] = dict(an, imp=imp, quem=quem, at=time.time())
    if decision(text) == "remover_needs":
        remove_label(ci["id"], OWNER_LABEL)
        comment(ci["id"], text + rodape_analise(quem))
        diary.append(f"Triagem · {ci['identifier']} {OWNER_LABEL} removida (pendência não existe mais)")
    elif ci["identifier"] + "|" + OWNER_LABEL not in st["alerts"]:
        comment(ci["id"], text + rodape_analise(quem))
    st["alerts"][ci["identifier"] + "|" + OWNER_LABEL] = datetime.now().isoformat(timespec="seconds")
    return True


# ---------- 4b. caixa do dono (PRD de 29/10) ----------
# O vigia monta `~/.transcentia/lanes/caixa-dono.json`: um item por card com a etiqueta do dono,
# com a pendência, até 3 decisões e a recomendada (da reconferência), para o app mostrar e o
# dono decidir com um clique. Card cancelado com pendência é limpo aqui também.
CAIXA_ARQUIVO = LANES_DIR / "caixa-dono.json"
ACAO_RE = re.compile(r"\[\s*(esforco\s*=\s*(baixo|medio|alto)|lane\s*=\s*([a-z0-9-]+)|cancelar)\s*\]\s*$", re.I)
SEM_DECISAO_RE = re.compile(r"\b(manter|esperar|aguardar)\b", re.I)


def caixa_da_analise(texto: str) -> dict:
    """PENDENCIA / OPCOES / RECOMENDA da reconferência. Linha ausente = campo vazio; opção
    "manter/esperar" ou com ação fora da lista fechada é descartada (não responder já é manter)."""
    def linha(nome: str) -> str:
        m = re.search(rf"^{nome}:\s*(.+)$", texto or "", re.M | re.I)
        return m.group(1).strip() if m else ""
    opcoes = []
    for parte in re.split(r"\s*\|\s*", linha("OPCOES")):
        m = re.match(r"^\(?([A-Da-d])\)\s*(.+)$", parte.strip())
        if not m:
            continue
        texto_op, acao = m.group(2).strip(), None
        a = ACAO_RE.search(texto_op)
        if a:
            texto_op = texto_op[:a.start()].strip()
            if a.group(2):
                acao = {"tipo": "esforco", "valor": a.group(2).lower()}
            elif a.group(3):
                if a.group(3).lower() not in catalogo.lanes_por_prioridade():
                    continue
                acao = {"tipo": "lane", "valor": a.group(3).lower()}
            else:
                acao = {"tipo": "cancelar", "valor": ""}
        elif "[" in texto_op:
            continue  # ação fora da lista fechada
        if not texto_op or (acao is None and SEM_DECISAO_RE.search(texto_op)):
            continue
        opcoes.append({"letra": m.group(1).upper(), "texto": texto_op, "acao": acao})
    rec = linha("RECOMENDA")
    m = re.match(r"^([A-Da-d])\b\s*[—–:-]?\s*(.*)$", rec)
    letra = m.group(1).upper() if m else ""
    opcoes = opcoes[:3]
    return {"pendencia": linha("PENDENCIA"), "opcoes": opcoes,
            "recomenda": letra if any(o["letra"] == letra for o in opcoes) else "",
            "porque": m.group(2).strip() if m else ""}


def _limpar_md(texto: str, n: int = 240) -> str:
    t = re.sub(r"[*`_>#]", "", texto or "")
    t = re.sub(r"\s+", " ", t).strip()
    return t[:n] + ("…" if len(t) > n else "")


def origem_e_motivo(ci: dict) -> tuple[str, str]:
    """Quem chamou o dono e por quê, pelo comentário mais novo que pediu o dono."""
    for n in reversed(ci["comments"]["nodes"]):
        b = n["body"] or ""
        if b.lstrip().startswith("✋"):
            m = re.search(r"Motivo:\*\*\s*(.+?)(?:\n\n|$)", b, re.S)
            return "lane", _limpar_md(m.group(1) if m else b)
        if b.startswith("[Triagem]") and ("preciso de você" in b or "chamar_dono" in b):
            return "triagem", _limpar_md(b.split("\n", 1)[0].replace("[Triagem]", ""))
        if b.startswith("[Gestor]") and OWNER_LABEL in b:
            return "gestor", _limpar_md(b.replace("[Gestor]", ""))
    return "dono", ""


def escrever_caixa(issues: list[dict], st: dict, agora: float | None = None) -> dict:
    """Grava a caixa do dono (atômica) e devolve o que gravou."""
    agora = time.time() if agora is None else agora
    st.setdefault("caixa_analise", {})
    st.setdefault("caixa_desde", {})
    itens, vistos = [], set()
    for ci in issues:
        if OWNER_LABEL not in labels_of(ci):
            continue
        ident = ci["identifier"]
        vistos.add(ident)
        desde = st["caixa_desde"].setdefault(ident, agora)
        an = st["caixa_analise"].get(ident) or {}
        origem, motivo = origem_e_motivo(ci)
        nomes = labels_of(ci)
        pergunta = f"{ident}:{an.get('imp') or int(desde)}"
        itens.append({"card": ident, "issue_id": ci["id"], "titulo": ci.get("title") or "", "url": ci.get("url") or "",
                      "desde": datetime.fromtimestamp(desde).isoformat(timespec="seconds"),
                      "origem": origem, "motivo": motivo, "pergunta_id": pergunta,
                      "pendencia": an.get("pendencia") or "", "opcoes": an.get("opcoes") or [],
                      "recomenda": an.get("recomenda") or "", "porque": an.get("porque") or "",
                      "analise": an.get("quem") or "",
                      "esforco": next((e for e in ESFORCOS if e in nomes), ""),
                      # Outras etiquetas que seguram o card: liberar o dono não o devolve à fila sozinho.
                      "outras_travas": [lb for lb in ("lane:falhou", "lane:parada") if lb in nomes],
                      "lane": next((l for l in catalogo.lanes_por_prioridade() if l in nomes), "")})
    for ident in list(st["caixa_desde"]):
        if ident not in vistos:
            st["caixa_desde"].pop(ident, None)
    ids = IDS_LINEAR or {}
    dados = {"atualizado_em": datetime.fromtimestamp(agora).isoformat(timespec="seconds"),
             "rotulo_dono": OWNER_LABEL,
             "ids": {"dono": LABEL_IDS.get(OWNER_LABEL, ""), "esforco": dict(ids.get("esforco") or {}),
                     "lanes": dict(ids.get("lanes") or {}), "cancelado": st.get("estado_cancelado_id", "")},
             "itens": sorted(itens, key=lambda i: i["desde"]),
             "cancelados": sorted((st.get("cancelados_limpos") or {}).keys())}
    CAIXA_ARQUIVO.parent.mkdir(parents=True, exist_ok=True)
    tmp = CAIXA_ARQUIVO.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(CAIXA_ARQUIVO)
    return dados


def estado_cancelado_id(st: dict) -> str:
    """Id do estado do tipo `canceled` do time do projeto (cache no estado do vigia)."""
    if st.get("estado_cancelado_id"):
        return st["estado_cancelado_id"]
    time_id = linear_ids.time_do_projeto(lambda q, v: linear(q, v), projeto_linear())
    if not time_id:
        return ""
    nos = ((linear("query($id:String!){ team(id:$id){ states{ nodes{ id type } } } }", {"id": time_id})
            .get("team") or {}).get("states") or {}).get("nodes") or []
    st["estado_cancelado_id"] = next((n["id"] for n in nos if n.get("type") == "canceled"), "")
    return st["estado_cancelado_id"]


def cancelados_recentes() -> list[dict]:
    flt = ("project:{ id:{ eq:$p } }, state:{ type:{ eq:\"canceled\" } }, "
           "updatedAt:{ gt:\"-P7D\" }")
    q = f"""query($p:ID!){{ issues(first:50, filter:{{ {flt} }}){{ nodes{{ {ISSUE_FIELDS} }} }} }}"""
    return [em_ordem(n) for n in linear(q, {"p": projeto_linear()})["issues"]["nodes"]]


def limpar_cancelados(cancelados: list[dict], st: dict, diary: list[str]) -> None:
    """Card cancelado com pendência: tira as etiquetas que seguram o card, os blocos de
    Retomada e o contador de paradas, e comenta o que limpou. Worktree e branch ficam."""
    st.setdefault("cancelados_limpos", {})
    for ci in cancelados:
        ident = ci["identifier"]
        presos = [lb for lb in (OWNER_LABEL, "lane:falhou", "lane:parada") if lb in labels_of(ci)]
        nova, tirados = limpar_retomadas(ci.get("description") or "")
        if not presos and not tirados:
            continue
        for lb in presos:
            remove_label(ci["id"], lb)
        if tirados:
            set_description(ci, nova)
        st["stops"].pop(ident, None)
        st.setdefault("caixa_analise", {}).pop(ident, None)
        st.setdefault("caixa_desde", {}).pop(ident, None)
        st["cancelados_limpos"][ident] = datetime.now().isoformat(timespec="seconds")
        partes = ([f"etiquetas {', '.join(f'`{x}`' for x in presos)}"] if presos else []) + \
                 ([f"{len(tirados)} instrução(ões) de retomada"] if tirados else [])
        comment(ci["id"], f"[Gestor] Card cancelado: limpei {' e '.join(partes)}. O worktree e a branch "
                          "ficaram; apagar é decisão do dono.")
        diary.append(f"Gestor · {ident} cancelado → pendências limpas ({', '.join(partes)})")
    corte = time.time() - 7 * 86400
    for ident, quando in list(st["cancelados_limpos"].items()):
        try:
            if datetime.fromisoformat(quando).timestamp() < corte:
                st["cancelados_limpos"].pop(ident, None)
        except ValueError:
            st["cancelados_limpos"].pop(ident, None)


def caixa_do_ciclo(issues: list[dict], st: dict, diary: list[str]) -> None:
    try:
        estado_cancelado_id(st)
        limpar_cancelados(cancelados_recentes(), st, diary)
    except Exception as exc:  # noqa: BLE001 — a limpeza é acessória; a caixa sai mesmo assim
        log(f"cancelados: {exc}")
    escrever_caixa(issues, st)


# ---------- 5. fila ----------
# Decisão escrita na descrição que segura o card fora das lanes (FRA-283, 12/10: o vigia
# promoveu um card cuja descrição dizia «Não vai para lane até ser retomado»).
HOLD_RE = re.compile(r"n[ãa]o vai para (a )?lane", re.I)

# --- FRA-471: freio legível por máquina na promoção Backlog→Todo ---
# E19 promoveu card que não estava pronto (18/10: FRA-407 voltou da lane; FRA-454 alto
# subiu com decisão de produto pendente). Os dois erros estavam escritos no card e
# precisavam de regra mecânica. As regras abaixo leem a convenção que a triagem já
# usa, em vez de caçar palavras soltas — procurar «decisão pendente» em qualquer
# parte do texto pegava quase todo card preparado, porque o cabeçalho da seção
# existe mesmo quando ela diz que não há nada pendente.

# Cabeçalho de seção de decisão, com a linha inteira. A seção só segura o card
# enquanto o próprio cabeçalho não disser que foi resolvida.
CABECALHO_DECISAO_RE = re.compile(r"(?m)^#{1,6}\s*Decis[aã]o\b[^\n]*$")
RESOLVIDO_RE = re.compile(r"RESOLVID", re.I)

# Aceite observável em checkbox. `alto` sem caixa de marcação não é verificável
# por ninguém — nem por quem lê, nem por quem roda.
CHECKLIST_RE = re.compile(r"^\s*[-*]\s*\[[ xX]\]", re.M)

# A linha de aceite, para o caso "a pessoa escreveu o aceite mas não em checkbox".
ACEITE_RE = re.compile(r"^\s*#*\s*(aceite|criterio de aceite|crit[ée]rios de aceite|prova)\b",
                       re.I | re.M)


def decisao_pendente(ci: dict) -> Optional[str]:
    """Trecho do card que segura a promoção, se houver decisão de produto aberta.

    A regra é a convenção do time, não um matcher de palavras: uma seção de
    decisão com cabeçalho `# Decisão …` segura o card até o cabeçalho dizer
    RESOLVIDA. Seção sem cabeçalho resolvido **e** sem texto abaixo é só o
    template, e não segura nada.
    """
    descricao = ci.get("description") or ""
    for m in CABECALHO_DECISAO_RE.finditer(descricao):
        cabecalho = m.group(0)
        if RESOLVIDO_RE.search(cabecalho):
            continue
        # o que vem depois do cabeçalho, até o próximo cabeçalho
        resto = descricao[m.end():]
        proximo = re.search(r"(?m)^#{1,6}\s", resto)
        conteudo = (resto[:proximo.start()] if proximo else resto).strip()
        if conteudo:
            return f"decisão aberta: «{cabecalho.strip('# ').strip()}»"
    return None


def motivo_do_freio(ci: dict) -> Optional[str]:
    """Por que este card não sobe do Backlog para o Todo. None = pode subir.

    Três gates, na ordem em que são explicados no log:
      - seção de decisão de produto ainda aberta;
      - esforço `alto` sem aceite observável em checkbox;
      - aceite observável ausente de todo (qualquer esforço).

    A lista existe para o card não subir por acidente. Ela não diz o que fazer:
    quem escreve o card é que escreve o aceite, e a triagem decide se a decisão é
    dela ou do dono.
    """
    if (aberta := decisao_pendente(ci)) is not None:
        return aberta
    if "[BLOQUEADA]" in (ci.get("title") or "").upper():
        return "título marcado como BLOQUEADA"

    descricao = ci.get("description") or ""
    if not CHECKLIST_RE.search(descricao):
        if not ACEITE_RE.search(descricao):
            return "sem aceite observável (nenhuma linha de aceite nem checkbox)"
        return "sem aceite observável em checkbox"

    return None


def held_by_description(ci: dict) -> bool:
    return bool(HOLD_RE.search(ci.get("description") or ""))


def is_ready(ci: dict) -> bool:
    """Pronto = tem label de lane ou de esforço, sem label de bloqueio, sem BLOQUEADA no título e sem bloqueio aberto."""
    groups = {(n.get("parent") or {}).get("name") for n in ci["labels"]["nodes"]}
    return bool(groups & {"lane", "esforco"}) and not (labels_of(ci) & BLOCKING) and "BLOQUEADA" not in ci["title"].upper() \
        and not open_blockers(ci) and not held_by_description(ci)


def open_blockers(ci: dict) -> list[str]:
    """Cards que bloqueiam este e ainda não estão em Done/Canceled."""
    return [n["issue"]["identifier"] for n in (ci.get("inverseRelations") or {}).get("nodes", [])
            if n.get("type") == "blocks" and n["issue"]["state"]["type"] not in ("completed", "canceled")]


def promotable(issues: list[dict]) -> list[dict]:
    """Backlog que já está pronto: tem esforço ou lane, sem label de bloqueio, sem BLOQUEADA no
    título e com todos os bloqueios em Done. Ordem: prioridade, depois a ordem do Linear.

    Além disso passa pelo freio do FRA-471: card com decisão pendente escrita ou sem
    aceite observável não sobe, por mais que tenha effort e lane."""
    c = [ci for ci in issues if ci["state"]["type"] == "backlog" and is_ready(ci) and not open_blockers(ci)]
    return sorted(c, key=lambda c: (c.get("priority") or 5, c.get("sortOrder") or 0))


def travados_pelo_freio(issues: list[dict]) -> list[tuple[dict, str]]:
    """Cards que `promotable` deixaria de fora por causa do freio do FRA-471."""
    out = []
    for ci in issues:
        if ci["state"]["type"] != "backlog" or not is_ready(ci) or open_blockers(ci):
            continue
        if motivo := motivo_do_freio(ci):
            out.append((ci, motivo))
    return out


def weight(ci: dict) -> tuple:
    """Peso da task (maior = mergeia primeiro): esforço, depois prioridade do Linear, depois o
    que começou antes. Regra de 11/10: no conflito, o mais pesado vai primeiro e o mais
    leve rebaseia, porque rebasear o leve custa menos."""
    eff = max((EFFORT_WEIGHT.get(n["name"], 0) for n in ci["labels"]["nodes"]
               if (n.get("parent") or {}).get("name") == "esforco"), default=EFFORT_WEIGHT["medio"])
    prio = ci.get("priority") or 0
    prio_rank = 5 - prio if prio > 0 else 0          # Urgent(1)=4 … Low(4)=1, sem prioridade=0
    started = ci.get("startedAt") or "9999"
    return (eff, prio_rank, tuple(-ord(c) for c in started))  # mais antigo pesa mais no empate


# Arquivos da infraestrutura das lanes citados nas instruções dos cards; não são código do app.
LANE_FILES = {"result.json", "settings.json", "settings.local.json", ".mcp.json", "mcp.json"}


def card_files(ci: dict) -> set[str]:
    """Nomes de arquivo citados na descrição do card (comparação por nome, sem pasta). Ignora a
    infraestrutura das lanes (.lane/, result.json…): em 11/10 o result.json citado nas instruções
    gerou conflito falso FRA-162 × FRA-319."""
    out = set()
    for m in FILE_RE.finditer(ci.get("description") or ""):
        path = m.group(1)
        name = path.rsplit("/", 1)[-1]
        if path.startswith(".lane") or "/.lane/" in path or name in LANE_FILES:
            continue
        out.add(name)
    return out


def conflicts(ci: dict, files: set[str], others: list[tuple[dict, set[str]]]) -> list[tuple[dict, set[str]]]:
    """Outros cards ativos que tocam algum dos mesmos arquivos."""
    return [(o, files & of) for o, of in others if o["identifier"] != ci["identifier"] and files & of]


def heavier_conflict(ci: dict, files: set[str], others: list[tuple[dict, set[str]]]) -> tuple | None:
    """O card mais pesado que conflita com este e deve mergear antes, ou None."""
    heavy = [(o, f) for o, f in conflicts(ci, files, others) if weight(o) > weight(ci)]
    return max(heavy, key=lambda x: weight(x[0])) if heavy else None


def busy_lanes() -> set[str]:
    return {p.stem.split("-", 1)[1] for p in LANES_DIR.glob("lane-*.json")
            if p.stem.split("-", 1)[1] in AGENTES_NOMES}


def lanes_ativas() -> set[str]:
    """Lanes ativas: ligadas no `enabled` E executáveis — a mesma regra do
    `lane_runnable` do dispatcher: só as implementadas no manifesto."""
    try:
        # Mesmo formato que o dispatcher e o notch gravam: nomes separados por espaço
        # ou por linha (`split()` cobre os dois). Com `splitlines()` a linha
        # «claude opencode opencode-go» virava um nome só e o vigia via 0 lanes ativas.
        enabled = {l.strip() for l in (LANES_DIR / "enabled").read_text().split() if l.strip()}
    except OSError:
        return set()
    return enabled & set(IMPLEMENTED_LANES)


def keep_lanes_busy(issues: list[dict], st: dict, diary: list[str]) -> None:
    queue = [c for c in issues if c["state"]["id"] == STATE_IN_PROGRESS_ID and is_ready(c)]
    ativas = lanes_ativas()
    running = busy_lanes() & ativas
    running_cards = {json.loads((LANES_DIR / f"lane-{l}.json").read_text()).get("card") for l in running}
    waiting = [c for c in queue if c["identifier"] not in running_cards]
    todo = sorted([c for c in issues if c["state"]["name"] == "Todo" and is_ready(c)],
                  key=lambda c: (c.get("priority") or 5, c.get("sortOrder") or 0))
    # Teto por lane ativa: MAX_PER_LANE (1 RUN + (N-1) WAIT) por lane.
    SLOTS = MAX_PER_LANE * len(ativas)
    free = max(0, SLOTS - len(running) - len(waiting))
    READY_TARGET = max(_cfg("watch.prontos_no_todo", 2), SLOTS)
    # Contramedida 11/10: fila vazia por 11 h porque ninguém promovia do Backlog. Card com
    # esforço e bloqueios resolvidos sobe sozinho para o Todo, até a meta de prontos.
    # O freio só decide o que sobe; o card que ele segura aparece no log com o motivo
    # (FRA-471), para o card não sumir sem explicação.
    for ci, motivo in travados_pelo_freio(issues):
        panel(f"freio: {ci['identifier']} não sobe do Backlog — {motivo}")
    for nxt in [c for c in promotable(issues) if not motivo_do_freio(c)][:max(0, READY_TARGET - len(todo))]:
        set_state(nxt["id"], STATE_TODO_ID)
        effort = ", ".join(sorted(n["name"] for n in nxt["labels"]["nodes"]
                                  if (n.get("parent") or {}).get("name") in ("esforco", "lane")))
        comment(nxt["id"], f"[Triagem] Promovido do Backlog para o Todo: pronto ({effort}) e sem bloqueio aberto. "
                           "Fila abaixo da meta de cards prontos.")
        panel(f"fila: {nxt['identifier']} promovido do Backlog para o Todo ({effort})")
        active = [(c, card_files(c)) for c in issues
                  if c["state"]["name"] in ("In Progress", "In Review", "Todo") and c["id"] != nxt["id"]]
        for other, shared in conflicts(nxt, card_files(nxt), active):
            first, second = (other, nxt) if weight(other) > weight(nxt) else (nxt, other)
            note = (f"[Gestor] Conflito previsto entre {nxt['identifier']} e {other['identifier']} "
                    f"({', '.join(sorted(shared)[:6])}). Ordem de merge pelo peso: **{first['identifier']} "
                    f"primeiro**; {second['identifier']} espera e rebaseia na main depois. As duas rodam em paralelo.")
            comment(nxt["id"], note)
            panel(f"conflito previsto {nxt['identifier']} × {other['identifier']}: merge {first['identifier']} "
                  f"primeiro, {second['identifier']} rebaseia")
        diary.append(f"Triagem · {nxt['identifier']} Backlog → Todo (pronto, sem bloqueio)")
        todo.append(nxt)
    free = SLOTS - len(running) - len(waiting)  # 1 rodando + 1 esperando por lane ativa (20/10)
    pulled = False
    if free > 0 and todo:
        nxt = todo.pop(0)
        set_state(nxt["id"], STATE_IN_PROGRESS_ID)
        comment(nxt["id"], "[Triagem] Lane ociosa: card puxado do Todo para a fila. O dispatcher escolhe a lane pela "
                           "medida (lanepct-auto, menor %).")
        diary.append(f"Triagem · {nxt['identifier']} Todo → fila (lane ociosa)")
        panel(f"fila: {nxt['identifier']} puxado do Todo para In Progress (lane ociosa)")
        pulled = True
    if free > 0 and not todo and not pulled and time.time() - st.get("painel_fila", 0) > EMPTY_QUEUE_PANEL_S:
        st["painel_fila"] = time.time()
        panel(f"fila vazia: {free} lane(s) ociosa(s) e nenhum card pronto no Todo nem no Backlog "
              "(precisa de esforço e bloqueios em Done); precisa de card pronto")
    if TRIAGEM_PEDIDOS_CARD and len(todo) < READY_TARGET and time.time() - st.get("pedido_triagem", 0) > TRIAGEM_PEDIDOS_S:
        target = issue(TRIAGEM_PEDIDOS_CARD)
        if target:
            comment(target["id"], f"[Gestor] triagem, só há {len(todo)} card(s) pronto(s) no Todo; a regra é manter "
                                  f"{READY_TARGET}. Preciso de mais um card pronto (lane ou esforço, aceite claro, "
                                  "erros conhecidos colados).")
            st["pedido_triagem"] = time.time()
            diary.append(f"Gestor · pediu card pronto à triagem ({len(todo)} no Todo)")


# ---------- 6. revisão ----------
# Melhoria 3 (21/10/2026): quem revisa sai dos Settings (`revisores.pr.*`), não do
# código, e pode ser QUALQUER agente do catálogo que tenha o bloco `revisao` no manifesto
# (agents.d/*.json: comando só leitura, flags de modelo e esforço, entrada e saída).
# O vigia só decide QUANDO revisar (PR sem [Revisor] no head) e publica. Com
# `independente`, o revisor nunca é do mesmo fornecedor da lane que escreveu o PR: vale o
# `reserva` (ou, em `auto`, a conta com mais folga abaixo de `folga_pct`, só entre os
# manifestos com `auto: true`). Papel `segunda_opiniao`: o AJUSTES dele bloqueia, mas o
# APROVADO precisa ser confirmado por um revisor que aprova sozinho.
# Reserva quando o revisor escolhido falha (FRA-532: era o Claude; agora o opencode free, e o Claude
# fica por último na `watch.ordem_revisao`). Configurável em `watch.adaptador_fallback`.
ADAPTADOR_FALLBACK = str(_cfg("watch.adaptador_fallback", "opencode") or "opencode")
MEDIDA_CACHE = LANES_DIR / "medida-cache.json"
REVISOR_VEREDITOS = HOME / "Library" / "Logs" / "TranscentIA" / "revisor-vereditos.jsonl"
REVISOR_PADRAO = {"lane": "claude", "independente": True, "reserva": "auto", "folga_pct": 85, "teto_usd": 4}
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def manifesto_revisao(agente: str) -> dict | None:
    """Bloco `revisao` do manifesto do agente (agents.d), ou None se ele não revisa."""
    return (catalogo.catalogo().get(agente) or {}).get("revisao")


def revisores_catalogo() -> tuple:
    """Quem pode revisar: todo agente do catálogo com `revisao` (adicionar = 1 JSON)."""
    return catalogo.revisores()


def conf_revisor() -> dict:
    """Ajustes do revisor (`revisores.pr.*`) com os padrões do código."""
    c = _cfg("revisores.pr", {}) or {}
    out = dict(REVISOR_PADRAO)
    out.update({k: v for k, v in c.items() if not isinstance(v, dict) and v not in (None, "")})
    return out


def papel(agente: str, conf: dict) -> str:
    m = manifesto_revisao(agente) or {}
    return "segunda_opiniao" if m.get("papel") == "segunda_opiniao" else "sozinho"


def fornecedor(agente: str) -> str:
    d = catalogo.catalogo().get(agente) or {}
    return (d.get("uso") or {}).get("tipo") or agente


def medidas_contas() -> dict:
    try:
        return dict(json.loads(MEDIDA_CACHE.read_text()).get("m") or {})
    except (OSError, ValueError, AttributeError):
        return {}


def cli_instalado(cli: str) -> str | None:
    """CLI no PATH que o vigia usa para rodar os agentes (PATH_ENV), não no do processo.

    Sob o launchd do app o PATH do processo é só /usr/bin:/bin:/usr/sbin:/sbin: com
    `shutil.which` puro nenhum CLI aparecia e toda revisão dava «nenhum revisor
    disponível» (PRs #7 a #10, 28–29/10), embora o `sh` rodasse os CLIs com PATH_ENV."""
    return shutil.which(cli, path=PATH_ENV)


_ESFORCO_ORDEM = {"baixo": 1, "medio": 2, "alto": 3,
                  "low": 1, "medium": 2, "high": 3, "xhigh": 4}


def esforco_agente(agente: str) -> str:
    """Esforço padrão do agente no manifesto (vazio se não houver)."""
    m = manifesto_revisao(agente) or {}
    return m.get("esforco_padrao") or ""


def esforco_maior_igual(e1: str, e2: str) -> bool:
    """True se e1 >= e2 na escala baixo < medio < alto."""
    return _ESFORCO_ORDEM.get(e1, 0) >= _ESFORCO_ORDEM.get(e2, 0)


def escolher_revisor(autor: str, conf: dict | None = None, medidas: dict | None = None,
                     instalado=None, so_sozinho: bool = False) -> tuple[str, str]:
    """(agente revisor, observação).

    Candidatos: os agentes do catálogo com `revisao` e CLI instalado. O preferido dos
    Ajustes vale se servir; senão a reserva (`auto` = só quem tem `auto: true` no
    manifesto, pela menor % abaixo de `folga_pct`). `so_sozinho` filtra quem pode
    aprovar sozinho (confirmação de uma segunda opinião). Sem nenhum, o preferido (ou o
    primeiro que aprova sozinho) com a observação "mesmo fornecedor"."""
    conf = conf or conf_revisor()
    instalado = instalado or cli_instalado
    nomes = [a for a in revisores_catalogo() if instalado(AGENTES.get(a, {}).get("cli") or a)
             and privacidade_ok(a, str((conf.get(a) or {}).get("modelo") or ""))[0]]
    if so_sozinho:
        nomes = [a for a in nomes if papel(a, conf) == "sozinho"]
    pref = conf.get("lane")
    indep = bool(conf.get("independente", True)) and autor in AGENTES

    def serve(a: str) -> bool:
        return a in nomes and (not indep or fornecedor(a) != fornecedor(autor))
    if pref and serve(pref):
        return pref, ""
    medidas = medidas_contas() if medidas is None else medidas
    folga = float(conf.get("folga_pct", 85))

    def pct(a: str):
        v = medidas.get(fornecedor(a)) or medidas.get(a)
        try:
            return float(v[0]) if v and v[0] is not None else None
        except (TypeError, ValueError, IndexError):
            return None
    reserva = conf.get("reserva") or "auto"
    if reserva == "auto":
        cands = [a for a in nomes if serve(a) and (manifesto_revisao(a) or {}).get("auto", True)]
    else:
        cands = [a for a in nomes if a == reserva and serve(a)]

    # Revisor reserva: tenta mesmo esforço da lane revisora, depois esforço >= padrão.
    esf_revisora = esforco_agente(pref) if pref else ""
    mesmo_esforco = [a for a in cands if esforco_agente(a) == esf_revisora]
    if mesmo_esforco:
        cands = mesmo_esforco
    elif esf_revisora:
        acima = [a for a in cands if esforco_maior_igual(esforco_agente(a), esf_revisora)]
        if acima:
            cands = acima

    livres = [a for a in cands if pct(a) is None or pct(a) < folga]
    livres.sort(key=lambda a: (50.0 if pct(a) is None else pct(a), a))
    if livres:
        return livres[0], ""
    if pref in nomes:
        return pref, "mesmo fornecedor"
    return (nomes[0] if nomes else ADAPTADOR_FALLBACK), "mesmo fornecedor"


def comando_revisao(agente: str, conf: dict, ctx: dict) -> tuple[list[str], str | None]:
    """(argv, texto para o stdin) a partir do manifesto. `ctx` traz prompt, saida, settings, mcp."""
    m = manifesto_revisao(agente)
    if not m:
        raise RuntimeError(f"{agente} não tem `revisao` no manifesto")
    c = conf.get(agente) or {}
    modelo = str(c.get("modelo") or "")
    esforco = str(c.get("esforco") or "")
    vals = {**ctx, "modelo": modelo, "esforco": esforco, "teto": str(conf.get("teto_usd") or CLAUDE_BUDGET_USD)}
    flags: list[str] = []
    if modelo and modelo not in ("padrao", "padrão", "default"):
        flags += list(m["flag_modelo"])
    if esforco and m["flag_esforco"]:
        flags += list(m["flag_esforco"])
    argv: list[str] = []
    for parte in m["comando"]:
        if parte == "{flags}":
            argv += [f.format(**vals) for f in flags]
        elif parte == "{prompt}":
            argv.append(ctx["prompt"])
        else:
            argv.append(parte.format(**vals))
    return argv, (ctx["prompt"] if m["entrada"] == "stdin" else None)


def limpar_saida(out: str) -> str:
    """Tira cor de terminal e o que vem antes do `[Revisor]` (cabeçalho e rodapé do CLI)."""
    out = ANSI_RE.sub("", out)
    i = achar_tag(out, TAG_REVISOR)
    return normalizar_tag((out[i:] if i >= 0 else out).strip(), TAG_REVISOR)


def run_revisor(agente: str, texto: str, cwd: Path, tag: str, conf: dict) -> str:
    """Revisão só leitura em qualquer agente com `revisao` no manifesto."""
    RUN_LOG_DIR.mkdir(parents=True, exist_ok=True)
    m = manifesto_revisao(agente) or {}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(READ_ONLY_SETTINGS, fh)
        settings = fh.name
    fd, saida = tempfile.mkstemp(suffix=".md")
    os.close(fd)
    mcp = STATE_DIR / "empty-mcp.json"
    if not mcp.exists():
        mcp.write_text('{"mcpServers":{}}')
    argv, entrada = comando_revisao(agente, conf, {"prompt": texto, "saida": saida, "settings": settings,
                                                    "mcp": str(mcp)})
    started = time.time()
    try:
        out = sh(argv, cwd=cwd, timeout=CLAUDE_TIMEOUT_S, inp=entrada)
        if m.get("saida") == "arquivo":
            out = Path(saida).read_text(encoding="utf-8", errors="replace")
    except Exception as exc:  # noqa: BLE001
        if agente == "claude":
            note_agent_failure(exc)
        raise
    finally:
        os.unlink(settings)
        os.unlink(saida)
    (RUN_LOG_DIR / f"{tag}-{datetime.now():%Y%m%d-%H%M%S}.md").write_text(out)
    c = conf.get(agente) or {}
    log(f"agente {tag} [{agente}/{c.get('modelo') or 'padrao'}/{c.get('esforco') or '-'}]: "
        f"{int(time.time() - started)} s, {len(out)} chars")
    return limpar_saida(out)


def adaptador_fallback() -> str:
    return str(_cfg("watch.adaptador_fallback", ADAPTADOR_FALLBACK) or ADAPTADOR_FALLBACK)


def ordem_revisao(revisor: str, conf: dict, so_sozinho: bool = False, instalado=None) -> list[str]:
    """Quem tenta revisar, em ordem: `escolhido` (o revisor de hoje), `fallback` (watch.adaptador_fallback)
    e os agentes listados em `watch.ordem_revisao`. Só quem revisa, tem o CLI e passa na privacidade."""
    instalado = instalado or cli_instalado  # na hora da chamada (o teste troca o shutil.which)
    fb = adaptador_fallback()
    out: list[str] = []
    for e in ordem("revisao"):
        a = revisor if e == "escolhido" else fb if e == "fallback" else e
        if a and a not in out:
            out.append(a)
    if revisor not in out:
        out.insert(0, revisor)
    validos = set(revisores_catalogo())
    out = [a for a in out if a in validos and instalado(AGENTES.get(a, {}).get("cli") or a)
           and privacidade_ok(a, str((conf.get(a) or {}).get("modelo") or ""))[0]]
    if so_sozinho:
        out = [a for a in out if papel(a, conf) == "sozinho"]
    return out


def revisar(texto: str, cwd: Path, tag: str, revisor: str, conf: dict, so_sozinho: bool = False) -> tuple[str, str]:
    """Roda a revisão na ordem de `ordem_revisao`; Claude no limite é pulado. (texto, quem revisou)."""
    erros: list[str] = []
    for a in ordem_revisao(revisor, conf, so_sozinho):
        if a == "claude" and agent_paused():
            erros.append("claude: conta no limite")
            continue
        try:
            out = run_revisor(a, texto, cwd, tag, conf)
        except Exception as exc:  # noqa: BLE001
            log(f"{tag}: revisor {a} falhou ({str(exc)[:160]}); tento o próximo")
            erros.append(f"{a}: {str(exc)[:80]}")
            continue
        if a != revisor:
            panel(f"{tag}: revisão feita por {a} (o escolhido, {revisor}, não respondeu)")
        return out, a
    raise RuntimeError("nenhum revisor respondeu (" + ("; ".join(erros) or "nenhum disponível") + ")")


def veredito_de(text: str) -> str:
    primeira = text.splitlines()[0] if text else ""
    return "APROVADO" if "REVISOR: APROVADO" in primeira else "AJUSTES"


def rodape_revisor(revisor: str, conf: dict, extra: str = "") -> str:
    c = conf.get(revisor) or {}
    return (f"\n\n_Revisor: {revisor} ({c.get('modelo') or 'padrao'})"
            f"{' · ' + extra if extra else ''}._")


def registrar_veredito(reg: dict) -> None:
    try:
        REVISOR_VEREDITOS.parent.mkdir(parents=True, exist_ok=True)
        with REVISOR_VEREDITOS.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": datetime.now().isoformat(timespec="seconds"), **reg}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def quem_confirma(lane: str, conf: dict) -> list[str]:
    """Quem aprova sozinho e pode rodar agora (Claude em pausa de limite não conta). Sem IA nem rede."""
    conf_rev, _ = escolher_revisor(lane, conf, so_sozinho=True)
    return [a for a in ordem_revisao(conf_rev, conf, so_sozinho=True)
            if not (a == "claude" and agent_paused())]


def avisar_espera_confirmacao(pr: dict, st: dict, guardada: bool) -> None:
    """Uma linha no painel por head enquanto a revisão espera quem confirma."""
    avisados = st.setdefault("espera_confirmacao", {})
    head = pr["headRefOid"]
    if head in avisados:
        return
    avisados[head] = time.time()
    ate, mensal = ler_pausa()
    quando = (f"sem cota mensal; nova tentativa às {datetime.fromtimestamp(ate):%H:%M}" if mensal
              else f"sem cota até {datetime.fromtimestamp(ate):%H:%M}") if ate else "sem cota"
    if guardada:
        panel(f"PR #{pr['number']}: segunda opinião APROVADO guardada; esperando a confirmação do Claude ({quando})")
    else:
        panel(f"PR #{pr['number']}: revisão espera o Claude ({quando}); a segunda opinião roda quando ele voltar")


def limpar_revisoes_fechadas(st: dict, heads_abertos: set[str]) -> None:
    """Segundas opiniões e avisos de espera só valem para heads de PR aberto."""
    for chave in ("segundas_opinioes", "espera_confirmacao", "sem_revisao"):
        d = st.get(chave) or {}
        for h in [h for h in d if h.split("|")[0] not in heads_abertos]:
            del d[h]


def avisar_pr_sem_card(pr: dict, st: dict, agora: float | None = None) -> None:
    """PR sem card não entra no merge automático (merge_ready anda pelos cards): depois de
    REVIEW_WAIT_MAX_S aberto, avisa o dono no painel uma vez por head."""
    if card_of(pr["title"], pr["headRefName"]):
        return
    agora = time.time() if agora is None else agora
    head = pr["headRefOid"]
    sem = st.setdefault("sem_revisao", {})
    desde = sem.setdefault(head, agora)
    if agora - desde < REVIEW_WAIT_MAX_S or sem.get(head + "|avisado"):
        return
    sem[head + "|avisado"] = agora
    horas = int((agora - desde) // 3600)
    if st["reviewed"].get(head) == "APROVADO":
        panel(f"PR #{pr['number']} sem card está APROVADO há {horas} h; o vigia não mergeia PR sem card: mergeie à mão")
    else:
        panel(f"PR #{pr['number']} sem card está sem APROVADO há {horas} h; revise ou mergeie à mão")


def review_pr(key: str, repo: dict, pr: dict, st: dict, diary: list[str]) -> bool | None:
    """Revisa o head do PR. False = não rodou IA (esperando quem confirma)."""
    rdir = repo["dir"]
    sh(["git", "fetch", "--quiet", "origin"], cwd=rdir, timeout=180)
    card = card_of(pr["title"], pr["headRefName"])
    ci = issue(card) if card else None
    stat = sh(["git", "diff", "--stat", f"origin/main...origin/{pr['headRefName']}"], cwd=rdir)[-4000:]
    lane = lane_of(ci)
    conf = conf_revisor()
    revisor, obs = escolher_revisor(lane, conf)

    def montar(rev: str) -> str:
        mesmo = lane in AGENTES and fornecedor(rev) == fornecedor(lane)
        return prompt("revisor").format(
            number=pr["number"], repo_slug=repo["slug"], title=pr["title"], branch=pr["headRefName"],
            sha=pr["headRefOid"], sha7=pr["headRefOid"][:7], merge_state=pr.get("mergeStateStatus"),
            card=card or "(nenhum no título/branch)", card_desc=(ci or {}).get("description", "")[:6000] or "(sem card)",
            card_comments=fmt_comments(ci), stat=stat, protected=", ".join(protected()), lane=lane,
            known_errors=known_errors(),
            same_model=(" O revisor é do mesmo fornecedor da lane que escreveu o PR: diga no topo que é "
                        "pré-review (mesmo fornecedor).") if mesmo else "",
        )
    tag = f"revisor-{key}-{pr['number']}"
    head = pr["headRefOid"]
    guardadas = st.setdefault("segundas_opinioes", {})
    if papel(revisor, conf) == "segunda_opiniao" and not quem_confirma(lane, conf):
        # Ninguém pode confirmar agora (Claude sem cota): nem chama a segunda opinião, que seria jogada fora.
        avisar_espera_confirmacao(pr, st, guardada=head in guardadas)
        return False
    if head in guardadas and papel(revisor, conf) == "segunda_opiniao":
        # Head já aprovado na segunda opinião: vai direto para a confirmação, sem revisar de novo.
        text, revisor = TAG_REVISOR + " REVISOR: APROVADO", guardadas[head]["revisor"]
    else:
        text, revisor = revisar(montar(revisor), rdir, tag, revisor, conf)
        if text.startswith(TAG_REVISOR) and papel(revisor, conf) == "segunda_opiniao" and veredito_de(text) == "APROVADO":
            guardadas[head] = {"revisor": revisor, "quando": time.time(), "pr": pr["number"]}
            save_state(st)  # uma falha da confirmação não apaga a segunda opinião
            registrar_veredito({"repo": key, "pr": pr["number"], "head": head[:7], "card": card,
                                "autor": lane, "revisor": revisor, "obs": "segunda opinião, não publicada",
                                "veredito": "APROVADO"})
    extra = obs
    if text.startswith(TAG_REVISOR) and papel(revisor, conf) == "segunda_opiniao" and veredito_de(text) == "APROVADO":
        # Segunda opinião só bloqueia; aprovar exige um revisor que aprova sozinho.
        primeiro = revisor
        conf_rev, obs2 = escolher_revisor(lane, conf, so_sozinho=True)
        text, revisor = revisar(montar(conf_rev), rdir, tag + "-confirma", conf_rev, conf, so_sozinho=True)
        extra = f"confirmou a aprovação de {primeiro}" + (f"; {obs2}" if obs2 else "")
    if not text.startswith(TAG_REVISOR):
        sha = pr["headRefOid"]
        if not format_failure(st, sha):
            log(f"PR #{pr['number']}: saída fora do formato; tento de novo no próximo ciclo")
            panel(f"PR #{pr['number']} revisão saiu fora do formato; nova tentativa no próximo ciclo")
            return
        log(f"PR #{pr['number']}: saída fora do formato de novo; desisto e aviso")
        st["reviewed"][sha] = "formato-invalido"
        msg = (f"PR #{pr['number']} head {sha[:7]}: revisão saiu fora do formato "
               f"{FORMAT_RETRIES + 1}x; PR parado sem revisão, precisa do gestor")
        panel(msg)
        diary.append(f"Revisor · {card or ''} {msg}")
        if ci:
            comment(ci["id"], f"[Gestor] ⚠️ {msg}. Saída bruta em ~/Library/Logs/TranscentIA/bots/revisor-{key}-{pr['number']}-*.md.")
        return
    if papel(revisor, conf) == "segunda_opiniao":
        extra = "segunda opinião" + (f"; {extra}" if extra else "")
    text = text + rodape_revisor(revisor, conf, extra)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
        fh.write(text)
        body = fh.name
    try:
        sh(["gh", "pr", "comment", str(pr["number"]), "--body-file", body], cwd=rdir)
    finally:
        os.unlink(body)
    if ci:
        comment(ci["id"], text)
    verdict = veredito_de(text)
    st["reviewed"][pr["headRefOid"]] = verdict
    registrar_veredito({"repo": key, "pr": pr["number"], "head": pr["headRefOid"][:7], "card": card,
                        "autor": lane, "revisor": revisor, "obs": extra, "veredito": verdict})
    diary.append(f"Revisor · {card or ''} PR #{pr['number']} head `{pr['headRefOid'][:7]}` → {verdict}")
    log(f"PR #{pr['number']} {verdict} (revisor {revisor}, autor {lane}{', ' + extra if extra else ''})")


# ---------- worktrees fora da pasta de branches (regra do dono, 29/10/2026) ----------
# `<repo>` é a main alinhada com o GitHub; qualquer outro checkout é branch e fica em
# `<worktrees>` do projeto (~/Developer/tuttidash-branches). O vigia só AVISA: não apaga nada.
WORKTREE_AVISO_S = 24 * 3600


def ler_worktrees(porcelain: str) -> list[dict]:
    """`git worktree list --porcelain` → [{path, head, branch}] (branch vazio = detached)."""
    out: list[dict] = []
    atual: dict = {}
    for linha in porcelain.splitlines() + [""]:
        if not linha.strip():
            if atual.get("path"):
                out.append({"path": atual["path"], "head": atual.get("head", ""),
                            "branch": atual.get("branch", "")})
            atual = {}
            continue
        chave, _, valor = linha.partition(" ")
        if chave == "worktree":
            atual["path"] = valor
        elif chave == "HEAD":
            atual["head"] = valor
        elif chave == "branch":
            atual["branch"] = valor.removeprefix("refs/heads/")
    return out


def _dentro(caminho: Path, raiz: Path) -> bool:
    try:
        caminho.resolve().relative_to(raiz.resolve())
        return True
    except (ValueError, OSError):
        return False


def worktrees_fora(lista: list[dict], repo: Path, branches: Path) -> list[dict]:
    """Os que não são o checkout principal nem ficam dentro da pasta de branches."""
    fora = []
    for wt in lista:
        p = Path(wt["path"])
        if p.resolve() == repo.resolve():
            continue
        if str(branches) and _dentro(p, branches):
            continue
        fora.append(wt)
    return fora


def avisar_worktrees_fora(st: dict, diary: list[str], agora: float | None = None) -> None:
    """Uma linha no painel por worktree fora do lugar, no máximo uma vez por dia cada."""
    p = projeto()
    if not str(p.repo) or not Path(p.repo).exists():
        return
    agora = time.time() if agora is None else agora
    lista = ler_worktrees(sh(["git", "worktree", "list", "--porcelain"], cwd=Path(p.repo), check=False))
    avisados = st.setdefault("worktrees_avisados", {})
    vistos = set()
    for wt in worktrees_fora(lista, Path(p.repo), Path(p.worktrees)):
        vistos.add(wt["path"])
        if wt["path"] in avisados and agora - float(avisados[wt["path"]]) < WORKTREE_AVISO_S:
            continue
        avisados[wt["path"]] = agora
        qual = wt["branch"] or f"detached {wt['head'][:7]}"
        panel(f"worktree fora da pasta de branches: {wt['path']} ({qual}); o lugar é {p.worktrees}")
    for velho in [k for k in avisados if k not in vistos]:
        del avisados[velho]


def step(name: str, fn, *args) -> None:
    try:
        fn(*args)
    except Exception as exc:  # noqa: BLE001
        log(f"{name} falhou: {exc}")


def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    projetos.recarregar()   # cadastro lido uma vez por ciclo
    if not projetos.configurado():
        return 0  # sem projeto cadastrado: nada a vigiar
    if (STATE_DIR / "PAUSE").exists():
        return 0  # espelho: o Grok Bot está trabalhando
    lock = open(STATE_DIR / "watch.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    global REPOS
    REPOS = _repos()
    garantir_ids()
    first_run = not STATE_FILE.exists()
    st = load_state()
    diary: list[str] = []
    runs = 0
    try:
        if first_run:
            for key, repo in REPOS.items():
                raw = sh(["gh", "pr", "list", "--state", "merged", "--limit", "10", "--json", "number"], cwd=repo["dir"])
                for pr in json.loads(raw):
                    st["done_moves"][f"{key}#{pr['number']}"] = "historico"
        step("instalação", check_install, st, diary)
        step("merge", merge_ready, st, diary)
        step("conflito", rebase_dirty, st, diary)
        step("instalar main", install_main_if_pending, st, diary)
        step("mergeado e não Done", merged_not_done, st, diary)
        issues = project_issues()
        step("retomadas", expirar_retomadas, issues, st, diary)
        for ci in issues:
            if runs >= MAX_RUNS_PER_TICK:
                break
            names = labels_of(ci)
            try:
                for label in STOP_LABELS:
                    if label in names and OWNER_LABEL not in names:
                        runs += handle_stops(ci, label, st, diary)
                        break
                else:
                    if OWNER_LABEL in names:
                        runs += recheck_needs(ci, st, diary)
            except Exception as exc:  # noqa: BLE001
                log(f"{ci['identifier']}: {exc}")
        atuais = project_issues()  # uma leitura para a caixa do dono e para a fila
        step("caixa do dono", caixa_do_ciclo, atuais, st, diary)
        step("worktrees", avisar_worktrees_fora, st, diary)
        step("fila", keep_lanes_busy, atuais, st, diary)
        heads_abertos: set[str] = set()
        for key, repo in REPOS.items():
            prs_abertos = open_prs(repo)
            heads_abertos |= {p["headRefOid"] for p in prs_abertos}
            for pr in prs_abertos:
                avisar_pr_sem_card(pr, st)
            if runs >= MAX_RUNS_PER_TICK:
                continue
            for pr in prs_abertos:
                if runs >= MAX_RUNS_PER_TICK:
                    break
                if not revisao_pode_tentar(st, pr["headRefOid"]):
                    continue
                if st["reviewed"].get(pr["headRefOid"]) is None and revisor_ja_revisou(repo, pr):
                    st["reviewed"][pr["headRefOid"]] = "ja-tinha"
                    continue
                runs += 1
                try:
                    if review_pr(key, repo, pr, st, diary) is False:
                        runs -= 1  # só esperou quem confirma: não gastou IA, não conta no ciclo
                except Exception as exc:  # noqa: BLE001
                    log(f"revisão PR #{pr['number']} falhou: {exc}")
                    if agent_paused():
                        continue  # limite da conta: não marca, revisa quando a conta voltar
                    st["reviewed"][pr["headRefOid"]] = f"erro {datetime.now():%m-%d %H:%M}"
                    st.setdefault("erros_revisao", {})[pr["headRefOid"]] = time.time()
        limpar_revisoes_fechadas(st, heads_abertos)
    except Exception as exc:  # noqa: BLE001
        log(f"tick falhou: {exc}")
    finally:
        save_state(st)
        diary_append(diary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
