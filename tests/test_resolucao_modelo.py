"""Contrato do modelo e do esforço de cada lane (PRD de 29/10/2026).

O mesmo arquivo `tests/fixtures/resolucao_modelo.json` é lido pelo teste do Swift
(`ModeloLaneContratoTests`): Python e Swift têm de dar o mesmo modelo, esforço e aviso."""
import json
import unittest
from pathlib import Path

from gasto_lanes import catalogo as c

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "resolucao_modelo.json"


class ContratoResolucao(unittest.TestCase):
    def setUp(self):
        self.f = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def _conferir(self, grupo, cache):
        for k in self.f[grupo]:
            with self.subTest(k["nome"]):
                r = c.resolver_modelo(k["lane"], k["peso"], k["config"], cache)
                self.assertEqual({x: r[x] for x in ("modelo", "esforco", "aviso")}, k["esperado"])

    def test_casos_com_cache(self):
        self._conferir("casos", self.f["cache"])

    def test_casos_sem_cache(self):
        self._conferir("sem_cache", {})

    def test_flag_invalida_nunca_vai_ao_cli(self):
        cache = self.f["cache"]
        r = c.resolver_modelo("codex", "medio", {"modo": "fixo", "fixo": "gpt-mini", "esforco": "high"}, cache)
        self.assertFalse(any("reasoning_effort" in t for t in r["flags"]))
        r = c.resolver_modelo("opencode", "medio", {"modo": "auto", "porPeso": {"medio": {"esforco": "high"}}}, cache)
        self.assertNotIn("--effort", r["flags"])
        r = c.resolver_modelo("claude", "alto", {"modo": "auto", "porPeso": {"alto": {"esforco": "high"}}}, cache)
        self.assertEqual(r["flags"], ["--model", "opus", "--effort", "high"])


class EsforcosDaFerramenta(unittest.TestCase):
    def test_help_do_claude(self):
        texto = ("  --effort <level>                      Effort level for the current session\n"
                 "                                        (low, medium, high, xhigh, max)\n"
                 "  --environment <environment_id>        Create a new cloud session\n")
        self.assertEqual(c.esforcos_do_help(texto), ["low", "medium", "high", "xhigh", "max"])
        self.assertEqual(c.esforcos_do_help("sem a flag"), [])

    def test_models_cache_do_codex(self):
        dados = {"models": [
            {"slug": "gpt-5.6-luna", "visibility": "list",
             "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}, {"effort": "max"}]},
            {"slug": "oculto", "visibility": "hidden", "supported_reasoning_levels": [{"effort": "low"}]},
            {"slug": "sem-nivel", "visibility": "list"}]}
        self.assertEqual(c.esforcos_cache_codex(dados), {"gpt-5.6-luna": ["low", "high", "max"]})
        self.assertEqual(c.esforcos_cache_codex({"x": 1}), {})

    def test_reserva_e_lane_sem_esforco(self):
        self.assertEqual(c.esforcos_aceitos("claude", "opus", {}), list(c.catalogo()["claude"]["revisao"]["esforcos"]))
        self.assertEqual(c.esforcos_aceitos("opencode", "opencode/x", {}), [])
        self.assertFalse(c.lane_tem_esforco("opencode"))
        self.assertTrue(c.lane_tem_esforco("codex"))

    def test_cache_de_listas_guarda_os_esforcos(self):
        cache = c.atualizar_cache_esforcos({}, "claude", {"*": ["low", "max"]})
        cache = c.atualizar_cache_lista(cache, "claude", ["opus"], "2026-10-29T12:00:00")
        self.assertEqual(cache["esforcos"]["claude"], {"*": ["low", "max"]})
        self.assertEqual(c.atualizar_cache_esforcos(cache, "claude", {})["esforcos"]["claude"], {"*": ["low", "max"]},
                         "busca vazia não apaga o que havia")


class EsforcoDoFixoNoArquivo(unittest.TestCase):
    def test_vai_e_volta(self):
        cfg = c.normalizar_config_modelo({"modo": "fixo", "fixo": "opus", "esforco": "medium"})
        self.assertEqual(cfg["esforco"], "medium")
        self.assertEqual(c.config_para_gravar(cfg), {"modo": "fixo", "fixo": "opus", "porPeso": {}, "esforco": "medium"})
        self.assertNotIn("esforco", c.config_para_gravar(c.normalizar_config_modelo({"modo": "fixo", "fixo": "opus"})))
        self.assertEqual(c.normalizar_config_modelo("opus")["esforco"], "")


if __name__ == "__main__":
    unittest.main()
