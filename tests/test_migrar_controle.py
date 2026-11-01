"""FRA-617: migração em HOME isolado, com rollback se a âncora não confere.

Instalação limpa e atualização de uma instalação antiga. O dispatcher e o
vigia sobem pelo tuttidash-agente do bundle. O script antigo não pega card.
Chave desligada não é religada. PAUSE e enabled ficam como estavam.
"""
import json
import os
import plistlib
import shutil
import stat
import subprocess
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PYTHON = "/usr/bin/python3"
AGENTE_C = ROOT / "apps" / "notch-mac" / "Agente" / "agente.c"
MIGRAR = ROOT / "tools" / "migrar-controle.py"
INTEGRIDADE = ROOT / "tools" / "integridade-controle.py"

FAKE = textwrap.dedent("""\
    #!/usr/bin/env python3
    import json, os, sys
    from pathlib import Path
    p = Path(os.environ["LAUNCHCTL_ESTADO"])
    st = json.loads(p.read_text())
    args = sys.argv[1:]
    st.setdefault("calls", []).append(args)
    cmd = args[0] if args else ""

    def label_de(arg):
        return arg.rsplit("/", 1)[-1].replace(".plist", "")

    if cmd == "print" and len(args) >= 2:
        lab = label_de(args[1])
        p.write_text(json.dumps(st))
        if lab in st.get("loaded", []):
            print("state = not running")
            raise SystemExit(0)
        raise SystemExit(113)
    if cmd == "print-disabled":
        for lab in st.get("disabled", []):
            print('"%s" => disabled' % lab)
        p.write_text(json.dumps(st))
        raise SystemExit(0)
    if cmd == "bootout" and len(args) >= 2:
        lab = label_de(args[1])
        st["loaded"] = [x for x in st.get("loaded", []) if x != lab]
        p.write_text(json.dumps(st))
        raise SystemExit(0)
    if cmd == "bootstrap" and len(args) >= 3:
        lab = label_de(args[2])
        loaded = st.setdefault("loaded", [])
        if lab not in loaded:
            loaded.append(lab)
        p.write_text(json.dumps(st))
        raise SystemExit(0)
    if cmd == "enable" and len(args) >= 2:
        lab = label_de(args[1])
        st["disabled"] = [x for x in st.get("disabled", []) if x != lab]
        st.setdefault("enabled", []).append(lab)
        p.write_text(json.dumps(st))
        raise SystemExit(0)
    p.write_text(json.dumps(st))
    raise SystemExit(0)
""")


def _compilador():
    return shutil.which("clang") or shutil.which("gcc")


def _escrever(caminho: Path, texto: str, modo: int = 0o755) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_text(texto)
    caminho.chmod(modo)


