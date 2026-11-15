"""Registro canônico dos erros conhecidos das lanes (FRA-668).

Fonte única do vocabulário E# que o revisor, a triagem da parada e o dispatcher
consultam. O vigia injeta o texto deste módulo no prompt quando o documento do
Linear não tem lista; o dispatcher aponta os códigos para cá.
"""
import unittest

from gasto_lanes import erros_conhecidos as erros


class RegistroErrosConhecidosTest(unittest.TestCase):
    def test_tem_os_erros_canonicos_da_base(self):
        self.assertTrue(erros.ERROS_CONHECIDOS, "registro vazio: o revisor não consegue citar erro nenhum")
        self.assertEqual([e["codigo"] for e in erros.ERROS_CONHECIDOS],
                         ["E3", "E5", "E13", "E14", "E19", "E22"])

    def test_codigos_unicos(self):
        codigos = [e["codigo"] for e in erros.ERROS_CONHECIDOS]
        self.assertEqual(len(codigos), len(set(codigos)))

    def test_cada_erro_tem_os_campos(self):
        for e in erros.ERROS_CONHECIDOS:
            with self.subTest(codigo=e["codigo"]):
                self.assertTrue(e.get("titulo"))
                self.assertTrue(e.get("resumo"))
                self.assertTrue(e.get("causa"))
                self.assertTrue(e.get("acao"))

    def test_por_codigo(self):
        e = erros.por_codigo("E22")
        self.assertIsNotNone(e)
        self.assertEqual(e["titulo"], "Prova sem evidência")
        self.assertIsNone(erros.por_codigo("E999"))
        self.assertIsNone(erros.por_codigo(None))

    def test_formato_tem_um_codigo_por_erro(self):
        texto = erros.formatar()
        for e in erros.ERROS_CONHECIDOS:
            self.assertIn(f"**{e['codigo']}**", texto)
        self.assertNotIn("{", texto, "o prompt é montado com str.format")


if __name__ == "__main__":
    unittest.main()
