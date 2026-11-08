"""reinstalar-app.sh: lane encerrada (sessão de pé, sem card) não segura a troca do app."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "reinstalar-app.sh"


class LanesRodando(unittest.TestCase):
    def _contar(self, sessoes, estados):
        tmp = Path(tempfile.mkdtemp())
        tmux = tmp / "tmux"
        tmux.write_text("#!/bin/sh\nprintf '%s\\n' " + " ".join(sessoes) + "\n")
        tmux.chmod(0o755)
        state = tmp / "state"
        state.mkdir()
        for e in estados:
            (state / f"{e}.json").write_text("{}")
        corpo = re.search(r"^lanes_rodando\(\) \{.*?^\}", SCRIPT.read_text(encoding="utf-8"), re.S | re.M).group(0)
        r = subprocess.run(["bash", "-c", corpo + "\nlanes_rodando"], capture_output=True, text=True,
                           env={**os.environ, "TMUX_BIN": str(tmux), "STATE": str(state)})
        return r.stdout.strip()

    def test_sessao_encerrada_nao_conta(self):
        self.assertEqual(self._contar(["lane-deepseek", "lane-opencode", "painel"], []), "0")

    def test_lane_com_card_conta(self):
        self.assertEqual(self._contar(["lane-deepseek", "lane-opencode", "lanes"], ["lane-opencode"]), "1")

    def test_sem_tmux(self):
        self.assertEqual(self._contar([], ["lane-x"]), "0")


if __name__ == "__main__":
    unittest.main()