class MigracaoHome(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self._mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.card = self.tmp / "card-pegou"
        self.app = self.tmp / "TuttiDash.app"
        self.controle = self.app / "Contents" / "Resources" / "controle"
        self.binario = self.app / "Contents" / "MacOS" / "tuttidash-agente"
        self.ancora = self.tmp / "ancora" / "controle.sha256"
        self.estado = self.tmp / "launchctl.json"
        self.fake = self.tmp / "launchctl"
        _escrever(self.fake, FAKE, 0o755)
        self.estado.write_text(json.dumps({"loaded": [], "disabled": [], "calls": []}))
        cc = _compilador()
        if not cc:
            self.skipTest("sem compilador C")
        self.binario.parent.mkdir(parents=True)
        r = subprocess.run(
            [cc, "-O2", "-Wall", "-Wextra", "-Werror",
             "-DTUTTIDASH_INTEGRIDADE_TESTE", "-DTUTTIDASH_PULAR_ASSINATURA",
             "-o", str(self.binario), str(AGENTE_C)],
            capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.binario.chmod(0o755)
        _escrever(self.controle / "lanes" / "dispatcher.py", "print('bundle-dispatcher')\n")
        _escrever(self.controle / "bots" / "watch.py", "print('bundle-vigia')\n")
        self.ancora.parent.mkdir()
        self.ancora.parent.chmod(0o755)
        subprocess.run(
            [PYTHON, str(INTEGRIDADE), "gerar", str(self.controle), str(self.ancora)],
            check=True, capture_output=True, text=True)
        self.ancora.chmod(0o644)

    def _mkdtemp(self):
        import tempfile
        return tempfile.mkdtemp(prefix="fra617-")

    def _env(self):
        return {
            **os.environ,
            "HOME": str(self.home),
            "FRA617_CARD": str(self.card),
            "TUTTIDASH_AGENTE": str(self.binario),
            "TUTTIDASH_CONTROLE": str(self.controle),
            "TUTTIDASH_INTEGRIDADE_ARQUIVO": str(self.ancora),
            "TUTTIDASH_LAUNCHCTL": str(self.fake),
            "LAUNCHCTL_ESTADO": str(self.estado),
        }

    def _aplicar(self):
        return subprocess.run(
            [PYTHON, str(MIGRAR), "aplicar"],
            cwd=self.tmp, env=self._env(),
            capture_output=True, text=True, timeout=30)

    def _calls(self):
        return json.loads(self.estado.read_text()).get("calls", [])

    def _rodar(self, papel: str):
        return subprocess.run(
            [str(self.binario), papel],
            cwd=self.tmp, env=self._env(),
            capture_output=True, text=True, timeout=20)

    def _log(self, nome: str) -> str:
        caminho = self.home / "Library" / "Logs" / "TranscentIA" / nome
        if not caminho.is_file():
            return ""
        return caminho.read_text()

    def _plant_antigo(self, rel: str, corpo: str, modo: int = 0o755) -> Path:
        destino = self.home.joinpath(*rel.split("/"))
        _escrever(destino, corpo, modo)
        return destino

    def _script_que_pega_card(self, marca: str) -> str:
        return textwrap.dedent(f"""\
            import os
            p = os.environ.get("FRA617_CARD", "")
            if p:
                open(p, "a").write({marca!r} + "\\n")
            """)

    def test_lista_igual_a_do_app(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("migrar_controle", MIGRAR)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        swift = (ROOT / "apps/notch-mac/Sources/GastoCore/MigracaoControle.swift").read_text()
        for rel in mod.COPIAS_ANTIGAS:
            self.assertIn(f'"{rel}"', swift)
        self.assertNotIn('".transcentia/tools/config.py"', swift)
        self.assertNotIn('".transcentia/bots/PAUSE"', swift)

    def test_instalacao_limpa_sobe_dispatcher_e_vigia(self):
        pause = self.home / ".transcentia" / "bots" / "PAUSE"
        _escrever(pause, "ligado-nao-mexer\n", 0o644)
        r = self._aplicar()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse(self.card.exists())
        self.assertEqual(pause.read_text(), "ligado-nao-mexer\n")
        calls = self._calls()
        self.assertFalse(any(c and c[0] == "enable" for c in calls))
        boot = [c[2] for c in calls if c and c[0] == "bootstrap"]
        self.assertTrue(any(p.endswith("com.transcentia.lanes.dispatcher.plist") for p in boot))
        self.assertTrue(any(p.endswith("com.transcentia.bots.watch.plist") for p in boot))
        for papel, log in (("dispatcher", "lanes-dispatcher.launchd.log"), ("vigia", "bots-watch.launchd.log")):
            rodou = self._rodar(papel)
            self.assertEqual(rodou.returncode, 0, rodou.stderr)
            self.assertIn(f"bundle-{papel}", self._log(log))
        self.assertFalse(self.card.exists())
        dispatcher = self.home / "Library" / "LaunchAgents" / "com.transcentia.lanes.dispatcher.plist"
        args = plistlib.loads(dispatcher.read_bytes())["ProgramArguments"]
        self.assertEqual(args, [str(self.binario), "dispatcher"])
        self.assertNotIn(".transcentia", " ".join(args))

    def test_atualiza_instalacao_antiga_sem_reativar_chave(self):
        pause = self.home / ".transcentia" / "bots" / "PAUSE"
        config = self.home / ".transcentia" / "tools" / "config.json"
        _escrever(pause, "pause-continua\n", 0o644)
        _escrever(config, '{"enabled": false}\n', 0o644)
        self._plant_antigo(".transcentia/lanes/dispatcher.py", self._script_que_pega_card("dispatcher"))
        self._plant_antigo(".transcentia/bots/watch.py", self._script_que_pega_card("vigia"))
        self._plant_antigo(".transcentia/tools/bots-chave", self._script_que_pega_card("chave"))
        alvo = self.tmp / "fora" / "lane_view.py"
        _escrever(alvo, self._script_que_pega_card("link"), 0o644)
        link = self.home / ".transcentia" / "lanes" / "lane_view.py"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(alvo)
        chave = self.home / "Library" / "LaunchAgents" / "com.transcentia.bots.chave.plist"
        chave.parent.mkdir(parents=True, exist_ok=True)
        chave.write_bytes(plistlib.dumps({
            "Label": "com.transcentia.bots.chave",
            "ProgramArguments": ["/usr/bin/python3", str(self.home / ".transcentia/tools/bots-chave")],
            "Disabled": True,
            "RunAtLoad": True,
        }))
        self.estado.write_text(json.dumps({
            "loaded": ["com.transcentia.lanes.dispatcher", "com.transcentia.bots.watch"],
            "disabled": ["com.transcentia.bots.chave"],
            "calls": [],
        }))
        r = self._aplicar()
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn("AVISO: cópia antiga aposentada:", r.stdout)
        self.assertIn(str(self.home / ".transcentia/lanes/dispatcher.py"), r.stdout)
        self.assertFalse((self.home / ".transcentia/lanes/dispatcher.py").exists())
        self.assertFalse((self.home / ".transcentia/bots/watch.py").exists())
        self.assertFalse((self.home / ".transcentia/tools/bots-chave").exists())
        self.assertFalse(link.exists())
        self.assertFalse(link.is_symlink())
        self.assertIn("link", alvo.read_text())
        self.assertEqual(pause.read_text(), "pause-continua\n")
        self.assertEqual(config.read_text(), '{"enabled": false}\n')
        self.assertFalse(self.card.exists())
        calls = self._calls()
        self.assertFalse(any(c and c[0] == "enable" for c in calls))
        boot = [c[2] for c in calls if c and c[0] == "bootstrap"]
        self.assertTrue(any("lanes.dispatcher.plist" in p for p in boot))
        self.assertTrue(any("bots.watch.plist" in p for p in boot))
        self.assertFalse(any("bots.chave.plist" in p for p in boot))
        chave_obj = plistlib.loads(chave.read_bytes())
        self.assertEqual(chave_obj["ProgramArguments"], [str(self.binario), "chave"])
        self.assertIs(chave_obj["Disabled"], True)
        for papel, log in (("dispatcher", "lanes-dispatcher.launchd.log"), ("vigia", "bots-watch.launchd.log")):
            rodou = self._rodar(papel)
            self.assertEqual(rodou.returncode, 0, rodou.stderr)
            self.assertIn(f"bundle-{papel}", self._log(log))
        self.assertFalse(self.card.exists(), "lane pegou card do script antigo")
        aposentado = next((self.home / ".transcentia" / "aposentados").rglob("dispatcher.py"))
        self.assertEqual(stat.S_IMODE(aposentado.stat().st_mode) & 0o111, 0)
        self.assertIn("dispatcher", aposentado.read_text())

    def test_verificacao_falha_faz_rollback(self):
        pause = self.home / ".transcentia" / "bots" / "PAUSE"
        _escrever(pause, "pause-rollback\n", 0o644)
        antigo = self._plant_antigo(
            ".transcentia/lanes/dispatcher.py", self._script_que_pega_card("dispatcher"), 0o755)
        conteudo = antigo.read_text()
        modo = stat.S_IMODE(antigo.stat().st_mode)
        plist = self.home / "Library" / "LaunchAgents" / "com.transcentia.lanes.dispatcher.plist"
        original = plistlib.dumps({
            "Label": "com.transcentia.lanes.dispatcher",
            "ProgramArguments": ["/usr/bin/python3", str(antigo)],
        })
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(original)
        alvo = self.tmp / "fora" / "view.py"
        _escrever(alvo, "print('alvo')\n", 0o644)
        link = self.home / ".transcentia" / "lanes" / "lane_view.py"
        link.symlink_to(alvo)
        self.estado.write_text(json.dumps({
            "loaded": ["com.transcentia.lanes.dispatcher"],
            "disabled": ["com.transcentia.bots.chave"],
            "calls": [],
        }))
        self.ancora.write_text(
            "tuttidash-controle-v1\n"
            "team 3QA76CY27W\n"
            + ("ab" * 32)
            + " lanes/dispatcher.py\n"
        )
        r = self._aplicar()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ROLLBACK:", r.stdout)
        self.assertIn("estado anterior restaurado", r.stdout)
        self.assertEqual(antigo.read_text(), conteudo)
        self.assertEqual(stat.S_IMODE(antigo.stat().st_mode), modo)
        self.assertEqual(plist.read_bytes(), original)
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(alvo))
        self.assertEqual(alvo.read_text(), "print('alvo')\n")
        self.assertEqual(pause.read_text(), "pause-rollback\n")
        self.assertFalse(self.card.exists())
        calls = self._calls()
        self.assertFalse(any(c and c[0] == "enable" for c in calls))
        st = json.loads(self.estado.read_text())
        self.assertIn("com.transcentia.lanes.dispatcher", st["loaded"])
        self.assertIn("com.transcentia.bots.chave", st["disabled"])
        self.assertFalse((self.home / ".transcentia" / "aposentados").exists()
                         and any((self.home / ".transcentia" / "aposentados").rglob("dispatcher.py")))


if __name__ == "__main__":
    unittest.main()
