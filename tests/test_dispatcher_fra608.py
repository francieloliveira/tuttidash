"""FRA-608: lock do ciclo, PATH, retomada citada e permissões do dispatcher."""
import fcntl
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from xml.etree import ElementTree

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "lanes"))

import dispatcher as d  # noqa: E402


class ConsistenciaDispatcher(unittest.TestCase):
    def test_path_pospoe_diretorio_gravavel_e_binarios_sao_absolutos(self):
        gravavel = f"{Path.home()}/.local/bin"
        partes = d.TOOL_PATH.split(":")
        self.assertNotEqual(partes[0], gravavel)
        self.assertEqual(partes[-1], gravavel)
        self.assertLess(partes.index("/usr/bin"), partes.index(gravavel))
        for nome, caminho in (("git", d.GIT), ("gh", d.GH), ("tmux", d.TMUX)):
            self.assertTrue(os.path.isabs(caminho), nome)
            self.assertNotIn(f"{os.sep}.local{os.sep}bin{os.sep}", caminho + os.sep)
            self.assertFalse(caminho.endswith("/.local/bin/" + nome))

    def test_lock_impede_ciclo_concorrente_de_matar_sessao(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.object(d, "STATE_DIR", tmp), mock.patch.object(d, "_ciclo", return_value=7) as ciclo:
            self.assertEqual(d.run(False, False), 7)
            ciclo.assert_called_once()
        self.assertEqual(stat.S_IMODE(os.stat(tmp).st_mode), 0o700)
        lock = tmp / "dispatcher.lock"
        self.assertEqual(stat.S_IMODE(os.stat(lock).st_mode), 0o600)
        with mock.patch.object(d, "STATE_DIR", tmp), \
                mock.patch.object(d, "_ciclo", side_effect=AssertionError("entrou no ciclo")):
            fh = open(lock, "a")
            self.addCleanup(fh.close)
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(d.run(False, False), 0)
            fcntl.flock(fh, fcntl.LOCK_UN)

    def test_casa_transcentia_fica_0700(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        estado = tmp / ".transcentia" / "lanes"
        with mock.patch.object(d, "STATE_DIR", estado):
            d._apertar_casa()
        self.assertEqual(stat.S_IMODE(os.stat(estado).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(tmp / ".transcentia").st_mode), 0o700)

    def test_estado_grava_0600(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.object(d, "STATE_DIR", tmp):
            d.save_state("claude", {"card": "FRA-608"})
        arq = tmp / "lane-claude.json"
        self.assertEqual(stat.S_IMODE(os.stat(arq).st_mode), 0o600)
        self.assertIn("FRA-608", arq.read_text())

    def test_retomada_cita_sessao_e_recusa_id_do_log(self):
        self.assertTrue(d.sessao_citavel("01a11399-e338"))
        self.assertFalse(d.sessao_citavel("a;rm"))
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        log = tmp / "l.jsonl"
        log.write_text('{"session_id": "01a11399-e338"}\n', encoding="utf-8")
        linha = d.resume_line({"log": str(log), "lane": "claude", "worktree": "/tmp/a b"})
        self.assertIn("cd '/tmp/a b'", linha)
        self.assertIn("--resume 01a11399-e338", linha)
        self.assertNotIn(";", linha)
        log.write_text('{"session_id": "a;rm -rf /"}\n', encoding="utf-8")
        self.assertEqual(d.resume_line({"log": str(log), "lane": "claude", "worktree": "/w"}), "")

    def test_plists_umask_077_e_log_do_agente_sem_seguir_symlink(self):
        for nome in (
            "app.tuttidash.agente.dispatcher.plist",
            "app.tuttidash.agente.chave.plist",
            "app.tuttidash.agente.vigia.plist",
        ):
            arvore = ElementTree.parse(RAIZ / "apps/notch-mac/Resources/LaunchAgents" / nome)
            umask = None
            chave = None
            for el in arvore.getroot().iter():
                if el.tag == "key":
                    chave = el.text
                elif chave == "Umask" and el.tag == "integer":
                    umask = int(el.text)
                    break
            self.assertEqual(umask, 63, nome)
        agente = (RAIZ / "apps/notch-mac/Agente/agente.c").read_text(encoding="utf-8")
        self.assertIn("O_NOFOLLOW", agente)
        self.assertIn("0600", agente)
        self.assertNotIn("0644", agente)


if __name__ == "__main__":
    unittest.main()
