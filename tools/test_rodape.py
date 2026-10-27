#!/usr/bin/python3
"""Testes do rodapé dos painéis: python3 tools/test_rodape.py"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rodape as r  # noqa: E402


def fake_contar(root, only):
    return {"WatchBandStateTests": 3}.get(only)


class ProgressoTestes(unittest.TestCase):
    def prova(self):
        p = r.Progresso("FRA-360", contar=fake_contar)
        p.linha("[safe] root=/x/fra-360")
        p.linha("[safe] destination=platform=iOS only=WatchBandStateTests")
        return p

    def test_conta_e_total(self):
        p = self.prova()
        self.assertEqual((p.total, p.feitos), (3, 0))
        p.linha("Test Case '-[TranscentIATests.WatchBandStateTests testA]' passed (0.001 seconds).")
        p.linha("Test Case '-[TranscentIATests.WatchBandStateTests testB]' failed (0.002 seconds).")
        self.assertEqual((p.feitos, p.falhas, p.classe), (2, 1, "WatchBandStateTests"))
        texto = r.visivel(r.rodape_progresso(p, 42, 120))
        self.assertIn("2/3 testes · 1 falha", texto)
        self.assertIn("0:42", texto)

    def test_started_nao_conta(self):
        p = self.prova()
        p.linha("Test Case '-[TranscentIATests.WatchBandStateTests testA]' started.")
        self.assertEqual(p.feitos, 0)

    def test_nova_execucao_zera(self):
        p = self.prova()
        p.linha("Test Case '-[TranscentIATests.WatchBandStateTests testA]' passed (0.001 seconds).")
        p.linha("[safe] destination=platform=iOS only=Outra/testX")
        self.assertEqual((p.feitos, p.fim), (0, None))

    def test_fim_ok_enche_a_barra(self):
        p = self.prova()
        for t in "ABC":
            p.linha("Test Case '-[T.WatchBandStateTests test%s]' passed (0.001 seconds)." % t)
        p.linha("** TEST SUCCEEDED **")
        texto = r.visivel(r.rodape_progresso(p, 80, 120))
        self.assertIn("✔ concluído", texto)
        self.assertNotIn("░", texto)

    def test_total_desconhecido_usa_executed(self):
        p = r.Progresso(contar=lambda *_: None)
        p.linha("[safe] destination=x only=Nada")
        p.linha("\t Executed 11 tests, with 0 failures (0 unexpected) in 0.04 seconds")
        self.assertEqual(p.total, 11)

    def test_antes_dos_testes_mostra_compilando(self):
        texto = r.visivel(r.rodape_progresso(self.prova(), 5, 120, agora=0))
        self.assertIn("compilando para testar", texto)

    def test_abortado(self):
        p = self.prova()
        p.linha("abortado: tempo esgotado")
        self.assertIn("✘ abortado", r.visivel(r.rodape_progresso(p, 5, 120)))


class ProgressoBuild(unittest.TestCase):
    def test_etapas_da_instalacao(self):
        p = r.Progresso("main", instalar=True)
        p.linha("CompileSwift normal arm64 /a.swift")
        p.linha("CompileSwift normal arm64 /b.swift")
        self.assertEqual((p.etapa, p.arquivos), (1, 2))
        self.assertIn("compilar · etapa 2/5 · 2 arquivos", r.visivel(r.rodape_progresso(p, 70, 160)))
        p.linha("CodeSign /x.app")
        p.linha("** BUILD SUCCEEDED **")
        p.linha("[safe] DEVICE INSTALL OK")
        self.assertEqual(p.etapa, 4)
        p.linha("[safe] WATCH INSTALL SKIP: nenhum Apple Watch")
        self.assertEqual(p.fim, "ok")

    def test_build_falhou(self):
        p = r.Progresso("x")
        p.linha("** BUILD FAILED **")
        self.assertIn("✘ falhou", r.visivel(r.rodape_progresso(p, 3, 120)))


class Lanes(unittest.TestCase):
    def test_ultimo_estado_por_lane(self):
        linhas = [
            "2026-10-13 19:24:51 lane:claude segura FRA-361: conta em 83% (semana); card",
            "2026-10-13 19:35:03 lane:claude segura FRA-361: conta em 85% (semana); card",
            "2026-10-13 19:35:03 lane:grok livre → fila vazia",
            "2026-10-13 19:35:03 fora: FRA-347 (label needs:dono)",
        ]
        texto = r.visivel(r.rodape_lanes(linhas, 0))
        self.assertIn("claude FRA-361 esperando (conta 85%)", texto)
        self.assertIn("grok livre", texto)

    def test_ocupada_nao_repete_card(self):
        texto = r.visivel(r.rodape_lanes(["2026-10-13 19:40:15 lane:grok ocupada com FRA-361"], 0))
        self.assertIn("grok FRA-361 trabalhando", texto)

    def test_sem_log(self):
        self.assertIn("sem notícia", r.visivel(r.rodape_lanes([], 0)))


class Utilidades(unittest.TestCase):
    def test_cortar_mantem_cores_e_largura(self):
        texto = r.VERDE + "abcdef" + r.RESET + "ghij"
        self.assertEqual(r.visivel(r.cortar(texto, 8)), "abcdefgh")

    def test_tempo(self):
        self.assertEqual((r.tempo(42), r.tempo(3725)), ("0:42", "1:02:05"))

    def test_contar_testes_no_worktree(self):
        with tempfile.TemporaryDirectory() as root:
            d = os.path.join(root, "TranscentIATests")
            os.makedirs(d)
            with open(os.path.join(d, "A.swift"), "w") as f:
                f.write("final class ATests: XCTestCase {\n func testUm() {}\n func testDois() throws {}\n func ajuda() {}\n}\n")
            with open(os.path.join(d, "B.swift"), "w") as f:
                f.write("struct BTests {\n @Test func um() {}\n}\n")
            r._indices.clear()
            self.assertEqual(r.contar_testes(root, "ATests"), 2)
            self.assertEqual(r.contar_testes(root, "ATests/testUm"), 1)
            self.assertEqual(r.contar_testes(root, "ALL"), 3)
            self.assertEqual(r.contar_testes(root, "TranscentIATests/BTests"), 1)
            self.assertIsNone(r.contar_testes(root, "Nenhuma"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
