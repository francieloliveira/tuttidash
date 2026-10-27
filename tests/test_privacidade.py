"""Privacidade por modelo do OpenCode (gasto_lanes/privacidade.py): leitura, busca e decisão."""
import datetime as dt
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
import privacidade as P  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "privacidade"
ZEN = (FIX / "zen.mdx").read_text(encoding="utf-8")
GO = (FIX / "go.mdx").read_text(encoding="utf-8")


def estado(conferido="2026-10-21T08:00:00"):
    return {"docs": {"zen": {"ok": True, "conferido_em": conferido, "modelos": P.ler_zen(ZEN)},
                     "go": {"ok": True, "conferido_em": conferido, "modelos": P.ler_go(GO)}}}


class Leitura(unittest.TestCase):
    def test_zen_por_modelo(self):
        m = P.ler_zen(ZEN)
        self.assertEqual(m["deepseek-v4.1-flash-free"]["treina"], False)
        self.assertEqual(m["deepseek-v4.1-flash-free"]["retencao_dias"], 0)
        self.assertTrue(m["nemotron-3.5-super-vl-free"]["treina"], "NVIDIA registra o uso")
        self.assertTrue(m["big-pickle"]["treina"])
        self.assertEqual(m["beam-free"]["retencao_dias"], 30)
        self.assertFalse(m["beam-free"]["treina"])

    def test_go_tabela_e_validade(self):
        m = P.ler_go(GO)
        self.assertEqual(m["deepseek-v4.1-flash"]["valido_ate"], "2026-10-31")
        self.assertTrue(m["muse-spark-1.3-contributor"]["treina"])
        self.assertEqual(m["grok-4.7"]["retencao_dias"], 30)
        self.assertIsNone(m["muse-spark-1.3-contributor"]["retencao_dias"])

    def test_texto_sem_ancoras_nao_vale(self):
        self.assertEqual(P.valido("zen", "## Privacy\nnada", P.FONTES_PADRAO["zen"]), {})
        self.assertEqual(P.valido("go", ZEN, P.FONTES_PADRAO["go"]), {})


def cfg_estrita(extra=None):
    """Regra de 21/10 ligada (`privacidade.exigir_sem_treino`), mais chaves extras do teste."""
    extra = dict(extra or {})
    extra.setdefault("privacidade.exigir_sem_treino", True)
    return lambda k, p: extra.get(k, p)


class Decisao(unittest.TestCase):
    """Regra antiga (21/10), agora só com `privacidade.exigir_sem_treino` ligado."""

    def setUp(self):
        self.antigo = P._cfg
        P._cfg = cfg_estrita()
        self.addCleanup(setattr, P, "_cfg", self.antigo)
        self.hoje = dt.date(2026, 10, 21)

    def pode(self, modelo, est=None, hoje=None):
        return P.pode_receber_codigo(modelo, estado() if est is None else est, hoje or self.hoje)[0]

    def test_regras(self):
        self.assertTrue(self.pode("opencode/deepseek-v4.1-flash-free"))
        self.assertFalse(self.pode("opencode/nemotron-3.5-super-vl-free"))
        self.assertTrue(self.pode("opencode-go/deepseek-v4.1-flash"))
        self.assertFalse(self.pode("opencode-go/muse-spark-1.3-contributor"))
        self.assertFalse(self.pode("opencode/modelo-que-nao-existe"))
        self.assertFalse(self.pode("outro/qualquer"))

    def test_acordo_vencido(self):
        self.assertFalse(self.pode("opencode-go/deepseek-v4.1-flash", hoje=dt.date(2026, 11, 1)))

    def test_conferencia_velha_ou_ausente_bloqueia(self):
        self.assertFalse(self.pode("opencode/deepseek-v4.1-flash-free", estado("2026-10-01T08:00:00")))
        self.assertFalse(self.pode("opencode/deepseek-v4.1-flash-free", {}))

    def test_limite_de_retencao(self):
        P._cfg = cfg_estrita({"privacidade.max_retencao_dias": 0})
        self.assertFalse(self.pode("opencode-go/grok-4.7"))
        self.assertTrue(self.pode("opencode-go/deepseek-v4.1-flash"))

    def test_excecao_manual(self):
        P._cfg = cfg_estrita({"privacidade.excecoes": {"opencode/nemotron-3.5-super-vl-free": "permitir"}})
        self.assertTrue(self.pode("opencode/nemotron-3.5-super-vl-free"))


