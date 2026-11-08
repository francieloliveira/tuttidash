"""FRA-618: modo bancada (comando `bancada` e perfil da lane)."""
import io
import json
import os
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ / "lanes"))
sys.path.insert(0, str(RAIZ / "gasto_lanes"))
import bancada as b  # noqa: E402
import projetos  # noqa: E402


class Proj:
    def __init__(self, worktrees, bancada=True, ativo=True):
        self.worktrees = Path(worktrees)
        self.bancada = bancada
        self.ativo = ativo


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, True))
        self.raiz = self.tmp / "app-worktrees"
        self.wt = self.raiz / "fra-539"
        (self.wt / "fw").mkdir(parents=True)
        self.fw = self.wt / "fw" / "app.bin"
        self.fw.write_bytes(b"\xe9" * 1024)
        self.proj = [Proj(self.raiz)]


class WorktreeDoCard(Base):
    def test_dentro_do_projeto_com_bancada(self):
        self.assertEqual(b.worktree_do_card(self.wt / "fw", self.proj), self.wt)

    def test_projeto_sem_bancada_ou_inativo_recusa(self):
        for proj in ([Proj(self.raiz, bancada=False)], [Proj(self.raiz, ativo=False)]):
            with self.assertRaises(b.Recusa):
                b.worktree_do_card(self.wt, proj)

    def test_fora_das_worktrees_e_a_propria_raiz_recusam(self):
        for cwd in (self.tmp, self.raiz):
            with self.assertRaises(b.Recusa):
                b.worktree_do_card(cwd, self.proj)

    def test_raiz_no_home_recusa(self):
        with self.assertRaises(b.Recusa):
            b.worktree_do_card(Path.home() / "x", [Proj(Path.home())])


class Portas(unittest.TestCase):
    def test_escolha(self):
        lista = ["/dev/cu.usbmodem3101"]
        self.assertEqual(b.escolher_porta(None, lista), lista[0])
        self.assertEqual(b.escolher_porta(lista[0], lista), lista[0])
        for pedida, disp in (("/dev/cu.Bluetooth-Incoming-Port", lista), (None, []),
                             (None, lista + ["/dev/cu.usbserial-1"]), ("/dev/disk0", lista)):
            with self.assertRaises(b.Recusa):
                b.escolher_porta(pedida, disp)

    def test_so_dispositivo_de_caractere(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "cu.usbmodemFAKE").write_text("x")      # arquivo comum: não é porta
            os.symlink("/dev/null", Path(d, "cu.usbmodemLINK"))  # symlink: não entra
            self.assertEqual(b.portas((str(Path(d, "cu.usbmodem*")),)), [])


class Firmware(Base):
    def test_arquivo_bom(self):
        self.assertEqual(b.firmware_no_worktree("fw/app.bin", self.wt, self.wt), self.fw)

    def test_recusas(self):
        fora = self.tmp / "fora.bin"
        fora.write_bytes(b"x")
        txt = self.wt / "fw" / "app.txt"
        txt.write_bytes(b"x")
        vazio = self.wt / "fw" / "vazio.bin"
        vazio.write_bytes(b"")
        os.symlink(fora, self.wt / "fw" / "link.bin")
        os.symlink(self.wt / "fw", self.wt / "pasta-link")
        for rel in ("../fora.bin", str(fora), "fw/app.txt", "fw/vazio.bin", "fw/link.bin",
                    "pasta-link/app.bin", "fw/nao-existe.bin", "-rf", "", "fw"):
            with self.subTest(rel=rel), self.assertRaises(b.Recusa):
                b.firmware_no_worktree(rel, self.wt, self.wt)

    def test_endereco(self):
        self.assertEqual(b.endereco("0x0"), 0)
        self.assertEqual(b.endereco("0x10000"), 0x10000)
        for txt in ("0", "10000", "0x123", "0x1000000", "0x-1", "0x10000;id", ""):
            with self.subTest(txt=txt), self.assertRaises(b.Recusa):
                b.endereco(txt)

    def test_pares(self):
        self.assertEqual(b.segmentos(["0x0", "fw/app.bin"], self.wt, self.wt), [("0x0", self.fw)])
        for args in ([], ["0x0"], ["0x0", "fw/app.bin"] * 5):
            with self.subTest(n=len(args)), self.assertRaises(b.Recusa):
                b.segmentos(args, self.wt, self.wt)


