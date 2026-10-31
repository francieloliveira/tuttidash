"""Precedência do arquivo de config (FRA-605).

env > TuttiDash > Lanekeeper > TranscentIA Gasto > legado.
A env aponta um caminho que ainda não existe: não se lê o arquivo seguinte.
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gasto_lanes import config as C
from gasto_lanes import projetos as P


def carregar_cfg():
    """`tools/cfg` não tem sufixo .py: `spec_from_file_location` devolve None."""
    nome = "cfg_fra605"
    carregado = sys.modules.get(nome)
    if carregado is not None:
        return carregado
    caminho = Path(__file__).resolve().parents[1] / "tools" / "cfg"
    loader = importlib.machinery.SourceFileLoader(nome, str(caminho))
    spec = importlib.util.spec_from_loader(nome, loader)
    if spec is None or spec.loader is None:
        raise ImportError(caminho)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[nome] = mod
    spec.loader.exec_module(mod)
    return mod


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


class MesmoArquivo(unittest.TestCase):
    """``projeto().repo`` e ``linear.*`` saem do arquivo que o resolvedor escolheu.

    O vigia lia ``linear.*`` pelo ``cfg`` e o repo por ``projetos.py``. Com a env
    ou com a config antiga, os dois caminhos agora apontam o mesmo arquivo.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(P._resetar_cache)
        P._resetar_cache()

    def escrever(self, relativo, dados) -> Path:
        caminho = self.home / relativo
        caminho.parent.mkdir(parents=True, exist_ok=True)
        caminho.write_text(json.dumps(dados), encoding="utf-8")
        return caminho

    def cfg(self):
        return carregar_cfg()

    def cadastro(self, repo, dono, workspace):
        return {
            "projetos": [{
                "id": "aaaaaaaa-0000-4000-8000-0000000000aa",
                "nome": "App",
                "repo": repo,
                "padrao": True,
            }],
            "linear": {"owner_label": dono, "workspace_url": workspace},
        }

    def assert_mesmo_arquivo(self, arquivo, repo, dono, workspace):
        P._resetar_cache()
        cfg = self.cfg()
        self.assertEqual(cfg.arquivo(), arquivo)
        self.assertEqual(C.arquivo_config(), arquivo)
        self.assertEqual(P.padrao().repo, Path(repo))
        self.assertEqual(cfg.get("linear.owner_label"), dono)
        self.assertEqual(cfg.get("linear.workspace_url"), workspace)
        self.assertEqual(C.obter("linear.owner_label"), dono)
        self.assertEqual(C.obter("linear.workspace_url"), workspace)

    def test_env_vence_e_os_dois_leem_esse_arquivo(self):
        repo = str(self.home / "repo-env")
        envf = self.escrever("env.json", self.cadastro(repo, "needs:env", "https://env.example"))
        self.escrever("Library/Application Support/TuttiDash/config.json",
                      self.cadastro(str(self.home / "repo-tutti"), "needs:tutti", "https://tutti.example"))
        self.escrever("Library/Application Support/Lanekeeper/config.json",
                      self.cadastro(str(self.home / "repo-lane"), "needs:lane", "https://lane.example"))
        self.escrever("Library/Application Support/TranscentIA Gasto/config.json",
                      self.cadastro(str(self.home / "repo-gasto"), "needs:gasto", "https://gasto.example"))
        self.escrever(".transcentia/tools/config.json",
                      self.cadastro(str(self.home / "repo-legado"), "needs:legado", "https://legado.example"))
        with mock.patch.object(Path, "home", return_value=self.home), \
             mock.patch.dict(os.environ, {C.ENV_CONFIG: str(envf)}):
            self.assert_mesmo_arquivo(envf, repo, "needs:env", "https://env.example")

    def test_config_antiga_sem_as_pastas_novas(self):
        repo = str(self.home / "repo-legado")
        legado = self.escrever(".transcentia/tools/config.json",
                               self.cadastro(repo, "needs:legado", "https://legado.example"))
        with mock.patch.object(Path, "home", return_value=self.home), \
             mock.patch.dict(os.environ, {C.ENV_CONFIG: ""}):
            self.assert_mesmo_arquivo(legado, repo, "needs:legado", "https://legado.example")

    def test_nome_provisorio_quando_e_o_mais_novo_que_existe(self):
        repo = str(self.home / "repo-gasto")
        gasto = self.escrever("Library/Application Support/TranscentIA Gasto/config.json",
                              self.cadastro(repo, "needs:gasto", "https://gasto.example"))
        self.escrever(".transcentia/tools/config.json",
                      self.cadastro(str(self.home / "repo-legado"), "needs:legado", "https://legado.example"))
        with mock.patch.object(Path, "home", return_value=self.home), \
             mock.patch.dict(os.environ, {C.ENV_CONFIG: ""}):
            self.assert_mesmo_arquivo(gasto, repo, "needs:gasto", "https://gasto.example")

    def test_tutti_sem_projeto_nao_busca_o_repo_no_legado(self):
        """O bug: linear no TuttiDash e o repo no legado. Os dois ficam no TuttiDash."""
        self.escrever("Library/Application Support/TuttiDash/config.json",
                      {"linear": {"owner_label": "needs:tutti", "workspace_url": "https://tutti.example"}})
        self.escrever(".transcentia/tools/config.json",
                      self.cadastro(str(self.home / "repo-legado"), "needs:legado", "https://legado.example"))
        tutti = self.home / "Library/Application Support/TuttiDash/config.json"
        with mock.patch.object(Path, "home", return_value=self.home), \
             mock.patch.dict(os.environ, {C.ENV_CONFIG: ""}):
            P._resetar_cache()
            cfg = self.cfg()
            self.assertEqual(cfg.arquivo(), tutti)
            self.assertEqual(cfg.get("linear.owner_label"), "needs:tutti")
            self.assertEqual(P.padrao().id, "")
            self.assertEqual(C.obter("linear.workspace_url"), "https://tutti.example")


if __name__ == "__main__":
    unittest.main()
