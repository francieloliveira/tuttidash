"""Leitor dos manifests de agente (`agents.d/*.json`) — o mesmo catálogo do Swift.

Fonte única da lista de CLIs/lanes: adicionar um agente novo = 1 arquivo JSON.
`gasto_lanes/agentes.py` (e o resto do Python) deriva deste catálogo em vez de
manter uma lista hardcoded paralela.

Busca, em ordem: cópia instalada (`~/.transcentia/agents.d/`, E13), depois o
diretório `agents.d/` na raiz do repo (dev), e por fim `EMBUTIDOS` — cópia
mecânica dos mesmos manifests dentro deste arquivo, para teste isolado e máquina
sem o catálogo instalado. `tests/test_catalogo.py` cobra a paridade dos três.

Somente Python 3 da stdlib.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

SCHEMA_ATUAL = 1

#: Diretório instalado pelo `tools/install.sh` (fonte da verdade em produção).
DIR_INSTALADO = Path.home() / ".transcentia" / "agents.d"


def _raiz_repo() -> Path:
    """Raiz do repo (onde fica `agents.d/`) a partir deste arquivo.

    Sobe os diretórios até achar `agents.d/` ou `.git`, para funcionar em
    qualquer profundidade de instalação.
    """
    aqui = Path(__file__).resolve()
    for pai in aqui.parents:
        if (pai / "agents.d").is_dir() or (pai / ".git").exists():
            return pai
    return aqui.parents[1]


DIR_REPO = _raiz_repo() / "agents.d"

#: Cópia embutida: o conteúdo literal de `agents.d/*.json`, colado aqui. É o
#: último recurso (teste isolado / máquina sem instalar), não a fonte da verdade.
EMBUTIDOS_JSON = """\
{
"schema": 1,
"nome": "claude",
"rotulo": "Claude Code",
"sigla": "CL",
"cli": "claude",
"ordem": 1,
"prioridade": 1,
"painel": true,
"execucao": "implementada",
"cor": {"base": "#FF8A5C", "gradiente": "#E8673C", "claro": "#FFAE85"},
"corPainel": "#9B7BFF",
"custo": "estimado",
"resume": "claude",
"pesoFontes": ["quota", "gasto"],
"nota": "Tabela de esforço aprovada em 2026-10-03. Lane de referência: é o fallback de `--resume` para qualquer agente sem CLI próprio.",
"modelos": {
  "baixo": {"id": "sonnet", "flags": ["--model", "sonnet", "--effort", "medium"]},
  "medio": {"id": "opus", "flags": ["--model", "opus", "--effort", "high"]},
  "alto": {"id": "opus", "flags": ["--model", "opus", "--effort", "xhigh"]}
  },
"revisao": {"papel": "sozinho", "auto": true, "comando": ["claude", "-p", "--output-format", "text", "--permission-mode", "default", "--settings", "{settings}", "--strict-mcp-config", "--mcp-config", "{mcp}", "--max-budget-usd", "{teto}", "{flags}"], "flag_modelo": ["--model", "{modelo}"], "flag_esforco": ["--effort", "{esforco}"], "entrada": "stdin", "saida": "stdout", "modelos": ["haiku", "sonnet", "opus"], "modelo_padrao": "opus", "esforcos": ["low", "medium", "high", "xhigh"], "esforco_padrao": "high"},
"instalar": {"comando": "curl -fsSL https://claude.ai/install.sh | bash", "entrar": "claude", "dica_entrar": "Na primeira vez o Claude Code abre o navegador para você entrar. Depois digite /exit.", "docs": "https://code.claude.com/docs/en/setup"},
"uso": {
  "tipo": "claude",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "codex",
"rotulo": "Codex",
"sigla": "CX",
"cli": "codex",
"ordem": 2,
"prioridade": 5,
"painel": true,
"execucao": "implementada",
"cor": {"base": "#7D5CFF", "gradiente": "#5B3DF0", "claro": "#B79DFF"},
"corPainel": "#3DFFA8",
"custo": "estimado",
"resume": "codex",
"pesoFontes": ["quota", "gasto"],
"nota": "Promovido a implementada após `codex exec --json` validado ponta a ponta em 2026-10-15. Modelos ficam vazios de propósito: IDs inventados quebram a lane, então cada esforço usa o default do CLI. `exec` não tem teto de gasto no CLI — monitorado pelo ledger. Fixar modelos por esforço depois da primeira rodada.",
"modelos": {
  "baixo": {"id": "", "flags": []},
  "medio": {"id": "", "flags": []},
  "alto": {"id": "", "flags": []}
  },
"revisao": {"papel": "sozinho", "auto": true, "comando": ["codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never", "--output-last-message", "{saida}", "{flags}", "-"], "flag_modelo": ["-m", "{modelo}"], "flag_esforco": ["-c", "model_reasoning_effort={esforco}"], "entrada": "stdin", "saida": "arquivo", "modelos": [], "modelo_padrao": "padrao", "esforcos": ["low", "medium", "high"], "esforco_padrao": "high"},
"instalar": {"comando": "brew install --cask codex", "entrar": "codex", "dica_entrar": "Escolha Sign in with ChatGPT e entre pelo navegador. Depois digite /quit.", "docs": "https://github.com/openai/codex"},
"uso": {
  "tipo": "codex",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "opencode",
"rotulo": "OpenCode",
"sigla": "OP",
"cli": "opencode",
"ordem": 3,
"prioridade": 3,
"painel": true,
"execucao": "implementada",
"cor": {"base": "#FF7AB8", "gradiente": "#E14E96", "claro": "#FFAED4"},
"corPainel": "#3DE8FF",
"custo": "estimado",
"resume": "opencode",
"pesoFontes": ["quota", "gasto"],
"nota": "Privacidade por MODELO, não por ser free: a regra de cada um sai da documentação do OpenCode (gasto_lanes/privacidade.py, conferida todo dia). Desde 23/10/2026 20h20 (troca a regra de 21/10) modelo free que registra ou treina com o uso também recebe código, nas lanes e na revisão, quando for o melhor free; `privacidade.exigir_sem_treino` religa a regra antiga. Por peso: baixo GLM 5.3 Flash (rápido), médio DeepSeek V4.1 Flash (o que mais entregou), alto Nemotron 3 Ultra (melhor SWE-bench dos free, 1M de contexto).",
"modelos": {
  "baixo": {
    "id": "opencode/glm-5.3-flash-free",
    "flags": ["-m", "opencode/glm-5.3-flash-free"]
    },
  "medio": {
    "id": "opencode/deepseek-v4.1-flash-free",
    "flags": ["-m", "opencode/deepseek-v4.1-flash-free"]
    },
  "alto": {
    "id": "opencode/nemotron-3-ultra-free",
    "flags": ["-m", "opencode/nemotron-3-ultra-free"]
    }
  },
"revisao": {"papel": "segunda_opiniao", "auto": true, "comando": ["opencode", "run", "{flags}", "--agent", "plan", "--", "{prompt}"], "flag_modelo": ["-m", "{modelo}"], "flag_esforco": [], "entrada": "argumento", "saida": "stdout", "modelos": ["opencode/deepseek-v4.1-flash-free", "opencode/nemotron-3-ultra-free", "opencode/glm-5.3-flash-free"], "modelo_padrao": "opencode/deepseek-v4.1-flash-free", "esforcos": [], "esforco_padrao": ""},
"privacidade": "opencode",
"instalar": {"comando": "brew install opencode", "entrar": "opencode", "dica_entrar": "Dentro do OpenCode, digite /connect e escolha o provedor da sua conta.", "docs": "https://github.com/anomalyco/opencode"},
"uso": {
  "tipo": "opencode",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "opencode-go",
"rotulo": "OpenCode Go",
"sigla": "OG",
"cli": "opencode",
"ordem": 4,
"prioridade": 4,
"painel": true,
"execucao": "implementada",
"cor": {"base": "#5CFFC8", "gradiente": "#2E9BFF", "claro": "#9BE6FF"},
"corPainel": "#5CFFC8",
"custo": "estimado",
"resume": "opencode",
"pesoFontes": ["quota", "gasto"],
"nota": "Modelos Go com ZDR (teto mensal por modelo, ex. deepseek-v4.1-flash US$80/mês; janelas 5h = 20%, semana = 50%, mês = 100%; após o teto: free + balance). Lane separada no notch. Proibidos: gemini-4-argon-contributor e muse-spark-1.2/1.3-contributor (treinam, sem ZDR). Os nomes sob opencode-go/ não têm o sufixo -free do Console free. Os modelos deepseek do Go exigem a região Global na Privacidade do workspace (erro 400 desde 23/10/2026); por isso a lane usa glm-5.3 (baixo) e kimi-k3 (médio, alto e revisão), que rodam sem a Global.",
"modelos": {
  "baixo": {
    "id": "opencode-go/glm-5.3",
    "flags": ["-m", "opencode-go/glm-5.3"]
    },
  "medio": {
    "id": "opencode-go/kimi-k3",
    "flags": ["-m", "opencode-go/kimi-k3"]
    },
  "alto": {
    "id": "opencode-go/kimi-k3",
    "flags": ["-m", "opencode-go/kimi-k3"]
    }
  },
"revisao": {"papel": "segunda_opiniao", "auto": true, "comando": ["opencode", "run", "{flags}", "--agent", "plan", "--", "{prompt}"], "flag_modelo": ["-m", "{modelo}"], "flag_esforco": [], "entrada": "argumento", "saida": "stdout", "modelos": ["opencode-go/kimi-k3"], "modelo_padrao": "opencode-go/kimi-k3", "esforcos": [], "esforco_padrao": ""},
"privacidade": "opencode",
"instalar": {"comando": "brew install opencode", "entrar": "opencode", "dica_entrar": "Dentro do OpenCode, digite /connect e escolha o provedor da sua conta.", "docs": "https://github.com/anomalyco/opencode"},
"uso": {
  "tipo": "opencode",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "grok",
"rotulo": "Grok CLI",
"sigla": "GR",
"cli": "grok",
"ordem": 5,
"prioridade": 2,
"painel": true,
"execucao": "implementada",
"cor": {"base": "#5CD3FF", "gradiente": "#2E9BFF", "claro": "#9BE6FF"},
"corPainel": "#5CD3FF",
"custo": "informado",
"resume": "grok",
"pesoFontes": ["quota", "gasto"],
"nota": "Lane do CLI grok no terminal: créditos próprios, separados do SuperGrok (Grok Bot via Cursor). Grok não tem teto em dólar: o limite é de turnos (GROK_MAX_TURNS no dispatcher). Ferramentas permitidas via --tools estão na lista GROK_TOOLS; fora dela ficam agendador, subagentes e web (use_tool/search_tool/workflow/ask_user_question cancelam a sessão sem executar — testado em 2026-10-03, grok 1.0.41).",
"modelos": {
  "baixo": {"id": "grok-4.7-build-fast", "flags": ["-m", "grok-4.7-build-fast"]},
  "medio": {"id": "grok-4.7", "flags": ["-m", "grok-4.7", "--effort", "high"]},
  "alto": {"id": "grok-4.7", "flags": ["-m", "grok-4.7", "--effort", "high"]}
  },
"revisao": {"papel": "sozinho", "auto": true, "comando": ["grok", "{flags}", "--tools", "read_file,grep,list_dir", "--disable-web-search", "-p", "{prompt}"], "flag_modelo": ["-m", "{modelo}"], "flag_esforco": ["--effort", "{esforco}"], "entrada": "argumento", "saida": "stdout", "modelos": ["grok-4.7", "grok-4.7-build-fast"], "modelo_padrao": "grok-4.7", "esforcos": ["high"], "esforco_padrao": "high"},
"instalar": {"comando": "curl -fsSL https://x.ai/cli/install.sh | bash", "entrar": "grok", "dica_entrar": "Na primeira vez o Grok abre o navegador para você entrar.", "docs": "https://github.com/xai-org/grok-build"},
"uso": {
  "tipo": "grok",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "cursor",
"rotulo": "Grok Bot / SuperGrok (via Cursor)",
"sigla": "CU",
"cli": null,
"ordem": 6,
"prioridade": null,
"painel": false,
"cor": {"base": "#5CFFC8", "gradiente": "#5CFFC8", "claro": "#5CFFC8"},
"corPainel": "#5CFFC8",
"custo": "informado",
"resume": null,
"pesoFontes": ["quota"],
"nota": "Conta de uso do Grok Bot / SuperGrok. O TuttiDash aberto não lê o limite dela (sem API oficial de cota). Não é lane de execução, não pega card e não compartilha cota com o Grok CLI. Não entra no painel/notch nem no dispatcher. Sem CLI próprio — `--resume` cai em claude.",
"modelos": {
  "baixo": {"id": "", "flags": []},
  "medio": {"id": "", "flags": []},
  "alto": {"id": "", "flags": []}
  },
"uso": {
  "tipo": "cursor",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "gemini",
"rotulo": "Gemini",
"sigla": "GE",
"cli": "gemini",
"ordem": 7,
"painel": false,
"optIn": true,
"cor": {"base": "#4C8DFF", "gradiente": "#2F6FE0", "claro": "#A9C8FF"},
"corPainel": "#4C8DFF",
"custo": "informado",
"resume": "gemini",
"pesoFontes": ["quota"],
"nota": "Conta de uso do Gemini CLI, não é lane: não pega card e não entra no dispatcher. Opt-in (fora da lista padrão de contas). O TuttiDash aberto não lê o limite desta conta (sem API oficial de cota).",
"instalar": {"comando": "brew install gemini-cli", "entrar": "gemini", "dica_entrar": "Escolha o jeito de entrar (conta Google ou chave da API) e siga a tela.", "docs": "https://github.com/google-gemini/gemini-cli"},
"uso": {
  "tipo": "gemini",
  "fonte": "",
  "credencial": ""
  }
}

{
"schema": 1,
"nome": "copilot",
"rotulo": "Copilot",
"sigla": "CP",
"cli": null,
"ordem": 8,
"painel": false,
"optIn": true,
"cor": {"base": "#6E40C9", "gradiente": "#4B2A8C", "claro": "#C4B5FD"},
"corPainel": "#6E40C9",
"custo": "informado",
"resume": null,
"pesoFontes": ["quota"],
"nota": "Conta de uso do GitHub Copilot, não é lane: não pega card e não entra no dispatcher. Opt-in (fora da lista padrão). A pessoa informa o usuário e a cota mensal de requisições premium. O token fica no Keychain (app.tuttidash.mac, conta copilot) ou num arquivo cujo caminho ela aponta; nunca no config.json. A leitura é o relatório pessoal oficial de billing. Licença gerida por organização não entra neste número.",
"uso": {
  "tipo": "copilot",
  "fonte": "api.github.com/users/{username}/settings/billing/premium_request/usage",
  "credencial": "copilot_token"
  }
}"""


class ErroCatalogo(Exception):
    """Manifesto ilegível ou de schema futuro."""


def _revisao(r) -> dict | None:
    """Bloco `revisao` do manifesto, com os padrões. Sem `comando`, o agente não revisa."""
    if not isinstance(r, dict) or not r.get("comando"):
        return None
    return {"papel": "segunda_opiniao" if r.get("papel") == "segunda_opiniao" else "sozinho",
            "auto": bool(r.get("auto", True)),
            "comando": tuple(r["comando"]),
            "flag_modelo": tuple(r.get("flag_modelo") or ()),
            "flag_esforco": tuple(r.get("flag_esforco") or ()),
            "entrada": r.get("entrada") if r.get("entrada") in ("stdin", "argumento") else "stdin",
            "saida": "arquivo" if r.get("saida") == "arquivo" else "stdout",
            "modelos": tuple(r.get("modelos") or ()),
            "modelo_padrao": r.get("modelo_padrao") or "",
            "esforcos": tuple(r.get("esforcos") or ()),
            "esforco_padrao": r.get("esforco_padrao") or ""}


def revisores() -> tuple:
    """Agentes que podem revisar PR (têm `revisao` e CLI), na ordem de exibição."""
    return tuple(n for n, d in catalogo().items() if d.get("revisao") and d.get("cli"))


def _normaliza(bruto: dict) -> dict:
    """Manifesto cru -> dicionário normalizado (mesmos campos para todos)."""
    uso = bruto.get("uso") or {}
    cor = bruto.get("cor") or {}
    modelos = bruto.get("modelos") or {}
    return {
        "rotulo": bruto["rotulo"],
        "sigla": bruto.get("sigla") or bruto["rotulo"][:1].upper(),
        "cli": bruto.get("cli"),
        "ordem": int(bruto.get("ordem", 999)),
        # Ordem de rotação do dispatcher (menor primeiro). None = não é lane.
        "prioridade": bruto.get("prioridade"),
        "painel": bool(bruto.get("painel", True)),
        # true = fora da lista padrão de contas (a pessoa adiciona em Ajustes).
        "optIn": bool(bruto.get("optIn", False)),
        # "implementada" | None (não é lane de execução)
        "execucao": bruto.get("execucao"),
        "nota": bruto.get("nota") or "",
        "cor": {"base": cor.get("base", "#FFFFFF"),
                "gradiente": cor.get("gradiente", "#FFFFFF"),
                "claro": cor.get("claro", "#FFFFFF")},
        "corPainel": bruto.get("corPainel") or "",
        "custo": "estimado" if bruto.get("custo") == "estimado" else "informado",
        "resume": bruto.get("resume"),
        "peso": tuple(bruto.get("pesoFontes") or ("quota", "gasto")),
        "uso": {"tipo": uso.get("tipo", ""), "fonte": uso.get("fonte", ""),
                "credencial": uso.get("credencial", "")},
        "modelos": {nivel: {"id": (m or {}).get("id", ""),
                            "flags": tuple((m or {}).get("flags") or ())}
                    for nivel, m in modelos.items()},
        # Revisão de PR só leitura (revisor). None = o agente não revisa. Ver agents.d/README.md.
        "revisao": _revisao(bruto.get("revisao")),
        # Fonte da regra de privacidade por modelo (gasto_lanes/privacidade.py). None = a conta
        # é do próprio fornecedor (claude, codex, grok) e não passa por essa conferência.
        "privacidade": bruto.get("privacidade") or None,
    }


def _do_texto(texto: str) -> dict:
    """Vários manifests JSON colados em sequência -> dicionário normalizado."""
    para, saida = texto, {}
    while para.strip():
        obj, fim = json.JSONDecoder().raw_decode(para.lstrip())
        para = para.lstrip()[fim:]
        saida[obj["nome"]] = _normaliza(obj)
    return dict(sorted(saida.items(), key=lambda kv: (kv[1]["ordem"], kv[0])))


#: Forma já normalizada do texto embutido (calculada uma vez na importação).
EMBUTIDOS: dict = _do_texto(EMBUTIDOS_JSON)


def ler_diretorio(diretorio) -> dict:
    """Lê os manifests de um diretório. Manifest ruim não derruba os outros.

    Levanta ErroCatalogo quando o diretório não existe ou não tem nenhum
    manifest válido (neste caso, quem chama cai no embutido).
    """
    d = Path(diretorio)
    if not d.is_dir():
        raise ErroCatalogo(f"pasta de agentes não existe: {d}")
    saida: dict = {}
    for arquivo in sorted(d.glob("*.json")):
        try:
            bruto = json.loads(arquivo.read_text(encoding="utf-8"))
            if int(bruto.get("schema", 0)) > SCHEMA_ATUAL:
                raise ErroCatalogo(
                    f"{arquivo.name}: schema {bruto['schema']} "
                    f"(este código entende até {SCHEMA_ATUAL})")
            saida[bruto["nome"]] = _normaliza(bruto)
        except ErroCatalogo:
            continue
        except Exception:
            continue
    if not saida:
        raise ErroCatalogo(f"nenhum manifest válido em {d}")
    return dict(sorted(saida.items(), key=lambda kv: (kv[1]["ordem"], kv[0])))


def _diretorios() -> list:
    return [DIR_INSTALADO, DIR_REPO]


_CACHE: dict = {}


def _resetar_cache() -> None:
    """Limpa o catálogo em memória (usado por teste que mexe nos manifests)."""
    _CACHE.clear()


def catalogo() -> dict:
    """Todos os agentes do catálogo: nome -> dados. Lê os manifests uma vez."""
    if "dados" in _CACHE:
        return _CACHE["dados"]
    dados = {}
    for d in _diretorios():
        try:
            dados = ler_diretorio(d)
            break
        except ErroCatalogo:
            continue
    if not dados:
        dados = dict(sorted(EMBUTIDOS.items(),
                            key=lambda kv: (kv[1]["ordem"], kv[0])))
    _CACHE["dados"] = dados
    return dados


def lanes() -> tuple:
    """Lanes com execução (têm `execucao` no manifesto), na ordem de exibição."""
    return tuple(n for n, d in catalogo().items() if d["execucao"])


def lanes_por_prioridade() -> tuple:
    """Lanes de execução na ordem de rotação do dispatcher (`prioridade`).

    A ordem de exibição (`ordem`) é a do painel/notch; a de rotação é a preferência
    do dispatcher ao escolher entre lanes livres.
    """
    com_prio = [(d["prioridade"], n) for n, d in catalogo().items()
                if d["execucao"] and d["prioridade"] is not None]
    return tuple(n for _, n in sorted(com_prio))


def lanes_implementadas() -> tuple:
    """Lanes prontas para o dispatcher (`execucao: implementada`)."""
    return tuple(n for n, d in catalogo().items() if d["execucao"] == "implementada")


def lanes_painel() -> tuple:
    """Lanes que entram na lista do painel/notch (`painel: true`)."""
    return tuple(n for n, d in catalogo().items() if d["painel"])


def tipos_conta() -> tuple:
    """Tipos de conta medidos, sem repetir (várias lanes podem medir a mesma)."""
    vistos, saida = set(), []
    for d in catalogo().values():
        t = d["uso"]["tipo"]
        if t and t not in vistos:
            vistos.add(t)
            saida.append(t)
    return tuple(saida)


def flag_de_effort(lane: str, effort: str) -> tuple:
    """Flags do modelo de um esforço. Vazio = o CLI usa o default."""
    d = catalogo().get(lane) or {}
    modelo = (d.get("modelos") or {}).get(effort) or {}
    return tuple(modelo.get("flags") or ())


def modelo_de_effort(lane: str, effort: str) -> str:
    d = catalogo().get(lane) or {}
    return ((d.get("modelos") or {}).get(effort) or {}).get("id", "") or ""


def rotulo(lane: str) -> str:
    return (catalogo().get(lane) or {}).get("rotulo", lane)


def label_de(lane: str) -> str:
    """Label do ledger: o nome da lane (os ids do Linear ficam em `linear_ids`, FRA-565)."""
    return lane


def dir_instalado() -> Path:
    return DIR_INSTALADO


def dir_repo() -> Path:
    return DIR_REPO


def ambientes_de_busca() -> tuple:
    return tuple(str(d) for d in _diretorios())


def existe_ambiente() -> bool:
    """True quando os manifests vieram do disco (não do fallback embutido)."""
    return any(Path(d).is_dir() for d in _diretorios())


# --- Modelo por lane (FRA-521) ------------------------------------------------
# O app grava `lanes.modelo.<lane>` no config do TuttiDash. String antiga = modelo
# fixo para todos os pesos. O formato novo é
# {"modo": "auto"|"fixo", "fixo": "...", "porPeso": {"baixo": {"modelo", "esforco"}, ...}}.
# O dispatcher e este módulo leem o mesmo arquivo e o mesmo cache de listas.

PESOS_MODELO = ("baixo", "medio", "alto")
ARQUIVOS_CONFIG_MODELO = [
    Path.home() / "Library/Application Support/TuttiDash/config.json",
    Path.home() / "Library/Application Support/Lanekeeper/config.json",
    Path.home() / ".transcentia/tools/config.json",
]
CACHE_MODELOS = Path.home() / "Library/Application Support/TuttiDash/modelos-cache.json"
# Antes do FRA-523 o app usava a pasta Lanekeeper; lida só como reserva.
CACHE_MODELOS_ANTIGO = Path.home() / "Library/Application Support/Lanekeeper/modelos-cache.json"
_ID_MODELO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*\Z")

try:
    import privacidade as _privacidade
except ModuleNotFoundError:  # cópia instalada sem o módulo: o filtro fecha
    _privacidade = None


def esforco_das_flags(flags) -> str:
    """Valor de esforço embutido nas flags do manifesto. Vazio se o CLI não recebe um."""
    flags = list(flags or [])
    if "--effort" in flags:
        i = flags.index("--effort")
        if i + 1 < len(flags):
            return str(flags[i + 1])
    for tok in flags:
        if isinstance(tok, str) and "model_reasoning_effort=" in tok:
            return tok.split("=", 1)[1]
    return ""


def padrao_por_peso(lane: str) -> dict:
    """Modelo e esforço de cada peso, como estão no manifesto."""
    saida = {}
    for nivel in PESOS_MODELO:
        flags = flag_de_effort(lane, nivel)
        saida[nivel] = {"modelo": modelo_de_effort(lane, nivel), "esforco": esforco_das_flags(flags)}
    return saida


def lane_tem_esforco(lane: str) -> bool:
    """O CLI da lane recebe esforço (flag no manifesto ou `revisao.flag_esforco`). OpenCode: não."""
    rev = (catalogo().get(lane) or {}).get("revisao") or {}
    if rev.get("flag_esforco"):
        return True
    return any(esforco_das_flags(flag_de_effort(lane, n)) for n in PESOS_MODELO)


def _sem_prefixo(lane: str, modelo: str) -> str:
    pref = prefixo_de_lane(lane)
    m = (modelo or "").strip()
    return m[len(pref):] if pref and m.startswith(pref) else m


def esforcos_aceitos(lane: str, modelo: str, cache: dict | None = None) -> list:
    """Esforços que o modelo aceita, na ordem de preferência (PRD de 29/10):
    1. o que a ferramenta informou para o modelo (Codex: `models_cache.json`);
    2. o que a ferramenta informou para todos os modelos (`*`; Claude: `claude --help`);
    3. a lista do agente no manifesto (`revisao.esforcos`).
    Vazio = a lane não recebe esforço."""
    if not lane_tem_esforco(lane):
        return []
    por_lane = ((cache or {}).get("esforcos") or {}).get(lane) or {}
    if isinstance(por_lane, dict):
        for chave in (com_prefixo_modelo(lane, modelo), _sem_prefixo(lane, modelo)):
            if chave and isinstance(por_lane.get(chave), list) and por_lane[chave]:
                return [str(x) for x in por_lane[chave]]
        if isinstance(por_lane.get("*"), list) and por_lane["*"]:
            return [str(x) for x in por_lane["*"]]
    rev = (catalogo().get(lane) or {}).get("revisao") or {}
    return [str(x) for x in (rev.get("esforcos") or ())]


# `--effort` como palavra inteira (não `--effort-x`), com os níveis entre parênteses na mesma linha
# ou na seguinte (o `claude --help` quebra a descrição).
_EFFORT_HELP = re.compile(r"--effort(?![\w-])[^(\n]*(?:\n[^(\n-]*)?\(([^)]*)\)")


def esforcos_do_help(texto: str) -> list:
    """`claude --help`: os níveis entre parênteses depois de `--effort` (ex.: low, medium, high, xhigh, max)."""
    m = _EFFORT_HELP.search(texto or "")
    if not m:
        return []
    saida = []
    for tok in re.split(r"[,|/\s]+", m.group(1)):
        tok = tok.strip().strip("'\"")
        if re.fullmatch(r"[a-z][a-z0-9_-]{0,15}", tok or "") and tok not in saida:
            saida.append(tok)
    return saida


def esforcos_cache_codex(dados) -> dict:
    """`~/.codex/models_cache.json`: `supported_reasoning_levels` de cada modelo visível."""
    saida = {}
    if not isinstance(dados, dict) or not isinstance(dados.get("models"), list):
        return saida
    for m in dados["models"]:
        if not isinstance(m, dict) or not isinstance(m.get("slug"), str) or not m["slug"].strip():
            continue
        if isinstance(m.get("visibility"), str) and m["visibility"] != "list":
            continue
        niveis = []
        for item in m.get("supported_reasoning_levels") or []:
            e = item.get("effort") if isinstance(item, dict) else item
            if isinstance(e, str) and e and e not in niveis:
                niveis.append(e)
        if niveis:
            saida[m["slug"].strip()] = niveis
    return saida


def buscar_esforcos(lane: str) -> dict:
    """Esforços que a ferramenta informa: {modelo: [...]} ou {"*": [...]}. Vazio se não informa
    ou se falhou (vale o que estava no cache e, depois, o manifesto)."""
    try:
        if lane == "claude":
            niveis = esforcos_do_help(_rodar(["claude", "--help"]))
            return {"*": niveis} if niveis else {}
        if lane == "codex":
            return esforcos_cache_codex(json.loads(
                (Path.home() / ".codex/models_cache.json").read_text(encoding="utf-8")))
    except Exception:  # noqa: BLE001 — acessório: nunca derruba o ciclo
        return {}
    return {}


def atualizar_cache_esforcos(cache: dict, lane: str, dados: dict) -> dict:
    """Troca os esforços da lane só quando a busca trouxe algo."""
    saida = dict(cache or {})
    esf = dict(saida.get("esforcos") or {})
    if dados:
        esf[lane] = dict(dados)
    saida["esforcos"] = esf
    return saida


def prefixo_de_lane(lane: str) -> str:
    """`opencode/` ou `opencode-go/` quando o manifesto usa esse prefixo. Senão, vazio."""
    for nivel in PESOS_MODELO:
        mid = modelo_de_effort(lane, nivel)
        if "/" in mid:
            return mid.split("/", 1)[0] + "/"
    return ""


def com_prefixo_modelo(lane: str, modelo: str) -> str:
    """Põe o prefixo do manifesto quando o modelo gravado veio sem ele."""
    modelo = (modelo or "").strip()
    if not modelo:
        return ""
    pref = prefixo_de_lane(lane)
    if pref and "/" not in modelo:
        return pref + modelo
    return modelo


def normalizar_config_modelo(valor) -> dict:
    """String antiga vira modo fixo. Sem valor, automático sem tabela (vale o manifesto)."""
    if isinstance(valor, str):
        return {"modo": "fixo", "fixo": valor, "porPeso": {}, "aviso": "", "esforco": ""}
    if not isinstance(valor, dict):
        return {"modo": "auto", "fixo": "", "porPeso": {}, "aviso": "", "esforco": ""}
    modo = valor.get("modo")
    if modo not in ("auto", "fixo"):
        modo = "fixo" if isinstance(valor.get("fixo"), str) and valor.get("fixo") else "auto"
    por = {}
    bruto = valor.get("porPeso") if isinstance(valor.get("porPeso"), dict) else {}
    for nivel in PESOS_MODELO:
        item = bruto.get(nivel)
        if isinstance(item, str):
            por[nivel] = {"modelo": item, "esforco": None}
        elif isinstance(item, dict):
            bloco = {"modelo": str(item.get("modelo") or "")}
            bloco["esforco"] = str(item.get("esforco") or "") if "esforco" in item else None
            por[nivel] = bloco
    aviso = valor.get("aviso") if isinstance(valor.get("aviso"), str) else ""
    return {"modo": modo, "fixo": str(valor.get("fixo") or ""), "porPeso": por, "aviso": aviso,
            "esforco": str(valor.get("esforco") or "")}


def config_para_gravar(cfg: dict) -> dict:
    """Dicionário pronto para o config.json (sem esforço None)."""
    por = {}
    for nivel, bloco in (cfg.get("porPeso") or {}).items():
        item = {"modelo": (bloco or {}).get("modelo") or ""}
        if (bloco or {}).get("esforco") is not None:
            item["esforco"] = (bloco or {}).get("esforco") or ""
        por[nivel] = item
    saida = {"modo": "fixo" if cfg.get("modo") == "fixo" else "auto",
             "fixo": cfg.get("fixo") or "", "porPeso": por}
    if cfg.get("esforco"):
        saida["esforco"] = cfg["esforco"]
    if cfg.get("aviso"):
        saida["aviso"] = cfg["aviso"]
    return saida


def bruto_modelo(lane: str, arquivos=None):
    """Valor cru de `lanes.modelo.<lane>`. A chave plana antiga ganha da aninhada."""
    for cfg in (ARQUIVOS_CONFIG_MODELO if arquivos is None else arquivos):
        if not Path(cfg).exists():
            continue
        try:
            dados = json.loads(Path(cfg).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError):
            continue
        if not isinstance(dados, dict):
            continue
        v = dados.get(f"lanes.modelo.{lane}")
        if not v:
            v = ((dados.get("lanes") or {}).get("modelo") or {}).get(lane)
        if v:
            return v
    return None


def ler_cache_modelos(caminho=None) -> dict:
    if caminho is None:
        caminho = CACHE_MODELOS if CACHE_MODELOS.exists() else CACHE_MODELOS_ANTIGO
    p = Path(caminho)
    try:
        dados = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError, TypeError):
        return {}
    return dados if isinstance(dados, dict) else {}


def gravar_cache_modelos(caminho, cache: dict) -> None:
    p = Path(caminho)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(p)


def atualizar_cache_lista(cache: dict, lane: str, modelos, agora: str = "") -> dict:
    """Troca a lista só quando a nova não está vazia, e guarda a anterior para detectar sumiço."""
    saida = {
        "atualizado_em": (cache or {}).get("atualizado_em") or "",
        "listas": dict((cache or {}).get("listas") or {}),
        "anteriores": dict((cache or {}).get("anteriores") or {}),
        "avisos": dict((cache or {}).get("avisos") or {}),
        "atualizado_em_por_lane": dict((cache or {}).get("atualizado_em_por_lane") or {}),
        "esforcos": dict((cache or {}).get("esforcos") or {}),
    }
    if modelos:
        antiga = list(saida["listas"].get(lane) or [])
        if antiga:
            saida["anteriores"][lane] = antiga
        saida["listas"][lane] = list(modelos)
        if agora:
            # FRA-564: selo por lane só com lista boa; a que falhou é tentada de novo.
            saida["atualizado_em_por_lane"][lane] = agora
    if agora:
        saida["atualizado_em"] = agora
    return saida


def _passou(selo: str, agora: dt.datetime, intervalo_s: float) -> bool:
    """True sem selo, com selo ilegível ou quando já passou `intervalo_s`."""
    if not selo:
        return True
    try:
        ult = dt.datetime.fromisoformat(selo)
    except ValueError:
        return True
    if ult.tzinfo is not None and agora.tzinfo is None:
        agora = agora.astimezone()
    elif ult.tzinfo is None and agora.tzinfo is not None:
        ult = ult.replace(tzinfo=agora.tzinfo)
    return (agora - ult).total_seconds() >= intervalo_s


def lista_modelos_vencida(caminho=None, agora: dt.datetime | None = None, intervalo_s: float = 86400) -> bool:
    cache = ler_cache_modelos(caminho)
    return _passou(cache.get("atualizado_em") or "", agora or dt.datetime.now(), intervalo_s)


def lanes_para_atualizar(lanes, caminho=None, agora: dt.datetime | None = None,
                         intervalo_s: float = 86400, espera_s: float = 3600) -> list:
    """Lanes cuja lista boa tem mais de um dia (ou nunca veio). A última tentativa (`atualizado_em`,
    que o app também grava ao abrir os Ajustes) segura novas tentativas por `espera_s` (FRA-564)."""
    cache = ler_cache_modelos(caminho)
    agora = agora or dt.datetime.now()
    if not _passou(cache.get("atualizado_em") or "", agora, espera_s):
        return []
    selos = cache.get("atualizado_em_por_lane") or {}
    if not isinstance(selos, dict):
        selos = {}
    return [lane for lane in lanes if _passou(str(selos.get(lane) or ""), agora, intervalo_s)]


def _na_lista(lane: str, modelo: str, lista) -> bool:
    alvo = com_prefixo_modelo(lane, modelo)
    return any(com_prefixo_modelo(lane, x) == alvo for x in (lista or []))


def modelo_sumiu(modelo: str, lane: str, cache: dict | None) -> bool:
    """True só quando o modelo estava na lista anterior e saiu da lista boa atual."""
    if not modelo or not cache:
        return False
    listas = (cache.get("listas") or {}).get(lane) or []
    anteriores = (cache.get("anteriores") or {}).get(lane) or []
    if not listas or not anteriores:
        return False
    return _na_lista(lane, modelo, anteriores) and not _na_lista(lane, modelo, listas)


def _aviso_sumiu(lane: str, modelo: str, peso: str | None = None) -> str:
    nome = com_prefixo_modelo(lane, modelo)
    if peso:
        return f"o modelo {nome} saiu da lista; o peso {peso} voltou ao padrão"
    return f"o modelo {nome} saiu da lista; a lane voltou ao automático"


AVISO_FIXO_VAZIO = "modo fixo sem modelo; a lane usa o automático"  # igual ao ModeloLane.avisoFixoVazio


def _aviso_esforco(esforco: str, modelo: str, padrao: str) -> str:
    return (f"o esforço {esforco} não vale para {modelo or 'o modelo padrão'}; "
            f"usei o padrão{f' ({padrao})' if padrao else ''}")


def _aviso_esforco_padrao(esforco: str, modelo: str) -> str:
    return f"o esforço padrão {esforco} não vale para {modelo or 'o modelo padrão'}; o CLI usa o dele"


def _esforco_valido(lane: str, modelo: str, esforco: str, cache: dict | None) -> bool:
    aceitos = esforcos_aceitos(lane, modelo, cache)
    return bool(aceitos) and esforco in aceitos


def resolver_modelo(lane: str, effort: str, bruto, cache: dict | None = None) -> dict:
    """Modelo, esforço, flags e aviso para este peso. Modelo sumido não é usado.

    Esforço (PRD de 29/10): o escolhido na tela vale mesmo com o modelo no padrão; no Fixo,
    um esforço só vale para os três pesos. Vazio = o padrão do peso. Esforço que o modelo
    não aceita (ou lane sem esforço) cai no padrão, com aviso: flag inválida nunca vai ao CLI."""
    cfg = normalizar_config_modelo(bruto) if bruto is not None else normalizar_config_modelo(None)
    cache = cache or {}
    padrao = padrao_por_peso(lane).get(effort) or {"modelo": "", "esforco": ""}
    aviso = ""
    modo = cfg["modo"]
    pedido = ""
    if modo == "fixo" and not cfg["fixo"]:
        # FRA-564: «Fixo» sem modelo roda no automático; o aviso deixa isso visível.
        aviso = AVISO_FIXO_VAZIO
    if modo == "fixo" and cfg["fixo"]:
        if modelo_sumiu(cfg["fixo"], lane, cache):
            modo = "auto"
            aviso = _aviso_sumiu(lane, cfg["fixo"])
        else:
            modelo = com_prefixo_modelo(lane, cfg["fixo"])
            pedido = cfg.get("esforco") or ""
            aviso = "modelo fixo"
    if modo != "fixo" or not cfg["fixo"] or aviso != "modelo fixo":
        modo = "auto"
        bloco = (cfg["porPeso"] or {}).get(effort) or {}
        modelo_cfg = (bloco.get("modelo") or "") if isinstance(bloco, dict) else ""
        if modelo_cfg and modelo_sumiu(modelo_cfg, lane, cache):
            if not aviso:
                aviso = _aviso_sumiu(lane, modelo_cfg, effort)
            modelo_cfg = ""
        modelo = com_prefixo_modelo(lane, modelo_cfg) if modelo_cfg else padrao["modelo"]
        pedido = (bloco.get("esforco") or "") if isinstance(bloco, dict) else ""
        if not aviso:
            aviso = cfg.get("aviso") or ""
    esforco, explicito = padrao["esforco"], False
    if pedido:
        if _esforco_valido(lane, modelo, pedido, cache):
            esforco, explicito = pedido, True
        else:
            aviso = _aviso_esforco(pedido, modelo, padrao["esforco"])
    if not explicito and esforco:
        aceitos = esforcos_aceitos(lane, modelo, cache)
        if aceitos and esforco not in aceitos:
            # O padrão do peso também não vai ao CLI se o modelo não o aceita (revisão do PR #17).
            aviso = _aviso_esforco_padrao(esforco, modelo)
            esforco, explicito = "", True
    flags = montar_flags(lane, effort, modelo, esforco, explicito)
    return {"modelo": modelo, "esforco": esforco, "esforco_explicito": explicito,
            "modo": modo, "aviso": aviso, "flags": flags}


def modelo_efetivo(lane: str, effort: str, arquivos=None, cache: dict | None = None) -> str:
    """Mesma escolha que o dispatcher usa para montar o comando."""
    if cache is None:
        cache = ler_cache_modelos()
    return resolver_modelo(lane, effort, bruto_modelo(lane, arquivos), cache)["modelo"]


def montar_flags(lane: str, effort: str, modelo: str, esforco: str, explicito: bool) -> list:
    """Flags do manifesto com o modelo (e, se pedido, o esforço) trocados."""
    flags = list(flag_de_effort(lane, effort))
    id_padrao = modelo_de_effort(lane, effort)
    if modelo and modelo != id_padrao:
        flags = _trocar_modelo(flags, id_padrao, modelo, lane)
    if explicito:
        flags = _trocar_esforco(flags, esforco, lane)
    return flags


def _trocar_modelo(flags: list, id_velho: str, modelo: str, lane: str) -> list:
    if id_velho and id_velho in flags:
        return [modelo if tok == id_velho else tok for tok in flags]
    saida, i, trocou = [], 0, False
    while i < len(flags):
        if flags[i] in ("-m", "--model") and i + 1 < len(flags):
            saida += [flags[i], modelo]
            i += 2
            trocou = True
        else:
            saida.append(flags[i])
            i += 1
    if trocou or not modelo:
        return saida
    rev = (catalogo().get(lane) or {}).get("revisao") or {}
    tmpl = list(rev.get("flag_modelo") or [])
    if tmpl:
        return [modelo if tok == "{modelo}" else tok for tok in tmpl] + saida
    if _lane_usa(lane, "--model"):
        return ["--model", modelo] + saida
    return ["-m", modelo] + saida


def _trocar_esforco(flags: list, esforco: str, lane: str) -> list:
    if "--effort" in flags:
        saida, i = [], 0
        while i < len(flags):
            if flags[i] == "--effort" and i + 1 < len(flags):
                if esforco:
                    saida += ["--effort", esforco]
                i += 2
            else:
                saida.append(flags[i])
                i += 1
        return saida
    if any(isinstance(tok, str) and "model_reasoning_effort=" in tok for tok in flags):
        if not esforco:
            return [tok for tok in flags if "model_reasoning_effort=" not in str(tok)]
        return [f"model_reasoning_effort={esforco}" if "model_reasoning_effort=" in str(tok) else tok
                for tok in flags]
    if not esforco:
        return flags
    rev = (catalogo().get(lane) or {}).get("revisao") or {}
    tmpl = list(rev.get("flag_esforco") or [])
    if tmpl:
        return flags + [esforco if tok == "{esforco}" else str(tok).replace("{esforco}", esforco) for tok in tmpl]
    if _lane_usa(lane, "--effort"):
        return flags + ["--effort", esforco]
    return flags


def _lane_usa(lane: str, flag: str) -> bool:
    for nivel in PESOS_MODELO:
        if flag in flag_de_effort(lane, nivel):
            return True
    return False


def ajuste_sumido(lane: str, bruto, cache: dict | None) -> tuple:
    """(config nova, aviso) se algum modelo escolhido saiu da lista. (None, aviso) se nada mudou."""
    if bruto is None:
        return None, ""
    cfg = normalizar_config_modelo(bruto)
    aviso = ""
    mudou = False
    if cfg["modo"] == "fixo" and cfg["fixo"] and modelo_sumiu(cfg["fixo"], lane, cache):
        cfg["modo"] = "auto"
        aviso = _aviso_sumiu(lane, cfg["fixo"])
        cfg["aviso"] = aviso
        mudou = True
    for peso, bloco in list((cfg.get("porPeso") or {}).items()):
        modelo = (bloco or {}).get("modelo") or ""
        if not modelo or not modelo_sumiu(modelo, lane, cache):
            continue
        padrao = padrao_por_peso(lane).get(peso) or {}
        bloco = dict(bloco)
        bloco["modelo"] = padrao.get("modelo") or ""
        if bloco.get("esforco") is None:
            bloco["esforco"] = padrao.get("esforco") or ""
        cfg["porPeso"][peso] = bloco
        if not aviso:
            aviso = _aviso_sumiu(lane, modelo, peso)
        cfg["aviso"] = aviso
        mudou = True
    if not mudou:
        return None, cfg.get("aviso") or ""
    return cfg, aviso


def linhas_de_item(linhas) -> list:
    """Só as linhas de lista (`*` ou `-`). O `grok models` abre com frases ("You are logged in…",
    "Default model: …") que viravam os ids `You` e `Default` (FRA-564)."""
    return [l for l in (linhas or []) if str(l).strip()[:1] in ("-", "*")]


def tokens_de_lista(linhas) -> list:
    """Uma linha de `opencode models` / `grok models` vira um id, se parecer um."""
    saida = []
    for bruto in linhas or []:
        s = str(bruto).strip().lstrip("-*").strip().strip("`")
        if not s or s.endswith(":"):
            continue
        tok = s.split()[0].strip("`").rstrip(",")
        if _ID_MODELO.fullmatch(tok):
            saida.append(tok)
    return saida


def filtrar_modelos(lane: str, linhas, pode=None) -> list:
    """Fica com o prefixo da lane. OpenCode ainda passa por `pode_receber_codigo`."""
    pref = prefixo_de_lane(lane)
    privado = bool((catalogo().get(lane) or {}).get("privacidade"))
    saida, vistos = [], set()
    for tok in tokens_de_lista(linhas):
        modelo = tok
        if pref:
            if "/" not in modelo:
                modelo = pref + modelo
            if not modelo.startswith(pref):
                continue
        if privado:
            fn = pode if pode is not None else (None if _privacidade is None else _privacidade.pode_receber_codigo)
            if fn is None:
                continue
            ok, _motivo = fn(modelo)
            if not ok:
                continue
        if modelo not in vistos:
            vistos.add(modelo)
            saida.append(modelo)
    return saida


def _rodar(argv: list) -> str:
    ambiente = dict(os.environ)
    ambiente["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + ambiente.get("PATH", "")
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=12, env=ambiente)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if r.returncode != 0:
        return ""
    return r.stdout or ""


def _get_json(url: str, headers: dict):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=8) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def _ids_de_json(dados) -> list:
    blocos = []
    if isinstance(dados, dict):
        for chave in ("data", "models", "items"):
            if isinstance(dados.get(chave), list):
                blocos = dados[chave]
                break
    elif isinstance(dados, list):
        blocos = dados
    saida, vistos = [], set()
    for item in blocos:
        modelo = ""
        if isinstance(item, str):
            modelo = item.strip()
        elif isinstance(item, dict):
            for chave in ("id", "slug", "model"):
                if isinstance(item.get(chave), str) and item[chave].strip():
                    modelo = item[chave].strip()
                    break
        if modelo and _ID_MODELO.fullmatch(modelo) and modelo not in vistos:
            vistos.add(modelo)
            saida.append(modelo)
    return saida


def _lista_extra(lane: str):
    """Lista de outra fonte (`gasto_privado`, só no build pessoal, FRA-565), ou None.

    O módulo fica fora do repositório aberto; quando existe, o install.sh o copia ao lado deste."""
    try:
        import gasto_privado  # noqa: PLC0415 — opcional
    except ImportError:
        return None
    f = getattr(gasto_privado, f"modelos_{lane}", None)
    if not callable(f):
        return None
    return f(_get_json, _ids_de_json, Path.home())


def _modelos_claude() -> list:
    """API oficial com `ANTHROPIC_API_KEY`; sem a chave, uma fonte extra, se houver."""
    ambiente = (os.environ.get("ANTHROPIC_API_KEY") or "").strip()
    if ambiente:
        headers = {"anthropic-version": "2023-06-01", "x-api-key": ambiente}
        try:
            return _ids_de_json(_get_json("https://api.anthropic.com/v1/models?limit=1000", headers))
        except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError, TimeoutError):
            return []
    return _lista_extra("claude") or []


def modelos_cache_codex(dados):
    """`~/.codex/models_cache.json`, a lista que o próprio Codex CLI usa: só `visibility == "list"`
    (sem os ocultos), na ordem de `priority`. None = formato desconhecido."""
    if not isinstance(dados, dict) or not isinstance(dados.get("models"), list):
        return None
    itens = []
    for ordem, m in enumerate(dados["models"]):
        if not isinstance(m, dict):
            continue
        slug = m.get("slug")
        if not isinstance(slug, str) or not _ID_MODELO.fullmatch(slug.strip()):
            continue
        visivel = m.get("visibility")
        if isinstance(visivel, str) and visivel != "list":
            continue
        prioridade = m.get("priority")
        prioridade = prioridade if isinstance(prioridade, (int, float)) and not isinstance(prioridade, bool) else float("inf")
        itens.append((prioridade, ordem, slug.strip()))
    saida, vistos = [], set()
    for _p, _o, slug in sorted(itens):
        if slug not in vistos:
            vistos.add(slug)
            saida.append(slug)
    return saida


def _modelos_codex() -> list:
    """Uma fonte só: com o cache do Codex CLI, só ele (fontes diferentes dariam falso "saiu da
    lista"). Sem o cache, a API oficial com `OPENAI_API_KEY`, ou uma fonte extra, se houver."""
    try:
        cache = modelos_cache_codex(json.loads(
            (Path.home() / ".codex/models_cache.json").read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, UnicodeError):
        cache = None
    if cache is not None:
        return cache
    ambiente = (os.environ.get("OPENAI_API_KEY") or "").strip()
    if ambiente:
        try:
            return _ids_de_json(_get_json("https://api.openai.com/v1/models",
                                          {"Authorization": f"Bearer {ambiente}"}))
        except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError, TimeoutError):
            return []
    return _lista_extra("codex") or []


def buscar_modelos(lane: str) -> list:
    """Lista viva da ferramenta. Vazia se o comando ou a chave falhar (a cache anterior fica)."""
    try:
        if lane in ("opencode", "opencode-go"):
            return filtrar_modelos(lane, _rodar(["opencode", "models"]).splitlines())
        if lane == "grok":
            return filtrar_modelos(lane, linhas_de_item(_rodar(["grok", "models"]).splitlines()))
        if lane == "claude":
            return _modelos_claude()
        if lane == "codex":
            return _modelos_codex()
    except Exception:  # noqa: BLE001 — lista é acessório; o ciclo da lane não pode cair
        return []
    return []