"""Resolução de caminhos e opções.

Um arquivo só (`arquivo_config`). Precedência, a primeira que vale:

  1. ``TRANSCENTIA_GASTO_CONFIG`` (mesmo se o arquivo ainda não existe: não cai no próximo)
  2. ``~/Library/Application Support/TuttiDash/config.json``
  3. ``~/Library/Application Support/Lanekeeper/config.json``
  4. ``~/Library/Application Support/TranscentIA Gasto/config.json``
  5. ``~/.transcentia/tools/config.json`` (legado)

No Windows não há as pastas do Mac: o único candidato é
``%APPDATA%/tuttidash/config.json``.

Dentro do arquivo escolhido, cada opção de caminho ou número segue
(a primeira que existir vence):

  1. flag na linha de comando (``--config`` também escolhe o arquivo e fica acima da env)
  2. variável de ambiente da opção
  3. valor no arquivo
  4. padrão da plataforma

Quem lê a config (``projetos``, ``catalogo``, ``dispatcher``, ``cfg``, o vigia
e o app) usa este módulo. Não mantenha outra lista de caminhos.
"""
from __future__ import annotations

import copy
import json
import os
import re
import sys
from pathlib import Path
from typing import Mapping, Optional

ENV_CONFIG = "TRANSCENTIA_GASTO_CONFIG"
ENV = {
    "logs_dir": "TRANSCENTIA_LANES_LOGS",
    "state_dir": "TRANSCENTIA_LANES_STATE",
    "ledger": "TRANSCENTIA_GASTO_LEDGER",
    "teto_semanal_usd": "TRANSCENTIA_GASTO_TETO",
    "aviso_pct": "TRANSCENTIA_GASTO_AVISO_PCT",
}
PATH_KEYS = ("logs_dir", "state_dir", "ledger")
NUM_KEYS = ("teto_semanal_usd", "aviso_pct")
AVISO_PCT_PADRAO = 80.0

# Catálogo padrão de agentes: fonte única em `agentes.py` (FRA-372). A chave
# `agentes` na config pode ser uma lista ["claude", "codex"] ou um dict
# {"codex": {"custo": "estimado"}}. O import é tardio: este módulo também é
# carregado pelo caminho (cópia ao lado do `cfg`) só para achar o arquivo.


class ConfigError(Exception):
    pass


def is_windows(platform: Optional[str] = None) -> bool:
    return (platform or sys.platform).startswith("win")


def _expand(value: str, env: Mapping[str, str], home: Path) -> Path:
    """Expande ~, $VAR e %VAR% usando o ambiente informado (testável)."""
    out = value
    for key, val in env.items():
        out = out.replace(f"%{key}%", val).replace(f"${{{key}}}", val)
    # $VAR simples
    out = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", lambda m: env.get(m.group(1), m.group(0)), out)
    if out == "~" or out.startswith("~/") or out.startswith("~\\"):
        out = str(home) + out[1:]
    return Path(out)


def app_dir(platform: Optional[str] = None, env: Optional[Mapping[str, str]] = None,
            home: Optional[Path] = None) -> Path:
    """Pasta da própria ferramenta (config e ledger). Nunca é pasta das lanes."""
    env = os.environ if env is None else env
    home = Path.home() if home is None else home
    if is_windows(platform):
        base = env.get("APPDATA")
        return (Path(base) if base else home / "AppData" / "Roaming") / "tuttidash"
    return home / ".transcentia" / "tools"


def platform_defaults(platform: Optional[str] = None, env: Optional[Mapping[str, str]] = None,
                      home: Optional[Path] = None) -> dict:
    env = os.environ if env is None else env
    home = Path.home() if home is None else home
    if is_windows(platform):
        local = env.get("LOCALAPPDATA")
        local_dir = Path(local) if local else home / "AppData" / "Local"
        # Sugestão: as lanes hoje rodam no Mac. No Windows, aponte para uma cópia
        # (ou pasta sincronizada) dos logs; o padrão abaixo é só um lugar previsível.
        logs = local_dir / "TranscentIA" / "Logs" / "lanes"
        state = home / ".transcentia" / "lanes"
    else:
        logs = home / "Library" / "Logs" / "TranscentIA" / "lanes"
        state = home / ".transcentia" / "lanes"
    return {
        "logs_dir": logs,
        "state_dir": state,
        "ledger": app_dir(platform, env, home) / "ledger.jsonl",
        "teto_semanal_usd": None,
        "aviso_pct": AVISO_PCT_PADRAO,
    }


def default_config_path(platform: Optional[str] = None, env: Optional[Mapping[str, str]] = None,
                        home: Optional[Path] = None) -> Path:
    return app_dir(platform, env, home) / "config.json"


def _agentes_padrao():
    try:
        from .agentes import AGENTES_CONHECIDOS
    except ImportError:
        from agentes import AGENTES_CONHECIDOS
    return AGENTES_CONHECIDOS


