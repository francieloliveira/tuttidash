#!/usr/bin/env python3
"""Atalho: python3 gasto.py <comando> (funciona de qualquer pasta)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gasto_lanes.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
