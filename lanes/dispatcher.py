#!/usr/bin/env python3
"""Dispatcher das lanes automáticas do TranscentIA.

Roda a cada 60 s via launchd (com.transcentia.lanes.dispatcher).

  --dry-run  só registra o que assumiria (padrão do plist até a titular ligar)
  --real     assume cards nas lanes habilitadas em ~/.transcentia/lanes/enabled

Divisão de trabalho (E3):
  dispatcher  lê o card, cria o worktree, abre a lane no tmux e, ao final,
              faz push para a URL do cadastro e abre o PR em rascunho. O card só
              vai para In Review quando o check remoto `prova-remota` está verde
              no SHA completo. Prova local e comentário DONE não autorizam essa passagem.
  agente      edita, testa, faz commit LOCAL e grava .lane/result.json.
              Não fala com Linear nem GitHub. A prova, o exit_code e o
              agent_cmd ficam fora do worktree (FRA-595).

Fonte da verdade: este repo (`tuttidash`), `lanes/`.
O launchd executa a cópia no bundle assinado
(`TuttiDash.app/Contents/Resources/controle/lanes/`), não `~/.transcentia`.
O estado (enabled, heartbeat, lane-*.json) continua em `~/.transcentia/lanes`.
O repo do app é só o que a lane edita — qual é, e a prova de cada um, sai do
cadastro `projetos` da config (`gasto_lanes/projetos.py`), lido a cada ciclo.
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
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

# A pasta deste arquivo entra primeiro: lanes_window.py sai daqui (repo ou
# bundle). Os módulos ficam em ../gasto_lanes (bundle assinado ou o repo).
# ~/.transcentia não entra no sys.path — nem antes, nem como reserva (FRA-615).
_AQUI = Path(__file__).resolve().parent


def _ativar_modulos() -> Path:
    """`gasto_lanes/` do bundle assinado, ou o do repo. Nunca `~/.transcentia`.

    Igual em `bots/watch.py` e `lanes/lanes_window.py`. Sem `catalogo.py`
    nessa pasta, o import fecha: a cópia gravável não é consultada.
    """
    aqui = Path(__file__).resolve().parent
    pasta = (aqui.parent / "gasto_lanes").resolve()
    catalogo = (pasta / "catalogo.py").resolve()
    if ".transcentia" in str(pasta) or ".transcentia" in str(catalogo) or not catalogo.is_file():
        sys.exit("catalogo não está no bundle; import recusado")
    for nome in ("projetos.py", "privacidade.py", "linear_ids.py", "fila.py", "config.py",
                 "proxy_linear.py", "gasto_privado.py"):
        arq = pasta / nome
        if not arq.exists():
            continue
        if ".transcentia" in str(arq.resolve()):
            sys.exit(f"{nome} não está no bundle; import recusado")

    def suspeito(p: str) -> bool:
        if ".transcentia" in p:
            return True
        if p == "":
            try:
                return ".transcentia" in str(Path.cwd().resolve())
            except OSError:
                return True
        return False

    resto = [p for p in sys.path if p not in (str(aqui), str(pasta)) and not suspeito(p)]
    sys.path[:] = [str(aqui), str(pasta), *resto]
    return pasta


_ativar_modulos()
import permissao  # noqa: E402  glob de Bash do CLI (um só lugar)
import lanes_window  # noqa: E402  janela única das lanes
try:
    import catalogo  # noqa: E402
    import fila  # noqa: E402
    import linear_ids  # noqa: E402
    import projetos  # noqa: E402
    import proxy_linear  # noqa: E402  token do Linear fica no proxy (FRA-607)
except ModuleNotFoundError as _falta:  # pragma: no cover - bundle incompleto
    sys.exit(f"{_falta.name} não está no bundle; import recusado")
try:
    import privacidade  # noqa: E402  privacidade por modelo do OpenCode (21/10/2026)
except ModuleNotFoundError:  # pragma: no cover - sem o módulo: lanes do OpenCode ficam fechadas
    privacidade = None

# --- Workspace Linear ---------------------------------------------------------
# Nenhum id no código (FRA-565): vêm da config (`linear.*`), do cache
# `~/.transcentia/lanes/linear-ids.json` ou da API, pelo nome (`garantir_ids()`, no
# começo de cada ciclo real). Sem id, a etiqueta ou o estado é pulado, com aviso no log.
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
           for nivel, m in (catalogo.catalogo().get(catalogo.perfil_da_lane(lane), {})
                            .get("modelos") or {}).items()}
    for lane in LANES
}   # instância: as flags do manifesto do agente dela (PRD lanes-v2)
# Teto de gasto por execução (USD). Estourou -> lane:falhou com o motivo.
BUDGET_USD = {"baixo": 3, "medio": 8, "alto": 20}
# Grok não tem teto em dólar: o limite é de turnos.
GROK_MAX_TURNS = {"baixo": 30, "medio": 60, "alto": 100}
# dsh (DeepSeek Harness): peso -> reasoningEffort do modelo. O CLI não recebe
# `--effort`; o dispatcher grava um patch de perfil por execução (deepseek_patch).
DSH_ESFORCO = {"baixo": "low", "medio": "high", "alto": "max"}
DSH_ESFORCOS_VALIDOS = {"off", "minimal", "low", "medium", "high", "xhigh", "max"}
# Risco alto sem lane explícita prefere estas lanes (mesma preferência do vigia).
RISCO_ALTO_LANES = {"claude", "grok"}


def risco_alto(lane: str) -> bool:
    """Lane preferida para risco alto: pelo nome ou pelo agente (instância `claude-sonnet`)."""
    return lane in RISCO_ALTO_LANES or catalogo.perfil_da_lane(lane) in RISCO_ALTO_LANES
# Teto de cards por lane ativa: 1 RUN + (MAX_PER_LANE - 1) WAIT.
# Deve bater com tools/cfg DEFAULTS["watch"]["max_tarefas_por_lane"].
MAX_PER_LANE = 2
# Ferramentas embutidas do Grok que a lane pode usar (--tools). FRA-598: arquivo
# e o terminal (git add/commit/status/diff). Fora da lista ficam agendador,
# subagentes, monitor e web. use_tool/search_tool/workflow/ask_user_question não
# saem com --tools, mas qualquer chamada a eles cancela a sessão sem executar
# (testado em 2026-10-03, grok 1.0.41).
GROK_TOOLS = ["run_terminal_command", "read_file", "search_replace", "write", "list_dir",
              "grep", "todo_write"]
# dontAsk: o que não está no allow não roda. acceptEdits aprovava edição em
# qualquer caminho (FRA-598).
MODO_PERMISSAO = "dontAsk"
# Perfil do Grok (`--sandbox lane`). `strict` lê o worktree, o sistema e
# ~/.grok. O deny tapa ssh, gh, transcentia e o binário de senhas. Não nega
# ~/.grok/auth.json: o processo precisa dele para autenticar. O token fica
# fora do agente pelo deny Read/Grep/Edit/Write de **/.grok/** (o `~` numa
# regra de permissão casa o caractere, não a home), pelo glob que pega
# -F, --file e --no-index em qualquer posição, e por sort.
# O texto do perfil fica em permissao.py: este arquivo não cita o binário.
PERFIL_SANDBOX = "lane"
PERFIL_SANDBOX_TOML = permissao.PERFIL_SANDBOX_TOML
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
# FRA-611. O mesmo nome do check que o workflow publica (FRA-610).
# A prova local em `.lane/proof_*` não autoriza In Review.
NOME_CHECK_REMOTO = "prova-remota"
# O workflow corta em 30 min. Aqui cabe a fila do runner e a execução.
ESPERA_PROVA_REMOTA_S = 45 * 60
_SHA_COMPLETO = re.compile(r"[0-9a-f]{40}")
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
def _caminho_cfg() -> Path:
    """`tools/cfg` do checkout, ou a cópia instalada. O cfg usa o resolvedor único."""
    local = Path(__file__).resolve().parent.parent / "tools" / "cfg"
    if local.is_file():
        return local
    return Path.home() / ".transcentia" / "tools" / "cfg"


def _cfg(chave, padrao):
    """Lê o `cfg` (FRA-295); sem cfg ou com erro, devolve o padrão."""
    try:
        import runpy
        v = runpy.run_path(str(_caminho_cfg()))["get"](chave, padrao)
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


def caminho_runner() -> Path:
    """`run_lane.sh` ao lado deste arquivo (repo ou bundle). Não usa ~/.transcentia."""
    return _AQUI / "run_lane.sh"


def caminho_comando_janela() -> Path:
    """`lanes.command` do bundle ou do repo. A cópia em ~/.transcentia só entra
    se o arquivo ao lado não existir (instalação antiga da ferramenta)."""
    ao_lado = _AQUI.parent / "tools" / "lanes.command"
    if ao_lado.is_file() and ".transcentia" not in str(ao_lado):
        return ao_lado
    return HOME / ".transcentia" / "tools" / "lanes.command"


LANES_COMMAND = caminho_comando_janela()
APP_PID = STATE_DIR / "app.pid"
VIEWER_FILE = STATE_DIR / "viewer-id"


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
# FRA-608: ~/.local/bin é gravável e não pode ficar na frente de git/gh/tmux.
# O diretório continua no fim, para um CLI instalado ali ainda ser achado.
_BINS_CONFIAVEIS = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin")
TOOL_PATH = ":".join((*_BINS_CONFIAVEIS, "/usr/sbin", "/sbin", f"{HOME}/.local/bin"))
_SESSAO_RE = re.compile(r"^[A-Za-z0-9._:-]+$")


def ferramenta(nome: str) -> str:
    """Caminho absoluto fora de diretório gravável. Sem achar, fica em /usr/bin."""
    for pasta in _BINS_CONFIAVEIS:
        caminho = os.path.join(pasta, nome)
        if os.path.isfile(caminho) and os.access(caminho, os.X_OK):
            return caminho
    return f"/usr/bin/{nome}"


GIT = ferramenta("git")
GH = ferramenta("gh")
TMUX = ferramenta("tmux")


def sessao_citavel(sid: str) -> bool:
    return bool(sid) and _SESSAO_RE.fullmatch(sid) is not None


def _privar(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _apertar_casa() -> None:
    """0700 na pasta de estado e em ~/.transcentia, quando o estado mora ali."""
    estado = STATE_DIR
    estado.mkdir(parents=True, exist_ok=True)
    pastas = [estado]
    for pai in estado.parents:
        if pai.name == ".transcentia":
            pastas.append(pai)
            break
    for pasta in pastas:
        try:
            os.chmod(pasta, 0o700)
        except OSError:
            pass


def _trava_ciclo():
    """Lock exclusivo, sem esperar. None se outro ciclo já segura dispatcher.lock."""
    _apertar_casa()
    path = STATE_DIR / "dispatcher.lock"
    fh = open(path, "a")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fh.close()
        return None
    _privar(path)
    return fh

# Textos fixos da allowlist do proxy (FRA-607). O script não escolhe a consulta.
QUERY_CANDIDATES = proxy_linear.consulta("candidatos")
QUERY_ISSUE = proxy_linear.consulta("card")
MUT_COMMENT = proxy_linear.consulta("comentar")
MUT_STATE = proxy_linear.consulta("mudar_estado")
MUT_LABEL = proxy_linear.consulta("adicionar_etiqueta")
MUT_REMOVE_LABEL = proxy_linear.consulta("remover_etiqueta")


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


def ambiente_git() -> dict[str, str]:
    """Ambiente dos comandos git, sem diretório nem config injetados.

    `GIT_DIR` e `GIT_WORK_TREE` trocariam o repositório. `GIT_CONFIG_*` (arquivo,
    global, system, contagem ou o par chave/valor) aplica config que o guard não
    leu do disco da pasta.
    """
    env = dict(os.environ)
    env["PATH"] = TOOL_PATH
    env["GIT_TERMINAL_PROMPT"] = "0"
    for chave in list(env):
        if chave in ("GIT_DIR", "GIT_WORK_TREE") or chave.startswith("GIT_CONFIG"):
            del env[chave]
    return env


def argv_git(args: list[str]) -> list[str]:
    """Desliga o hook da pasta em todo git do dispatcher.

    O fetch e o push precisam disso: `core.hooksPath` no config da pasta rodaria
    no meio do envio. O merge da main também dispara hook, então o mesmo `-c`
    vale para qualquer subcomando.
    """
    if not args or args[0] not in ("git", GIT):
        return list(args)
    resto = args[1:]
    if resto[:2] == ["-c", "core.hooksPath=/dev/null"]:
        return [GIT, *resto]
    return [GIT, "-c", "core.hooksPath=/dev/null", *resto]


def sh(args: list[str], cwd: Optional[Path] = None, check: bool = True, timeout: int = 120) -> str:
    argv = argv_git(args)
    out = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=ambiente_git(), timeout=timeout)
    if check and out.returncode != 0:
        raise RuntimeError(f"{' '.join(argv[:6])}… falhou ({out.returncode}): {out.stderr.strip()[:300]}")
    return out.stdout.strip()


def linear(query: str, variables: dict) -> dict:
    """Pede a consulta ao proxy local. O token não passa por este processo."""
    try:
        return proxy_linear.executar_consulta(query, variables)
    except proxy_linear.ErroProxy as exc:
        raise RuntimeError(str(exc)) from None


def viewer_linear() -> str:
    """Id do usuário do token, para o dispatcher também respeitar assignee."""
    try:
        salvo = VIEWER_FILE.read_text().strip()
        if salvo:
            return salvo
    except OSError:
        pass
    try:
        viewer = (linear(proxy_linear.consulta("viewer"), {}).get("viewer") or {})
        ident = str(viewer.get("id") or "")
    except RuntimeError as exc:
        log(f"fila: não li o viewer do Linear ({exc})")
        return ""
    if ident:
        try:
            VIEWER_FILE.write_text(ident)
        except OSError:
            pass
    return ident


def estado_do_card(identifier: str) -> str:
    """Estado atual do card, para revalidar antes de mover (CAS leve)."""
    try:
        issue = (linear(proxy_linear.consulta("estado_card"), {"id": identifier}).get("issue") or {})
        return str((issue.get("state") or {}).get("name") or "")
    except RuntimeError as exc:
        log(f"fila: não reli o estado de {identifier} ({exc})")
        return ""


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


def _template_producao(nome: str) -> Optional[Path]:
    """Template versionado no repo. Não é o fixture de teste nem a cópia em ~/.transcentia."""
    aqui = Path(__file__).resolve()
    if ".transcentia" in aqui.parts:
        return None
    raiz = None
    for pai in aqui.parents:
        if (pai / ".git").exists():
            raiz = pai
            break
    if raiz is None:
        return None
    caminho = raiz / "apps" / "notch-mac" / "Resources" / nome
    try:
        resolvido = caminho.resolve()
    except OSError:
        return None
    if "fixtures" in resolvido.parts or ".transcentia" in resolvido.parts or not resolvido.is_file():
        return None
    return resolvido


def _recusar_mcp_fora_do_bundle(arq: Path) -> None:
    """Comando absoluto do MCP tem de ficar dentro do `Contents/Resources` deste arquivo.

    Caminho de outra máquina, ou script fora do bundle, não sobe na próxima lane.
    Comando relativo (nome no PATH, ou relativo a este diretório) continua.
    """
    try:
        dados = json.loads(arq.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(dados, dict):
        return
    servidores = dados.get("mcpServers") or {}
    if not isinstance(servidores, dict):
        return
    raiz = arq.parent.resolve()
    for spec in servidores.values():
        if not isinstance(spec, dict):
            continue
        candidatos = [spec.get("command")]
        args = spec.get("args")
        if isinstance(args, list):
            candidatos.extend(args)
        for bruto in candidatos:
            if not isinstance(bruto, str) or not bruto.startswith("/"):
                continue
            try:
                alvo = Path(bruto).resolve()
            except OSError:
                raise FileNotFoundError(f"comando MCP fora do bundle: {bruto}") from None
            if alvo != raiz and raiz not in alvo.parents:
                raise FileNotFoundError(f"comando MCP fora do bundle: {bruto}")


def caminho_controle(nome: str) -> Path:
    """`claude-settings.json` ou `lane-mcp.json` do bundle assinado; senão, o template do repo.

    A cópia em `~/.transcentia/lanes` e o fixture de teste não servem: a lane escreve
    na primeira, e o fixture é um stub (`allow: ["Read"]`).
    """
    if nome not in ("claude-settings.json", "lane-mcp.json"):
        raise ValueError(nome)
    recursos = catalogo.recursos_do_bundle()
    if recursos is not None:
        arq = (recursos / nome).resolve()
        if arq.is_file() and "fixtures" not in arq.parts and ".transcentia" not in arq.parts:
            if nome == "lane-mcp.json":
                _recusar_mcp_fora_do_bundle(arq)
            return arq
    repo = _template_producao(nome)
    if repo is not None:
        if nome == "lane-mcp.json":
            _recusar_mcp_fora_do_bundle(repo)
        return repo
    raise FileNotFoundError(
        f"{nome} não está no bundle assinado nem no template de produção; "
        "não uso ~/.transcentia nem o fixture de teste")



def caminho_settings() -> Path:
    """Settings que a lane usa: o bundle assinado, ou o template de produção.

    Não lê `lanes/claude-settings.json` nem `~/.transcentia`: a lane consegue
    reescrever as duas. O template carrega o perfil estrito da main (dontAsk,
    sandbox, sem allow global).
    """
    return caminho_controle("claude-settings.json")


def lane_settings() -> dict:
    """Objeto inteiro de `claude-settings.json` (permissões e sandbox do Claude)."""
    return json.loads(caminho_settings().read_text(encoding="utf-8"))


# --- Modo bancada (FRA-618) -----------------------------------------------------
# Hardware na USB (ex.: ESP32). Liga só com as três condições juntas; sem elas, a
# lane recebe os settings estritos de sempre. A lane ganha um único comando, que
# o Claude Code roda fora do sandbox só quando a linha inteira casa com o caminho
# absoluto do bundle. As validações ficam no próprio comando (lanes/bancada.py).
ETIQUETA_BANCADA = "lane:bancada"
COMANDO_BANCADA = _AQUI / "bancada.py"


def bancada_ativa(lane: str, issue: dict) -> bool:
    """Lane do CLI `claude` + etiqueta `lane:bancada` no card + `bancada.ativo` no cadastro."""
    if catalogo.cli_da_lane(lane) != "claude":
        return False
    nomes = {str(l.get("name") or "") for l in (issue.get("labels") or {}).get("nodes") or []
             if isinstance(l, dict)}
    if ETIQUETA_BANCADA not in nomes:
        return False
    try:
        return projeto().bancada is True
    except Exception:  # noqa: BLE001 — sem cadastro legível, o modo fica desligado
        return False


def settings_bancada(base: dict, comando: Path = COMANDO_BANCADA) -> dict:
    """Os settings estritos mais o comando `bancada`. Nada além disso muda."""
    caminho = str(comando)
    if (".transcentia" in caminho or not os.path.isabs(caminho) or any(c.isspace() for c in caminho)
            or not os.path.isfile(caminho) or not os.access(caminho, os.X_OK)):
        raise RuntimeError(f"comando da bancada recusado: {caminho}")
    novo = json.loads(json.dumps(base))
    regra = f"{caminho} *"
    novo.setdefault("permissions", {}).setdefault("allow", []).append(f"Bash({regra})")
    novo.setdefault("sandbox", {})["excludedCommands"] = [regra]
    return novo


TEXTO_BANCADA = """

