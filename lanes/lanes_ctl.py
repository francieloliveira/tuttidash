#!/usr/bin/python3
"""Habilita/desabilita uma lane (usado pelo menu da barra).

    lanes_ctl.py enable claude
    lanes_ctl.py disable grok

Só habilita lanes que o dispatcher declara implementadas no heartbeat.
Desabilitar não interrompe o card em andamento: só impede novos claims.

Habilitar também tira a lane do marcador `disabled-by-user` (arquivo com nomes
ou pasta com um arquivo por lane). O painel lê esse marcador antes do `enabled`;
se ele ficasse para trás, a lane voltaria a aparecer "Desligada" mesmo habilitada.
"""
import json
import os
import sys
import tempfile
from pathlib import Path

D = Path.home() / ".transcentia" / "lanes"
ENABLED = D / "enabled"
HEARTBEAT = D / "heartbeat.json"
USER_OFF = D / "disabled-by-user"


def _gravar(destino, nomes):
    """Troca atômica: quem lê o arquivo nunca o vê pela metade."""
    fd, tmp = tempfile.mkstemp(dir=destino.parent)
    with os.fdopen(fd, "w") as fh:
        fh.write(" ".join(sorted(nomes)) + "\n")
    os.replace(tmp, destino)


def liberar_desligada_pelo_usuario(lane):
    """Tira `lane` de `disabled-by-user`. Devolve True se havia o que tirar."""
    if USER_OFF.is_dir():
        marca = USER_OFF / lane
        if marca.exists():
            marca.unlink()
            return True
        return False
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