def caminhos_config(home: Optional[Path] = None, platform: Optional[str] = None,
                    env: Optional[Mapping[str, str]] = None) -> tuple:
    """Candidatos sem a env, na ordem TuttiDash > Lanekeeper > TranscentIA Gasto > legado."""
    env = os.environ if env is None else env
    home = Path.home() if home is None else Path(home)
    if is_windows(platform):
        return (app_dir(platform, env, home) / "config.json",)
    return (
        home / "Library/Application Support/TuttiDash/config.json",
        home / "Library/Application Support/Lanekeeper/config.json",
        home / "Library/Application Support/TranscentIA Gasto/config.json",
        home / ".transcentia/tools/config.json",
    )


def arquivo_config(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None,
                   platform: Optional[str] = None) -> Optional[Path]:
    """Arquivo de config em uso. None se não há env e nenhum candidato existe.

    A env vence mesmo quando o caminho ainda não existe: não se lê o arquivo
    seguinte. Assim ``projeto()`` e ``linear.*`` não saem de arquivos diferentes.
    """
    env = os.environ if env is None else env
    home = Path.home() if home is None else Path(home)
    bruto = str(env.get(ENV_CONFIG) or "").strip()
    if bruto:
        return _expand(bruto, env, home)
    for caminho in caminhos_config(home, platform, env):
        if caminho.exists():
            return caminho
    return None


def arquivos_em_uso(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None,
                    platform: Optional[str] = None) -> list:
    """Lista de um elemento, ou vazia. Os leitores percorrem esta lista e param."""
    escolhido = arquivo_config(env, home, platform)
    return [escolhido] if escolhido is not None else []


_AUSENTE = object()


def buscar(dados, chave: str):
    """Valor de uma chave pontuada (``linear.owner_label``). ``_AUSENTE`` se faltar."""
    atual = dados
    for parte in str(chave).split("."):
        if isinstance(atual, dict) and parte in atual:
            atual = atual[parte]
        else:
            return _AUSENTE
    return atual


