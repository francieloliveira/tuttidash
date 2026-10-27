#!/usr/bin/env python3
"""Grava as respostas de uso das contas como fixtures versionadas.

Cada arquivo em `tests/fixtures/uso/` é a resposta crua de um endpoint, no formato
que o servidor manda. O Swift (`UsoCopilotTests`) lê daqui em vez de ter o JSON
embutido no arquivo de teste.

Por que assim, e não uma cópia Swift: o parser de uso só existe em Swift hoje,
mas o payload é dado de servidor, não código. Deixar no arquivo de teste é uma
cópia sem dono; deixar em `fixtures/` é dado que qualquer linguagem lê e que dá
para comparar com o que a API devolve. É a mesma direção do `agents.d/`: fonte
única, sem lista parallel.

Uso: python3 tests/fixtures/gerar_uso.py
"""
from __future__ import annotations

import json
from pathlib import Path

AQUI = Path(__file__).resolve().parent

#: endpoint -> (arquivo, resposta). Mês travado para os testes serem determinísticos.
RESPOSTAS: dict = {
    "github_premium_request_usage": (
        "copilot.json",
        {"timePeriod": {"year": 2026, "month": 10},
         "user": "octocat",
         "product": "copilot",
         "usageItems": [
             {"product": "copilot", "sku": "copilot_premium_request", "model": "gpt-4o",
              "unitType": "requests", "pricePerUnit": 0.04,
              "grossQuantity": 100, "grossAmount": 4,
              "discountQuantity": 0, "discountAmount": 0,
              "netQuantity": 100, "netAmount": 4},
             {"product": "copilot", "sku": "copilot_premium_request", "model": "claude-sonnet",
              "unitType": "requests", "pricePerUnit": 0.04,
              "grossQuantity": 50, "grossAmount": 2,
              "discountQuantity": 0, "discountAmount": 0,
              "netQuantity": 50, "netAmount": 2},
         ]},
    ),
}


def main() -> int:
    destino = AQUI / "uso"
    destino.mkdir(parents=True, exist_ok=True)
    for endpoint, (arquivo, corpo) in RESPOSTAS.items():
        caminho = destino / arquivo
        caminho.write_text(json.dumps(corpo, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
        print(f"{endpoint:24} -> {caminho.relative_to(AQUI.parent.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())