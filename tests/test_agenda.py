"""Agenda dos projetos (FRA-705): rodízio justo, prioridade e lane em andamento."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gasto_lanes import agenda


class Projeto:
    def __init__(self, id, ativo=True, prioridade=0):
        self.id = id
        self.ativo = ativo
        self.prioridade = prioridade


class Rodizio(unittest.TestCase):
    def test_ordem_por_prioridade_e_lista(self):
        ps = [Projeto("a"), Projeto("b", prioridade=2), Projeto("c", prioridade=2)]
        self.assertEqual([p.id for p in agenda.ordenar(ps)], ["b", "c", "a"])

    def test_rodizio_sem_ultimo_comeca_no_primeiro(self):
        ps = [Projeto("a"), Projeto("b")]
        self.assertEqual(agenda.escolher(ps).id, "a")

    def test_rodizio_alterna(self):
        ps = [Projeto("a"), Projeto("b")]
        self.assertEqual(agenda.escolher(ps, "a").id, "b")
        self.assertEqual(agenda.escolher(ps, "b").id, "a")

    def test_prioridade_nao_da_exclusividade(self):
        ps = [Projeto("a", prioridade=9), Projeto("b")]
        self.assertEqual(agenda.escolher(ps).id, "a")
        self.assertEqual(agenda.escolher(ps, "a").id, "b")
        self.assertEqual(agenda.escolher(ps, "b").id, "a")

    def test_inativo_e_pulado(self):
        ps = [Projeto("a", ativo=False), Projeto("b")]
        self.assertEqual(agenda.escolher(ps).id, "b")

    def test_lane_em_andamento_manda(self):
        ps = [Projeto("a"), Projeto("b")]
        self.assertEqual(agenda.escolher(ps, "a", {"b"}).id, "b")

    def test_projeto_ocupado_fora_do_cadastro_nao_e_inventado(self):
        ps = [Projeto("a")]
        self.assertIsNone(agenda.escolher(ps, "a", {"sumiu"}))

    def test_id_desconhecido_nao_escolhe(self):
        ps = [Projeto("a")]
        self.assertIsNone(agenda.escolher(ps, "a", {"nao-existe"}))

    def test_sem_projeto_ativo(self):
        self.assertIsNone(agenda.escolher([Projeto("a", ativo=False)]))


class Slots(unittest.TestCase):
    def test_distribui_em_rodizio(self):
        ps = [Projeto("a", prioridade=2), Projeto("b"), Projeto("c")]
        self.assertEqual(agenda.distribuir(ps, 4), ["a", "b", "c", "a"])

    def test_respeita_max_lanes_por_projeto(self):
        a = Projeto("a", prioridade=2)
        a.max_lanes = 1
        b = Projeto("b")
        ps = [a, b]
        self.assertEqual(agenda.distribuir(ps, 5), ["a", "b", "b", "b", "b"])

    def test_max_global_e_zero(self):
        ps = [Projeto("a"), Projeto("b")]
        self.assertEqual(agenda.distribuir(ps, 10, max_global=3), ["a", "b", "a"])
        self.assertEqual(agenda.distribuir(ps, 0), [])

    def test_inativo_nao_recebe(self):
        ps = [Projeto("a", ativo=False), Projeto("b")]
        self.assertEqual(agenda.distribuir(ps, 2), ["b", "b"])


class Habilitado(unittest.TestCase):
    def test_bool_e_texto(self):
        self.assertTrue(agenda.habilitado(True))
        self.assertFalse(agenda.habilitado(False))
        for v in ("1", "true", "sim", "on", "ligado", " TRUE "):
            self.assertTrue(agenda.habilitado(v), v)
        for v in ("0", "false", "", None, "nao", 0):
            self.assertFalse(agenda.habilitado(v), v)


class Ultimo(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_roundtrip(self):
        caminho = self.tmp / "agenda.json"
        agenda.gravar_ultimo(caminho, "abc")
        self.assertEqual(agenda.ler_ultimo(caminho), "abc")
        self.assertEqual(json.loads(caminho.read_text())["ultimo"], "abc")

    def test_ausente_ou_ilegivel(self):
        self.assertEqual(agenda.ler_ultimo(self.tmp / "nao.json"), "")
        ruim = self.tmp / "ruim.json"
        ruim.write_text("{nao e json", encoding="utf-8")
        self.assertEqual(agenda.ler_ultimo(ruim), "")


class SelecaoNoDispatcher(unittest.TestCase):
    """A agenda ligada/desligada no ponto em que o dispatcher escolhe o projeto."""

    @classmethod
    def setUpClass(cls):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
        import dispatcher as d
        cls.d = d

    def setUp(self):
        self.a = self.d.projetos.Projeto(id="a", nome="A", repo="~/a")
        self.b = self.d.projetos.Projeto(id="b", nome="B", repo="~/b")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.patches = [
            mock.patch.object(self.d, "STATE_DIR", self.tmp),
            mock.patch.object(self.d.projetos, "projetos", return_value=[self.a, self.b]),
            mock.patch.object(self.d.projetos, "padrao", return_value=self.a),
            mock.patch.object(self.d, "load_state", return_value=None),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_desligada_usa_o_padrao(self):
        with mock.patch.object(self.d.agenda, "habilitado", return_value=False):
            self.assertIs(self.d.selecionar_projeto(), self.a)

    def test_ligada_alterna_sem_lane(self):
        with mock.patch.object(self.d.agenda, "habilitado", return_value=True), \
             mock.patch.object(self.d.agenda, "ler_ultimo", return_value="a"), \
             mock.patch.object(self.d.agenda, "gravar_ultimo") as gravou:
            self.assertIs(self.d.selecionar_projeto(), self.b)
            gravou.assert_called_once()

    def test_lane_em_andamento_manda(self):
        with mock.patch.object(self.d.agenda, "habilitado", return_value=True), \
             mock.patch.object(self.d, "load_state", return_value={"projeto": "a"}), \
             mock.patch.object(self.d.agenda, "ler_ultimo", return_value="b"), \
             mock.patch.object(self.d.agenda, "gravar_ultimo"):
            self.assertIs(self.d.selecionar_projeto(), self.a)

    def test_ciclo_roteia_para_simultaneo(self):
        with mock.patch.object(self.d.agenda, "habilitado", return_value=True), \
             mock.patch.object(self.d, "_ciclo_simultaneo", return_value=7) as chamou:
            self.assertEqual(self.d._ciclo(False, False), 7)
            chamou.assert_called_once_with(False, False)

    def test_estado_sem_projeto_nao_troca(self):
        with mock.patch.object(self.d.agenda, "habilitado", return_value=True), \
             mock.patch.object(self.d, "load_state", return_value={"lane": "claude"}):
            self.assertIs(self.d.selecionar_projeto(), self.a)


if __name__ == "__main__":
    unittest.main()
