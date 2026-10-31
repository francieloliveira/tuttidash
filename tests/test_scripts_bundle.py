"""FRA-613: o launchd executa os scripts do bundle, não os de ~/.transcentia.

Compila o `tuttidash-agente`, monta um .app falso e confirma que mudar a cópia
antiga não muda o processo. Também confere o install e o `run_lane.sh`.
"""
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTE_C = ROOT / "apps" / "notch-mac" / "Agente" / "agente.c"
BUILD = ROOT / "apps" / "notch-mac" / "build.sh"
PYTHON = "/usr/bin/python3"

SCRIPTS = {
    "dispatcher": ("lanes/dispatcher.py", "lanes-dispatcher.launchd.log", "--real"),
    "vigia": ("bots/watch.py", "bots-watch.launchd.log", None),
    "chave": ("tools/bots-chave", "bots-chave.launchd.log", None),
}


def _compilador():
    return shutil.which("clang") or shutil.which("gcc")


def _escrever(caminho: Path, texto: str, modo: int = 0o755) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(texto)
    caminho.chmod(modo)


class BundleDoAgente(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fra613-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.app = self.tmp / "TuttiDash.app"
        self.binario = self.app / "Contents" / "MacOS" / "tuttidash-agente"
        self.binario.parent.mkdir(parents=True)
        cc = _compilador()
        if not cc:
            self.skipTest("sem compilador C")
        r = subprocess.run(
            [cc, "-O2", "-Wall", "-Wextra", "-Werror", "-o", str(self.binario), str(AGENTE_C)],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.binario.chmod(0o755)

    def _script(self, papel: str, corpo: str) -> Path:
        rel = SCRIPTS[papel][0]
        destino = self.app / "Contents" / "Resources" / "controle" / rel
        _escrever(destino, corpo)
        return destino

    def _legado(self, papel: str, corpo: str) -> Path:
        rel = {
            "dispatcher": ".transcentia/lanes/dispatcher.py",
            "vigia": ".transcentia/bots/watch.py",
            "chave": ".transcentia/tools/bots-chave",
        }[papel]
        destino = self.home / rel
        _escrever(destino, corpo)
        return destino

    def _rodar(self, papel: str):
        return subprocess.run(
            [str(self.binario), papel],
            cwd=self.tmp, env={**os.environ, "HOME": str(self.home)},
            capture_output=True, text=True, timeout=20)

    def _log(self, papel: str) -> str:
        nome = SCRIPTS[papel][1]
        caminho = self.home / "Library" / "Logs" / "TranscentIA" / nome
        if not caminho.is_file():
            return ""
        return caminho.read_text()

    def test_launchd_usa_o_bundle_e_ignora_a_copia_antiga(self):
        for papel in ("dispatcher", "vigia", "chave"):
            with self.subTest(papel=papel):
                marca = self.tmp / f"marca-{papel}"
                self._script(papel, f"print('bundle-{papel}')\n")
                self._legado(papel, textwrap.dedent(f"""\
                    print('legado-{papel}')
                    open({str(marca)!r}, 'w').write('legado')
                    """))
                r = self._rodar(papel)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f"bundle-{papel}", self._log(papel))
                self.assertNotIn(f"legado-{papel}", self._log(papel))
                self.assertFalse(marca.exists())
                # Mudar a cópia antiga não muda o que o processo executa.
                self._legado(papel, "print('mudou')\n")
                log = self.home / "Library" / "Logs" / "TranscentIA" / SCRIPTS[papel][1]
                log.unlink()
                r2 = self._rodar(papel)
                self.assertEqual(r2.returncode, 0, r2.stderr)
                self.assertEqual(self._log(papel).strip(), f"bundle-{papel}")
                self.assertFalse(marca.exists())

    def test_sem_script_no_bundle_nao_cai_no_legado(self):
        marca = self.tmp / "marca-ausente"
        self._legado("vigia", f"open({str(marca)!r}, 'w').write('legado')\n")
        r = self._rodar("vigia")
        self.assertEqual(r.returncode, 70)
        self.assertIn("ausente ou recusado", r.stderr)
        self.assertFalse(marca.exists())
        self.assertEqual(self._log("vigia"), "")

    def test_recusa_executavel_dentro_de_transcentia(self):
        planta = self.tmp / ".transcentia" / "TuttiDash.app"
        destino = planta / "Contents" / "MacOS" / "tuttidash-agente"
        destino.parent.mkdir(parents=True)
        shutil.copy2(self.binario, destino)
        destino.chmod(0o755)
        marca = self.tmp / "marca-planta"
        script = planta / "Contents" / "Resources" / "controle" / "bots" / "watch.py"
        _escrever(script, f"open({str(marca)!r}, 'w').write('planta')\nprint('planta')\n")
        r = subprocess.run(
            [str(destino), "vigia"],
            env={**os.environ, "HOME": str(self.home)},
            capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 70, r.stderr)
        self.assertFalse(marca.exists())


class ScriptsReaisSobem(unittest.TestCase):
    def test_dispatcher_vigia_e_chave_saem_sem_app(self):
        with tempfile.TemporaryDirectory(prefix="fra613-sobe-") as bruto:
            home = Path(bruto)
            env = {**os.environ, "HOME": str(home)}
            casos = [
                [PYTHON, str(ROOT / "lanes" / "dispatcher.py"), "--dry-run"],
                [PYTHON, str(ROOT / "bots" / "watch.py")],
                [PYTHON, str(ROOT / "tools" / "bots-chave")],
            ]
            for cmd in casos:
                with self.subTest(cmd=cmd[-1]):
                    r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(r.returncode, 0, r.stderr[-500:] if r.stderr else r.stdout[-500:])


class RunLaneDoBundle(unittest.TestCase):
    def test_lane_view_sai_do_mesmo_diretorio_que_o_runner(self):
        with tempfile.TemporaryDirectory(prefix="fra613-run-") as bruto:
            base = Path(bruto)
            home = base / "home"
            bundle = base / "TuttiDash.app" / "Contents" / "Resources" / "controle" / "lanes"
            bundle.mkdir(parents=True)
            home.mkdir()
            marca_bundle = base / "viu-bundle"
            marca_legado = base / "viu-legado"
            shutil.copy(ROOT / "lanes" / "run_lane.sh", bundle / "run_lane.sh")
            (bundle / "run_lane.sh").chmod(0o755)
            _escrever(bundle / "lane_view.py", textwrap.dedent(f"""\
                import sys
                sys.stdin.read()
                open({str(marca_bundle)!r}, 'w').write('bundle')
                """))
            legado = home / ".transcentia" / "lanes" / "lane_view.py"
            _escrever(legado, f"open({str(marca_legado)!r}, 'w').write('legado')\n")
            wt = base / "wt"
            (wt / ".lane").mkdir(parents=True)
            (wt / ".lane" / "prompt.md").write_text("oi\n")
            (wt / ".lane" / "agent_cmd").write_text("echo oi\n")
            (wt / ".lane" / "finalized").write_text("ok\n")
            (wt / ".lane" / "exit_code").write_text("0\n")
            log = base / "lane.jsonl"
            try:
                subprocess.run(
                    ["bash", str(bundle / "run_lane.sh"),
                     "claude", str(wt), "FRA-613", str(log)],
                    cwd=wt, env={**os.environ, "HOME": str(home)},
                    capture_output=True, text=True, timeout=5)
            except subprocess.TimeoutExpired:
                pass
            self.assertEqual(marca_bundle.read_text(), "bundle")
            self.assertFalse(marca_legado.exists())


class InstallNaoCopiaScripts(unittest.TestCase):
    def test_install_deixa_o_legado_inerte_e_aponta_o_lancador(self):
        with tempfile.TemporaryDirectory(prefix="fra613-inst-") as bruto:
            home = Path(bruto)
            lanes = home / ".transcentia" / "lanes"
            bots = home / ".transcentia" / "bots"
            tools = home / ".transcentia" / "tools"
            lanes.mkdir(parents=True)
            bots.mkdir(parents=True)
            tools.mkdir(parents=True)
            sentinela = "LEGADO-NAO-ATUALIZAR\n"
            for caminho in (
                lanes / "dispatcher.py", lanes / "lanes_window.py", lanes / "lanes_ctl.py",
                lanes / "run_lane.sh", lanes / "lane_view.py", bots / "watch.py", tools / "bots-chave",
            ):
                caminho.write_text(sentinela)
            env = {**os.environ, "HOME": str(home)}
            r = subprocess.run(
                ["bash", str(ROOT / "tools" / "install.sh"), "--sem-launchd"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr[-800:] if r.stderr else r.stdout[-800:])
            self.assertIn("legado inerte", r.stdout)
            for caminho in (
                lanes / "dispatcher.py", lanes / "run_lane.sh", lanes / "lane_view.py",
                bots / "watch.py", tools / "bots-chave",
            ):
                self.assertEqual(caminho.read_text(), sentinela, caminho)
            self.assertTrue((lanes / "catalogo.py").is_file())
            lancador = home / "Library" / "Application Support" / "AgentesLocais" / "TuttiDash Vigia"
            texto = lancador.read_text()
            self.assertIn("tuttidash-agente", texto)
            self.assertNotIn("python3", texto)
            self.assertNotIn("watch.py", texto)
            modo = stat.S_IMODE(lancador.stat().st_mode)
            self.assertEqual(modo, 0o755)
            for nome in ("TuttiDash Chave", "TuttiDash Dispatcher"):
                self.assertTrue((lancador.parent / nome).is_file())


class ContratoDoBuild(unittest.TestCase):
    def test_build_copia_antes_do_codesign_com_modo_certo(self):
        texto = BUILD.read_text()
        copia = texto.index("plano de controle")
        verifica = texto.index("codesign --verify")
        self.assertLess(copia, verifica)
        for nome in (
            "dispatcher.py", "lane_view.py", "lanes_window.py", "lanes_ctl.py",
            "run_lane.sh", "watch.py", "bots-chave", "lanes.command",
        ):
            self.assertIn(f'install -m 755 "$REPO/', texto)
            self.assertIn(nome, texto)
        self.assertIn('install -m 644 "$REPO/tools/script-controle.sh"', texto)

    def test_padroes_do_cfg_apontam_para_o_bundle(self):
        import runpy
        cfg = runpy.run_path(str(ROOT / "tools" / "cfg"))
        prefixo = "/Applications/TuttiDash.app/Contents/Resources/controle/"
        por_chave = {j["chave"]: j["script"] for j in cfg["DEFAULTS"]["agendas"]["jobs"]}
        self.assertEqual(por_chave["dispatcher"], prefixo + "lanes/dispatcher.py")
        self.assertEqual(por_chave["watch"], prefixo + "bots/watch.py")
        self.assertEqual(por_chave["chave"], prefixo + "tools/bots-chave")
        for script in por_chave.values():
            self.assertNotIn(".transcentia", script)

    def test_runner_fica_ao_lado_do_dispatcher(self):
        sys.path.insert(0, str(ROOT / "lanes"))
        import dispatcher as d
        runner = d.caminho_runner()
        self.assertEqual(runner, Path(d.__file__).resolve().parent / "run_lane.sh")
        self.assertTrue(runner.is_file())
        self.assertNotIn(".transcentia", str(runner))
        janela = d.caminho_comando_janela()
        self.assertTrue(janela.is_file())
        self.assertNotIn(".transcentia", str(janela))


if __name__ == "__main__":
    unittest.main()
