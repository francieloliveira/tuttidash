import datetime as dt
import unittest

from gasto_lanes import ledger as L
from gasto_lanes import report as R
from gasto_lanes.estado import read_state
from tests.helpers import Sandbox


class Relatorio(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sb = Sandbox()
        s = L.collect(cls.sb.logs, cls.sb.ledger, read_state(cls.sb.estado)["logs_em_andamento"])
        cls.recs = list(s["registros"].values())

    @classmethod
    def tearDownClass(cls):
        cls.sb.cleanup()

    def test_totais_separam_desconhecido(self):
        t = R.totais(self.recs)
        self.assertEqual(t["execucoes"], 7)
        self.assertEqual((t["ok"], t["erro"], t["morta"], t["em_andamento"], t["cancelada"]), (3, 1, 1, 1, 1))
        self.assertAlmostEqual(t["custo_conhecido_usd"], 2.3141 + 0.48 + 3.02, places=4)
        self.assertAlmostEqual(t["custo_estimado_usd"], 2.3141 + 3.02, places=4)
        self.assertAlmostEqual(t["custo_informado_usd"], 0.48, places=4)
        self.assertEqual(t["execucoes_custo_desconhecido"], 4)

    def test_por_semana(self):
        rows = {r["grupo"]: r for r in R.agrupar(self.recs, "semana")}
        self.assertEqual(sorted(rows), ["2026-W39", "2026-W40", "2026-W41"])
        self.assertAlmostEqual(rows["2026-W40"]["custo_conhecido_usd"], 2.7941, places=4)
        self.assertEqual(rows["2026-W40"]["execucoes_custo_desconhecido"], 1)
        self.assertEqual(rows["2026-W41"]["custo_conhecido_usd"], 0)
        self.assertEqual(rows["2026-W41"]["execucoes_custo_desconhecido"], 3)

    def test_por_dia_card_lane(self):
        dias = [r["grupo"] for r in R.agrupar(self.recs, "dia")]
        self.assertEqual(dias, ["2026-09-27", "2026-10-03", "2026-10-04", "2026-10-05"])
        cards = R.agrupar(self.recs, "card")
        self.assertEqual(cards[0]["grupo"], "FRA-248")      # maior gasto primeiro
        lanes = {r["grupo"]: r for r in R.agrupar(self.recs, "lane")}
        self.assertEqual(lanes["claude"]["execucoes"], 4)
        self.assertEqual(lanes["grok"]["execucoes"], 3)
        self.assertEqual(lanes["grok"]["execucoes_custo_desconhecido"], 2)

    def test_duracao_real_e_estimada_separadas(self):
        lanes = {r["grupo"]: r for r in R.agrupar(self.recs, "lane")}
        self.assertEqual(lanes["claude"]["duracao_ms"], 1_500_000 + 2_400_000)
        self.assertEqual(lanes["claude"]["duracao_estimada_ms"], (90 + 15) * 60_000)

    def test_filtros(self):
        f = R.filtrar(self.recs, desde=dt.date(2026, 10, 4), lanes={"grok"})
        self.assertEqual([r["card"] for r in f], ["FRA-259", "FRA-260", "FRA-252"])
        self.assertEqual(len(R.filtrar(self.recs, cards={"FRA-250"})), 1)

    def test_teto(self):
        hoje = dt.date(2026, 10, 4)  # semana 40: conhecido US$ 2,7941
        self.assertIsNone(R.avaliar_teto(self.recs, None, 80, hoje))
        ok = R.avaliar_teto(self.recs, 10, 80, hoje)
        self.assertEqual((ok["status"], ok["exit_code"]), ("ok", 0))
        perto = R.avaliar_teto(self.recs, 3, 80, hoje)
        self.assertEqual((perto["status"], perto["exit_code"]), ("perto", 3))
        est = R.avaliar_teto(self.recs, 2.5, 80, hoje)
        self.assertEqual((est["status"], est["exit_code"]), ("estourado", 4))
        self.assertEqual(est["execucoes_custo_desconhecido"], 1)
        self.assertIn("pode ser maior", R.teto_txt(est))
        self.assertIn("nada foi pausado", R.teto_txt(est))

    def test_texto_marca_desconhecido(self):
        txt = R.render_text(self.recs, ["semana"], None)
        self.assertIn("desconhecido (3)", txt)          # W41 sem nenhum custo conhecido
        self.assertIn("US$ 2,79 + 1 desconh.", txt)     # W40

    def test_formatos(self):
        self.assertEqual(R.usd(1234.5), "US$ 1.234,50")
        self.assertEqual(R.dur(5_400_000), "1 h 30")
        self.assertEqual(R.tok(1_275_120), "1,3M")


if __name__ == "__main__":
    unittest.main()
