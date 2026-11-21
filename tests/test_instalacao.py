"""Instalação por projeto (FRA-698): serviço, artefato instalável e nenhuma.

Sem `/Applications`, sem app: destino, estado e logs ficam numa pasta temporária.
O que se prova aqui é o contrato do `gasto_lanes/instalar.py` que a tela e o vigia usam,
inclusive instalar uma versão de branch a partir de um worktree isolado.
"""
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from gasto_lanes import instalar
from gasto_lanes import projetos as P

ID = "00000000-0000-4000-8000-000000000698"

SERVIDOR = """
import http.server, json, sys
porta = int(sys.argv[sys.argv.index("--porta") + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        corpo = json.dumps({"versao": "9.9.9"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", porta), H).serve_forever()
"""


def porta_livre() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    n = s.getsockname()[1]
    s.close()
    return n


def git(cwd, *args) -> str:
    r = subprocess.run(["/usr/bin/git", "-C", str(cwd), *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"git {args} falhou: {r.stderr}")
    return r.stdout.strip()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="instalacao-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.pid = None

    def tearDown(self):
        if self.pid:
            instalar._sinal(int(self.pid), 15)
            time.sleep(0.2)
            instalar._sinal(int(self.pid), 9)

    def projeto(self, config=None):
        return P.Projeto(id=ID, nome="Projeto de teste", repo=str(self.repo), instalacao=config)

    def escrever(self, nome, texto, modo=0o755):
        arq = self.repo / nome
        arq.write_text(texto, encoding="utf-8")
        arq.chmod(modo)
        return arq

    def config_artefato(self):
        self.artefato = self.tmp / "pacote.txt"
        self.destino = self.tmp / "destino" / "pacote.txt"
        self.destino.parent.mkdir()
        return {
            "classe": "artefato",
            "instalar": [sys.executable, "-c",
                         "import shutil,sys; shutil.copy(sys.argv[1], sys.argv[2])",
                         str(self.artefato), str(self.destino)],
            "artefato": str(self.artefato),
            "destino": str(self.destino),
        }


class Servico(Base):
    def setUp(self):
        super().setUp()
        self.escrever("servidor.py", SERVIDOR)
        self.porta = porta_livre()
        self.cfg = {
            "classe": "servico",
            "subir": [sys.executable, "servidor.py", "--porta", "{porta}"],
            "porta": self.porta,
            "saude": "http://127.0.0.1:{porta}/saude",
            "url": "http://127.0.0.1:{porta}/",
        }

    def test_sobe_uma_vez_e_para(self):
        p = self.projeto(self.cfg)
        r = instalar.subir(p, home=self.home)
        self.assertTrue(r["ok"], r)
        st = r["estado"]
        self.assertEqual(st["situacao"], "rodando")
        self.assertEqual(st["versao"], "9.9.9")
        self.pid = st["pid"]
        self.assertEqual(st["porta"], self.porta)

        r2 = instalar.subir(p, home=self.home)
        self.assertTrue(r2["ok"])
        self.assertEqual(r2["estado"]["pid"], self.pid, "subir de novo não duplica o processo")

        self.pid = None
        r3 = instalar.parar(p, home=self.home)
        self.assertTrue(r3["ok"], r3)
        self.assertEqual(r3["estado"]["situacao"], "parado")
        self.assertFalse(instalar._vivo(st["pid"]))

    def test_estado_sem_subir_e_parado(self):
        st = instalar.estado(self.projeto(self.cfg), home=self.home)
        self.assertEqual(st["situacao"], "parado")
        self.assertEqual([a for a in st["acoes"]], ["subir", "parar"])


class Artefato(Base):
    def setUp(self):
        super().setUp()
        self.cfg = self.config_artefato()
        self.cfg.update({
            "empacotar": [sys.executable, "-c",
                          "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('pacote')",
                          str(self.artefato)],
            "validar": [sys.executable, "-c",
                        "import pathlib,sys; sys.exit(0 if pathlib.Path(sys.argv[1]).is_file() else 3)",
                        str(self.artefato)],
        })

    def test_empacotar_validar_instalar(self):
        p = self.projeto(self.cfg)
        r = instalar.empacotar(p, home=self.home)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["estado"]["situacao"], "empacotado")
        self.assertTrue(self.artefato.is_file())

        r = instalar.instalar(p, home=self.home)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["estado"]["situacao"], "instalado")
        self.assertTrue(self.destino.is_file())

    def test_falha_preserva_o_estado_anterior(self):
        p = self.projeto(self.cfg)
        self.assertTrue(instalar.empacotar(p, home=self.home)["ok"])
        self.assertTrue(instalar.instalar(p, home=self.home)["ok"])

        quebrado = dict(self.cfg, validar=[sys.executable, "-c", "import sys; sys.exit(4)"])
        r = instalar.validar(self.projeto(quebrado), home=self.home)
        self.assertFalse(r["ok"])
        self.assertIn("saiu 4", r["texto"])
        self.assertEqual(r["estado"]["situacao"], "instalado", "a falha não desinstala o que já estava")
        self.assertTrue(r["estado"]["erro"])

    def test_destino_que_some_aparece_como_nao_instalado(self):
        p = self.projeto(self.cfg)
        self.assertTrue(instalar.empacotar(p, home=self.home)["ok"])
        self.assertTrue(instalar.instalar(p, home=self.home)["ok"])
        self.destino.unlink()
        st = instalar.estado(p, home=self.home)
        self.assertEqual(st["situacao"], "não instalado")
        self.pid = None


