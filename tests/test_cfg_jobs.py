"""cfg migrate: jobs com script em ~/.transcentia passam para o bundle (FRA-613).

Sem isso o app recusa o caminho antigo e os agentes somem dos Ajustes.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
CFG = RAIZ / "tools" / "cfg"
CONTROLE = "/Applications/TuttiDash.app/Contents/Resources/controle/"


class MigraScriptsDosJobs(unittest.TestCase):
    def _migrar(self, montar_jobs):
        """`montar_jobs(home)` devolve os jobs gravados antes do `cfg migrate`."""
        with tempfile.TemporaryDirectory() as bruto:
            home = Path(bruto)
            arq = home / "Library" / "Application Support" / "TuttiDash" / "config.json"
            arq.parent.mkdir(parents=True)
            jobs = montar_jobs(home)
            arq.write_text(json.dumps({"version": 1, "agendas": {"jobs": jobs}}), encoding="utf-8")
            env = {**os.environ, "HOME": str(home)}
            env.pop("TRANSCENTIA_GASTO_CONFIG", None)
            subprocess.run([str(CFG), "migrate"], env=env, check=True, capture_output=True)
            return json.loads(arq.read_text(encoding="utf-8"))["agendas"]["jobs"]

    def test_scripts_antigos_vao_para_o_bundle(self):
        jobs = self._migrar(lambda home: [
            {"label": "com.transcentia.lanes.dispatcher", "script": "~/.transcentia/lanes/dispatcher.py",
             "argumentos": ["--real"]},
            {"label": "com.transcentia.bots.watch", "script": "~/.transcentia/bots/watch.py"},
            {"label": "com.transcentia.bots.chave", "script": "~/.transcentia/tools/bots-chave"},
        ])
        self.assertEqual([j["script"] for j in jobs], [
            CONTROLE + "lanes/dispatcher.py", CONTROLE + "bots/watch.py", CONTROLE + "tools/bots-chave"])
        self.assertEqual(jobs[0]["argumentos"], ["--real"])

    def test_caminho_absoluto_do_home_tambem_migra(self):
        jobs = self._migrar(lambda home: [
            {"label": "com.transcentia.bots.watch", "script": str(home / ".transcentia" / "bots" / "watch.py")},
        ])
        self.assertEqual(jobs[0]["script"], CONTROLE + "bots/watch.py")

    def test_script_proprio_nao_muda(self):
        jobs = self._migrar(lambda home: [{"label": "com.exemplo.meu", "script": "~/scripts/meu.py"}])
        self.assertEqual(jobs[0]["script"], "~/scripts/meu.py")


if __name__ == "__main__":
    unittest.main()
