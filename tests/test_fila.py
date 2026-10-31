"""Regras compartilhadas da fila (gasto_lanes/fila.py): vigia e dispatcher."""
import time
import unittest

from gasto_lanes import fila


def card(lane=None, effort="alto", risk=None, assignee=None):
    labels = []
    if lane:
        labels.append({"name": lane, "parent": {"name": "lane"}})
    if effort:
        labels.append({"name": effort, "parent": {"name": "esforco"}})
    if risk:
        labels.append({"name": risk, "parent": None})
    return {"identifier": "FRA-1", "labels": {"nodes": labels},
            "assignee": {"id": assignee} if assignee else None}


class FilaCompartilhadaTest(unittest.TestCase):
    def test_cota_por_esforco(self):
        self.assertTrue(fila.cota_ok("grok", "alto", {"grok": (11, "créditos")}))
        self.assertFalse(fila.cota_ok("grok", "alto", {"grok": (61, "créditos")}))
        self.assertTrue(fila.cota_ok("grok", "alto", {"grok": (80, "30 dias")}))
        self.assertFalse(fila.cota_ok("grok", "alto", {"grok": (86, "30 dias")}))

    def test_lane_pedida_e_vaga(self):
        manifesto = lambda lane: {}
        c = card(lane="codex")
        self.assertIsNone(fila.escolher_lane(c, {"grok"}, {"grok": (11, "créditos")},
                                             {"grok": 0}, 2, manifesto))
        self.assertIsNone(fila.escolher_lane(card(lane="grok"), {"grok"}, {"grok": (11, "créditos")},
                                             {"grok": 2}, 2, manifesto))

    def test_risco_alto_prefere_lane_forte(self):
        c = card(risk="risco:alto")
        medidas = {"opencode": (1, "créditos"), "grok": (50, "créditos")}
        manifesto = lambda lane: {}
        self.assertEqual(fila.escolher_lane(c, {"opencode", "grok"}, medidas,
                                            {"opencode": 0, "grok": 1}, 2, manifesto,
                                            risco_alto={"grok"}), "grok")

    def test_cooldown_e_assignee(self):
        agora = time.time()
        self.assertTrue(fila.card_em_cooldown({"identifier": "FRA-1"},
                                              {"stops": {"FRA-1": {"ultimo": agora}}}, 60))
        self.assertTrue(fila.lane_em_cooldown({"lane_falhas": {"opencode": agora}}, "opencode", 60))
        self.assertTrue(fila.atribuido_a_outro({"assignee": {"id": "u1"}}, "u2"))
        self.assertFalse(fila.atribuido_a_outro({"assignee": {"id": "u1"}}, "u1"))


if __name__ == "__main__":
    unittest.main()
