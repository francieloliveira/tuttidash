#!/usr/bin/env python3
"""Gera dados de EXEMPLO para a foto do painel (docs/imagens) e para conferir o layout.

Nada aqui é lido pelo app em uso normal: o app só olha estes arquivos quando é aberto com
TRANSCENTIA_GASTO_CONFIG apontando para o config.json gerado (ver foto.sh).

Uso: python3 gerar.py <pasta-de-saida> [--prova]
  --prova  põe uma prova em curso na lane opencode (para a página Testes)
"""
import datetime as dt
import json
import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
com_prova = "--prova" in sys.argv
saida = os.path.abspath(args[0] if args else "/tmp/tuttidash-exemplo")
estado = os.path.join(saida, "estado")
logs = os.path.join(saida, "logs")
os.makedirs(estado, exist_ok=True)
os.makedirs(logs, exist_ok=True)

agora = dt.datetime.now().replace(microsecond=0)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%S")


def semana(d):
    a, s, _ = d.isocalendar()
    return f"{a:04d}-W{s:02d}"


registros = []


def execucao(card, lane, inicio, custo=None, status="ok", dur_min=20):
    ident = f"{card}-{lane}-{inicio.strftime('%Y%m%d-%H%M%S')}"
    r = {"id": ident, "card": card, "lane": lane, "inicio": iso(inicio), "dia": inicio.strftime("%Y-%m-%d"),
         "semana": semana(inicio), "status": status, "duracao_ms": dur_min * 60_000}
    if custo is not None:
        r["custo"] = "estimado"
        r["custo_usd"] = round(custo, 2)
    else:
        r["custo"] = "desconhecido"
    registros.append(r)
    return ident


hoje = agora.replace(hour=0, minute=0, second=0)
seg = hoje - dt.timedelta(days=hoje.weekday())        # segunda desta semana


def dia(offset_da_segunda, h, m=0):
    return seg + dt.timedelta(days=offset_da_segunda, hours=h, minutes=m)


def antes(minutos):
    return agora - dt.timedelta(minutes=minutos)


# Top 5 dos últimos 7 dias (todos claude, como na imagem)
for i, c in enumerate([3.10, 3.60, 3.69, 4.00]):
    execucao("FRA-453", "claude", antes(36 + 60 * (4 - i)), c, "erro" if i == 1 else "ok")
for i, c in enumerate([2.70, 2.70, 2.80, 2.80, 2.78]):
    execucao("FRA-108", "claude", dia(1, 9 + i), c)
for i, c in enumerate([1.80, 1.90, 1.90, 1.90, 1.88, 1.88]):
    execucao("FRA-506", "claude", dia(0, 9 + i), c)
for i, c in enumerate([3.00, 3.00, 2.98]):
    execucao("FRA-508", "claude", antes(22 + 30 * (3 - i)), c)
for i, c in enumerate([2.30, 2.30, 2.40]):
    execucao("FRA-126", "claude", dia(-2, 10 + i), c)          # sábado: semana anterior
execucao("FRA-460", "claude", dia(2, 15), 1.50)

# Demais lanes: cada card abaixo de US$ 7 para não entrar no top 5
for card, lane, valores, base in [
    ("FRA-301", "codex", [3.40, 3.49], (1, 14)), ("FRA-302", "codex", [3.44, 3.45], (2, 11)),
    ("FRA-260", "opencode", [2.80, 2.83], (0, 15)), ("FRA-261", "opencode", [2.81, 2.82], (2, 16)),
    ("FRA-270", "opencode-go", [2.24, 2.25], (1, 16)), ("FRA-271", "opencode-go", [2.24, 2.25], (2, 9)),
    ("FRA-280", "grok", [1.75, 1.75], (0, 11)), ("FRA-281", "grok", [1.75, 1.75], (1, 11)),
]:
    for i, v in enumerate(valores):
        execucao(card, lane, dia(base[0], base[1] + i), v)

# Sexta, sábado e domingo anteriores (aparecem no gráfico dos 7 dias)
for d, h, v in [(-3, 10, 4.0), (-3, 14, 4.0), (-2, 15, 6.0), (-1, 10, 7.0), (-1, 15, 7.0)]:
    execucao(f"FRA-{400 + h}", "codex", dia(d, h), v)

# Semana anterior até o mesmo ponto: ~126 → custo da semana cai 28%
for i in range(6):
    execucao(f"FRA-{350 + i}", ["claude", "codex", "opencode"][i % 3], dia(-7 + (i % 4), 10 + i), 21.05)

# Hoje: 12 builds (2 falhas nas últimas 24 h), ontem 10
execucao("FRA-453", "claude", antes(8), None, "em_andamento")
execucao("FRA-260", "opencode", antes(12), None, "em_andamento")
execucao("FRA-271", "opencode-go", antes(28), 0.40)
execucao("FRA-302", "codex", antes(120), 0.30, "erro")
execucao("FRA-281", "grok", antes(180), 0.20)
for i in range(4):
    execucao(f"FRA-49{i}", "opencode", antes(200 + 25 * i), None)
