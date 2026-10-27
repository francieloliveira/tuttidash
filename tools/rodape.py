#!/usr/bin/python3
"""Rodapé com barra de progresso para os painéis do painel.command (tmux).

Fica entre o seguidor de log e o terminal: o que chega pela entrada rola numa
região de rolagem (linhas 1..N-1) e a última linha do painel é um rodapé fixo,
redesenhado a cada linha e a cada segundo. O rodapé não depende do filtro do
painel: ele mesmo lê o log mais recente (--glob) e calcula o progresso.

  rodape.py testes --glob '~/…/*/.lane/proof.log'   provas das lanes
  rodape.py testes --glob '/tmp/fra*-*.log'         testes do gestor
  rodape.py build  --glob A --glob B                build e instalação
  rodape.py lanes  --log ~/Library/Logs/TranscentIA/lanes-dispatcher.log

Python 3.9 do macOS, sem dependências. As funções puras (Progresso, contar_testes,
rodape_*) têm teste em test_rodape.py.
"""
import glob
import os
import re
import select
import signal
import sys
import time

E = "\033["
RESET = E + "0m"
VERDE, VERMELHO, AMARELO, CINZA, AZUL = E + "32m", E + "31m", E + "33m", E + "2m", E + "36m"

RE_ROOT = re.compile(r"\[safe\] root=(\S+)")
RE_ONLY = re.compile(r"\[safe\] destination=\S+ only=(\S+)")
RE_CASO = re.compile(r"Test Case '-\[\S+?\.(\w+) (\w+)\]' (passed|failed)")
RE_SWIFT = re.compile(r"[✔✘] Test (\S+?)\(\) (passed|failed)")
RE_EXEC = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")
ETAPAS_INSTALAR = ["preparar", "compilar", "assinar", "instalar no iPhone", "instalar no relógio"]
ETAPAS_BUILD = ["preparar", "compilar", "assinar", "pronto"]


# ---------------------------------------------------------------- contagem de testes

_indices = {}


def _arquivos_de_teste(root):
    """Arquivos .swift nos alvos de teste do worktree (cache por root)."""
    if root not in _indices:
        achados = []
        for alvo in ("TranscentIATests", "TranscentIAUITests", "TranscentIA Watch AppUITests"):
            base = os.path.join(root, alvo)
            for pasta, _, nomes in os.walk(base):
                achados += [os.path.join(pasta, n) for n in nomes if n.endswith(".swift")]
        _indices[root] = achados
    return _indices[root]


def _testes_no_texto(texto):
    return len(re.findall(r"func test\w*\s*\(", texto)) + len(re.findall(r"@Test\b", texto))


def contar_testes(root, only):
    """Quantos testes a execução vai rodar, a partir do `only=` do safe_xcodebuild.
    Devolve None quando não dá para saber (o rodapé mostra só o que já rodou)."""
    if not root or not only:
        return None
    alvo = None
    for prefixo in ("TranscentIATests", "TranscentIAUITests"):
        if only == prefixo:
            alvo, only = prefixo, ""
        elif only.startswith(prefixo + "/"):
            only = only[len(prefixo) + 1:]
    if only == "ALL":
        alvo, only = "TranscentIATests", ""
    if "/" in only:
        return 1
    arquivos = _arquivos_de_teste(root)
    total = 0
    for caminho in arquivos:
        if alvo and os.sep + alvo + os.sep not in caminho:
            continue
        try:
            with open(caminho, encoding="utf-8", errors="replace") as f:
                texto = f.read()
        except OSError:
            continue
        if not only:
            total += _testes_no_texto(texto)
        elif re.search(r"\b(class|struct)\s+" + re.escape(only) + r"\b", texto):
            total += _testes_no_texto(texto)
    return total or None


# ---------------------------------------------------------------- estado de um log

