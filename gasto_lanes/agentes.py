"""Registry único de agentes (FRA-372/FRA-410), derivado de `agents.d/*.json`.

A lista de CLIs/lanes NÃO é mais hardcoded aqui: `catalogo.py` lê os manifests
versionados no repo (mesmos que o Swift lê) e este módulo expõe a visão Python
com a mesma API de sempre. Adicionar um agente novo = 1 arquivo JSON.

Fallback embutido (em `catalogo.py`) cobre teste isolado e máquina sem
`agents.d/` instalado; a paridade entre o disco e o embutido é cobrada por
`tests/test_catalogo.py`.

Campos expostos por agente:
  custo  "estimado" (preço de tabela) ou "informado" (servidor). Fora do
         catálogo, custo desconhecido vira "informado"; nunca vira zero.
  cli    comando do CLI (login, renovação, `--resume`). None = conta sem CLI
         próprio (cursor) — cai no fallback.
  resume CLI para `<cli> --resume <id>`, ou None quando o CLI não tem resume
         conhecido (cai em `claude`).
  peso   fontes de peso para o dispatcher, em ordem: "quota" (% da conta) cai
         para "gasto" (gasto conhecido da semana no ledger, FRA-371) e depois
         "manual" (peso fixo da config). Lane sem nenhuma fonte aparece como
         "sem peso" — nunca é excluída em silêncio.
"""
from __future__ import annotations

from . import catalogo

CUSTO_PADRAO_FALLBACK = "informado"
CLI_PADRAO_FALLBACK = "claude"


def _agentes() -> dict:
    """Catálogo na forma antiga: nome -> {custo, label, cli, resume, peso}."""
    return {
        nome: {
            "custo": d["custo"],
            "label": nome,
            "cli": d["cli"],
            "resume": d["resume"],
            "peso": d["peso"],
        }
        for nome, d in catalogo.catalogo().items()
    }


AGENTES: dict = _agentes()
AGENTES_CONHECIDOS: tuple = tuple(AGENTES)


def conhecidos() -> tuple:
    return tuple(catalogo.catalogo())


def custo_para(lane: str) -> str:
    """Tipo de custo de um agente com custo > 0. Desconhecido vira informado."""
    return AGENTES.get(lane, {}).get("custo", CUSTO_PADRAO_FALLBACK)


def cli_para(lane: str) -> str:
    """CLI do agente. Sem CLI próprio (cursor), cai no fallback `claude`."""
    return AGENTES.get(lane, {}).get("cli") or CLI_PADRAO_FALLBACK


def resume_para(lane: str) -> str:
    """CLI do `<cli> --resume <id>`. Sem resume conhecido, cai em `claude`."""
    return AGENTES.get(lane, {}).get("resume") or CLI_PADRAO_FALLBACK


def peso_fontes(lane: str) -> tuple:
    return tuple(AGENTES.get(lane, {}).get("peso", ("quota", "gasto")))