"""FRA-596. A prova do dispatcher roda este módulo (`tests.*`).

Os casos moram em `lanes/test_lanes.py`. Aqui só entram no unittest os desta
entrega, sem puxar o resto da suíte das lanes.
"""
import importlib.util
import sys
import unittest
from pathlib import Path

_caminho = Path(__file__).resolve().parents[1] / "lanes" / "test_lanes.py"
_spec = importlib.util.spec_from_file_location("test_lanes_fra596", _caminho)
_mod = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _mod
_spec.loader.exec_module(_mod)

CaminhoNonAsciiProtegido = _mod.CaminhoNonAsciiProtegido
SuitesEstritas = _mod.SuitesEstritas


if __name__ == "__main__":
    unittest.main()
