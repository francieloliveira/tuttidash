"""Integração da fundação multi-projeto (FRA-702..705/710).

Sem rede, sem Linear e sem GitHub: usa os módulos reais de cadastro, agenda,
estado, parser, ledger e relatório com dois projetos temporários.
"""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import agenda, ledger, parser, projetos, report
from gasto_lanes.estado import read_state


def _log(caminho: Path, projeto: str, nome: str, card: str, lane: str, custo: float) -> None:
    caminho.write_text(
        json.dumps({"type": "tutti_projeto", "projeto": projeto, "nome": nome}) + "\n"
        + json.dumps({"type": "result", "subtype": "success", "is_error": False,
                      "num_turns": 1, "duration_ms": 1000,
                      "total_cost_usd": custo}) + "\n",
        encoding="utf-8")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="multi-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.logs = self.tmp / "logs"
        self.logs.mkdir()
        self.estado = self.tmp / "estado"
        self.estado.mkdir()


class CadastroEAgenda(Base):
    def test_dois_projetos_com_prioridade_e_limites(self):
        a = projetos.Projeto(id="a", nome="A", repo=str(self.tmp / "a"), prioridade=2,
                            operacao={"budget_usd": {"medio": 5}, "lane_timeout_min": 30,
                                      "max_lanes": 2, "max_tarefas_por_lane": 1})
        b = projetos.Projeto(id="b", nome="B", repo=str(self.tmp / "b"))
        self.assertEqual([p.id for p in agenda.ordenar([b, a])], ["a", "b"])
        self.assertEqual(agenda.escolher([b, a], "a").id, "b")
        self.assertEqual(agenda.escolher([b, a], "b").id, "a")
        self.assertEqual(a.budget_usd, {"medio": 5})
        self.assertEqual((a.lane_timeout_min, a.max_lanes, a.max_tarefas_por_lane), (30, 2, 1))
        self.assertEqual((b.lane_timeout_min, b.max_lanes), (0, 0))

    def test_lane_em_andamento_vence_o_rodizio(self):
        a = projetos.Projeto(id="a", nome="A", repo=str(self.tmp / "a"))
        b = projetos.Projeto(id="b", nome="B", repo=str(self.tmp / "b"))
        self.assertEqual(agenda.escolher([a, b], "a", {"b"}).id, "b")


class LogsELedger(Base):
    def test_custo_e_log_por_projeto(self):
        _log(self.logs / "FRA-1-claude-20261122-100000.jsonl", "p1", "Projeto 1", "FRA-1", "claude", 1.5)
        _log(self.logs / "FRA-2-claude-20261122-100100.jsonl", "p2", "Projeto 2", "FRA-2", "claude", 2.5)
        (self.logs / "FRA-3-grok-20261122-100200.jsonl").write_text(
            json.dumps({"type": "tutti_projeto", "projeto": "p1", "nome": "Projeto 1"}) + "\n"
            + json.dumps({"type": "result", "subtype": "success", "is_error": False,
                          "num_turns": 1, "total_cost_usd": 0.5}) + "\n", encoding="utf-8")

        s = ledger.collect(self.logs, self.tmp / "ledger.jsonl", set())
        self.assertEqual(s["novas"], 3)
        recs = list(s["registros"].values())
        self.assertEqual({r.get("projeto") for r in recs}, {"p1", "p2"})

        p1 = report.filtrar(recs, projetos={"p1"})
        self.assertEqual({r["card"] for r in p1}, {"FRA-1", "FRA-3"})
        self.assertAlmostEqual(report.totais(p1)["custo_conhecido_usd"], 2.0)

        grupos = {r["grupo"]: r for r in report.agrupar(recs, "projeto")}
        self.assertEqual(set(grupos), {"Projeto 1", "Projeto 2"})
        self.assertAlmostEqual(grupos["Projeto 1"]["custo_conhecido_usd"], 2.0)
        self.assertAlmostEqual(grupos["Projeto 2"]["custo_conhecido_usd"], 2.5)

    def test_log_antigo_fica_sem_projeto(self):
        # Sem cabeçalho: não inventa projeto nem descarta a execução.
        (self.logs / "FRA-9-grok-20261122-120000.jsonl").write_text(
            json.dumps({"type": "result", "subtype": "success", "is_error": False,
                        "num_turns": 1, "total_cost_usd": 0.3}) + "\n", encoding="utf-8")
        s = ledger.collect(self.logs, self.tmp / "ledger.jsonl", set())
        r = next(iter(s["registros"].values()))
        self.assertNotIn("projeto", r)
        grupos = report.agrupar(list(s["registros"].values()), "projeto")
        self.assertEqual(grupos[0]["grupo"], "sem projeto")


class EstadoDaLane(Base):
    def test_estado_de_dois_projetos_carrega_o_dono(self):
        for lane, projeto, nome in (("claude", "p1", "Projeto 1"), ("grok", "p2", "Projeto 2")):
            (self.estado / f"lane-{lane}.json").write_text(json.dumps({
                "lane": lane, "card": "FRA-1", "log": f"/x/FRA-1-{lane}.jsonl",
                "projeto": projeto, "projeto_nome": nome,
            }), encoding="utf-8")
        st = read_state(self.estado)
        self.assertEqual(st["lanes"]["claude"]["projeto"], "p1")
        self.assertEqual(st["lanes"]["grok"]["projeto"], "p2")
        self.assertEqual(st["lanes"]["grok"]["projeto_nome"], "Projeto 2")


if __name__ == "__main__":
    unittest.main()
