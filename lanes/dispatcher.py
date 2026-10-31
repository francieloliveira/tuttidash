#!/usr/bin/env python3
"""Dispatcher das lanes automáticas do TranscentIA.

Roda a cada 60 s via launchd (com.transcentia.lanes.dispatcher).

  --dry-run  só registra o que assumiria (padrão do plist até a titular ligar)
  --real     assume cards nas lanes habilitadas em ~/.transcentia/lanes/enabled

Divisão de trabalho (E3):
  dispatcher  lê o card, cria o worktree, abre a lane no tmux e, ao final,
              faz push, abre o PR, comenta DONE <sha> e move para In Review
  agente      edita, testa, faz commit LOCAL e grava .lane/result.json.
              Não fala com Linear nem GitHub.

Fonte da verdade: este repo (`tuttidash`), `lanes/`.
Cópia instalada: ~/.transcentia/lanes/ (tools/install.sh neste repo). O repo
do app é só o que a lane edita — qual é, e a prova de cada um, sai do cadastro
`projetos` da config (`gasto_lanes/projetos.py`), lido a cada ciclo.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lanes_window  # noqa: E402  janela única das lanes

# Catálogo de agentes: `catalogo.py` lê os manifests em `agents.d/` (mesmos que o
# Swift). O dispatcher é instalado sozinho em ~/.transcentia/lanes, então o
# `catalogo.py` vai junto (tools/install.sh copia). Adicionar um agente novo =
# 1 arquivo JSON em `agents.d/`, sem tocar neste arquivo.
_AQUI = Path(__file__).resolve().parent
for _cand in (_AQUI, _AQUI.parent / "gasto_lanes"):   # 1º: instalado; 2º: dev no repo
    if (_cand / "catalogo.py").is_file():
        sys.path.insert(0, str(_cand))
        break
try:
    import catalogo  # noqa: E402
    import fila  # noqa: E402
    import linear_ids  # noqa: E402
    import projetos  # noqa: E402
except ModuleNotFoundError as _falta:  # pragma: no cover - só sem instalar
    sys.exit(f"{_falta.name} não encontrado ao lado do dispatcher.py — "
             "rode tools/install.sh para instalar o catálogo de agentes e projetos")
try:
    import privacidade  # noqa: E402  privacidade por modelo do OpenCode (21/10/2026)
except ModuleNotFoundError:  # pragma: no cover - sem instalar: lanes do OpenCode ficam seguras
    privacidade = None

# --- Workspace Linear ---------------------------------------------------------
# Nenhum id no código (FRA-565): vêm da config (`linear.*`), do cache
# `~/.transcentia/lanes/linear-ids.json` ou da API, pelo nome (`garantir_ids()`, no
# começo de cada ciclo real). Sem id, a etiqueta ou o estado é pulado, com aviso no log.
LINEAR_API = "https://api.linear.app/graphql"
KEYCHAIN_SERVICE = "linear-transcentia-lanes"
STATE_IN_PROGRESS_ID = STATE_IN_REVIEW_ID = STATE_TODO_ID = ""
LABEL_DONO_ID = LABEL_LANE_FALHOU_ID = LABEL_LANE_PARADA_ID = ""
# Catálogo de agentes (fonte única: `agents.d/*.json`, via `catalogo.py`).
# labels de lane (FRA-269), aplicados quando o dispatcher escolhe a lane pela medida.
LABEL_LANE_IDS: dict = {}

# Lanes na ordem de rotação do dispatcher (`prioridade` no manifesto).
LANES = catalogo.lanes_por_prioridade()
# Lanes com execução real. Habilitar uma lane fora desta lista não faz nada
# (o dispatcher ignora e registra no log). codex promovido após teste vivo
# (codex exec --json validado em 2026-10-15).
IMPLEMENTED_LANES = catalogo.lanes_implementadas()
LABEL_GROUP_LANE = "lane"
LABEL_GROUP_EFFORT = "esforco"
LABEL_EFFORT_IDS: dict = {}
# Quem decide quando a lane não resolve sozinha (`linear.owner_label`, FRA-565).
OWNER_LABEL = "needs:dono"
BLOCKING_LABELS = {OWNER_LABEL, linear_ids.FALHOU, linear_ids.PARADA}
# FRA-269: card sem lane mas com esforço = "o dispatcher escolhe a lane pela medida".
AUTO_LANE = "auto"
EFFORT_DEFAULT = "medio"

# Nível de esforço -> flags por agente, do campo `modelos.<nivel>.flags` de cada
# manifesto (tabela aprovada em 2026-10-03; as notas de por-lane estão em `nota`).
EFFORT_FLAGS = {
    lane: {nivel: list(m.get("flags", ()))
           for nivel, m in (catalogo.catalogo().get(lane, {}).get("modelos") or {}).items()}
    for lane in LANES
}
# Teto de gasto por execução (USD). Estourou -> lane:falhou com o motivo.
BUDGET_USD = {"baixo": 3, "medio": 8, "alto": 20}
# Grok não tem teto em dólar: o limite é de turnos.
GROK_MAX_TURNS = {"baixo": 30, "medio": 60, "alto": 100}
# dsh (DeepSeek Harness): peso -> reasoningEffort do modelo. O CLI não recebe
# `--effort`; o dispatcher grava um patch de perfil por execução (deepseek_patch).
DSH_ESFORCO = {"baixo": "low", "medio": "high", "alto": "max"}
DSH_ESFORCOS_VALIDOS = {"off", "minimal", "low", "medium", "high", "xhigh", "max"}
# Teto de cards por lane ativa: 1 RUN + (MAX_PER_LANE - 1) WAIT.
# Deve bater com tools/cfg DEFAULTS["watch"]["max_tarefas_por_lane"].
MAX_PER_LANE = 2
# Ferramentas embutidas do Grok que a lane pode usar (--tools). Fora da lista ficam
# agendador, subagentes e web. use_tool/search_tool/workflow/ask_user_question não
# saem com --tools, mas qualquer chamada a eles cancela a sessão sem executar
# (testado em 2026-10-03, grok 1.0.41).
GROK_TOOLS = ["run_terminal_command", "read_file", "search_replace", "write", "list_dir",
              "grep", "todo_write", "get_command_or_subagent_output",
              "kill_command_or_subagent", "monitor"]
LANE_TIMEOUT_MIN = 90
# FRA-443 — freios acumulados por card. Decisão do dono em 28/10/2026.
# D1 tentativas, em qualquer lane. D2 gasto acumulado em US$. D3 tempo acumulado em min.
# D4: comentário do revisor com MARCA_AJUSTE_OLLIE conta 1 tentativa.
# D5: só estes freios; o verificador do aceite é o card seguinte.
# D6: estouro aplica FREIO_LABEL e o comentário traz tentativas, gasto e tempo.
# Nenhum número desta tabela foi escolhido pela lane. Ideia de freio por card;
# o código é novo e não foi copiado de outro projeto.
TENTATIVAS_MAX = {"baixo": 3, "medio": 3, "alto": 5}
ORCAMENTO_ACUMULADO_USD = {"baixo": 8, "medio": 20, "alto": 40}
TEMPO_ACUMULADO_MIN = {"baixo": 120, "medio": 270, "alto": 360}
FREIO_LABEL = linear_ids.FALHOU
MARCA_AJUSTE_OLLIE = "REVISOR: AJUSTES"

# Contramedida de 11/10 (FRA-306 cortado pelo limite de 5 h no turno 107, lanes 11 h paradas).
# Folga mínima na conta para assumir um card, pela janela que mais aperta (lanepct).
# Um card `alto` do Claude gastou ~60% da janela de 5 h sozinho.
HEADROOM_PCT = {"baixo": 90, "medio": 80, "alto": 60}
# Folga por janela (18/10): o teto acima foi calibrado na janela curta de 5 h. Quando a
# conta só informa uma janela longa (>= 1 dia: "30 dias", "semana", "mês"), o mesmo % é
# menos crítico — nenhum card consome 60% de um mês. Sem afrouxar, uma quota mensal a 79%
# travava os cards `alto` (caso FRA-448/FRA-451 em 18/10). Curta = rígida; longa = afrouxada.
HEADROOM_PCT_LONGA = {"baixo": 95, "medio": 90, "alto": 85}
JANELA_LONGA_RE = re.compile(r"\d+\s*dias?\b|semana|m[êe]s\b|mensal", re.I)
# Sem horário de volta no log do agente: tenta de novo depois disto.
LIMIT_FALLBACK_S = 3600
# 429 ou limite de uso sem horário de volta, em qualquer lane (FRA-515). A API não diz
# quando volta. Espera 1 h na 1ª vez e dobra a cada ocorrência seguida, até 8 h.
# 6 h sem novo limite zera a contagem. O 429 citado em texto de código não conta:
# só evento `error`, como no recuo do OpenCode (#58).
LIMIT_429_BASE_S = 1 * 3600
LIMIT_429_MAX_S = 8 * 3600
LIMIT_429_RESET_S = 6 * 3600
# Medida reaproveitada entre ciclos (o lanepct-auto chama a API das contas).
MEASURE_CACHE_S = 60
# Buraco entre dois ciclos (launchd roda a cada 60 s) acima disto = Mac em repouso/desligado.
SLEEP_GAP_S = 5 * 60
# FRA-269: a prova (safe_xcodebuild.sh test) roda fora do terminal do agente, pelo
# dispatcher, em segundo plano. Teto próprio: um build não incremental passa de 30 min.
PROOF_TIMEOUT_MIN = 150
PROOF_DEFAULT_SUITES = ["TranscentIATests"]
# Log do agente sem saída nova por este tempo: a lane parou em silêncio (FRA-515).
LOG_PARADO_S = 10 * 60
# Teto antigo, só da opencode (2). O freio que vale agora é TENTATIVAS_MAX (FRA-443).
# O número continua no arquivo `opencode-strikes.json` (`max`) para o que já estava gravado.
STRIKES_OPENCODE = 2
# FRA-269: medida de uso das contas (mesma fonte do app de notch). Renova o token
# vencido sozinho (claude -p / grok -p) e mede de novo; sai 3 se continuar vencido.
LANEPCT_AUTO = Path.home() / ".transcentia" / "tools" / "lanepct-auto"

# --- Projeto em que o dispatcher trabalha -----------------------------------
# Vem do cadastro `projetos` da config do TuttiDash (`gasto_lanes/projetos.py`).
# Sem a chave na config não há projeto e o ciclo só registra isso (FRA-565).
# `projeto()` é lido a cada ciclo: mudar a config muda o projeto na hora.
def _cfg(chave, padrao):
    """Lê ~/.transcentia/tools/cfg (FRA-295); sem cfg ou com erro, devolve o padrão."""
    try:
        import runpy
        v = runpy.run_path(str(Path.home() / ".transcentia/tools/cfg"))["get"](chave, padrao)
        return type(padrao)(v) if padrao is not None and not isinstance(padrao, (list, set, dict)) else v
    except Exception:  # noqa: BLE001
        return padrao


def _owner_label() -> str:
    return str(_cfg("linear.owner_label", linear_ids.DONO_PADRAO) or linear_ids.DONO_PADRAO).strip()


def _aplicar_ids(ids: dict, dono: Optional[str] = None) -> None:
    """Põe os ids do Linear nas constantes que o resto do dispatcher usa."""
    global STATE_IN_PROGRESS_ID, STATE_IN_REVIEW_ID, STATE_TODO_ID
    global LABEL_DONO_ID, LABEL_LANE_FALHOU_ID, LABEL_LANE_PARADA_ID
    global LABEL_LANE_IDS, LABEL_EFFORT_IDS, OWNER_LABEL, BLOCKING_LABELS
    OWNER_LABEL = dono or _owner_label()
    BLOCKING_LABELS = {OWNER_LABEL, linear_ids.FALHOU, linear_ids.PARADA}
    estados, labels = ids.get("estados") or {}, ids.get("labels") or {}
    STATE_TODO_ID = estados.get("todo", "")
    STATE_IN_PROGRESS_ID = estados.get("in_progress", "")
    STATE_IN_REVIEW_ID = estados.get("in_review", "")
    LABEL_DONO_ID = labels.get(OWNER_LABEL, "")
    LABEL_LANE_FALHOU_ID = labels.get(linear_ids.FALHOU, "")
    LABEL_LANE_PARADA_ID = labels.get(linear_ids.PARADA, "")
    LABEL_LANE_IDS = dict(ids.get("lanes") or {})
    LABEL_EFFORT_IDS = dict(ids.get("esforco") or {})


def garantir_ids() -> None:
    """Ciclo real: busca pelo nome, na API do Linear, os ids que faltam (uma vez; fica no cache)."""
    try:
        ids = linear_ids.garantir(_cfg, lambda q, v: linear(q, v), dono=_owner_label(), lanes=LANES,
                                  project_id=projeto().id, log=log)
    except Exception as exc:  # noqa: BLE001 — sem token ou sem rede: segue com o que tinha
        log(f"linear: ids não conferidos ({exc})")
        return
    _aplicar_ids(ids)


def label_ok(label_id: str, nome: str) -> bool:
    """Etiqueta sem id no Linear: avisa e não manda a mutação (que falharia)."""
    if label_id:
        return True
    log(f"linear: etiqueta «{nome}» sem id; crie no Linear ou ponha em linear.labels.nomes")
    return False


def aplicar_label(issue_id: str, label_id: str, nome: str) -> bool:
    if not label_ok(label_id, nome):
        return False
    linear(MUT_LABEL, {"id": issue_id, "label": label_id})
    return True


def mudar_estado(issue_id: str, state_id: str) -> bool:
    if not state_id:
        log("linear: estado sem id; confira linear.state_*_id ou os nomes dos estados do time")
        return False
    linear(MUT_STATE, {"id": issue_id, "state": state_id})
    return True


_aplicar_ids(linear_ids.carregar(_cfg, project_id=projetos.padrao().id))  # sem rede: config e cache


def projeto():
    """Projeto em que este ciclo trabalha. A config é lida uma vez por ciclo —
    quem chama `recarregar()` no começo dele."""
    return projetos.padrao()


def projeto_repo() -> Path:
    return projeto().repo


def projeto_worktrees() -> Path:
    return projeto().worktrees


# Caminhos que nenhuma lane pode tocar, relativos ao repo do projeto. Checado de
# novo antes do push (defesa em profundidade além das permissões do agente).
# Sai do campo `protegidos` do projeto no cadastro.
def protected_globs() -> list:
    return projeto().protegidos


# Nome antigo, mantido para as permissões do agente e para quem já importava.
PROTECTED_GLOBS = projetos.PROTEGIDOS_PADRAO

HOME = Path.home()
STATE_DIR = HOME / ".transcentia" / "lanes"
LANES_COMMAND = HOME / ".transcentia" / "tools" / "lanes.command"
APP_PID = STATE_DIR / "app.pid"


def app_aberta() -> bool:
    """O app TuttiDash é o dono do ciclo: sem o PID vivo, o dispatcher não trabalha."""
    try:
        pid = int(APP_PID.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return False
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
PAUSE_FILE = STATE_DIR / "PAUSE"
ENABLED_FILE = STATE_DIR / "enabled"
HEARTBEAT_FILE = STATE_DIR / "heartbeat.json"
MODE_FILE = STATE_DIR / "last_mode"
LAST_DECISION_FILE = STATE_DIR / "last_decision.sha"
LOG_DIR = HOME / "Library" / "Logs" / "TranscentIA"
LOG_FILE = LOG_DIR / "lanes-dispatcher.log"
LANE_LOG_DIR = LOG_DIR / "lanes"
TOOL_PATH = f"{HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

QUERY_CANDIDATES = """
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
"""
QUERY_ISSUE = """
query Card($id: String!) {
  issue(id: $id) { id identifier title description url branchName state { id name } }
}
"""
MUT_COMMENT = """
mutation($id: String!, $body: String!) {
  commentCreate(input: { issueId: $id, body: $body }) { success }
}
"""
MUT_STATE = """
mutation($id: String!, $state: String!) {
  issueUpdate(id: $id, input: { stateId: $state }) { success }
}
"""
MUT_LABEL = """
mutation($id: String!, $label: String!) {
  issueAddLabel(id: $id, labelId: $label) { success }
}
"""
MUT_REMOVE_LABEL = """
mutation($id: String!, $label: String!) {
  issueRemoveLabel(id: $id, labelId: $label) { success }
}
"""


# --- Utilitários -----------------------------------------------------------
def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(msg: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{now()} {msg}"
    with LOG_FILE.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    if sys.stdout.isatty():
        print(line)


def sh(args: list[str], cwd: Optional[Path] = None, check: bool = True, timeout: int = 120) -> str:
    env = dict(os.environ, PATH=TOOL_PATH, GIT_TERMINAL_PROMPT="0")
    out = subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env, timeout=timeout)
    if check and out.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:3])}… falhou ({out.returncode}): {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def linear_key() -> str:
    # Lida a cada uso; nunca gravada em arquivo nem em log.
    out = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(f"chave '{KEYCHAIN_SERVICE}' não encontrada no Keychain")
    return out.stdout.strip()


def linear(query: str, variables: dict) -> dict:
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        LINEAR_API, data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": linear_key()},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        # O Linear devolve 400 com o motivo no corpo (ex.: campo inexistente).
        try:
            detail = json.loads(exc.read())["errors"][0]["message"]
        except Exception:  # noqa: BLE001
            detail = str(exc)
        raise RuntimeError(f"Linear HTTP {exc.code}: {detail}") from None
    if data.get("errors"):
        raise RuntimeError(f"Linear: {data['errors'][0].get('message', data['errors'])}")
    return data["data"]


# --- Regras de elegibilidade (determinísticas) ------------------------------
def classify(issue: dict) -> tuple[Optional[str], str, Optional[str]]:
    """Devolve (lane, esforço, motivo_de_exclusão). motivo=None => elegível."""
    labels = issue["labels"]["nodes"]
    lane_opts = [l["name"] for l in labels if (l.get("parent") or {}).get("name") == LABEL_GROUP_LANE]
    effort_opts = [l["name"] for l in labels if (l.get("parent") or {}).get("name") == LABEL_GROUP_EFFORT]
    flat = {l["name"] for l in labels if not l.get("parent")}

    lane = lane_opts[0] if len(lane_opts) == 1 else None
    if len(effort_opts) == 1:
        effort = effort_opts[0]
        issue["_esforco_automatico"] = False
    else:
        # FRA-516: classificação automática de esforço (regra + Ollama)
        effort, _motivo = classificar_esforco(issue.get("title", ""), issue.get("description", "") or "")
        issue["_esforco_automatico"] = True
        issue["_esforco_motivo"] = _motivo

    if not lane_opts:
        # FRA-269: esforço sem lane = a pessoa delegou e o dispatcher escolhe a lane.
        # Sem nenhum dos dois, o card é trabalho manual e fica fora.
        if not effort_opts:
            return None, effort, "sem label de lane"
        lane = AUTO_LANE
    if len(lane_opts) > 1 or (lane not in LANES and lane != AUTO_LANE):
        return None, effort, f"lane inválida: {lane_opts}"
    if "BLOQUEADA" in issue["title"].upper():
        return lane, effort, "título contém BLOQUEADA"
    hit = BLOCKING_LABELS & flat
    if hit:
        return lane, effort, f"label {sorted(hit)[0]}"
    open_blockers = [
        r["issue"]["identifier"]
        for r in issue["inverseRelations"]["nodes"]
        if r["type"] == "blocks" and r["issue"]["state"]["type"] != "completed"
    ]
    if open_blockers:
        return lane, effort, f"blockedBy aberto: {', '.join(open_blockers)}"
    bot = moved_in_by_integration(issue)
    if bot:
        return lane, effort, f"entrou em In Progress por integração ({bot}), não por pessoa"
    return lane, effort, None


def moved_in_by_integration(issue: dict) -> Optional[str]:
    """O gatilho da lane é humano. Se a última entrada em In Progress foi feita
    por uma integração (GitHub, automação do Linear...), devolve o nome dela.

    Pessoa = actor preenchido e sem botActor (a Triagem usa o token do dono,
    então conta como pessoa). Sem histórico de entrada: não há prova de
    integração, o card segue elegível."""
    nodes = (issue.get("history") or {}).get("nodes") or []
    entries = [h for h in nodes if (h.get("toState") or {}).get("id") == STATE_IN_PROGRESS_ID]
    if not entries:
        return None
    last = max(entries, key=lambda h: h.get("createdAt") or "")
    if last.get("botActor") or not last.get("actor"):
        return (last.get("botActor") or {}).get("name") or "integração"
    return None


def lane_runnable(lane: str) -> bool:
    return lane in IMPLEMENTED_LANES


def effective_lanes(enabled: set) -> tuple:
    """(lanes que assumem de verdade, lanes habilitadas mas sem execução real)."""
    return ({l for l in enabled if lane_runnable(l)},
            sorted(l for l in enabled if not lane_runnable(l)))


def lane_permissions() -> dict:
    """Mesmas regras para as duas lanes (claude-settings.json)."""
    return json.loads((STATE_DIR / "claude-settings.json").read_text())["permissions"]


def sort_key(issue: dict) -> tuple:
    # Linear: 1=Urgent 2=High 3=Medium 4=Low 0=sem prioridade (vai para o fim).
    p = issue.get("priority") or 0
    return (p if p > 0 else 5, issue.get("startedAt") or issue.get("createdAt") or "")


def touched_protected(paths: list[str]) -> list[str]:
    """Caminhos que a lane tocou e que o projeto declara protegidos."""
    globs = protected_globs()
    return [p for p in paths if any(fnmatch.fnmatch(p, g) for g in globs)]


# --- Modelo customizado por lane (do config do TuttiDash) -------------------
# O app grava em ~/Library/Application Support/TuttiDash/config.json (FRA-523);
# a pasta antiga Lanekeeper fica como reserva.
# O dispatcher lê esse caminho primeiro, com fallback para ~/.transcentia/tools/config.json.
CONFIG_FILES = [
    Path.home() / "Library/Application Support/TuttiDash/config.json",
    Path.home() / "Library/Application Support/Lanekeeper/config.json",
    Path.home() / ".transcentia/tools/config.json",
]
# Última lista boa de modelos, a mesma que os Ajustes gravam (FRA-521).
CACHE_MODELOS = catalogo.CACHE_MODELOS


def ler_modelo_lane(lane: str) -> Optional[str]:
    """Modelo fixo da lane, ou None no automático (e quando o fixo saiu da lista).

    String antiga e `{"modo": "fixo"}` devolvem o modelo. O automático por peso não cabe
    numa string: `modelo_da_lane` lê `porPeso`."""
    bruto = catalogo.bruto_modelo(lane, CONFIG_FILES)
    if bruto is None:
        return None
    cfg = catalogo.normalizar_config_modelo(bruto)
    if cfg["modo"] != "fixo" or not cfg["fixo"]:
        return None
    if catalogo.modelo_sumiu(cfg["fixo"], lane, catalogo.ler_cache_modelos(CACHE_MODELOS)):
        return None
    return cfg["fixo"]


_ler_modelo_lane_impl = ler_modelo_lane


def _cache_modelos() -> dict:
    return catalogo.ler_cache_modelos(CACHE_MODELOS)


def _resolucao_modelo(lane: str, effort: str) -> dict:
    return catalogo.resolver_modelo(lane, effort, catalogo.bruto_modelo(lane, CONFIG_FILES), _cache_modelos())


def modelo_da_lane(lane: str, effort: str) -> str:
    """Modelo que a lane usa neste esforço, no formato do CLI (`opencode/x`, `opencode-go/x`).

    Fixo (e a string antiga) vale para todos os pesos. Automático usa `porPeso` e, no
    que faltar, o manifesto. Sem o prefixo do provedor, ganha o do manifesto.
    Teste que troca `ler_modelo_lane` continua no caminho antigo (None = manifesto)."""
    if ler_modelo_lane is not _ler_modelo_lane_impl:
        flags = EFFORT_FLAGS.get(lane, {}).get(effort) or []
        m = ler_modelo_lane(lane) or (flags[-1] if flags else "")
        padrao = catalogo.modelo_de_effort(lane, effort)
        if m and "/" not in m and "/" in padrao:
            m = padrao.split("/", 1)[0] + "/" + m
        return m
    return _resolucao_modelo(lane, effort)["modelo"]


def flags_da_lane(lane: str, effort: str) -> list[str]:
    """Flags do CLI neste peso, já com o modelo e o esforço da config."""
    if ler_modelo_lane is not _ler_modelo_lane_impl:
        m = ler_modelo_lane(lane)
        if not m:
            return list(EFFORT_FLAGS.get(lane, {}).get(effort) or [])
        return catalogo.montar_flags(lane, effort, catalogo.com_prefixo_modelo(lane, m), "", False)
    return list(_resolucao_modelo(lane, effort)["flags"])


def aviso_modelo(lane: str, effort: str) -> str:
    """«modelo fixo» ou o texto de modelo que saiu da lista. Vazio no automático quieto."""
    if ler_modelo_lane is not _ler_modelo_lane_impl:
        return "modelo fixo" if ler_modelo_lane(lane) else ""
    return _resolucao_modelo(lane, effort)["aviso"]


def filtrar_modelos(lane: str, linhas, pode=None) -> list:
    """Mesmo filtro do catálogo: prefixo da lane e, no OpenCode, privacidade."""
    return catalogo.filtrar_modelos(lane, linhas, pode)


def reconciliar_modelos_sumidos() -> list[str]:
    """Grava modo automático nas lanes cujo modelo escolhido saiu da última lista boa."""
    cache = _cache_modelos()
    if not cache:
        return []
    mudou: list[str] = []
    for cfg_path in CONFIG_FILES:
        if not cfg_path.exists():
            continue
        try:
            dados = json.loads(cfg_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError):
            continue
        if not isinstance(dados, dict):
            continue
        modelo_map = dados.get("lanes") if isinstance(dados.get("lanes"), dict) else {}
        modelo_map = modelo_map.get("modelo") if isinstance(modelo_map.get("modelo"), dict) else {}
        chaves = set(modelo_map)
        chaves.update(k.split(".")[-1] for k in dados if isinstance(k, str) and k.startswith("lanes.modelo."))
        alterou = False
        for lane in sorted(chaves):
            bruto = dados.get(f"lanes.modelo.{lane}") or modelo_map.get(lane)
            novo, _aviso = catalogo.ajuste_sumido(lane, bruto, cache)
            if novo is None:
                continue
            dados.pop(f"lanes.modelo.{lane}", None)
            lanes_cfg = dados.get("lanes")
            if not isinstance(lanes_cfg, dict):
                lanes_cfg = {}
                dados["lanes"] = lanes_cfg
            mm = lanes_cfg.get("modelo")
            if not isinstance(mm, dict):
                mm = {}
                lanes_cfg["modelo"] = mm
            mm[lane] = catalogo.config_para_gravar(novo)
            alterou = True
            if lane not in mudou:
                mudou.append(lane)
        if alterou:
            cfg_path.write_text(json.dumps(dados, ensure_ascii=False, indent=2), encoding="utf-8")
        break
    return mudou


def atualizar_listas_modelos() -> None:
    """Renova a lista das lanes sem lista boa do dia e devolve ao automático o que sumiu.
    Lane que falhou é tentada de novo depois de uma hora (FRA-564)."""
    try:
        pendentes = catalogo.lanes_para_atualizar(LANES, CACHE_MODELOS)
        if not pendentes:
            return
        cache = _cache_modelos()
        agora = dt.datetime.now().isoformat(timespec="seconds")
        for lane in pendentes:
            cache = catalogo.atualizar_cache_lista(cache, lane, catalogo.buscar_modelos(lane), agora)
            # PRD 29/10: esforços aceitos que a ferramenta informa (Claude: --help; Codex: por modelo).
            cache = catalogo.atualizar_cache_esforcos(cache, lane, catalogo.buscar_esforcos(lane))
        catalogo.gravar_cache_modelos(CACHE_MODELOS, cache)
        for lane in reconciliar_modelos_sumidos():
            log(f"modelo da lane {lane} saiu da lista; voltei ao automático")
    except Exception as exc:  # noqa: BLE001 — a lista nunca derruba o ciclo
        log(f"lista de modelos: erro ao atualizar ({exc}); vale a última lista boa")


def privacy_block(lane: str, effort: str) -> Optional[str]:
    """Motivo para não mandar código a esta lane (modelo sem garantia de privacidade), ou None.
    Só vale para agentes com `privacidade` no manifesto (hoje, os do OpenCode)."""
    if not (catalogo.catalogo().get(lane) or {}).get("privacidade"):
        return None
    if privacidade is None:
        return "módulo de privacidade ausente (rode tools/install.sh)"
    ok, motivo = privacidade.pode_receber_codigo(modelo_da_lane(lane, effort))
    return None if ok else motivo


def atualizar_privacidade() -> None:
    """Confere a documentação de privacidade do OpenCode uma vez por `privacidade.intervalo_h`.
    Fica no dispatcher (roda sempre) e não no vigia (que pausa no modo Grok Bot)."""
    if privacidade is None:
        return
    try:
        if not privacidade.precisa_atualizar(privacidade.ler_estado()):
            return
        est, avisos = privacidade.atualizar()
        for a in avisos:
            log(a)
        resumo = "; ".join(f"{d}: {v.get('caminho')} ({len(v.get('modelos') or {})} modelos)"
                           for d, v in (est.get("docs") or {}).items() if v.get("ok"))
        log(f"privacidade OpenCode conferida: {resumo or 'nenhuma fonte lida'}")
    except Exception as exc:  # noqa: BLE001 — nunca derruba o ciclo
        log(f"privacidade OpenCode: erro ao conferir ({exc}); vale a última conferência")


def deepseek_esforco(effort: str) -> str:
    """reasoningEffort do dsh: o da config, se válido; senão o padrão do peso."""
    bruto = str(_resolucao_modelo("deepseek", effort).get("esforco") or "").strip()
    if bruto in DSH_ESFORCOS_VALIDOS:
        return bruto
    return DSH_ESFORCO.get(effort, "high")


def deepseek_patch(effort: str) -> str:
    """Patch do perfil headless do dsh para esta execução.

    O perfil de fábrica monta o provedor oficial (chave de API) e desliga a conta.
    Com a conta do app, é preciso religar authorization/credentials/account e
    apontar o modelo padrão para `deepseek-account`. Com DEEPSEEK_API_KEY no
    ambiente, basta fixar o modelo no provedor oficial.
    """
    modelo = modelo_da_lane("deepseek", effort) or "deepseek-flash"
    esforco = deepseek_esforco(effort)
    com_api_key = bool((os.environ.get("DEEPSEEK_API_KEY") or "").strip())
    linhas: list[str] = []
    if not com_api_key:
        linhas += [
            "- id: authorization",
            '  name: "@deepseek-ai/dsh-authorization"',
            "  disabled: false",
            "- id: deepseek-account",
            '  name: "@deepseek-ai/dsh-deepseek-account-platform"',
            "  disabled: false",
            "  config:",
            "    desktopPlatform: darwin",
            "- id: credentials",
            '  name: "@deepseek-ai/dsh-credentials-local"',
            "  disabled: false",
        ]
    linhas += [
        "- id: agent-default-model",
        '  name: "@deepseek-ai/dsh-agent-default-model"',
        "  config:",
        f"    provider: {'deepseek-official' if com_api_key else 'deepseek-account'}",
        f"    model: {modelo}",
        f"    reasoningEffort: {esforco}",
    ]
    return "\n".join(linhas) + "\n"


def deepseek_resumo(effort: str) -> str:
    """Modelo e esforço no comentário do claim (o dsh não recebe flags de modelo)."""
    return f"{modelo_da_lane('deepseek', effort) or 'deepseek-flash'} · reasoning {deepseek_esforco(effort)}"


def agent_command(lane: str, effort: str) -> list[str]:
    """Comando headless do agente (claude, grok e opencode são executadas de verdade)."""
    if lane == "claude":
        return [
            "claude", "-p",  # prompt chega pelo stdin (run_lane.sh < .lane/prompt.md)
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "acceptEdits",
            "--settings", str(STATE_DIR / "claude-settings.json"),
            "--strict-mcp-config", "--mcp-config", str(STATE_DIR / "lane-mcp.json"),
            "--max-budget-usd", str(BUDGET_USD[effort]),
            *flags_da_lane("claude", effort),
        ]
    if lane == "grok":
        perms = lane_permissions()
        cmd = [
            "grok", "--prompt-file", ".lane/prompt.md",
            "--output-format", "streaming-messages-json",
            "--permission-mode", "acceptEdits",   # vence o always-approve global (testado)
            "--tools", ",".join(GROK_TOOLS), "--disable-web-search",
            "--max-turns", str(GROK_MAX_TURNS[effort]),
            *flags_da_lane("grok", effort),
        ]
        for rule in perms["allow"]:
            if not rule.startswith("mcp__"):      # nenhum MCP liberado na lane grok
                cmd += ["--allow", rule]
        for rule in perms["deny"] + ["WebFetch", "WebSearch", "mcp__linear", "mcp__obsidian-rest",
                                     "mcp__obsidian-filesystem", "mcp__outsystems-docs"]:
            cmd += ["--deny", rule]
        return cmd
    if lane == "opencode":
        # FRA-374: `run` lê eventos JSON
        # linha a linha (--format json). O prompt vai como argumento (o `run` não
        # documenta leitura do stdin). `texto_do_agente` põe "$(cat .lane/prompt.md)"
        # entre aspas: o bash expande, e espaços e aspas do arquivo chegam num
        # argumento só. O run_lane.sh continua redirecionando o stdin por
        # compatibilidade com as outras lanes.
        # Modelo pode ser customizado pelo usuário no config do TuttiDash
        # (chave lanes.modelo.opencode).
        modelo = modelo_da_lane("opencode", effort)
        return [
            "opencode", "run", "--format", "json",
            "-m", modelo,
        ]
    if lane == "opencode-go":
        # opencode-go: modelos Go com ZDR (teto mensal por modelo).
        # Modelo customizado pelo usuário no config (chave lanes.modelo.opencode-go).
        modelo = modelo_da_lane("opencode-go", effort)
        return [
            "opencode", "run", "--format", "json",
            "-m", modelo,
        ]
    if lane == "codex":
        # FRA-374: `exec --json` emite eventos JSONL; o prompt vai
        # como argumento posicional (ver claim). Padrão = modelo default do CLI.
        # Sem teto de gasto no CLI; monitorado pelo ledger depois.
        return [
            "codex", "exec", "--json",
            *flags_da_lane("codex", effort),
        ]
    if lane == "deepseek":
        # dsh (DeepSeek Harness) headless: uma sessão nova, a resposta final no
        # stdout e sai. O prompt vai como argumento posicional (texto_do_agente).
        # O patch escrito no claim liga a conta e fixa modelo/reasoningEffort.
        # Sem `--max-budget-usd` e sem stream JSON: o ledger não mede esta lane.
        return ["dsh", "--profile", "headless", "--patch", ".lane/deepseek.yml"]
    # cursor não tem CLI headless público para execução de lanes; fica como
    # placeholder até existir comando equivalente.
    raise NotImplementedError(f"lane {lane} não tem comando de agente")


def texto_do_agente(lane: str, effort: str) -> str:
    """Linha que o `run_lane.sh` executa no worktree.

    Na opencode e no dsh o prompt entra entre aspas. Sem aspas, um espaço ou uma
    aspa do card partia o argumento e o CLI lia lixo (ou uma flag)."""
    agent_text = shlex.join(agent_command(lane, effort))
    if lane in ("opencode", "deepseek"):
        agent_text += ' -- "$(cat .lane/prompt.md)"'
    return agent_text


# --- Estado local das lanes --------------------------------------------------
def state_file(lane: str) -> Path:
    return STATE_DIR / f"lane-{lane}.json"


def load_state(lane: str) -> Optional[dict]:
    f = state_file(lane)
    return json.loads(f.read_text()) if f.exists() else None


def save_state(lane: str, st: dict) -> None:
    # Escrita atômica: um lane-<x>.json pela metade (Mac dormiu, disco cheio) fazia o
    # load_state levantar em todo ciclo e parava o dispatcher inteiro.
    f = state_file(lane)
    tmp = f.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2))
    tmp.replace(f)


TITULOS_MAX = 500  # o painel só mostra cards recentes; o arquivo não cresce sem fim


def atualizar_cache_titulos(cards) -> None:
    """Mantém `titulos-cache.json` (lido pelo app TuttiDash) com o título de cada card
    que o dispatcher vê no Linear, para que a UI exiba o nome do card em vez do id.
    Grava só quando algo mudou, de forma atômica (o app nunca lê arquivo pela metade),
    e guarda os `TITULOS_MAX` mais recentes (FRA-563)."""
    try:
        cache_path = STATE_DIR / "titulos-cache.json"
        cache = {}
        if cache_path.exists():
            try:
                lido = json.loads(cache_path.read_text(encoding="utf-8"))
                cache = lido if isinstance(lido, dict) else {}
            except (json.JSONDecodeError, OSError, UnicodeError):
                cache = {}
        alterou = False
        for card in (cards or []):
            if not isinstance(card, dict):
                continue
            ident, title = card.get("identifier"), card.get("title")
            if ident and title and cache.get(ident) != title:
                cache.pop(ident, None)  # reinsere no fim: o mais recente fica por último
                cache[ident] = title
                alterou = True
        if len(cache) > TITULOS_MAX:
            cache = dict(list(cache.items())[-TITULOS_MAX:])
            alterou = True
        if alterou:
            tmp = cache_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp.replace(cache_path)
    except Exception:  # noqa: BLE001 — o cache é acessório; o ciclo não pode cair
        pass


def enabled_lanes() -> set[str]:
    if not ENABLED_FILE.exists():
        return set()
    return {l.strip() for l in ENABLED_FILE.read_text().split() if l.strip() in LANES}


def tmux_alive(session: str) -> bool:
    return subprocess.run(["tmux", "has-session", "-t", session], capture_output=True,
                          env=dict(os.environ, PATH=TOOL_PATH)).returncode == 0


def descendants(pid: int) -> list[int]:
    out = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True)
    kids = [int(x) for x in out.stdout.split()]
    return kids + [d for k in kids for d in descendants(k)]


def kill_lane_tree(session: str) -> None:
    """Mata a árvore inteira da lane (o xcodebuild junto: senão segura o lock)."""
    try:
        panes = sh(["tmux", "list-panes", "-t", session, "-F", "#{pane_pid}"], check=False)
    except Exception:  # noqa: BLE001
        panes = ""
    pids: list[int] = []
    for p in panes.split():
        pids += descendants(int(p))
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(3)


# --- Escolha da lane pela medida (FRA-269) -----------------------------------
def parse_lanepct(text: str) -> dict:
    """`conta<TAB>pct<TAB>janela<TAB>reset` -> {conta: (pct|None, janela)}."""
    out = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        conta, pct, janela = parts[0].strip(), parts[1].strip(), parts[2].strip()
        out[conta] = (int(pct) if pct.isdigit() else None, janela)
    return out


def measure_lanes(renew: bool = True) -> tuple[dict, str]:
    """Mede o uso das contas. Com `renew`, usa o lanepct-auto (renova token vencido);
    sem, só lê (simulação não renova nada)."""
    exe = LANEPCT_AUTO
    if not renew:
        exe = HOME / ".transcentia" / "tools" / "lane-pct" / ".build" / "release" / "lanepct"
    if not exe.exists():
        return {}, f"{exe} não existe"
    try:
        out = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300,
                             env=dict(os.environ, PATH=TOOL_PATH))
    except subprocess.TimeoutExpired:
        return {}, "medida passou de 5 min"
    return parse_lanepct(out.stdout), out.stdout.strip()


def pick_lane(measures: dict, candidates, spend: Optional[dict] = None) -> tuple[Optional[str], str]:
    """Lane de menor % entre as candidatas com medida. Sem medida em ninguém (ex.:
    opencode sem Go), cai no menor gasto conhecido da semana no ledger (FRA-371) —
    nunca silencia: o critério vai no `shown`. (None, motivo) só sem candidatas.

    Lane sem janela de limite (o servidor respondeu, mas não há teto) entra como
    folga total; lane com erro de leitura fica fora — ver `pct_para_ordem`."""
    ok = {l: pct for l in candidates
          if (pct := pct_para_ordem(measures.get(l))) is not None}
    shown = " · ".join(f"{l} {measures[l][0]}% ({measures[l][1]})" if l in ok
                       else f"{l} sem medida ({measures.get(l, (None, 'ausente'))[1]})"
                       for l in sorted(candidates))
    if ok:
        lane = min(sorted(ok), key=lambda l: ok[l])
        return lane, shown + " (peso: quota %)"
    cand = sorted(candidates)
    if not cand:
        return None, shown
    if spend is None:
        spend = week_spend()
    lane = min(cand, key=lambda l: (spend.get(l, 0.0), l))
    return lane, shown + f" (peso: gasto semanal US$ {spend.get(lane, 0.0):.2f})"


LEDGER_FILE = Path.home() / ".transcentia" / "tools" / "ledger.jsonl"


def _iter_ledger(ledger: Path):
    """Registros JSON do ledger. Arquivo ausente ou linha inválida não derruba o ciclo."""
    try:
        fh = ledger.open(encoding="utf-8")
    except OSError:
        return
    with fh:
        for raw in fh:
            try:
                r = json.loads(raw)
            except ValueError:
                continue
            if isinstance(r, dict):
                yield r


def _custo_conhecido(valor) -> Optional[float]:
    """US$ conhecido. Zero, ausente ou bool não conta — nunca vira «grátis»."""
    if isinstance(valor, bool) or not isinstance(valor, (int, float)) or valor <= 0:
        return None
    return float(valor)


def _duracao_ms(reg: dict) -> float:
    """Duração medida; sem ela, a estimativa do parser. As duas não se somam."""
    for chave in ("duracao_ms", "duracao_estimada_ms"):
        valor = reg.get(chave)
        if isinstance(valor, bool) or not isinstance(valor, (int, float)) or valor <= 0:
            continue
        return float(valor)
    return 0.0


def _id_do_log(log_path: str) -> str:
    nome = Path(log_path or "").name
    if nome.endswith(".jsonl"):
        return nome[: -len(".jsonl")]
    return nome


def week_spend(ledger: Path = LEDGER_FILE, hoje: Optional[dt.date] = None) -> dict:
    """Gasto conhecido (custo_usd) da semana ISO por lane, lido do ledger do gasto.
    Fallback de peso quando nenhuma candidata tem medida de quota (FRA-371)."""
    hoje = hoje or dt.date.today()
    iso = hoje.isocalendar()
    semana = f"{iso[0]}-W{iso[1]:02d}"
    out: dict = {}
    for r in _iter_ledger(ledger):
        if r.get("semana") != semana:
            continue
        c = _custo_conhecido(r.get("custo_usd"))
        if c is None:
            continue  # zero/ausente = desconhecido, nunca "grátis"
        lane = r.get("lane") or "?"
        out[lane] = out.get(lane, 0.0) + c
    return out


def _esforco_freio(effort: str) -> str:
    return effort if effort in TENTATIVAS_MAX else EFFORT_DEFAULT


def resumo_freio(n: int, effort: str, gasto: float, tempo: float) -> str:
    """Linha única do comentário: tentativas, gasto e tempo contra o teto do esforço."""
    nivel = _esforco_freio(effort)
    return (f"tentativas: {n} de {TENTATIVAS_MAX[nivel]}; "
            f"gasto: US$ {gasto:.2f} de {ORCAMENTO_ACUMULADO_USD[nivel]:g}; "
            f"tempo: {int(round(tempo))} de {TEMPO_ACUMULADO_MIN[nivel]} min")


def causa_estouro(n: int, effort: str, gasto: float, tempo: float) -> Optional[str]:
    """None se o card cabe. Senão o que estourou, junto se for mais de um.

    O teto é inclusivo: chegar em N, em US$ Y ou em B min já para.
    """
    nivel = _esforco_freio(effort)
    partes = []
    if n >= TENTATIVAS_MAX[nivel]:
        partes.append("tentativas")
    if gasto >= ORCAMENTO_ACUMULADO_USD[nivel]:
        partes.append("gasto")
    if tempo >= TEMPO_ACUMULADO_MIN[nivel]:
        partes.append("tempo")
    return "+".join(partes) if partes else None


# --- Claim ------------------------------------------------------------------
def caminho_prompt(nome: str) -> Path:
    """Prompt versionado ao lado deste arquivo. Na cópia instalada o diretório
    é o mesmo. Se o install não levou o arquivo, vale o que já está no estado."""
    local = _AQUI / nome
    if local.is_file():
        return local
    return STATE_DIR / nome


def copiar_para_worktree(repo: Path, wt: Path, caminhos) -> list[str]:
    """Copia do `repo` para o worktree os arquivos que ficam fora do git (ex.: `AGENTS.md`
    gerado na máquina). Só caminho relativo dentro do repo; nunca sobrescreve o que o
    worktree já tem (versionado ou não). Devolve o que copiou."""
    copiados: list[str] = []
    raiz = repo.resolve()
    for rel in caminhos or []:
        rel = str(rel).strip()
        if not rel or Path(rel).is_absolute():
            continue
        origem = (repo / rel).resolve()
        if raiz not in origem.parents or not origem.is_file():
            continue  # fora do repo (../) ou ausente: nada a copiar
        destino = wt / rel
        if destino.exists():
            continue
        destino.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(origem, destino)
        copiados.append(rel)
    return copiados


def motivo_para_nao_enviar(wt: Path) -> str:
    """Vazio se a branch pode ir para o `origin`; senão o motivo (nada é enviado).

    0. O `origin` da pasta é o repositório do GitHub do cadastro (FRA-567).
    1. A branch tem de ter a `origin/main` atual na história. Uma branch criada antes
       de o repositório recomeçar (histórico antigo, sem ancestral comum) levaria todo
       o histórico antigo junto no push.
    2. O `antes_do_push` do projeto (ex.: conferência de publicação) tem de sair 0."""
    env = dict(os.environ, PATH=TOOL_PATH, GIT_TERMINAL_PROMPT="0")
    esperado = projeto().github
    origem = subprocess.run(["git", "config", "--get", "remote.origin.url"], cwd=wt,
                            capture_output=True, text=True, env=env)
    atual = projetos.normalizar_github(origem.stdout.strip()) if origem.returncode == 0 else ""
    if not esperado:
        return "o projeto não tem o repositório do GitHub no cadastro (Ajustes › Projetos)"
    if atual != esperado:
        return (f"o `origin` da pasta é `{atual or 'nenhum'}`, mas o projeto é do repositório "
                f"`{esperado}`; confira a pasta no cadastro")
    sh(["git", "fetch", "-q", "origin", "main"], cwd=wt, check=False)
    base = subprocess.run(["git", "merge-base", "HEAD", "origin/main"], cwd=wt,
                          capture_output=True, text=True, env=env)
    if base.returncode != 0 or not base.stdout.strip():
        return ("a branch não tem a `origin/main` atual na história (criada sobre um histórico "
                "antigo); recrie a branch a partir da main antes de rodar a lane")
    cmd = projeto().antes_do_push
    if cmd:
        r = subprocess.run(cmd, shell=True, cwd=wt, capture_output=True, text=True, timeout=300, env=env)
        if r.returncode != 0:
            fim = (r.stdout + r.stderr).strip().splitlines()[-12:]
            return f"a conferência antes do push (`{cmd}`) saiu {r.returncode}:\n" + "\n".join(fim)
    return ""


def prepare_worktree(branch: str, identifier: str) -> Path:
    repo, wts = projeto_repo(), projeto_worktrees()
    wt = wts / identifier.lower()
    if wt.exists():
        copiar_para_worktree(repo, wt, projeto().copiar_para_worktree)
        return wt
    sh(["git", "fetch", "-q", "origin", "main"], cwd=repo)
    remote = sh(["git", "ls-remote", "--heads", "origin", branch], cwd=repo, check=False)
    local = sh(["git", "branch", "--list", branch], cwd=repo, check=False)
    if remote:
        sh(["git", "fetch", "-q", "origin", f"{branch}:{branch}"], cwd=repo, check=False)
        sh(["git", "worktree", "add", "-q", str(wt), branch], cwd=repo)
    elif local:
        sh(["git", "worktree", "add", "-q", str(wt), branch], cwd=repo)
    else:
        sh(["git", "worktree", "add", "-q", "-b", branch, str(wt), "origin/main"], cwd=repo)
    # .lane/ (prompt, resultado, código de saída) nunca vai para o git.
    exclude = Path(sh(["git", "rev-parse", "--git-path", "info/exclude"], cwd=wt))
    if not exclude.is_absolute():
        exclude = wt / exclude
    text = exclude.read_text() if exclude.exists() else ""
    if ".lane/" not in text.split():
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text(text + ("\n" if text and not text.endswith("\n") else "") + ".lane/\n")
    copiar_para_worktree(repo, wt, projeto().copiar_para_worktree)
    return wt


def juntar_main(wt: Path) -> tuple[str, str]:
    """Traz a `origin/main` para a branch do card antes de cada rodada (PRD 29/10, mudança 1).

    Sem isto o worktree reaproveitado fica congelado na main da primeira rodada: os
    consertos que o dono faz na main (ex.: `scripts/testar.sh`) não chegam à prova,
    que roda o que está na branch (FRA-581 parou 2x assim). Merge, nunca rebase: a
    branch pode já estar no GitHub. Devolve (linha para o comentário de claim, nota
    para o prompt da lane); ("", "") quando a branch já tem a main."""
    try:
        return _juntar_main(wt)
    except Exception as exc:  # noqa: BLE001 — juntar a main nunca pode travar a fila
        return f"- main não entrou ({type(exc).__name__}: {str(exc)[:120]}); a rodada segue com a branch como está\n", ""


def historico_antigo(wt: Path) -> bool:
    """A branch do worktree não tem ancestral comum com a `origin/main` (veio de outro histórico)."""
    env = dict(os.environ, PATH=TOOL_PATH, GIT_TERMINAL_PROMPT="0")
    try:
        tem = subprocess.run(["git", "rev-parse", "-q", "--verify", "origin/main"], cwd=wt,
                             capture_output=True, text=True, env=env, timeout=60)
        if tem.returncode != 0:
            return False  # sem origin/main local (fetch falhou): não dá para afirmar
        base = subprocess.run(["git", "merge-base", "HEAD", "origin/main"], cwd=wt,
                              capture_output=True, text=True, env=env, timeout=60)
        return base.returncode != 0 or not base.stdout.strip()
    except Exception:  # noqa: BLE001
        return False


def _nota_conflito(main: str, lista: str) -> str:
    return ("\n\n## Rodada de conflito (escrito pelo dispatcher)\n\n"
            f"O `git merge origin/main` ({main}) neste worktree deu conflito em {lista} e o merge "
            "ainda não foi concluído.\n\n"
            "- Primeiro: resolva os marcadores mantendo o que a `main` trouxe e o que este card fez, "
            "`git add` dos arquivos e `git commit --no-edit`.\n"
            "- Depois siga o card normalmente.\n")


def _juntar_main(wt: Path) -> tuple[str, str]:
    env = dict(os.environ, PATH=TOOL_PATH, GIT_TERMINAL_PROMPT="0")

    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *args], cwd=wt, capture_output=True, text=True, env=env, timeout=180)

    # Merge pela metade (rodada anterior ou `rebase_dirty` do vigia): não começa outro;
    # a lane conclui o que já está marcado.
    if git("rev-parse", "-q", "--verify", "MERGE_HEAD").returncode == 0:
        pendentes = git("diff", "--name-only", "--diff-filter=U").stdout.split()
        lista = ", ".join(pendentes[:8]) or "nenhum arquivo marcado (falta só o commit)"
        main = git("rev-parse", "--short", "MERGE_HEAD").stdout.strip()
        return f"- merge da main pela metade no worktree ({lista}); a lane conclui nesta rodada\n", _nota_conflito(main, lista)
    if git("fetch", "-q", "origin", "main").returncode != 0:
        return "- main não buscada (fetch falhou); a rodada segue com a branch como está\n", ""
    if git("merge-base", "--is-ancestor", "origin/main", "HEAD").returncode == 0:
        return "", ""
    antes = git("rev-parse", "--short", "HEAD").stdout.strip()
    main = git("rev-parse", "--short", "origin/main").stdout.strip()
    sujos = [l for l in git("status", "--porcelain", "--untracked-files=no").stdout.splitlines()
             if l.strip() and ".lane/" not in l]
    if sujos:
        return ("- main não entrou: o worktree tem mudança sem commit\n",
                "\n\n## Main atrasada (escrito pelo dispatcher)\n\n"
                f"A `origin/main` ({main}) andou e não entrou nesta branch porque o worktree tem mudança "
                "sem commit. Termine e commite o trabalho; o dispatcher junta a main na próxima rodada.\n")
    out = git("merge", "--no-edit", "origin/main")
    if out.returncode == 0:
        depois = git("rev-parse", "--short", "HEAD").stdout.strip()
        return f"- main juntada na branch: {antes} → {depois} (main {main})\n", ""
    conflitos = git("diff", "--name-only", "--diff-filter=U").stdout.split()
    if not conflitos:
        git("merge", "--abort")
        erro = (out.stderr or out.stdout).strip().splitlines()[-1:] or ["?"]
        return f"- main não entrou: o merge falhou ({erro[0][:160]}); a branch ficou como estava\n", ""
    lista = ", ".join(conflitos[:8])
    return f"- main juntada com conflito em {lista}; a lane resolve nesta rodada\n", _nota_conflito(main, lista)


def limit_text(lane: str, effort: str) -> str:
    """Limite da execução no comentário do claim: grok tem turnos; claude e opencode,
    teto em US$ (no opencode o CLI não trava — o gasto monitora depois da rodada)."""
    if lane == "grok":
        return f"limite {GROK_MAX_TURNS[effort]} turnos"
    if lane == "deepseek":
        return "sem teto de gasto no CLI"
    return f"teto US$ {BUDGET_USD[effort]}"


def claim(lane: str, issue: dict, effort: str, measure: str = "") -> None:
    card = linear(QUERY_ISSUE, {"id": issue["id"]})["issue"]
    ident = card["identifier"]
    wt = prepare_worktree(card["branchName"], ident)
    linha_main, nota_main = juntar_main(wt)
    if historico_antigo(wt):
        # FRA-443 (29/10): a branch local era do repositório antigo; a lane rodou opus xhigh
        # sobre código velho e o push seria barrado no fim. Melhor falhar antes de gastar.
        raise RuntimeError(
            f"a branch `{card['branchName']}` não tem ancestral comum com a `origin/main` (histórico "
            f"antigo do repositório). Nada foi rodado. Se ela não tem trabalho a salvar, recrie-a no "
            f"worktree com `git checkout -B {card['branchName']} origin/main` e devolva o card à fila")
    lane_dir = wt / ".lane"
    if lane_dir.exists():
        for f in ("exit_code", "result.json", "finalized", "triagem_reprova"):  # triagem_reprova: rodadas antigas
            (lane_dir / f).unlink(missing_ok=True)
        archive_old_proofs(lane_dir, ident)
    lane_dir.mkdir(exist_ok=True)

    (lane_dir / "card.md").write_text(
        f"# {ident} — {card['title']}\n\n{card['url']}\n\n{card.get('description') or ''}\n",
        encoding="utf-8",
    )
    base_prompt = caminho_prompt("lane-prompt.md")
    template = base_prompt.read_text(encoding="utf-8") if base_prompt.is_file() else ""
    extra = caminho_prompt(f"lane-prompt-{lane}.md")   # regras específicas do agente
    if extra.is_file():
        template += "\n" + extra.read_text(encoding="utf-8")
    prompt = (template.replace("{{CARD}}", ident).replace("{{LANE}}", lane)
              .replace("{{BRANCH}}", card["branchName"]).replace("{{WORKTREE}}", str(wt)))
    prompt += resume_note(wt)
    prompt += nota_main
    prompt_file = lane_dir / "prompt.md"
    prompt_file.write_text(prompt, encoding="utf-8")

    # dsh: o patch do perfil (conta + modelo + esforço) vai junto com o prompt.
    if lane == "deepseek":
        (lane_dir / "deepseek.yml").write_text(deepseek_patch(effort), encoding="utf-8")

    # FRA-374: o `--` fecha o parsing de flags do CLI. Sem ele, um token do
    # prompt como `--check` (git diff --check) é lido como flag e o CLI aborta.
    agent_text = texto_do_agente(lane, effort)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    LANE_LOG_DIR.mkdir(parents=True, exist_ok=True)
    lane_log = LANE_LOG_DIR / f"{ident}-{lane}-{stamp}.jsonl"
    (lane_dir / "agent_cmd").write_text(agent_text)

    # FRA-267: commit de partida. O caminho protegido se confere só no que a lane fez
    # depois dele: a branch pode já trazer commits de pessoas (ex.: FRA-13).
    base = sh(["git", "rev-parse", "HEAD"], cwd=wt)
    st = {"lane": lane, "card": ident, "issue_id": card["id"], "title": card["title"],
          "url": card["url"], "branch": card["branchName"], "worktree": str(wt), "base": base,
          "effort": effort, "modelo": modelo_da_lane(lane, effort),
          "modelo_fixo": aviso_modelo(lane, effort) == "modelo fixo",
          "aviso_modelo": aviso_modelo(lane, effort),
          "started": time.time(), "started_at": now(),
          "log": str(lane_log), "session": f"lane-{lane}"}
    save_state(lane, st)

    flags = (deepseek_resumo(effort) if lane == "deepseek"
             else " ".join(flags_da_lane(lane, effort)) or "padrão do CLI")
    linear(MUT_COMMENT, {"id": card["id"], "body":
        f"▶️ **lane:{lane}** assumiu o card ({now()}).\n\n"
        f"- esforço `{effort}` → `{flags}`, {limit_text(lane, effort)}, timeout {LANE_TIMEOUT_MIN} min\n"
        f"- branch `{card['branchName']}`, worktree local\n"
        + linha_main
        + (f"- lane escolhida pela medida: {measure}\n" if measure else "") +
        f"- o agente não fala com Linear/GitHub; o dispatcher fecha o card ao final"})

    session = st["session"]
    if tmux_alive(session):
        sh(["tmux", "kill-session", "-t", session], check=False)
    runner = STATE_DIR / "run_lane.sh"
    sh(["tmux", "new-session", "-d", "-s", session, "-c", str(wt),
        f"bash {shlex.quote(str(runner))} {lane} {shlex.quote(str(wt))} {ident} {shlex.quote(str(lane_log))}"])
    # Janela única 'lanes' (claude em cima, grok embaixo). Fechar não para a lane.
    st["window_ok"] = _show_in_lanes_window(lane, session, ident)
    save_state(lane, st)
    # Cache de títulos para o painel (FRA-563): grava o título do card para que
    # o painel possa exibi-lo mesmo quando a lane não está rodando.
    atualizar_cache_titulos([card])
    log(f"lane:{lane} ASSUMIU {ident} (esforço {effort}) → {wt}")


def _show_in_lanes_window(lane: str, session: str, card: str) -> bool:
    """Único caminho de exibição: o painel da lane na janela 'lanes'. Nunca abre
    outra janela; se falhar, registra e o watch tenta de novo no próximo ciclo."""
    try:
        ok = lanes_window.show_task(lane, session, card)
        lanes_window.open_window_once(LANES_COMMAND)
    except Exception as exc:  # noqa: BLE001 — a janela nunca pode derrubar a lane
        ok = False
        log(f"janela das lanes: {exc}")
    if not ok:
        log(f"lane:{lane} {card}: painel da janela 'lanes' não atualizou; tento no próximo ciclo")
    return ok


def archive_old_proofs(lane_dir: Path, ident: str) -> None:
    """Ao reassumir um card, move .lane/proof* da rodada anterior para fora do
    worktree (STATE_DIR/stale-proof-<card>-<HHMM>), para a prova nova não ler lixo."""
    old = sorted(lane_dir.glob("proof*"))
    if not old:
        return
    dest = STATE_DIR / f"stale-proof-{ident.lower()}-{dt.datetime.now():%H%M}"
    dest.mkdir(parents=True, exist_ok=True)
    for f in old:
        f.rename(dest / f.name)
    log(f"{ident}: {len(old)} proof* antigos arquivados em {dest}")


def discard_stale_proof(lane_dir: Path, ident: str, round_started: float) -> bool:
    """FRA-282: só vale a prova desta rodada. Se o proof_started é mais velho que o início
    da rodada (ou ilegível), arquiva os proof* e devolve True; a prova roda de novo."""
    ps = lane_dir / "proof_started"
    if not ps.exists():
        return False
    try:
        when = float(ps.read_text() or 0)
    except ValueError:
        when = 0.0
    if when >= round_started:
        return False
    archive_old_proofs(lane_dir, ident)
    return True


# --- Acompanhamento e fechamento --------------------------------------------
def git_summary(wt: Path, base: Optional[str] = None) -> dict:
    """`files`: tudo o que a branch muda em relação à main (vai no PR).
    `new` e `lane_files`: só o que a lane fez desde `base` (sem base, estado antigo, vale a main)."""
    sh(["git", "fetch", "-q", "origin", "main"], cwd=wt, check=False)
    ahead = int(sh(["git", "rev-list", "--count", "origin/main..HEAD"], cwd=wt) or 0)
    files = [f for f in sh(["git", "diff", "--name-only", "origin/main...HEAD"], cwd=wt).splitlines() if f]
    if base:
        new = int(sh(["git", "rev-list", "--count", f"{base}..HEAD"], cwd=wt) or 0)
        desde_base = [f for f in sh(["git", "diff", "--name-only", f"{base}..HEAD"], cwd=wt).splitlines() if f]
        # A lane pode trazer a main para dentro da branch. O merge põe no
        # `base..HEAD` arquivos que são da main, não dela — foi assim que a
        # FRA-453 morreu três vezes acusada de tocar `caminho.md`, que a main
        # tinha mudado. O que a branch acrescenta à main é `origin/main...HEAD`;
        # a interseção deixa só o que a lane fez nesta rodada.
        da_branch = set(files)
        lane_files = [f for f in desde_base if f in da_branch]
    else:
        new, lane_files = ahead, files
    dirty = [l for l in sh(["git", "status", "--porcelain"], cwd=wt).splitlines() if l.strip()]
    sha = sh(["git", "rev-parse", "--short", "HEAD"], cwd=wt)
    return {"ahead": ahead, "new": new, "files": files, "lane_files": lane_files, "dirty": dirty, "sha": sha}


def read_result(wt: Path) -> Optional[dict]:
    f = wt / ".lane" / "result.json"
    try:
        r = json.loads(f.read_text(encoding="utf-8"))
        return r if isinstance(r, dict) else None
    except Exception:  # noqa: BLE001
        return None


def agent_outcome(log_path: str) -> str:
    """Desfecho declarado pelo próprio agente (última linha 'result' do stream).
    No Grok, ação fora da lista permitida encerra com subtype error_during_execution
    e errors=['cancelled'], mas com código de saída 0."""
    try:
        lines = Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return "log ausente"
    for raw in reversed(lines):
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if ev.get("type") == "result":
            errs = ev.get("errors") or []
            out = f"agente: {ev.get('subtype')}, {ev.get('num_turns')} turnos"
            if "cancelled" in errs:
                out += "; sessão cancelada por ação fora da lista permitida"
            elif errs:
                out += f"; erros: {errs}"
            return out
    return "agente não registrou resultado"


LIMIT_TEXT_RE = re.compile(r"(hit your|reached your)[^\"\n]{0,60}limit", re.I)


def provider_429(lines: list) -> bool:
    """O stream tem erro HTTP 429 ou limite de uso num evento `error`?

    Vale para todas as lanes (OpenCode: `status` 429, `FreeUsageLimitError`,
    `provider.quota`; codex e grok: o mesmo formato de evento). Só evento
    `error`: um 429 citado em texto de código ou de resposta não segura a lane."""
    for raw in lines:
        if '"error"' not in raw or ("429" not in raw and "FreeUsageLimit" not in raw):
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        err = ev.get("error") if isinstance(ev, dict) and ev.get("type") == "error" else None
        if isinstance(err, dict) and (err.get("status") == 429 or err.get("type") == "provider.quota"
                                      or "FreeUsageLimit" in json.dumps(err)):
            return True
    return False


def backoff_429(lane: str) -> float:
    """Segundos de espera depois de um 429 em `lane`; dobra a cada 429 seguido (FRA-192 caiu
    nele 10 vezes em 1 dia porque a lane voltava a assumir cards a cada ciclo de 60 s)."""
    f = STATE_DIR / f"limite-429-{lane}.json"
    n = 0
    try:
        est = json.loads(f.read_text())
        if time.time() - float(est.get("at", 0)) < LIMIT_429_RESET_S:
            n = int(est.get("n", 0)) + 1
    except (ValueError, OSError, AttributeError):
        n = 0
    espera = min(LIMIT_429_BASE_S * 2 ** n, LIMIT_429_MAX_S)
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"n": n, "at": time.time(), "espera_s": espera}))
    except OSError:
        pass
    return espera


def account_limit(log_path: str, lane: str = "") -> Optional[float]:
    """Epoch em que a conta volta, se o agente foi cortado pelo limite de uso; senão None.

    Claude: evento `rate_limit_event` com status `rejected` (traz `resetsAt`).
    Qualquer lane: erro 429 do provedor no evento `error` (sem horário de volta)
    espera com recuo de 1 h até 8 h (`backoff_429`). Fallback: o aviso em texto
    nas últimas linhas do stream. Não é falha do card."""
    try:
        lines = Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    hit, resets = False, None
    for raw in lines:
        if "rate_limit" not in raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        info = ev.get("rate_limit_info") if isinstance(ev, dict) else None
        if isinstance(info, dict) and info.get("status") == "rejected":
            hit, resets = True, info.get("resetsAt") or resets
    if not hit and any(LIMIT_TEXT_RE.search(l) for l in lines[-30:]):
        hit = True
    if not hit and provider_429(lines):
        return time.time() + backoff_429(lane or "conta")
    if not hit:
        return None
    try:
        until = float(resets)
    except (TypeError, ValueError):
        # Sem horário de volta: a mesma espera que dobra de 1 h até 8 h.
        return time.time() + backoff_429(lane or "conta")
    return max(until, time.time() + 120)  # já passou: tenta de novo em 2 min


def wake_gap_line(prev_at: Optional[str], now_dt: dt.datetime) -> Optional[str]:
    """Linha do painel quando o dispatcher ficou sem rodar (Mac em repouso, tampa fechada, desligado)."""
    try:
        prev = dt.datetime.strptime(prev_at or "", "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    gap = (now_dt - prev).total_seconds()
    if gap < SLEEP_GAP_S:
        return None
    mins = int(gap // 60)
    took = f"{mins // 60} h {mins % 60:02d} min" if mins >= 60 else f"{mins} min"
    since = f"{prev:%d/%m %H:%M}" if prev.date() != now_dt.date() else f"{prev:%H:%M}"
    return (f"repouso: o dispatcher ficou sem rodar das {since} às {now_dt:%H:%M} ({took}); Mac em repouso, "
            f"tampa fechada ou desligado. Nenhuma lane assumiu card nesse intervalo")


def hhmm(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%H:%M")


def limit_file(lane: str) -> Path:
    return STATE_DIR / f"limite-{lane}.json"


def lane_limited(lane: str) -> Optional[float]:
    """Epoch até quando a lane espera o limite da conta; None se livre (e limpa o arquivo vencido)."""
    f = limit_file(lane)
    if not f.exists():
        return None
    try:
        until = float(json.loads(f.read_text()).get("until", 0))
    except (ValueError, OSError, AttributeError):
        until = 0.0
    if until > time.time():
        return until
    f.unlink(missing_ok=True)
    log(f"lane:{lane} limite da conta liberou; volta a assumir cards")
    return None


def headroom_pct(effort: str, janela: str = "") -> int:
    """Teto de folga do esforço, pela janela da medida: curta (5 h) = rígido; longa
    (>= 1 dia) = afrouxado (HEADROOM_PCT_LONGA)."""
    tabela = HEADROOM_PCT_LONGA if JANELA_LONGA_RE.search(janela or "") else HEADROOM_PCT
    return tabela.get(effort, tabela[EFFORT_DEFAULT])


# O que o lanepct escreve na coluna `janela` quando o servidor respondeu mas não
# tem janela de limite. Distingue "não tem teto" de "não deu para ler" sem
# precisar casar texto de erro (token vencido, 503, sem credencial...). O motivo
# real de leitura vem em `janela` no lugar dessa frase.
SEM_JANELA = "sem dado"


def pct_para_ordem(medida) -> Optional[float]:
    """O % que a lane tem agora, para ordenar. None = não é candidata.

    Três casos, e a distinção é o que segura o auto-pick:
      - pct conhecido                       → o número;
      - sem janela e `janela == sem dado`   → 0.0 (conta respondeu, sem teto: folga total);
      - sem pct com algum motivo em `janela`→ None (leitura falhou: fora, como sempre).
    Sem o caso do meio, uma lane com o Console fora do ar ficava esperando folga
    que ninguém ia medir (FRA-470).
    """
    if medida is None:
        return None
    pct, janela = medida[0], (medida[1] if len(medida) > 1 else "")
    if pct is not None:
        return float(pct)
    return 0.0 if janela == SEM_JANELA else None


def headroom_block(lane: str, effort: str, measures: dict) -> Optional[str]:
    """Motivo para segurar o card (conta sem folga para o esforço), ou None."""
    m = measures.get(lane)
    if not m or m[0] is None:
        return None  # sem medida não segura: esse caso já tem a etiqueta do dono na atribuição
    cap = headroom_pct(effort, m[1])
    if m[0] >= cap:
        return f"conta em {m[0]}% ({m[1]}); card `{effort}` só entra abaixo de {cap}%"
    return None


def measures_cached(real: bool) -> dict:
    cache = STATE_DIR / "medida-cache.json"
    try:
        c = json.loads(cache.read_text())
        if time.time() - c["at"] < MEASURE_CACHE_S:
            return {k: tuple(v) for k, v in c["m"].items()}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    m, _ = measure_lanes(renew=real)
    # Mesmo sem medida, grava o at: assim o painel sabe que a leitura é de agora
    # e não repete para sempre o último 100% de dois dias atrás.
    try:
        cache.write_text(json.dumps({"at": time.time(), "m": m}))
    except OSError:
        pass
    return m


def resume_note(wt: Path) -> str:
    """Prompt da retomada: worktree com trabalho de rodada anterior não pode ser refeito."""
    try:
        dirty = [l for l in sh(["git", "status", "--porcelain"], cwd=wt, check=False).splitlines()
                 if l.strip() and ".lane/" not in l]
        ahead = sh(["git", "rev-list", "--count", "origin/main..HEAD"], cwd=wt, check=False).strip()
    except Exception:  # noqa: BLE001
        return ""
    ahead_n = int(ahead) if ahead.isdigit() else 0
    if not dirty and not ahead_n:
        return ""
    return ("\n\n## Retomada (escrito pelo dispatcher)\n\n"
            f"Este worktree já tem trabalho de uma rodada anterior: {len(dirty)} arquivo(s) sem commit e "
            f"{ahead_n} commit(s) à frente da main. Comece por `git status` e `git diff`, confira contra o "
            "aceite e continue dele. Não refaça o que já está feito.\n")


def agent_session_id(log_path: str) -> Optional[str]:
    """Id da sessão do agente, lido do stream (o init e o result trazem session_id,
    no Claude e no Grok)."""
    try:
        with open(log_path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    sid = json.loads(raw).get("session_id")
                except (ValueError, AttributeError):
                    continue
                if isinstance(sid, str) and sid:
                    return sid
    except OSError:
        pass
    return None


def resume_line(st: dict) -> str:
    """Linha do comentário com o comando pronto para retomar a sessão do agente;
    vazia quando o log não tem o id."""
    sid = agent_session_id(st.get("log", ""))
    if not sid or st["lane"] == "deepseek":
        return ""   # o dsh headless não expõe `--resume` nem session_id no stdout
    cli = "grok" if st["lane"] == "grok" else "claude"
    return f"- retomar o agente: `cd {shlex.quote(st['worktree'])} && {cli} --resume {sid}`\n"


def pending_lines(st: dict) -> str:
    """FRA-269: trabalho pronto não fica invisível. Lista o que está sem commit e os
    commits da lane ainda não enviados."""
    wt = Path(st["worktree"])
    try:
        dirty = [l for l in sh(["git", "status", "--porcelain"], cwd=wt, check=False).splitlines() if l.strip()]
        base = st.get("base")
        commits = (sh(["git", "log", "--oneline", f"{base}..HEAD"], cwd=wt, check=False).splitlines()
                   if base else [])
    except Exception:  # noqa: BLE001
        return ""
    out = ""
    if dirty:
        shown = "\n".join(f"  - `{l.strip()}`" for l in dirty[:15])
        more = f"\n  - … e mais {len(dirty) - 15}" if len(dirty) > 15 else ""
        out += f"- **não commitado** ({len(dirty)}):\n{shown}{more}\n"
    if commits:
        out += f"- commits da lane no worktree ({len(commits)}): " + ", ".join(f"`{c}`" for c in commits[:5]) + "\n"
    return out


# Causa estável de cada parada (melhoria 1, 21/10/2026). Vai numa linha `- causa: `x``
# do comentário: o vigia conta as paradas repetidas por ela, e não pelo texto do motivo
# (que muda de rodada para rodada — a lista de suítes, por exemplo — e fazia a trava
# dos 3 strikes nunca disparar).
CAUSAS = (
    ("caminho protegido", "caminho-protegido"),
    ("parada manual", "parada-manual"),
    ("sem saída", "sem-saida"),
    ("timeout de", "timeout-lane"),
    ("sessão tmux sumiu", "sessao-sumiu"),
    ("sessão cancelada", "sessao-cancelada"),
    ("agente saiu com código", "agente-erro"),
    ("sem .lane/result.json", "sem-resultado"),
    ("nenhum commit novo", "sem-commit"),
    ("mudanças sem commit", "mudancas-sem-commit"),
    ("não contou", "prova-sem-contagem"),
    ("a prova do dispatcher falhou", "prova-vermelha"),
    ("prova morreu", "prova-morta"),
    ("preflight", "preflight"),
    ("passou de", "prova-timeout"),
    ("freio do card", "freio-card"),
)


def causa_de(motivo: str) -> str:
    m = (motivo or "").lower()
    for trecho, causa in CAUSAS:
        if trecho in m:
            return causa
    return "outra"


def linha_causa(causa: str) -> str:
    return f"- causa: `{causa}`\n"


def _arquivo_strikes() -> Path:
    return STATE_DIR / "opencode-strikes.json"


def ler_strikes() -> dict:
    try:
        dados = json.loads(_arquivo_strikes().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"strikes": 0, "max": STRIKES_OPENCODE, "cards": {}}
    if not isinstance(dados, dict):
        return {"strikes": 0, "max": STRIKES_OPENCODE, "cards": {}}
    if not isinstance(dados.get("cards"), dict):
        dados["cards"] = {}
    return dados


def gravar_strikes(dados: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        _arquivo_strikes().write_text(json.dumps(dados, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass


def strikes_do_card(identifier: str) -> int:
    card = (ler_strikes().get("cards") or {}).get(identifier) or {}
    if not isinstance(card, dict):
        return 0
    try:
        return int(card.get("n", 0))
    except (TypeError, ValueError):
        return 0


def _publicar_topo(dados: dict, ident: str, card: dict, effort: str) -> None:
    dados["cards"][ident] = card
    nivel = _esforco_freio(effort)
    dados["max"] = TENTATIVAS_MAX[nivel]
    dados["strikes"] = int(card.get("n") or 0)
    dados["motivos"] = [f"{ident}: {m}" for m in card.get("motivos") or [] if isinstance(m, str)]
    gravar_strikes(dados)


def registrar_tentativa(st: dict, motivo: str) -> int:
    """Conta uma tentativa deste card, em qualquer lane. A mesma `log` não conta de novo."""
    ident = st.get("card") or ""
    if not ident:
        return 0
    dados = ler_strikes()
    card = _bloco_card(dados, ident)
    chave = st.get("log") or ""
    chaves = [x for x in (card.get("chaves") or []) if isinstance(x, str)]
    if chave and chave in chaves:
        return int(card.get("n") or 0)
    if chave:
        chaves.append(chave)
        card["chaves"] = chaves[-20:]
    card["n"] = int(card.get("n") or 0) + 1
    motivos = [m for m in card.get("motivos") or [] if isinstance(m, str)]
    motivos.append((motivo or "")[:180])
    card["motivos"] = motivos[-6:]
    effort = _esforco_freio(st.get("effort") or card.get("esforco") or EFFORT_DEFAULT)
    card["esforco"] = effort
    _publicar_topo(dados, ident, card, effort)
    return card["n"]


def registrar_falha_opencode(st: dict, motivo: str) -> int:
    """Nome antigo. Conta uma tentativa do card em qualquer lane (FRA-443)."""
    return registrar_tentativa(st, motivo)


def _lembrar_sessao(st: dict) -> None:
    """Guarda os minutos desta rodada no estado, uma vez por log."""
    ident = st.get("card") or ""
    log_id = _id_do_log(st.get("log") or "")
    if not ident or not log_id or st.get("started") is None:
        return
    marca = st.get("agora")
    marca = time.time() if marca is None else float(marca)
    decorrido = (marca - float(st["started"])) / 60.0
    if decorrido <= 0:
        return
    dados = ler_strikes()
    card = _bloco_card(dados, ident)
    rodadas = card.get("rodadas_min")
    if not isinstance(rodadas, dict):
        rodadas = {}
    anterior = rodadas.get(log_id)
    if (isinstance(anterior, bool) or not isinstance(anterior, (int, float))
            or decorrido > float(anterior)):
        rodadas[log_id] = round(decorrido, 2)
    card["rodadas_min"] = rodadas
    soma = sum(float(v) for v in rodadas.values()
               if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0)
    card["tempo_min"] = round(soma, 2)
    effort = _esforco_freio(st.get("effort") or card.get("esforco") or EFFORT_DEFAULT)
    _publicar_topo(dados, ident, card, effort)


def _anotar_medidas(ident: str, effort: str, gasto: float, tempo: float) -> None:
    if not ident:
        return
    dados = ler_strikes()
    card = _bloco_card(dados, ident)
    nivel = _esforco_freio(effort or card.get("esforco") or EFFORT_DEFAULT)
    card["gasto_usd"] = round(float(gasto), 4)
    card["tempo_min"] = round(float(tempo), 2)
    card["esforco"] = nivel
    card["resumo"] = resumo_freio(int(card.get("n") or 0), nivel, gasto, card["tempo_min"])
    _publicar_topo(dados, ident, card, nivel)


def comentarios_de(issue: dict) -> list:
    bruto = issue.get("comments")
    if isinstance(bruto, dict):
        nodes = bruto.get("nodes") or []
    elif isinstance(bruto, list):
        nodes = bruto
    else:
        nodes = []
    return [n for n in nodes if isinstance(n, dict)]


def registrar_ajustes_ollie(identifier: str, comentarios: list, effort: str = EFFORT_DEFAULT) -> int:
    """Cada comentário novo com pedido de ajuste do revisor soma 1 (D4). O mesmo id não repete."""
    if not identifier:
        return 0
    dados = ler_strikes()
    card = _bloco_card(dados, identifier)
    vistos = [x for x in (card.get("ajustes") or []) if isinstance(x, str)]
    novos = 0
    for comentario in comentarios or []:
        corpo = comentario.get("body") or ""
        if MARCA_AJUSTE_OLLIE not in corpo:
            continue
        cid = str(comentario.get("id") or "")
        if not cid or cid in vistos:
            continue
        vistos.append(cid)
        novos += 1
        motivos = [m for m in card.get("motivos") or [] if isinstance(m, str)]
        motivos.append("revisor pediu ajustes")
        card["motivos"] = motivos[-6:]
    if not novos:
        return int(card.get("n") or 0)
    card["ajustes"] = vistos[-30:]
    card["n"] = int(card.get("n") or 0) + novos
    nivel = _esforco_freio(effort)
    card["esforco"] = nivel
    _publicar_topo(dados, identifier, card, nivel)
    return card["n"]


def limpar_strike_do_card(identifier: str) -> None:
    dados = ler_strikes()
    cards = dados.get("cards") or {}
    if identifier not in cards:
        return
    cards.pop(identifier, None)
    dados["cards"] = cards
    dados["strikes"] = 0
    dados["max"] = STRIKES_OPENCODE
    dados["motivos"] = []
    gravar_strikes(dados)


def _bloco_card(dados: dict, identifier: str) -> dict:
    cards = dados.setdefault("cards", {})
    atual = cards.get(identifier)
    if not isinstance(atual, dict):
        atual = {"n": 0, "motivos": []}
    if not isinstance(atual.get("motivos"), list):
        atual["motivos"] = []
    cards[identifier] = atual
    return atual


def _numero_guardado(card: dict, chave: str) -> float:
    valor = card.get(chave)
    if isinstance(valor, bool) or not isinstance(valor, (int, float)) or valor < 0:
        return 0.0
    return float(valor)


def gasto_do_card(identifier: str, ledger: Optional[Path] = None) -> float:
    """US$ acumulado do card: o que o ledger soma, ou o que o estado já guardou — o maior."""
    alvo = (identifier or "").upper()
    vivo = 0.0
    if alvo:
        for reg in _iter_ledger(LEDGER_FILE if ledger is None else ledger):
            if str(reg.get("card") or "").upper() != alvo:
                continue
            custo = _custo_conhecido(reg.get("custo_usd"))
            if custo is not None:
                vivo += custo
    card = (ler_strikes().get("cards") or {}).get(identifier) or {}
    guardado = _numero_guardado(card, "gasto_usd") if isinstance(card, dict) else 0.0
    return max(vivo, guardado)


def tempo_do_card_min(identifier: str, ledger: Optional[Path] = None,
                      sessao: Optional[dict] = None, agora: Optional[float] = None) -> float:
    """Minutos acumulados do card. Cada log entra uma vez: o ledger vence o que o
    dispatcher guardou; a rodada ainda aberta soma pelo relógio se o log não está lá."""
    alvo = (identifier or "").upper()
    por_id: dict = {}
    if alvo:
        for reg in _iter_ledger(LEDGER_FILE if ledger is None else ledger):
            if str(reg.get("card") or "").upper() != alvo:
                continue
            dur = _duracao_ms(reg) / 60000.0
            chave = reg.get("id")
            if dur > 0 and chave:
                por_id[str(chave)] = dur
    card = (ler_strikes().get("cards") or {}).get(identifier) or {}
    rodadas = card.get("rodadas_min") if isinstance(card, dict) else None
    if isinstance(rodadas, dict):
        for chave, valor in rodadas.items():
            if chave in por_id:
                continue
            if isinstance(valor, bool) or not isinstance(valor, (int, float)) or valor <= 0:
                continue
            por_id[str(chave)] = float(valor)
    if sessao:
        log_id = _id_do_log(sessao.get("log") or "")
        if log_id and sessao.get("started") is not None:
            marca = agora if agora is not None else sessao.get("agora")
            marca = time.time() if marca is None else float(marca)
            decorrido = (marca - float(sessao["started"])) / 60.0
            if decorrido > por_id.get(log_id, 0):
                por_id[log_id] = decorrido
    _espelhar_tempos(identifier, por_id)
    return sum(por_id.values())


def _espelhar_tempos(identifier: str, por_id: dict) -> None:
    """Grava no estado os minutos já unidos (ledger + rodadas), se mudaram."""
    if not identifier:
        return
    dados = ler_strikes()
    card = _bloco_card(dados, identifier)
    novo = {str(k): round(float(v), 2) for k, v in por_id.items() if float(v) > 0}
    total = round(sum(novo.values()), 2)
    atual = card.get("rodadas_min") if isinstance(card.get("rodadas_min"), dict) else {}
    if atual == novo and _numero_guardado(card, "tempo_min") == total:
        return
    card["rodadas_min"] = novo
    card["tempo_min"] = total
    _publicar_topo(dados, identifier, card, card.get("esforco") or EFFORT_DEFAULT)


def causa_do_card(identifier: str, effort: str, sessao: Optional[dict] = None,
                  agora: Optional[float] = None) -> Optional[str]:
    if not identifier:
        return None
    return causa_estouro(strikes_do_card(identifier), effort,
                         gasto_do_card(identifier),
                         tempo_do_card_min(identifier, sessao=sessao, agora=agora))


def card_banido_da_lane(lane: str, identifier: str, effort: str = "") -> bool:
    """True quando o card estourou tentativas, gasto ou tempo (FRA-443).

    O freio é do card, em qualquer lane. `lane` fica na assinatura porque a fila
    já chamava assim; o teto não muda com a lane.
    """
    del lane
    return causa_do_card(identifier, effort or EFFORT_DEFAULT) is not None


def tirar_label_da_lane(issue_id: str, lane: str) -> None:
    label = LABEL_LANE_IDS.get(lane)
    if not label or not issue_id:
        return
    try:
        linear(MUT_REMOVE_LABEL, {"id": issue_id, "label": label})
    except Exception as exc:  # noqa: BLE001
        log(f"lane:{lane} não removeu a label do card {issue_id}: {exc}")


def _corpo_freio(lane: str, motivo: str, resumo: str, extra: str, st: Optional[dict]) -> str:
    st = st or {}
    linhas = (f"⛔ **lane:{lane}** parou por freio do card: {motivo}.\n\n"
              f"- {resumo}\n"
              f"{linha_causa('freio-card')}")
    if st.get("log"):
        linhas += f"- log: `{st['log']}`\n"
    if st.get("worktree"):
        linhas += f"- worktree: `{st['worktree']}` (não foi apagado)\n"
        linhas += f"{resume_line(st)}{pending_lines(st)}"
    else:
        linhas += "- o worktree não foi apagado\n"
    linhas += f"{extra or ''}\n"
    linhas += (f"O dispatcher não assume este card de novo enquanto o freio estiver estourado "
               f"(label `{FREIO_LABEL}`).")
    return linhas


def publicar_freio(issue_id: str, lane: str, ident: str, effort: str, motivo: str,
                   extra: str = "", st: Optional[dict] = None) -> str:
    """Aplica lane:falhou e comenta os totais. O mesmo resumo não gera outro comentário."""
    nivel = _esforco_freio(effort)
    n = strikes_do_card(ident)
    gasto = gasto_do_card(ident)
    tempo = tempo_do_card_min(ident, sessao=st, agora=(st or {}).get("agora"))
    _anotar_medidas(ident, nivel, gasto, tempo)
    resumo = resumo_freio(n, nivel, gasto, tempo)
    dados = ler_strikes()
    card = _bloco_card(dados, ident) if ident else {}
    ja = bool(ident) and card.get("aviso") == resumo
    aplicar_label(issue_id, LABEL_LANE_FALHOU_ID, FREIO_LABEL)
    if not ja and issue_id:
        linear(MUT_COMMENT, {"id": issue_id, "body": _corpo_freio(lane, motivo, resumo, extra, st)})
        if ident:
            card["aviso"] = resumo
            _publicar_topo(dados, ident, card, nivel)
    return f"lane:falhou ({motivo})"


def fail(st: dict, motivo: str, extra: str = "", causa: str = "") -> str:
    ident = st.get("card") or ""
    n = registrar_tentativa(st, motivo)
    _lembrar_sessao(st)
    effort = _esforco_freio(st.get("effort") or EFFORT_DEFAULT)
    gasto = gasto_do_card(ident)
    tempo = tempo_do_card_min(ident, sessao=st, agora=st.get("agora"))
    _anotar_medidas(ident, effort, gasto, tempo)
    if causa_estouro(n, effort, gasto, tempo):
        return publicar_freio(st.get("issue_id") or "", st.get("lane") or "", ident, effort,
                              motivo, extra, st)
    aplicar_label(st["issue_id"], LABEL_LANE_FALHOU_ID, FREIO_LABEL)
    resumo = resumo_freio(n, effort, gasto, tempo)
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"⛔ **lane:{st['lane']}** terminou sem fechar o card: {motivo}.\n\n"
        f"{linha_causa(causa or causa_de(motivo))}"
        f"- {resumo}\n"
        f"- log: `{st['log']}`\n- worktree: `{st['worktree']}`\n{resume_line(st)}{pending_lines(st)}{extra}\n"
        f"Para voltar à fila: corrigir a causa e remover a label `{FREIO_LABEL}`."})
    return f"lane:falhou ({motivo})"


def freio_da_sessao_aberta(st: dict, agora: Optional[float] = None) -> Optional[str]:
    """Causa do freio se a rodada em andamento já passou do teto; None se ainda cabe."""
    return causa_do_card(st.get("card") or "", st.get("effort") or EFFORT_DEFAULT, sessao=st, agora=agora)


def retirar_travados(auto: list, per_lane: dict, real: bool) -> list:
    """Tira da fila o card que já estourou o freio. Em modo real, aplica a label e comenta."""
    linhas = []

    def trava(it: dict, lane_nome: str) -> bool:
        ident = it.get("identifier") or ""
        effort = it.get("_effort") or EFFORT_DEFAULT
        if real:
            registrar_ajustes_ollie(ident, comentarios_de(it), effort)
        causa = causa_do_card(ident, effort)
        if not causa:
            return False
        n = strikes_do_card(ident)
        resumo = resumo_freio(n, effort, gasto_do_card(ident), tempo_do_card_min(ident))
        linhas.append(f"lane:{lane_nome} freio {ident}: {resumo}")
        if real:
            publicar_freio(it.get("id") or "", lane_nome, ident, effort, f"freio do card ({causa})")
        return True

    if auto:
        auto[:] = [it for it in auto if not trava(it, AUTO_LANE)]
    for lane in list(per_lane):
        per_lane[lane] = [it for it in per_lane[lane] if not trava(it, lane)]
    return linhas


def card_ja_comecou(st: dict) -> bool:
    """Tem commit ou arquivo da lane desde o claim? Sem isso o card ainda não começou."""
    wt = Path(st.get("worktree") or "")
    try:
        base = st.get("base")
        novo = 0
        if base:
            saida = sh(["git", "rev-list", "--count", f"{base}..HEAD"], cwd=wt)
            novo = int(saida or 0)
        dirty = [l for l in sh(["git", "status", "--porcelain"], cwd=wt).splitlines()
                 if l.strip() and ".lane/" not in l]
    except Exception:  # noqa: BLE001
        return True
    return novo > 0 or bool(dirty)


def devolver_card_a_fila(st: dict, until: float) -> str:
    """Limite de uso antes de o card começar: a lane espera, o card volta à fila, sem falha."""
    limit_file(st["lane"]).write_text(json.dumps({"until": until, "card": st["card"], "at": now()}))
    tirar_label_da_lane(st["issue_id"], st["lane"])
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"⏳ **lane:{st['lane']}** bateu no limite de uso antes de começar o card "
        f"(não é erro do card, sem `lane:falhou`).\n\n"
        f"- a lane espera até **{hhmm(until)}** (a espera dobra de 1 h até 8 h a cada limite seguido)\n"
        f"- este card volta à fila e pode seguir em outra lane livre\n"
        f"{linha_causa('limite-conta')}"
        f"- log: `{st['log']}`\n- worktree: `{st['worktree']}`\n"})
    return f"devolvido à fila até {hhmm(until)} (limite de uso, sem falha)"


def reacao_ao_limite(st: dict, until: float) -> str:
    """Limite de uso nunca vira `lane:falhou`. Card já começado retoma; o outro volta à fila."""
    if card_ja_comecou(st):
        return hold_for_limit(st, until)
    return devolver_card_a_fila(st, until)


def hold_for_limit(st: dict, until: float) -> str:
    """Agente cortado pelo limite da conta: não é falha do card. Sem label de bloqueio; a lane
    espera até `until` e o card volta sozinho, retomando do worktree."""
    limit_file(st["lane"]).write_text(json.dumps({"until": until, "card": st["card"], "at": now()}))
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"⏳ **lane:{st['lane']}** parou pelo **limite de uso {'do provedor (HTTP 429)' if st['lane'].startswith('opencode') else 'da conta'}** (não é erro do card).\n\n"
        f"- volta sozinha às **{hhmm(until)}** e retoma este card do worktree (o trabalho fica lá)\n"
        f"{linha_causa('limite-conta')}"
        f"- log: `{st['log']}`\n- worktree: `{st['worktree']}`\n{resume_line(st)}{pending_lines(st)}"})
    return f"aguardando o limite da conta até {hhmm(until)} (volta sozinho, sem label)"


def stop(st: dict, motivo: str, extra: str = "", causa: str = "") -> str:
    """FRA-269: interrupção sem erro do agente (parada manual, timeout, sessão cancelada,
    prova sem tempo). Não é `lane:falhou`: o trabalho pode estar pronto no worktree."""
    aplicar_label(st["issue_id"], LABEL_LANE_PARADA_ID, linear_ids.PARADA)
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"⏸️ **lane:{st['lane']}** foi interrompida: {motivo}.\n\n"
        f"{linha_causa(causa or causa_de(motivo))}"
        f"- log: `{st['log']}`\n- worktree: `{st['worktree']}`\n{resume_line(st)}{pending_lines(st)}{extra}\n"
        f"Para voltar à fila: conferir o worktree e remover a label `lane:parada`."})
    return f"lane:parada ({motivo})"


# --- Prova pelo dispatcher (FRA-269) ------------------------------------------
# O comando vem do campo `prova` do projeto no cadastro: o iOS usa
# `safe_xcodebuild.sh` (que precisa de 2 tentativas, a 1ª com SKIP_PREFLIGHT), e um
# projeto Python usa `python3 {suite}` com 1 tentativa só.
def proof_suites(res: dict) -> list[str]:
    tests = res.get("tests")
    if isinstance(tests, str):
        tests = tests.split()
    suites = [t for t in (tests or []) if isinstance(t, str) and t.replace("/", "").replace("_", "").replace(".", "").isalnum()]
    if suites:
        return suites
    # Sem suíte válida na lane: vale o padrão do projeto, nunca o de outro projeto.
    try:
        padrao = projeto().suites
    except Exception:  # noqa: BLE001 — sem projeto: cai no legado
        padrao = []
    return list(padrao) if padrao else list(PROOF_DEFAULT_SUITES)


def proof_script(wt: Path, suites: list[str]) -> str:
    """Comando de prova das suítes, gravado em `.lane/proof.log`.

    `prova_tentativas >= 2` repete a 2ª vez sem `SKIP_PREFLIGHT` — é o que o
    `safe_xcodebuild.sh` precisa (o preflight é caro e faz a 1ª passar rápido).
    A falha da última tentativa sai com código != 0 e segue virando lane:parada.
    """
    p = projeto()

    def um(x: str) -> str:
        # O comando do cadastro é uma linha de comando e vai inteira para o shell.
        # Escapá-la (FRA-477 → 19/10) fazia o bash procurar um arquivo com o nome
        # «./scripts/safe_xcodebuild.sh test FooTests» e sair 127 em toda prova.
        comando = p.comando_prova(x)
        aviso = shlex.quote(f"[prova] {x}")
        if p.prova_tentativas < 2:
            return f"{{ echo {aviso}; {comando}; }}"
        primeira = shlex.quote(f"[prova] {x}: 1ª tentativa SKIP_PREFLIGHT=1")
        segunda = shlex.quote(f"[prova] {x}: 1ª falhou; 2ª tentativa com preflight")
        return (f"{{ echo {primeira}; "
                f"SKIP_PREFLIGHT=1 {comando} || "
                f"{{ echo {segunda}; "
                f"{comando}; }}; }}")
    loop = " && ".join(um(x) for x in suites)
    return f"cd {shlex.quote(str(wt))} && {{ {loop}; }} > .lane/proof.log 2>&1; echo $? > .lane/proof_exit"


def start_proof(wt: Path, suites: list[str]) -> None:
    """Roda o comando de prova em segundo plano, fora do terminal do agente.

    Grava .lane/proof.log e, ao final, .lane/proof_exit (0 = verde). O pid fica
    em .lane/proof_pid: o processo é líder do grupo (`start_new_session`), e
    `matar_prova` mata o grupo inteiro. O xcodebuild filho morre junto e solta
    o build lock.
    """
    lane_dir = wt / ".lane"
    lane_dir.mkdir(exist_ok=True)
    (lane_dir / "proof_exit").unlink(missing_ok=True)
    script = proof_script(wt, suites)
    proc = subprocess.Popen(["/bin/bash", "-c", script], start_new_session=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=dict(os.environ, PATH=TOOL_PATH))
    # O pid fica no arquivo e o grupo vive sozinho. Sem isto, o destrutor do
    # Popen avisa que o processo ainda roda: a gente não espera aqui.
    pid = proc.pid
    proc.returncode = 0
    (lane_dir / "proof_pid").write_text(str(pid))
    (lane_dir / "proof_started").write_text(str(time.time()))


def ler_proof_pid(lane_dir: Path) -> Optional[int]:
    try:
        pid = int((lane_dir / "proof_pid").read_text().strip())
    except (OSError, ValueError):
        return None
    return pid if pid > 0 else None


def prova_viva(pid: int) -> bool:
    """O processo ainda roda? Zumbi conta como morto: o lock já foi solto."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    if sys.platform == "linux":
        try:
            estado = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        except (OSError, IndexError):
            estado = ""
        if estado == "Z":
            try:
                os.waitpid(pid, os.WNOHANG)
            except OSError:
                pass
            return False
    try:
        waited, _status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return True
    except OSError:
        return True
    return waited != pid