class Progresso:
    """Estado lido de um log de prova, de teste do gestor ou de build."""

    def __init__(self, nome="", instalar=False, contar=contar_testes):
        self.nome = nome
        self.instalar = instalar
        self.contar = contar
        self.root = None
        self.total = None
        self.feitos = 0
        self.falhas = 0
        self.classe = ""
        self.testes = False
        self.etapa = 0
        self.arquivos = 0
        self.fim = None  # None, "ok", "falhou", "abortado"

    @property
    def etapas(self):
        return ETAPAS_INSTALAR if self.instalar else ETAPAS_BUILD

    def linha(self, texto):
        m = RE_ROOT.search(texto)
        if m:
            self.root = m.group(1)
        m = RE_ONLY.search(texto)
        if m:  # nova execução do xcodebuild: zera a contagem desta execução
            self.testes = True
            self.total = self.contar(self.root, m.group(1))
            self.feitos = self.falhas = 0
            self.classe = m.group(1).split("/")[-1]
            self.fim = None
        m = RE_CASO.search(texto) or RE_SWIFT.search(texto)
        if m:
            self.testes = True
            self.feitos += 1
            if m.group(m.lastindex) == "failed":
                self.falhas += 1
            if m.re is RE_CASO:
                self.classe = m.group(1)
            if self.total is not None and self.feitos > self.total:
                self.total = self.feitos
        m = RE_EXEC.search(texto)
        if m and self.total is None:
            self.total = int(m.group(1))
        if re.search(r"CompileSwift|SwiftCompile|Compiling ", texto):
            self.etapa = max(self.etapa, 1)
            self.arquivos += 1
        if re.search(r"CodeSign|Signing ", texto):
            self.etapa = max(self.etapa, 2)
        if "BUILD SUCCEEDED" in texto:
            self.etapa = max(self.etapa, 3 if self.instalar else len(self.etapas) - 1)
            if not self.instalar and not self.testes:
                self.fim = "ok"
        if "DEVICE INSTALL OK" in texto:
            self.etapa = max(self.etapa, 4)
        if re.search(r"WATCH INSTALL (OK|SKIP)", texto):
            self.etapa = len(self.etapas) - 1
            self.fim = "ok"
        if "TEST SUCCEEDED" in texto:
            self.fim = "ok"
        if re.search(r"TEST FAILED|BUILD FAILED|INSTALL FAIL", texto):
            self.fim = "falhou"
        if "abortado" in texto:
            self.fim = "abortado"


# ---------------------------------------------------------------- desenho

def barra(fracao, largura, cor, agora=None):
    """Barra ▕████░░░░▏. fracao=None desenha um bloco que anda (indeterminado)."""
    largura = max(4, largura)
    if fracao is None:
        pos = int((agora if agora is not None else time.time()) * 2) % largura
        cel = ["░"] * largura
        for i in range(pos, min(pos + 3, largura)):
            cel[i] = "█"
        return "▕" + cor + "".join(cel) + RESET + "▏"
    cheio = max(0, min(largura, int(round(fracao * largura))))
    return "▕" + cor + "█" * cheio + RESET + CINZA + "░" * (largura - cheio) + RESET + "▏"


def tempo(segundos):
    segundos = max(0, int(segundos))
    h, r = divmod(segundos, 3600)
    m, s = divmod(r, 60)
    return "%d:%02d:%02d" % (h, m, s) if h else "%d:%02d" % (m, s)


