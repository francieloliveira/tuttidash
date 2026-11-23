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
from . import auditoria as auditoriamod
from . import backup as backupmod
from . import config as cfgmod
from . import doutor as doutormod
from . import eventos as eventosmod
from . import fluxo as fluxomod
from . import integracoes as integracoesmod
from . import isolamento as isolamentomod
from . import ledger as ledgermod
from . import projetos as projetosmod
from . import report
from . import semanal as semanalmod
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
    p.add_argument("--projeto", type=_csv, metavar="ID,NOME",
                   help="filtra pelo id ou pelo nome do projeto gravado no log/ledger")
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
                   help="dimensões, separadas por vírgula: dia,semana,projeto,card,lane (padrão: todas)")

    p = sub.add_parser("execucoes", help="lista as execuções, uma por linha")
    _common(p)
    _filters(p)
    p.add_argument("--limite", type=int, default=30, metavar="N", help="últimas N (padrão 30; 0 = todas)")

    p = sub.add_parser("teto", help="confere o teto semanal (só avisa: exit 3 perto, 4 estourado)")
    _common(p)
    _teto_args(p)
    p.add_argument("--sem-coletar", action="store_true")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("eventos", help="lê o log de eventos do fluxo (claim, finalize, merge)")
    _common(p)
    p.add_argument("--projeto", metavar="ID", help="só eventos deste projeto")
    p.add_argument("--card", metavar="FRA-1", help="só eventos deste card")
    p.add_argument("--limite", type=int, default=30, metavar="N", help="últimos N (padrão 30; 0 = todos)")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("fluxo", help="resume claims, finais, merges e duração por projeto")
    _common(p)
    p.add_argument("--projeto", metavar="ID", help="só este projeto")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("semanal", help="relatório dos últimos 7 dias por projeto (texto ou Markdown)")
    _common(p)
    p.add_argument("--dias", type=int, default=7, metavar="N", help="janela em dias (padrão 7)")
    p.add_argument("--hoje", type=_date, metavar="AAAA-MM-DD", help=argparse.SUPPRESS)
    p.add_argument("--projeto", metavar="ID", help="só este projeto")
    p.add_argument("--enviar", action="store_true", help="envia o texto ao webhook configurado")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("auditoria", help="trilha de eventos por projeto/card/etapa")
    _common(p)
    p.add_argument("--projeto", metavar="ID")
    p.add_argument("--card", metavar="FRA-1")
    p.add_argument("--etapa", choices=["claim", "finalize", "merge"])
    p.add_argument("--desde", type=_date, metavar="AAAA-MM-DD")
    p.add_argument("--ate", type=_date, metavar="AAAA-MM-DD")
    p.add_argument("--limite", type=int, default=0, metavar="N", help="últimos N (0 = todos)")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("backup", help="exporta estado, ledger, eventos e (opcional) config")
    _common(p)
    p.add_argument("--destino", required=True, metavar="ARQUIVO.tar.gz")
    p.add_argument("--incluir-config", action="store_true", help="inclui o config.json")
    p.add_argument("--incluir-provas", action="store_true", help="inclui a pasta provas/ (pode ser grande)")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("restaurar", help="confere e restaura um backup")
    _common(p)
    p.add_argument("--arquivo", required=True, metavar="ARQUIVO.tar.gz")
    p.add_argument("--forcar", action="store_true", help="substitui estado/ledger/config existentes")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("doutor", help="diagnostica config, pastas, repos, worktrees, proxy e gh")
    _common(p)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("notificar", help="envia um texto ao webhook configurado")
    _common(p)
    p.add_argument("--texto", default="", help="texto a enviar")
    p.add_argument("--arquivo", metavar="ARQUIVO", help="lê o texto deste arquivo")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("planejamento", help="ordem, ocupação, custo, fluxo e sinais por projeto")
    _common(p)
    p.add_argument("--hoje", type=_date, metavar="AAAA-MM-DD", help=argparse.SUPPRESS)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("isolamento", help="audita a fronteira de projeto de cada lane")
    _common(p)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("seguranca", help="audita permissões do estado/config/ledger")
    _common(p)
    p.add_argument("--corrigir", action="store_true", help="aplica 0700/0600")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("retencao", help="planeja/aplica corte por data no eventos.jsonl e no ledger")
    _common(p)
    p.add_argument("--eventos-dias", type=int, default=0, metavar="N", help="0 = não mexe")
    p.add_argument("--ledger-dias", type=int, default=0, metavar="N", help="0 = não mexe")
    p.add_argument("--hoje", type=_date, metavar="AAAA-MM-DD", help=argparse.SUPPRESS)
    p.add_argument("--aplicar", action="store_true", help="sem isto, só conta")
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
               "lane": args.lane, "card": [c.upper() for c in args.card] if args.card else None,
               "projeto": args.projeto}
    out = report.filtrar(recs, desde, args.ate, set(args.lane) if args.lane else None,
                         set(filtros["card"]) if filtros["card"] else None,
                         set(args.projeto) if args.projeto else None)
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
        if args.cmd == "isolamento":
            try:
                projetosmod.recarregar()
                lista_projetos = projetosmod.projetos()
            except Exception:  # noqa: BLE001
                lista_projetos = []
            achados = isolamentomod.revisar(vals["state_dir"], lista_projetos,
                                            log_dir=vals["logs_dir"])
            resumo = isolamentomod.resumo(achados)
            if args.json:
                _print_json(resumo, out)
            else:
                out.write(isolamentomod.texto(achados) + "\n")
            return 1 if resumo["erros"] else 0
        if args.cmd == "seguranca":
            achados = segurancamod.revisar(vals["state_dir"], config=resolved["config_file"],
                                           ledger=vals["ledger"], corrigir=args.corrigir)
            resumo = segurancamod.resumo(achados)
            if args.json:
                _print_json(resumo, out)
            else:
                out.write(segurancamod.texto(achados) + "\n")
            return 1 if resumo["erros"] else 0
        if args.cmd == "retencao":
            hoje = getattr(args, "hoje", None) or dt.date.today()
            achados = []
            if (getattr(args, "eventos_dias", 0) or 0) > 0:
                achados.append(retencaomod.podar(vals["state_dir"] / "eventos.jsonl", "ts",
                                                args.eventos_dias, hoje, args.aplicar))
            if (getattr(args, "ledger_dias", 0) or 0) > 0:
                achados.append(retencaomod.podar(vals["ledger"], "dia",
                                                args.ledger_dias, hoje, args.aplicar))
            if args.json:
                _print_json(achados, out)
            else:
                if not achados:
                    out.write("retenção desligada: use --eventos-dias/--ledger-dias\n")
                for r in achados:
                    acao = "podado" if r["gravou"] else ("aplicaria" if args.aplicar else "manteria")
                    out.write(f"{r['arquivo']}: {r['manter']} manter, {r['remover']} remover, "
                              f"{r['sem_data']} sem data ({acao})\n")
            return 0
        if args.cmd == "notificar":
            texto = args.texto or ""
            if args.arquivo:
                try:
                    texto = Path(args.arquivo).read_text(encoding="utf-8")
                except OSError as exc:
                    print(f"erro: {exc}", file=err)
                    return 1
            url = integracoesmod.webhook(lambda k, d: cfgmod.obter(k, d))
            r = integracoesmod.enviar(url, texto)
            if args.json:
                _print_json(r, out)
            else:
                out.write(("enviado" if r["ok"] else "não enviado: " + r["erro"]) + "\n")
            return 0 if r["ok"] else 1
        if args.cmd == "planejamento":
            recs, estado, _ = _gather(args, vals, err)
            evs = eventosmod.ler(vals["state_dir"] / "eventos.jsonl")
            try:
                projetosmod.recarregar()
                lista_projetos = projetosmod.projetos()
            except Exception:  # noqa: BLE001
                lista_projetos = []
            hoje = getattr(args, "hoje", None) or dt.date.today()
            quadro = planejamentomod.quadro(lista_projetos, recs, evs,
                                            estado_lanes=estado.get("lanes", {}).values(), hoje=hoje)
            if args.json:
                _print_json(quadro, out)
            else:
                out.write(planejamentomod.texto(quadro) + "\n")
            return 0
        if args.cmd == "auditoria":
            evs = auditoriamod.filtrar(eventosmod.ler(vals["state_dir"] / "eventos.jsonl"),
                                        projeto=getattr(args, "projeto", "") or "",
                                        card=getattr(args, "card", "") or "",
                                        etapa=getattr(args, "etapa", "") or "",
                                        desde=getattr(args, "desde", None),
                                        ate=getattr(args, "ate", None))
            limite = getattr(args, "limite", 0) or 0
            if limite > 0:
                evs = evs[-limite:]
            if args.json:
                _print_json(evs, out)
            else:
                if not evs:
                    out.write("nenhum evento de auditoria\n")
                else:
                    out.write("\n".join(auditoriamod.linhas(evs)) + "\n")
            return 0
        if args.cmd == "backup":
            manifesto = backupmod.exportar(
                args.destino, state_dir=vals["state_dir"], ledger=vals["ledger"],
                config=resolved["config_file"], incluir_config=args.incluir_config,
                incluir_provas=args.incluir_provas)
            if args.json:
                _print_json(manifesto, out)
            else:
                out.write(f"backup: {args.destino} ({len(manifesto['arquivos'])} arquivos, "
                          f"versão {manifesto['versao']})\n")
            return 0
        if args.cmd == "restaurar":
            conferido = backupmod.verificar(args.arquivo)
            if not conferido["ok"]:
                print("erro: backup inválido: " + "; ".join(conferido["erros"]), file=err)
                return 1
            restaurado = backupmod.restaurar(
                args.arquivo, state_dir=vals["state_dir"], ledger=vals["ledger"],
                config=resolved["config_file"], forcar=args.forcar)
            if args.json:
                _print_json({"restaurados": restaurado["restaurados"],
                             "manifesto": restaurado["manifesto"]}, out)
            else:
                out.write(f"restaurado: {len(restaurado['restaurados'])} arquivos\n")
            return 0
        if args.cmd == "doutor":
            import types
            try:
                projetosmod.recarregar()
                lista_projetos = projetosmod.projetos()
            except Exception:  # noqa: BLE001
                lista_projetos = []
            cfg = types.SimpleNamespace(arquivoConfig=resolved["config_file"],
                                        stateDir=vals["state_dir"], logsDir=vals["logs_dir"],
                                        ledger=vals["ledger"])
            try:
                agenda_ligada = bool(cfgmod.obter("agenda.multiprojeto", False))
            except Exception:  # noqa: BLE001
                agenda_ligada = False
            achados = doutormod.checar(cfg, lista_projetos, agenda_ligada=agenda_ligada)
            resumo = doutormod.resumo(achados)
            if args.json:
                _print_json(resumo, out)
            else:
                out.write(doutormod.texto(achados) + "\n")
            return 1 if resumo["erros"] else 0
        if args.cmd == "semanal":
            recs, _estado, _ = _gather(args, vals, err)
            eventos = eventosmod.ler(vals["state_dir"] / "eventos.jsonl")
            try:
                projetosmod.recarregar()
                lista_projetos = projetosmod.projetos()
            except Exception:  # noqa: BLE001 — sem cadastro: o relatório usa os ids do ledger
                lista_projetos = []
            hoje = getattr(args, "hoje", None) or dt.date.today()
            resumo = semanalmod.gerar(recs, eventos, lista_projetos, hoje=hoje,
                                      dias=getattr(args, "dias", 7) or 7)
            filtro = getattr(args, "projeto", "") or ""
            if filtro:
                resumo["projetos"] = [p for p in resumo["projetos"]
                                      if filtro in (p["projeto"], p["nome"])]
            texto = semanalmod.texto(resumo)
            if args.json:
                _print_json(resumo, out)
            else:
                out.write(texto)
            if getattr(args, "enviar", False):
                url = integracoesmod.webhook(lambda k, d: cfgmod.obter(k, d))
                r = integracoesmod.enviar(url, texto)
                if not r["ok"]:
                    print(f"aviso: não enviei o relatório: {r['erro']}", file=err)
            return 0
        if args.cmd == "fluxo":
            caminho = vals["state_dir"] / "eventos.jsonl"
            resumo = fluxomod.resumo(eventosmod.ler(caminho, projeto=getattr(args, "projeto", "") or ""))
            if args.json:
                _print_json(resumo, out)
            else:
                out.write(fluxomod.texto(resumo) + "\n")
            return 0
        if args.cmd == "eventos":
            caminho = vals["state_dir"] / "eventos.jsonl"
            evs = eventosmod.ler(caminho, projeto=getattr(args, "projeto", "") or "",
                                 card=getattr(args, "card", "") or "",
                                 limite=getattr(args, "limite", 0) or 0)
            if args.json:
                _print_json(evs, out)
            else:
                if not evs:
                    out.write(f"nenhum evento em {caminho}\n")
                for ev in evs:
                    partes = [str(ev.get("ts") or ""), str(ev.get("card") or ""),
                              str(ev.get("lane") or ""), str(ev.get("etapa") or "")]
                    if ev.get("status"):
                        partes.append(str(ev["status"]))
                    if ev.get("pr"):
                        partes.append(str(ev["pr"]))
                    if ev.get("motivo"):
                        partes.append(str(ev["motivo"]))
                    out.write("  ".join(partes) + "\n")
            return 0
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

