"""FRA-616: a âncora do plano de controle fica fora do agente.

Trocar um script ou módulo do bundle é detectado. A cópia antiga em
~/.transcentia não satisfaz a verificação. O binário de produção ignora
o ambiente e exige a âncora de root mais o designated requirement
Apple Development 3QA76CY27W — não um CDHash.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTE_C = ROOT / "apps" / "notch-mac" / "Agente" / "agente.c"
FERRAMENTA = ROOT / "tools" / "integridade-controle.py"
BUILD = ROOT / "apps" / "notch-mac" / "build.sh"
SWIFT = ROOT / "apps" / "notch-mac" / "Sources" / "GastoCore" / "IntegridadeControle.swift"
PYTHON = "/usr/bin/python3"

import importlib.util

_spec = importlib.util.spec_from_file_location("integridade_controle", FERRAMENTA)
ancora_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ancora_mod)


def _compilador():
    return shutil.which("clang") or shutil.which("gcc") or shutil.which("cc")


def _escrever(caminho: Path, texto: str, modo: int = 0o755) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(texto)
    caminho.chmod(modo)


class Binario(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self._mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.app = self.tmp / "TuttiDash.app"
        self.controle = self.app / "Contents" / "Resources" / "controle"
        self.binario = self.app / "Contents" / "MacOS" / "tuttidash-agente"
        self.ancora = self.tmp / "ancora" / "controle.sha256"
        self.cc = _compilador()
        if not self.cc:
            self.skipTest("sem compilador C")

    def _mkdtemp(self):
        import tempfile
        return tempfile.mkdtemp(prefix="fra616-")

    def _compilar(self, destino: Path, teste: bool, pular_assinatura: bool) -> None:
        destino.parent.mkdir(parents=True, exist_ok=True)
        flags = [self.cc, "-O2", "-Wall", "-Wextra", "-Werror"]
        if teste:
            flags.append("-DTUTTIDASH_INTEGRIDADE_TESTE")
        if pular_assinatura:
            flags.append("-DTUTTIDASH_PULAR_ASSINATURA")
        flags += ["-o", str(destino), str(AGENTE_C)]
        r = subprocess.run(flags, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        destino.chmod(0o755)

    def _plantar(self, relativos: dict[str, str]) -> None:
        for rel, corpo in relativos.items():
            _escrever(self.controle / rel, corpo)

    def _gravar_ancora(self) -> None:
        self.ancora.parent.mkdir(parents=True, exist_ok=True)
        self.ancora.parent.chmod(0o755)
        subprocess.run(
            [PYTHON, str(FERRAMENTA), "gerar", str(self.controle), str(self.ancora)],
            check=True, capture_output=True, text=True)
        self.ancora.chmod(0o644)

    def _rodar(self, papel: str, binario: Path | None = None, ancora: Path | None = None):
        env = {**os.environ, "HOME": str(self.home)}
        if ancora is not None:
            env["TUTTIDASH_INTEGRIDADE_ARQUIVO"] = str(ancora)
        return subprocess.run(
            [str(binario or self.binario), papel],
            cwd=self.tmp, env=env, capture_output=True, text=True, timeout=20)

    def test_sha256_bate_com_hashlib(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        bruto = self.tmp / "blob"
        for dados in (b"", b"abc", b"a" * 100, bytes(range(256)) * 3):
            bruto.write_bytes(dados)
            r = subprocess.run([str(self.binario), "--sha256", str(bruto)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), hashlib.sha256(dados).hexdigest())

    def test_trocar_script_ou_modulo_aborta_e_o_legado_nao_engana(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        marca = self.tmp / "marca"
        self._plantar({
            "lanes/dispatcher.py": "print('bundle-dispatcher')\n",
            "gasto_lanes/catalogo.py": "VALOR = 'bundle'\n",
        })
        self._gravar_ancora()
        r = self._rodar("dispatcher", ancora=self.ancora)
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.home / "Library" / "Logs" / "TranscentIA" / "lanes-dispatcher.launchd.log"
        self.assertIn("bundle-dispatcher", log.read_text())

        # A cópia antiga tem o conteúdo que o manifesto descreve. Não vale.
        legado = self.home / ".transcentia" / "lanes" / "dispatcher.py"
        _escrever(legado, "print('bundle-dispatcher')\n")
        _escrever(self.home / ".transcentia" / "gasto_lanes" / "catalogo.py", "VALOR = 'bundle'\n")
        _escrever(self.home / ".transcentia" / "controle.sha256", self.ancora.read_text(), 0o644)
        _escrever(self.controle / "gasto_lanes" / "catalogo.py", "VALOR = 'trocado'\n", 0o644)
        _escrever(self.controle / "lanes" / "dispatcher.py", f"open({str(marca)!r}, 'w').write('executou')\n")
        log.unlink()
        r2 = self._rodar("dispatcher", ancora=self.ancora)
        self.assertEqual(r2.returncode, 77, r2.stderr)
        self.assertIn("integridade: divergencia: hash", r2.stderr)
        self.assertFalse(marca.exists())
        self.assertNotIn("executou", log.read_text())
        self.assertIn("integridade: divergencia", log.read_text())

    def test_manifesto_no_bundle_ou_no_transcentia_nao_e_ancora(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        marca = self.tmp / "marca-lugar"
        self._plantar({"bots/watch.py": f"open({str(marca)!r}, 'w').write('x')\n"})
        dentro = self.controle / "controle.sha256"
        subprocess.run(
            [PYTHON, str(FERRAMENTA), "gerar", str(self.controle), str(dentro)],
            check=True, capture_output=True, text=True)
        # O gerador passou a incluir o próprio manifesto. Regenerar não: o teste
        # aponta a âncora para dentro do bundle de propósito.
        r = self._rodar("vigia", ancora=dentro)
        self.assertEqual(r.returncode, 77, r.stderr)
        self.assertIn("integridade: divergencia: alcance", r.stderr)
        self.assertFalse(marca.exists())

        legado = self.home / ".transcentia" / "controle.sha256"
        _escrever(legado, dentro.read_text(), 0o644)
        r2 = self._rodar("vigia", ancora=legado)
        self.assertEqual(r2.returncode, 77, r2.stderr)
        self.assertIn("integridade: divergencia: alcance", r2.stderr)
        self.assertFalse(marca.exists())

    def test_symlink_nao_executa_a_copia_antiga(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        marca = self.tmp / "marca-link"
        legado = self.home / ".transcentia" / "bots" / "watch.py"
        _escrever(legado, f"open({str(marca)!r}, 'w').write('legado')\n")
        destino = self.controle / "bots" / "watch.py"
        destino.parent.mkdir(parents=True)
        destino.symlink_to(legado)
        r = self._rodar("vigia", ancora=self.ancora)
        self.assertNotEqual(r.returncode, 0, r.stderr)
        self.assertFalse(marca.exists())

    def test_pycache_nao_quebra_e_py_extra_quebra(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        self._plantar({"tools/bots-chave": "print('chave')\n"})
        self._gravar_ancora()
        cache = self.controle / "gasto_lanes" / "__pycache__" / "catalogo.pyc"
        _escrever(cache, "lixo", 0o644)
        r = self._rodar("chave", ancora=self.ancora)
        self.assertEqual(r.returncode, 0, r.stderr)
        _escrever(self.controle / "gasto_lanes" / "evil.py", "print('evil')\n", 0o644)
        r2 = self._rodar("chave", ancora=self.ancora)
        self.assertEqual(r2.returncode, 77, r2.stderr)
        self.assertIn("integridade: divergencia: hash", r2.stderr)

    def test_ancora_gravavel_pelo_grupo_nao_vale(self):
        self._compilar(self.binario, teste=True, pular_assinatura=True)
        self._plantar({"tools/bots-chave": "print('chave')\n"})
        self._gravar_ancora()
        self.ancora.chmod(0o666)
        r = self._rodar("chave", ancora=self.ancora)
        self.assertEqual(r.returncode, 77, r.stderr)
        self.assertIn("integridade: divergencia: ancora", r.stderr)

    def test_producao_ignora_o_ambiente(self):
        self._compilar(self.binario, teste=False, pular_assinatura=False)
        marca = self.tmp / "marca-prod"
        self._plantar({"lanes/dispatcher.py": f"open({str(marca)!r}, 'w').write('prod')\n"})
        self._gravar_ancora()
        r = self._rodar("dispatcher", binario=self.binario, ancora=self.ancora)
        self.assertEqual(r.returncode, 77, r.stderr)
        self.assertIn("integridade: divergencia", r.stderr)
        self.assertNotIn("assinatura", r.stderr)
        self.assertNotIn(str(self.ancora), r.stderr)
        self.assertFalse(marca.exists())

    def test_sem_designated_requirement_nao_executa(self):
        self._compilar(self.binario, teste=True, pular_assinatura=False)
        self._plantar({"bots/watch.py": "print('nao')\n"})
        self._gravar_ancora()
        r = self._rodar("vigia", ancora=self.ancora)
        self.assertEqual(r.returncode, 77, r.stderr)
        self.assertIn("integridade: divergencia: assinatura 3QA76CY27W", r.stderr)
        self.assertNotIn("cdhash", r.stderr.lower())


class Formato(unittest.TestCase):
    def test_requisito_e_o_mesmo_nos_tres_lugares_e_nao_e_cdhash(self):
        trechos = {
            "c": AGENTE_C.read_text(),
            "swift": SWIFT.read_text(),
            "py": FERRAMENTA.read_text(),
            "build": BUILD.read_text(),
        }
        for nome, texto in trechos.items():
            self.assertIn("3QA76CY27W", texto, nome)
            self.assertIn("anchor apple generic", texto, nome)
            self.assertIn('certificate leaf[subject.OU]', texto, nome)
        self.assertNotIn("cdhash", ancora_mod.REQUISITO.lower())
        self.assertNotIn("cdhash", IntegridadeRequisito.do_c().lower())
        self.assertEqual(ancora_mod.EQUIPE, "3QA76CY27W")
        self.assertEqual(ancora_mod.MAGIA, "tuttidash-controle-v1")
        self.assertTrue(ancora_mod.CAMINHO_ANCORA.endswith("/tuttidash/controle.sha256"))
        self.assertNotIn(".transcentia", ancora_mod.CAMINHO_ANCORA)
        self.assertNotIn("/Contents/", ancora_mod.CAMINHO_ANCORA)

    def test_lista_do_build_coincide_com_o_gerador(self):
        import re
        texto = BUILD.read_text()
        fixos = set(re.findall(r'install -m \d+ "\$REPO/([^"$]+)" "\$CTRL/([^"$]+)"', texto))
        loop = re.search(r"for mod in ([^;]+);", texto)
        self.assertIsNotNone(loop)
        mods = set(loop.group(1).split())
        esperado_fixo = {(origem, rel) for origem, rel, _modo in ancora_mod.COPIAS if not rel.startswith("gasto_lanes/")}
        esperado_mods = {rel.split("/", 1)[1] for _origem, rel, _modo in ancora_mod.COPIAS if rel.startswith("gasto_lanes/")}
        self.assertEqual(fixos, esperado_fixo)
        self.assertEqual(mods, esperado_mods)
        self.assertIn('if [[ -f "$PRIVADO_PY" ]]', texto)

    def test_gravar_recusa_destino_no_alcance_do_agente(self):
        with self.assertRaises(SystemExit):
            ancora_mod._recusa_destino(Path("/tmp/.transcentia/controle.sha256"))
        with self.assertRaises(SystemExit):
            ancora_mod._recusa_destino(Path("/Applications/TuttiDash.app/Contents/Resources/controle.sha256"))
        ancora_mod._recusa_destino(Path(ancora_mod.CAMINHO_ANCORA))


class IntegridadeRequisito:
    @staticmethod
    def do_c() -> str:
        texto = AGENTE_C.read_text()
        inicio = texto.index("static const char REQUISITO[] =")
        miolo = texto[inicio:texto.index(";", inicio)]
        return miolo


class AncoraRoot(unittest.TestCase):
    def test_instala_fora_do_home_com_dono_root(self):
        if os.geteuid() != 0 and subprocess.call(["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            self.skipTest("sem root")
        r = subprocess.run(
            [PYTHON, str(FERRAMENTA), "instalar-repo", str(ROOT)],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        destino = Path(ancora_mod.CAMINHO_ANCORA)
        self.assertTrue(destino.is_file())
        st = destino.lstat()
        self.assertFalse(stat.S_ISLNK(st.st_mode))
        self.assertTrue(stat.S_ISREG(st.st_mode))
        self.assertEqual(st.st_uid, 0)
        self.assertEqual(st.st_mode & (stat.S_IWGRP | stat.S_IWOTH), 0)
        self.assertNotIn(".transcentia", str(destino))
        self.assertNotIn("/Contents/", str(destino))
        texto = destino.read_text()
        self.assertTrue(texto.startswith("tuttidash-controle-v1\n"))
        self.assertIn("team 3QA76CY27W\n", texto)


if __name__ == "__main__":
    unittest.main()