def matar_prova(wt: Path) -> None:
    """Mata o grupo da prova. O build lock sai junto com o xcodebuild."""
    lane_dir = wt / ".lane"
    pid = ler_proof_pid(lane_dir)
    if pid is None:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if not prova_viva(pid):
            break
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            break
        except PermissionError:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
        for _ in range(20):
            if not prova_viva(pid):
                break
            time.sleep(0.05)
    (lane_dir / "proof_pid").unlink(missing_ok=True)


def decidir_prova_morta(lane_dir: Path) -> str:
    """'viva', 'refazer' (uma única vez) ou 'esgotou'. Sem pid, segue como viva."""
    if (lane_dir / "proof_exit").exists():
        # A prova acabou: colhe o zumbi do bash para não vazar um por card.
        pid = ler_proof_pid(lane_dir)
        if pid:
            prova_viva(pid)
        return "viva"
    pid = ler_proof_pid(lane_dir)
    if pid is None or prova_viva(pid):
        return "viva"
    if (lane_dir / "proof_morta").exists():
        return "esgotou"
    try:
        (lane_dir / "proof_morta").write_text("1", encoding="utf-8")
    except OSError:
        return "esgotou"
    return "refazer"


def acompanhar_prova(st: dict, wt: Path, suites: list[str]) -> str:
    """Estado da prova já disparada.

    'rodando': ainda no prazo. 'refeita': a prova morta começou de novo.
    'timeout', 'stop' e 'morta': o grupo já foi morto (o build lock sai com ele).
    'pronta': tem proof_exit para o veredito.
    """
    lane_dir = wt / ".lane"
    stop_file = STATE_DIR / f"stop-{st['lane']}"
    if stop_file.exists():
        stop_file.unlink(missing_ok=True)
        matar_prova(wt)
        return "stop"
    decisao = decidir_prova_morta(lane_dir)
    if decisao == "refazer":
        (lane_dir / "proof_exit").unlink(missing_ok=True)
        (lane_dir / "proof.log").unlink(missing_ok=True)
        log(f"lane:{st['lane']} {st['card']}: prova morreu sem terminar; refaz uma vez")
        start_proof(wt, suites)
        return "refeita"
    if decisao == "esgotou":
        matar_prova(wt)
        return "morta"
    if not (lane_dir / "proof_exit").exists():
        try:
            started = float((lane_dir / "proof_started").read_text() or 0)
        except (OSError, ValueError):
            started = 0.0
        if started and (time.time() - started) / 60 > PROOF_TIMEOUT_MIN:
            matar_prova(wt)
            return "timeout"
        return "rodando"
    return "pronta"


