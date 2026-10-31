"""FRA-600: contrato do lane-*.json e do sinal em proof_pid / caffeinate.pid.

Sem Linear e sem rede. A prova do projeto entra por `tests.test_lane_json`.
"""
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))

import dispatcher as d


class EstadoLaneJson(unittest.TestCase):
    def setUp(self):
        self.assertIn("claude", d.LANES)
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = self.tmp / "state"
        self.logs = self.tmp / "logs"
        self.wts = self.tmp / "worktrees"
        self.state.mkdir()
        self.logs.mkdir()
        self.wts.mkdir()
        self.antes = (d.STATE_DIR, d.LOG_DIR, d.LOG_FILE)
        d.STATE_DIR = self.state
        d.LOG_DIR = self.logs
        d.LOG_FILE = self.logs / "lanes-dispatcher.log"
        self.addCleanup(self._restaura)
        self.wt = self.wts / "fra-600"
        self._git_init(self.wt)
        (self.wt / ".lane").mkdir()
        self.base = self._rev(self.wt)
        self.log_path = self.logs / "lanes" / "FRA-600-claude-1.jsonl"
        self.log_path.parent.mkdir()
        self.log_path.write_text("", encoding="utf-8")
        self.st = {
            "lane": "claude",
            "card": "FRA-600",
            "issue_id": "issue-600",
            "title": "t",
            "url": "u",
            "branch": "francieltechnix/fra-600-seguranca",
            "worktree": str(self.wt),
            "base": self.base,
            "effort": "medio",
            "started": time.time(),
            "started_at": "2026-10-31 00:00:00",
            "log": str(self.log_path),
            "session": "lane-claude",
        }
        d.save_state("claude", self.st)
        d.gravar_claim("claude", self.st)
        self.patch = mock.patch.object(d, "projeto_worktrees", return_value=self.wts)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.procs = []
        self.addCleanup(self._mata)

    def _restaura(self):
        d.STATE_DIR, d.LOG_DIR, d.LOG_FILE = self.antes

    def _mata(self):
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    try:
                        proc.kill()
                    except OSError:
                        pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass

    def _vigiar(self, proc):
        self.procs.append(proc)
        return proc

    def _git(self, wt: Path, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=wt, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def _git_init(self, wt: Path) -> None:
        wt.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(wt)], check=True)
        self._git(wt, "config", "user.email", "t@example.com")
        self._git(wt, "config", "user.name", "t")
        (wt / "a.txt").write_text("a\n", encoding="utf-8")
        self._git(wt, "add", "a.txt")
        self._git(wt, "commit", "-q", "-m", "i")

    def _rev(self, wt: Path) -> str:
        return self._git(wt, "rev-parse", "HEAD")

    def test_estado_legitimo_passa_e_save_state_le_de_volta(self):
        self.assertIsNone(d.motivo_recusa_estado("claude", d.load_state("claude")))
        d.save_state("claude", dict(self.st, window_ok=True))
        lido = d.load_state("claude")
        self.assertEqual(lido["issue_id"], "issue-600")
        self.assertEqual(lido["base"], self.base)
        self.assertTrue(lido["window_ok"])
        self.assertIsNone(d.motivo_recusa_estado("claude", lido))
        self.assertEqual(d.ler_claim("claude")["issue_id"], "issue-600")
        self.assertFalse(any(p.name.endswith(".tmp") for p in self.state.rglob("*")))

    def test_save_state_minimo_ainda_le_de_volta(self):
        d.save_state("claude", {"card": "FRA-1"})
        self.assertEqual(d.load_state("claude"), {"card": "FRA-1"})
        self.assertFalse(any(p.name.endswith(".tmp") for p in self.state.iterdir()))

    def test_worktree_fora_da_pasta(self):
        fora = self.tmp / "outro"
        fora.mkdir()
        motivo = d.motivo_recusa_estado("claude", dict(self.st, worktree=str(fora)))
        self.assertIn("worktree", motivo)

    def test_worktree_symlink_escapa(self):
        alvo = self.tmp / "fora-link"
        alvo.mkdir()
        link = self.wts / "atalho"
        link.symlink_to(alvo, target_is_directory=True)
        motivo = d.motivo_recusa_estado("claude", dict(self.st, worktree=str(link)))
        self.assertIn("worktree", motivo)

    def test_worktree_de_outro_card_dentro_da_pasta(self):
        outro = self.wts / "fra-1"
        subprocess.run(["git", "clone", "-q", str(self.wt), str(outro)], check=True, capture_output=True)
        motivo = d.motivo_recusa_estado("claude", dict(self.st, worktree=str(outro)))
        self.assertIn("worktree", motivo)

    def test_sessao_forjada(self):
        self.assertIn("sessão", d.motivo_recusa_estado("claude", dict(self.st, session="outra")))
        self.assertIn("sessão", d.motivo_recusa_estado("claude", dict(self.st, session="lane-grok")))

    def test_issue_id_forjado(self):
        motivo = d.motivo_recusa_estado("claude", dict(self.st, issue_id="outro-issue"))
        self.assertIn("issue_id", motivo)
        self.assertIn("claim", motivo)

    def test_base_forjada(self):
        self.assertIn("base", d.motivo_recusa_estado("claude", dict(self.st, base="deadbeef")))
        (self.wt / "b.txt").write_text("b\n", encoding="utf-8")
        self._git(self.wt, "add", "b.txt")
        self._git(self.wt, "commit", "-q", "-m", "dois")
        outro = self._rev(self.wt)
        self.assertNotEqual(outro, self.base)
        self.assertIn("base", d.motivo_recusa_estado("claude", dict(self.st, base=outro)))

    def test_log_forjado(self):
        fora = self.tmp / "segredo.log"
        fora.write_text("x", encoding="utf-8")
        self.assertIn("log", d.motivo_recusa_estado("claude", dict(self.st, log=str(fora))))
        outro = self.logs / "lanes" / "outro.jsonl"
        outro.write_text("x", encoding="utf-8")
        self.assertIn("log", d.motivo_recusa_estado("claude", dict(self.st, log=str(outro))))

    def test_card_e_branch_invalidos(self):
        self.assertIn("card", d.motivo_recusa_estado("claude", dict(self.st, card="../FRA-1")))
        self.assertIn("card", d.motivo_recusa_estado("claude", dict(self.st, card="FRA-")))
        self.assertIn("branch", d.motivo_recusa_estado("claude", dict(self.st, branch="a b")))
        self.assertIn("branch", d.motivo_recusa_estado("claude", dict(self.st, branch="-evil")))
        self.assertIn("branch", d.motivo_recusa_estado("claude", dict(self.st, branch="foo/../../x")))

    def _watch_nao_age(self, texto: str):
        (self.state / "lane-claude.json").write_text(texto, encoding="utf-8")
        with mock.patch.object(d, "finalize") as fin, \
                mock.patch.object(d, "kill_lane_tree") as kill, \
                mock.patch.object(d, "linear") as linear, \
                mock.patch.object(d, "mudar_estado") as mover, \
                mock.patch.object(d, "aplicar_label") as label, \
                mock.patch.object(d, "sh") as sh:
            d.watch("claude", d.load_state("claude"))
        fin.assert_not_called()
        kill.assert_not_called()
        linear.assert_not_called()
        mover.assert_not_called()
        label.assert_not_called()
        sh.assert_not_called()
        log = d.LOG_FILE.read_text(encoding="utf-8")
        self.assertIn("não fecho, não mato sessão, não movo o card", log)
        self.assertTrue((self.state / "lane-claude.json").exists())

    def test_json_invalido_nao_fecha_nem_mata_nem_move(self):
        self._watch_nao_age("{")
        self.assertIn("json inválido", d.LOG_FILE.read_text(encoding="utf-8"))

    def test_estado_forjado_nao_fecha_nem_mata_nem_move(self):
        bruto = dict(self.st, session="sessao-alheia", issue_id="outro",
                     worktree="/tmp", base="deadbeef", log="/tmp/x")
        self._watch_nao_age(json.dumps(bruto))

    def test_kill_recusa_sessao_que_nao_e_da_lane(self):
        self.assertTrue(d.sessao_de_lane("lane-claude"))
        self.assertFalse(d.sessao_de_lane("lane-nao-existe"))
        self.assertFalse(d.sessao_de_lane("sessao-alheia"))
        with mock.patch.object(d, "sh") as sh:
            for nome in ("sessao-alheia", "lane-nao-existe", "", "lane-claude;rm"):
                d.kill_lane_tree(nome)
            sh.assert_not_called()
        self.assertIn("não é lane-<lane>", d.LOG_FILE.read_text(encoding="utf-8"))

    def test_proof_pid_forjado_nao_sinaliza(self):
        vitima = self._vigiar(subprocess.Popen(
            ["sleep", "30"], start_new_session=True,
        ))
        foto = d.foto_processo(vitima.pid)
        self.assertIsNotNone(foto)
        (self.wt / ".lane" / "proof_pid").write_text(str(vitima.pid), encoding="utf-8")
        path = d.arquivo_prova_proc(self.wt)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(foto), encoding="utf-8")
        d.matar_prova(self.wt)
        self.assertTrue(d.prova_viva(vitima.pid))
        self.assertIn("não sinalizo", d.LOG_FILE.read_text(encoding="utf-8"))

    def test_proof_registrada_mata_o_bash_e_nao_a_vitima(self):
        vitima = self._vigiar(subprocess.Popen(["sleep", "30"], start_new_session=True))
        bash_cmd = f"cd {shlex.quote(str(self.wt))} && sleep 30 > .lane/proof.log 2>&1"
        bash = self._vigiar(subprocess.Popen(
            ["/bin/bash", "-c", bash_cmd], cwd=self.wt, start_new_session=True,
        ))
        time.sleep(0.2)
        self.assertIsNotNone(d.registrar_prova(self.wt, bash.pid))
        (self.wt / ".lane" / "proof_pid").write_text(str(vitima.pid), encoding="utf-8")
        d.matar_prova(self.wt)
        self.assertTrue(d.prova_viva(vitima.pid))
        self.assertFalse(d.prova_viva(bash.pid))

    def test_caffeinate_pid_forjado_nao_sinaliza(self):
        vitima = self._vigiar(subprocess.Popen(["sleep", "30"], start_new_session=True))
        foto = d.foto_processo(vitima.pid)
        self.assertIsNotNone(foto)
        d.arquivo_caffeinate().write_text(json.dumps(foto), encoding="utf-8")
        self.assertFalse(d.encerrar_caffeinate(d.ler_caffeinate()))
        self.assertTrue(d.prova_viva(vitima.pid))

    def test_caffeinate_antigo_so_numero_nao_sinaliza(self):
        vitima = self._vigiar(subprocess.Popen(["sleep", "30"], start_new_session=True))
        d.arquivo_caffeinate().write_text(str(vitima.pid), encoding="utf-8")
        self.assertIsNone(d.ler_caffeinate())
        d.keep_awake(False)
        self.assertTrue(d.prova_viva(vitima.pid))
        self.assertFalse(d.arquivo_caffeinate().exists())

    def test_caffeinate_confere_e_sinaliza(self):
        proc = self._vigiar(subprocess.Popen(
            [d.CAFFEINATE_BIN, "-i", "-s", "-t", str(d.CAFFEINATE_SECONDS)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        ))
        foto = d.foto_processo(proc.pid)
        self.assertIsNotNone(foto)
        self.assertTrue(d.comando_e_caffeinate(foto["command"]), foto["command"])
        self.assertTrue(d.encerrar_caffeinate(foto))
        proc.wait(timeout=5)
        self.assertFalse(d.prova_viva(proc.pid))


if __name__ == "__main__":
    unittest.main()