class Esptool(unittest.TestCase):
    def test_versao_fixa_e_chip_da_lista(self):
        cmd = b.comando_esptool(Path("/opt/homebrew/bin/uv"), "esp32s3", "/dev/cu.usbmodem1", ["chip_id"])
        self.assertEqual(cmd[:6], ["/opt/homebrew/bin/uv", "tool", "run", "--from", b.ESPTOOL, "esptool"])
        self.assertRegex(b.ESPTOOL, r"^esptool==\d+\.\d+\.\d+$")
        with self.assertRaises(b.Recusa):
            b.comando_esptool(Path("/x/uv"), "stm32", "/dev/cu.usbmodem1", ["chip_id"])

    def test_uv_so_de_caminho_fixo(self):
        with self.assertRaises(b.Recusa):
            b.uv_fixo((Path("/nao/existe/uv"),))


class Executar(Base):
    def _rodar(self, argv, **kw):
        chamadas = []
        kw.setdefault("achar_portas", lambda: ["/dev/cu.usbmodem3101"])
        kw.setdefault("uv", lambda: Path("/opt/homebrew/bin/uv"))
        kw.setdefault("rodar_cmd", lambda cmd: chamadas.append(cmd) or 0)
        kw.setdefault("serial", lambda p, s, baud: chamadas.append(("serial", p, s, baud)) or 0)
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            rc = b.executar(argv, self.wt, self.proj, **kw)
        return rc, chamadas, out.getvalue()

    def test_portas(self):
        rc, _, out = self._rodar(["portas"])
        self.assertEqual((rc, out.strip()), (0, "/dev/cu.usbmodem3101"))

    def test_gravar_monta_o_esptool(self):
        rc, chamadas, _ = self._rodar(["gravar", "--chip", "esp32s3", "0x0", "fw/app.bin"])
        self.assertEqual(rc, 0)
        cmd = chamadas[0]
        self.assertEqual(cmd[cmd.index("--port") + 1], "/dev/cu.usbmodem3101")
        self.assertIn("write_flash", cmd)
        self.assertEqual(cmd[cmd.index("write_flash") + 1:], ["0x0", str(self.fw)])
        self.assertEqual(cmd[cmd.index("--chip") + 1], "esp32s3")

    def test_serial(self):
        rc, chamadas, _ = self._rodar(["serial", "--baud", "115200", "30"])
        self.assertEqual(chamadas, [("serial", "/dev/cu.usbmodem3101", 30, 115200)])

    def test_recusas(self):
        for argv in ([], ["shell"], ["portas", "x"], ["serial", "121"], ["serial", "0"],
                     ["serial", "--baud", "1000000", "10"], ["serial", "10", "20"],
                     ["chip", "extra"], ["chip", "--outra", "x"], ["gravar", "0x0"],
                     ["gravar", "--porta", "/dev/cu.Bluetooth-Incoming-Port", "0x0", "fw/app.bin"]):
            with self.subTest(argv=argv), self.assertRaises(b.Recusa):
                self._rodar(argv)

    def test_fora_do_worktree_recusa_antes_de_tudo(self):
        chamadas = []
        with self.assertRaises(b.Recusa):
            b.executar(["portas"], self.tmp, self.proj, achar_portas=lambda: chamadas.append(1) or [])
        self.assertEqual(chamadas, [])


class Serial(unittest.TestCase):
    def test_le_da_porta_com_tempo_limitado(self):
        mestre, escravo = os.openpty()
        nome = os.ttyname(escravo)
        self.addCleanup(os.close, mestre)
        self.addCleanup(os.close, escravo)
        threading.Timer(0.2, lambda: os.write(mestre, b"boot ok\r\n")).start()
        saida = io.StringIO()
        inicio = time.monotonic()
        self.assertEqual(b.ler_serial(nome, 1, 115200, saida=saida), 0)
        self.assertIn("boot ok", saida.getvalue())
        self.assertLess(time.monotonic() - inicio, 3)


