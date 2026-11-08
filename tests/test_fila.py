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

    def test_saude_de_lane_e_compartilhada(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as d:
            caminho = Path(d) / "saude-lanes.json"
            fila.marcar_falha_lane(caminho, "opencode", "modelo indisponível", 60, quando=100)
            saude = fila.ler_saude(caminho)
            self.assertFalse(fila.lane_saudavel(saude, "opencode", agora=130))
            self.assertTrue(fila.lane_saudavel(saude, "opencode", agora=161))
            self.assertEqual(saude["opencode"]["motivo"], "modelo indisponível")


    def test_dispatcher_respeita_assignee(self):
        import lanes.dispatcher as d
        c = card(lane="grok", assignee="u1")
        c.update({"title": "x", "inverseRelations": {"nodes": []}})
        medidas = {"grok": (11, "créditos")}
        self.assertEqual(d.escolher_do_todo([c], ["grok"], medidas, viewer="u2"), [])
        self.assertEqual(len(d.escolher_do_todo([c], ["grok"], medidas, viewer="u1")), 1)

    def test_conflito_de_arquivos(self):
        a = {"identifier": "FRA-1", "description": "mexe em `app/Foo.swift`"}
        b = {"identifier": "FRA-2", "description": "mexe em `app/Foo.swift` e `Bar.swift`"}
        self.assertEqual(fila.arquivos_card(a), {"Foo.swift"})
        self.assertEqual(fila.conflita(b, {"FRA-1": {"Foo.swift"}}), "FRA-1")
        self.assertIsNone(fila.conflita(b, {"FRA-1": {"Outro.swift"}}))

    def test_dispatcher_nao_pega_dois_cards_do_mesmo_arquivo(self):
        import lanes.dispatcher as d
        a = card(lane="grok")
        a.update({"identifier": "FRA-1", "description": "app/Foo.swift", "title": "x",
                  "inverseRelations": {"nodes": []}})
        b = card(lane="grok")
        b.update({"identifier": "FRA-2", "description": "app/Foo.swift", "title": "x",
                  "inverseRelations": {"nodes": []}})
        medidas = {"grok": (11, "créditos")}
        escolhidos = d.escolher_do_todo([a, b], ["grok"], medidas)
        self.assertEqual([c["identifier"] for c in escolhidos], ["FRA-1"])


if __name__ == "__main__":
    unittest.main()



class CotaSemPctTipada(unittest.TestCase):
    """Medida sem %: o motivo tipado (5ª coluna do lanepct) decide; o texto nunca."""

    PISOS = {"baixo": 0.5, "medio": 1.0, "alto": 2.0}

    def test_sem_limite_tem_folga_em_qualquer_esforco(self):
        for codigo in ("sem_janelas", "sem_limite_incluido", "cota_compartilhada"):
            for effort in ("baixo", "medio", "alto"):
                with self.subTest(codigo=codigo, effort=effort):
                    self.assertTrue(fila.cota_ok("x", effort, {"x": (None, "qualquer", codigo, None)}, self.PISOS))

    def test_falha_de_leitura_continua_fechada(self):
        for codigo in ("token_vencido", "token_recusado", "rede", "http", "limitado", "resposta_ilegivel",
                       "sem_credencial", "nao_oficial_desligado", "motivo", ""):
            with self.subTest(codigo=codigo):
                self.assertFalse(fila.cota_ok("x", "baixo", {"x": (None, "falhou", codigo, None)}, self.PISOS))

    def test_formato_antigo_sem_codigo_fecha(self):
        self.assertFalse(fila.cota_ok("x", "baixo", {"x": (None, "servidor não informou nenhuma janela de limite")}))
        self.assertFalse(fila.cota_ok("x", "baixo", {}))

    def test_saldo_respeita_o_piso_do_esforco(self):
        m = {"deepseek": (None, "saldo US$ 1.50", "saldo", 1.5)}
        self.assertTrue(fila.cota_ok("deepseek", "baixo", m, self.PISOS))
        self.assertTrue(fila.cota_ok("deepseek", "medio", m, self.PISOS))
        self.assertFalse(fila.cota_ok("deepseek", "alto", m, self.PISOS))
        self.assertFalse(fila.cota_ok("deepseek", "baixo", {"deepseek": (None, "s", "saldo", None)}, self.PISOS))
        self.assertFalse(fila.cota_ok("deepseek", "baixo", {"deepseek": (None, "s", "saldo", "abc")}, self.PISOS))

    def test_medida_numerica_nao_muda(self):
        self.assertTrue(fila.cota_ok("c", "alto", {"c": (10, "5 h", "", None)}, self.PISOS))
        self.assertFalse(fila.cota_ok("c", "alto", {"c": (70, "5 h")}, self.PISOS))

    def test_piso_vem_da_config(self):
        import unittest.mock as mock
        fila._pisos_cache.update(at=0.0, v=None)
        try:
            with mock.patch.object(fila, "_obter_config", return_value={"alto": 5, "baixo": "x", "medio": True}):
                pisos = fila.pisos_saldo()
            self.assertEqual(pisos, {"baixo": 0.5, "medio": 1.0, "alto": 5.0})
            fila._pisos_cache.update(at=0.0, v=None)
            with mock.patch.object(fila, "_obter_config", side_effect=OSError("ilegível")):
                self.assertEqual(fila.pisos_saldo(), fila.PISO_SALDO_USD)
        finally:
            fila._pisos_cache.update(at=0.0, v=None)