class RegraNova(unittest.TestCase):
    """Decisão de 23/10/2026 20h20: modelo que registra ou treina com o uso também recebe código,
    nas lanes e na revisão. Sem exceção só para o revisor: é a mesma função para os dois."""

    def setUp(self):
        self.antigo = P._cfg
        P._cfg = lambda k, p: p
        self.addCleanup(setattr, P, "_cfg", self.antigo)

    def pode(self, modelo, est=None):
        return P.pode_receber_codigo(modelo, estado() if est is None else est, dt.date(2026, 10, 23))

    def test_padrao_e_a_regra_nova(self):
        self.assertFalse(P.exige_sem_treino())

    def test_modelo_que_treina_passa(self):
        ok, motivo = self.pode("opencode/nemotron-3.5-super-vl-free")
        self.assertTrue(ok)
        self.assertIn("treinar", motivo)
        self.assertTrue(self.pode("opencode-go/muse-spark-1.3-contributor")[0])

    def test_sem_conferencia_ou_fora_da_doc_tambem_passa(self):
        self.assertTrue(self.pode("opencode/deepseek-v4.1-flash-free", {})[0])
        self.assertTrue(self.pode("opencode/deepseek-v4.1-flash-free", estado("2026-10-01T08:00:00"))[0])
        self.assertTrue(self.pode("opencode/nemotron-3-ultra-free")[0])

    def test_continua_bloqueando_prefixo_estranho_e_excecao_manual(self):
        self.assertFalse(self.pode("outro/qualquer")[0])
        P._cfg = lambda k, p: {"opencode/nemotron-3.5-super-vl-free": "bloquear"} if k == "privacidade.excecoes" else p
        self.assertFalse(self.pode("opencode/nemotron-3.5-super-vl-free")[0])


class Localizacao(unittest.TestCase):
    """A documentação muda de lugar: acha pelo conteúdo e avisa."""

    def setUp(self):
        self.orig = (P._baixar, P._buscar_caminhos, P._cfg)
        self.addCleanup(lambda: (setattr(P, "_baixar", self.orig[0]), setattr(P, "_buscar_caminhos", self.orig[1]),
                                 setattr(P, "_cfg", self.orig[2])))
        P._cfg = lambda k, p: p
        self.arquivos = {"docs/novo/lugar/models.mdx": ZEN, "docs/da/models.mdx": ZEN, "outro/go-v3.mdx": GO}
        P._baixar = lambda repo, ref, c: (self.arquivos[c], "sha-" + c) if c in self.arquivos else None
        P._buscar_caminhos = lambda repo, q: P.ordenar_caminhos(list(self.arquivos))

    def test_caminho_conhecido_sumiu_e_a_busca_acha(self):
        r = P.localizar("zen", P.FONTES_PADRAO["zen"], {"caminho": "services/antigo/models.mdx"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["caminho"], "docs/novo/lugar/models.mdx", "prefere o arquivo sem pasta de idioma")
        self.assertEqual(r["mudou_de"], "services/antigo/models.mdx")

    def test_nada_achado_mantem_o_anterior_e_avisa(self):
        self.arquivos = {}
        with tempfile.TemporaryDirectory() as d:
            arq = Path(d) / "priv.json"
            arq.write_text('{"docs": {"go": {"ok": true, "caminho": "x", "conferido_em": "2026-10-20T08:00:00", '
                           '"modelos": {"deepseek-v4.1-flash": {"treina": false, "retencao_dias": 0}}}}}')
            est, avisos = P.atualizar(arq, dt.datetime(2026, 10, 21, 9))
            self.assertFalse(est["docs"]["go"]["ok"])
            self.assertEqual(est["docs"]["go"]["conferido_em"], "2026-10-20T08:00:00", "não apaga o que sabia")
            self.assertTrue(any("nenhuma fonte" in a for a in avisos))

    def test_atualizar_avisa_mudanca_de_lugar_e_de_regra(self):
        with tempfile.TemporaryDirectory() as d:
            arq = Path(d) / "priv.json"
            arq.write_text('{"docs": {"go": {"ok": true, "caminho": "antigo/go.mdx", "conferido_em": "2026-10-20T08:00:00", '
                           '"modelos": {"grok-4.7": {"treina": true, "retencao_dias": 30}}}}}')
            est, avisos = P.atualizar(arq, dt.datetime(2026, 10, 21, 9))
            self.assertEqual(est["docs"]["go"]["caminho"], "outro/go-v3.mdx")
            self.assertTrue(any("mudou de lugar" in a for a in avisos))
            self.assertTrue(any("regra mudou" in a and "grok-4.7" in a for a in avisos))


if __name__ == "__main__":
    unittest.main()
