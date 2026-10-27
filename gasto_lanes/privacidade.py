"""Privacidade dos modelos do OpenCode: quem pode receber código (e texto de card).

Por quê: os modelos do OpenCode (Zen e Go) têm regras diferentes de treino e retenção,
e elas mudam (período gratuito acaba, acordo de retenção zero renovado todo mês, modelo
novo entra). Não há campo técnico na API que diga isso: a fonte é a documentação do
próprio OpenCode. Este módulo lê essa documentação, guarda o que ela diz com data e
origem, e decide **fail-closed**: sem conferência recente e explícita, o modelo não
recebe código.

A fonte é achada pelo **conteúdo**, não pelo endereço (a documentação já mudou de lugar:
`packages/web/src/content/docs/zen.mdx` virou `services/www/src/docs/content/console/models.mdx`):
  1. o último caminho que funcionou;
  2. os caminhos conhecidos da config;
  3. a busca de código do GitHub pelas frases-âncora, dentro do repositório.
Se o caminho mudar, o novo é adotado e o painel avisa. Se nada for achado, o estado
anterior vale até `max_idade_dias`; depois disso, tudo do OpenCode fica bloqueado.
Nunca libera sozinho o que a documentação não disser.

Somente Python 3 da stdlib (+ `gh` no PATH para a busca, opcional).
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import urllib.request
from pathlib import Path
from typing import Optional

ESTADO = Path.home() / ".transcentia" / "privacidade-modelos.json"
PATH_EXTRA = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

#: Fontes padrão. `prefixo` liga o ID do modelo (`opencode/…`, `opencode-go/…`) ao documento.
FONTES_PADRAO = {
    "zen": {"prefixo": "opencode", "repo": "anomalyco/opencode", "ref": "dev",
            "caminhos": ["services/www/src/docs/content/console/models.mdx",
                         "packages/web/src/content/docs/zen.mdx"],
            "busca": "\"zero-retention policy and do not use your data for model training\"",
            "ancoras": ["zero-retention policy", "## Privacy"]},
    "go": {"prefixo": "opencode-go", "repo": "anomalyco/opencode", "ref": "dev",
           "caminhos": ["services/www/src/docs/content/console/go.mdx",
                        "packages/web/src/content/docs/go.mdx"],
           "busca": "\"Model training\" \"Data retention\" Contributor",
           "ancoras": ["Model training", "Data retention"]},
}
MESES = {m: i for i, m in enumerate(["january", "february", "march", "april", "may", "june", "july",
                                     "august", "september", "october", "november", "december"], 1)}
LOCALE_RE = re.compile(r"/(?:[a-z]{2}|[a-z]{2}-[a-z]{2}|zh-cn|zh-tw|pt-br)/", re.I)


def _cfg(chave, padrao):
    try:
        import runpy
        v = runpy.run_path(str(Path.home() / ".transcentia/tools/cfg"))["get"](chave, padrao)
        return padrao if v in (None, "") else v
    except Exception:  # noqa: BLE001
        return padrao


def slug(nome: str) -> str:
    """'DeepSeek V4.1 Flash Free' -> 'deepseek-v4.1-flash-free' (formato dos IDs do OpenCode)."""
    s = re.sub(r"<[^>]+>", " ", nome)
    s = re.sub(r"[*`~]", "", s).strip().lower()
    return re.sub(r"\s+", "-", s)


# --- Leitura do markdown -------------------------------------------------------------
def _tabelas(md: str) -> list[list[list[str]]]:
    """Tabelas markdown como listas de linhas de células (sem a linha de separação)."""
    tabs, atual = [], []
    for linha in md.splitlines():
        t = linha.strip()
        if t.startswith("|") and t.endswith("|"):
            cels = [c.strip() for c in t.strip("|").split("|")]
            if all(re.fullmatch(r":?-{3,}:?", c) for c in cels if c):
                continue
            atual.append(cels)
        elif atual:
            tabs.append(atual)
            atual = []
    if atual:
        tabs.append(atual)
    return tabs


def _ids(md: str) -> dict:
    """Nome exibido -> ID, das tabelas com colunas 'Model' e 'Model ID'."""
    out = {}
    for tab in _tabelas(md):
        cab = [c.lower() for c in tab[0]]
        if "model" in cab and "model id" in cab:
            i, j = cab.index("model"), cab.index("model id")
            for row in tab[1:]:
                if len(row) > max(i, j) and row[j].strip("` "):
                    out[slug(row[i])] = row[j].strip("` ")
    return out


def _secao(md: str, titulo: str) -> str:
    m = re.search(rf"^##\s+{re.escape(titulo)}\s*$(.*?)(?=^##\s|\Z)", md, re.M | re.S)
    return m.group(1) if m else ""


def _data(txt: str) -> Optional[str]:
    m = re.search(r"valid through\s+([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})", txt)
    if not m or m.group(1).lower() not in MESES:
        return None
    return dt.date(int(m.group(3)), MESES[m.group(1).lower()], int(m.group(2))).isoformat()


def ler_go(md: str) -> dict:
    """Tabela 'Model | Model training | Data retention' + notas de validade (asterisco)."""
    ids = _ids(md)
    priv = _secao(md, "Privacy") or md
    notas = {}
    for linha in priv.splitlines():
        m = re.match(r"\s*-\s+\*\*(.+?):?\*\*:?\s*(.+)", linha)
        if m:
            notas[m.group(1).strip().rstrip(":")] = m.group(2)
    out = {}
    for tab in _tabelas(priv):
        cab = [c.lower() for c in tab[0]]
        if not ("model training" in cab and "data retention" in cab):
            continue
        i, tr, rt = cab.index("model") if "model" in cab else 0, cab.index("model training"), cab.index("data retention")
        for row in tab[1:]:
            if len(row) <= max(i, tr, rt):
                continue
            nome, treino, ret = row[i].strip(), row[tr].lower(), row[rt].replace("\\", "")
            m = re.search(r"(\d+)\s*day", ret)
            item = {"nome": nome, "treina": not treino.startswith("not used"),
                    "retencao_dias": int(m.group(1)) if m else None}
            if "*" in ret:
                for chave, nota in notas.items():
                    if chave.lower() in nome.lower():
                        item["valido_ate"] = _data(nota)
                        item["nota"] = nota[:200]
            out[ids.get(slug(nome), slug(nome))] = item
    return out


def ler_zen(md: str) -> dict:
    """Seção 'Privacy': regra geral (retenção zero, sem treino) + exceções nomeadas.
    Só vale a regra geral se a frase dela estiver lá; senão nada é liberado."""
    ids = _ids(md)
    priv = _secao(md, "Privacy")
    geral = "zero-retention policy and do not use your data for model training" in priv
    out = {}
    if geral:
        for s, mid in ids.items():
            out[mid] = {"nome": s, "treina": False, "retencao_dias": 0}
    for linha in priv.splitlines():
        m = re.match(r"\s*-\s+\**([^:*]+?)\**(?:\s*\([^)]*\))?:\s*(.+)", linha)
        if not m:
            continue
        nome, txt = m.group(1).strip(), m.group(2).lower()
        nao_treina = "not used for training" in txt or "does not use your data for model training" in txt
        treina = not nao_treina and bool(re.search(r"improve|train|logged|confidential", txt))
        r = re.search(r"retained for (\d+) days", txt)
        ret = int(r.group(1)) if r else (0 if not treina and "retained" not in txt else None)
        item = {"nome": nome, "treina": treina, "retencao_dias": ret, "nota": m.group(2)[:200]}
        if nome.lower().endswith(" apis"):
            prov = nome.lower().split()[0]
            pref = {"openai": ("gpt",), "anthropic": ("claude",), "mistral": ("mistral", "devstral", "codestral")}.get(prov, ())
            for mid in list(out):
                if mid.startswith(pref):
                    out[mid] = dict(item, nome=out[mid]["nome"])
            continue
        out[ids.get(slug(nome), slug(nome))] = item
    return out


LEITORES = {"zen": ler_zen, "go": ler_go}


def valido(doc: str, md: str, fonte: dict) -> dict:
    """Modelos lidos, ou {} se o texto não é a fonte (âncoras ausentes ou nada lido)."""
    if not all(a in md for a in fonte["ancoras"]):
        return {}
    return LEITORES[doc](md)


# --- Busca da fonte pelo conteúdo --------------------------------------------------------
def _env() -> dict:
    return dict(os.environ, PATH=PATH_EXTRA + ":" + os.environ.get("PATH", ""))


def _baixar(repo: str, ref: str, caminho: str) -> Optional[tuple[str, str]]:
    """(texto, sha) pelo `gh api` (segue repositório renomeado); sem gh, pelo raw."""
    try:
        out = subprocess.run(["gh", "api", f"repos/{repo}/contents/{caminho}?ref={ref}"],
                             capture_output=True, text=True, timeout=60, env=_env())
        if out.returncode == 0:
            d = json.loads(out.stdout)
            import base64
            return base64.b64decode(d["content"]).decode("utf-8", "replace"), d.get("sha", "")
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError):
        pass
    try:
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/{repo}/{ref}/{caminho}", timeout=30) as r:
            return r.read().decode("utf-8", "replace"), ""
    except Exception:  # noqa: BLE001
        return None


def _buscar_caminhos(repo: str, consulta: str) -> list[str]:
    """Caminhos de arquivos .md/.mdx no repositório com as frases-âncora (busca do GitHub)."""
    try:
        out = subprocess.run(["gh", "api", "-X", "GET", "search/code", "-f", f"q={consulta} repo:{repo}",
                              "--jq", ".items[].path"], capture_output=True, text=True, timeout=60, env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return []
    return ordenar_caminhos([p for p in out.stdout.split() if p.endswith((".md", ".mdx"))])


def ordenar_caminhos(caminhos: list[str]) -> list[str]:
    """Original antes da tradução (sem pasta de idioma), dentro de docs, caminho mais curto."""
    return sorted(caminhos, key=lambda p: (bool(LOCALE_RE.search("/" + p)), "docs" not in p, len(p)))


def localizar(doc: str, fonte: dict, anterior: dict | None = None) -> dict:
    """Acha e lê um documento. {'ok', 'caminho', 'sha', 'modelos', 'mudou_de', 'erro'}."""
    anterior = anterior or {}
    tentativas = []
    for c in [anterior.get("caminho")] + list(fonte["caminhos"]):
        if c and c not in tentativas:
            tentativas.append(c)
    for c in tentativas:
        r = _baixar(fonte["repo"], fonte["ref"], c)
        if r and (mods := valido(doc, r[0], fonte)):
            return {"ok": True, "caminho": c, "sha": r[1], "modelos": mods,
                    "mudou_de": anterior.get("caminho") if anterior.get("caminho") not in (None, c) else None}
    for c in _buscar_caminhos(fonte["repo"], fonte["busca"]):
        if c in tentativas:
            continue
        r = _baixar(fonte["repo"], fonte["ref"], c)
        if r and (mods := valido(doc, r[0], fonte)):
            return {"ok": True, "caminho": c, "sha": r[1], "modelos": mods, "achado_pela_busca": True,
                    "mudou_de": anterior.get("caminho") or tentativas[0]}
    return {"ok": False, "erro": f"nenhuma fonte com as âncoras em {fonte['repo']} ({', '.join(tentativas)} e busca)"}


# --- Estado e decisão --------------------------------------------------------------------
def fontes() -> dict:
    conf = _cfg("privacidade.fontes", {}) or {}
    return {k: {**v, **(conf.get(k) or {})} for k, v in FONTES_PADRAO.items()}


def ler_estado(caminho: Path = ESTADO) -> dict:
    try:
        return json.loads(caminho.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def atualizar(caminho: Path = ESTADO, agora: Optional[dt.datetime] = None) -> tuple[dict, list[str]]:
    """Confere as fontes e grava o estado. Devolve (estado, avisos para o painel)."""
    agora = agora or dt.datetime.now()
    est = ler_estado(caminho)
    docs = est.setdefault("docs", {})
    avisos = []
    for doc, fonte in fontes().items():
        ant = docs.get(doc) or {}
        r = localizar(doc, fonte, ant)
        if r["ok"]:
            antigos = ant.get("modelos") or {}
            novos = r["modelos"]
            chave = lambda d: (d.get("treina"), d.get("retencao_dias"), d.get("valido_ate"))  # noqa: E731
            mudou = sorted(m for m in antigos if m in novos and chave(antigos[m]) != chave(novos[m]))
            sumiu = sorted(m for m in antigos if m not in novos)
            if antigos and sumiu:
                avisos.append(f"privacidade OpenCode ({doc}): saíram da documentação (agora bloqueados): "
                              f"{', '.join(sumiu[:8])}")
            if r.get("mudou_de"):
                avisos.append(f"privacidade OpenCode ({doc}): a documentação mudou de lugar "
                              f"({r['mudou_de']} → {r['caminho']}); adotei o novo caminho")
            if antigos and mudou:
                avisos.append(f"privacidade OpenCode ({doc}): regra mudou para {', '.join(mudou[:8])}")
            docs[doc] = {"ok": True, "repo": fonte["repo"], "caminho": r["caminho"], "sha": r.get("sha", ""),
                         "conferido_em": agora.isoformat(timespec="seconds"), "modelos": r["modelos"]}
        else:
            ant.update(ok=False, erro=r["erro"], falhou_em=agora.isoformat(timespec="seconds"))
            docs[doc] = ant
            avisos.append(f"privacidade OpenCode ({doc}): {r['erro']}; mantenho a última conferência "
                          f"({ant.get('conferido_em') or 'nenhuma'}) até {int(_cfg('privacidade.max_idade_dias', 7))} dias")
    est["atualizado_em"] = agora.isoformat(timespec="seconds")
    try:
        caminho.parent.mkdir(parents=True, exist_ok=True)
        tmp = caminho.with_suffix(".tmp")
        tmp.write_text(json.dumps(est, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(caminho)
    except OSError as exc:
        avisos.append(f"privacidade OpenCode: não gravei o estado ({exc})")
    return est, avisos


def precisa_atualizar(est: dict, agora: Optional[dt.datetime] = None) -> bool:
    agora = agora or dt.datetime.now()
    try:
        ult = dt.datetime.fromisoformat(est["atualizado_em"])
    except (KeyError, ValueError, TypeError):
        return True
    return (agora - ult).total_seconds() >= float(_cfg("privacidade.intervalo_h", 24)) * 3600


def exige_sem_treino() -> bool:
    """Regra de 21/10/2026 (só modelo que não treina e com retenção curta). Desligada por padrão
    desde 23/10/2026 20h20; `privacidade.exigir_sem_treino = true` nos Ajustes a religa."""
    return bool(_cfg("privacidade.exigir_sem_treino", False))


def pode_receber_codigo(modelo: str, est: Optional[dict] = None,
                        hoje: Optional[dt.date] = None) -> tuple[bool, str]:
    """(pode, motivo). `modelo` no formato do CLI: `opencode/x` (Zen) ou `opencode-go/x` (Go).
    Desde 23/10/2026 20h20, treino e registro de uso não bloqueiam (vale para lanes e revisão);
    bloqueiam só a exceção manual `bloquear` e um prefixo fora das fontes do OpenCode.
    Com `privacidade.exigir_sem_treino` ligado volta a regra de 21/10 (fail-closed): sem
    conferência, sem o modelo na documentação, com treino, com retenção acima do limite, com
    acordo vencido ou com conferência velha, não pode."""
    hoje = hoje or dt.date.today()
    exc = (_cfg("privacidade.excecoes", {}) or {}).get(modelo)
    if exc in ("permitir", "bloquear"):
        return exc == "permitir", f"exceção manual nos Ajustes ({exc})"
    prefixo, _, mid = modelo.partition("/")
    doc = next((d for d, f in fontes().items() if f["prefixo"] == prefixo), None)
    if not doc or not mid:
        return False, f"modelo `{modelo}` fora das fontes conhecidas do OpenCode"
    est = ler_estado() if est is None else est
    if not exige_sem_treino():
        # Decisão de 23/10/2026 20h20: modelo free que registra ou treina com o uso
        # também pode receber código, nas lanes e na revisão, quando for a melhor opção free.
        # A conferência da documentação continua só como informação (o motivo diz o que ela sabe).
        m = (((est.get("docs") or {}).get(doc) or {}).get("modelos") or {}).get(mid) or {}
        if m.get("treina"):
            return True, f"`{mid}` pode registrar ou treinar com o uso (permitido desde 23/10/2026)"
        if m:
            return True, f"`{mid}`: não treina, retenção {m.get('retencao_dias')} dias"
        return True, f"`{mid}`: sem regra na documentação; treino e registro de uso permitidos desde 23/10/2026"
    d = (est.get("docs") or {}).get(doc) or {}
    if not d.get("conferido_em"):
        return False, f"privacidade do OpenCode ({doc}) nunca conferida"
    idade = (hoje - dt.date.fromisoformat(d["conferido_em"][:10])).days
    if idade > int(_cfg("privacidade.max_idade_dias", 7)):
        return False, f"última conferência da privacidade ({doc}) tem {idade} dias"
    m = (d.get("modelos") or {}).get(mid)
    if not m:
        return False, f"`{mid}` não aparece na documentação de privacidade ({doc})"
    if m.get("treina"):
        return False, f"`{mid}` pode usar os dados para treino/melhoria ({(m.get('nota') or '')[:90]})"
    ret = m.get("retencao_dias")
    limite = int(_cfg("privacidade.max_retencao_dias", 30))
    if ret is None:
        return False, f"`{mid}` sem retenção informada"
    if ret > limite:
        return False, f"`{mid}` retém por {ret} dias (limite {limite})"
    if m.get("valido_ate") and dt.date.fromisoformat(m["valido_ate"]) < hoje:
        return False, f"o acordo de retenção zero de `{mid}` venceu em {m['valido_ate']}"
    return True, f"`{mid}`: não treina, retenção {ret} dias (conferido em {d['conferido_em'][:10]})"


if __name__ == "__main__":  # pragma: no cover
    import sys
    if "--atualizar" in sys.argv:
        _, av = atualizar()
        for a in av:
            print("AVISO:", a)
    est = ler_estado()
    for doc, d in (est.get("docs") or {}).items():
        print(f"[{doc}] {d.get('repo')}:{d.get('caminho')} conferido {d.get('conferido_em')} ok={d.get('ok')}")
    for m in sys.argv[1:]:
        if not m.startswith("--"):
            print(m, pode_receber_codigo(m, est))
