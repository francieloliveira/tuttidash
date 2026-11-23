"""Painel namespaced da janela de lanes (FRA-706)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
import lanes_window as w  # noqa: E402


class Panes(unittest.TestCase):
    def setUp(self):
        self.orig = w._tmux
        self.orig_lanes = w.LANES
        self.addCleanup(setattr, w, "_tmux", self.orig)
        self.addCleanup(setattr, w, "LANES", self.orig_lanes)
        w.LANES = ("claude", "grok")

    def test_separa_painel_normal_do_namespaced(self):
        saida = "%1 claude \n%2 claude p1-claude\n%3 grok p2-grok\n"
        w._tmux = lambda *a, **k: saida
        self.assertEqual(w._panes(), {"claude": "%1"})
        self.assertEqual(w._pane_da_sessao("p1-claude"), "%2")
        self.assertEqual(w._pane_da_sessao("p2-grok"), "%3")
        self.assertEqual(w._pane_da_sessao("lane-claude"), "")


if __name__ == "__main__":
    unittest.main()
