"""FRA-565: ids do Linear vêm da config, do cache ou da API pelo nome; nunca do código."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import linear_ids as L


def leitor(cfg: dict):
    def get(chave, padrao=None):
        d = cfg
        for parte in chave.split("."):
            if not isinstance(d, dict) or parte not in d:
                return padrao
            d = d[parte]
        return d
    return get


ESTADOS = [{"id": "s-todo", "name": "Todo"}, {"id": "s-and", "name": "In Progress"},
           {"id": "s-rev", "name": "In Review"}, {"id": "s-done", "name": "Done"}]
LABELS = [
    {"id": "l-dono", "name": "needs:dono", "parent": None, "team": {"id": "t1"}},
    {"id": "l-dono-outro", "name": "needs:dono", "parent": None, "team": {"id": "t2"}},
    {"id": "l-falhou", "name": "lane:falhou", "parent": None, "team": None},
    {"id": "l-parada", "name": "lane:parada", "parent": None, "team": None},
    {"id": "l-alto", "name": "alto", "parent": {"name": "esforco"}, "team": None},
    {"id": "l-medio", "name": "medio", "parent": {"name": "esforco"}, "team": None},
    {"id": "l-baixo", "name": "baixo", "parent": {"name": "esforco"}, "team": None},
    {"id": "l-claude", "name": "claude", "parent": {"name": "lane"}, "team": None},
    {"id": "l-solto", "name": "claude", "parent": None, "team": None},
]


class Falso:
    def __init__(self, paginas=1):
        self.chamadas = []
        self.paginas = paginas

    def __call__(self, query, variaveis):
        self.chamadas.append((query, variaveis))
        if "project(" in query:
            return {"project": {"teams": {"nodes": [{"id": "t1"}]}}}
        if "team(" in query:
            return {"team": {"states": {"nodes": ESTADOS}}}
        if self.paginas == 2 and variaveis.get("after") is None:
            return {"issueLabels": {"nodes": LABELS[:3], "pageInfo": {"hasNextPage": True, "endCursor": "c1"}}}
        nos = LABELS[3:] if self.paginas == 2 else LABELS
        return {"issueLabels": {"nodes": nos, "pageInfo": {"hasNextPage": False}}}


class IdsDoLinear(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.cache = self.tmp / "linear-ids.json"

    def test_sem_nada_fica_vazio_e_nao_vai_a_rede(self):
        ids = L.carregar(leitor({}), self.cache)
        self.assertEqual(ids, L.vazio())
        self.assertIn("estado:todo", L.faltando(ids, "needs:dono", ["claude"]))

    def test_resolve_pelo_nome_prefere_o_time_e_respeita_o_grupo(self):
        ids = L.resolver(Falso(), project_id="p1", dono="needs:dono", lanes=["claude", "grok"])
        self.assertEqual(ids["estados"], {"todo": "s-todo", "in_progress": "s-and", "in_review": "s-rev"})
        self.assertEqual(ids["labels"], {"needs:dono": "l-dono", "lane:falhou": "l-falhou", "lane:parada": "l-parada"})
        self.assertEqual(ids["esforco"], {"alto": "l-alto", "medio": "l-medio", "baixo": "l-baixo"})
        self.assertEqual(ids["lanes"], {"claude": "l-claude"}, "a etiqueta solta 'claude' não é a do grupo lane")

    def test_paginas_de_etiquetas(self):
        ids = L.resolver(Falso(paginas=2), team_id="t1", dono="needs:dono", lanes=["claude"])
        self.assertEqual(ids["lanes"], {"claude": "l-claude"})
        self.assertEqual(ids["labels"]["needs:dono"], "l-dono")

    def test_garantir_grava_cache_e_depois_nao_consulta(self):
        f = Falso()
        cfg = leitor({})
        ids = L.garantir(cfg, f, dono="needs:dono", lanes=["claude"], project_id="p1", caminho=self.cache)
        self.assertEqual(ids["estados"]["todo"], "s-todo")
        self.assertTrue(self.cache.exists())
        f2 = Falso()
        de_novo = L.garantir(cfg, f2, dono="needs:dono", lanes=["claude"], project_id="p1", caminho=self.cache)
        self.assertEqual(de_novo, ids)
        self.assertEqual(f2.chamadas, [], "tudo no cache: não vai à rede")

    def test_cache_e_por_projeto(self):
        self.assertEqual(L.caminho_cache(""), L.CACHE)
        a, b = L.caminho_cache("p-1"), L.caminho_cache("p-2")
        self.assertNotEqual(a, b)
        self.assertEqual(a.parent, L.CACHE_DIR)
        self.assertEqual(L.caminho_cache("../x/y").name, "xy.json", "o id não sai da pasta do cache")

    def test_config_vence_o_cache(self):
        L.gravar_cache({**L.vazio(), "estados": {"todo": "do-cache", "in_progress": "", "in_review": ""}}, self.cache)
        cfg = leitor({"linear": {"state_todo_id": "da-config", "labels": {"lanes": {"claude": "cfg-claude"}}}})
        ids = L.carregar(cfg, self.cache)
        self.assertEqual(ids["estados"]["todo"], "da-config")
        self.assertEqual(ids["lanes"], {"claude": "cfg-claude"})

    def test_erro_de_rede_nao_derruba_e_avisa(self):
        avisos = []

        def quebra(_q, _v):
            raise OSError("sem rede")

        ids = L.garantir(leitor({}), quebra, dono="needs:dono", caminho=self.cache, log=avisos.append)
        self.assertEqual(ids, L.vazio())
        self.assertTrue(any("sem rede" in a for a in avisos))
        self.assertFalse(self.cache.exists())

    def test_cache_estragado_conta_como_vazio(self):
        self.cache.write_text("{quebrado", encoding="utf-8")
        self.assertEqual(L.ler_cache(self.cache), L.vazio())
        self.cache.write_text(json.dumps(["lista"]), encoding="utf-8")
        self.assertEqual(L.ler_cache(self.cache), L.vazio())


if __name__ == "__main__":
    unittest.main()