## Modo bancada (hardware na USB)

Este card roda no modo bancada. O único acesso a hardware é o comando abaixo,
sempre pelo caminho completo, sozinho na linha (sem `&&`, `|`, `>`, `cd` nem `$(...)`):

    {comando} portas
    {comando} chip [--porta P] [--chip esp32s3]
    {comando} gravar [--porta P] [--chip esp32s3] 0x0 caminho/no/worktree/firmware.bin
    {comando} serial [--porta P] [--baud 115200] SEGUNDOS

- O firmware tem de ser um `.bin` dentro deste worktree. A serial lê no máximo 120 s.
- Não existe outro acesso: sem rede, sem Docker, sem Python e sem shell livre.
- Cada uso fica registrado fora do worktree. Confirmações de privacidade e assinaturas
  são do dono: escreva o que falta em `residual_risk` ou peça com `needs_dono`.
"""


def lane_permissions() -> dict:
    """Mesmas regras para claude e grok (allow/deny/defaultMode)."""
    return lane_settings()["permissions"]


def escrever_perfil_sandbox(destino: Optional[Path] = None) -> Path:
    """Grava `[profiles.lane]` em `~/.grok/sandbox.toml` sem apagar os outros perfis.

    O claim chama isto antes de subir o Grok. O perfil é do dispatcher: a lane
    não consegue reescrevê-lo depois, porque o `strict` deixa `sandbox.toml`
    só para leitura. Sem o perfil, o Grok recusa subir (falha fechada)."""
    destino = destino or (Path.home() / ".grok" / "sandbox.toml")
    destino.parent.mkdir(parents=True, exist_ok=True)
    atual = destino.read_text(encoding="utf-8") if destino.is_file() else ""
    novo = _trocar_bloco_toml(atual, f"[profiles.{PERFIL_SANDBOX}]", PERFIL_SANDBOX_TOML)
    if novo != atual:
        destino.write_text(novo, encoding="utf-8")
    return destino


def _trocar_bloco_toml(texto: str, cabecalho: str, bloco: str) -> str:
    """Troca a seção `cabecalho` pelo `bloco`. O resto do arquivo fica."""
    linhas = texto.splitlines()
    ini = next((i for i, linha in enumerate(linhas) if linha.strip() == cabecalho), None)
    bloco_linhas = bloco.strip("\n").splitlines()
    if ini is None:
        base = texto
        if base and not base.endswith("\n"):
            base += "\n"
        if base and not base.endswith("\n\n"):
            base += "\n"
        return base + "\n".join(bloco_linhas) + "\n"
    fim = next((j for j in range(ini + 1, len(linhas)) if linhas[j].startswith("[")), len(linhas))
    meio = bloco_linhas + ([""] if fim < len(linhas) else [])
    novo = "\n".join(linhas[:ini] + meio + linhas[fim:])
    return novo if novo.endswith("\n") else novo + "\n"


def _re_glob_caminho(padrao: str) -> str:
    """Glob de caminho: `*` não cruza `/`, `**` cruza. `**/` no início casa zero pastas."""
    i, n = 0, len(padrao)
    out = ["^"]
    while i < n:
        if padrao.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
            continue
        if padrao.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        ch = padrao[i]
        if ch == "*":
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(ch))
        i += 1
    out.append("$")
    return "".join(out)


def _expandir_til(caminho: str) -> str:
    if caminho == "~" or caminho.startswith("~/"):
        return str(Path.home()) + caminho[1:]
    return caminho


def _casa_glob_caminho(padrao: str, caminho: str) -> bool:
    """`**/.ssh/**` também casa a própria pasta (`~/.ssh`), não só o que está dentro."""
    for alvo in (caminho, _expandir_til(caminho)):
        if re.fullmatch(_re_glob_caminho(padrao), alvo):
            return True
        if padrao.endswith("/**") and re.fullmatch(_re_glob_caminho(padrao[:-3]), alvo):
            return True
    return False


def _miolo(regra: str, ferramenta: str) -> Optional[str]:
    prefixo = ferramenta + "("
    if regra.startswith(prefixo) and regra.endswith(")"):
        return regra[len(prefixo):-1]
    return None


def _caminho_no_worktree(caminho: str) -> bool:
    """Relativo ao cwd da lane, sem `..` e sem absoluto. É o que `Read(./**)` cobre."""
    if not caminho or caminho.startswith("~") or caminho.startswith("/"):
        return False
    return ".." not in Path(caminho).parts


def _caminho_negado(caminho: str, regras: list, ferramenta: str) -> bool:
    for regra in regras:
        miolo = _miolo(regra, ferramenta)
        if miolo and _casa_glob_caminho(miolo, caminho):
            return True
    return False


def leitura_negada(caminho: str, permissoes: Optional[dict] = None) -> bool:
    """A ferramenta de leitura não alcança este caminho.

    Deny ganha do allow. Sem `Read` global, caminho fora do worktree também cai
    (dontAsk). `~/.config/gh/hosts.yml` não passa."""
    perms = permissoes if permissoes is not None else lane_permissions()
    deny = list(perms.get("deny") or [])
    if _caminho_negado(caminho, deny, "Read") or _caminho_negado(caminho, deny, "Grep"):
        return True
    if any(r in ("Read", "Grep") for r in (perms.get("allow") or [])):
        return False
    return not _caminho_no_worktree(caminho)


def escrita_negada(caminho: str, permissoes: Optional[dict] = None) -> bool:
    """Edit/Write negados (`.git/config`, `.git/hooks`) ou fora do worktree."""
    perms = permissoes if permissoes is not None else lane_permissions()
    deny = list(perms.get("deny") or [])
    if _caminho_negado(caminho, deny, "Edit") or _caminho_negado(caminho, deny, "Write"):
        return True
    if any(r in ("Edit", "Write") for r in (perms.get("allow") or [])):
        return False
    return not _caminho_no_worktree(caminho)


_WRAPPERS_BASH = {"env", "timeout", "nice", "ionice", "chrt", "stdbuf"}
# Comandos que o Grok trata como só-leitura e rodaria até no dontAsk, se nenhum
# deny pegar (doc 22, "Read-Only Shell Commands"). cat/head/tail/grep/sort estão
# no deny da lane justamente por isso. O deny ganha desta lista.
_SO_LEITURA = {
    "ls", "cat", "pwd", "date", "whoami", "hostname", "uptime", "ps",
    "head", "tail", "wc", "sort", "uniq", "tr", "cut",
    "mkdir", "touch", "grep", "rg",
}
_GIT_SO_LEITURA = {
    "status", "branch", "log", "diff", "ls-files", "show", "rev-parse",
    "blame", "describe", "merge-base", "shortlog", "check-ignore", "check-attr",
    "cat-file", "ls-tree", "show-ref", "for-each-ref", "rev-list", "name-rev",
    "count-objects",
}


def _segmentos_bash(comando: str) -> list:
    """Parte em `&&`, `||`, `;` e `|`. Não parte dentro de aspas."""
    partes: list = []
    buf: list = []
    aspas = ""
    i = 0
    while i < len(comando):
        c = comando[i]
        if aspas:
            buf.append(c)
            if c == aspas:
                aspas = ""
            i += 1
            continue
        if c in "\"'":
            aspas = c
            buf.append(c)
            i += 1
            continue
        if comando.startswith("&&", i) or comando.startswith("||", i):
            partes.append("".join(buf))
            buf = []
            i += 2
            continue
        if c in ";|":
            partes.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    partes.append("".join(buf))
    return [p.strip() for p in partes if p.strip()]


def _sem_involucro(segmento: str) -> str:
    """Tira `VAR=...` e invólucros (`env`, `timeout`) para a regra ver o comando de dentro."""
    try:
        tokens = shlex.split(segmento)
    except ValueError:
        tokens = segmento.split()
    i = 0
    while i < len(tokens) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[i] or ""):
        i += 1
    while i < len(tokens) and tokens[i] in _WRAPPERS_BASH:
        i += 1
        while i < len(tokens) and tokens[i].startswith("-"):
            i += 1
    return " ".join(tokens[i:])


def _regra_bash_casa(regras: list, comando: str) -> bool:
    for regra in regras:
        miolo = _miolo(regra, "Bash")
        if miolo and permissao.bash_casa(miolo, comando):
            return True
    return False


def _so_leitura(comando: str) -> bool:
    tokens = comando.split()
    if not tokens:
        return False
    base = tokens[0].rsplit("/", 1)[-1]
    if base in _SO_LEITURA:
        return True
    if base == "git" and len(tokens) > 1 and tokens[1] in _GIT_SO_LEITURA:
        return True
    return False


def _toca_caminho_negado(comando: str, deny: list) -> bool:
    """O deny de Read/Edit vale para o caminho que o shell toca.

    Token que começa com `-` não é caminho. `--file=~/.grok/auth.json` carrega
    o caminho depois do `=`. `-F~/.grok/auth.json` não tem `=`: o glob
    `Bash(git commit *-F*)` é quem nega essa forma."""
    try:
        tokens = shlex.split(comando)
    except ValueError:
        tokens = comando.split()
    for token in tokens[1:]:
        candidatos = []
        if "=" in token:
            valor = token.split("=", 1)[1]
            if valor:
                candidatos.append(valor)
        elif not token.startswith("-"):
            candidatos.append(token)
        for cand in candidatos:
            if _caminho_negado(cand, deny, "Read") or _caminho_negado(cand, deny, "Edit"):
                return True
    return False


def comando_negado_pela_lane(comando: str, permissoes: Optional[dict] = None) -> bool:
    """True se a lane não deixa este comando rodar.

    Deny ganha. No `dontAsk`, o que não é allow e não é só-leitura também cai.
    `cat ~/.config/gh/hosts.yml` e a busca de senha do `security` caem aqui:
    o primeiro pelo deny de `cat` e do caminho, o segundo porque `security`
    não está no allow (e o basename do binário casa o deny)."""
    perms = permissoes if permissoes is not None else lane_permissions()
    deny = list(perms.get("deny") or [])
    allow = list(perms.get("allow") or [])
    dont = (perms.get("defaultMode") or MODO_PERMISSAO) == "dontAsk"
    for bruto in _segmentos_bash(comando):
        segmento = _sem_involucro(bruto)
        if not segmento:
            return True
        if _regra_bash_casa(deny, segmento) or _toca_caminho_negado(segmento, deny):
            return True
        if _so_leitura(segmento):
            continue
        if _regra_bash_casa(allow, segmento):
            continue
        if dont:
            return True
    return False


def sort_key(issue: dict) -> tuple:
    # Linear: 1=Urgent 2=High 3=Medium 4=Low 0=sem prioridade (vai para o fim).
    p = issue.get("priority") or 0
    return (p if p > 0 else 5, issue.get("startedAt") or issue.get("createdAt") or "")


def touched_protected(paths: list[str]) -> list[str]:
    """Caminhos que a lane tocou e que o projeto declara protegidos."""
    globs = protected_globs()
    return [p for p in paths if any(fnmatch.fnmatch(p, g) for g in globs)]


# --- Modelo customizado por lane (do config do TuttiDash) -------------------
# O arquivo é o do resolvedor único (gasto_lanes/config.py): env > TuttiDash >
# Lanekeeper > TranscentIA Gasto > legado. Testes trocam CONFIG_FILES por uma lista.
_USAR_RESOLVEDOR = object()
CONFIG_FILES = _USAR_RESOLVEDOR


def _arquivos_cfg() -> list:
    if CONFIG_FILES is not _USAR_RESOLVEDOR:
        return list(CONFIG_FILES)
    try:
        from config import arquivos_em_uso
    except ImportError:
        from gasto_lanes.config import arquivos_em_uso
    return arquivos_em_uso()
# Última lista boa de modelos, a mesma que os Ajustes gravam (FRA-521).
CACHE_MODELOS = catalogo.CACHE_MODELOS


def ler_modelo_lane(lane: str) -> Optional[str]:
    """Modelo fixo da lane, ou None no automático (e quando o fixo saiu da lista).

    String antiga e `{"modo": "fixo"}` devolvem o modelo. O automático por peso não cabe
    numa string: `modelo_da_lane` lê `porPeso`."""
    bruto = catalogo.bruto_modelo(lane, _arquivos_cfg())
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


def _bruto_da_lane(lane: str):
    """`lanes.modelo.<lane>`. Instância sem essa chave e com `modelo` fixo na própria entrada
    (formato do piloto ACP) vale como Fixo."""
    bruto = catalogo.bruto_modelo(lane, _arquivos_cfg())
    if bruto is None:
        inst = catalogo.instancia(lane)
        if inst and inst["modelo"] != catalogo.MODELO_AUTO:
            bruto = {"modo": "fixo", "fixo": inst["modelo"]}
    return bruto


def _resolucao_modelo(lane: str, effort: str) -> dict:
    """Modelo, esforço e flags da lane neste peso. A config é a da lane
    (`lanes.modelo.<lane>`); o manifesto é o do agente (PRD lanes-v2)."""
    return catalogo.resolver_modelo(catalogo.perfil_da_lane(lane), effort, _bruto_da_lane(lane),
                                    _cache_modelos())


def modelo_da_lane(lane: str, effort: str) -> str:
    """Modelo que a lane usa neste esforço, no formato do CLI (`opencode/x`, `opencode-go/x`).

    Fixo (e a string antiga) vale para todos os pesos. Automático usa `porPeso` e, no
    que faltar, o manifesto. Sem o prefixo do provedor, ganha o do manifesto.
    Teste que troca `ler_modelo_lane` continua no caminho antigo (None = manifesto).
    Instância (PRD lanes-v2): a mesma resolução, com a config da instância e o manifesto
    do agente dela."""
    if catalogo.instancia(lane):
        return _resolucao_modelo(lane, effort)["modelo"]
    if ler_modelo_lane is not _ler_modelo_lane_impl:
        flags = EFFORT_FLAGS.get(lane, {}).get(effort) or []
        m = ler_modelo_lane(lane) or (flags[-1] if flags else "")
        padrao = catalogo.modelo_de_effort(lane, effort)
        if m and "/" not in m and "/" in padrao:
            m = padrao.split("/", 1)[0] + "/" + m
        return m
    return _resolucao_modelo(lane, effort)["modelo"]


def flags_da_lane(lane: str, effort: str) -> list[str]:
    """Flags do CLI neste peso, já com o modelo e o esforço da config.
    Instância ACP: só para exibir (o runner recebe `--modelo`)."""
    inst = catalogo.instancia(lane)
    if inst and inst["transporte"] == "acp":
        m = modelo_da_lane(lane, effort)
        return ["-m", m] if m else []
    if inst:
        return list(_resolucao_modelo(lane, effort)["flags"])
    if ler_modelo_lane is not _ler_modelo_lane_impl:
        m = ler_modelo_lane(lane)
        if not m:
            return list(EFFORT_FLAGS.get(lane, {}).get(effort) or [])
        return catalogo.montar_flags(lane, effort, catalogo.com_prefixo_modelo(lane, m), "", False)
    return list(_resolucao_modelo(lane, effort)["flags"])


def aviso_modelo(lane: str, effort: str) -> str:
    """«modelo fixo» ou o texto de modelo que saiu da lista. Vazio no automático quieto."""
    if catalogo.instancia(lane):
        return _resolucao_modelo(lane, effort)["aviso"]
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
    for cfg_path in _arquivos_cfg():
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
            novo, _aviso = catalogo.ajuste_sumido(catalogo.perfil_da_lane(lane), bruto, cache)
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
            _privar(cfg_path)
        break
    return mudou


def atualizar_listas_modelos() -> None:
    """Renova a lista das lanes sem lista boa do dia e devolve ao automático o que sumiu.
    Lane que falhou é tentada de novo depois de uma hora (FRA-564)."""
    try:
        pendentes = catalogo.lanes_para_atualizar([l for l in LANES if l in catalogo.catalogo()],
                                                  CACHE_MODELOS)
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
    if not catalogo.dados_lane(lane).get("privacidade"):
        return None
    if privacidade is None:
        return "módulo de privacidade ausente (rode tools/install.sh)"
    modelo = modelo_da_lane(lane, effort)
    if catalogo.instancia(lane) and not modelo:
        return f"lane sem modelo para o peso `{effort}`: a privacidade só é conferida com um modelo"
    ok, motivo = privacidade.pode_receber_codigo(modelo)
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


def deepseek_esforco(effort: str, lane: str = "deepseek") -> str:
    """reasoningEffort do dsh: o da config, se válido; senão o padrão do peso."""
    bruto = str(_resolucao_modelo(lane, effort).get("esforco") or "").strip()
    if bruto in DSH_ESFORCOS_VALIDOS:
        return bruto
    return DSH_ESFORCO.get(effort, "high")


def deepseek_patch(effort: str, lane: str = "deepseek") -> str:
    """Patch do perfil headless do dsh para esta execução.

    O perfil de fábrica monta o provedor oficial (chave de API) e desliga a conta.
    Com a conta do app, é preciso religar authorization/credentials/account e
    apontar o modelo padrão para `deepseek-account`. Com DEEPSEEK_API_KEY no
    ambiente, basta fixar o modelo no provedor oficial.
    """
    modelo = modelo_da_lane(lane, effort) or "deepseek-flash"
    esforco = deepseek_esforco(effort, lane)
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


def deepseek_resumo(effort: str, lane: str = "deepseek") -> str:
    """Modelo e esforço no comentário do claim (o dsh não recebe flags de modelo)."""
    return f"{modelo_da_lane(lane, effort) or 'deepseek-flash'} · reasoning {deepseek_esforco(effort, lane)}"


def agent_command(lane: str, effort: str, prompt: Optional[Path] = None,
                  patch: Optional[Path] = None, settings: Optional[Path] = None) -> list[str]:
    """Comando headless do agente (claude, grok e opencode são executadas de verdade).

    `prompt` e `patch` são caminhos fora do worktree. O agente não pode trocar
    o arquivo que o runner vai ler.
    """
    # PRD lanes-v2: o comando sai do CLI da lane (`claude`, `grok`, `opencode`, `codex`,
    # `dsh`), não do nome dela. Uma instância (`claude-sonnet`) usa o mesmo comando do
    # agente, com o modelo e o esforço da própria config.
    if catalogo.transporte_da_lane(lane) == "acp":
        return comando_acp(lane, catalogo.instancia(lane), settings, effort)
    cli = catalogo.cli_da_lane(lane)
    if cli == "claude":
        return [
            "claude", "-p",  # prompt chega pelo stdin, do RUN_DIR (FRA-595)
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", MODO_PERMISSAO,
            "--settings", str(settings or caminho_settings()),
            "--strict-mcp-config", "--mcp-config", str(caminho_controle("lane-mcp.json")),
            "--max-budget-usd", str(BUDGET_USD[effort]),
            *flags_da_lane(lane, effort),
        ]
    if cli == "grok":
        if prompt is None or ".lane" in Path(prompt).parts:
            raise RuntimeError("o prompt da lane fica fora do worktree")
        perms = lane_permissions()
        cmd = [
            "grok", "--prompt-file", str(prompt),
            "--output-format", "streaming-messages-json",
            "--permission-mode", MODO_PERMISSAO,
            "--sandbox", PERFIL_SANDBOX,
            "--tools", ",".join(GROK_TOOLS), "--disable-web-search",
            "--max-turns", str(GROK_MAX_TURNS[effort]),
            *flags_da_lane(lane, effort),
        ]
        for rule in perms["allow"]:
            if not rule.startswith("mcp__"):      # nenhum MCP liberado na lane grok
                cmd += ["--allow", rule]
        for rule in perms["deny"] + ["WebFetch", "WebSearch", "mcp__linear", "mcp__obsidian-rest",
                                     "mcp__obsidian-filesystem", "mcp__outsystems-docs"]:
            cmd += ["--deny", rule]
        return cmd
    if cli == "opencode":
        # FRA-374: `run` lê eventos JSON
        # linha a linha (--format json). O prompt vai como argumento (o `run` não
        # documenta leitura do stdin). `texto_do_agente` põe "$(cat <prompt>)"
        # entre aspas, com o prompt fora do worktree: o bash expande, e espaços
        # e aspas do arquivo chegam num argumento só. O run_lane.sh continua
        # redirecionando o stdin por compatibilidade com as outras lanes.
        # Modelo da config da lane (`lanes.modelo.<lane>`); `opencode-go` é a mesma
        # invocação com os modelos Go (ZDR, teto mensal por modelo).
        modelo = modelo_da_lane(lane, effort)
        return [
            "opencode", "run", "--format", "json",
            "-m", modelo,
        ]
    if cli == "codex":
        # FRA-374: `exec --json` emite eventos JSONL; o prompt vai
        # como argumento posicional (ver claim). Padrão = modelo default do CLI.
        # Sem teto de gasto no CLI; monitorado pelo ledger depois.
        return [
            "codex", "exec", "--json",
            *flags_da_lane(lane, effort),
        ]
    if cli == "dsh":
        # dsh (DeepSeek Harness) headless: uma sessão nova, a resposta final no
        # stdout e sai. O prompt vai como argumento posicional (texto_do_agente).
        # O patch escrito no claim liga a conta e fixa modelo/reasoningEffort.
        # Sem `--max-budget-usd` e sem stream JSON: o ledger não mede esta lane.
        # O yml fica no RUN_DIR: o agente não reescreve o patch.
        if patch is None:
            raise RuntimeError("o patch do dsh fica fora do worktree")
        return ["dsh", "--profile", "headless", "--patch", str(patch)]
    # cursor não tem CLI headless público para execução de lanes; fica como
    # placeholder até existir comando equivalente.
    raise NotImplementedError(f"lane {lane} não tem comando de agente")


def comando_acp(lane: str, inst: dict, settings: Optional[Path] = None,
                effort: str = EFFORT_DEFAULT) -> list[str]:
    """Lane ACP (PRD lanes-acp): o `acp_runner.py` do bundle fala ACP com o agente.

    Comando e config do agente saem do manifesto assinado; daqui só vão nome, agente
    e modelo. O `run_lane.sh` entra no worktree antes (`cd "$WT"`) e entrega o prompt
    no stdin."""
    runner = (_AQUI / "acp_runner.py").resolve()
    if ".transcentia" in runner.parts or not runner.is_file():
        raise RuntimeError("acp_runner.py não está no bundle; lane ACP fechada")
    cmd = ["/usr/bin/python3", str(runner), "--lane", lane, "--agente", inst["agente"],
           "--worktree", ".", "--settings", str(settings or caminho_settings()),
           "--espera", str(LANE_TIMEOUT_MIN * 60)]
    modelo = modelo_da_lane(lane, effort)   # "auto" resolve pelo peso do card
    if modelo:
        cmd += ["--modelo", modelo]
    return cmd


def texto_do_agente(lane: str, effort: str, prompt: Path,
                    patch: Optional[Path] = None, settings: Optional[Path] = None) -> str:
    """Linha que o `run_lane.sh` executa. O prompt é um arquivo fora do worktree.

    Na opencode e no dsh o prompt entra entre aspas. Sem aspas, um espaço ou uma
    aspa do card partia o argumento e o CLI lia lixo (ou uma flag)."""
    agent_text = shlex.join(agent_command(lane, effort, prompt=prompt, patch=patch, settings=settings))
    if catalogo.transporte_da_lane(lane) == "cli" and catalogo.cli_da_lane(lane) in ("opencode", "dsh"):
        agent_text += f' -- "$(cat {shlex.quote(str(prompt))})"'
    return agent_text


# --- Estado local das lanes --------------------------------------------------
def state_file(lane: str) -> Path:
    return STATE_DIR / f"lane-{lane}.json"


def load_state(lane: str) -> Optional[dict]:
    """Lê `lane-<lane>.json`. None se não há arquivo.

    JSON ilegível ou que não é objeto volta marcado como recusado: a lane fica
    ocupada, e o `watch` não fecha, não mata e não move o card. `save_state`
    legítimo continua gravando o dict e a leitura devolve o que foi gravado.
    """
    f = state_file(lane)
    if not f.exists():
        return None
    try:
        data = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return {"lane": lane, "_recusado": "json inválido"}
    if not isinstance(data, dict):
        return {"lane": lane, "_recusado": "json não é objeto"}
    return data


def save_state(lane: str, st: dict) -> None:
    # Escrita atômica: um lane-<x>.json pela metade (Mac dormiu, disco cheio) fazia o
    # load_state levantar em todo ciclo e parava o dispatcher inteiro.
    f = state_file(lane)
    tmp = f.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2))
    _privar(tmp)
    tmp.replace(f)
    _privar(f)


# FRA-600. O `lane-<lane>.json` mora no home, gravável pelo mesmo usuário do agente.
# Isto é consistência: worktree, sessão, card, branch, issue do claim, base e log.
# Não é barreira. Quem já é o usuário forja o JSON e o claim. A garantia real é a
# fase 5 (estado fora do alcance do agente).
_CARD_RE = re.compile(r"^[A-Za-z]+-\d+$")
_BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
_CAMPOS_CLAIM = ("card", "issue_id", "branch", "worktree", "base", "log", "session")


def claim_file(lane: str) -> Path:
    return STATE_DIR / f"claim-{lane}.json"


def gravar_claim(lane: str, st: dict) -> None:
    """Par que o `claim` gravou. O JSON da lane não pode trocar estes campos."""
    dados = {k: st.get(k) for k in _CAMPOS_CLAIM}
    f = claim_file(lane)
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(dados, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(f)


def ler_claim(lane: str) -> Optional[dict]:
    try:
        data = json.loads(claim_file(lane).read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return None
    return data if isinstance(data, dict) else None


def apagar_claim(lane: str) -> None:
    try:
        claim_file(lane).unlink(missing_ok=True)
    except OSError:
        pass


def soltar_lane(lane: str) -> None:
    state_file(lane).unlink(missing_ok=True)
    apagar_claim(lane)
    _arquivo_recusa(lane).unlink(missing_ok=True)


def sessao_de_lane(session: str) -> bool:
    """`lane-<lane>` de uma lane conhecida. Outro nome não é sessão nossa."""
    if not isinstance(session, str) or not session.startswith("lane-"):
        return False
    return session[len("lane-"):] in LANES


def branch_valida(nome) -> bool:
    if not isinstance(nome, str) or not _BRANCH_RE.fullmatch(nome):
        return False
    if nome.startswith("-") or nome.endswith("/") or nome.endswith(".") or nome.endswith(".lock"):
        return False
    if ".." in nome.split("/") or "//" in nome or "@{" in nome or ":" in nome:
        return False
    return True


def branch_segura(nome, identificador: str) -> str:
    """Nome de branch que o `branch_valida` aceita, derivado do `branchName` do Linear.

    Causa raiz do FRA-630 (01/11/2026): o Linear gerou a branch com `×` (título
    "ambiente × Watch"). O git aceita, o claim gravou, e o `branch_valida` (só ASCII)
    recusou o próprio estado do dispatcher em todo ciclo: a lane ficou presa sem prova,
    sem PR e sem alerta. Aqui o claim normaliza antes de criar o worktree:
    translitera (× → x, acento some), troca o resto por hífen e garante o identificador
    do card no nome (o Linear liga o PR ao card por ele). Determinístico: a retomada do
    mesmo card chega ao mesmo nome. Nome já válido volta igual.
    """
    if branch_valida(nome):
        return nome
    import unicodedata
    texto = str(nome or "").replace("×", "x").replace("÷", "-")
    texto = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode("ascii")
    texto = re.sub(r"[^A-Za-z0-9._/-]+", "-", texto)
    partes = []
    for parte in texto.split("/"):
        parte = re.sub(r"-{2,}", "-", parte).strip("-.")
        if parte.endswith(".lock"):
            parte = parte[: -len(".lock")].rstrip("-.")
        if parte and parte != "..":
            partes.append(parte)
    texto = "/".join(partes)
    ident = str(identificador or "").strip().lower()
    if ident and ident not in texto.lower():
        texto = f"{texto}-{ident}" if texto else ident
    if branch_valida(texto):
        return texto
    if branch_valida(ident):
        return ident
    raise RuntimeError(f"sem nome de branch válido para {identificador!r} (Linear: {nome!r})")


def _resolvido_sob(caminho: str, raiz: Path) -> Optional[Path]:
    """Caminho resolvido estritamente dentro de `raiz`, ou None (symlink incluso)."""
    if not isinstance(caminho, str) or not caminho.strip():
        return None
    try:
        base = Path(raiz).expanduser().resolve()
        alvo = Path(caminho).expanduser().resolve()
    except (OSError, RuntimeError):
        return None
    if not base.is_dir() or alvo == base or base not in alvo.parents:
        return None
    return alvo


def _commit_alcancavel(wt: Path, base: str) -> bool:
    try:
        out = subprocess.run(
            argv_git(["git", "cat-file", "-e", f"{base}^{{commit}}"]),
            cwd=wt, capture_output=True, text=True, timeout=30,
            env=ambiente_git(),
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0


def _mesmo_caminho(a, b) -> bool:
    try:
        return Path(str(a)).expanduser().resolve() == Path(str(b)).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return False


def motivo_recusa_estado(lane: str, st: dict) -> Optional[str]:
    """None se o estado pode seguir para o `watch`. Senão o motivo, para o log.

    O mesmo usuário ainda pode forjar este JSON e o `claim-<lane>.json`. A
    garantia real é a fase 5.
    """
    if not isinstance(st, dict):
        return "estado não é objeto"
    if st.get("_recusado"):
        return str(st["_recusado"])
    if lane not in LANES or st.get("lane") != lane:
        return "lane diferente do arquivo"
    if st.get("session") != f"lane-{lane}":
        return "sessão não é lane-<lane>"
    card = st.get("card")
    if not isinstance(card, str) or not _CARD_RE.fullmatch(card):
        return "card inválido"
    branch = st.get("branch")
    if not branch_valida(branch):
        return "branch inválida"
    issue = st.get("issue_id")
    if not isinstance(issue, str) or not issue or any(c.isspace() for c in issue) or '"' in issue:
        return "issue_id inválido"
    try:
        raiz = projeto_worktrees()
    except Exception as exc:  # noqa: BLE001 — sem pasta não há worktree confiável
        return f"pasta de worktrees indisponível ({type(exc).__name__})"
    wt = _resolvido_sob(st.get("worktree"), raiz)
    if wt is None or not wt.is_dir():
        return "worktree fora da pasta de worktrees"
    base = st.get("base")
    if not isinstance(base, str) or not _SHA_RE.fullmatch(base.strip()):
        return "base não é commit"
    base_norm = base.strip().lower()
    if not _commit_alcancavel(wt, base_norm):
        return "base não é commit alcançável"
    log_path = _resolvido_sob(st.get("log"), LOG_DIR)
    if log_path is None:
        return "log fora de LOG_DIR"
    claim = ler_claim(lane)
    if not claim:
        return "sem claim gravado"
    if str(claim.get("issue_id") or "") != issue:
        return "issue_id diferente do claim gravado"
    if claim.get("card") != card:
        return "card diferente do claim gravado"
    if claim.get("branch") != branch:
        return "branch diferente do claim gravado"
    if claim.get("session") != st.get("session"):
        return "sessão diferente do claim gravado"
    if str(claim.get("base") or "").strip().lower() != base_norm:
        return "base diferente do claim gravado"
    if not _mesmo_caminho(claim.get("worktree"), st.get("worktree")):
        return "worktree diferente do claim gravado"
    if not _mesmo_caminho(claim.get("log"), st.get("log")):
        return "log diferente do claim gravado"
    return None


def card_confiavel(lane: str, st: Optional[dict]) -> Optional[str]:
    """Card do estado, só quando o esquema confere. Forjado não entra na fila."""
    if not st or motivo_recusa_estado(lane, st):
        return None
    card = st.get("card")
    return card if isinstance(card, str) else None


def _ps_processo(pid: int) -> Optional[dict]:
    """uid, início (`lstart`) e command do processo vivo. None se não dá para ler."""
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        return None
    try:
        # `lstart` é `%c`: o número de campos muda com o locale e a foto zera.
        # C (e pt_BR) fecha em 5. O `ps` roda em C para a leitura não depender do idioma.
        out = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "lstart=", "-o", "command="],
            capture_output=True, text=True, timeout=5,
            env=dict(os.environ, LC_ALL="C", LANG="C", LC_TIME="C"),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    linha = out.stdout.strip()
    if out.returncode != 0 or not linha:
        return None
    partes = linha.split()
    # uid, lstart em C (5 tokens: dia mês número mês hora ano) e o command.
    if len(partes) < 7:
        return None
    try:
        uid = int(partes[0])
    except ValueError:
        return None
    return {"pid": pid, "uid": uid, "lstart": " ".join(partes[1:6]), "command": " ".join(partes[6:])}


def foto_processo(pid: int) -> Optional[dict]:
    """A mesma leitura do `_ps_processo`, com folga para o processo acabar de nascer."""
    for i in range(8):
        foto = _ps_processo(pid)
        if foto:
            return foto
        if i < 7:
            time.sleep(0.05)
    return None


def pid_autorizado(pid: int, foto: dict, comando_ok) -> bool:
    """Dono, início e command batem com o que foi gravado, e o command é o esperado.

    O critério do command é do dispatcher, não o texto que veio do arquivo sozinho.
    """
    if not isinstance(foto, dict) or foto.get("pid") != pid:
        return False
    if not isinstance(foto.get("uid"), int) or foto["uid"] != os.getuid():
        return False
    if not isinstance(foto.get("lstart"), str) or not foto["lstart"]:
        return False
    if not isinstance(foto.get("command"), str) or not foto["command"]:
        return False
    viva = _ps_processo(pid)
    if not viva:
        return False
    if viva["uid"] != foto["uid"] or viva["lstart"] != foto["lstart"] or viva["command"] != foto["command"]:
        return False
    try:
        return bool(comando_ok(viva["command"]))
    except Exception:  # noqa: BLE001 — critério quebrado não autoriza sinal
        return False


def arquivo_prova_proc(wt: Path) -> Path:
    chave = hashlib.sha256(str(Path(wt).resolve()).encode()).hexdigest()[:20]
    return STATE_DIR / "proof-proc" / f"{chave}.json"


_FRONTEIRA_PATH = set("/'\" \t\n;|&<>()`")


def _no_comando_com_fronteira(command: str, caminho: str) -> bool:
    """`caminho` aparece no command e não é prefixo de outro componente (`fra-1` em `fra-10`)."""
    if not caminho:
        return False
    inicio = 0
    while True:
        i = command.find(caminho, inicio)
        if i < 0:
            return False
        fim = i + len(caminho)
        antes = i == 0 or command[i - 1] in _FRONTEIRA_PATH
        depois = fim == len(command) or command[fim] in _FRONTEIRA_PATH
        if antes and depois:
            return True
        inicio = i + 1


def comando_e_prova(wt: Path, command: str) -> bool:
    """O process group da prova é o `/bin/bash` que o dispatcher lançou neste worktree."""
    if not command or command.split()[0] != "/bin/bash":
        return False
    try:
        texto = str(Path(wt).resolve())
    except (OSError, RuntimeError):
        texto = str(wt)
    if not _no_comando_com_fronteira(command, str(wt)) and not _no_comando_com_fronteira(command, texto):
        return False
    # `.lane/proof.log` (FRA-600) ou o log na pasta da rodada (FRA-595).
    return "proof.log" in command


def registrar_foto(wt: Path, pid: int) -> Optional[dict]:
    """Grava dono, início e command da prova fora do worktree. Sem isto não há sinal."""
    foto = foto_processo(pid)
    if not foto or not comando_e_prova(wt, foto["command"]):
        return None
    path = arquivo_prova_proc(wt)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(foto), encoding="utf-8")
    tmp.replace(path)
    return foto


def _ler_foto(path: Path) -> Optional[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return None
    if not isinstance(data, dict) or isinstance(data.get("pid"), bool) or not isinstance(data.get("pid"), int):
        return None
    return data


def comando_e_caffeinate(command: str) -> bool:
    partes = (command or "").split()
    return partes == [CAFFEINATE_BIN, "-i", "-s", "-t", str(CAFFEINATE_SECONDS)]


def arquivo_caffeinate() -> Path:
    return STATE_DIR / "caffeinate.pid"


def gravar_caffeinate(pid: int) -> Optional[dict]:
    foto = foto_processo(pid)
    if not foto or not comando_e_caffeinate(foto["command"]):
        return None
    path = arquivo_caffeinate()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".pid.tmp")
    tmp.write_text(json.dumps(foto), encoding="utf-8")
    tmp.replace(path)
    return foto


def ler_caffeinate() -> Optional[dict]:
    """None no formato antigo (só o número): sem início e command, não há sinal."""
    return _ler_foto(arquivo_caffeinate())


def encerrar_caffeinate(foto: Optional[dict]) -> bool:
    """SIGTERM só se o pid ainda é o caffeinate que este ciclo gravou."""
    if not foto or not isinstance(foto.get("pid"), int):
        return False
    pid = foto["pid"]
    if not pid_autorizado(pid, foto, comando_e_caffeinate):
        log(f"caffeinate.pid {pid} recusado (dono, início ou comando); não sinalizo")
        return False
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    except PermissionError:
        log(f"caffeinate.pid {pid} sem permissão; não sinalizo")
        return False
    return True


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
    """Lanes do arquivo `enabled`, mais as instâncias com `ligada: true` na config."""
    ligadas = {n for n in catalogo.instancias_ligadas() if n in LANES}
    if not ENABLED_FILE.exists():
        return ligadas
    return {l.strip() for l in ENABLED_FILE.read_text().split() if l.strip() in LANES} | ligadas


def tmux_alive(session: str) -> bool:
    return subprocess.run([TMUX, "has-session", "-t", session], capture_output=True,
                          env=dict(os.environ, PATH=TOOL_PATH)).returncode == 0


def descendants(pid: int) -> list[int]:
    out = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True)
    kids = [int(x) for x in out.stdout.split()]
    return kids + [d for k in kids for d in descendants(k)]


def kill_lane_tree(session: str) -> None:
    """Mata a árvore inteira da lane (o xcodebuild junto: senão segura o lock).

    Sessão que não é `lane-<lane>` não chega no tmux: o JSON não escolhe o alvo.
    """
    if not sessao_de_lane(session):
        log(f"recuso matar sessão {session!r}: não é lane-<lane>")
        return
    try:
        panes = sh([TMUX, "list-panes", "-t", session, "-F", "#{pane_pid}"], check=False)
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
    """`conta<TAB>pct<TAB>janela<TAB>reset[<TAB>codigo<TAB>saldo]` ->
    {conta: (pct|None, janela)} ou, com o motivo tipado, (pct|None, janela, codigo, saldo|None)."""
    out = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        conta, pct, janela = parts[0].strip(), parts[1].strip(), parts[2].strip()
        valor = int(pct) if pct.isdigit() else None
        codigo = parts[4].strip() if len(parts) > 4 else ""
        if codigo:
            try:
                saldo = float(parts[5]) if len(parts) > 5 and parts[5].strip() else None
            except ValueError:
                saldo = None
            out[conta] = (valor, janela, codigo, saldo)
        else:
            out[conta] = (valor, janela)
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
    shown = " · ".join((f"{l} {measures[l][0]}% ({measures[l][1]})" if measures[l][0] is not None
                        else f"{l} sem janela ({measures[l][1]})") if l in ok
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


_HOSTS_GITHUB = {"github.com", "ssh.github.com", "www.github.com"}
# Prefixo de URL do GitHub. `insteadOf` casa por prefixo de string: um valor curto
# (`https://github.co`, `http`) também reescreve `https://github.com/dono/repo`.
_PREFIXOS_GITHUB = (
    "https://github.com/",
    "http://github.com/",
    "https://www.github.com/",
    "http://www.github.com/",
    "https://ssh.github.com/",
    "http://ssh.github.com/",
    "ssh://git@github.com/",
    "ssh://git@ssh.github.com/",
    "git@github.com:",
    "git@ssh.github.com:",
    "git://github.com/",
)


def _valor_config(bruto: str) -> str:
    """Valor como o git lê a linha.

    Fora de aspas, `#` e `;` comentam até o fim: `https://github.com#x` é
    `https://github.com`. Dentro de aspas o caractere fica no valor.
    """
    i = 0
    n = len(bruto)
    while i < n and bruto[i] in " \t":
        i += 1
    partes: list[str] = []
    aspas = False
    while i < n:
        c = bruto[i]
        if aspas:
            if c == "\\" and i + 1 < n:
                nxt = bruto[i + 1]
                if nxt == "n":
                    partes.append("\n")
                elif nxt == "t":
                    partes.append("\t")
                elif nxt == "b":
                    partes.append("\b")
                else:
                    partes.append(nxt)
                i += 2
                continue
            if c == '"':
                aspas = False
                i += 1
                continue
            partes.append(c)
            i += 1
            continue
        if c in "#;":
            break
        if c == '"':
            aspas = True
            i += 1
            continue
        partes.append(c)
        i += 1
    return "".join(partes).rstrip(" \t")


def _parse_gitconfig(texto: str) -> list[tuple[str, str, str, str]]:
    """(seção, subseção, chave, valor). Seção e chave em minúsculas.

    Não segue `include`: quem chama recusa a chave antes de o git abrir outro arquivo.
    """
    secao, sub = "", ""
    saida: list[tuple[str, str, str, str]] = []
    pendente = ""
    cab_re = re.compile(r'^\s*\[([A-Za-z0-9]+)(?:\s+"((?:\\.|[^"])*)")?\]\s*(?:[;#].*)?$')
    chave_re = re.compile(r"^\s*([A-Za-z0-9-]+)\s*=\s*(.*)$")
    plana_re = re.compile(r"^\s*([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\s*=\s*(.*)$")
    for bruta in texto.splitlines():
        linha = pendente + bruta if pendente else bruta
        pendente = ""
        if linha.endswith("\\") and not linha.endswith("\\\\"):
            pendente = linha[:-1]
            continue
        if not linha.strip() or linha.lstrip().startswith(("#", ";")):
            continue
        cab = cab_re.match(linha)
        if cab:
            secao = cab.group(1).lower()
            sub = (cab.group(2) or "").replace('\\"', '"').replace("\\\\", "\\")
            continue
        plana = plana_re.match(linha)
        if plana:
            partes = plana.group(1).split(".")
            valor = _valor_config(plana.group(2))
            if len(partes) == 2:
                saida.append((partes[0].lower(), "", partes[1].lower(), valor))
            else:
                saida.append((partes[0].lower(), ".".join(partes[1:-1]), partes[-1].lower(), valor))
            continue
        chave = chave_re.match(linha)
        if not chave:
            continue
        saida.append((secao, sub, chave.group(1).lower(), _valor_config(chave.group(2))))
    return saida


def _host_de(url: str) -> str:
    u = url.strip()
    if not u:
        return ""
    baixo = u.lower()
    if baixo.startswith("git@"):
        return u[4:].split(":", 1)[0].lower()
    if "://" not in u:
        return ""
    sem = u.split("://", 1)[1].split("/", 1)[0]
    if "@" in sem:
        sem = sem.rsplit("@", 1)[1]
    return sem.split(":", 1)[0].lower().strip("[]")


def _reescreve_github(valor: str) -> bool:
    """O `insteadOf` troca uma URL do GitHub (outro host ou outro `dono/repo`)."""
    v = valor.strip().lower()
    if not v:
        return False
    if _host_de(valor) in _HOSTS_GITHUB:
        return True
    return any(base.startswith(v) or v.startswith(base) for base in _PREFIXOS_GITHUB)


def _motivo_chave(onde: str, secao: str, sub: str, chave: str, valor: str) -> str:
    """Motivo para recusar esta chave do config local/worktree, ou vazio."""
    if chave == "pushurl" and valor.strip():
        quem = f"remote.{sub}.pushurl" if secao == "remote" and sub else "pushurl"
        return f"o config {onde} tem `{quem}`; o push não usa pushurl"
    if secao == "core" and chave == "sshcommand" and valor.strip():
        return f"o config {onde} tem `core.sshCommand`"
    if secao == "core" and chave == "fsmonitor" and valor.strip():
        return f"o config {onde} tem `core.fsmonitor`"
    if secao == "credential" and chave == "helper":
        return f"o config {onde} tem `credential.helper`"
    if secao in ("include", "includeif") and valor.strip():
        return f"o config {onde} tem `include`"
    if secao == "filter" and valor.strip():
        return f"o config {onde} tem `filter.{sub or chave}`"
    if secao == "url" and chave in ("insteadof", "pushinsteadof"):
        if not valor.strip() or _reescreve_github(valor):
            nome = "pushInsteadOf" if chave == "pushinsteadof" else "insteadOf"
            return f"o config {onde} reescreve o GitHub com `url.*.{nome}`"
    return ""


def _diretorios_git(wt: Path) -> list[Path]:
    """Diretório comum e, se for worktree ligado, o gitdir dele. Vazio se não é repo."""
    ponteiro = wt / ".git"
    if ponteiro.is_dir():
        return [ponteiro]
    if not ponteiro.is_file():
        return []
    try:
        linhas = ponteiro.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    linha = linhas[0].strip() if linhas else ""
    if not linha.lower().startswith("gitdir:"):
        return []
    bruto = linha.split(":", 1)[1].strip()
    if not bruto:
        return []
    gitdir = Path(bruto)
    gitdir = gitdir.resolve() if gitdir.is_absolute() else (wt / gitdir).resolve()
    comum = gitdir
    arquivo = gitdir / "commondir"
    if arquivo.is_file():
        try:
            rel = arquivo.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            rel = ""
        if rel:
            comum = (gitdir / rel).resolve()
    if comum == gitdir:
        return [gitdir]
    return [comum, gitdir]


def _arquivos_config(wt: Path) -> list[tuple[str, Path]]:
    dirs = _diretorios_git(wt)
    if not dirs:
        return []
    comum, gitdir = dirs[0], dirs[-1]
    return [("local", comum / "config"), ("worktree", gitdir / "config.worktree")]


def diagnostico_config(wt: Path) -> tuple[str, str]:
    """(motivo, url do `origin`). Motivo vazio = config local e de worktree aceitável.

    Lê o arquivo em vez de `git config`: `include`, `fsmonitor` e `credential.helper`
    não podem rodar durante o guard. A url do worktree, se houver, prevalece.
    """
    origem = ""
    for onde, caminho in _arquivos_config(wt):
        if not caminho.is_file():
            continue
        try:
            texto = caminho.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return f"não consegui ler o config {onde} do git", ""
        for secao, sub, chave, valor in _parse_gitconfig(texto):
            motivo = _motivo_chave(onde, secao, sub, chave, valor)
            if motivo:
                return motivo, ""
            if secao == "remote" and sub.lower() == "origin" and chave == "url" and valor.strip():
                origem = valor.strip()
    return "", origem


def url_explicita(github: str, origem: str) -> str:
    """URL de push a partir do `dono/repo` do cadastro, no esquema do `origin`.

    HTTPS, ou SSH (`git@` ou `ssh://`) quando o `origin` já é SSH. `http` sobe
    para `https`. O host que não é o GitHub não entra: o slug é o do cadastro.
    Não lê `pushurl`.
    """
    slug = projetos.normalizar_github(github)
    if not slug:
        return ""
    bruto = (origem or "").strip()
    baixo = bruto.lower()
    if baixo.startswith("git@") and ":" in bruto[4:]:
        host = bruto[4:].split(":", 1)[0].lower()
        if host not in ("github.com", "ssh.github.com"):
            host = "github.com"
        return f"git@{host}:{slug}.git"
    if baixo.startswith("ssh://"):
        sem = bruto[6:]
        if "@" in sem.split("/", 1)[0]:
            sem = sem.split("@", 1)[1]
        hostport = sem.split("/", 1)[0]
        host, sep, porta = hostport.partition(":")
        host = host.lower()
        if host not in ("github.com", "ssh.github.com"):
            host, sep, porta = "github.com", "", ""
        porta_s = f":{porta}" if sep and porta else ""
        return f"ssh://git@{host}{porta_s}/{slug}.git"
    return f"https://github.com/{slug}.git"


def motivo_para_nao_enviar(wt: Path) -> str:
    """Vazio se a branch pode ir para o repositório do cadastro; senão o motivo.

    Primeira barreira, antes de qualquer git que possa executar o config da pasta:
    0. O config local/worktree não tem `pushurl`, `insteadOf`/`pushInsteadOf` que
       reescreva o GitHub, `core.sshCommand`, `credential.helper`, `include`,
       `core.fsmonitor` nem `filter`.
    1. O `origin` da pasta é o repositório do GitHub do cadastro (FRA-567).
    2. A branch tem a `origin/main` atual na história. Uma branch criada antes
       de o repositório recomeçar (histórico antigo, sem ancestral comum) levaria
       todo o histórico antigo junto no push.
    3. O `antes_do_push` do projeto (ex.: conferência de publicação) sai 0.

    A segunda barreira é `enviar_branch`: o push usa a URL explícita do cadastro.
    """
    motivo, origem = diagnostico_config(wt)
    if motivo:
        return motivo
    esperado = projeto().github
    atual = projetos.normalizar_github(origem)
    if not esperado:
        return "o projeto não tem o repositório do GitHub no cadastro (Ajustes › Projetos)"
    if atual != esperado:
        return (f"o `origin` da pasta é `{atual or 'nenhum'}`, mas o projeto é do repositório "
                f"`{esperado}`; confira a pasta no cadastro")
    env = ambiente_git()
    sh(["git", "fetch", "-q", "origin", "main"], cwd=wt, check=False)
    base = subprocess.run(argv_git(["git", "merge-base", "HEAD", "origin/main"]), cwd=wt,
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


def enviar_branch(wt: Path, branch: str) -> str:
    """Envia `HEAD` para a URL do cadastro. Vazio se enviou; senão o motivo.

    Segunda barreira: não é `git push origin` (isso honraria `pushurl`) e não leva
    `-u`. `-u` com a URL solta gravaria o upstream nessa URL. O rastreio fica no
    remote `origin`.
    """
    branch = str(branch or "").strip()
    if (not branch or branch.startswith(("-", "/")) or branch.endswith(("/", ".lock"))
            or any(c in branch for c in "\n\r\t ~^:?*[\\")
            or any(p in ("", ".", "..") for p in branch.split("/"))):
        return "nome de branch inválido para o push"
    motivo, origem = diagnostico_config(wt)
    if motivo:
        return motivo
    esperado = projeto().github
    if not esperado:
        return "o projeto não tem o repositório do GitHub no cadastro (Ajustes › Projetos)"
    url = url_explicita(esperado, origem)
    if projetos.normalizar_github(url) != esperado:
        return f"a URL de push `{url or 'nenhuma'}` não é a do repositório `{esperado}`"
    sh(["git", "push", "-q", url, f"HEAD:{branch}"], cwd=wt, timeout=180)
    # O fetch não criou `origin/<branch>`: o push foi para a URL, não para o remote.
    sh(["git", "update-ref", f"refs/remotes/origin/{branch}", "HEAD"], cwd=wt, check=False)
    sh(["git", "branch", "--set-upstream-to", f"origin/{branch}", branch], cwd=wt, check=False)
    return ""


def prepare_worktree(branch: str, identifier: str) -> Path:
    repo, wts = projeto_repo(), projeto_worktrees()
    wt = wts / identifier.lower()
    if wt.exists():
        # Retomada de um card claimado antes da normalização (ex.: FRA-630): a branch
        # do worktree tem o nome do Linear; passa para o nome seguro do estado.
        atual = sh([GIT, "branch", "--show-current"], cwd=wt, check=False).strip()
        if atual and atual != branch and branch_segura(atual, identifier) == branch:
            sh([GIT, "branch", "-m", atual, branch], cwd=wt)
        copiar_para_worktree(repo, wt, projeto().copiar_para_worktree)
        return wt
    sh([GIT, "fetch", "-q", "origin", "main"], cwd=repo)
    remote = sh([GIT, "ls-remote", "--heads", "origin", branch], cwd=repo, check=False)
    local = sh([GIT, "branch", "--list", branch], cwd=repo, check=False)
    if remote:
        sh([GIT, "fetch", "-q", "origin", f"{branch}:{branch}"], cwd=repo, check=False)
        sh([GIT, "worktree", "add", "-q", str(wt), branch], cwd=repo)
    elif local:
        sh([GIT, "worktree", "add", "-q", str(wt), branch], cwd=repo)
    else:
        sh(["git", "worktree", "add", "-q", "-b", branch, str(wt), "origin/main"], cwd=repo)
    # .lane/ (só o result.json do agente) nunca vai para o git.
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
    env = ambiente_git()
    try:
        tem = subprocess.run(argv_git(["git", "rev-parse", "-q", "--verify", "origin/main"]), cwd=wt,
                             capture_output=True, text=True, env=env, timeout=60)
        if tem.returncode != 0:
            return False  # sem origin/main local (fetch falhou): não dá para afirmar
        base = subprocess.run(argv_git(["git", "merge-base", "HEAD", "origin/main"]), cwd=wt,
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
    env = ambiente_git()

    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(argv_git(["git", *args]), cwd=wt, capture_output=True, text=True, env=env, timeout=180)

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
    if catalogo.transporte_da_lane(lane) == "acp":
        return "sem teto de gasto no CLI (ACP: o custo vem do agente, no ledger)"
    cli = catalogo.cli_da_lane(lane)
    if cli == "grok":
        return f"limite {GROK_MAX_TURNS[effort]} turnos"
    if cli == "dsh":
        return "sem teto de gasto no CLI"
    return f"teto US$ {BUDGET_USD[effort]}"


def claim(lane: str, issue: dict, effort: str, measure: str = "") -> None:
    card = linear(QUERY_ISSUE, {"id": issue["id"]})["issue"]
    ident = card["identifier"]
    branch = branch_segura(card["branchName"], ident)
    nota_branch = ("" if branch == card["branchName"] else
                   f"- a branch do Linear (`{card['branchName']}`) tem caractere que o git das lanes "
                   f"não aceita; usando `{branch}`\n")
    wt = prepare_worktree(branch, ident)
    linha_main, nota_main = juntar_main(wt)
    if historico_antigo(wt):
        # FRA-443 (29/10): a branch local era do repositório antigo; a lane rodou opus xhigh
        # sobre código velho e o push seria barrado no fim. Melhor falhar antes de gastar.
        raise RuntimeError(
            f"a branch `{branch}` não tem ancestral comum com a `origin/main` (histórico "
            f"antigo do repositório). Nada foi rodado. Se ela não tem trabalho a salvar, recrie-a no "
            f"worktree com `git checkout -B {branch} origin/main` e devolva o card à fila")
    # FRA-595: a prova e o comando nascem fora do worktree. `.lane` só existe
    # para o agente gravar result.json; o dispatcher não escreve esse arquivo.
    run_id = secrets.token_hex(16)
    prova = preparar_prova_dir({"lane": lane, "card": ident, "run_id": run_id}, wt)
    preparar_lane_do_agente(wt)

    base_prompt = caminho_prompt("lane-prompt.md")
    template = base_prompt.read_text(encoding="utf-8") if base_prompt.is_file() else ""
    # regras específicas do agente (pelo manifesto da lane); lane ACP usa as do transporte
    cli = catalogo.cli_da_lane(lane)
    extra = caminho_prompt("lane-prompt-acp.md" if catalogo.transporte_da_lane(lane) == "acp"
                           else f"lane-prompt-{catalogo.perfil_da_lane(lane)}.md")
    if extra.is_file():
        template += "\n" + extra.read_text(encoding="utf-8")
    prompt = (template.replace("{{CARD}}", ident).replace("{{LANE}}", lane)
              .replace("{{BRANCH}}", branch).replace("{{WORKTREE}}", str(wt)))
    prompt += resume_note(wt)
    prompt += nota_main
    bancada = bancada_ativa(lane, issue)
    if bancada:
        prompt += TEXTO_BANCADA.replace("{comando}", str(COMANDO_BANCADA))
    escrever_exclusivo(prova / "card.md",
                       f"# {ident} — {card['title']}\n\n{card['url']}\n\n{card.get('description') or ''}\n")
    prompt_file = prova / "prompt.md"
    escrever_exclusivo(prompt_file, prompt)

    # dsh: o patch do perfil (conta + modelo + esforço) vai junto com o prompt.
    patch_file = None
    if cli == "dsh":
        patch_file = prova / "deepseek.yml"
        escrever_exclusivo(patch_file, deepseek_patch(effort, lane))

    # FRA-618: settings do modo bancada no RUN_DIR (fora do worktree, a lane não reescreve).
    settings_file = None
    if bancada:
        settings_file = prova / "claude-settings-bancada.json"
        escrever_exclusivo(settings_file, json.dumps(settings_bancada(lane_settings()), indent=2))

    # FRA-598: o perfil do Grok tem de existir antes do processo. Sem ele o CLI
    # recusa subir, em vez de rodar sem o deny de `security` e dos segredos.
    if cli == "grok":
        escrever_perfil_sandbox()

    # FRA-374: o `--` fecha o parsing de flags do CLI. Sem ele, um token do
    # prompt como `--check` (git diff --check) é lido como flag e o CLI aborta.
    # FRA-595: o comando fica no RUN_DIR, com nonce no nome. O runner recebe o
    # caminho por argv e não lê `.lane/agent_cmd`.
    agent_text = texto_do_agente(lane, effort, prompt_file, patch_file, settings_file)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    LANE_LOG_DIR.mkdir(parents=True, exist_ok=True)
    lane_log = LANE_LOG_DIR / f"{ident}-{lane}-{stamp}.jsonl"
    cmd_path = prova / f"agent_cmd.{secrets.token_hex(16)}"
    escrever_exclusivo(cmd_path, agent_text + "\n")

    # FRA-267: commit de partida. O caminho protegido se confere só no que a lane fez
    # depois dele: a branch pode já trazer commits de pessoas (ex.: FRA-13).
    base = sh([GIT, "rev-parse", "HEAD"], cwd=wt)
    st = {"lane": lane, "card": ident, "issue_id": card["id"], "title": card["title"],
          "url": card["url"], "branch": branch, "worktree": str(wt), "base": base,
          "effort": effort, "modelo": modelo_da_lane(lane, effort),
          "modelo_fixo": aviso_modelo(lane, effort) == "modelo fixo",
          "aviso_modelo": aviso_modelo(lane, effort),
          "started": time.time(), "started_at": now(),
          "log": str(lane_log), "session": f"lane-{lane}",
          "run_id": run_id, "agent_cmd": str(cmd_path), "bancada": bancada}
    save_state(lane, st)
    gravar_claim(lane, st)

    flags = (deepseek_resumo(effort, lane) if cli == "dsh"
             else " ".join(flags_da_lane(lane, effort)) or "padrão do CLI")
    linear(MUT_COMMENT, {"id": card["id"], "body":
        f"▶️ **lane:{lane}** assumiu o card ({now()}).\n\n"
        f"- esforço `{effort}` → `{flags}`, {limit_text(lane, effort)}, timeout {LANE_TIMEOUT_MIN} min\n"
        f"- branch `{branch}`, worktree local\n"
        + nota_branch
        + linha_main
        + (f"- lane escolhida pela medida: {measure}\n" if measure else "")
        + ("- 🔌 modo bancada: só o comando `bancada` (USB), com auditoria fora do worktree\n"
           if bancada else "") +
        f"- o agente não fala com Linear/GitHub; o dispatcher fecha o card ao final"})

    session = st["session"]
    if tmux_alive(session):
        sh([TMUX, "kill-session", "-t", session], check=False)
    runner = caminho_runner()
    sh([TMUX, "new-session", "-d", "-s", session, "-c", str(wt),
        " ".join([
            "bash", shlex.quote(str(runner)),
            shlex.quote(lane), shlex.quote(str(wt)), shlex.quote(ident),
            shlex.quote(str(lane_log)), shlex.quote(str(cmd_path)), shlex.quote(str(prova)),
            shlex.quote(cli or lane),
        ])])
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


# FRA-595: higiene no mesmo usuário. Não isola processo — o fechamento real é
# a fase 5 do FRA-589. O que este código faz é não confiar em arquivo que o
# agente escreve no worktree.
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_NOME_SEGURO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$")
_LIXO_LANE = (
    "exit_code", "result.json", "finalized", "triagem_reprova", "agent_cmd",
    "freio.txt", "card.md", "prompt.md", "deepseek.yml", "proof_exit", "proof_pid",
    "proof_started", "proof.log", "proof_morta", "proof_retries",
)


def nome_seguro(valor: str) -> str:
    if not isinstance(valor, str) or not _NOME_SEGURO.fullmatch(valor):
        raise RuntimeError(f"nome recusado: {valor!r}")
    return valor


def _caminho_dentro(filho: Path, pai: Path) -> bool:
    """True se `filho` está em `pai`, sem seguir symlink."""
    f = filho.absolute().parts
    p = pai.absolute().parts
    return len(f) >= len(p) and f[:len(p)] == p


def exigir_dir_real(path: Path, mode: int = 0o700) -> None:
    """Cria ou confere um diretório. Symlink é recusado. O modo sai por fchmod."""
    if path.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    if not path.exists():
        path.mkdir(mode=mode)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | _NOFOLLOW
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise RuntimeError(f"não é diretório real: {path}")
        os.fchmod(fd, mode)
        info = os.fstat(fd)
        if (info.st_mode & 0o777) != mode:
            raise RuntimeError(f"permissão de {path} não ficou {mode:04o}")
    finally:
        os.close(fd)


def prova_dir(st: dict) -> Path:
    """STATE_DIR/provas/<lane>/<card>/<run_id>. Não cria a pasta."""
    lane = nome_seguro(str(st["lane"]))
    card = nome_seguro(str(st["card"]))
    run_id = nome_seguro(str(st["run_id"]))
    return STATE_DIR / "provas" / lane / card / run_id


def preparar_prova_dir(st: dict, wt: Optional[Path] = None) -> Path:
    """Pasta 0700 da rodada, fora do worktree. O agente não escreve aqui."""
    leaf = prova_dir(st)
    if wt is not None and _caminho_dentro(leaf, wt):
        raise RuntimeError("a prova não pode ficar no worktree")
    if STATE_DIR.is_symlink():
        raise RuntimeError(f"symlink recusado: {STATE_DIR}")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    base = STATE_DIR / "provas"
    for parte in (base, base / nome_seguro(str(st["lane"])),
                  base / nome_seguro(str(st["lane"])) / nome_seguro(str(st["card"])), leaf):
        exigir_dir_real(parte, 0o700)
    return leaf


def escrever_exclusivo(path: Path, texto: str, mode: int = 0o600) -> None:
    """Cria o arquivo com O_NOFOLLOW|O_EXCL. Não segue symlink e não sobrescreve."""
    if path.is_symlink() or path.parent.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    data = texto.encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            if n <= 0:
                raise OSError(f"escrita vazia em {path}")
            view = view[n:]
    finally:
        os.close(fd)


def ler_sem_seguir(path: Path, limite: int = 8_000_000) -> str:
    """Lê um arquivo regular. Symlink no pai ou no arquivo é recusado."""
    if path.is_symlink() or path.parent.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    fd = os.open(path, os.O_RDONLY | _NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError(f"não é arquivo regular: {path}")
        blocos = []
        total = 0
        while total < limite:
            pedaco = os.read(fd, min(1 << 20, limite - total))
            if not pedaco:
                break
            blocos.append(pedaco)
            total += len(pedaco)
        return b"".join(blocos).decode("utf-8", "replace")
    finally:
        os.close(fd)


def ler_arquivo_lane(path: Path) -> str:
    """Lê um arquivo de `.lane` depois de lstat no diretório e no arquivo.

    Recusa symlink. O dispatcher não grava `result.json`; só lê o que o agente
    deixou, e só se for um arquivo regular.
    """
    lane = path.parent
    if lane.name != ".lane" or lane.is_symlink():
        raise RuntimeError(f"symlink recusado: {lane}")
    info = lane.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"symlink recusado: {lane}")
    if path.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    return ler_sem_seguir(path)


def preparar_lane_do_agente(wt: Path) -> Path:
    """`.lane` real, vazio de arquivos de controle. Não cria `result.json`."""
    lane = wt / ".lane"
    if lane.is_symlink():
        raise RuntimeError(f"symlink recusado: {lane}")
    if lane.exists():
        info = lane.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise RuntimeError(f"symlink recusado: {lane}")
        for nome in _LIXO_LANE:
            alvo = lane / nome
            if alvo.is_symlink() or (alvo.exists() and not alvo.is_dir()):
                alvo.unlink()
        for alvo in list(lane.glob("proof*")):
            if alvo.is_symlink() or alvo.is_file():
                alvo.unlink()
    else:
        lane.mkdir(mode=0o755)
    info = lane.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"symlink recusado: {lane}")
    return lane


def identidade_do_processo(pid: int) -> Optional[dict]:
    """uid, início e comando. None se o pid não existe. Não mata ninguém."""
    if not isinstance(pid, int) or pid <= 1:
        return None
    if sys.platform == "linux" and Path(f"/proc/{pid}/stat").exists():
        try:
            status = Path(f"/proc/{pid}/status").read_text(encoding="utf-8", errors="replace")
            stat_txt = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(
                "utf-8", "replace").strip()
        except OSError:
            return None
        uid = None
        for linha in status.splitlines():
            if linha.startswith("Uid:"):
                partes = linha.split()
                if len(partes) >= 2:
                    uid = int(partes[1])
        depois = stat_txt.rsplit(")", 1)
        if uid is None or len(depois) != 2:
            return None
        campos = depois[1].split()
        if len(campos) < 20:
            return None
        return {"uid": uid, "start": campos[19], "cmd": cmd}
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "uid=,lstart=,command="],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    linha = out.stdout.strip()
    if out.returncode != 0 or not linha:
        return None
    partes = linha.split(None, 1)
    if len(partes) < 2:
        return None
    resto = partes[1]
    pedacos = resto.split(None, 5)
    if len(pedacos) < 6:
        return None
    try:
        uid = int(partes[0])
    except ValueError:
        return None
    return {"uid": uid, "start": " ".join(pedacos[:5]), "cmd": pedacos[5]}


def registrar_prova(prova: Path, pid: int, marcador: str) -> None:
    """Grava pid, dono, início e comando. O marcador tem que estar no cmdline."""
    if not marcador:
        raise RuntimeError("prova sem marcador")
    ident = identidade_do_processo(pid)
    if ident is None:
        meta = {"pid": pid, "uid": os.getuid(), "start": None, "marcador": marcador}
    else:
        if ident["uid"] != os.getuid() or marcador not in ident["cmd"]:
            raise RuntimeError("o processo da prova não confere com o comando")
        meta = {"pid": pid, "uid": ident["uid"], "start": ident["start"], "marcador": marcador}
    escrever_exclusivo(prova / "proof_meta.json", json.dumps(meta))
    escrever_exclusivo(prova / "proof_pid", f"{pid}\n")
    escrever_exclusivo(prova / "proof_started", f"{time.time()}\n")


def _meta_da_prova(prova: Path) -> Optional[dict]:
    try:
        meta = json.loads(ler_sem_seguir(prova / "proof_meta.json"))
    except (OSError, RuntimeError, ValueError):
        return None
    return meta if isinstance(meta, dict) else None


def classificar_pid(prova: Path) -> str:
    """'nosso-vivo', 'nosso-morto', 'alheio' ou 'ausente'. Não mata."""
    meta = _meta_da_prova(prova)
    if not meta:
        return "ausente"
    pid = meta.get("pid")
    if not isinstance(pid, int) or pid <= 1 or meta.get("uid") != os.getuid():
        return "alheio"
    ident = identidade_do_processo(pid)
    if ident is None:
        return "nosso-morto"
    if ident["uid"] != meta.get("uid") or str(ident["start"]) != str(meta.get("start")):
        return "alheio"
    if not prova_viva(pid):
        return "nosso-morto"
    marcador = str(meta.get("marcador") or "")
    if not marcador or marcador not in ident["cmd"]:
        return "alheio"
    return "nosso-vivo"


def pid_validado(prova: Path) -> Optional[int]:
    """Pid do grupo da prova, só se dono, início e comando conferem."""
    if classificar_pid(prova) != "nosso-vivo":
        return None
    meta = _meta_da_prova(prova)
    if not meta:
        return None
    pid = meta.get("pid")
    return pid if isinstance(pid, int) else None


def archive_old_proofs(prova: Path, ident: str) -> None:
    """Move proof* da pasta da rodada para STATE_DIR/stale-proof-<card>-<HHMM>.

    Não lê `.lane/proof*`: arquivo plantado no worktree não entra no histórico
    que o painel conta.
    """
    if not prova.exists() or prova.is_symlink():
        return
    try:
        info = prova.lstat()
    except OSError:
        return
    if not stat.S_ISDIR(info.st_mode):
        return
    old = []
    for candidato in sorted(prova.iterdir()):
        if not candidato.name.startswith("proof") or candidato.is_symlink():
            continue
        if candidato.is_file():
            old.append(candidato)
    if not old:
        return
    dest = STATE_DIR / f"stale-proof-{ident.lower()}-{dt.datetime.now():%H%M}"
    dest.mkdir(parents=True, exist_ok=True)
    for f in old:
        f.rename(dest / f.name)
    log(f"{ident}: {len(old)} proof* antigos arquivados em {dest}")


def discard_stale_proof(prova: Path, ident: str, round_started: float) -> bool:
    """FRA-282: só vale a prova desta rodada. Se o proof_started é mais velho que o início
    da rodada (ou ilegível), arquiva os proof* e devolve True; a prova roda de novo."""
    ps = prova / "proof_started"
    if ps.is_symlink() or not ps.is_file():
        return False
    try:
        when = float(ler_sem_seguir(ps) or 0)
    except (OSError, RuntimeError, ValueError):
        when = 0.0
    if when >= round_started:
        return False
    archive_old_proofs(prova, ident)
    return True


# --- Acompanhamento e fechamento --------------------------------------------
def nomes_do_diff(wt: Path, spec: str) -> list[str]:
    """Caminhos completos do diff, sem o escape octal do `core.quotepath`.

    O padrão do git cita non-ASCII entre aspas (`relat\\303\\263rio.docx`) e o
    `fnmatch` não casa o glob do cadastro. `-z` separa por NUL; a decodificação
    é UTF-8 para o acento não depender do locale do processo.
    """
    out = subprocess.run(
        argv_git([GIT, "-c", "core.quotepath=false", "diff", "--name-only", "-z", spec]),
        cwd=wt, capture_output=True, env=ambiente_git(), timeout=120,
    )
    if out.returncode != 0:
        erro = out.stderr.decode("utf-8", "replace").strip()[:300]
        raise RuntimeError(f"git diff… falhou ({out.returncode}): {erro}")
    texto = out.stdout.decode("utf-8", "surrogateescape")
    return [p for p in texto.split("\0") if p]


def git_summary(wt: Path, base: Optional[str] = None) -> dict:
    """`files`: tudo o que a branch muda em relação à main (vai no PR).
    `new` e `lane_files`: só o que a lane fez desde `base` (sem base, estado antigo, vale a main).

    Não chama git se o config local ou de worktree for recusado: o fetch e o
    `status` rodariam `credential.helper` e `core.fsmonitor`."""
    motivo, _origem = diagnostico_config(wt)
    if motivo:
        return {"ahead": 0, "new": 0, "files": [], "lane_files": [], "dirty": [], "sha": ""}
    sh(["git", "fetch", "-q", "origin", "main"], cwd=wt, check=False)
    ahead = int(sh(["git", "rev-list", "--count", "origin/main..HEAD"], cwd=wt) or 0)
    files = nomes_do_diff(wt, "origin/main...HEAD")
    if base:
        new = int(sh([GIT, "rev-list", "--count", f"{base}..HEAD"], cwd=wt) or 0)
        desde_base = nomes_do_diff(wt, f"{base}..HEAD")
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
    # SHA completo (40). O DONE usa este valor; o vigia compara com ==, não com prefixo.
    sha = sh(["git", "rev-parse", "HEAD"], cwd=wt)
    return {"ahead": ahead, "new": new, "files": files, "lane_files": lane_files, "dirty": dirty, "sha": sha}


def read_result(wt: Path) -> Optional[dict]:
    """O agente grava `.lane/result.json`. Symlink é recusado; o dispatcher não escreve o arquivo."""
    try:
        r = json.loads(ler_arquivo_lane(wt / ".lane" / "result.json"))
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
        # Saída em texto (dsh/DeepSeek) pode ter linha que é JSON mas não objeto ("ok", 3).
        # Era ela que derrubava o fechamento: `'str' object has no attribute 'get'` (FRA-608, FRA-652).
        if not isinstance(ev, dict):
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

    Casos, e a distinção é o que segura o auto-pick:
      - pct conhecido                                   → o número;
      - código sem janela (`fila.SEM_LIMITE`)           → 0.0 (sem teto: folga total);
      - código `saldo` com saldo ≥ piso do esforço baixo → `fila.PCT_ORDEM_SALDO` (paga por uso:
        atrás das cotas incluídas com folga; o piso por esforço fica no `headroom_block`);
      - sem código e `janela == sem dado`               → 0.0 (formato antigo);
      - sem pct com outro motivo                        → None (leitura falhou: fora).
    Sem os casos sem pct, uma lane com o Console fora do ar ficava esperando folga
    que ninguém ia medir (FRA-470).
    """
    if medida is None:
        return None
    pct, janela = medida[0], (medida[1] if len(medida) > 1 else "")
    if pct is not None:
        return float(pct)
    codigo = fila.codigo_medida(medida)
    if codigo in fila.SEM_LIMITE:
        return 0.0
    if codigo == fila.CODIGO_SALDO:
        return fila.PCT_ORDEM_SALDO if fila.folga_sem_pct(medida, "baixo") else None
    return 0.0 if janela == SEM_JANELA else None


