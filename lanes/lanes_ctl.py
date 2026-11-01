#!/usr/bin/python3
"""Habilita/desabilita uma lane (usado pelo menu da barra).

    lanes_ctl.py enable claude
    lanes_ctl.py disable grok

O nome casa `^[a-z0-9][a-z0-9-]*$` e tem de estar no catálogo
(`lanes_por_prioridade`). Habilitar ainda exige o nome em `implemented`
no heartbeat. Fora disso, `enable` e `disable` não mexem em arquivo.

Habilitar também tira a lane do marcador `disabled-by-user` (arquivo com nomes
ou pasta com um arquivo por lane). Nesse caso o `unlink` só atinge o filho
direto da pasta: um componente, sem separador. O painel lê esse marcador antes
do `enabled`; se ele ficasse para trás, a lane voltaria a aparecer "Desligada"
mesmo habilitada.
"""
import json
import os
import re
import sys
import tempfile
from pathlib import Path

# Catálogo ao lado do script (cópia instalada) ou em gasto_lanes/ (dev no repo).
_AQUI = Path(__file__).resolve().parent
for _cand in (_AQUI, _AQUI.parent / "gasto_lanes"):
    if (_cand / "catalogo.py").is_file():
        sys.path.insert(0, str(_cand))
        break
import catalogo  # noqa: E402

D = Path.home() / ".transcentia" / "lanes"
ENABLED = D / "enabled"
HEARTBEAT = D / "heartbeat.json"
USER_OFF = D / "disabled-by-user"
LANE_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def lane_aceita(lane):
    """Nome de lane do catálogo. Recusa `..`, barra e o que o heartbeat inventar."""
    if not isinstance(lane, str) or LANE_RE.fullmatch(lane) is None:
        return False
    if "/" in lane or "\\" in lane:
        return False
    try:
        conhecidas = catalogo.lanes_por_prioridade()
    except Exception:
        return False
    return lane in conhecidas


def _marca_direta(lane):
    """Filho direto de `disabled-by-user`, ou None se o caminho sai da pasta."""
    if not isinstance(lane, str) or LANE_RE.fullmatch(lane) is None:
        return None
    if "/" in lane or "\\" in lane or lane in (".", ".."):
        return None
    if not USER_OFF.is_dir():
        return None
    base = USER_OFF.resolve()
    marca = base / lane
    # Um componente só. Não segue a folha: `unlink` remove a entrada, não o alvo.
    if marca.parent != base:
        return None
    return marca


def _gravar(destino, nomes):
    """Troca atômica: quem lê o arquivo nunca o vê pela metade."""
    fd, tmp = tempfile.mkstemp(dir=destino.parent)
    with os.fdopen(fd, "w") as fh:
        fh.write(" ".join(sorted(nomes)) + "\n")
    os.replace(tmp, destino)


def liberar_desligada_pelo_usuario(lane):
    """Tira `lane` de `disabled-by-user`. Devolve True se havia o que tirar."""
    if not isinstance(lane, str) or LANE_RE.fullmatch(lane) is None:
        return False
    if USER_OFF.is_dir():
        marca = _marca_direta(lane)
        if marca is None or not marca.exists():
            return False
        marca.unlink()
        return True
    if not USER_OFF.exists():
        return False
    try:
        nomes = set(USER_OFF.read_text().split())
    except OSError:
        return False
    if lane not in nomes:
        return False
    nomes.discard(lane)
    _gravar(USER_OFF, nomes)
    return True


def main(argv):
    if len(argv) != 3 or argv[1] not in ("enable", "disable"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    action, lane = argv[1], argv[2]
    if not lane_aceita(lane):
        print("nome de lane inválido", file=sys.stderr)
        return 1
    try:
        implemented = set(json.loads(HEARTBEAT.read_text()).get("implemented") or [])
    except (OSError, ValueError):
        implemented = set()
    current = set(ENABLED.read_text().split()) if ENABLED.exists() else set()
    if action == "enable":
        if lane not in implemented:
            print(f"lane {lane} não tem execução real ainda; não habilitada", file=sys.stderr)
            return 1
        current.add(lane)
    else:
        current.discard(lane)
    D.mkdir(parents=True, exist_ok=True)
    _gravar(ENABLED, current)
    print(f"habilitadas: {' '.join(sorted(current)) or 'nenhuma'}")
    if action == "enable" and liberar_desligada_pelo_usuario(lane):
        print(f"{lane} saiu de disabled-by-user")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
