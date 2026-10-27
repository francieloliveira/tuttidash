import json
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
USO = RAIZ / "tests" / "fixtures" / "uso"


class FixturesDeUsoTest(unittest.TestCase):
    """As respostas de uso são dado versionado, não JSON dentro do teste.

    O Swift (`UsoCopilotTests`) lê estes arquivos. Se o payload mudar de lugar, o
    teste tem de dizer qual é o lugar, não ler `""` e passar por acidente.
    """

    ESPERADOS = {
        "copilot.json": ("timePeriod", "user", "usageItems"),
    }

    def test_todas_as_respostas_existem(self):
        for nome in self.ESPERADOS:
            with self.subTest(fixture=nome):
                self.assertTrue((USO / nome).is_file(), f"falta {nome}")

    def test_sao_json_valido_com_as_chaves_esperadas(self):
        for nome, chaves in self.ESPERADOS.items():
            with self.subTest(fixture=nome):
                obj = json.loads((USO / nome).read_text(encoding="utf-8"))
                for chave in chaves:
                    self.assertIn(chave, obj, f"{nome} sem a chave {chave}")

    def test_so_ha_respostas_de_apis_oficiais(self):
        """O repositório aberto não guarda respostas de endpoints fora das APIs oficiais (FRA-565)."""
        self.assertEqual(sorted(p.name for p in USO.glob("*.json")), sorted(self.ESPERADOS))

    def test_o_gerador_reproduz_as_fixtures(self):
        """`gerar_uso.py` tem que escrever exatamente o que está versionado."""
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "gerar_uso", RAIZ / "tests" / "fixtures" / "gerar_uso.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for arquivo, corpo in mod.RESPOSTAS.values():
            with self.subTest(fixture=arquivo):
                self.assertEqual(json.loads((USO / arquivo).read_text(encoding="utf-8")),
                                 corpo, "tests/fixtures/uso divergiu do gerador")


if __name__ == "__main__":
    unittest.main()