ATTEMPT_MARK = "[prova] "
# Evidência de teste vermelho: só diagnóstico de verdade (melhoria 1, 21/10/2026).
#  - `arquivo:linha:col: error: …` ou `error: …` no começo da linha (compilador, linker);
#  - teste que falhou (`Test Case … failed (`, `✘ Test … failed`), `TEST FAILED`, `BUILD FAILED`;
#  - `Executed N tests, with M failures` com M > 0 (`with 0 failures` NÃO entra).
# Trecho de código que o compilador imprime junto de um aviso (`189 |  func f(_ error: Error)`)
# nunca é evidência: em 20–21/10 o padrão antigo `(?:^|\s)error: ` casou com esses trechos
# e marcou 20 provas verdes como vermelhas («falhou … código 0»), refazendo lanes em opus.
EVIDENCIA_RE = re.compile(r"^\s*(?:.*?:\d+(?::\d+)?:\s*)?(?:fatal\s+)?error:\s"
                          r"|failed \(|✘ Test\b.*\bfailed\b|TEST FAILED|BUILD FAILED"
                          r"|Executed \d+ tests?, with [1-9]\d* failure")
TRECHO_RE = re.compile(r"^\s*\d*\s*\|")


def evidencia(linha: str) -> bool:
    """A linha prova teste vermelho? Trecho de código citado num aviso nunca prova."""
    return not TRECHO_RE.match(linha) and bool(EVIDENCIA_RE.search(linha))