class Nenhuma(Base):
    def test_estado_e_acoes(self):
        p = self.projeto(None)
        st = instalar.estado(p, home=self.home)
        self.assertEqual(st["situacao"], "nenhuma")
        self.assertEqual(st["acoes"], [])
        with self.assertRaises(instalar.ErroInstalacao):
            instalar.subir(p, home=self.home)

    def test_sem_instalacao_mesmo(self):
        st = instalar.estado(self.projeto({}), home=self.home)
        self.assertEqual(st["situacao"], "nenhuma")


class CadastroInvalido(Base):
    def test_classe_desconhecida(self):
        p = self.projeto({"classe": "container"})
        st = instalar.estado(p, home=self.home)
        self.assertEqual(st["situacao"], "cadastro inválido")
        self.assertIn("classe desconhecida", st["erro"])
        with self.assertRaises(instalar.ErroInstalacao):
            instalar.empacotar(p, home=self.home)

    def test_comando_com_aspas_sem_fechar(self):
        p = self.projeto({"classe": "servico", "subir": "python3 x.py 'sem fechar"})
        st = instalar.estado(p, home=self.home)
        self.assertEqual(st["situacao"], "cadastro inválido")

    def test_texto_vira_argv_sem_shell(self):
        e = instalar.de_projeto(self.projeto({"classe": "servico", "subir": 'python3 x.py "a b"'}))
        self.assertEqual(e.subir, ("python3", "x.py", "a b"))


class Trava(Base):
    def test_lane_no_projeto_recusa_e_aparece_no_estado(self):
        lanes = self.home / ".transcentia" / "lanes"
        lanes.mkdir(parents=True)
        (lanes / "lane-opencode.json").write_text(json.dumps({"projeto": ID}), encoding="utf-8")
        p = self.projeto({
            "classe": "artefato",
            "empacotar": [sys.executable, "-c", "import sys; sys.exit(0)"],
            "instalar": [sys.executable, "-c", "import sys; sys.exit(0)"],
            "destino": str(self.tmp / "destino"),
        })
        st = instalar.estado(p, home=self.home)
        self.assertIn("lane rodando no projeto", st["bloqueio"])
        self.assertIn("opencode", st["bloqueio"])
        with self.assertRaises(instalar.ErroInstalacao):
            instalar.empacotar(p, home=self.home)

    def test_lane_de_outro_projeto_nao_trava(self):
        lanes = self.home / ".transcentia" / "lanes"
        lanes.mkdir(parents=True)
        (lanes / "lane-claude.json").write_text(json.dumps({"projeto": "outro"}), encoding="utf-8")
        p = self.projeto({"classe": "artefato", "empacotar": [sys.executable, "-c", "print('ok')"]})
        self.assertEqual(instalar.bloqueio(p, home=self.home), "")
        self.assertTrue(instalar.empacotar(p, home=self.home)["ok"])


