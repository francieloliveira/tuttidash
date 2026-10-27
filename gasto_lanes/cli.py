"""Linha de comando: coletar, relatorio, execucoes, teto, config.

Exit codes:
  0  ok (ou abaixo do teto)
  1  erro (config inválida, ledger ilegível...)
  2  uso inválido (argparse)
  3  perto do teto semanal (>= aviso_pct)
  4  teto semanal atingido ou estourado
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from typing import Optional

from . import __version__
from . import config as cfgmod
from . import ledger as ledgermod
from . import report
from .estado import read_state


def _date(s: str) -> dt.date:
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"data inválida: {s} (use AAAA-MM-DD)") from None


def _csv(s: str) -> list:
    return [x.strip() for x in s.split(",") if x.strip()]


def _common(p: argparse.ArgumentParser) -> None:
    g = p.add_argument_group("caminhos (flag > variável de ambiente > config > padrão)")
    g.add_argument("--logs", dest="logs_dir", metavar="PASTA",
                   help=f"pasta dos logs das lanes (env {cfgmod.ENV['logs_dir']})")
    g.add_argument("--estado", dest="state_dir", metavar="PASTA",
                   help=f"pasta de estado das lanes (env {cfgmod.ENV['state_dir']})")
    g.add_argument("--ledger", dest="ledger", metavar="ARQUIVO",
                   help=f"ledger.jsonl da ferramenta (env {cfgmod.ENV['ledger']})")
    g.add_argument("--config", dest="config", metavar="ARQUIVO",
                   help=f"arquivo de config JSON (env {cfgmod.ENV_CONFIG})")


def _filters(p: argparse.ArgumentParser) -> None:
    p.add_argument("--desde", type=_date, metavar="AAAA-MM-DD")
    p.add_argument("--ate", type=_date, metavar="AAAA-MM-DD")
    p.add_argument("--ultimos-dias", type=int, metavar="N", help="só os últimos N dias (inclui hoje)")
    p.add_argument("--lane", type=_csv, metavar="L1,L2")
    p.add_argument("--card", type=_csv, metavar="FRA-1,FRA-2")
    p.add_argument("--sem-coletar", action="store_true",
                   help="não lê os logs; usa só o ledger existente")
    p.add_argument("--json", action="store_true", help="saída em JSON")


def _teto_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--teto-semanal", dest="teto_semanal_usd", type=float, metavar="USD",
                   help=f"teto semanal em US$ (só avisa; env {cfgmod.ENV['teto_semanal_usd']})")
    p.add_argument("--aviso-pct", dest="aviso_pct", type=float, metavar="PCT",
                   help=f"avisa a partir de PCT%% do teto (padrão {cfgmod.AVISO_PCT_PADRAO:g})")
    p.add_argument("--hoje", type=_date, metavar="AAAA-MM-DD", help=argparse.SUPPRESS)


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="gasto",
        description="Controle de gasto das lanes do TranscentIA. Somente leitura sobre logs e "
                    "estado das lanes; o único arquivo gravado é o ledger da própria ferramenta.")
    ap.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = ap.add_subparsers(dest="cmd", metavar="comando")
    sub.required = True

    p = sub.add_parser("coletar", help="lê os logs e atualiza o ledger (idempotente)")
    _common(p)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("relatorio", help="totais por dia, semana, card e lane")
    _common(p)
    _filters(p)
    _teto_args(p)
    p.add_argument("--por", type=_csv, metavar="DIMS",
                   help="dimensões, separadas por vírgula: dia,semana,card,lane (padrão: todas)")

    p = sub.add_parser("execucoes", help="lista as execuções, uma por linha")
    _common(p)
    _filters(p)
    p.add_argument("--limite", type=int, default=30, metavar="N", help="últimas N (padrão 30; 0 = todas)")

    p = sub.add_parser("teto", help="confere o teto semanal (só avisa: exit 3 perto, 4 estourado)")
    _common(p)
    _teto_args(p)
    p.add_argument("--sem-coletar", action="store_true")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("config", help="mostra caminhos resolvidos e de onde vieram")
    _common(p)
    p.add_argument("--json", action="store_true")
    return ap


def _resolve(args) -> dict:
    cli = {k: getattr(args, k, None) for k in ("logs_dir", "state_dir", "ledger", "config",
                                               "teto_semanal_usd", "aviso_pct")}
    return cfgmod.resolve(cli)


def _gather(args, vals: dict, out_err) -> tuple:
    """(registros, estado, stats|None)."""
    estado = read_state(vals["state_dir"])
    if getattr(args, "sem_coletar", False):
        return list(ledgermod.load(vals["ledger"]).values()), estado, None
    stats = ledgermod.collect(vals["logs_dir"], vals["ledger"], estado["logs_em_andamento"])
    if not stats["logs_dir_existe"]:
        print(f"aviso: pasta de logs não encontrada: {vals['logs_dir']} (usando só o ledger)", file=out_err)
    return list(stats["registros"].values()), estado, stats


def _apply_filters(args, recs: list, hoje: dt.date) -> tuple:
    desde = args.desde
    if args.ultimos_dias:
        d = hoje - dt.timedelta(days=args.ultimos_dias - 1)
        desde = max(desde, d) if desde else d
    filtros = {"desde": desde.isoformat() if desde else None,
               "ate": args.ate.isoformat() if args.ate else None,
               "lane": args.lane, "card": [c.upper() for c in args.card] if args.card else None}
    out = report.filtrar(recs, desde, args.ate, set(args.lane) if args.lane else None,
                         set(filtros["card"]) if filtros["card"] else None)
    return out, {k: v for k, v in filtros.items() if v}


def _print_json(obj, out) -> None:
    out.write(json.dumps(obj, ensure_ascii=False, indent=2, default=str) + "\n")


def main(argv: Optional[list] = None, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    for stream in (out, err):
        try:
            stream.reconfigure(errors="replace")  # console do Windows sem UTF-8
        except (AttributeError, ValueError):
            pass
    args = build_parser().parse_args(argv)
    try:
        resolved = _resolve(args)
    except cfgmod.ConfigError as exc:
        print(f"erro: {exc}", file=err)
        return 1
    vals = resolved["valores"]

    if args.cmd == "config":
        data = {k: str(v) if v is not None else None for k, v in vals.items()}
        data = {"valores": data, "origem": resolved["origem"], "config_file": str(resolved["config_file"]),
                "config_file_existe": resolved["config_file"].exists()}
        if args.json:
            _print_json(data, out)
        else:
            for k, v in data["valores"].items():
                out.write(f"{k:17} {v}  [{data['origem'][k]}]\n")
            out.write(f"{'config':17} {data['config_file']}"
                      f"{'' if data['config_file_existe'] else ' (não existe; opcional)'}\n")
        return 0

    try:
        if args.cmd == "coletar":
            estado = read_state(vals["state_dir"])
            stats = ledgermod.collect(vals["logs_dir"], vals["ledger"], estado["logs_em_andamento"])
            resumo = {k: stats[k] for k in ("novas", "atualizadas", "sem_mudanca", "ignorados", "gravou",
                                            "logs_dir_existe")}
            resumo["total_no_ledger"] = len(stats["registros"])
            resumo["ledger"] = str(vals["ledger"])
            if args.json:
                _print_json(resumo, out)
            else:
                if not stats["logs_dir_existe"]:
                    print(f"aviso: pasta de logs não encontrada: {vals['logs_dir']}", file=err)
                out.write(f"{resumo['novas']} novas, {resumo['atualizadas']} atualizadas, "
                          f"{resumo['sem_mudanca']} sem mudança, {len(resumo['ignorados'])} ignorados; "
                          f"{resumo['total_no_ledger']} execuções no ledger ({vals['ledger']})\n")
                for name in resumo["ignorados"]:
                    out.write(f"  ignorado: {name}\n")
            return 0

        hoje = getattr(args, "hoje", None) or dt.date.today()
        recs, estado, _ = _gather(args, vals, err)

        if args.cmd == "teto":
            teto = report.avaliar_teto(recs, vals["teto_semanal_usd"], vals["aviso_pct"], hoje)
            if teto is None:
                print("erro: teto semanal não configurado (--teto-semanal, "
                      f"{cfgmod.ENV['teto_semanal_usd']} ou 'teto_semanal_usd' na config)", file=err)
                return 1
            if args.json:
                _print_json(teto, out)
            else:
                out.write(report.teto_txt(teto) + "\n")
            return teto["exit_code"]

        recs, filtros = _apply_filters(args, recs, hoje)

        if args.cmd == "execucoes":
            if args.limite and args.limite > 0:
                recs = recs[-args.limite:]
            if args.json:
                _print_json(recs, out)
            else:
                out.write(report.execucoes_txt(recs) + "\n")
            return 0

        # relatorio
        dims = args.por or list(report.DIMENSOES)
        bad = [d for d in dims if d not in report.DIMENSOES]
        if bad:
            print(f"erro: dimensão inválida: {', '.join(bad)} (use {', '.join(report.DIMENSOES)})", file=err)
            return 2
        # O teto olha a semana inteira de hoje, independente dos filtros de data.
        # Depois da coleta o ledger já está atualizado: relê inteiro.
        base_teto = list(ledgermod.load(vals["ledger"]).values())
        teto = report.avaliar_teto(base_teto, vals["teto_semanal_usd"], vals["aviso_pct"], hoje)
        if args.json:
            _print_json(report.render_json(recs, dims, teto, estado, filtros), out)
        else:
            ftxt = ", ".join(f"{k} {','.join(v) if isinstance(v, list) else v}" for k, v in filtros.items())
            out.write(report.render_text(recs, dims, teto, estado, ftxt) + "\n")
        return teto["exit_code"] if teto else 0
    except (OSError, ValueError) as exc:
        print(f"erro: {type(exc).__name__}: {exc}", file=err)
        return 1

