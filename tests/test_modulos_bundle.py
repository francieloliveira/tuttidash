"""FRA-615: os módulos Python saem do bundle, não de ~/.transcentia.

Trocar a cópia antiga não muda o dispatcher nem o vigia. Sem o módulo no
bundle, o import fecha e a cópia gravável não roda. gasto_privado.py segue
opcional.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = "/usr/bin/python3"
MODULOS = ("catalogo.py", "projetos.py", "privacidade.py", "linear_ids.py", "fila.py", "config.py")

GANCHO = (
    "\nimport os as _fra_os, sys as _fra_sys\n"
    "import privacidade as _fra_priv\n"
    "_marca = _fra_os.environ.get('FRA615_MARCA')\n"
    "if _marca:\n"
    "    open(_marca, 'w', encoding='utf-8').write(\n"
    "        __file__ + '\\n' + str(getattr(_fra_priv, '__file__', '')) + '\\n'\n"
    "        + '\\n'.join(_fra_sys.path) + '\\n')\n"
)

VENENO = (
    "import os\n"
    "p = os.environ.get('FRA615_VENENO', '')\n"
    "if p:\n"
    "    open(p, 'a', encoding='utf-8').write('legado\\n')\n"
    "raise SystemExit('legado')\n"
)


def _escrever(caminho: Path, texto: str) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(texto)


class ModulosDoBundle(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self._tmp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.controle = self.tmp / "TuttiDash.app" / "Contents" / "Resources" / "controle"
        self.modulos = self.controle / "gasto_lanes"
        self.modulos.mkdir(parents=True)
        for nome in MODULOS:
            origem = ROOT / "gasto_lanes" / nome
            destino = self.modulos / nome
            shutil.copy(origem, destino)
        (self.modulos / "catalogo.py").write_text(
            (self.modulos / "catalogo.py").read_text(encoding="utf-8") + GANCHO,
            encoding="utf-8")
        for rel in ("lanes/dispatcher.py", "lanes/lanes_window.py", "bots/watch.py"):
            destino = self.controle / rel
            destino.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / rel, destino)
        self.marca = self.tmp / "marca"
        self.veneno = self.tmp / "veneno"
        for pasta in ("lanes", "bots", "tools", "gasto_lanes"):
            base = self.home / ".transcentia" / pasta
            for nome in ("catalogo.py", "privacidade.py", "projetos.py", "linear_ids.py",
                         "fila.py", "config.py", "gasto_privado.py"):
                _escrever(base / nome, VENENO)

    def _tmp(self) -> str:
        return tempfile.mkdtemp(prefix="fra615-")

    def _env(self) -> dict:
        return {
            **os.environ,
            "HOME": str(self.home),
            "FRA615_MARCA": str(self.marca),
            "FRA615_VENENO": str(self.veneno),
            "PYTHONPATH": str(self.home / ".transcentia" / "lanes"),
        }

    def _rodar(self, argv: list[str]):
        return subprocess.run(
            argv, cwd=self.tmp, env=self._env(),
            capture_output=True, text=True, timeout=30)

    def _conferir_marca(self):
        self.assertTrue(self.marca.is_file(), "o bundle não importou catalogo")
        linhas = self.marca.read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(linhas), 2)
        self.assertTrue(linhas[0].endswith("/controle/gasto_lanes/catalogo.py"), linhas[0])
        self.assertTrue(linhas[1].endswith("/controle/gasto_lanes/privacidade.py"), linhas[1])
        self.assertNotIn(".transcentia", linhas[0])
        self.assertNotIn(".transcentia", linhas[1])
        for caminho in linhas[2:]:
            self.assertNotIn(".transcentia", caminho)
        self.assertTrue(any(c.rstrip("/").endswith("/gasto_lanes") for c in linhas[2:]))
        self.assertFalse(self.veneno.exists())

    def test_dispatcher_ignora_a_copia_antiga(self):
        r = self._rodar([PYTHON, str(self.controle / "lanes" / "dispatcher.py"), "--dry-run"])
        self.assertEqual(r.returncode, 0, r.stderr[-800:] if r.stderr else r.stdout[-800:])
        self._conferir_marca()
        self.marca.unlink()
        _escrever(self.home / ".transcentia" / "lanes" / "catalogo.py", VENENO + "\n# trocado\n")
        r2 = self._rodar([PYTHON, str(self.controle / "lanes" / "dispatcher.py"), "--dry-run"])
        self.assertEqual(r2.returncode, 0, r2.stderr[-800:] if r2.stderr else r2.stdout[-800:])
        self._conferir_marca()

    def test_vigia_ignora_a_copia_antiga(self):
        r = self._rodar([PYTHON, str(self.controle / "bots" / "watch.py")])
        self.assertEqual(r.returncode, 0, r.stderr[-800:] if r.stderr else r.stdout[-800:])
        self._conferir_marca()

    def test_janela_ignora_a_copia_antiga(self):
        script = str(self.controle / "lanes" / "lanes_window.py")
        codigo = textwrap.dedent(f"""\
            import importlib.util
            spec = importlib.util.spec_from_file_location("janela_fra615", {script!r})
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            """)
        r = self._rodar([PYTHON, "-c", codigo])
        self.assertEqual(r.returncode, 0, r.stderr[-800:] if r.stderr else r.stdout[-800:])
        self._conferir_marca()

    def test_sem_modulo_no_bundle_nao_cai_no_gravavel(self):
        (self.modulos / "catalogo.py").unlink()
        for papel, argv in (
            ("dispatcher", [PYTHON, str(self.controle / "lanes" / "dispatcher.py"), "--dry-run"]),
            ("vigia", [PYTHON, str(self.controle / "bots" / "watch.py")]),
        ):
            with self.subTest(papel=papel):
                self.veneno.unlink(missing_ok=True)
                r = self._rodar(argv)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("recusado", r.stderr)
                self.assertFalse(self.veneno.exists())
                self.assertFalse(self.marca.exists())

    def test_atalho_para_transcentia_e_recusado(self):
        fora = self.home / ".transcentia" / "lanes" / "catalogo.py"
        dentro = self.modulos / "catalogo.py"
        dentro.unlink()
        dentro.symlink_to(fora)
        r = self._rodar([PYTHON, str(self.controle / "lanes" / "dispatcher.py"), "--dry-run"])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("recusado", r.stderr)
        self.assertFalse(self.veneno.exists())


class GastoPrivadoOpcional(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fra615-priv-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.addCleanup(lambda: sys.modules.pop("gasto_privado", None))

    def _catalogo(self, pasta: Path):
        spec = importlib.util.spec_from_file_location(f"catalogo_{pasta.name}", pasta / "catalogo.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def _veneno(self, home: Path) -> Path:
        marca = self.tmp / "veneno-privado"
        texto = (
            "import os\n"
            f"open({str(marca)!r}, 'w').write('legado')\n"
            "def modelos_claude(get_json, ids, home):\n"
            "    return ['veneno']\n"
        )
        for pasta in ("lanes", "bots", "tools"):
            _escrever(home / ".transcentia" / pasta / "gasto_privado.py", texto)
        return marca

    def test_ausente_nao_quebra_e_ignora_a_copia_antiga(self):
        pasta = self.tmp / "publico" / "gasto_lanes"
        pasta.mkdir(parents=True)
        shutil.copy(ROOT / "gasto_lanes" / "catalogo.py", pasta / "catalogo.py")
        home = self.tmp / "home"
        marca = self._veneno(home)
        anterior = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = str(home / ".transcentia" / "lanes")
        try:
            mod = self._catalogo(pasta)
            self.assertIsNone(mod._lista_extra("claude"))
        finally:
            if anterior is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = anterior
        self.assertFalse(marca.exists())

    def test_ao_lado_vence_a_copia_antiga(self):
        pasta = self.tmp / "pessoal" / "gasto_lanes"
        pasta.mkdir(parents=True)
        shutil.copy(ROOT / "gasto_lanes" / "catalogo.py", pasta / "catalogo.py")
        _escrever(pasta / "gasto_privado.py", textwrap.dedent("""\
            def modelos_claude(get_json, ids, home):
                return ["pessoal"]
            """))
        home = self.tmp / "home"
        marca = self._veneno(home)
        mod = self._catalogo(pasta)
        self.assertEqual(mod._lista_extra("claude"), ["pessoal"])
        self.assertFalse(marca.exists())

    def test_atalho_ate_transcentia_nao_carrega(self):
        pasta = self.tmp / "atalho" / "gasto_lanes"
        pasta.mkdir(parents=True)
        shutil.copy(ROOT / "gasto_lanes" / "catalogo.py", pasta / "catalogo.py")
        home = self.tmp / "home"
        marca = self._veneno(home)
        (pasta / "gasto_privado.py").symlink_to(home / ".transcentia" / "lanes" / "gasto_privado.py")
        mod = self._catalogo(pasta)
        self.assertIsNone(mod._lista_extra("claude"))
        self.assertFalse(marca.exists())

    def test_pasta_pessoal_do_checkout_entra_sem_ser_obrigatoria(self):
        repo = self.tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        pasta = repo / "gasto_lanes"
        pasta.mkdir(parents=True)
        shutil.copy(ROOT / "gasto_lanes" / "catalogo.py", pasta / "catalogo.py")
        _escrever(repo / "apps" / "notch-mac" / "Privado" / "python" / "gasto_privado.py",
                  "def modelos_claude(get_json, ids, home):\n    return ['checkout']\n")
        mod = self._catalogo(pasta)
        self.assertEqual(mod._lista_extra("claude"), ["checkout"])
        (repo / "apps" / "notch-mac" / "Privado" / "python" / "gasto_privado.py").unlink()
        sys.modules.pop("gasto_privado", None)
        mod2 = self._catalogo(pasta)
        self.assertIsNone(mod2._lista_extra("claude"))


if __name__ == "__main__":
    unittest.main()