class Versoes(Base):
    """`refs` e `instalar --ref`: qualquer branch ou tag, em worktree isolado."""

    def setUp(self):
        super().setUp()
        self.origem = self.tmp / "origem.git"
        git(self.tmp, "init", "--bare", "-q", str(self.origem))
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "teste@local")
        git(self.repo, "config", "user.name", "Teste")
        (self.repo / "versao.txt").write_text("main\n", encoding="utf-8")
        git(self.repo, "add", "versao.txt")
        git(self.repo, "commit", "-q", "-m", "main")
        git(self.repo, "remote", "add", "origin", str(self.origem))
        git(self.repo, "push", "-q", "-u", "origin", "main")
        git(self.repo, "checkout", "-q", "-b", "feature/nova")
        (self.repo / "versao.txt").write_text("feature\n", encoding="utf-8")
        git(self.repo, "commit", "-q", "-am", "feature")
        self.head_feature = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "push", "-q", "origin", "feature/nova")
        git(self.repo, "tag", "-a", "v1.0", "-m", "v1.0")
        git(self.repo, "push", "-q", "origin", "v1.0")
        git(self.repo, "checkout", "-q", "main")

        self.cfg = {
            "classe": "artefato",
            "empacotar": [sys.executable, "-c",
                          "import shutil,sys; shutil.copy(sys.argv[1], sys.argv[2])",
                          "{worktree}/versao.txt", "{artefato}"],
            "validar": [sys.executable, "-c",
                        "import pathlib,sys; texto=pathlib.Path(sys.argv[1]).read_text().strip(); "
                        "sys.exit(0 if texto == 'feature' else 5)", "{artefato}"],
            "instalar": [sys.executable, "-c",
                         "import pathlib,shutil,sys; shutil.copy(sys.argv[1], sys.argv[2])",
                         "{artefato}", "{destino}"],
            "artefato": str(self.tmp / "pacote.txt"),
            "destino": str(self.tmp / "destino.txt"),
        }

    def test_refs_lista_branches_e_tags_com_main_primeiro(self):
        r = instalar.refs(self.projeto(self.cfg))
        self.assertTrue(r["ok"])
        self.assertEqual(r["branches"][0], "main")
        self.assertIn("feature/nova", r["branches"])
        self.assertIn("v1.0", r["tags"])
        self.assertEqual(r["erro"], "")

    def test_refs_sem_origin_sempre_oferece_main(self):
        p = self.projeto(self.cfg)
        self.repo = self.tmp / "sem-origin"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        r = instalar.refs(self.projeto(self.cfg))
        self.assertIn("main", r["branches"])
        self.assertTrue(r["erro"], "sem origin, o motivo fica visível na tela")

    def test_instala_branch_em_worktree_isolado(self):
        p = self.projeto(self.cfg)
        r = instalar.instalar(p, ref="feature/nova", home=self.home)
        self.assertTrue(r["ok"], r)
        st = r["estado"]
        self.assertEqual(st["situacao"], "instalado")
        self.assertEqual(st["ref"], "feature/nova")
        self.assertEqual(st["head"], self.head_feature)
        self.assertEqual(Path(self.cfg["destino"]).read_text().strip(), "feature")
        wt = Path(st["worktree"]).resolve()
        self.assertNotEqual(wt, self.repo.resolve())
        self.assertTrue(wt.is_relative_to((self.tmp / "repo-worktrees").resolve()),
                        f"worktree fora da pasta de worktrees: {wt}")
        # o checkout principal não foi tocado
        self.assertEqual((self.repo / "versao.txt").read_text().strip(), "main")

    def test_instala_tag(self):
        r = instalar.instalar(self.projeto(self.cfg), ref="v1.0", home=self.home)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["estado"]["head"], self.head_feature)

    def test_ref_instala_com_o_checkout_principal_no_ambiente(self):
        cfg = dict(self.cfg)
        cfg["instalar"] = [sys.executable, "-c",
                           "import os,pathlib,sys; pathlib.Path(sys.argv[1]).write_text("
                           "os.environ.get('TUTTIDASH_REPO_MAIN', '') + '|' + "
                           "os.environ.get('TUTTIDASH_REF', ''))", "{destino}"]
        r = instalar.instalar(self.projeto(cfg), ref="feature/nova", home=self.home)
        self.assertTrue(r["ok"], r)
        principal, ref = Path(cfg["destino"]).read_text().split("|")
        self.assertEqual(ref, "feature/nova")
        self.assertEqual(Path(principal).resolve(), self.repo.resolve(),
                         "o comando precisa saber onde estão os dados locais do build")

    def test_branch_inexistente_recusa_sem_instalar(self):
        with self.assertRaises(instalar.ErroInstalacao):
            instalar.instalar(self.projeto(self.cfg), ref="nao-existe", home=self.home)
        self.assertFalse(Path(self.cfg["destino"]).exists())

    def test_ref_com_caractere_recusado(self):
        for ruim in ("-x", "a b", "a;b", "a$b", "a\nb"):
            with self.assertRaises(instalar.ErroInstalacao):
                instalar.validar_ref(ruim)
        self.assertEqual(instalar.validar_ref(" feature/nova "), "feature/nova")


class Cli(unittest.TestCase):
    def test_uso_invalido_nao_quebra(self):
        self.assertEqual(instalar.main(["estado", "--projeto", "nao-existe", "--json"]), 2)

    def test_ref_so_vale_para_instalar(self):
        self.assertEqual(instalar.main(["subir", "--projeto", "nao-existe", "--ref", "main", "--json"]), 2)


if __name__ == "__main__":
    unittest.main()