class Auditoria(unittest.TestCase):
    def test_linha_json_0600_e_recusa_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "bancada.log"
            b.auditar({"argv": ["portas"], "rc": 0}, log)
            self.assertEqual(json.loads(log.read_text())["rc"], 0)
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            alvo = Path(d) / "outro"
            link = Path(d) / "link.log"
            os.symlink(alvo, link)
            with self.assertRaises(OSError):
                b.auditar({"rc": 0}, link)
            self.assertFalse(alvo.exists())


class Arquivo(unittest.TestCase):
    def test_python_do_sistema_em_modo_isolado(self):
        primeira = (RAIZ / "lanes" / "bancada.py").read_text().splitlines()[0]
        self.assertEqual(primeira, "#!/usr/bin/python3 -I")
        self.assertTrue(os.access(RAIZ / "lanes" / "bancada.py", os.X_OK))


class CadastroDoProjeto(unittest.TestCase):
    def test_so_objeto_com_ativo_true_liga(self):
        base = {"id": "x", "repo": "/tmp/x"}
        casos = [({"ativo": True}, True), (True, False), ({"ativo": "sim"}, False), (None, False)]
        for bruto, esperado in casos:
            with self.subTest(bruto=bruto):
                item = dict(base, bancada=bruto) if bruto is not None else base
                self.assertIs(projetos._do_registro([item])[0].bancada, esperado)


class DockerValidador(unittest.TestCase):
    """FRA-619: validações básicas do compose antes de rodar docker."""

    def test_aceita_com_digest_e_named_volume(self):
        bom = """
services:
  broker:
    image: "eclipse-mosquitto@sha256:d12c8f80dfc65b768bb9acecc7ef182b976f71fb681640b66358e5e0cf94e9e9"
    volumes:
      - mosquitto-data:/mosquitto
"""
        b._validar_compose(bom, Path("/tmp/wt"))

    def test_recusa_sem_digest(self):
        ruim = "services:\n  x:\n    image: python:3.12"
        with self.assertRaises(b.Recusa):
            b._validar_compose(ruim, Path("/tmp/wt"))

    def test_recusa_privileged(self):
        ruim = "services:\n  x:\n    privileged: true\n    image: foo@sha256:abc"
        with self.assertRaises(b.Recusa):
            b._validar_compose(ruim, Path("/tmp/wt"))

    def test_recusa_network_host(self):
        ruim = "services:\n  x:\n    network_mode: host\n    image: foo@sha256:abc"
        with self.assertRaises(b.Recusa):
            b._validar_compose(ruim, Path("/tmp/wt"))


COMPOSE_MINIMO = """
services:
  broker:
    image: "eclipse-mosquitto@sha256:d12c8f80dfc65b768bb9acecc7ef182b976f71fb681640b66358e5e0cf94e9e9"
    volumes:
      - mosquitto-data:/mosquitto
volumes:
  mosquitto-data: {}
"""


class DockerExecutar(Base):
    def _rodar_docker(self, argv, **kw):
        chamadas = []
        kw.setdefault("achar_portas", lambda: ["/dev/cu.usbmodem3101"])
        with mock.patch("sys.stdout", new=io.StringIO()):
            # compose mínimo e válido no local padrão (dentro do wt). O POC do FRA-539 mora no
            # projeto que usa a bancada, não neste repositório.
            (self.wt / "docker").mkdir(parents=True, exist_ok=True)
            (self.wt / "docker" / "compose.yml").write_text(COMPOSE_MINIMO)
            rc = b.executar(argv, self.wt, self.proj, **kw)
        return rc, chamadas

    def test_docker_subir_valida_e_chama(self):
        # mock para não rodar docker de verdade
        with mock.patch("bancada._rodar_docker", return_value=0) as mock_run:
            rc, _ = self._rodar_docker(["docker", "subir"])
            self.assertEqual(rc, 0)
            self.assertTrue(mock_run.called)

    def test_docker_recusa_fora_do_wt(self):
        with self.assertRaises(b.Recusa):
            b.executar(["docker", "subir", "--file", "../fora.yml"], self.wt, self.proj)


if __name__ == "__main__":
    unittest.main()