ontem = hoje - dt.timedelta(days=1)
while sum(1 for r in registros if r["dia"] == hoje.strftime("%Y-%m-%d")) < 12:
    execucao("FRA-495", "opencode-go", max(antes(320 + (9 * len(registros)) % 200), hoje + dt.timedelta(minutes=1 + len(registros))), None)
n_ontem = sum(1 for r in registros if r["dia"] == ontem.strftime("%Y-%m-%d"))
for i in range(max(0, 10 - n_ontem)):
    execucao(f"FRA-48{i}", "opencode", ontem + dt.timedelta(hours=8, minutes=50 * i), None)

# Histórico antigo: completa o número das builds (claude fica com a #2258)
faltam = 2258 - len(registros)
inicio_ano = dt.datetime(agora.year, 1, 5, 9)
for i in range(faltam):
    d = inicio_ano + dt.timedelta(minutes=int(i * (260 * 24 * 60 / max(faltam, 1))))
    execucao(f"FRA-{1000 + i % 900}", ["claude", "codex", "opencode", "grok"][i % 4], d, 0.05)

with open(os.path.join(saida, "ledger.jsonl"), "w") as f:
    for r in registros:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")

# Estado das lanes
with open(os.path.join(estado, "heartbeat.json"), "w") as f:
    json.dump({"at": (agora - dt.timedelta(seconds=16)).strftime("%Y-%m-%d %H:%M:%S"), "dry_run": False,
               "enabled": ["claude", "codex", "opencode", "opencode-go"],
               "implemented": ["claude", "codex", "opencode", "opencode-go", "grok"]}, f)
with open(os.path.join(estado, "enabled"), "w") as f:
    f.write("claude codex opencode opencode-go\n")
for lane, card, branch, minutos in [("claude", "FRA-453", "main", 8), ("opencode", "FRA-260", "feature/card", 12)]:
    ini = antes(minutos)
    with open(os.path.join(estado, f"lane-{lane}.json"), "w") as f:
        json.dump({"lane": lane, "card": card, "title": "Card de exemplo", "branch": branch,
                   "worktree": os.path.join(saida, "wt-" + lane), "started_at": ini.strftime("%Y-%m-%d %H:%M:%S"),
                   "log": os.path.join(logs, f"{card}-{lane}-{ini.strftime('%Y%m%d-%H%M%S')}.jsonl")}, f)
if com_prova:
    lane_dir = os.path.join(saida, "wt-opencode", ".lane")
    os.makedirs(lane_dir, exist_ok=True)
    with open(os.path.join(lane_dir, "proof_started"), "w") as f:
        f.write(str(int((agora - dt.timedelta(minutes=4, seconds=12)).timestamp())))
    log = ["[prova] AppTests: 1ª tentativa SKIP_PREFLIGHT=1", "Compiling App"]
    for i in range(86):
        nome = "SyncRelogioTests" if i == 17 else ("AgendaWidgetTests" if i == 53 else f"Suite{i:03d}Tests")
        estado_caso = "failed" if i in (17, 53) else "passed"
        log.append(f"Test Case '-[{nome} testCaso]' {estado_caso} ({0.4 + i % 7 / 10:.3f} seconds)")
    with open(os.path.join(lane_dir, "proof.log"), "w") as f:
        f.write("\n".join(log) + "\n")
else:
    import shutil
    shutil.rmtree(os.path.join(saida, "wt-opencode"), ignore_errors=True)
with open(os.path.join(estado, "medida-cache.json"), "w") as f:
    json.dump({"at": agora.timestamp(), "m": {"codex": [93, "7d"], "claude": [62, "5h"]}}, f)
with open(os.path.join(estado, "opencode-strikes.json"), "w") as f:
    json.dump({"strikes": 0}, f)

# Log do dispatcher: as cinco entregas da imagem
linhas = []
for minutos, card, pr in [(291, "FRA-186", "PR #222"), (220, "FRA-176", "PR #223"), (147, "FRA-126", "PR #224"),
                          (66, "FRA-108", "PR #225"), (58, "FRA-192", "")]:
    quando = antes(minutos).strftime("%Y-%m-%d %H:%M:%S")
    linhas.append(f"{quando} lane:opencode FECHOU {card} → {pr}".rstrip(" →"))
with open(os.path.join(saida, "lanes-dispatcher.log"), "w") as f:
    f.write("\n".join(linhas) + "\n")

with open(os.path.join(saida, "config.json"), "w") as f:
    json.dump({"version": 1, "logs_dir": logs, "state_dir": estado, "ledger": os.path.join(saida, "ledger.jsonl"),
               "uso_contas": False, "linear": {"owner_label": "claude"}}, f, indent=2)
print(saida)