def headroom_block(lane: str, effort: str, measures: dict) -> Optional[str]:
    """Motivo para segurar o card (conta sem folga para o esforço), ou None."""
    m = measures.get(lane)
    if m and m[0] is None and fila.codigo_medida(m) == fila.CODIGO_SALDO:
        if not fila.folga_sem_pct(m, effort):
            saldo = fila.saldo_medida(m)
            return (f"saldo US$ {saldo if saldo is not None else 0:.2f}; card `{effort}` "
                    f"só entra com US$ {fila.piso_saldo(effort):.2f} ou mais")
        return None
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
            return medidas_com_contas({k: tuple(v) for k, v in c["m"].items()})
    except (OSError, ValueError, KeyError, TypeError):
        pass
    m, _ = measure_lanes(renew=real)
    # Mesmo sem medida, grava o at: assim o painel sabe que a leitura é de agora
    # e não repete para sempre o último 100% de dois dias atrás.
    try:
        cache.write_text(json.dumps({"at": time.time(), "m": m}))
    except OSError:
        pass
    return medidas_com_contas(m)


def medidas_com_contas(m: dict) -> dict:
    """Lane ACP mede pela conta (`catalogo.medidas_com_contas`, o mesmo do vigia)."""
    return catalogo.medidas_com_contas(m)