def proof_attempts(wt: Path) -> list[list[str]]:
    """O `proof.log` quebrado em tentativas, na ordem em que rodaram.

    `proof_script` anuncia cada tentativa com `[prova] <suíte>: ...` antes de rodar,
    então cada tentativa é o bloco que começa num desses anúncios. Sem o bloco, o
    log inteiro é uma tentativa só (prova de 1 tentativa, ou log antigo).
    """
    try:
        lines = (wt / ".lane" / "proof.log").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    blocos: list[list[str]] = []
    for linha in lines:
        if ATTEMPT_MARK in linha:
            blocos.append([linha])
        elif blocos:
            blocos[-1].append(linha)
    return blocos or ([lines] if lines else [])


def _suite_do_bloco(bloco: list[str]) -> str:
    """`[prova] FooTests: 1ª tentativa …` → `FooTests` ("" sem anúncio)."""
    if not bloco or ATTEMPT_MARK not in bloco[0]:
        return ""
    return bloco[0].split(ATTEMPT_MARK, 1)[1].split(":", 1)[0].strip()


def ultimas_tentativas(blocos: list[list[str]]) -> list[list[str]]:
    """A última tentativa de cada suíte: é ela que decide o código de saída."""
    ult: dict = {}
    for b in blocos:
        ult[_suite_do_bloco(b)] = b
    return list(ult.values())