def ler_objeto(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None,
               platform: Optional[str] = None) -> tuple:
    """``(caminho ou None, dict)``. Ausente ou ilegível vira ``{}`` — não tenta o próximo."""
    caminho = arquivo_config(env, home, platform)
    if caminho is None or not caminho.is_file():
        return caminho, {}
    try:
        dados = json.loads(caminho.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        return caminho, {}
    if not isinstance(dados, dict):
        return caminho, {}
    return caminho, dados


def obter(chave: str, padrao=None, env: Optional[Mapping[str, str]] = None,
          home: Optional[Path] = None, platform: Optional[str] = None):
    """Valor da chave no arquivo em uso. Vazio ou ausente devolve ``padrao``."""
    _, dados = ler_objeto(env, home, platform)
    valor = buscar(dados, chave)
    if valor is _AUSENTE or valor is None or valor == "":
        return padrao
    return valor


def tipos_compativeis(atual, novo) -> bool:
    """True quando ``novo`` pode substituir ``atual``. Texto não cobre dict, bool não cobre número."""
    if isinstance(atual, bool) or isinstance(novo, bool):
        return isinstance(atual, bool) and isinstance(novo, bool)
    if isinstance(atual, (int, float)) and isinstance(novo, (int, float)):
        return True
    if isinstance(atual, str) and isinstance(novo, str):
        return True
    if isinstance(atual, list) and isinstance(novo, list):
        return True
    if isinstance(atual, dict) and isinstance(novo, dict):
        return True
    return False


def job_valido(item) -> bool:
    """Mesma régua do app (``Trabalho.lista``): label, nome sem barra, chave, script e log."""
    if not isinstance(item, dict):
        return False
    for campo in ("label", "nome", "chave", "script", "log"):
        valor = item.get(campo)
        if not isinstance(valor, str) or not valor.strip():
            return False
    if "/" in item["nome"]:
        return False
    if "argumentos" in item:
        args = item["argumentos"]
        if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
            return False
    if "interpretador" in item and not isinstance(item["interpretador"], str):
        return False
    if "intervalo_padrao" in item and (
            isinstance(item["intervalo_padrao"], bool)
            or not isinstance(item["intervalo_padrao"], (int, float))):
        return False
    if "run_at_load" in item and not isinstance(item["run_at_load"], bool):
        return False
    return True


def jobs_validos(bruto):
    """Cópia da lista se todos os jobs passam. None = não migrar (fica o padrão)."""
    if not isinstance(bruto, list) or not bruto:
        return None
    if not all(job_valido(j) for j in bruto):
        return None
    return [copy.deepcopy(j) for j in bruto]


def mesclar(base, extra) -> dict:
    """Copia ``extra`` sobre ``base``. Dict desce. Tipo diferente não substitui.

    ``jobs`` que já é lista (``agendas.jobs``) só entra se cada item for um
    lançador válido. Lista vazia, texto ou item sem label ficam de fora.
    """
    out = copy.deepcopy(base) if isinstance(base, dict) else {}
    if not isinstance(extra, dict):
        return out
    for chave, valor in extra.items():
        if chave == "jobs" and isinstance(out.get(chave), list):
            validos = jobs_validos(valor)
            if validos is None:
                continue
            out[chave] = validos
            continue
        if chave in out and isinstance(out[chave], dict) and isinstance(valor, dict):
            out[chave] = mesclar(out[chave], valor)
            continue
        if chave in out and not tipos_compativeis(out[chave], valor):
            continue
        out[chave] = valor
    return out


def _num(key: str, value, origem: str) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        raise ConfigError(f"{key} inválido em {origem}: {value!r} (esperado número)") from None
    if out < 0:
        raise ConfigError(f"{key} não pode ser negativo ({origem})")
    return out


def resolve(cli: Optional[Mapping] = None, env: Optional[Mapping[str, str]] = None,
            platform: Optional[str] = None, home: Optional[Path] = None) -> dict:
    """Devolve {"valores": {...}, "origem": {...}, "config_file": Path}."""
    cli = dict(cli or {})
    env = dict(os.environ if env is None else env)
    home = Path.home() if home is None else home

    defaults = platform_defaults(platform, env, home)

    if cli.get("config"):
        cfg_path, cfg_required = _expand(str(cli["config"]), env, home), True
    else:
        # Mesma escolha de `arquivo_config` (env > TuttiDash > Lanekeeper >
        # TranscentIA Gasto > legado). Sem arquivo, o caminho novo fica só
        # como referência: a leitura continua opcional.
        escolhido = arquivo_config(env, home, platform)
        if escolhido is None:
            cfg_path, cfg_required = caminhos_config(home, platform, env)[0], False
        else:
            cfg_path = escolhido
            cfg_required = bool(str(env.get(ENV_CONFIG) or "").strip())

    file_vals: dict = {}
    if cfg_path.exists():
        try:
            file_vals = json.loads(cfg_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ConfigError(f"config ilegível em {cfg_path}: {exc}") from None
        if not isinstance(file_vals, dict):
            raise ConfigError(f"config em {cfg_path} precisa ser um objeto JSON")
    elif cfg_required:
        raise ConfigError(f"arquivo de config não encontrado: {cfg_path}")

    valores, origem = {}, {}
    for key in list(PATH_KEYS) + list(NUM_KEYS):
        if cli.get(key) not in (None, ""):
            raw, src = cli[key], "flag"
        elif env.get(ENV[key]) not in (None, ""):
            raw, src = env[ENV[key]], f"ambiente ({ENV[key]})"
        elif file_vals.get(key) not in (None, ""):
            raw, src = file_vals[key], f"config ({cfg_path})"
        else:
            raw, src = defaults[key], "padrão"
        if key in PATH_KEYS:
            valores[key] = raw if isinstance(raw, Path) else _expand(str(raw), env, home)
        else:
            valores[key] = _num(key, raw, src)
        origem[key] = src

    valores["agentes"], origem["agentes"] = _resolve_agentes(file_vals.get("agentes"), cfg_path)

    _guard_ledger(valores["ledger"], valores["logs_dir"], valores["state_dir"])
    return {"valores": valores, "origem": origem, "config_file": cfg_path}


def _resolve_agentes(raw, cfg_path) -> tuple:
    """Normaliza a chave `agentes` da config: lista ou dict -> tuple de nomes."""
    if raw in (None, ""):
        return tuple(_agentes_padrao()), "padrão"
    if isinstance(raw, dict):
        nomes = [str(k).strip() for k in raw.keys() if str(k).strip()]
    elif isinstance(raw, (list, tuple)):
        nomes = [str(x).strip() for x in raw if str(x).strip()]
    else:
        raise ConfigError(f"agentes inválido em config ({cfg_path}): esperado lista ou objeto")
    if not nomes:
        raise ConfigError(f"agentes inválido em config ({cfg_path}): lista vazia")
    # preserva ordem, remove duplicados
    vistos, out = set(), []
    for n in nomes:
        if n not in vistos:
            vistos.add(n)
            out.append(n)
    return tuple(out), f"config ({cfg_path})"


def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _guard_ledger(ledger: Path, logs_dir: Path, state_dir: Path) -> None:
    """O ledger é o único arquivo que a ferramenta grava: nunca dentro das pastas das lanes."""
    for nome, pasta in (("logs das lanes", logs_dir), ("estado das lanes", state_dir)):
        if _inside(ledger, pasta):
            raise ConfigError(
                f"ledger ({ledger}) não pode ficar dentro da pasta de {nome} ({pasta}): "
                "a ferramenta não grava nada nas pastas das lanes")