def lane_limited_conta(lane: str) -> Optional[float]:
    """Limite da lane ou, numa lane ACP, o da lane da conta dela."""
    u = lane_limited(lane)
    conta = catalogo.conta_da_lane(lane)
    if u is None and conta != lane and conta in LANES:
        u = lane_limited(conta)
    return u


def situacao_simultaneo(conta: str, na_conta) -> Optional[str]:
    """Motivo para a conta rodar uma lane por vez (PRD lanes-v2, fase 2), ou None.

    - Teste reprovado: uma por vez, em qualquer conta partilhada.
    - Conta com lane extra (instância) ligada: uma por vez até o teste aprovar, e de novo
      se ele vencer. O par do catálogo `opencode` + `opencode-go` já rodava junto e só
      cai para uma por vez com teste reprovado."""
    try:
        import teste_simultaneo as ts
    except ImportError:  # pragma: no cover — bundle sem o módulo: a conta fica como antes
        return None
    try:
        estado, texto = ts.situacao(conta, STATE_DIR)
    except ValueError:
        return None
    if estado == "reprovado":
        return texto
    if estado == "aprovado":
        return None
    ligadas = enabled_lanes()
    if any(catalogo.instancia(l) is not None and l in ligadas for l in na_conta):
        lane_teste = next((l for l in na_conta if l in ligadas), na_conta[0])
        return f"{texto}; rode `teste_simultaneo.py {lane_teste}`"
    return None