# E22: a prova só vale com esta linha, N>0, na última tentativa de cada suíte.
# `with 0 failures` seguido de `(0 unexpected)` também vale. `Executed 0 tests` não.
EXEC_OK_RE = re.compile(r"Executed ([1-9]\d*) tests?, with 0 failures\b")


# unittest do Python (o `scripts/testar.sh` manda `tests*` para `python3 -m unittest`):
# `Ran N tests in …` com N>0 e, depois, a linha `OK` (ou `OK (skipped=…)`).
RAN_RE = re.compile(r"^Ran ([1-9]\d*) tests? in ")
UNITTEST_OK_RE = re.compile(r"^OK(?: \(.*\))?\s*$")


def suite_provada(bloco: list[str]) -> bool:
    """A tentativa provou teste de verdade: `Executed N tests, with 0 failures` (XCTest)
    ou `Ran N tests` seguido de `OK` (unittest), sempre com N>0."""
    if any(EXEC_OK_RE.search(l) for l in bloco):
        return True
    for i, l in enumerate(bloco):
        if RAN_RE.match(l) and any(UNITTEST_OK_RE.match(x) for x in bloco[i + 1:]):
            return True
    return False


def prova_e22(wt: Path) -> bool:
    """Cada suíte, na última tentativa, provou que rodou teste de verdade."""
    blocos = ultimas_tentativas(proof_attempts(wt))
    return bool(blocos) and all(suite_provada(b) for b in blocos)


