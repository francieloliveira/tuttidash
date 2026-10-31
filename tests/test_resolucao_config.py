"""Precedência do arquivo de config (FRA-605).

env > TuttiDash > Lanekeeper > TranscentIA Gasto > legado.
A env aponta um caminho que ainda não existe: não se lê o arquivo seguinte.
"""
import json
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import config as C


class PrecedenciaDoArquivo(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def escrever(self, relativo, dados) -> Path:
        caminho = self.home / relativo
        caminho.parent.mkdir(parents=True, exist_ok=True)
        caminho.write_text(json.dumps(dados), encoding="utf-8")
        return caminho

    def test_sem_arquivo_devolve_none(self):
        self.assertIsNone(C.arquivo_config(env={}, home=self.home, platform="darwin"))
        self.assertEqual(C.arquivos_em_uso(env={}, home=self.home, platform="darwin"), [])

    def test_ordem_env_tutti_lanekeeper_gasto_legado(self):
        legado = self.escrever(".transcentia/tools/config.json", {"aviso_pct": 1})
        self.assertEqual(C.arquivo_config(env={}, home=self.home), legado)

        gasto = self.escrever(
            "Library/Application Support/TranscentIA Gasto/config.json", {"aviso_pct": 2})
        self.assertEqual(C.arquivo_config(env={}, home=self.home), gasto)

        lanekeeper = self.escrever(
            "Library/Application Support/Lanekeeper/config.json", {"aviso_pct": 3})
        self.assertEqual(C.arquivo_config(env={}, home=self.home), lanekeeper)

        tutti = self.escrever(
            "Library/Application Support/TuttiDash/config.json", {"aviso_pct": 4})
        self.assertEqual(C.arquivo_config(env={}, home=self.home), tutti)

        fora = self.escrever("fora.json", {"aviso_pct": 5})
        self.assertEqual(
            C.arquivo_config(env={C.ENV_CONFIG: str(fora)}, home=self.home), fora)

    def test_env_que_nao_existe_nao_cai_no_proximo(self):
        self.escrever("Library/Application Support/TuttiDash/config.json", {"aviso_pct": 4})
        faltando = self.home / "nao-existe.json"
        self.assertEqual(
            C.arquivo_config(env={C.ENV_CONFIG: str(faltando)}, home=self.home), faltando)
        self.assertEqual(C.ler_objeto(env={C.ENV_CONFIG: str(faltando)}, home=self.home),
                         (faltando, {}))

    def test_env_vazia_nao_vence(self):
        legado = self.escrever(".transcentia/tools/config.json", {"aviso_pct": 1})
        self.assertEqual(C.arquivo_config(env={C.ENV_CONFIG: "  "}, home=self.home), legado)

    def test_env_expande_til(self):
        alvo = self.escrever("cfg.json", {"aviso_pct": 1})
        self.assertEqual(
            C.arquivo_config(env={C.ENV_CONFIG: "~/cfg.json"}, home=self.home), alvo)

    def test_resolve_le_tutti_e_nao_o_legado(self):
        self.escrever(".transcentia/tools/config.json", {"teto_semanal_usd": 1})
        tutti = self.escrever(
            "Library/Application Support/TuttiDash/config.json", {"teto_semanal_usd": 9})
        r = C.resolve({}, env={}, platform="darwin", home=self.home)
        self.assertEqual(r["valores"]["teto_semanal_usd"], 9.0)
        self.assertEqual(r["config_file"], tutti)

    def test_resolve_usa_o_legado_quando_e_o_unico(self):
        legado = self.escrever(".transcentia/tools/config.json", {"teto_semanal_usd": 3})
        r = C.resolve({}, env={}, platform="darwin", home=self.home)
        self.assertEqual(r["valores"]["teto_semanal_usd"], 3.0)
        self.assertEqual(r["config_file"], legado)

    def test_windows_continua_no_appdata(self):
        env = {"APPDATA": str(self.home / "Roaming")}
        caminho = self.home / "Roaming" / "tuttidash" / "config.json"
        caminho.parent.mkdir(parents=True)
        caminho.write_text("{}", encoding="utf-8")
        self.assertEqual(
            C.arquivo_config(env=env, home=self.home, platform="win32"), caminho)
        self.assertEqual(C.caminhos_config(self.home, "win32", env), (caminho,))


if __name__ == "__main__":
    unittest.main()