def bloqueio_por_conta(lane: str, a_assumir=()) -> Optional[str]:
    """Motivo para segurar a lane: a conta já tem o máximo de lanes rodando.

    Só vale quando a conta é partilhada por mais de uma lane (instâncias, ou `opencode` e
    `opencode-go`). O máximo é `lanes.limite_conta` (sem limite por padrão: a cota segura)
    ou 1, enquanto a conta não tem teste de execução simultânea aprovado (fase 2)."""
    conta = catalogo.conta_da_lane(lane)
    na_conta = [l for l in LANES if catalogo.conta_da_lane(l) == conta]
    if len(na_conta) <= 1:
        return None
    limite = catalogo.limite_por_conta(conta)
    motivo = f"limite {limite}" if limite is not None else ""
    sim = situacao_simultaneo(conta, na_conta)
    if sim and (limite is None or limite > 1):
        limite, motivo = 1, f"limite 1: {sim}"
    if limite is None:
        return None
    pegando = {item[0] for item in a_assumir}
    ocupadas = [l for l in na_conta if l in pegando or load_state(l)]
    if len(ocupadas) >= limite:
        return (f"conta `{conta}` com {len(ocupadas)} lane(s) rodando "
                f"({', '.join(sorted(ocupadas))}); {motivo}")
    return None