def proof_veredito(wt: Path, rc: str = "") -> str:
    """O que a prova diz de verdade: 'verde', 'vermelho', 'preflight' ou 'sem-dado'.

    Exit 0 (melhoria 1, 21/10/2026, e E22): manda o código de saída. Só vira `vermelho`
    com evidência forte na **última** tentativa de alguma suíte. Trecho de código e
    tentativa anterior que a seguinte resolveu não derrubam um exit 0. Verde só com
    `Executed N tests, with 0 failures` e N>0 em cada suíte; sem isso é `sem-prova`.

    Exit != 0, o sinal mais forte de todas as tentativas, na ordem:
    1. qualquer tentativa com erro de teste é `vermelho` — nem preflight posterior
       pode tapar teste vermelho de verdade (FRA-14);
    2. sem erro de teste, alguma tentativa barrada pelo preflight é `preflight`
       (máquina ocupada: vale repetir, não é teste vermelho);
    3. falhou sem nenhum dos dois: `vermelho` mesmo assim.
    """
    blocos = proof_attempts(wt)
    if not blocos:
        return "sem-dado"
    if rc == "0":
        if any(evidencia(l) for b in ultimas_tentativas(blocos) for l in b):
            return "vermelho"
        # Exit 0 sem a linha do E22 não é prova: log vazio ou 0 testes não fecham o card.
        if prova_e22(wt):
            return "verde"
        return "sem-prova"
    if any(evidencia(l) for b in blocos for l in b):
        return "vermelho"
    if any("abortado pelo preflight" in l for b in blocos for l in b):
        return "preflight"
    return "vermelho"


def proof_failures(wt: Path) -> str:
    """Resumo das linhas que explicam a falha, da tentativa que manda.

    Teste vermelho tem precedência sobre abort de preflight: se alguma tentativa
    deu erro de teste, o resumo mostra essa, senão o do preflight.
    """
    blocos = proof_attempts(wt)
    com_erro = [b for b in blocos if any(evidencia(l) for l in b)]
    com_preflight = [b for b in blocos if any("abortado pelo preflight" in l for l in b)]
    escolhido = com_erro[-1] if com_erro else (com_preflight[-1] if com_preflight else None)
    if escolhido is None:
        return "  - (sem linha de erro reconhecida; ver proof.log)"
    hits = [l.strip() for l in escolhido
            if evidencia(l) or "abortado pelo preflight" in l]
    return "\n".join(f"  - `{h[:200]}`" for h in hits[-10:])