def rodape_progresso(p, decorrido, colunas, agora=None):
    largura = max(8, min(30, colunas // 4))
    nome = (p.nome + " · ") if p.nome else ""
    if p.testes:
        cor = VERMELHO if p.falhas or p.fim in ("falhou", "abortado") else VERDE
        if p.fim == "ok" and not p.falhas:
            fr = 1.0
        elif p.total:
            fr = p.feitos / float(p.total)
        else:
            fr = None if p.feitos == 0 and p.fim is None else (1.0 if p.fim else None)
        conta = "%d/%s testes" % (p.feitos, p.total if p.total else "?")
        if p.feitos == 0 and p.fim is None:
            conta = "compilando para testar"
            cor = AZUL
        estado = {"ok": "✔ concluído", "falhou": "✘ falhou", "abortado": "✘ abortado"}.get(p.fim, p.classe)
        falhas = (" · %d falha%s" % (p.falhas, "s" if p.falhas > 1 else "")) if p.falhas else ""
        texto = "%s %s%s%s · %s · %s" % (barra(fr, largura, cor, agora), nome, conta, falhas, tempo(decorrido), estado)
    else:
        n = len(p.etapas)
        if p.fim == "ok":
            fr, cor = 1.0, VERDE
        elif p.fim:
            fr, cor = (p.etapa + 1) / float(n), VERMELHO
        else:
            fr, cor = (p.etapa + 0.5) / float(n), AZUL
        extra = (" · %d arquivos" % p.arquivos) if p.arquivos else ""
        estado = {"ok": "✔ concluído", "falhou": "✘ falhou", "abortado": "✘ abortado"}.get(
            p.fim, "%s · etapa %d/%d" % (p.etapas[p.etapa], p.etapa + 1, n))
        texto = "%s %s%s%s · %s" % (barra(fr, largura, cor, agora), nome, estado, extra, tempo(decorrido))
    return texto


RE_LANE = re.compile(r"^(\S+ \S+) lane:(\w+) (.*)$")


def resumo_lane(msg):
    m = re.search(r"segura (FRA-\d+): conta em (\d+)%", msg)
    if m:
        return AMARELO + "%s esperando (conta %s%%)" % (m.group(1), m.group(2)) + RESET
    if msg.startswith("livre"):
        return CINZA + "livre" + RESET
    m = re.search(r"(FRA-\d+)", msg, re.I)
    card = m.group(1).upper() if m else ""
    for chave, rotulo in (("prova", "prova"), ("falh", "falhou"), ("merge", "merge"), ("PR", "PR"),
                          ("limite", "esperando limite"), ("ocupad", "trabalhando"), ("assum", "trabalhando"), ("trabalh", "trabalhando")):
        if chave in msg:
            cor = VERMELHO if rotulo == "falhou" else VERDE
            return cor + ("%s %s" % (card, rotulo)).strip() + RESET
    return (card + " " + msg[:28]).strip()


def rodape_lanes(linhas, agora_ts):
    ultimas = {}
    for linha in linhas:
        m = RE_LANE.match(linha.strip())
        if m:
            ultimas[m.group(2)] = (m.group(1), m.group(3))
    if not ultimas:
        return CINZA + "lanes: sem notícia no log" + RESET
    partes = []
    for lane in sorted(ultimas):
        quando, msg = ultimas[lane]
        try:
            idade = agora_ts - time.mktime(time.strptime(quando, "%Y-%m-%d %H:%M:%S"))
            idade_txt = " " + CINZA + "há " + tempo(idade) + RESET
        except ValueError:
            idade_txt = ""
        partes.append("%s%s%s %s%s" % (E + "1m", lane, RESET, resumo_lane(msg), idade_txt))
    return "  ·  ".join(partes)


def visivel(texto):
    return re.sub(r"\033\[[0-9;]*m", "", texto)


def cortar(texto, colunas):
    """Corta pelo texto visível, sem quebrar as cores."""
    saida, n = [], 0
    for parte in re.split(r"(\033\[[0-9;]*m)", texto):
        if parte.startswith("\033["):
            saida.append(parte)
            continue
        resta = colunas - n
        if resta <= 0:
            continue
        saida.append(parte[:resta])
        n += len(parte[:resta])
    return "".join(saida) + RESET


# ---------------------------------------------------------------- fonte (arquivo seguido)

class Fonte:
    def __init__(self, globs, modo):
        self.globs = [os.path.expanduser(g) for g in globs]
        self.modo = modo
        self.caminho = None
        self.pos = 0
        self.resto = b""
        self.p = None
        self.inicio = None

    def _mais_recente(self):
        achados = []
        for g in self.globs:
            achados += glob.glob(g)
        return max(achados, key=lambda c: os.path.getmtime(c)) if achados else None

    def _nome(self, caminho):
        if caminho.endswith(os.path.join(".lane", "proof.log")) or os.sep + ".lane" + os.sep in caminho:
            return os.path.basename(os.path.dirname(os.path.dirname(caminho))).upper()
        return os.path.basename(caminho).rsplit(".", 1)[0]

    def atualizar(self):
        atual = self._mais_recente()
        if atual is None:
            return
        if atual != self.caminho:
            self.caminho, self.pos, self.resto = atual, 0, b""
            instalar = self.modo == "build" and bool(re.search(r"device|install", atual))
            self.p = Progresso(self._nome(atual), instalar=instalar)
            st = os.stat(atual)
            self.inicio = getattr(st, "st_birthtime", st.st_mtime)
        try:
            with open(self.caminho, "rb") as f:
                f.seek(self.pos)
                novo = f.read()
                self.pos = f.tell()
        except OSError:
            return
        dados = self.resto + novo
        linhas = dados.split(b"\n")
        self.resto = linhas.pop()
        for linha in linhas:
            self.p.linha(linha.decode("utf-8", "replace"))

    def decorrido(self):
        if not self.caminho:
            return 0
        fim = os.path.getmtime(self.caminho) if self.p and self.p.fim else time.time()
        return fim - (self.inicio or fim)


# ---------------------------------------------------------------- terminal

class Tela:
    def __init__(self, saida):
        self.saida = saida
        self.linhas, self.colunas = 24, 80
        self.medir()

    def medir(self):
        try:
            tam = os.get_terminal_size(self.saida.fileno())
            self.colunas, self.linhas = tam.columns, tam.lines
        except OSError:
            pass
        # região de rolagem 1..N-1; DECSTBM leva o cursor para o topo, então desce para a base
        self.escrever(("%s1;%dr%s%d;1H" % (E, max(2, self.linhas - 1), E, max(1, self.linhas - 1))).encode())

    def escrever(self, dados):
        if dados:
            self.saida.write(dados)
            self.saida.flush()

    def rodape(self, texto):
        linha = cortar(texto, max(10, self.colunas - 1))
        self.escrever(("\0337%s%d;1H%s2K%s\0338" % (E, self.linhas, E, linha)).encode())

    def soltar(self):
        self.escrever(("%sr" % E).encode())


def principal(argv):
    if len(argv) < 2 or argv[1] not in ("testes", "build", "lanes"):
        sys.stderr.write(__doc__)
        return 2
    modo, globs, log = argv[1], [], None
    i = 2
    while i < len(argv):
        if argv[i] == "--glob":
            globs.append(argv[i + 1]); i += 2
        elif argv[i] == "--log":
            log = os.path.expanduser(argv[i + 1]); i += 2
        else:
            i += 1
    saida = os.fdopen(sys.stdout.fileno(), "wb", buffering=0)
    tela = Tela(saida)
    signal.signal(signal.SIGWINCH, lambda *_: tela.medir())
    fonte = Fonte(globs, modo) if modo != "lanes" else None
    entrada = sys.stdin.fileno()
    aberta = True
    ultimo = 0.0

    def desenhar():
        if modo == "lanes":
            try:
                with open(log, "rb") as f:
                    f.seek(max(0, os.path.getsize(log) - 40000))
                    linhas = f.read().decode("utf-8", "replace").splitlines()
            except (OSError, TypeError):
                linhas = []
            tela.rodape(rodape_lanes(linhas, time.time()))
            return
        fonte.atualizar()
        if fonte.p is None:
            tela.rodape(CINZA + "aguardando o primeiro log…" + RESET)
        else:
            tela.rodape(rodape_progresso(fonte.p, fonte.decorrido(), tela.colunas))

    try:
        while True:
            espera = max(0.0, 1.0 - (time.time() - ultimo))
            prontos = []
            if aberta:
                try:
                    prontos, _, _ = select.select([entrada], [], [], espera)
                except InterruptedError:
                    prontos = []
            else:
                time.sleep(espera)
            if prontos:
                dados = os.read(entrada, 65536)
                if not dados:
                    aberta = False
                else:
                    tela.escrever(dados)
            if time.time() - ultimo >= 0.5 or prontos:
                desenhar()
                ultimo = time.time()
    except KeyboardInterrupt:
        pass
    finally:
        tela.soltar()
    return 0


if __name__ == "__main__":
    sys.exit(principal(sys.argv))