def resume_note(wt: Path) -> str:
    """Prompt da retomada: worktree com trabalho de rodada anterior não pode ser refeito."""
    try:
        dirty = [l for l in sh([GIT, "status", "--porcelain"], cwd=wt, check=False).splitlines()
                 if l.strip() and ".lane/" not in l]
        ahead = sh([GIT, "rev-list", "--count", "origin/main..HEAD"], cwd=wt, check=False).strip()
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
    # O id vem do log do agente: sem o formato seguro, a linha não entra no comentário.
    cli_lane = catalogo.cli_da_lane(st["lane"])
    if not sid or not sessao_citavel(sid) or cli_lane == "dsh":
        return ""   # o dsh headless não expõe `--resume` nem session_id no stdout
    cli = "grok" if cli_lane == "grok" else "claude"
    return (
        f"- retomar o agente: `cd {shlex.quote(st['worktree'])} && {cli} --resume {shlex.quote(sid)}`\n"
    )


def pending_lines(st: dict) -> str:
    """FRA-269: trabalho pronto não fica invisível. Lista o que está sem commit e os
    commits da lane ainda não enviados.

    O `fail` da recusa passa por aqui. Sem o config aceito, `git status` rodaria
    o `core.fsmonitor` que o guard acabou de recusar."""
    wt = Path(st["worktree"])
    motivo, _origem = diagnostico_config(wt)
    if motivo:
        return ""
    try:
        dirty = [l for l in sh([GIT, "status", "--porcelain"], cwd=wt, check=False).splitlines() if l.strip()]
        base = st.get("base")
        commits = (sh([GIT, "log", "--oneline", f"{base}..HEAD"], cwd=wt, check=False).splitlines()
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
            saida = sh([GIT, "rev-list", "--count", f"{base}..HEAD"], cwd=wt)
            novo = int(saida or 0)
        dirty = [l for l in sh([GIT, "status", "--porcelain"], cwd=wt).splitlines()
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
        f"⏳ **lane:{st['lane']}** parou pelo **limite de uso {'do provedor (HTTP 429)' if catalogo.cli_da_lane(st['lane']) == 'opencode' else 'da conta'}** (não é erro do card).\n\n"
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
# Nome de suíte: identificador com pontos (`FooTests`, `tests.test_parser`).
# `re.fullmatch` rejeita caminho (`/`, `..`), flag (`-`) e espaço. Tirar esses
# caracteres antes do `isalnum` deixava `../../tmp/x` passar, e `python3 {suite}`
# executava um arquivo fora do worktree.
SUITE_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")


def suite_nome_ok(nome: str) -> bool:
    return isinstance(nome, str) and bool(SUITE_RE.fullmatch(nome))


def proof_suites(res: dict) -> list[str]:
    tests = res.get("tests")
    if isinstance(tests, str):
        tests = tests.split()
    try:
        declaradas = [s for s in projeto().suites if suite_nome_ok(s)]
    except Exception:  # noqa: BLE001 — sem projeto: sem lista fechada
        declaradas = []
    permitidas = set(declaradas)
    suites = []
    for t in tests or []:
        if not suite_nome_ok(t):
            continue
        if permitidas and t not in permitidas:
            continue
        suites.append(t)
    if suites:
        return suites
    # Sem suíte válida na lane: vale a lista do projeto, nunca a de outro projeto.
    # Sem lista no projeto não há suíte padrão (TD-24): `TranscentIATests` era do iOS.
    return declaradas


_ABRE_PROVA = r"""
import os, subprocess, sys
log, saida, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(log, flags, 0o600)
except OSError as exc:
    sys.stderr.write(f"prova recusada: {exc}\n")
    sys.exit(1)
try:
    proc = subprocess.run(["/bin/bash", "-c", cmd], stdout=fd, stderr=subprocess.STDOUT)
    rc = proc.returncode
finally:
    os.close(fd)
try:
    efd = os.open(saida, flags, 0o600)
except OSError as exc:
    sys.stderr.write(f"proof_exit recusado: {exc}\n")
    sys.exit(1)
os.write(efd, (str(rc) + "\n").encode())
os.close(efd)
"""

_ARQUIVOS_PROVA = ("proof.log", "proof_exit", "proof_pid", "proof_started", "proof_meta.json")


def proof_script(wt: Path, suites: list[str], prova: Path) -> str:
    """Comando de prova. O log e o exit nascem em `prova`, com O_NOFOLLOW|O_EXCL.

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
    py = shlex.quote(sys.executable)
    log = shlex.quote(str(prova / "proof.log"))
    saida = shlex.quote(str(prova / "proof_exit"))
    return (f"cd {shlex.quote(str(wt))} && "
            f"{py} - {log} {saida} {shlex.quote(loop)} <<'PY'\n"
            f"{_ABRE_PROVA}PY\n")


def _apagar_regular(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    if path.exists():
        path.unlink()


def start_proof(wt: Path, suites: list[str], st: dict) -> None:
    """Roda a prova em segundo plano. Log, exit e pid ficam na pasta 0700 da rodada.

    O processo é líder do grupo (`start_new_session`). `matar_prova` só mata
    esse grupo se dono, início e comando conferem com o registro.
    """
    prova = preparar_prova_dir(st, wt)
    for nome in _ARQUIVOS_PROVA:
        alvo = prova / nome
        if alvo.is_symlink() or alvo.exists():
            raise RuntimeError(f"{nome} já existe na prova; recusado")
    script = proof_script(wt, suites, prova)
    proc = subprocess.Popen(["/bin/bash", "-c", script], start_new_session=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=dict(os.environ, PATH=TOOL_PATH))
    # O pid fica no arquivo e o grupo vive sozinho. Sem isto, o destrutor do
    # Popen avisa que o processo ainda roda: a gente não espera aqui.
    pid = proc.pid
    proc.returncode = 0
    try:
        registrar_prova(prova, pid, str(st["run_id"]))
        if registrar_foto(wt, pid) is None:
            log(f"prova: pid {pid} sem foto confiável (dono, início ou comando); não sinalizo este pid")
    except Exception:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
        raise


def ler_proof_exit(prova: Path) -> str:
    path = prova / "proof_exit"
    if path.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    return ler_sem_seguir(path).strip()


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


def _pid_escrito_na_worktree(wt: Path) -> Optional[int]:
    """Pid que o agente deixou em `.lane`. Não é o que o dispatcher sinaliza."""
    path = wt / ".lane" / "proof_pid"
    if not path.is_file() or path.is_symlink():
        return None
    try:
        pid = int(ler_sem_seguir(path).strip())
    except (OSError, RuntimeError, ValueError):
        return None
    return pid if pid > 0 else None


def _avisar_pid_da_worktree(wt: Path) -> None:
    """O arquivo em `.lane` não escolhe o processo. Se divergir da foto, fica no log."""
    lane_pid = _pid_escrito_na_worktree(wt)
    if lane_pid is None:
        return
    foto = _ler_foto(arquivo_prova_proc(wt))
    real = foto.get("pid") if foto else None
    if isinstance(real, int) and lane_pid != real:
        log(f"prova: proof_pid {lane_pid} não é o da foto ({real}); ignoro o arquivo")


def _sinalizar_grupo(pid: int, prova: Optional[Path]) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if prova is not None and pid_validado(prova) not in (None, pid):
            break
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
    if prova is not None:
        alvo = prova / "proof_pid"
        if not alvo.is_symlink():
            alvo.unlink(missing_ok=True)


def matar_prova(st: dict) -> None:
    """Mata o grupo da prova só se a foto fora do worktree autoriza.

    O pid em `.lane/proof_pid` nunca é o alvo. Sem foto, vale o registro da
    pasta da rodada (`pid_validado`). Foto de um processo que não é a prova
    deste worktree não recebe sinal.
    """
    try:
        prova = prova_dir(st)
    except (KeyError, RuntimeError):
        prova = None
    wt = Path(st["worktree"]) if st.get("worktree") else None
    if wt is not None:
        _avisar_pid_da_worktree(wt)
        foto = _ler_foto(arquivo_prova_proc(wt))
        if foto:
            pid = foto.get("pid")
            if not isinstance(pid, int) or not pid_autorizado(
                    pid, foto, lambda comando: comando_e_prova(wt, comando)):
                log(f"prova: pid {pid} recusado (dono, início ou comando); não sinalizo")
                return
            _sinalizar_grupo(pid, prova)
            if prova is not None:
                alvo = prova / "proof_pid"
                if not alvo.is_symlink():
                    alvo.unlink(missing_ok=True)
            return
    if prova is None:
        return
    pid = pid_validado(prova)
    if pid is None:
        return
    _sinalizar_grupo(pid, prova)
    alvo = prova / "proof_pid"
    if not alvo.is_symlink():
        alvo.unlink(missing_ok=True)


def decidir_prova_morta(prova: Path) -> str:
    """'viva', 'refazer' (uma única vez) ou 'esgotou'.

    Pid alheio não conta como prova morta e não é morto. Sem o nosso pid, segue viva.
    """
    saida = prova / "proof_exit"
    if saida.is_symlink():
        return "esgotou"
    if saida.is_file():
        meta = _meta_da_prova(prova)
        pid = meta.get("pid") if meta else None
        if isinstance(pid, int) and pid > 1:
            prova_viva(pid)
        return "viva"
    classe = classificar_pid(prova)
    if classe in ("ausente", "nosso-vivo", "alheio"):
        return "viva"
    morta = prova / "proof_morta"
    if morta.is_symlink() or morta.exists():
        return "esgotou"
    try:
        escrever_exclusivo(morta, "1\n")
    except OSError:
        return "esgotou"
    return "refazer"


def acompanhar_prova(st: dict, wt: Path, suites: list[str]) -> str:
    """Estado da prova já disparada, lida na pasta da rodada e não em `.lane`.

    'rodando': ainda no prazo. 'refeita': a prova morta começou de novo.
    'timeout', 'stop' e 'morta': o grupo já foi morto, se ainda era o nosso.
    'pronta': tem proof_exit para o veredito.
    """
    prova = preparar_prova_dir(st, wt)
    _avisar_pid_da_worktree(wt)
    stop_file = STATE_DIR / f"stop-{st['lane']}"
    if stop_file.exists():
        stop_file.unlink(missing_ok=True)
        matar_prova(st)
        return "stop"
    decisao = decidir_prova_morta(prova)
    if decisao == "refazer":
        # Mata com a foto ainda no disco. Sem isto o grupo autorizado fica sem sinal.
        matar_prova(st)
        for nome in ("proof_exit", "proof.log", "proof_pid", "proof_started", "proof_meta.json"):
            _apagar_regular(prova / nome)
        log(f"lane:{st['lane']} {st['card']}: prova morreu sem terminar; refaz uma vez")
        start_proof(wt, suites, st)
        return "refeita"
    if decisao == "esgotou":
        matar_prova(st)
        return "morta"
    saida = prova / "proof_exit"
    if saida.is_symlink():
        return "morta"
    if not saida.is_file():
        try:
            started = float(ler_sem_seguir(prova / "proof_started") or 0)
        except (OSError, RuntimeError, ValueError):
            started = 0.0
        if started and (time.time() - started) / 60 > PROOF_TIMEOUT_MIN:
            matar_prova(st)
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


def proof_attempts(wt: Path, prova: Optional[Path] = None) -> list[list[str]]:
    """O `proof.log` quebrado em tentativas, na ordem em que rodaram.

    `proof_script` anuncia cada tentativa com `[prova] <suíte>: ...` antes de rodar,
    então cada tentativa é o bloco que começa num desses anúncios. Sem o bloco, o
    log inteiro é uma tentativa só (prova de 1 tentativa, ou log antigo).

    Produção passa `prova` (a pasta da rodada). Sem isso, o parser de teste lê
    `.lane/proof.log`. O `finalize` não usa esse caminho.
    """
    log = (prova if prova is not None else wt / ".lane") / "proof.log"
    try:
        if log.is_symlink() or log.parent.is_symlink():
            return []
        lines = ler_sem_seguir(log).splitlines()
    except (OSError, RuntimeError):
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


def prova_e22(wt: Path, prova: Optional[Path] = None) -> bool:
    """Cada suíte, na última tentativa, provou que rodou teste de verdade."""
    blocos = ultimas_tentativas(proof_attempts(wt, prova))
    return bool(blocos) and all(suite_provada(b) for b in blocos)


def proof_veredito(wt: Path, rc: str = "", prova: Optional[Path] = None) -> str:
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
    blocos = proof_attempts(wt, prova)
    if not blocos:
        return "sem-dado"
    if rc == "0":
        if any(evidencia(l) for b in ultimas_tentativas(blocos) for l in b):
            return "vermelho"
        # Exit 0 sem a linha do E22 não é prova: log vazio ou 0 testes não fecham o card.
        if prova_e22(wt, prova):
            return "verde"
        return "sem-prova"
    if any(evidencia(l) for b in blocos for l in b):
        return "vermelho"
    if any("abortado pelo preflight" in l for b in blocos for l in b):
        return "preflight"
    return "vermelho"


def proof_failures(wt: Path, prova: Optional[Path] = None) -> str:
    """Resumo das linhas que explicam a falha, da tentativa que manda.

    Teste vermelho tem precedência sobre abort de preflight: se alguma tentativa
    deu erro de teste, o resumo mostra essa, senão o do preflight.
    """
    blocos = proof_attempts(wt, prova)
    com_erro = [b for b in blocos if any(evidencia(l) for l in b)]
    com_preflight = [b for b in blocos if any("abortado pelo preflight" in l for l in b)]
    escolhido = com_erro[-1] if com_erro else (com_preflight[-1] if com_preflight else None)
    if escolhido is None:
        return "  - (sem linha de erro reconhecida; ver proof.log)"
    hits = [l.strip() for l in escolhido
            if evidencia(l) or "abortado pelo preflight" in l]
    return "\n".join(f"  - `{h[:200]}`" for h in hits[-10:])


def normalizar_sha(sha: str) -> str:
    return (sha or "").strip().lower()


def sha_completo(sha: str) -> bool:
    """40 hex minúsculos. Prefixo curto não é o SHA do check."""
    return _SHA_COMPLETO.fullmatch(normalizar_sha(sha)) is not None


def normalizar_rollup(bruto) -> list:
    """`statusCheckRollup` do gh: lista, ou objeto com `nodes`/`contexts`."""
    if isinstance(bruto, dict):
        bruto = bruto.get("nodes") or bruto.get("contexts") or []
    return list(bruto) if isinstance(bruto, list) else []


def _sha_do_item(item: dict) -> str:
    for chave in ("sha", "headSha", "head_sha", "headRefOid"):
        valor = item.get(chave)
        if isinstance(valor, str) and valor.strip():
            return valor.strip()
    return ""


def checks_que_contam(sha: str, head_sha: str, checks) -> list:
    """Checks `prova-remota` cujo SHA é o head completo esperado.

    Item com SHA próprio diferente não conta, mesmo que o head do PR coincida.
    Item sem SHA só conta quando o `headRefOid` do PR é o SHA completo.
    """
    esperado = normalizar_sha(sha)
    head = normalizar_sha(head_sha)
    if not sha_completo(esperado):
        return []
    saida = []
    for item in normalizar_rollup(checks):
        if not isinstance(item, dict):
            continue
        nome = str(item.get("name") or item.get("context") or "").strip()
        if nome != NOME_CHECK_REMOTO:
            continue
        visto = normalizar_sha(_sha_do_item(item))
        if visto:
            if visto != esperado or not sha_completo(visto):
                continue
        elif head != esperado:
            continue
        saida.append(item)
    return saida


_FALHA_CHECK = {"FAILURE", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ERROR",
                "ACTION_REQUIRED", "STALE"}
_ESPERA_CHECK = {"PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "EXPECTED"}


def veredito_item(item: dict) -> str:
    """`verde`, `vermelho` ou `pendente` para um check que já conta no SHA."""
    conclusao = str(item.get("conclusion") or item.get("state") or "").strip().upper()
    status = str(item.get("status") or "").strip().upper()
    if conclusao in _FALHA_CHECK or status in _FALHA_CHECK:
        return "vermelho"
    if status in _ESPERA_CHECK or conclusao in _ESPERA_CHECK:
        return "pendente"
    if conclusao == "SUCCESS":
        return "verde"
    return "pendente"


def decisao_prova_remota(sha: str, head_sha: str, checks, *, agora: float, desde: float,
                         limite_s: float, erro: str = "") -> str:
    """`mover`, `esperar` ou `dono`.

    Verde no SHA completo move. Pendente espera. Verde noutro SHA não conta.
    Vermelho, timeout, SHA incompleto e erro de consulta chamam o dono e não movem.
    """
    if erro or not sha_completo(sha):
        return "dono"
    vereditos = [veredito_item(i) for i in checks_que_contam(sha, head_sha, checks)]
    if "vermelho" in vereditos:
        return "dono"
    if vereditos and "pendente" not in vereditos and "verde" in vereditos:
        return "mover"
    if agora - float(desde) >= float(limite_s):
        return "dono"
    return "esperar"


def url_do_check(sha: str, head_sha: str, checks) -> str:
    for item in checks_que_contam(sha, head_sha, checks):
        url = str(item.get("detailsUrl") or item.get("targetUrl") or item.get("url") or "").strip()
        if url.startswith("https://"):
            return url
    return ""


def aviso_prova_remota(st: dict) -> str:
    """Frase que o app mostra, com o link do PR e, quando existe, o do check."""
    aviso = "aguardando prova remota"
    url = str(st.get("prova_remota_url") or "").strip()
    check = str(st.get("prova_remota_check") or "").strip()
    if url:
        aviso += " " + url
    if check:
        aviso += " check " + check
    return aviso


def anotar_espera(st: dict, sha: str, url: str, check: str) -> None:
    st["prova_remota_url"] = url
    st["prova_remota_check"] = check
    st["prova_remota_sha"] = sha
    if not isinstance(st.get("prova_remota_desde"), (int, float)):
        st["prova_remota_desde"] = time.time()


def motivo_prova_remota(sha: str, head_sha: str, checks, desde: float, agora: float) -> str:
    contam = checks_que_contam(sha, head_sha, checks)
    if any(veredito_item(i) == "vermelho" for i in contam):
        return f"o check `{NOME_CHECK_REMOTO}` ficou vermelho no SHA {sha}"
    minutos = ESPERA_PROVA_REMOTA_S // 60
    if agora - float(desde) >= ESPERA_PROVA_REMOTA_S:
        return f"a prova remota passou de {minutos} min sem ficar verde no SHA {sha}"
    return f"a prova remota não autorizou o SHA {sha}"


# Histórico da prova remota para a tela de Testes do app (PRD testes-prova-remota, 08/11/2026).
PROVAS_REMOTAS = "provas-remotas.jsonl"


def registrar_prova_remota(st: dict, estado: str, sha: str = "") -> None:
    """Uma linha por desfecho (card + SHA + estado). Só acrescenta; erro não atrapalha o fechamento."""
    sha = sha or str(st.get("prova_remota_sha") or "")
    chave = f"{sha}|{estado}"
    if st.get("prova_remota_registrada") == chave:
        return
    rec = {"card": st.get("card"), "lane": st.get("lane"), "titulo": st.get("title") or "",
           "sha": sha, "pr": st.get("prova_remota_url") or "", "check": st.get("prova_remota_check") or "",
           "inicio": st.get("prova_remota_desde"), "fim": time.time(), "estado": estado}
    try:
        with open(STATE_DIR / PROVAS_REMOTAS, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        st["prova_remota_registrada"] = chave
    except OSError as exc:
        log(f"lane:{st.get('lane')} {st.get('card')}: não registrei a prova remota ({exc})")


# Main vermelha não é culpa do card (causa raiz de 08/11/2026): o `prova-remota` roda a checagem
# da base, então com a main suja todo PR fica vermelho. O card espera a main, sem `needs:dono`.
WORKFLOW_DA_MAIN = "testes"


def estado_da_main(wt: Path) -> tuple[str, str, str]:
    """(`verde` | `vermelha` | ``, url, sha) do último run concluído do workflow da main.
    Erro de consulta ou nada concluído = `` (desconhecido: vale o comportamento de antes)."""
    try:
        raw = sh([GH, "run", "list", "--branch", "main", "--workflow", WORKFLOW_DA_MAIN,
                  "--event", "push", "--limit", "5", "--json", "status,conclusion,url,headSha"],
                 cwd=wt, timeout=60)
        runs = json.loads(raw or "[]")
    except Exception:  # noqa: BLE001 - sem saber, não muda nada
        return "", "", ""
    for r in runs if isinstance(runs, list) else []:
        if not isinstance(r, dict) or str(r.get("status") or "").lower() != "completed":
            continue
        conclusao = str(r.get("conclusion") or "").lower()
        if conclusao in ("cancelled", "skipped", "neutral", ""):
            continue
        estado = "verde" if conclusao == "success" else "vermelha"
        return estado, str(r.get("url") or ""), str(r.get("headSha") or "")
    return "", "", ""


def esperar_main(st: dict, url_main: str, sha_main: str) -> None:
    """Card fica esperando a main, sem `needs:dono` e sem rodar a lane de novo.
    Um comentário por SHA da main; o tempo de espera da prova não corre enquanto isso."""
    if st.get("aguardando_main") == sha_main:
        st["prova_remota_desde"] = time.time()
        return
    registrar_prova_remota(st, "main-vermelha")
    st["prova_remota_desde"] = time.time()
    st["aguardando_main"] = sha_main or "?"
    log(f"lane:{st['lane']} {st['card']}: main vermelha ({url_main or 'sem link'}); "
        "o card espera a main, sem needs:dono")
    linhas = [f"⏸️ **lane:{st['lane']}** aguardando a main: o check `{NOME_CHECK_REMOTO}` ficou "
              f"vermelho, mas a main também está vermelha no `{WORKFLOW_DA_MAIN}`. "
              "A falha não é deste card.", ""]
    if url_main:
        linhas.append(f"Main: {url_main}")
    linhas.append("Quando a main voltar a ficar verde, a branch recebe a main e a prova roda de novo sozinha.")
    linear(MUT_COMMENT, {"id": st["issue_id"], "body": "\n".join(linhas)})


def retomar_depois_da_main(st: dict, wt: Path) -> str:
    """Main voltou ao verde: traz a main para a branch (merge, sem rebase) e deixa o
    próximo ciclo enviar. Vazio = feito; senão o motivo (conflito vira pedido ao dono)."""
    sh(argv_git(["git", "fetch", "-q", "origin", "main"]), cwd=wt, timeout=180)
    try:
        sh(argv_git(["git", "merge", "--no-edit", "-q", "origin/main"]), cwd=wt, timeout=180)
    except RuntimeError as exc:
        sh(argv_git(["git", "merge", "--abort"]), cwd=wt, check=False)
        return f"a main voltou ao verde, mas não entra na branch sem conflito ({str(exc)[:160]})"
    st.pop("aguardando_main", None)
    st["prova_remota_desde"] = time.time()
    linear(MUT_COMMENT, {"id": st["issue_id"], "body":
        f"▶️ **lane:{st['lane']}** a main voltou ao verde: a branch recebeu a main e a prova "
        f"`{NOME_CHECK_REMOTO}` roda de novo."})
    log(f"lane:{st['lane']} {st['card']}: main verde de novo; branch atualizada, prova de novo")
    return ""


def chamar_dono_prova_remota(st: dict, motivo: str) -> str:
    """Timeout ou erro: etiqueta do dono. O card não vai para In Review."""
    aplicar_label(st["issue_id"], LABEL_DONO_ID, OWNER_LABEL)
    url = str(st.get("prova_remota_url") or "").strip()
    check = str(st.get("prova_remota_check") or "").strip()
    linhas = [f"✋ **lane:{st['lane']}** precisa do dono: {motivo}.", ""]
    if url:
        linhas.append(f"PR: {url}")
    if check:
        linhas.append(f"Check: {check}")
    linhas.append("")
    linhas.append(f"Para retomar: responder no card e remover a label `{OWNER_LABEL}`.")
    linear(MUT_COMMENT, {"id": st["issue_id"], "body": "\n".join(linhas)})
    return OWNER_LABEL


def ler_pr_aberto(wt: Path, branch: str) -> Optional[dict]:
    """PR aberto da branch, ou None se ainda não existe. Outro erro sobe."""
    try:
        raw = sh([GH, "pr", "view", branch, "--json",
                  "url,state,isDraft,number,headRefOid,statusCheckRollup"],
                 cwd=wt, timeout=120)
    except RuntimeError as exc:
        if "no pull request" in str(exc).lower():
            return None
        raise
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"gh pr view não devolveu JSON ({exc})") from exc
    if not isinstance(data, dict):
        raise RuntimeError("gh pr view não devolveu um objeto")
    if str(data.get("state") or "").upper() != "OPEN":
        return None
    return data


def corpo_do_rascunho(st: dict, res: dict, arquivos: list) -> str:
    lista = "\n".join(f"- {a}" for a in (arquivos or [])[:30])
    return (
        f"{st['card']}: {st['title']}\n\n"
        f"{res.get('summary', '')}\n\n"
        f"Executado pela lane:{st['lane']} (esforço {st['effort']}).\n\n"
        f"Arquivos:\n{lista}\n\n"
        "Rascunho. O card só vai para In Review quando o check "
        f"`{NOME_CHECK_REMOTO}` estiver verde no SHA completo do head.\n"
    )


def abrir_rascunho(st: dict, wt: Path, res: dict, arquivos: list) -> str:
    return sh([GH, "pr", "create", "--draft", "--base", "main", "--head", st["branch"],
               "--title", f"[{st['card']}] {st['title']}",
               "--body", corpo_do_rascunho(st, res, arquivos)],
              cwd=wt, timeout=120)


def fechar_com_prova_remota(st: dict, wt: Path, res: dict, g: dict) -> Optional[str]:
    """Push, PR em rascunho, e In Review só com o check verde no SHA completo.

    None = ainda esperando. A prova em `.lane/proof_*` não entra nesta decisão.
    """
    barrado = motivo_para_nao_enviar(wt)
    if barrado:
        return fail(st, f"nada foi enviado: {barrado}", causa="push-barrado")
    sha = normalizar_sha(sh([GIT, "rev-parse", "HEAD"], cwd=wt))
    if not sha_completo(sha):
        return chamar_dono_prova_remota(st, "o SHA do head não está completo")
    # FRA-594: push só para a URL do cadastro, nunca `git push origin`.
    recusa = enviar_branch(wt, st["branch"])
    if recusa:
        return fail(st, f"nada foi enviado: {recusa}", causa="push-barrado")
    try:
        pr = ler_pr_aberto(wt, st["branch"])
    except RuntimeError as exc:
        return chamar_dono_prova_remota(st, f"erro ao consultar a prova remota ({exc})")
    if pr is None:
        try:
            url = abrir_rascunho(st, wt, res, g.get("files") or []).strip()
        except RuntimeError as exc:
            return chamar_dono_prova_remota(st, f"erro ao abrir o PR em rascunho ({exc})")
        anotar_espera(st, sha, url, "")
        return None
    url = str(pr.get("url") or "").strip()
    head = normalizar_sha(str(pr.get("headRefOid") or ""))
    checks = pr.get("statusCheckRollup")
    check = url_do_check(sha, head, checks)
    anotar_espera(st, sha, url, check)
    agora = time.time()
    desde = float(st["prova_remota_desde"])
    decisao = decisao_prova_remota(sha, head, checks, agora=agora, desde=desde,
                                   limite_s=ESPERA_PROVA_REMOTA_S)
    if decisao == "esperar":
        return None
    vermelho = any(veredito_item(i) == "vermelho" for i in checks_que_contam(sha, head, checks))
    if decisao == "dono" and vermelho:
        main, url_main, sha_main = estado_da_main(wt)
        if main == "vermelha":
            esperar_main(st, url_main, sha_main)
            return None
        if main == "verde" and st.get("aguardando_main"):
            conflito = retomar_depois_da_main(st, wt)
            if conflito:
                return chamar_dono_prova_remota(st, conflito)
            return None
    if decisao == "dono":
        registrar_prova_remota(st, "vermelho" if vermelho else "tempo", sha)
        return chamar_dono_prova_remota(st, motivo_prova_remota(sha, head, checks, desde, agora))
    if decisao != "mover":
        raise RuntimeError(f"decisão de prova remota desconhecida: {decisao}")
    try:
        if pr.get("isDraft"):
            alvo = str(pr.get("number") or url)
            sh([GH, "pr", "ready", alvo], cwd=wt, timeout=120)
        linhas = [
            f"**lane:{st['lane']}** prova remota `{NOME_CHECK_REMOTO}` verde no SHA `{sha}`.",
            "",
            f"PR: {url}",
        ]
        if check:
            linhas.append(f"Check: {check}")
        linhas += ["", "O card foi para In Review."]
        registrar_prova_remota(st, "verde", sha)
        linear(MUT_COMMENT, {"id": st["issue_id"], "body": "\n".join(linhas)})
        mudar_estado(st["issue_id"], STATE_IN_REVIEW_ID)
    except Exception as exc:  # noqa: BLE001 — erro ao concluir chama o dono, não vira lane:falhou
        return chamar_dono_prova_remota(st, f"erro ao concluir a prova remota ({exc})")
    return f"In Review ({url})"


def ler_exit_code(st: dict) -> str:
    """Código de saída da rodada. Ignora `.lane/exit_code`."""
    path = prova_dir(st) / "exit_code"
    if path.is_symlink():
        raise RuntimeError(f"symlink recusado: {path}")
    return ler_sem_seguir(path).strip()


def finalize(st: dict) -> Optional[str]:
    """Fecha o card. None = ainda esperando o check remoto no SHA completo.

    `.lane/proof_*` e `.lane/exit_code` não entram: a rodada mora em
    `STATE_DIR/provas/<lane>/<card>/<run_id>`.
    """
    wt = Path(st["worktree"])
    # FRA-594: config que executa código (helper, fsmonitor, pushurl) recusa
    # antes da prova. Origem e histórico seguem no fim, depois do veredito.
    motivo_cfg, _origem = diagnostico_config(wt)
    if motivo_cfg:
        return fail(st, f"nada foi enviado: {motivo_cfg}", causa="push-barrado")
    prova = preparar_prova_dir(st, wt)
    code = ler_exit_code(st)
    res = read_result(wt)
    g = git_summary(wt, st.get("base"))

    prot = touched_protected(g["lane_files"])
    if prot:
        return fail(st, f"tocou caminho protegido ({', '.join(prot)}); nada foi enviado")
    if code == "freio":
        try:
            detalhe = ler_sem_seguir(prova / "freio.txt").strip()
        except (OSError, RuntimeError):
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
            recusa = enviar_branch(wt, st["branch"])
            if recusa:
                return fail(st, f"nada foi enviado: {recusa}")
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

    # FRA-611: `.lane/proof_*` e um DONE não decidem. O PR abre em rascunho.
    return fechar_com_prova_remota(st, wt, res, g)


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


# Estado recusado sem saída (FRA-630, 01/11/2026): o `watch` retornava antes de todos os
# freios (timeout, sem saída, sessão sumida, FRA-443) e só logava, a cada minuto, para
# sempre. Continua sem fechar, matar ou mover nada (FRA-600: o JSON pode ser forjado),
# mas agora avisa o dono uma vez no card do claim e loga uma vez por hora.
RECUSA_AVISO_MIN = 15
RECUSA_LOG_S = 3600
_ISSUE_RE = re.compile(r"[0-9a-fA-F-]{8,64}")


def _arquivo_recusa(lane: str) -> Path:
    return STATE_DIR / f"recusado-{lane}.json"


def limpar_recusa(lane: str) -> None:
    _arquivo_recusa(lane).unlink(missing_ok=True)


def avisar_estado_recusado(lane: str, st: dict, motivo: str, agora: Optional[float] = None) -> dict:
    """Registra a recusa, loga no máximo 1x/hora e avisa o dono 1x depois de RECUSA_AVISO_MIN."""
    agora = time.time() if agora is None else agora
    f = _arquivo_recusa(lane)
    try:
        reg = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        reg = {}
    if not isinstance(reg, dict) or reg.get("motivo") != motivo or not isinstance(reg.get("desde"), (int, float)):
        reg = {"desde": agora, "motivo": motivo, "avisado": False, "ultimo_log": 0}
    minutos = int((agora - reg["desde"]) // 60)
    if agora - float(reg.get("ultimo_log") or 0) >= RECUSA_LOG_S:
        log(f"lane:{lane} estado recusado: {motivo} (há {minutos} min); não fecho, não mato sessão, "
            f"não movo o card")
        reg["ultimo_log"] = agora
    if not reg.get("avisado") and minutos >= RECUSA_AVISO_MIN:
        reg["avisado"] = avisar_dono_recusa(lane, st, motivo, minutos)
    try:
        tmp = f.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(reg), encoding="utf-8")
        _privar(tmp)
        tmp.replace(f)
    except OSError:
        pass
    return reg


def avisar_dono_recusa(lane: str, st: dict, motivo: str, minutos: int) -> bool:
    """Comentário + etiqueta do dono no card do claim. Só com claim do mesmo card."""
    log(f"ALERTA lane:{lane} parada há {minutos} min com estado recusado ({motivo}); "
        f"precisa do dono")
    claim = ler_claim(lane) or {}
    issue = claim.get("issue_id")
    if (claim.get("card") != st.get("card") or not isinstance(issue, str)
            or not _ISSUE_RE.fullmatch(issue)):
        return True  # sem card confiável: o alerta fica no log e no painel
    try:
        linear(MUT_COMMENT, {"id": issue, "body":
            f"⚠️ **lane:{lane}** está parada há {minutos} min: o dispatcher recusa o estado da lane "
            f"(`{motivo}`). Nada foi fechado, morto ou movido.\n\n"
            f"A lane não assume outro card até isso ser resolvido. Confira o "
            f"`lane-{lane}.json` e o `claim-{lane}.json`; se o trabalho não vale, apagar os dois "
            f"libera a lane.\n\n{linha_causa('estado-recusado')}"})
        aplicar_label(issue, LABEL_DONO_ID, OWNER_LABEL)
        return True
    except Exception as exc:  # noqa: BLE001 — sem Linear, tenta de novo no próximo ciclo
        log(f"lane:{lane} aviso de estado recusado não foi ao Linear: {exc}")
        return False


def watch(lane: str, st: dict) -> None:
    motivo = motivo_recusa_estado(lane, st)
    if motivo:
        avisar_estado_recusado(lane, st, motivo)
        return
    limpar_recusa(lane)
    if st.get("stuck"):
        return  # precisa de ação humana: ver log; apagar lane-<x>.json libera a lane
    wt = Path(st["worktree"])
    try:
        prova = preparar_prova_dir(st, wt)
    except (KeyError, RuntimeError) as exc:
        log(f"lane:{lane} {st.get('card')}: sem pasta de prova ({exc}); não leio .lane/exit_code")
        return
    exit_file = prova / "exit_code"
    if exit_file.is_symlink():
        log(f"lane:{lane} {st.get('card')}: exit_code é symlink; recusado")
        return
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
        if freio:
            escrever_exclusivo(prova / "freio.txt", f"freio do card ({freio})\n")
            escrever_exclusivo(exit_file, "freio\n")
        else:
            texto = reason if reason.endswith("\n") else reason + "\n"
            escrever_exclusivo(exit_file, texto)
        kill_lane_tree(st["session"])
        matar_prova(st)
        stop_file.unlink(missing_ok=True)
    try:
        outcome = finalize(st)
        if outcome is None:
            aviso = aviso_prova_remota(st)
            if st.get("prova_remota_anuncio") != aviso:
                st["prova_remota_anuncio"] = aviso
                log(f"lane:{lane} {st['card']}: {aviso}")
            save_state(lane, st)
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
    destino = prova / "finalized"
    if destino.is_symlink():
        raise RuntimeError(f"symlink recusado: {destino}")
    if not destino.exists():
        escrever_exclusivo(destino, outcome)
    # Arquiva a prova na pasta de estado antes de soltar a lane: o painel lê
    # `stale-proof-*` para o histórico e para o contador de testes do dia. Sem
    # isso a prova some quando o `lane-<lane>.json` passa a apontar para outro card.
    try:
        archive_old_proofs(prova, st["card"])
    except Exception as exc:  # noqa: BLE001 — o fechamento não pode falhar por causa do histórico
        log(f"lane:{lane} {st['card']}: não arquivei a prova ({exc})")
    soltar_lane(lane)
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
        if fila.contexto_card(it).get("risk") == "risco:alto":
            fit_run.sort(key=lambda l: (0 if risco_alto(l) else 1, l))
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
        if fila.contexto_card(it).get("risk") == "risco:alto":
            fit_wait.sort(key=lambda l: (0 if risco_alto(l) else 1, l))
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


def lanes_ociosas(lanes_on, running, limited, per_lane, saude: Optional[dict] = None) -> list[str]:
    """Lanes ligadas, sem card rodando, sem limite de uso, saudáveis e com a fila vazia."""
    return [lane for lane in LANES
            if lane in lanes_on and lane not in running and lane not in limited
            and not per_lane.get(lane)
            and (saude is None or fila.lane_saudavel(saude, lane))]


def escolher_do_todo(cards: list, vagas: list[str], medidas: Optional[dict] = None,
                     viewer: str = "", ocupados: Optional[dict] = None,
                     motivos: Optional[list] = None) -> list:
    """Até um card por vaga: o de maior prioridade que uma lane ociosa pode receber.

    Card com lane própria só sobe se essa lane está na lista de vagas **e** tem
    cota para o esforço. Card sem lane (só esforço) sobe se alguma vaga tem cota
    para o esforço; a lane final continua sendo a de menor %.
    """
    if not vagas:
        return []
    livres = set(vagas)
    ocupados = dict(ocupados or {})
    prontos = []
    def fora(card: dict, motivo: str) -> None:
        if motivos is not None:
            motivos.append(f"{card.get('identifier') or '?'} fora do Todo: {motivo}")

    for card in cards:
        motivo = motivo_que_segura_todo(card)
        if motivo:
            fora(card, motivo)
            continue
        if fila.atribuido_a_outro(card, viewer):
            fora(card, "atribuído a outra pessoa")
            continue
        conflito = fila.conflita(card, ocupados)
        if conflito:
            fora(card, f"conflito com {conflito}")
            continue
        lane, effort, why = classify(card)
        if why or not lane:
            fora(card, why or "sem lane")
            continue
        if lane != AUTO_LANE and lane not in livres:
            fora(card, f"lane {lane} sem vaga")
            continue
        if medidas is not None:
            if lane == AUTO_LANE:
                if not any(fila.cota_ok(candidata, effort, medidas) for candidata in livres):
                    fora(card, f"sem cota para {effort}")
                    continue
            elif not fila.cota_ok(lane, effort, medidas):
                fora(card, f"lane {lane} sem cota para {effort}")
                continue
        prontos.append(card)
        ocupados[card.get("identifier") or ""] = fila.arquivos_card(card)
    return sorted(prontos, key=sort_key)[:len(vagas)]


def subir_do_todo(auto: list, per_lane: dict, lanes_on, running, limited, project_id: str,
                  medidas: Optional[dict] = None) -> list[str]:
    """Com lane ociosa, sobe do Todo o card pronto. Não depende da vigia nem do PAUSE dos bots."""
    saude = fila.ler_saude(STATE_DIR / "saude-lanes.json")
    vagas = lanes_ociosas(lanes_on, running, limited, per_lane, saude)
    if not vagas:
        return []
    try:
        todos = linear(QUERY_CANDIDATES, {"project": project_id, "state": STATE_TODO_ID})["issues"]["nodes"]
        atualizar_cache_titulos(todos)
    except Exception as exc:  # noqa: BLE001
        log(f"fila: não li o Todo ({exc})")
        return []
    viewer = viewer_linear() if any((c.get("assignee") or {}).get("id") for c in todos) else ""
    ocupados = {it.get("identifier"): fila.arquivos_card(it) for it in auto}
    for fila_lane in per_lane.values():
        ocupados.update({it.get("identifier"): fila.arquivos_card(it) for it in fila_lane})
    motivos: list = []
    linhas = []
    for it in escolher_do_todo(todos, vagas, medidas, viewer, ocupados, motivos):
        ident = it.get("identifier") or "?"
        if estado_do_card(ident) != "Todo":
            log(f"fila: {ident} não está mais no Todo; não puxo")
            continue
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
    linhas.extend(f"fila: {m}" for m in motivos)
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


def keep_awake(has_work: bool) -> None:
    antigo = ler_caffeinate()
    pid_file = arquivo_caffeinate()
    if not has_work:
        if pid_file.exists():
            pid_file.unlink(missing_ok=True)
            log("liberado: sem trabalho, caffeinate expira sozinho")
        return
    proc = subprocess.Popen([CAFFEINATE_BIN, "-i", "-s", "-t", str(CAFFEINATE_SECONDS)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    foto = gravar_caffeinate(proc.pid)
    if foto is None:
        log(f"caffeinate {proc.pid} sem foto; o próximo ciclo não sinaliza este pid")
    if antigo is not None:
        encerrar_caffeinate(antigo)
    elif foto is not None:
        log(f"mantendo acordado: caffeinate {proc.pid} por {CAFFEINATE_SECONDS} s, renovado a cada ciclo")


def run(real: bool, verbose: bool) -> int:
    """Um ciclo por vez. Sem o lock, dois launchd se atropelam e matam a sessão um do outro."""
    fh = _trava_ciclo()
    if fh is None:
        log("ciclo: outro dispatcher segura dispatcher.lock; não mato sessão nem worktree")
        return 0
    try:
        return _ciclo(real, verbose)
    finally:
        fcntl.flock(fh, fcntl.LOCK_UN)
        fh.close()


def _ciclo(real: bool, verbose: bool) -> int:
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
            _privar(MODE_FILE)
        return 0
    lanes_on, ignored = effective_lanes(enabled_lanes()) if real else (set(), [])
    try:
        prev_at = json.loads(HEARTBEAT_FILE.read_text()).get("at") if HEARTBEAT_FILE.exists() else None
    except (OSError, ValueError, AttributeError):
        prev_at = None
    gap = wake_gap_line(prev_at, dt.datetime.now())
    if gap and real:
        busy = [f"lane:{l} com {card_confiavel(l, st) or 'estado inválido'}"
                for l in LANES if (st := load_state(l))]
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
    _privar(HEARTBEAT_FILE)
    mode = (f"{'real' if real else 'simulação'} · projeto: {projeto().nome} · "
            f"lanes: {', '.join(sorted(lanes_on)) or 'nenhuma'}")
    previous_mode = MODE_FILE.read_text().strip() if MODE_FILE.exists() else ""
    if mode != previous_mode:
        log(f"MODO {mode}" + (f" (habilitada sem execução real, ignorada: {', '.join(ignored)})" if ignored else ""))
        MODE_FILE.write_text(mode)
        _privar(MODE_FILE)

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
        busy = {c for l in LANES if (c := card_confiavel(l, load_state(l)))}
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
        limited = {l: u for l in LANES if (u := lane_limited_conta(l))}
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
                nome = card_confiavel(lane, running) or "estado inválido"
                espera = [i["identifier"] for i in queue]
                if espera:
                    lines.append(f"lane:{lane} ocupada com {nome} "
                                 f"(espera: {', '.join(espera)})")
                else:
                    lines.append(f"lane:{lane} ocupada com {nome}")
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
                cblock = bloqueio_por_conta(lane, to_claim)
                if cblock:
                    lines.append(f"lane:{lane} segura {top['identifier']}: {cblock}")
                    continue
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
                soltar_lane(lane)
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
        modelo = str(_cfg("watch.modelo_needs_ollama", "") or "").strip()
        if not modelo:
            return None  # sem modelo nos Ajustes, a regra decide sozinha
        body = json.dumps({"model": modelo, "prompt": prompt, "stream": False}).encode()
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
