#!/usr/bin/env python3
"""CLI da instalação por projeto do TuttiDash (FRA-698).

Uso:
  tools/instalar.py estado   [--projeto ID|NOME] [--json]
  tools/instalar.py listar   [--json]
  tools/instalar.py refs     [--projeto ID|NOME] [--json]
  tools/instalar.py instalar [--projeto ID|NOME] [--ref BRANCH|TAG|SHA] [--json]
  tools/instalar.py empacotar|validar|subir|parar [--projeto ID|NOME] [--json]

Sem `--projeto`, usa o projeto padrão do cadastro (`gasto_lanes/projetos.py`).
As três classes de instalação e o estado em `~/.transcentia/instalacoes/` estão
em `gasto_lanes/instalar.py`. O app lê o mesmo estado; esta CLI é a única que age.
`--ref` instala a versão pedida a partir de um worktree isolado.
"""
from __future__ import annotations

import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
import instalar  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(instalar.main(sys.argv[1:]))