def finalize(st: dict) -> Optional[str]:
    """Fecha o card. None = ainda não (a prova do dispatcher está rodando)."""
    wt = Path(st["worktree"])
    code = (wt / ".lane" / "exit_code").read_text().strip()
    res = read_result(wt)
    g = git_summary(wt, st.get("base"))

    prot = touched_protected(g["lane_files"])
    if prot:
        return fail(st, f"tocou caminho protegido ({', '.join(prot)}); nada foi enviado")
    if code == "freio":
        try:
            detalhe = (wt / ".lane" / "freio.txt").read_text(encoding="utf-8").strip()
        except OSError:
            detalhe = ""
        return fail(st, detalhe or "freio do card", causa="freio-card")
    if code.lstrip("-").isdigit() and (code != "0" or not res or res.get("status") not in ("done", "needs_dono")):
        until = account_limit(st["log"], st["lane"])
        if until:
            return reacao_ao_limite(st, until)
    if code not in ("0",):
        # O watch() grava o motivo em texto quando ele mesmo interrompe a lane.
        if not code.lstrip("-").isdigit():
            return stop(st, code)
        # Diz o porquê (ex.: error_max_turns) em vez de só o código.
        return fail(st, f"agente saiu com código {code} ({agent_outcome(st['log'])})")
    if not res or res.get("status") not in ("done", "needs_dono"):
        outcome = agent_outcome(st["log"])
        if "sessão cancelada" in outcome:
            return stop(st, f"sem .lane/result.json ({outcome})")
        return fail(st, f"sem .lane/result.json válido ({outcome})")

    if res["status"] == "needs_dono":
        # Só empurra o que a lane fez: a branch pode ter commits antigos de pessoas.
        if g["new"] > 0:
            barrado = motivo_para_nao_enviar(wt)
            if barrado:
                return fail(st, f"nada foi enviado: {barrado}")
            sh(["git", "push", "-q", "-u", "origin", f"HEAD:{st['branch']}"], cwd=wt, timeout=180)
        resume = resume_line(st)
        aplicar_label(st["issue_id"], LABEL_DONO_ID, OWNER_LABEL)
        linear(MUT_COMMENT, {"id": st["issue_id"], "body":
            f"✋ **lane:{st['lane']}** parou e precisa do dono.\n\n**Motivo:** {res.get('reason', '—')}\n\n"
            + (f"Trabalho parcial enviado na branch `{st['branch']}` ({g['sha']}).\n" if g["new"] else "")
            + (f"\n{resume}\n" if resume else "")
            + f"Para retomar: responder no card e remover a label `{OWNER_LABEL}`."})
        return OWNER_LABEL

    # done: vale a branch inteira (numa nova execução, o trabalho pode ser de uma lane anterior).
    if g["ahead"] == 0:
        return fail(st, "result=done mas nenhum commit novo na branch")
    if g["dirty"]:
        return fail(st, "result=done mas há mudanças sem commit")

    # FRA-269: a prova é do dispatcher, não do terminal do agente.
    lane_dir = wt / ".lane"
    suites = proof_suites(res)
    discard_stale_proof(lane_dir, st["card"], st.get("started", 0))
    if not (lane_dir / "proof_started").exists():
        start_proof(wt, suites)
        return None  # volta no próximo ciclo
    fase = acompanhar_prova(st, wt, suites)
    if fase in ("rodando", "refeita"):
        return None
    if fase == "timeout":
        return stop(st, f"a prova ({', '.join(suites)}) passou de {PROOF_TIMEOUT_MIN} min",
                    "- log da prova: `.lane/proof.log` no worktree\n", causa="prova-timeout")
    if fase == "stop":
        return stop(st, "parada manual (menu)", causa="parada-manual")
    if fase == "morta":
        return stop(st, "a prova morreu sem terminar e a repetição também não terminou",
                    "- log da prova: `.lane/proof.log` no worktree\n", causa="prova-morta")
    if fase != "pronta":
        raise RuntimeError(f"fase de prova desconhecida: {fase}")
    proof_rc = (lane_dir / "proof_exit").read_text().strip()
    veredito = proof_veredito(wt, proof_rc)
    if proof_rc != "0" and veredito == "preflight":
        # Mac ocupado (load/RAM): a barra nenhuma foi teste vermelho. Tenta de novo, até 3 vezes.
        tries_f = lane_dir / "proof_retries"
        tries = int(tries_f.read_text() or 0) if tries_f.exists() else 0
        if tries < 3:
            tries_f.write_text(str(tries + 1))
            (lane_dir / "proof_started").unlink(missing_ok=True)
            (lane_dir / "proof_exit").unlink(missing_ok=True)
            return None
        return stop(st, "a prova foi barrada 4 vezes pelo preflight (Mac ocupado)",
                    f"- log da prova: `{wt / '.lane' / 'proof.log'}`\n")
    if proof_rc != "0" or veredito == "vermelho":
        # Falha: código de saída não-zero OU evidência forte na última tentativa (mesmo com código 0).
        return fail(st, f"a prova do dispatcher falhou ({', '.join(suites)}, código {proof_rc})",
                    f"- resumo:\n{proof_failures(wt)}\n"
                    f"- log completo: `{wt / '.lane' / 'proof.log'}`\n", causa="prova-vermelha")
    if veredito != "verde":
        # Exit 0 com log vazio, 0 testes, ou suíte sem a linha do E22 não é DONE.
        return fail(st, "a prova não contou Executed N tests, with 0 failures (N>0) em cada suíte",
                    f"- log completo: `{wt / '.lane' / 'proof.log'}`\n", causa="prova-sem-contagem")
    res = dict(res, verification=f"dispatcher: {projeto().prova.replace('{suite}', '')}"
                                 f"{' '.join(suites)} → verde"
                                 + (f"; agente: {res['verification']}" if res.get("verification") else ""))
    barrado = motivo_para_nao_enviar(wt)
    if barrado:
        return fail(st, f"nada foi enviado: {barrado}", causa="push-barrado")
    sh(["git", "push", "-q", "-u", "origin", f"HEAD:{st['branch']}"], cwd=wt, timeout=180)

    meta = {k: res.get(k) for k in ("changed_files", "verification", "residual_risk", "decisions")}
    meta["changed_files"] = g["files"]
    body = (f"{st['card']}: {st['title']}\n\n{res.get('summary', '')}\n\n"
            f"Executado pela lane:{st['lane']} (esforço {st['effort']}).\n\n"
            f"```json\n{json.dumps(meta, ensure_ascii=False, indent=2)}\n```\n")
    # Idempotente: se o fechamento anterior caiu depois de abrir o PR, reaproveita.
    # Só PR aberto: `gh pr view <branch>` também acha PR fechado ou mergeado, e o card ia para
    # In Review apontando para ele, sem PR aberto para o vigia mergear.
    pr = sh(["gh", "pr", "view", st["branch"], "--json", "url,state", "-q",
             'select(.state == "OPEN") | .url'], cwd=wt, check=False)
    if not pr:
        pr = sh(["gh", "pr", "create", "--base", "main", "--head", st["branch"],
                 "--title", f"[{st['card']}] {st['title']}", "--body", body], cwd=wt, timeout=120)
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"DONE {g['sha']}\n\n{res.get('summary', '')}\n\nPR: {pr}\n\n"
        f"```json\n{json.dumps(meta, ensure_ascii=False, indent=2)}\n```"})
    mudar_estado(st["issue_id"], STATE_IN_REVIEW_ID)
    return f"In Review ({pr})"


def log_sem_saida(log_path: str, agora: Optional[float] = None, limite: float = LOG_PARADO_S) -> bool:
    """O log existe e não recebe saída nova há `limite` segundos?"""
    if not log_path:
        return False
    agora = time.time() if agora is None else agora
    try:
        mtime = Path(log_path).stat().st_mtime
    except OSError:
        return False
    return agora - mtime >= limite


def razao_sem_exit(st: dict, agora: Optional[float] = None) -> Optional[str]:
    """Por que a lane sem exit_code deve parar, ou None se ela segue."""
    agora = time.time() if agora is None else agora
    if (STATE_DIR / f"stop-{st['lane']}").exists():
        return "parada manual (menu)"
    if (agora - st["started"]) / 60 > LANE_TIMEOUT_MIN:
        return f"timeout de {LANE_TIMEOUT_MIN} min"
    if not tmux_alive(st["session"]):
        return "sessão tmux sumiu sem código de saída"
    if log_sem_saida(st.get("log") or "", agora):
        return "sem saída"
    return None


def watch(lane: str, st: dict) -> None:
    if st.get("stuck"):
        return  # precisa de ação humana: ver log; apagar lane-<x>.json libera a lane
    wt = Path(st["worktree"])
    exit_file = wt / ".lane" / "exit_code"
    stop_file = STATE_DIR / f"stop-{lane}"
    if not exit_file.exists() and tmux_alive(st["session"]) and not st.get("window_ok"):
        st["window_ok"] = _show_in_lanes_window(lane, st["session"], st["card"])
        save_state(lane, st)
    if not exit_file.exists():
        freio = freio_da_sessao_aberta(st)
        reason = freio or razao_sem_exit(st)
        if not reason:
            return
        # Motivo gravado ANTES de matar: o runner não sobrescreve exit_code existente.
        exit_file.parent.mkdir(exist_ok=True)
        if freio:
            (exit_file.parent / "freio.txt").write_text(f"freio do card ({freio})", encoding="utf-8")
            exit_file.write_text("freio")
        else:
            exit_file.write_text(reason)
        kill_lane_tree(st["session"])
        matar_prova(wt)
        stop_file.unlink(missing_ok=True)
    try:
        outcome = finalize(st)
        if outcome is None:
            if not st.get("proving"):
                st["proving"] = now()
                save_state(lane, st)
                log(f"lane:{lane} {st['card']}: agente terminou; prova do dispatcher em andamento")
            return
    except Exception as exc:  # noqa: BLE001
        # Mantém o estado: tenta fechar de novo no próximo ciclo (sem novo claim).
        st["finalize_errors"] = st.get("finalize_errors", 0) + 1
        save_state(lane, st)
        log(f"lane:{lane} ERRO ao fechar {st['card']} (tentativa {st['finalize_errors']}): {exc}")
        if st["finalize_errors"] < 5:
            return
        # Desistir sem marcar o card o deixaria elegível de novo (In Progress, última
        # entrada por pessoa): a lane rodaria outra vez sobre o mesmo trabalho.
        outcome = "fechamento falhou 5 vezes; ver log"
        try:
            aplicar_label(st["issue_id"], LABEL_LANE_FALHOU_ID, linear_ids.FALHOU)
            linear(MUT_COMMENT, {"id": st["issue_id"], "body":
                f"⛔ **lane:{st['lane']}** terminou, mas o dispatcher não conseguiu fechar o card "
                f"depois de 5 tentativas (último erro: {exc}).\n\n{linha_causa('fechamento')}"
                f"- log do dispatcher: `{LOG_FILE}`\n"
                f"- worktree: `{st['worktree']}`\n\nConferir o worktree e a branch, fechar à mão "
                f"e remover a label `lane:falhou`."})
            outcome += " (lane:falhou aplicada)"
        except Exception as exc2:  # noqa: BLE001
            # Sem Linear: mantém o estado e para de tentar sozinho; o card não é reassumido
            # enquanto lane-<x>.json existir (lane ocupada). O menu e o log mostram o erro.
            st["stuck"] = f"fechamento falhou 5 vezes e o Linear não respondeu: {exc2}"
            save_state(lane, st)
            log(f"lane:{lane} TRAVADA em {st['card']}: {st['stuck']}")
            return
    (wt / ".lane" / "finalized").write_text(outcome)
    # Arquiva a prova na pasta de estado antes de soltar a lane: o painel lê
    # `stale-proof-*` para o histórico e para o contador de testes do dia. Sem
    # isso a prova some quando o `lane-<lane>.json` passa a apontar para outro card.
    try:
        archive_old_proofs(wt / ".lane", st["card"])
    except Exception as exc:  # noqa: BLE001 — o fechamento não pode falhar por causa do histórico
        log(f"lane:{lane} {st['card']}: não arquivei a prova ({exc})")
    state_file(lane).unlink(missing_ok=True)
    log(f"lane:{lane} FECHOU {st['card']} → {outcome}")


def spread_auto(auto: list, measures: dict, candidates, busy, per_lane: dict,
               spend: Optional[dict] = None, max_per_lane: int = 2) -> list[tuple[dict, Optional[str]]]:
    """Distribui os cards delegados em 2 rodadas:
    1ª rodada (RUN): 1 card por lane livre (fill == 0) com folga (headroom_block).
    2ª rodada (WAIT): 1 card adicional por lane com fill < max_per_lane e
    len(per_lane[lane]) < max_per_lane - 1, sem headroom_block.
    Devolve [(card, lane|None)] na ordem de prioridade."""
    ok = sorted((l for l in candidates
                 if pct_para_ordem(measures.get(l)) is not None),
                key=lambda l: (pct_para_ordem(measures.get(l)), l))
    if not ok:
        if spend is None:
            spend = week_spend()
        ok = sorted(candidates, key=lambda l: (spend.get(l, 0.0), l))
    if not ok:
        return []
    # fill[l] = cards já atribuídos à lane (rodando + esperando)
    fill = {l: len(per_lane.get(l, [])) + (1 if l in busy else 0) for l in candidates}
    out = []
    # Rodada 1: RUN - cada lane com fill == 0 e headroom_block OK
    for it in sorted(auto, key=sort_key):
        effort = it.get("_effort") or EFFORT_DEFAULT
        fit_run = [l for l in ok if fill[l] == 0 and not headroom_block(l, effort, measures)
                   and not card_banido_da_lane(l, it.get("identifier", ""), it.get("_effort") or "")]
        if not fit_run:
            continue
        lane = fit_run[0]
        fill[lane] += 1
        per_lane.setdefault(lane, []).append(it)
        out.append((it, lane))
    # Rodada 2: WAIT - lanes com fill < max_per_lane (sem headroom_block)
    for it in sorted(auto, key=sort_key):
        if any(o[0] is it for o in out):
            continue
        effort = it.get("_effort") or EFFORT_DEFAULT
        fit_wait = [l for l in ok if fill[l] < max_per_lane
                    and not card_banido_da_lane(l, it.get("identifier", ""), it.get("_effort") or "")]
        if not fit_wait:
            out.append((it, None))
            continue
        lane = fit_wait[0]
        fill[lane] += 1
        per_lane.setdefault(lane, []).append(it)
        out.append((it, lane))
    return out


def assign_auto_lanes(auto: list, per_lane: dict, candidates, real: bool, busy=(),
                      max_per_lane: int = MAX_PER_LANE) -> list[str]:
    """Escolhe a lane dos cards delegados sem lane (esforço sem lane). Uma medida por
    ciclo. Real: aplica a label (é a atribuição) e põe o card na fila da lane. Sem
    candidatas, a etiqueta do dono (`linear.owner_label`) com o motivo. Simulação: só registra."""
    if not auto:
        return []
    if not candidates:
        return [f"auto: {', '.join(i['identifier'] for i in auto)} aguardam (nenhuma lane habilitada)"]
    measures, raw = measure_lanes(renew=real)
    lane, shown = pick_lane(measures, candidates)
    ids = ", ".join(i["identifier"] for i in auto)
    if lane is None:
        if real:
            for it in auto:
                aplicar_label(it["id"], LABEL_DONO_ID, OWNER_LABEL)
                linear(MUT_COMMENT, {"id": it["id"], "body":
                    f"✋ O dispatcher não conseguiu escolher a lane: nenhuma candidata "
                    f"com peso ({shown}). Renove abrindo os CLIs das lanes no Terminal "
                    f"e remova a label `{OWNER_LABEL}`."})
        return [f"auto: {ids} sem lane ({shown})" + (f" → {OWNER_LABEL}" if real else "")]
    out = []
    for it, ln in spread_auto(auto, measures, candidates, set(busy), per_lane,
                              max_per_lane=max_per_lane):
        if ln is None:
            out.append(f"{it['identifier']} aguarda folga na conta (nenhuma lane com medida "
                       f"abaixo do teto do esforço `{it.get('_effort') or EFFORT_DEFAULT}`; "
                       f"janela longa afrouxa o teto)")
            continue
        it["_measure"] = f"{shown} → `{ln}`"
        if real:
            label_id = LABEL_LANE_IDS.get(ln)
            if label_id:
                aplicar_label(it["id"], label_id, "lane")
            else:
                log(f"lane:{ln} sem label no Linear (LABEL_LANE_IDS); segue sem aplicar label")
        per_lane[ln].append(it)
        out.append(f"{it['identifier']} → lane:{ln}")
    return [f"auto: {', '.join(out)} ({shown})"]


def motivo_que_segura_todo(issue: dict) -> Optional[str]:
    """Por que o card não sobe do Todo. None = pode subir.

    Segura bloqueio aberto, título BLOQUEADA e label que trava a fila
    (a etiqueta do dono, `lane:falhou`, `lane:parada`).
    """
    if "BLOQUEADA" in (issue.get("title") or "").upper():
        return "título contém BLOQUEADA"
    nomes = {l.get("name") for l in (issue.get("labels") or {}).get("nodes") or [] if l.get("name")}
    hit = BLOCKING_LABELS & nomes
    if hit:
        return f"label {sorted(hit)[0]}"
    abertos = []
    for rel in (issue.get("inverseRelations") or {}).get("nodes") or []:
        if rel.get("type") != "blocks":
            continue
        issue_rel = rel.get("issue") or {}
        if (issue_rel.get("state") or {}).get("type") == "completed":
            continue
        ident = issue_rel.get("identifier")
        if ident:
            abertos.append(ident)
    if abertos:
        return f"blockedBy aberto: {', '.join(abertos)}"
    return None


def lanes_ociosas(lanes_on, running, limited, per_lane) -> list[str]:
    """Lanes ligadas, sem card rodando, sem limite de uso e com a fila vazia."""
    return [lane for lane in LANES
            if lane in lanes_on and lane not in running and lane not in limited
            and not per_lane.get(lane)]


def escolher_do_todo(cards: list, vagas: list[str], medidas: Optional[dict] = None) -> list:
    """Até um card por vaga: o de maior prioridade que uma lane ociosa pode receber.

    Card com lane própria só sobe se essa lane está na lista de vagas **e** tem
    cota para o esforço. Card sem lane (só esforço) sobe se alguma vaga tem cota
    para o esforço; a lane final continua sendo a de menor %.
    """
    if not vagas:
        return []
    livres = set(vagas)
    prontos = []
    for card in cards:
        if motivo_que_segura_todo(card):
            continue
        lane, effort, why = classify(card)
        if why or not lane:
            continue
        if lane != AUTO_LANE and lane not in livres:
            continue
        if medidas is not None:
            if lane == AUTO_LANE:
                if not any(fila.cota_ok(candidata, effort, medidas) for candidata in livres):
                    continue
            elif not fila.cota_ok(lane, effort, medidas):
                continue
        prontos.append(card)
    return sorted(prontos, key=sort_key)[:len(vagas)]


def subir_do_todo(auto: list, per_lane: dict, lanes_on, running, limited, project_id: str,
                  medidas: Optional[dict] = None) -> list[str]:
    """Com lane ociosa, sobe do Todo o card pronto. Não depende da vigia nem do PAUSE dos bots."""
    vagas = lanes_ociosas(lanes_on, running, limited, per_lane)
    if not vagas:
        return []
    try:
        todos = linear(QUERY_CANDIDATES, {"project": project_id, "state": STATE_TODO_ID})["issues"]["nodes"]
        atualizar_cache_titulos(todos)
    except Exception as exc:  # noqa: BLE001
        log(f"fila: não li o Todo ({exc})")
        return []
    linhas = []
    for it in escolher_do_todo(todos, vagas, medidas):
        ident = it.get("identifier") or "?"
        try:
            mudar_estado(it["id"], STATE_IN_PROGRESS_ID)
            linear(MUT_COMMENT, {"id": it["id"], "body":
                f"▶️ Fila: **{ident}** subiu do Todo para In Progress ({now()}) "
                f"porque havia lane ociosa. A lane segue sendo a de menor %."})
        except Exception as exc:  # noqa: BLE001
            log(f"fila: {ident} não subiu do Todo ({exc})")
            continue
        it["_projeto"] = projeto().nome
        lane, effort, why = classify(it)
        if why or not lane:
            linhas.append(f"fila: {ident} subiu do Todo mas ficou de fora ({why})")
            continue
        it["_effort"] = effort
        if lane == AUTO_LANE:
            auto.append(it)
        else:
            per_lane.setdefault(lane, []).append(it)
        linhas.append(f"fila: {ident} sobe do Todo (lane ociosa)")
    return linhas


def subir_do_todo_com_lock(auto: list, per_lane: dict, lanes_on, running, limited, project_id: str,
                            medidas: Optional[dict] = None) -> list[str]:
    """Serializa a decisão de fila com o vigia (mesmo fila.lock do outro processo)."""
    lock_path = STATE_DIR / "fila.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("fila: outra decisão em andamento; pulo o Todo neste ciclo")
            return []
        try:
            return subir_do_todo(auto, per_lane, lanes_on, running, limited, project_id, medidas)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


# --- Ciclo ------------------------------------------------------------------
# Mac acordado: caffeinate com tempo (2 ciclos de 60 s), renovado a cada ciclo com trabalho.
# Sem trabalho, não renova e ele expira sozinho. Sem pmset nem sudo.
CAFFEINATE_BIN = "/usr/bin/caffeinate"
CAFFEINATE_SECONDS = 150
CAFFEINATE_PID_FILE = STATE_DIR / "caffeinate.pid"


def keep_awake(has_work: bool) -> None:
    old_pid = None
    if CAFFEINATE_PID_FILE.exists():
        try:
            old_pid = int(CAFFEINATE_PID_FILE.read_text().strip())
        except ValueError:
            old_pid = None
    if not has_work:
        if old_pid is not None:
            CAFFEINATE_PID_FILE.unlink(missing_ok=True)
            log("liberado: sem trabalho, caffeinate expira sozinho")
        return
    proc = subprocess.Popen([CAFFEINATE_BIN, "-i", "-s", "-t", str(CAFFEINATE_SECONDS)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    CAFFEINATE_PID_FILE.write_text(str(proc.pid))
    if old_pid is not None:
        try:
            os.kill(old_pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    else:
        log(f"mantendo acordado: caffeinate {proc.pid} por {CAFFEINATE_SECONDS} s, renovado a cada ciclo")


def run(real: bool, verbose: bool) -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not app_aberta():
        # Boot sem o app, ou app encerrado/caiu: interrompe o que tiver ficado e sai.
        for lane in LANES:
            st = load_state(lane)
            if st:
                try:
                    kill_lane_tree(f"lane-{lane}")
                except Exception:  # noqa: BLE001 — limpeza de saída não pode derrubar o launchd
                    pass
        return 0
    projetos.recarregar()   # cadastro lido uma vez por ciclo: mexer na config vale no ciclo seguinte
    if not projetos.configurado():
        aviso = "sem projeto: cadastre um em Ajustes › Avançado › Projetos (chave `projetos` da config)"
        previous = MODE_FILE.read_text().strip() if MODE_FILE.exists() else ""
        if previous != aviso:
            log(aviso)
            MODE_FILE.write_text(aviso)
        return 0
    lanes_on, ignored = effective_lanes(enabled_lanes()) if real else (set(), [])
    try:
        prev_at = json.loads(HEARTBEAT_FILE.read_text()).get("at") if HEARTBEAT_FILE.exists() else None
    except (OSError, ValueError, AttributeError):
        prev_at = None
    gap = wake_gap_line(prev_at, dt.datetime.now())
    if gap and real:
        busy = [f"lane:{l} com {st['card']}" for l in LANES if (st := load_state(l))]
        log(gap + (f"; em andamento: {', '.join(busy)} (se a sessão caiu, o card volta como lane:parada "
                   "e a triagem devolve à fila)" if busy else ""))
    if real:
        garantir_ids()
        atualizar_privacidade()
        atualizar_listas_modelos()
    HEARTBEAT_FILE.write_text(json.dumps({"at": now(), "dry_run": not real,
                                          "enabled": sorted(lanes_on),
                                          "project": projeto().id,
                                          "project_name": projeto().nome,
                                          "implemented": [l for l in LANES if lane_runnable(l)]}))
    mode = (f"{'real' if real else 'simulação'} · projeto: {projeto().nome} · "
            f"lanes: {', '.join(sorted(lanes_on)) or 'nenhuma'}")
    previous_mode = MODE_FILE.read_text().strip() if MODE_FILE.exists() else ""
    if mode != previous_mode:
        log(f"MODO {mode}" + (f" (habilitada sem execução real, ignorada: {', '.join(ignored)})" if ignored else ""))
        MODE_FILE.write_text(mode)

    if real:
        for lane in LANES:
            # Uma lane com erro (estado ilegível, tmux, janela) não pode impedir as outras
            # de fechar nem a fila de andar.
            try:
                st = load_state(lane)
                if st:
                    watch(lane, st)
            except Exception as exc:  # noqa: BLE001
                log(f"lane:{lane} ERRO ao acompanhar: {type(exc).__name__}: {exc}")

    if PAUSE_FILE.exists():
        lines = ["PAUSE presente: nenhum claim novo"]
        to_claim: list[tuple[str, dict, str, str]] = []
    else:
        proj = projeto()
        issues = linear(QUERY_CANDIDATES, {"project": proj.id,
                                           "state": STATE_IN_PROGRESS_ID})["issues"]["nodes"]
        atualizar_cache_titulos(issues)
        # O nome do projeto entra em cada card: um card que sobrou de outro projeto
        # fica visível no log em vez de sumir sem explicação.
        for it in issues:
            it["_projeto"] = proj.nome
        busy = {s["card"] for s in (load_state(l) for l in LANES) if s}
        per_lane: dict[str, list[dict]] = {l: [] for l in LANES}
        excluded: list[str] = []
        auto: list[dict] = []
        for it in issues:
            lane, effort, why = classify(it)
            if not why and it["identifier"] in busy:
                why = "em execução"
            if why:
                excluded.append(f"{it['identifier']} ({why})")
            else:
                it["_effort"] = effort
                # FRA-516: grava a label de esforço no Linear quando classificado automaticamente
                if it.get("_esforco_automatico") and real:
                    # Verifica se já tem label de esforço
                    tem_effort = any((l.get("parent") or {}).get("name") == LABEL_GROUP_EFFORT
                                     for l in it.get("labels", {}).get("nodes", []))
                    if not tem_effort and effort in LABEL_EFFORT_IDS:
                        try:
                            aplicar_label(it["id"], LABEL_EFFORT_IDS[effort], f"esforco/{effort}")
                            linear(MUT_COMMENT, {"id": it["id"], "body":
                                f"⚖️ Peso automático: `{effort}` (regra + Ollama). "
                                f"Motivo: {it.get('_esforco_motivo', '—')}"})
                        except Exception:  # noqa: BLE001
                            pass
                (auto if lane == AUTO_LANE else per_lane[lane]).append(it)

        # FRA-269: card delegado sem lane recebe a lane mais leve, medida agora.
        running_lanes = {l for l in LANES if load_state(l)}
        limited = {l: u for l in LANES if (u := lane_limited(l))}
        # FRA-515: lane ociosa puxa o Todo sem esperar a vigia. A escolha da lane
        # continua sendo a de menor % (assign_auto_lanes / pick_lane). A mesma
        # medida agora barra card cujo esforço não tem folga.
        measures: Optional[dict] = measures_cached(real) if real else None
        fila_linhas = (subir_do_todo_com_lock(auto, per_lane, lanes_on, running_lanes, limited, proj.id,
                                              medidas=measures)
                       if real else [])
        freio_linhas = retirar_travados(auto, per_lane, real)
        cands = (lanes_on if real else set(LANES)) - set(limited)
        auto_lines = assign_auto_lanes(auto, per_lane, cands, real, busy=running_lanes,
                                       max_per_lane=MAX_PER_LANE)
        lines, to_claim = [], []
        lines.extend(fila_linhas)
        lines.extend(freio_linhas)
        for lane in LANES:
            queue = sorted(per_lane[lane], key=sort_key)
            running = load_state(lane)
            if running:
                    espera = [i["identifier"] for i in queue]
                    if espera:
                        lines.append(f"lane:{lane} ocupada com {running['card']} "
                                   f"(espera: {', '.join(espera)})")
                    else:
                        lines.append(f"lane:{lane} ocupada com {running['card']}")
                    continue
            if lane in limited:
                waiting_ids = ", ".join(i["identifier"] for i in queue) or "nenhum card"
                lines.append(f"lane:{lane} em limite da conta até {hhmm(limited[lane])} "
                             f"(aguardando: {waiting_ids})")
                continue
            if not queue:
                lines.append(f"lane:{lane} livre → fila vazia: precisa de card pronto "
                             f"(In Progress com lane ou esforço)")
                continue
            top = queue[0]
            if lane in lanes_on:
                if measures is None:
                    measures = measures_cached(real)
                block = headroom_block(lane, top["_effort"], measures)
                if block:
                    lines.append(f"lane:{lane} segura {top['identifier']}: {block}; mede de novo a cada "
                                 f"{MEASURE_CACHE_S // 60} min")
                    continue
                pblock = privacy_block(lane, top["_effort"])
                if pblock:
                    lines.append(f"lane:{lane} segura {top['identifier']}: privacidade — {pblock}")
                    continue
            flags = " ".join(flags_da_lane(lane, top["_effort"]))
            rest = ", ".join(i["identifier"] for i in queue[1:]) or "—"
            verb = "ASSUME" if lane in lanes_on else "ASSUMIRIA"
            lines.append(f"lane:{lane} → {verb} {top['identifier']} "
                         f"(esforço {top['_effort']}: {flags}; branch {top['branchName']}); fila: {rest}")
            if lane in lanes_on:
                to_claim.append((lane, top, top["_effort"], top.get("_measure", "")))
        lines += auto_lines
        lines.append("fora: " + ("; ".join(excluded) if excluded else "—"))

    digest = hashlib.sha256("\n".join(lines).encode()).hexdigest()
    previous = LAST_DECISION_FILE.read_text().strip() if LAST_DECISION_FILE.exists() else ""
    if digest != previous or verbose:
        prefix = "" if real else "[SIMULAÇÃO] "
        for line in lines:
            log(prefix + line)
        LAST_DECISION_FILE.write_text(digest)

    for lane, issue, effort, measure in to_claim:
        try:
            claim(lane, issue, effort, measure)
        except Exception as exc:  # noqa: BLE001
            log(f"lane:{lane} ERRO no claim de {issue['identifier']}: {exc}")
            st = load_state(lane)
            if st and st.get("card") == issue["identifier"]:
                state_file(lane).unlink(missing_ok=True)
            try:
                aplicar_label(issue["id"], LABEL_LANE_FALHOU_ID, linear_ids.FALHOU)
                linear(MUT_COMMENT, {"id": issue["id"], "body":
                    f"⛔ **lane:{lane}** não conseguiu assumir o card: {exc}\n\n{linha_causa('claim')}"})
            except Exception:  # noqa: BLE001
                pass
    if real:
        has_work = any(load_state(l) for l in LANES) or bool(to_claim) or any(
            "ASSUME" in line for line in lines)
        try:
            keep_awake(has_work)
        except Exception as exc:  # noqa: BLE001
            log(f"ERRO no caffeinate: {exc}")
    return 0


# --- Classificação automática de esforço (FRA-516) ----------------------------
# Etapa 1: regra determinística. Olha as áreas citadas, os caminhos sensíveis
# (Watch, HealthKit, erase, dispatcher, LGPD, privacidade) e se o card é UI nova
# ou só texto e testes. Devolve ("baixo"|"medio"|"alto", motivo, em_duvida).
AREAS_SENSIVEIS = (
    "watch", "healthkit", "erase", "dispatcher", "lgpd", "privacidade",
    "segurança", "security", "keychain", "criptografia", "aes",
)
AREAS_UI = ("ui", "tela", "painel", "janela", "notch", "pílula", "pilula",
            "layout", "dashboard", "nova tela", "nova janela")
AREAS_TEXTO = ("docs", "documentação", "doc", "readme", "texto", "comentário",
               "renomear", "rename", "typo", "ortografia")
AREAS_TESTE = ("teste", "test", "unitário", "unitario", "spec", "cobertura")


def classificar_esforco_por_regra(titulo: str, descricao: str) -> tuple[str, str, bool]:
    """Regra determinística de classificação de esforço.

    Devolve (esforço, motivo, em_duvida). `em_duvida` é True quando a regra
    não tem sinal forte e o Ollama deve ser consultado (Etapa 2).
    """
    titulo_low = (titulo or "").lower()
    desc_low = (descricao or "").lower()

    alto_kw = [
        "painel", "dashboard", "layout", "provedor", "provider",
        "copilot", "gemini", "integração", "integracao", "integrate",
        "novo painel", "nova tela", "nova janela", "refeita", "refazer",
        "refactor", "refator", "frase nova", "vermelho não é preflight",
    ]
    medio_kw = [
        "dispatcher", "freio", "vigia", "classificação", "classificacao",
        "modelo", "modelos", "privacidade", "privac", "tela builds",
        "builds", "lock", "fila", "filas", "esforço", "esforco",
        "verificador", "promoção", "promocao", "ollama", "triagem",
        "frase", "vermelho", "preflight", "caminho protegido",
    ]
    baixo_kw = [
        "test_", "teste", "test ", "test", "unitário", "unitario", "spec",
        "tirar", "remover", "renomear", "rename", "typo", "docs",
        "documentação", "documentacao", "readme", "ajuste", "simples",
        "pequeno", "minor", "fix", "corrigir typo", "pílula", "pilula",
    ]
    tem_teste_kw = any(k in titulo_low for k in ("test_", "teste", "test ", "test", "spec", "unitário", "unitario"))
    sensivel = [a for a in ("watch", "healthkit", "erase", "lgpd", "keychain",
                            "criptografia", "aes", "segurança", "security")
                if a in titulo_low and not (a == "watch" and tem_teste_kw)]

    # Título tem peso 2, descrição tem peso 1 (só para medio)
    alto_hits = (sum(2 for k in alto_kw if k in titulo_low) +
                 len(sensivel) * 2)
    medio_hits = (sum(2 for k in medio_kw if k in titulo_low) +
                  sum(1 for k in medio_kw if k in desc_low and k not in titulo_low))
    baixo_hits = sum(2 for k in baixo_kw if k in titulo_low)

    # Descrição longa aumenta a complexidade
    if len(descricao or "") > 500:
        medio_hits += 1

    # Decisão: título tem mais peso
    if alto_hits >= 2:
        return "alto", f"sinais de alto: {alto_hits}", False
    if alto_hits >= 1 and medio_hits == 0 and baixo_hits == 0:
        return "alto", f"sinal de alto: {alto_hits}", False
    if baixo_hits >= 3 and alto_hits == 0 and medio_hits == 0:
        return "baixo", f"sinais de baixo: {baixo_hits}", False
    if baixo_hits >= 2 and alto_hits == 0 and medio_hits <= 1:
        return "baixo", f"sinal de baixo: {baixo_hits}", False
    if medio_hits >= 2 and alto_hits == 0:
        return "medio", f"sinais de medio: {medio_hits}", False
    if alto_hits >= 1 and medio_hits >= 1 and alto_hits > baixo_hits:
        return "alto", f"alto({alto_hits}) + medio({medio_hits})", False
    if medio_hits >= 1 and alto_hits == 0:
        return "medio", f"sinais de medio: {medio_hits}", False

    # Sem sinal forte → medio, em dúvida
    return "medio", "sem sinal forte (default)", True


def classificar_esforco_com_ollama(titulo: str, descricao: str, timeout: int = 30) -> Optional[str]:
    """Etapa 2: consulta Ollama como segunda opinião. Devolve 'baixo'/'medio'/'alto' ou None."""
    try:
        import urllib.request
        prompt = (
            "Classifique o esforço de implementação deste card em uma única palavra: "
            "baixo, medio ou alto. Responda só a palavra.\n\n"
            f"Título: {titulo}\nDescrição: {descricao[:500]}"
        )
        body = json.dumps({"model": "qwen2.5-coder:7b", "prompt": prompt, "stream": False}).encode()
        req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=body, method="POST",
                                    headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
            resposta = (data.get("response") or "").strip().lower()
            for nivel in ("alto", "medio", "baixo"):
                if nivel in resposta:
                    return nivel
    except Exception:  # noqa: BLE001
        pass
    return None


def classificar_esforco(titulo: str, descricao: str) -> tuple[str, str]:
    """Orquestra: regra determinística → se em dúvida, Ollama → fallback para regra.

    Devolve (esforço, motivo)."""
    nivel, motivo, em_duvida = classificar_esforco_por_regra(titulo, descricao)
    if em_duvida:
        ollama = classificar_esforco_com_ollama(titulo, descricao)
        if ollama:
            return ollama, f"Ollama: {ollama} (regra em dúvida: {motivo})"
    return nivel, motivo


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="só registra o que faria")
    mode.add_argument("--real", action="store_true", help="assume cards nas lanes de ~/.transcentia/lanes/enabled")
    ap.add_argument("--verbose", action="store_true", help="registra mesmo sem mudança de decisão")
    args = ap.parse_args()
    try:
        return run(real=args.real, verbose=args.verbose)
    except (urllib.error.URLError, TimeoutError) as exc:
        log(f"ERRO de rede: {exc}")  # transitório: o próximo ciclo tenta de novo
        return 1
    except Exception as exc:  # noqa: BLE001 — nunca derrubar o launchd em silêncio
        log(f"ERRO: {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
