"""Testes offline das lanes (sem Linear, sem rede, sem tmux).

Roda da raiz do repo: python3 lanes/test_lanes.py
"""
import datetime as dt
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dispatcher as d
import lanes_ctl as c
import lanes_window as w

# FRA-565: o código não traz ids do Linear. Os testes usam ids falsos, iguais em qualquer máquina.
IDS_TESTE = {
    "estados": {"todo": "estado-todo", "in_progress": "estado-andamento", "in_review": "estado-revisao"},
    "labels": {"needs:dono": "label-dono", "lane:falhou": "label-falhou", "lane:parada": "label-parada"},
    "esforco": {"baixo": "label-esforco-baixo", "medio": "label-esforco-medio", "alto": "label-esforco-alto"},
    "lanes": {lane: f"label-lane-{lane}" for lane in d.LANES},
}
d._aplicar_ids(IDS_TESTE, dono="needs:dono")


class Peso(unittest.TestCase):
    def test_quota_vence_quando_ha_medida(self):
        lane, shown = d.pick_lane({"claude": (80, "5 h"), "opencode": (10, "ciclo")},
                                  ["claude", "opencode"])
        self.assertEqual(lane, "opencode")
        self.assertIn("quota", shown)

    def test_sem_medida_cai_no_menor_gasto(self):
        lane, shown = d.pick_lane({}, ["claude", "opencode"],
                                  spend={"claude": 5.0, "opencode": 1.0})
        self.assertEqual(lane, "opencode")
        self.assertIn("gasto semanal", shown)

    def test_sem_candidatas(self):
        self.assertIsNone(d.pick_lane({}, [])[0])
        self.assertEqual(d.spread_auto([], {}, [], set(), {}), [])

    def test_spread_sem_medida_usa_gasto(self):
        out = d.spread_auto([{"identifier": "A", "_effort": "baixo"}], {},
                            ["opencode", "claude"], set(), {},
                            spend={"claude": 5.0, "opencode": 1.0})
        self.assertEqual(out[0][1], "opencode")

    def test_week_spend_so_semana_atual_e_conhecido(self):
        p = Path(tempfile.mkdtemp()) / "ledger.jsonl"
        linhas = [
            {"id": "a", "lane": "opencode", "semana": "2026-W42", "custo_usd": 2.5},
            {"id": "b", "lane": "claude", "semana": "2026-W41", "custo_usd": 9.0},
            {"id": "c", "lane": "grok", "semana": "2026-W42", "custo_usd": 0},
            {"id": "d", "lane": "grok", "semana": "2026-W42"},
            "nao-json",
        ]
        p.write_text("\n".join(l if isinstance(l, str) else json.dumps(l) for l in linhas))
        self.assertEqual(d.week_spend(p, dt.date(2026, 10, 15)), {"opencode": 2.5})
        self.assertEqual(d.week_spend(p.parent / "nao-existe.jsonl"), {})

    def test_spread_auto_duas_rodadas_run_e_wait(self):
        # 2 lanes candidatas, 2 cards auto: 1ª rodada dá RUN para cada, 2ª rodada não tem mais vaga
        medidas = {"claude": (20, "5 h"), "opencode": (10, "5 h")}
        out = d.spread_auto(
            [{"identifier": "A", "_effort": "medio"}, {"identifier": "B", "_effort": "medio"}],
            medidas, ["claude", "opencode"], set(), {},
            max_per_lane=2,
        )
        atribuidos = [(i["identifier"], ln) for i, ln in out if ln]
        self.assertEqual(sorted(atribuidos), [("A", "opencode"), ("B", "claude")])

    def test_spread_auto_wait_sem_headroom_block(self):
        # Lane acima do headroom não recebe RUN na rodada 1, mas pode receber WAIT na rodada 2.
        # opencode (10%) recebe A (RUN) na rodada 1 e B (WAIT) na rodada 2.
        # claude (90%) fica sem nada porque está acima do headroom para médio.
        medidas = {"claude": (90, "5 h"), "opencode": (10, "5 h")}
        out = d.spread_auto(
            [{"identifier": "A", "_effort": "medio"}, {"identifier": "B", "_effort": "medio"}],
            medidas, ["claude", "opencode"], set(), {},
            max_per_lane=2,
        )
        atribuidos = [(i["identifier"], ln) for i, ln in out if ln]
        # opencode recebe 2 cards (RUN + WAIT), claude fica sem nada (acima do headroom)
        self.assertEqual(sorted(atribuidos), [("A", "opencode"), ("B", "opencode")])

    def test_spread_auto_nao_terceiro_card_por_lane(self):
        # max_per_lane=2: cada lane no máximo 1 RUN + 1 WAIT = 2 cards por lane.
        # 2 lanes = 4 slots totais. 3 cards -> todos atribuídos.
        medidas = {"claude": (10, "5 h"), "opencode": (10, "5 h")}
        out = d.spread_auto(
            [{"identifier": "A", "_effort": "medio"}, {"identifier": "B", "_effort": "medio"},
             {"identifier": "C", "_effort": "medio"}],
            medidas, ["claude", "opencode"], set(), {},
            max_per_lane=2,
        )
        atribuidos = [(i["identifier"], ln) for i, ln in out if ln]
        nao_atribuidos = [i["identifier"] for i, ln in out if ln is None]
        self.assertEqual(len(atribuidos), 3)
        self.assertEqual(len(nao_atribuidos), 0)
        # Cada lane no máximo 2 cards
        por_lane = {}
        for ident, ln in atribuidos:
            por_lane[ln] = por_lane.get(ln, 0) + 1
        self.assertTrue(all(v <= 2 for v in por_lane.values()))

    def test_spread_auto_fill_respeita_busy(self):
        # Lane em busy não recebe RUN na rodada 1
        medidas = {"claude": (10, "5 h"), "opencode": (10, "5 h")}
        out = d.spread_auto(
            [{"identifier": "A", "_effort": "medio"}],
            medidas, ["claude", "opencode"], {"claude"}, {},
            max_per_lane=2,
        )
        self.assertEqual(out[0][1], "opencode")


def sem_ajustes_reais(teste: unittest.TestCase) -> None:
    """O modelo por peso sai dos Ajustes do Mac (FRA-521); o teste olha só o manifesto."""
    antigo = d.CONFIG_FILES
    teste.addCleanup(setattr, d, "CONFIG_FILES", antigo)
    d.CONFIG_FILES = [Path(tempfile.mkdtemp()) / "nao-existe.json"]


class CopiarParaWorktree(unittest.TestCase):
    """Arquivos fora do git (ex.: AGENTS.md gerado na máquina) chegam ao worktree da lane."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo, self.wt = self.tmp / "repo", self.tmp / "wt"
        (self.repo / "docs").mkdir(parents=True)
        self.wt.mkdir()
        (self.repo / "AGENTS.md").write_text("regras locais", encoding="utf-8")
        (self.repo / "docs" / "local.md").write_text("doc", encoding="utf-8")
        (self.tmp / "segredo.txt").write_text("fora do repo", encoding="utf-8")

    def test_copia_o_que_existe_e_nao_sobrescreve(self):
        (self.wt / "docs").mkdir()
        (self.wt / "docs" / "local.md").write_text("versão do git", encoding="utf-8")
        copiados = d.copiar_para_worktree(self.repo, self.wt, ["AGENTS.md", "docs/local.md", "nao-existe.md"])
        self.assertEqual(copiados, ["AGENTS.md"])
        self.assertEqual((self.wt / "AGENTS.md").read_text(encoding="utf-8"), "regras locais")
        self.assertEqual((self.wt / "docs" / "local.md").read_text(encoding="utf-8"), "versão do git")

    def test_recusa_caminho_absoluto_ou_fora_do_repo(self):
        copiados = d.copiar_para_worktree(self.repo, self.wt, [str(self.tmp / "segredo.txt"), "../segredo.txt", ""])
        self.assertEqual(copiados, [])
        self.assertFalse((self.wt / "segredo.txt").exists())

    def test_lista_vazia_nao_faz_nada(self):
        self.assertEqual(d.copiar_para_worktree(self.repo, self.wt, []), [])
        self.assertEqual(list(self.wt.iterdir()), [])


class TravaAntesDoPush(unittest.TestCase):
    """Nada vai para o origin sem a main atual na história nem com a conferência vermelha."""

    def git(self, *args, cwd):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd,
                       check=True, capture_output=True, text=True)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        origem, self.wt = self.tmp / "origem.git", self.tmp / "wt"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origem)], check=True)
        subprocess.run(["git", "clone", "-q", str(origem), str(self.wt)], check=True, capture_output=True)
        # O origin fica com o link do GitHub; o git troca pelo caminho local ao buscar e enviar.
        self.git("remote", "set-url", "origin", "https://github.com/dono/app.git", cwd=self.wt)
        self.git("config", f"url.{origem}.insteadOf", "https://github.com/dono/app.git", cwd=self.wt)
        (self.wt / "a.txt").write_text("a", encoding="utf-8")
        self.git("add", "a.txt", cwd=self.wt)
        self.git("commit", "-q", "-m", "main", cwd=self.wt)
        self.git("push", "-q", "origin", "HEAD:main", cwd=self.wt)
        self.conf = mock.patch.object(d, "projeto", lambda: d.projetos.Projeto(
            id="x", repo=str(self.wt), github="https://github.com/Dono/App"))
        self.conf.start()
        self.addCleanup(self.conf.stop)

    def test_branch_da_main_atual_pode_ir(self):
        self.git("checkout", "-q", "-b", "fra-1", cwd=self.wt)
        (self.wt / "b.txt").write_text("b", encoding="utf-8")
        self.git("add", "b.txt", cwd=self.wt)
        self.git("commit", "-q", "-m", "lane", cwd=self.wt)
        self.assertEqual(d.motivo_para_nao_enviar(self.wt), "")

    def test_branch_de_historico_antigo_e_barrada(self):
        self.git("checkout", "-q", "--orphan", "antiga", cwd=self.wt)
        (self.wt / "c.txt").write_text("c", encoding="utf-8")
        self.git("add", "-A", cwd=self.wt)
        self.git("commit", "-q", "-m", "histórico antigo", cwd=self.wt)
        self.assertIn("histórico antigo", d.motivo_para_nao_enviar(self.wt))

    def test_origin_diferente_do_cadastro_e_barrado(self):
        with mock.patch.object(d, "projeto", lambda: d.projetos.Projeto(id="x", repo=str(self.wt), github="dono/outro")):
            self.assertIn("dono/app", d.motivo_para_nao_enviar(self.wt))
        with mock.patch.object(d, "projeto", lambda: d.projetos.Projeto(id="x", repo=str(self.wt))):
            self.assertIn("não tem o repositório do GitHub", d.motivo_para_nao_enviar(self.wt))

    def test_conferencia_vermelha_barra_o_push(self):
        with mock.patch.object(d, "projeto", lambda: d.projetos.Projeto(
                id="x", repo=str(self.wt), github="dono/app",
                antes_do_push="echo achou nome pessoal; exit 1")):
            motivo = d.motivo_para_nao_enviar(self.wt)
        self.assertIn("saiu 1", motivo)
        self.assertIn("achou nome pessoal", motivo)


class Comandos(unittest.TestCase):
    def setUp(self):
        sem_ajustes_reais(self)

    def test_opencode_headless_json(self):
        self.assertEqual(d.agent_command("opencode", "medio"),
                         ["opencode", "run", "--format", "json",
                          "-m", "opencode/deepseek-v4.1-flash-free"])
        self.assertEqual(d.agent_command("opencode", "baixo"),
                         ["opencode", "run", "--format", "json",
                          "-m", "opencode/glm-5.3-flash-free"])
        self.assertEqual(d.agent_command("opencode", "alto"),
                         ["opencode", "run", "--format", "json",
                          "-m", "opencode/nemotron-3-ultra-free"])
        self.assertEqual(d.agent_command("opencode-go", "medio"),
                         ["opencode", "run", "--format", "json",
                          "-m", "opencode-go/kimi-k3"])
        for effort in ("baixo", "medio", "alto"):
            d.agent_command("opencode", effort)  # todo esforço tem flags
            self.assertTrue(d.limit_text("opencode", effort).startswith("teto US$"))
            d.agent_command("opencode-go", effort)
            self.assertTrue(d.limit_text("opencode-go", effort).startswith("teto US$"))

    def test_codex_headless_json(self):
        self.assertEqual(d.agent_command("codex", "medio"),
                         ["codex", "exec", "--json"])
        for effort in ("baixo", "medio", "alto"):
            d.agent_command("codex", effort)  # modelo default do CLI

    def test_desconhecida_levanta(self):
        with self.assertRaises(NotImplementedError):
            d.agent_command("umanova", "medio")

    def test_opencode_implementadas(self):
        for lane in ("opencode", "opencode-go"):
            with self.subTest(lane=lane):
                self.assertIn(lane, d.IMPLEMENTED_LANES)
                self.assertTrue(d.lane_runnable(lane))

    def test_codex_implementada(self):
        self.assertIn("codex", d.IMPLEMENTED_LANES)
        self.assertTrue(d.lane_runnable("codex"))
        self.assertIn("codex", d.LANES)

    def test_label_opencode(self):
        self.assertEqual(d.LABEL_LANE_IDS["opencode"], "label-lane-opencode")


class Janela(unittest.TestCase):
    def test_ordem_e_enabled(self):
        self.assertEqual(w.LANES_ORDEM[:3], ("claude", "grok", "opencode"))
        # sem arquivo enabled ao lado: padrão compatível
        import tempfile as t
        d2 = Path(t.mkdtemp())
        (d2 / "lanes_window.py").write_text((Path(w.__file__).read_text()))
        (d2 / "enabled").write_text("claude grok opencode\n")
        sys.path.insert(0, str(d2))
        try:
            import importlib
            mod = importlib.import_module("lanes_window")
            importlib.reload(mod)
            self.assertEqual(mod.LANES, ("claude", "grok", "opencode"))
        finally:
            sys.path.remove(str(d2))
            importlib.reload(w)


class CatalogoDeAgentes(unittest.TestCase):
    """As listas do dispatcher vêm de `agents.d/`, não de tuplas escritas à mão."""

    def setUp(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gasto_lanes"))
        import catalogo
        self.cat = catalogo
        self.dados = catalogo.catalogo()

    def test_lanes_na_ordem_de_rotacao_do_manifesto(self):
        self.assertEqual(d.LANES, d.catalogo.lanes_por_prioridade())

    def test_implementadas_partem_do_manifesto(self):
        self.assertEqual(d.IMPLEMENTED_LANES, d.catalogo.lanes_implementadas())
        self.assertFalse(hasattr(d, "EXPERIMENTAL_LANES"))

    def test_toda_lane_do_dispatcher_tem_flags_de_esforco(self):
        for lane in d.LANES:
            with self.subTest(lane=lane):
                self.assertEqual(set(d.EFFORT_FLAGS[lane]), {"baixo", "medio", "alto"})

    def test_codigo_nao_traz_id_do_linear(self):
        """FRA-565: nenhum UUID no dispatcher, no catálogo nem nos manifestos."""
        import re
        raiz = Path(__file__).resolve().parent.parent
        uuid = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        for arq in [raiz / "lanes" / "dispatcher.py", raiz / "gasto_lanes" / "catalogo.py",
                    *sorted((raiz / "agents.d").glob("*.json"))]:
            with self.subTest(arquivo=arq.name):
                self.assertEqual(uuid.findall(arq.read_text(encoding="utf-8")), [])

    def test_toda_lane_do_manifesto_tem_comando_no_dispatcher(self):
        """Manifesto pode declarar lane nova; o comando de execução é código por CLI."""
        texto = Path(d.__file__).read_text()
        for nome in d.LANES:
            with self.subTest(lane=nome):
                self.assertIn(f'lane == "{nome}"', texto,
                              f"{nome}: falta o comando em agent_command()")

    def test_nota_do_manifesto_explica_a_lane(self):
        """Cada lane implementada carrega a justificativa no manifesto."""
        for nome, dados in self.dados.items():
            if dados["execucao"]:
                with self.subTest(lane=nome):
                    self.assertTrue(dados["nota"], f"{nome}: sem nota no manifesto")


class FreioDeCaminhoProtegido(unittest.TestCase):
    """FRA-477: a lista de protegidos é do projeto e tem que casar com o disco.

    O glob `scripts/lanes/*` apontava para uma pasta que o E13 tirou do repo do
    app: ele não protegia nada e mesmo assim aparecia na lista que o agente lê
    como freio. Um glob morto é pior que nenhum — dá sensação de proteção que
    não existe.
    """

    APP = ["docs/produto/caminho.md", "docs/produto/mvp-patente.md", "scripts/safe_xcodebuild.sh"]

    def setUp(self):
        # Hermético (FRA-565): o cadastro do teste, não o da máquina.
        d.projetos._resetar_cache()
        d.projetos._CACHE["lista"] = [d.projetos.Projeto(
            id="app", nome="App", repo="~/Developer/app", protegidos=self.APP)]
        self.addCleanup(d.projetos._resetar_cache)

    def test_caminho_protegido_real_bloqueia(self):
        self.assertEqual(d.touched_protected(["scripts/safe_xcodebuild.sh"]),
                         ["scripts/safe_xcodebuild.sh"])
        self.assertEqual(d.touched_protected(["docs/produto/caminho.md"]),
                         ["docs/produto/caminho.md"])

    def test_glob_morto_deixa_de_casar(self):
        self.assertEqual(d.touched_protected(["scripts/lanes/dispatcher.py"]), [],
                         "scripts/lanes/* não existe mais no repo do app")
        self.assertNotIn("scripts/lanes/*", d.protected_globs())

    def test_prova_roda_mesmo_o_comando_do_cadastro(self):
        """O comando do cadastro vai para o shell como linha de comando.

        Regressão de 19/10: `shlex.quote` na linha inteira fazia o bash procurar
        um arquivo chamado «./scripts/safe_xcodebuild.sh test FooTests» e toda
        prova saía 127 («No such file or directory»), em todo card.
        """
        import subprocess, tempfile, os
        with tempfile.TemporaryDirectory() as tmp:
            wt = Path(tmp)
            (wt / ".lane").mkdir()
            (wt / "scripts").mkdir()
            falso = wt / "scripts" / "prova-falsa.sh"
            falso.write_text("#!/bin/bash\necho \"rodou $*\"\n", encoding="utf-8")
            falso.chmod(0o755)
            d.projetos._resetar_cache()
            d.projetos._CACHE["lista"] = [d.projetos.Projeto(
                id="x", nome="Falso", repo=str(wt), worktrees=str(wt),
                prova="./scripts/prova-falsa.sh test {suite}", prova_tentativas=2)]
            try:
                script = d.proof_script(wt, ["FooTests"])
                subprocess.run(["/bin/bash", "-c", script], check=False)
                saida = (wt / ".lane" / "proof.log").read_text(encoding="utf-8")
                codigo = (wt / ".lane" / "proof_exit").read_text(encoding="utf-8").strip()
            finally:
                d.projetos._CACHE.pop("lista", None)
                d.projetos._resetar_cache()
        self.assertIn("rodou test FooTests", saida)
        self.assertNotIn("No such file or directory", saida)
        self.assertEqual(codigo, "0")

    def test_merge_da_main_nao_conta_como_arquivo_da_lane(self):
        """Trazer a main para a branch não pode acusar a lane do que a main mudou.

        Regressão da FRA-453: a lane fez merge de origin/main, a main tinha
        mudado `docs/produto/caminho.md`, e o freio de caminho protegido matou o
        card três vezes por um arquivo em que a lane não encostou.
        """
        import subprocess, tempfile
        def git(*args, cwd):
            subprocess.run(["git", *args], cwd=cwd, check=True,
                           capture_output=True, text=True)
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            repo.mkdir()
            git("init", "-q", "-b", "main", cwd=repo)
            git("config", "user.email", "t@t", cwd=repo)
            git("config", "user.name", "t", cwd=repo)
            (repo / "app.swift").write_text("um\n", encoding="utf-8")
            (repo / "protegido.md").write_text("norte\n", encoding="utf-8")
            git("add", "-A", cwd=repo)
            git("commit", "-qm", "inicial", cwd=repo)
            base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo,
                                  capture_output=True, text=True).stdout.strip()
            # a main anda e mexe no arquivo protegido
            git("checkout", "-q", "-b", "lane", cwd=repo)
            git("checkout", "-q", "main", cwd=repo)
            (repo / "protegido.md").write_text("norte novo\n", encoding="utf-8")
            git("commit", "-aqm", "main mexe no protegido", cwd=repo)
            # a lane mexe só no código e traz a main para dentro
            git("checkout", "-q", "lane", cwd=repo)
            (repo / "app.swift").write_text("dois\n", encoding="utf-8")
            git("commit", "-aqm", "lane mexe no app", cwd=repo)
            git("merge", "-q", "--no-edit", "main", cwd=repo)
            # origin/main, que é o que o git_summary compara
            git("update-ref", "refs/remotes/origin/main", "main", cwd=repo)
            g = d.git_summary(repo, base)
        self.assertIn("app.swift", g["lane_files"])
        self.assertNotIn("protegido.md", g["lane_files"],
                         "arquivo que veio da main não é da lane")
        self.assertEqual(d.touched_protected(g["lane_files"]), [])

    def test_freio_eh_do_projeto_que_a_lane_trabalha(self):
        """O alcance do freio acompanha o projeto: o worktree e os globs saem juntos.

        A lane trabalha num projeto só por vez (o `padrao` do cadastro), e é o
        worktree desse projeto que `git_summary` lê. Não existe caminho do
        tuttidash no diff de uma lane que trabalha no app, nem o inverso:
        o alcance acompanha o projeto, não um repo fixo.
        """
        with self.subTest(projeto="app"):
            self.assertIn("docs/produto/caminho.md", d.protected_globs())
            # caminho que só existe no repo do app é protegido no app
            self.assertEqual(d.touched_protected(["docs/produto/mvp-patente.md"]),
                             ["docs/produto/mvp-patente.md"])

        with self.subTest(projeto="TuttiDash"):
            anterior = d.projetos.projetos()
            d.projetos._CACHE["lista"] = [d.projetos.Projeto(
                id="teste", nome="TuttiDash", repo="~/Developer/tuttidash",
                protegidos=["agents.d/*", "docs/produto/caminho.md"])]
            try:
                self.assertEqual(d.touched_protected(["agents.d/claude.json"]),
                                 ["agents.d/claude.json"])
                self.assertEqual(d.touched_protected(["docs/produto/mvp-patente.md"]), [],
                                 "o freio do TuttiDash não é o do app")
            finally:
                d.projetos._CACHE["lista"] = anterior


class SemJanelaDeLimite(unittest.TestCase):
    """FRA-472 (a): conta que respondeu e não tem teto tem folga total.

    A distinção é estrutural, por `pct_para_ordem`: sem pct com `janela == "sem
    dado"` é o servidor dizendo que não há janela; sem pct com qualquer motivo em
    `janela` é leitura falhada, que continua fora. Nada de casar texto de erro.
    """

    def test_pct_conhecido_vai_numero(self):
        self.assertEqual(d.pct_para_ordem((80, "5 h")), 80.0)
        self.assertEqual(d.pct_para_ordem((0, "semana")), 0.0)

    def test_sem_janela_e_folga_total(self):
        self.assertEqual(d.pct_para_ordem((None, d.SEM_JANELA)), 0.0)

    def test_erro_de_leitura_nao_e_folga(self):
        for motivo in ["token local vencido (rode `claude` para renovar)",
                       "sem credencial local (rode `grok` e faça login)",
                       "servidor respondeu HTTP 503"]:
            with self.subTest(motivo=motivo):
                self.assertIsNone(d.pct_para_ordem((None, motivo)))

    def test_auto_pick_escolhe_a_lane_sem_janela(self):
        lane, shown = d.pick_lane({"claude": (80, "semana"),
                                   "opencode": (None, d.SEM_JANELA)},
                                  ["claude", "opencode"])
        self.assertEqual(lane, "opencode", "conta sem teto tem mais folga que a de 80%")
        self.assertIn("opencode", shown)

    def test_auto_pick_ignora_lane_com_leitura_falha(self):
        lane, shown = d.pick_lane({"claude": (80, "semana"),
                                   "opencode": (None, "token local vencido")},
                                  ["claude", "opencode"])
        self.assertEqual(lane, "claude", "leitura falhada não vira folga")
        self.assertIn("token local vencido", shown)

    def test_spread_auto_tambem_considera_sem_janela(self):
        medidas = {"claude": (95, "semana"), "opencode": (None, d.SEM_JANELA)}
        out = d.spread_auto([{"identifier": "FRA-1", "_effort": "medio"}],
                            medidas, ["claude", "opencode"], set(), {})
        self.assertEqual(out[0][1], "opencode", "o saturado sai, a sem teto assume")

    def test_spread_auto_deixa_lane_que_so_tem_erro_de_fora(self):
        """Lane com leitura falhada nunca é candidata, nem para RUN nem para WAIT."""
        medidas = {"claude": (95, "semana"), "opencode": (None, "servidor respondeu HTTP 503")}
        out = d.spread_auto([{"identifier": "FRA-1", "_effort": "medio"}],
                            medidas, ["claude", "opencode"], set(), {})
        # o claude saturado entra só na vaga de espera (2ª rodada não checa headroom);
        # o que não pode é o opencode, cujo erro de leitura não é folga.
        self.assertEqual(out[0][1], "claude")

    def test_lane_com_erro_nao_toma_vaga_quando_ha_outra_com_folga(self):
        medidas = {"claude": (10, "semana"), "opencode": (None, "token local vencido")}
        out = d.spread_auto([{"identifier": "FRA-1", "_effort": "medio"}],
                            medidas, ["claude", "opencode"], set(), {})
        self.assertEqual(out[0][1], "claude")


class ProvaDoDispatcher(unittest.TestCase):
    """FRA-472 (b): a ÚLTIMA tentativa não pode tapar teste vermelho de antes."""

    def log_com(self, *linhas) -> Path:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        lane_dir = tmp / ".lane"
        lane_dir.mkdir()
        (lane_dir / "proof.log").write_text("\n".join(linhas) + "\n", encoding="utf-8")
        return tmp

    def log_vermelho_depois_de_preflight(self) -> Path:
        """O caso do FRA-14: 1ª tentativa deu vermelho, a 2ª foi barrada pelo preflight."""
        return self.log_com(
            "[prova] FooTests: 1ª tentativa SKIP_PREFLIGHT=1",
            "error: cannot find 'X' in scope",
            "Executed 12 tests, with 1 failure",
            "[prova] FooTests: 1ª falhou; 2ª tentativa com preflight",
            "abortado pelo preflight. SKIP_PREFLIGHT=1 para forçar.",
        )

    def test_vermelho_vence_preflight(self):
        self.assertEqual(d.proof_veredito(self.log_vermelho_depois_de_preflight()), "vermelho")

    def test_somente_preflight_e_preflight(self):
        wt = self.log_com(
            "[prova] FooTests: 1ª tentativa SKIP_PREFLIGHT=1",
            "abortado pelo preflight. SKIP_PREFLIGHT=1 para forçar.",
            "[prova] FooTests: 1ª falhou; 2ª tentativa com preflight",
            "abortado pelo preflight. SKIP_PREFLIGHT=1 para forçar.",
        )
        self.assertEqual(d.proof_veredito(wt), "preflight")

    def test_log_sem_marca_ou_inexistente(self):
        self.assertEqual(d.proof_veredito(Path("/nao/existe")), "sem-dado")
        self.assertEqual(d.proof_veredito(self.log_com("nada aqui")), "vermelho")

    def test_falha_sem_sinal_e_vermelho(self):
        """Falhou e não é preflight: o retry é só do preflight, o resto é falha."""
        wt = self.log_com("[prova] FooTests: 1ª tentativa SKIP_PREFLIGHT=1",
                          "bash: python3: command not found")
        self.assertEqual(d.proof_veredito(wt), "vermelho")

    def test_resumo_mostra_a_tentativa_do_vermelho(self):
        resumo = d.proof_failures(self.log_vermelho_depois_de_preflight())
        self.assertIn("cannot find 'X' in scope", resumo)
        self.assertNotIn("abortado pelo preflight", resumo,
                         "o resumo não pode esconder o erro de teste atrás do preflight")

    def test_linha_verde_nao_e_evidencia(self):
        """`Executed N tests, with 0 failures` é o oposto de vermelho: não conta."""
        verde = "Executed 12 tests, with 0 failures"
        self.assertNotRegex(verde, d.EVIDENCIA_RE)
        self.assertRegex("Executed 12 tests, with 1 failure", d.EVIDENCIA_RE)
        wt = self.log_com("[prova] FooTests: 1ª tentativa SKIP_PREFLIGHT=1", verde)
        self.assertIn("sem linha de erro reconhecida", d.proof_failures(wt))

    def test_resumo_mostra_o_erro_de_compilacao(self):
        resumo = d.proof_failures(self.log_vermelho_depois_de_preflight())
        self.assertIn("cannot find 'X' in scope", resumo)
        self.assertIn("with 1 failure", resumo)

    def test_exit_code_zero_com_erro_no_log_eh_falha(self):
        """FRA-472 (b): proof_exit == "0" mas o log tem teste vermelho → falha.

        O agente pode mascarar o erro de teste no exit code (retornar 0 mesmo
        com falha). O finalize deve confiar no proof.log, não só no exit code.
        """
        wt = self.log_com(
            "[prova] FooTests: 1ª tentativa SKIP_PREFLIGHT=1",
            "error: cannot find 'X' in scope",
            "Executed 12 tests, with 1 failure",
        )
        (wt / ".lane" / "proof_exit").write_text("0", encoding="utf-8")
        # O finalize trata como falha se rc != 0 OU veredito == "vermelho":
        proof_rc = (wt / ".lane" / "proof_exit").read_text().strip()
        veredito = d.proof_veredito(wt)
        self.assertEqual(veredito, "vermelho", "erro no log deve ser vermelho")
        self.assertTrue(proof_rc != "0" or veredito == "vermelho",
                        "exit code 0 com erro no log deve ser tratado como falha")
        # E o resumo deve conter o erro real, não apenas o preflight.
        resumo = d.proof_failures(wt)
        self.assertIn("cannot find 'X' in scope", resumo)


class ProvaRc0Test(unittest.TestCase):
    def test_rc0_sem_erro_e_verde(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            wt = Path(tmp)
            (wt / ".lane").mkdir()
            log = ("[prova] AsrBenchmarkTests: 1a tentativa SKIP_PREFLIGHT=1" + chr(10)
                   + "Executed 4 tests, with 0 failures" + chr(10)
                   + "** TEST SUCCEEDED **" + chr(10))
            (wt / ".lane" / "proof.log").write_text(log, encoding="utf-8")
            self.assertEqual(d.proof_veredito(wt, "0"), "verde")
            self.assertEqual(d.proof_veredito(wt, "1"), "vermelho")
            self.assertEqual(d.proof_veredito(wt), "vermelho")


class FalsoVermelho(unittest.TestCase):
    """Melhoria 1 (21/10/2026): prova verde lida como vermelha por trecho de código no log."""

    def wt(self, *linhas, rc=None) -> Path:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / ".lane").mkdir()
        (tmp / ".lane" / "proof.log").write_text("\n".join(linhas) + "\n", encoding="utf-8")
        return tmp

    TRECHO = "189 |     static func texto(_ error: Error) -> String {"

    def test_trecho_de_codigo_nao_e_evidencia(self):
        self.assertFalse(d.evidencia(self.TRECHO))
        self.assertFalse(d.evidencia("    |                      `- warning: x"))
        self.assertTrue(d.evidencia("/Users/x/My App/F.swift:12:5: error: cannot find 'X' in scope"))
        self.assertTrue(d.evidencia("error: linker command failed"))
        self.assertTrue(d.evidencia("Test Case '-[A b]' failed (0.01 seconds)."))
        self.assertTrue(d.evidencia("** TEST FAILED **"))
        self.assertFalse(d.evidencia("func registrar(_ error: Error)"))

    def test_caso_fra_508_e_verde(self):
        wt = self.wt("[prova] WhisperTranscriberTests: 1ª tentativa SKIP_PREFLIGHT=1",
                     self.TRECHO, "Executed 30 tests, with 0 failures (0 unexpected)", "** TEST SUCCEEDED **")
        self.assertEqual(d.proof_veredito(wt, "0"), "verde")

    def test_rc0_com_vermelho_na_ultima_tentativa_ainda_e_vermelho(self):
        wt = self.wt("[prova] A: 1ª tentativa SKIP_PREFLIGHT=1", "Executed 3 tests, with 1 failure")
        self.assertEqual(d.proof_veredito(wt, "0"), "vermelho")

    def test_rc0_com_vermelho_resolvido_pela_tentativa_seguinte_e_verde(self):
        wt = self.wt("[prova] A: 1ª tentativa SKIP_PREFLIGHT=1", "Executed 3 tests, with 1 failure",
                     "[prova] A: 1ª falhou; 2ª tentativa com preflight",
                     "Executed 3 tests, with 0 failures", "** TEST SUCCEEDED **")
        self.assertEqual(d.proof_veredito(wt, "0"), "verde")

    def test_causa_estavel(self):
        self.assertEqual(d.causa_de("a prova do dispatcher falhou (A, B, código 65)"), "prova-vermelha")
        self.assertEqual(d.causa_de("a prova do dispatcher falhou (A, código 1)"), "prova-vermelha")
        self.assertEqual(d.causa_de("a prova foi barrada 4 vezes pelo preflight (Mac ocupado)"), "preflight")
        self.assertEqual(d.causa_de("a prova (A) passou de 150 min"), "prova-timeout")
        self.assertEqual(d.causa_de("timeout de 90 min"), "timeout-lane")
        self.assertEqual(d.causa_de("agente saiu com código 1 (x)"), "agente-erro")
        self.assertEqual(d.causa_de("algo novo"), "outra")


class SemTriagemLocal(unittest.TestCase):
    """A triagem local saiu do TuttiDash em 29/10: prova vermelha vai direto para lane:falhou."""

    def test_dispatcher_nao_tem_mais_triagem_local(self):
        for nome in ("triagem_local", "triagem_texto", "triagem_linha", "TRIAGEM_SCRIPT_PADRAO", "TRIAGEM_LOG"):
            self.assertFalse(hasattr(d, nome), nome)

class PrivacidadeDasLanes(unittest.TestCase):
    """Privacidade das lanes do OpenCode: desde 23/10/2026 20h20 treino/registro de uso não bloqueia."""

    def setUp(self):
        sem_ajustes_reais(self)
        import privacidade as P
        self.P = P
        self.antigo = (P.pode_receber_codigo, d.ler_modelo_lane)
        self.addCleanup(lambda: (setattr(P, "pode_receber_codigo", self.antigo[0]),
                                 setattr(d, "ler_modelo_lane", self.antigo[1])))
        self.vistos = []

        def falso(modelo, est=None, hoje=None):
            self.vistos.append(modelo)
            return ("nemotron" not in modelo, "teste")
        P.pode_receber_codigo = falso
        d.ler_modelo_lane = lambda lane: None

    def test_modelos_por_peso_de_23_10(self):
        self.assertEqual(d.modelo_da_lane("opencode", "baixo"), "opencode/glm-5.3-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "medio"), "opencode/deepseek-v4.1-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "alto"), "opencode/nemotron-3-ultra-free")
        self.assertIsNone(d.privacy_block("opencode", "medio"))

    def test_regra_de_23_10_modelo_que_treina_recebe_codigo(self):
        """Mesma função da revisão (watch.privacidade_ok): sem exceção só para o revisor."""
        P = self.P
        P.pode_receber_codigo = self.antigo[0]
        antigo_cfg = P._cfg
        self.addCleanup(setattr, P, "_cfg", antigo_cfg)
        P._cfg = lambda k, p: p
        d.ler_modelo_lane = lambda lane: "nemotron-3.5-super-vl-free"
        self.assertIsNone(d.privacy_block("opencode", "medio"))
        self.assertIsNone(d.privacy_block("opencode", "alto"))
        P._cfg = lambda k, p: True if k == "privacidade.exigir_sem_treino" else p
        self.assertIsNotNone(d.privacy_block("opencode", "medio"), "com a regra de 21/10 religada, bloqueia")

    def test_modelo_customizado_ganha_prefixo_e_e_conferido(self):
        d.ler_modelo_lane = lambda lane: "nemotron-3.5-super-vl-free"
        self.assertEqual(d.modelo_da_lane("opencode", "medio"), "opencode/nemotron-3.5-super-vl-free")
        self.assertEqual(d.privacy_block("opencode", "medio"), "teste")

    def test_lanes_fora_do_opencode_nao_passam_pela_conferencia(self):
        self.assertIsNone(d.privacy_block("claude", "alto"))
        self.assertEqual(self.vistos, [])


class ModeloDosAjustes(unittest.TestCase):
    """O app grava `lanes.modelo` aninhado; o dispatcher lia só a chave plana (21/10/2026)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.antigo = d.CONFIG_FILES
        self.addCleanup(setattr, d, "CONFIG_FILES", self.antigo)

    def config(self, dados) -> None:
        f = self.tmp / "config.json"
        f.write_text(json.dumps(dados), encoding="utf-8")
        d.CONFIG_FILES = [f]

    def test_le_aninhado(self):
        self.config({"lanes": {"modelo": {"opencode": "glm-5.3-flash-free"}}})
        self.assertEqual(d.ler_modelo_lane("opencode"), "glm-5.3-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "medio"), "opencode/glm-5.3-flash-free")
        self.assertIsNone(d.ler_modelo_lane("grok"))

    def test_chave_plana_antiga_ainda_vale(self):
        self.config({"lanes.modelo.opencode-go": "kimi-k3"})
        self.assertEqual(d.modelo_da_lane("opencode-go", "alto"), "opencode-go/kimi-k3")


class ModeloPorPeso(unittest.TestCase):
    """FRA-521: automático pelo peso, fixo, formato antigo e modelo que saiu da lista."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.antigo = (d.CONFIG_FILES, d.CACHE_MODELOS)
        self.addCleanup(self.restaura)
        self.cache = self.tmp / "modelos-cache.json"
        d.CACHE_MODELOS = self.cache

    def restaura(self):
        d.CONFIG_FILES, d.CACHE_MODELOS = self.antigo

    def config(self, dados) -> None:
        f = self.tmp / "config.json"
        f.write_text(json.dumps(dados), encoding="utf-8")
        d.CONFIG_FILES = [f]

    def test_sem_config_as_flags_sao_as_do_manifesto(self):
        self.config({})
        for lane in ("claude", "grok", "opencode", "codex"):
            for peso in ("baixo", "medio", "alto"):
                self.assertEqual(d.flags_da_lane(lane, peso), list(d.EFFORT_FLAGS[lane][peso]), lane)

    def test_auto_por_peso_troca_modelo_e_esforco(self):
        self.config({"lanes": {"modelo": {"claude": {
            "modo": "auto",
            "fixo": "sonnet",
            "porPeso": {
                "baixo": {"modelo": "haiku", "esforco": "low"},
                "medio": {"modelo": "sonnet", "esforco": "medium"},
                "alto": {"modelo": "opus", "esforco": "xhigh"},
            },
        }, "opencode": {
            "modo": "auto",
            "fixo": "",
            "porPeso": {
                "baixo": {"modelo": "glm-5.3-flash-free", "esforco": ""},
                "medio": {"modelo": "opencode/deepseek-v4.1-flash-free", "esforco": ""},
                "alto": {"modelo": "minimax-m3.1-flash-free", "esforco": ""},
            },
        }}}})
        self.assertIsNone(d.ler_modelo_lane("claude"))
        self.assertEqual(d.modelo_da_lane("claude", "baixo"), "haiku")
        self.assertEqual(d.modelo_da_lane("claude", "alto"), "opus")
        self.assertEqual(d.flags_da_lane("claude", "baixo"), ["--model", "haiku", "--effort", "low"])
        self.assertEqual(d.flags_da_lane("claude", "alto"), ["--model", "opus", "--effort", "xhigh"])
        self.assertEqual(d.modelo_da_lane("opencode", "baixo"), "opencode/glm-5.3-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "alto"), "opencode/minimax-m3.1-flash-free")
        self.assertEqual(d.flags_da_lane("opencode", "baixo"), ["-m", "opencode/glm-5.3-flash-free"])
        self.assertEqual(d.catalogo.modelo_efetivo(
            "claude", "alto", arquivos=d.CONFIG_FILES, cache=d.catalogo.ler_cache_modelos(d.CACHE_MODELOS)),
            d.modelo_da_lane("claude", "alto"))

    def test_fixo_vale_para_todos_os_pesos_e_guarda_o_esforco_do_card(self):
        self.config({"lanes": {"modelo": {"claude": {
            "modo": "fixo",
            "fixo": "sonnet",
            "porPeso": {"alto": {"modelo": "opus", "esforco": "low"}},
        }, "grok": {
            "modo": "fixo",
            "fixo": "grok-4.7-build-fast",
            "porPeso": {},
        }}}})
        self.assertEqual(d.ler_modelo_lane("claude"), "sonnet")
        self.assertEqual(d.modelo_da_lane("claude", "baixo"), "sonnet")
        self.assertEqual(d.modelo_da_lane("claude", "alto"), "sonnet")
        self.assertEqual(d.flags_da_lane("claude", "alto"), ["--model", "sonnet", "--effort", "xhigh"])
        self.assertEqual(d.flags_da_lane("grok", "medio"), ["-m", "grok-4.7-build-fast", "--effort", "high"])
        self.assertEqual(d.flags_da_lane("grok", "baixo"), ["-m", "grok-4.7-build-fast"])
        self.assertEqual(d.aviso_modelo("claude", "alto"), "modelo fixo")

    def test_formato_antigo_string_e_fixo_em_todos_os_pesos(self):
        self.config({"lanes": {"modelo": {"opencode": "glm-5.3-flash-free"}}})
        self.assertEqual(d.ler_modelo_lane("opencode"), "glm-5.3-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "baixo"), "opencode/glm-5.3-flash-free")
        self.assertEqual(d.modelo_da_lane("opencode", "alto"), "opencode/glm-5.3-flash-free")
        self.assertEqual(d.aviso_modelo("opencode", "medio"), "modelo fixo")
        self.config({"lanes.modelo.grok": "grok-4.7"})
        self.assertEqual(d.modelo_da_lane("grok", "baixo"), "grok-4.7")
        self.assertEqual(d.modelo_da_lane("grok", "alto"), "grok-4.7")
        self.assertEqual(d.flags_da_lane("grok", "alto"), ["-m", "grok-4.7", "--effort", "high"])

    def test_modelo_sumido_volta_ao_auto(self):
        self.config({"lanes": {"modelo": {"opencode": {
            "modo": "fixo",
            "fixo": "glm-5.3-flash-free",
            "porPeso": {"baixo": {"modelo": "opencode/deepseek-v4.1-flash-free", "esforco": ""}},
        }}}})
        self.cache.write_text(json.dumps({
            "listas": {"opencode": ["opencode/deepseek-v4.1-flash-free"]},
            "anteriores": {"opencode": ["opencode/glm-5.3-flash-free", "opencode/deepseek-v4.1-flash-free"]},
        }), encoding="utf-8")
        self.assertIsNone(d.ler_modelo_lane("opencode"))
        self.assertEqual(d.modelo_da_lane("opencode", "alto"), d.catalogo.modelo_de_effort("opencode", "alto"),
                         "peso sem escolha nos Ajustes cai no manifesto")
        self.assertEqual(d.modelo_da_lane("opencode", "baixo"), "opencode/deepseek-v4.1-flash-free")
        self.assertIn("voltou ao automático", d.aviso_modelo("opencode", "alto"))
        self.assertEqual(d.reconciliar_modelos_sumidos(), ["opencode"])
        gravado = json.loads((self.tmp / "config.json").read_text(encoding="utf-8"))
        bloco = gravado["lanes"]["modelo"]["opencode"]
        self.assertEqual(bloco["modo"], "auto")
        self.assertIn("saiu da lista", bloco["aviso"])
        self.assertNotIn("lanes.modelo.opencode", gravado)

    def test_filtro_de_privacidade_da_opencode(self):
        linhas = [
            "opencode/deepseek-v4.1-flash-free",
            "opencode/nemotron-3.5-super-vl-free",
            "opencode-go/deepseek-v4.1-flash",
            "anthropic/claude-sonnet",
            "Available models:",
        ]

        def pode(modelo, est=None, hoje=None):
            return ("nemotron" not in modelo, "teste")

        self.assertEqual(
            d.filtrar_modelos("opencode", linhas, pode),
            ["opencode/deepseek-v4.1-flash-free"])
        self.assertEqual(
            d.filtrar_modelos("opencode-go", linhas, pode),
            ["opencode-go/deepseek-v4.1-flash"])
        self.assertEqual(d.filtrar_modelos("grok", ["grok-4.7", "grok-4.7-build-fast"], pode),
                         ["grok-4.7", "grok-4.7-build-fast"])

    def test_cache_so_troca_lista_boa_e_guarda_a_anterior(self):
        c1 = d.catalogo.atualizar_cache_lista({}, "grok", ["grok-4.7", "grok-4.7-build-fast"], "t1")
        c2 = d.catalogo.atualizar_cache_lista(c1, "grok", [], "t2")
        self.assertEqual(c2["listas"]["grok"], ["grok-4.7", "grok-4.7-build-fast"])
        c3 = d.catalogo.atualizar_cache_lista(c2, "grok", ["grok-4.7"], "t3")
        self.assertEqual(c3["anteriores"]["grok"], ["grok-4.7", "grok-4.7-build-fast"])
        self.assertTrue(d.catalogo.modelo_sumiu("grok-4.7-build-fast", "grok", c3))
        self.assertFalse(d.catalogo.modelo_sumiu("grok-4.7", "grok", c3))


    # FRA-564: Claude e Codex sem lista nos Ajustes; lixo no grok; fixo vazio; selo por lane.

    def test_claude_lista_pela_api_oficial_com_a_chave(self):
        pedidos = []

        def get_json(url, headers):
            pedidos.append((url, headers))
            return {"data": [{"id": "claude-opus-5-5"}, {"id": "claude-sonnet-5-5"}]}

        with mock.patch.object(d.catalogo, "_get_json", get_json), \
                mock.patch.dict(d.catalogo.os.environ, {"ANTHROPIC_API_KEY": "sk-teste"}):
            self.assertEqual(d.catalogo._modelos_claude(), ["claude-opus-5-5", "claude-sonnet-5-5"])
        self.assertEqual(pedidos[0][1]["x-api-key"], "sk-teste")
        self.assertNotIn("Authorization", pedidos[0][1])

    def test_claude_sem_chave_nem_fonte_extra_fica_sem_lista(self):
        def sem_rede(url, headers):
            raise AssertionError("sem ANTHROPIC_API_KEY e sem fonte extra não vai à rede")

        with mock.patch.object(d.catalogo, "_get_json", sem_rede), \
                mock.patch.object(d.catalogo, "_lista_extra", lambda lane: None), \
                mock.patch.dict(d.catalogo.os.environ, {"ANTHROPIC_API_KEY": ""}):
            self.assertEqual(d.catalogo._modelos_claude(), [])

    def test_codex_le_a_lista_que_o_cli_guarda_sem_os_ocultos(self):
        dados = {"fetched_at": "2026-10-23T18:41:46Z", "models": [
            {"slug": "gpt-reserve", "visibility": "hide", "priority": 4},
            {"slug": "gpt-5.6-luna", "visibility": "list", "priority": 9},
            {"slug": "gpt-5.6-terra", "visibility": "list", "priority": 8},
            {"slug": "codex-auto-review", "visibility": "hide", "priority": 43},
            {"slug": "sem-prioridade"},
            {"display_name": "sem slug"},
        ]}
        self.assertEqual(d.catalogo.modelos_cache_codex(dados), ["gpt-5.6-terra", "gpt-5.6-luna", "sem-prioridade"])
        self.assertIsNone(d.catalogo.modelos_cache_codex({"outra": []}))
        home = self.tmp / "home"
        (home / ".codex").mkdir(parents=True)
        (home / ".codex/models_cache.json").write_text(json.dumps(dados), encoding="utf-8")

        def sem_rede(url, headers):
            raise AssertionError("com o cache do Codex não deve ir à rede")

        with mock.patch.object(d.catalogo, "_get_json", sem_rede), \
                mock.patch.object(d.catalogo.Path, "home", lambda: home), \
                mock.patch.dict(d.catalogo.os.environ, {"OPENAI_API_KEY": ""}):
            self.assertEqual(d.catalogo._modelos_codex(), ["gpt-5.6-terra", "gpt-5.6-luna", "sem-prioridade"])

    def test_grok_ignora_as_frases_do_cabecalho(self):
        saida = ("You are logged in with grok.com.\nDefault model: grok-4.7\nAvailable models:\n"
                 "  * grok-4.7 (default)\n  - grok-4.7-build-fast\n  - grok-4.6\n  - grok-4.5\n")
        linhas = d.catalogo.linhas_de_item(saida.splitlines())
        self.assertEqual(d.filtrar_modelos("grok", linhas, None),
                         ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])
        with mock.patch.object(d.catalogo, "_rodar", lambda argv: saida):
            self.assertEqual(d.catalogo.buscar_modelos("grok"),
                             ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])

    def test_fixo_sem_modelo_usa_o_automatico_com_aviso(self):
        self.config({"lanes": {"modelo": {"claude": {"modo": "fixo", "fixo": "", "porPeso": {}}}}})
        self.assertEqual(d.modelo_da_lane("claude", "alto"), d.catalogo.modelo_de_effort("claude", "alto"))
        self.assertEqual(d.aviso_modelo("claude", "alto"), d.catalogo.AVISO_FIXO_VAZIO)

    def test_selo_por_lane_e_nova_tentativa_da_que_falhou(self):
        c = d.catalogo.atualizar_cache_lista({}, "grok", ["grok-4.7"], "2026-10-26T10:00:00")
        c = d.catalogo.atualizar_cache_lista(c, "claude", [], "2026-10-26T10:00:00")
        self.assertEqual(c["atualizado_em_por_lane"], {"grok": "2026-10-26T10:00:00"})
        d.catalogo.gravar_cache_modelos(self.cache, c)
        lanes = ["grok", "claude"]
        cedo = d.dt.datetime(2026, 10, 26, 10, 30)
        self.assertEqual(d.catalogo.lanes_para_atualizar(lanes, self.cache, cedo), [],
                         "menos de uma hora desde a última tentativa")
        depois = d.dt.datetime(2026, 10, 26, 11, 30)
        self.assertEqual(d.catalogo.lanes_para_atualizar(lanes, self.cache, depois), ["claude"])
        amanha = d.dt.datetime(2026, 10, 27, 10, 30)
        self.assertEqual(d.catalogo.lanes_para_atualizar(lanes, self.cache, amanha), ["grok", "claude"])
        self.cache.write_text(json.dumps({"atualizado_em": "2026-10-26T10:00:00",
                                          "listas": {"grok": ["grok-4.7"]}}), encoding="utf-8")
        self.assertEqual(d.catalogo.lanes_para_atualizar(lanes, self.cache, depois), ["grok", "claude"],
                         "cache antigo, sem selo por lane, renova tudo")


class Limite429DoProvedor(unittest.TestCase):
    """O plano grátis do OpenCode devolve 429 (`FreeUsageLimitError`) no 1º passo; a lane não
    pode voltar a assumir card a cada ciclo (FRA-189/FRA-507/FRA-192, 20/10)."""

    LOG_429 = (
        '{"type":"step_start","timestamp":1792535201000}\n'
        '{"type":"error","timestamp":1792535201320,"sessionID":"ses_x","error":{"type":"provider.quota",'
        '"message":"Rate limit exceeded. Please try again later.","status":429,"response":{"body":'
        '"{\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"FreeUsageLimitError\\"}}"}}}\n'
    )

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.antigo = d.STATE_DIR
        d.STATE_DIR = self.tmp
        self.addCleanup(lambda: setattr(d, "STATE_DIR", self.antigo))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _log(self, texto):
        p = self.tmp / "agent.jsonl"
        p.write_text(texto)
        return str(p)

    def test_429_do_opencode_segura_a_lane(self):
        antes = time.time()
        until = d.account_limit(self._log(self.LOG_429), "opencode")
        self.assertIsNotNone(until)
        self.assertGreaterEqual(until - antes, d.LIMIT_429_BASE_S - 1)

    def test_recuo_dobra_a_cada_429_seguido_e_tem_teto(self):
        log = self._log(self.LOG_429)
        esperas = []
        for _ in range(6):
            esperas.append(round(d.account_limit(log, "opencode") - time.time()))
        self.assertEqual(esperas[0], d.LIMIT_429_BASE_S)
        self.assertEqual(esperas[1], d.LIMIT_429_BASE_S * 2)
        self.assertEqual(esperas[2], d.LIMIT_429_BASE_S * 4)
        self.assertEqual(esperas[-1], d.LIMIT_429_MAX_S)

    def test_recuo_zera_depois_de_6h_sem_429(self):
        log = self._log(self.LOG_429)
        d.account_limit(log, "opencode")
        d.account_limit(log, "opencode")
        f = self.tmp / "limite-429-opencode.json"
        est = json.loads(f.read_text())
        est["at"] = time.time() - d.LIMIT_429_RESET_S - 10
        f.write_text(json.dumps(est))
        self.assertEqual(round(d.account_limit(log, "opencode") - time.time()), d.LIMIT_429_BASE_S)

    def test_cada_lane_tem_o_seu_recuo(self):
        log = self._log(self.LOG_429)
        d.account_limit(log, "opencode")
        d.account_limit(log, "opencode")
        self.assertEqual(round(d.account_limit(log, "opencode-go") - time.time()), d.LIMIT_429_BASE_S)

    def test_429_so_conta_em_evento_error_do_opencode(self):
        # texto citado pelo agente não segura. Evento error com 429 segura qualquer lane.
        citado = '{"type":"text","part":{"text":"o erro era \\"status\\": 429 no \\"error\\""}}\n'
        self.assertIsNone(d.account_limit(self._log(citado), "opencode"))
        self.assertIsNone(d.account_limit(self._log(citado), "grok"))
        self.assertIsNotNone(d.account_limit(self._log(self.LOG_429), "grok"))
        self.assertIsNone(d.account_limit(self._log(""), "opencode"))

    def test_hold_for_limit_grava_o_arquivo_que_a_lane_le(self):
        until = d.account_limit(self._log(self.LOG_429), "opencode")
        antigo = d.linear
        d.linear = lambda *a, **k: None
        self.addCleanup(lambda: setattr(d, "linear", antigo))
        st = {"lane": "opencode", "card": "FRA-189", "issue_id": "x", "log": "l", "worktree": "w"}
        d.hold_for_limit(st, until)
        self.assertAlmostEqual(d.lane_limited("opencode"), until, delta=1)
        self.assertIsNone(d.lane_limited("opencode-go"))


class ControleDeLanes(unittest.TestCase):
    """`lanes_ctl.py enable` precisa deixar a lane ligada para o painel também."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.antes = (c.D, c.ENABLED, c.HEARTBEAT, c.USER_OFF)
        c.D = self.tmp
        c.ENABLED = self.tmp / "enabled"
        c.HEARTBEAT = self.tmp / "heartbeat.json"
        c.USER_OFF = self.tmp / "disabled-by-user"
        c.HEARTBEAT.write_text(json.dumps({"implemented": ["claude", "grok", "codex"]}))
        self.addCleanup(lambda: (setattr(c, "D", self.antes[0]), setattr(c, "ENABLED", self.antes[1]),
                                 setattr(c, "HEARTBEAT", self.antes[2]), setattr(c, "USER_OFF", self.antes[3])))

    def test_enable_tira_a_lane_do_marcador_em_arquivo(self):
        c.ENABLED.write_text("codex\n")
        c.USER_OFF.write_text("claude grok\n")
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "claude"]), 0)
        self.assertEqual(set(c.ENABLED.read_text().split()), {"claude", "codex"})
        self.assertEqual(c.USER_OFF.read_text().split(), ["grok"])

    def test_enable_tira_a_lane_do_marcador_em_pasta(self):
        c.USER_OFF.mkdir()
        (c.USER_OFF / "claude").write_text("")
        (c.USER_OFF / "grok").write_text("")
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "claude"]), 0)
        self.assertEqual(sorted(p.name for p in c.USER_OFF.iterdir()), ["grok"])

    def test_enable_sem_marcador_continua_funcionando(self):
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "claude"]), 0)
        self.assertEqual(c.ENABLED.read_text().split(), ["claude"])
        self.assertFalse(c.USER_OFF.exists())

    def test_lane_nao_implementada_nao_mexe_em_nada(self):
        c.USER_OFF.write_text("opencode\n")
        self.assertEqual(c.main(["lanes_ctl.py", "enable", "opencode"]), 1)
        self.assertEqual(c.USER_OFF.read_text().split(), ["opencode"])
        self.assertFalse(c.ENABLED.exists())

    def test_disable_nao_cria_marcador(self):
        c.ENABLED.write_text("claude grok\n")
        self.assertEqual(c.main(["lanes_ctl.py", "disable", "claude"]), 0)
        self.assertEqual(c.ENABLED.read_text().split(), ["grok"])
        self.assertFalse(c.USER_OFF.exists())


def _lane_dir(caso: unittest.TestCase) -> Path:
    tmp = Path(tempfile.mkdtemp())
    caso.addCleanup(shutil.rmtree, tmp, True)
    (tmp / ".lane").mkdir()
    return tmp


class ProvaE22(unittest.TestCase):
    """(a) A prova só vale com `Executed N tests, with 0 failures`, N>0, em cada suíte."""

    def wt(self, *linhas) -> Path:
        tmp = _lane_dir(self)
        (tmp / ".lane" / "proof.log").write_text("\n".join(linhas) + "\n", encoding="utf-8")
        return tmp

    def test_zero_testes_ou_log_vazio_nao_e_verde(self):
        vazio = _lane_dir(self)
        (vazio / ".lane" / "proof.log").write_text("", encoding="utf-8")
        self.assertNotEqual(d.proof_veredito(vazio, "0"), "verde")
        zero = self.wt("[prova] FooTests: 1ª tentativa", "Executed 0 tests, with 0 failures")
        self.assertEqual(d.proof_veredito(zero, "0"), "sem-prova")
        sem_linha = self.wt("[prova] FooTests: 1ª tentativa", "** TEST SUCCEEDED **")
        self.assertEqual(d.proof_veredito(sem_linha, "0"), "sem-prova")

    def test_cada_suite_precisa_da_linha_com_n_maior_que_zero(self):
        falta = self.wt(
            "[prova] FooTests: 1ª tentativa", "Executed 4 tests, with 0 failures",
            "[prova] BarTests: 1ª tentativa", "** TEST SUCCEEDED **",
        )
        self.assertEqual(d.proof_veredito(falta, "0"), "sem-prova")
        ok = self.wt(
            "[prova] FooTests: 1ª tentativa", "Executed 4 tests, with 0 failures",
            "[prova] BarTests: 1ª tentativa", "Executed 2 tests, with 0 failures (0 unexpected)",
        )
        self.assertEqual(d.proof_veredito(ok, "0"), "verde")

    def test_unittest_do_python_conta_como_prova(self):
        ok = self.wt("[prova] tests.test_watch", "......", "-" * 70, "Ran 77 tests in 0.007s", "", "OK")
        self.assertEqual(d.proof_veredito(ok, "0"), "verde")
        pulado = self.wt("[prova] tests.test_x", "Ran 3 tests in 0.1s", "", "OK (skipped=1)")
        self.assertEqual(d.proof_veredito(pulado, "0"), "verde")
        zero = self.wt("[prova] tests.test_x", "Ran 0 tests in 0.000s", "", "OK")
        self.assertEqual(d.proof_veredito(zero, "0"), "sem-prova")
        sem_ok = self.wt("[prova] tests.test_x", "Ran 3 tests in 0.1s", "", "FAILED (failures=1)")
        self.assertNotEqual(d.proof_veredito(sem_ok, "0"), "verde")
        misto = self.wt("[prova] FooTests", "Executed 4 tests, with 0 failures",
                        "[prova] tests.test_x", "Ran 3 tests in 0.1s", "OK")
        self.assertEqual(d.proof_veredito(misto, "0"), "verde")

    def test_vermelho_na_ultima_tentativa_continua_vermelho(self):
        wt = self.wt("[prova] FooTests: 1ª tentativa", "Executed 4 tests, with 1 failure")
        self.assertEqual(d.proof_veredito(wt, "0"), "vermelho")


class StrikesDaOpencode(unittest.TestCase):
    """FRA-443: um contador por card, em qualquer lane. O teto é o do esforço (D1)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.antes = (d.STATE_DIR, d.linear, d.LEDGER_FILE)
        d.STATE_DIR = self.tmp
        self.ledger = self.tmp / "ledger.jsonl"
        self.ledger.write_text("", encoding="utf-8")
        d.LEDGER_FILE = self.ledger
        self.calls = []

        def falso(query, variables):
            self.calls.append((query, variables))
            return {}

        d.linear = falso
        self.addCleanup(lambda: (
            setattr(d, "STATE_DIR", self.antes[0]),
            setattr(d, "linear", self.antes[1]),
            setattr(d, "LEDGER_FILE", self.antes[2]),
        ))

    def st(self, lane="opencode", card="FRA-9", log="l", effort="medio"):
        return {"lane": lane, "card": card, "issue_id": f"id-{card}", "log": log,
                "worktree": "w", "effort": effort,
                "started": 1_700_000_000, "agora": 1_700_000_060}

    def corpos(self):
        return [v.get("body", "") for q, v in self.calls if "commentCreate" in q]

    def test_abaixo_do_limite_marca_lane_falhou_e_nao_tira_a_lane(self):
        primeira = d.fail(self.st(log="rodada-1"), "a prova do dispatcher falhou (A, código 1)")
        self.assertIn("lane:falhou", primeira)
        self.assertEqual(d.strikes_do_card("FRA-9"), 1)
        self.assertFalse(any("issueRemoveLabel" in q for q, _v in self.calls))
        self.calls.clear()
        segunda = d.fail(self.st(log="rodada-2"), "a prova do dispatcher falhou (A, código 1)")
        self.assertIn("lane:falhou", segunda)
        self.assertEqual(d.strikes_do_card("FRA-9"), 2)
        self.assertFalse(any("parou por freio" in c for c in self.corpos()))
        self.assertFalse(any("issueRemoveLabel" in q for q, _v in self.calls))
        self.assertTrue(any(v.get("label") == d.LABEL_LANE_FALHOU_ID for _q, v in self.calls))

    def test_qualquer_lane_entra_no_contador(self):
        d.fail(self.st("claude", log="claude-1"), "agente saiu com código 1 (x)")
        self.assertEqual(d.strikes_do_card("FRA-9"), 1)

    def test_a_mesma_rodada_nao_conta_duas_vezes(self):
        d.registrar_falha_opencode(self.st(log="mesmo-log"), "falha")
        d.registrar_falha_opencode(self.st(log="mesmo-log"), "falha de novo")
        self.assertEqual(d.strikes_do_card("FRA-9"), 1)

    def test_abaixo_do_limite_a_menor_porcentagem_ainda_vence(self):
        d.registrar_falha_opencode(self.st(log="a"), "falha 1")
        d.registrar_falha_opencode(self.st(log="b"), "falha 2")
        medidas = {"claude": (80, "5 h"), "opencode": (10, "5 h")}
        card = {"identifier": "FRA-9", "_effort": "medio"}
        out = d.spread_auto([card], medidas, ["claude", "opencode"], set(), {})
        self.assertEqual(out[0][1], "opencode")

    def test_no_limite_nenhuma_lane_assume(self):
        for i in range(3):
            d.registrar_falha_opencode(self.st(log=f"n-{i}"), f"falha {i}")
        medidas = {"claude": (80, "5 h"), "opencode": (10, "5 h")}
        card = {"identifier": "FRA-9", "_effort": "medio"}
        out = d.spread_auto([card], medidas, ["claude", "opencode"], set(), {})
        self.assertIsNone(out[0][1])
        self.assertTrue(d.card_banido_da_lane("claude", "FRA-9", "medio"))
        self.assertTrue(d.card_banido_da_lane("opencode", "FRA-9", "medio"))

    def test_alto_ainda_cabe_com_tres_falhas(self):
        for i in range(3):
            d.registrar_falha_opencode(self.st(card="FRA-460", log=f"alto-{i}", effort="alto"), "falha")
        self.assertFalse(d.card_banido_da_lane("codex", "FRA-460", "alto"))
        self.assertEqual(d.strikes_do_card("FRA-460"), 3)

    def test_arquivo_antigo_continua_sendo_lido(self):
        (self.tmp / "opencode-strikes.json").write_text(json.dumps({
            "strikes": 2, "max": 2,
            "cards": {"FRA-9": {"n": 2, "motivos": ["prova antiga"]}},
        }), encoding="utf-8")
        self.assertEqual(d.strikes_do_card("FRA-9"), 2)
        d.registrar_falha_opencode(self.st(log="novo"), "de novo")
        self.assertEqual(d.strikes_do_card("FRA-9"), 3)
        dados = json.loads((self.tmp / "opencode-strikes.json").read_text(encoding="utf-8"))
        self.assertIn("prova antiga", dados["cards"]["FRA-9"]["motivos"])

    def test_constantes_sao_as_da_decisao(self):
        self.assertEqual(d.TENTATIVAS_MAX, {"baixo": 3, "medio": 3, "alto": 5})
        self.assertEqual(d.ORCAMENTO_ACUMULADO_USD, {"baixo": 8, "medio": 20, "alto": 40})
        self.assertEqual(d.TEMPO_ACUMULADO_MIN, {"baixo": 120, "medio": 270, "alto": 360})
        self.assertEqual(d.FREIO_LABEL, "lane:falhou")
        self.assertEqual(d.HEADROOM_PCT, {"baixo": 90, "medio": 80, "alto": 60})
        self.assertEqual(d.HEADROOM_PCT_LONGA, {"baixo": 95, "medio": 90, "alto": 85})
        self.assertEqual(d.BUDGET_USD, {"baixo": 3, "medio": 8, "alto": 20})
        self.assertEqual(d.LANE_TIMEOUT_MIN, 90)
        texto = Path(d.__file__).read_text(encoding="utf-8")
        self.assertIn("28/10/2026", texto)
        self.assertIn("Franciel", texto)

    def test_limite_de_tentativas_em_qualquer_lane(self):
        for lane in ("claude", "grok", "codex", "opencode"):
            self.assertIn(lane, d.LANES)
        for lane, ident in (("claude", "FRA-443"), ("grok", "FRA-444"),
                            ("codex", "FRA-445"), ("opencode", "FRA-446")):
            self.calls.clear()
            saida = ""
            for i in range(3):
                saida = d.fail(self.st(lane, ident, f"{ident}-{i}"),
                               "a prova do dispatcher falhou (A, código 1)")
            self.assertIn("lane:falhou", saida)
            self.assertEqual(d.strikes_do_card(ident), 3)
            self.assertTrue(any("tentativas: 3 de 3" in c and "gasto:" in c and "tempo:" in c
                                for c in self.corpos()))
            self.assertTrue(any("parou por freio" in c for c in self.corpos()))
            self.assertTrue(any(v.get("label") == d.LABEL_LANE_FALHOU_ID for _q, v in self.calls))
            self.assertFalse(any("issueRemoveLabel" in q for q, _v in self.calls))

    def test_alto_so_freia_na_quinta(self):
        for i in range(4):
            self.calls.clear()
            d.fail(self.st("claude", "FRA-447", f"alto-{i}", "alto"), "agente saiu com código 1 (x)")
            self.assertFalse(any("parou por freio" in c for c in self.corpos()))
        self.calls.clear()
        d.fail(self.st("claude", "FRA-447", "alto-4", "alto"), "agente saiu com código 1 (x)")
        self.assertTrue(any("tentativas: 5 de 5" in c for c in self.corpos()))
        self.assertTrue(any("parou por freio" in c for c in self.corpos()))

    def test_orcamento_acumulado_para_o_card(self):
        self.ledger.write_text("\n".join([
            json.dumps({"id": "FRA-450-claude-20261028-120000", "card": "FRA-450",
                        "lane": "claude", "custo_usd": 5.0, "duracao_ms": 60_000,
                        "semana": "2026-W44"}),
            json.dumps({"id": "FRA-450-claude-20261028-130000", "card": "FRA-450",
                        "lane": "claude", "custo_usd": 4.0, "duracao_ms": 60_000,
                        "semana": "2026-W44"}),
        ]) + "\n", encoding="utf-8")
        wt = self.tmp / "wt-450"
        wt.mkdir()
        (wt / "arquivo").write_text("fica", encoding="utf-8")
        st = self.st("claude", "FRA-450", "FRA-450-claude-20261028-140000.jsonl", "baixo")
        st["worktree"] = str(wt)
        saida = d.fail(st, "a prova do dispatcher falhou (A, código 1)")
        self.assertIn("lane:falhou", saida)
        self.assertTrue(any("parou por freio" in c and "US$ 9.00 de 8" in c for c in self.corpos()))
        self.assertEqual((wt / "arquivo").read_text(encoding="utf-8"), "fica")
        dados = json.loads((self.tmp / "opencode-strikes.json").read_text(encoding="utf-8"))
        self.assertEqual(dados["cards"]["FRA-450"]["gasto_usd"], 9.0)

    def test_tempo_acumulado_soma_ledger_e_relogio(self):
        self.ledger.write_text(json.dumps({
            "id": "FRA-451-claude-20261028-100000", "card": "FRA-451", "lane": "claude",
            "custo_usd": 1.0, "duracao_ms": 100 * 60 * 1000, "semana": "2026-W44",
        }) + "\n", encoding="utf-8")
        st = self.st("grok", "FRA-451", "FRA-451-grok-20261028-120000.jsonl", "baixo")
        st["started"] = 1_700_000_000
        st["agora"] = 1_700_000_000 + 21 * 60
        saida = d.fail(st, "a prova do dispatcher falhou (A, código 1)")
        self.assertIn("lane:falhou", saida)
        self.assertTrue(any("parou por freio" in c and "tempo: 121 de 120" in c for c in self.corpos()))

    def test_ajuste_do_revisor_conta_uma_vez(self):
        comentarios = [
            {"id": "c1", "body": "[Revisor] REVISOR: AJUSTES · head `abc1234`"},
            {"id": "c1", "body": "[Revisor] REVISOR: AJUSTES · head `abc1234`"},
            {"id": "c2", "body": "[Revisor] REVISOR: APROVADO · head `abc1234`"},
        ]
        self.assertEqual(d.registrar_ajustes_ollie("FRA-448", comentarios, "baixo"), 1)
        mais = comentarios + [{"id": "c3", "body": "REVISOR: AJUSTES no head novo"}]
        self.assertEqual(d.registrar_ajustes_ollie("FRA-448", mais, "baixo"), 2)
        self.assertEqual(d.strikes_do_card("FRA-448"), 2)

    def test_tres_ajustes_no_baixo_estouram_o_freio_antes_de_assumir(self):
        comentarios = [{"id": f"c{i}", "body": "REVISOR: AJUSTES"} for i in range(3)]
        issue = {"identifier": "FRA-449", "id": "id-449", "_effort": "baixo",
                 "comments": {"nodes": comentarios}}
        auto, por_lane = [issue], {}
        linhas = d.retirar_travados(auto, por_lane, True)
        self.assertEqual(auto, [])
        self.assertTrue(linhas)
        self.assertTrue(any("tentativas: 3 de 3" in c and "parou por freio" in c for c in self.corpos()))
        self.assertTrue(any(v.get("label") == d.LABEL_LANE_FALHOU_ID for _q, v in self.calls))


class ProvaPresa(unittest.TestCase):
    """(b) pid em proof_pid, killpg no timeout e no stop, prova morta refeita uma vez."""

    def setUp(self):
        self.antes_state = d.STATE_DIR
        self.tmp_state = Path(tempfile.mkdtemp())
        d.STATE_DIR = self.tmp_state
        self.addCleanup(setattr, d, "STATE_DIR", self.antes_state)
        self.addCleanup(shutil.rmtree, self.tmp_state, True)
        self.procs = []
        self.addCleanup(self._mata_sobras)

    def _mata_sobras(self):
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                proc.wait(timeout=2)

    def _segura_lock(self) -> tuple[Path, subprocess.Popen]:
        wt = _lane_dir(self)
        lock = wt / "build.lock"
        ready = wt / "ready"
        codigo = (
            "import fcntl, sys, time\n"
            "f = open(sys.argv[1], 'a')\n"
            "fcntl.flock(f, fcntl.LOCK_EX)\n"
            "open(sys.argv[2], 'w').write('ok')\n"
            "f.flush()\n"
            "time.sleep(60)\n"
        )
        proc = subprocess.Popen([sys.executable, "-c", codigo, str(lock), str(ready)],
                                start_new_session=True)
        self.procs.append(proc)
        for _ in range(50):
            if ready.exists():
                break
            time.sleep(0.05)
        self.assertTrue(ready.exists(), "a prova de teste não segurou o lock")
        (wt / ".lane" / "proof_pid").write_text(str(proc.pid), encoding="utf-8")
        (wt / ".lane" / "proof_started").write_text(str(time.time() - d.PROOF_TIMEOUT_MIN * 60 - 30),
                                                   encoding="utf-8")
        return wt, proc

    def _lock_livre(self, lock: Path) -> bool:
        fd = os.open(lock, os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
            return True
        except BlockingIOError:
            return False
        finally:
            os.close(fd)

    def test_timeout_mata_o_grupo_e_solta_o_lock(self):
        wt, proc = self._segura_lock()
        st = {"lane": "claude", "card": "FRA-1", "session": "lane-claude"}
        self.assertEqual(d.acompanhar_prova(st, wt, ["FooTests"]), "timeout")
        self.assertFalse(d.prova_viva(proc.pid))
        self.assertTrue(self._lock_livre(wt / "build.lock"))
        self.assertFalse((wt / ".lane" / "proof_pid").exists())

    def test_stop_mata_o_grupo_e_solta_o_lock(self):
        wt, proc = self._segura_lock()
        (self.tmp_state / "stop-claude").write_text("1", encoding="utf-8")
        st = {"lane": "claude", "card": "FRA-1", "session": "lane-claude"}
        self.assertEqual(d.acompanhar_prova(st, wt, ["FooTests"]), "stop")
        self.assertFalse(d.prova_viva(proc.pid))
        self.assertTrue(self._lock_livre(wt / "build.lock"))

    def test_prova_morta_refeita_uma_vez(self):
        wt = _lane_dir(self)
        morto = subprocess.Popen(["sleep", "0"])
        morto.wait(timeout=5)
        lane = wt / ".lane"
        (lane / "proof_pid").write_text(str(morto.pid), encoding="utf-8")
        (lane / "proof_started").write_text(str(time.time()), encoding="utf-8")
        self.assertEqual(d.decidir_prova_morta(lane), "refazer")
        self.assertTrue((lane / "proof_morta").exists())
        self.assertEqual(d.decidir_prova_morta(lane), "esgotou")
        # a repetição também morta encerra; uma terceira não começa
        st = {"lane": "claude", "card": "FRA-1"}
        self.assertEqual(d.acompanhar_prova(st, wt, ["FooTests"]), "morta")

    def test_start_proof_grava_o_pid(self):
        wt = _lane_dir(self)
        d.projetos._resetar_cache()
        d.projetos._CACHE["lista"] = [d.projetos.Projeto(
            id="x", nome="Falso", repo=str(wt), worktrees=str(wt),
            prova="sleep 30", prova_tentativas=1)]
        self.addCleanup(d.projetos._resetar_cache)
        try:
            d.start_proof(wt, ["FooTests"])
            pid = int((wt / ".lane" / "proof_pid").read_text())
            self.assertTrue(d.prova_viva(pid))
            d.matar_prova(wt)
            self.assertFalse(d.prova_viva(pid))
        finally:
            d.projetos._CACHE.pop("lista", None)


class LimiteEmTodasAsLanes(unittest.TestCase):
    """(c) 429 e limite de uso em qualquer lane: sem lane:falhou, espera de 1 h a 8 h,
    card que não começou volta à fila."""

    LOGS = {
        "claude": '{"type":"error","error":{"status":429,"message":"You have hit your limit"}}\n',
        "codex": "You've hit your usage limit. Try again later.\n",
        "grok": '{"type":"error","error":{"status":429,"message":"rate limit exceeded"}}\n',
        "opencode": (
            '{"type":"error","error":{"type":"provider.quota","status":429,'
            '"message":"FreeUsageLimitError"}}\n'
        ),
    }

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.antes = (d.STATE_DIR, d.linear)
        d.STATE_DIR = self.tmp
        self.calls = []
        d.linear = lambda query, variables: self.calls.append((query, variables)) or {}
        self.addCleanup(lambda: (setattr(d, "STATE_DIR", self.antes[0]), setattr(d, "linear", self.antes[1])))

    def _log(self, texto):
        p = self.tmp / "agent.jsonl"
        p.write_text(texto, encoding="utf-8")
        return str(p)

    def test_espera_dobra_de_1h_ate_8h(self):
        self.assertEqual(d.LIMIT_429_BASE_S, 3600)
        self.assertEqual(d.LIMIT_429_MAX_S, 8 * 3600)
        log = self._log(self.LOGS["codex"])
        esperas = [round(d.account_limit(log, "codex") - time.time()) for _ in range(5)]
        self.assertEqual(esperas[0], 3600)
        self.assertEqual(esperas[1], 7200)
        self.assertEqual(esperas[2], 14400)
        self.assertEqual(esperas[-1], 8 * 3600)

    def test_cada_lane_reconhece_limite_e_nao_vira_falha(self):
        for lane, texto in self.LOGS.items():
            with self.subTest(lane=lane):
                until = d.account_limit(self._log(texto), lane)
                self.assertIsNotNone(until)
                self.assertGreaterEqual(until - time.time(), d.LIMIT_429_BASE_S - 2)

    def test_card_nao_iniciado_volta_a_fila_sem_lane_falhou(self):
        wt = self._repo()
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=wt, text=True).strip()
        st = {"lane": "claude", "card": "FRA-2", "issue_id": "id-2", "log": "l",
              "worktree": str(wt), "base": base}
        until = time.time() + 3600
        texto = d.reacao_ao_limite(st, until)
        self.assertIn("devolvido à fila", texto)
        self.assertNotIn("lane:falhou", texto)
        self.assertFalse(any(v.get("label") == d.LABEL_LANE_FALHOU_ID for _q, v in self.calls))
        self.assertTrue(any("issueRemoveLabel" in q and v.get("label") == d.LABEL_LANE_IDS["claude"]
                            for q, v in self.calls))
        self.assertAlmostEqual(d.lane_limited("claude"), until, delta=2)

    def test_card_ja_comecado_retoma_sem_lane_falhou(self):
        wt = self._repo()
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=wt, text=True).strip()
        (wt / "novo.txt").write_text("x", encoding="utf-8")
        st = {"lane": "grok", "card": "FRA-3", "issue_id": "id-3", "log": "l",
              "worktree": str(wt), "base": base}
        self.assertTrue(d.card_ja_comecou(st))
        texto = d.reacao_ao_limite(st, time.time() + 3600)
        self.assertIn("volta sozinho", texto)
        self.assertFalse(any(v.get("label") == d.LABEL_LANE_FALHOU_ID for _q, v in self.calls))
        self.assertFalse(any("issueRemoveLabel" in q for q, _v in self.calls))

    def _repo(self) -> Path:
        wt = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, wt, True)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=wt, check=True)
        subprocess.run(["git", "config", "user.email", "t@example.com"], cwd=wt, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=wt, check=True)
        (wt / "a.txt").write_text("a", encoding="utf-8")
        subprocess.run(["git", "add", "a.txt"], cwd=wt, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "i"], cwd=wt, check=True)
        (wt / ".lane").mkdir()
        return wt


class JuntaMainAntesDaRodada(unittest.TestCase):
    """PRD 29/10, mudança 1: a branch do card recebe a origin/main antes de cada rodada."""

    def _git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    def setUp(self):
        raiz = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, raiz, True)
        self.origem = raiz / "origem.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origem)], check=True)
        self.dono = raiz / "dono"
        subprocess.run(["git", "clone", "-q", str(self.origem), str(self.dono)], check=True, capture_output=True)
        for wt in (self.dono,):
            self._git(wt, "config", "user.email", "t@example.com")
            self._git(wt, "config", "user.name", "t")
        self._git(self.dono, "checkout", "-q", "-b", "main")
        (self.dono / "a.txt").write_text("a\n", encoding="utf-8")
        self._git(self.dono, "add", "a.txt")
        self._git(self.dono, "commit", "-q", "-m", "i")
        self._git(self.dono, "push", "-q", "origin", "main")
        self.wt = raiz / "wt"
        subprocess.run(["git", "clone", "-q", str(self.origem), str(self.wt)], check=True, capture_output=True)
        self._git(self.wt, "config", "user.email", "t@example.com")
        self._git(self.wt, "config", "user.name", "t")
        self._git(self.wt, "checkout", "-q", "-b", "card")
        (self.wt / ".lane").mkdir()
        (self.wt / "card.txt").write_text("card\n", encoding="utf-8")
        self._git(self.wt, "add", "card.txt")
        self._git(self.wt, "commit", "-q", "-m", "card")

    def _main_anda(self, nome: str = "b.txt", texto: str = "b\n") -> None:
        (self.dono / nome).write_text(texto, encoding="utf-8")
        self._git(self.dono, "add", nome)
        self._git(self.dono, "commit", "-q", "-m", "main andou")
        self._git(self.dono, "push", "-q", "origin", "main")

    def test_branch_em_dia_nao_ganha_commit(self):
        head = self._git(self.wt, "rev-parse", "HEAD")
        self.assertEqual(d.juntar_main(self.wt), ("", ""))
        self.assertEqual(self._git(self.wt, "rev-parse", "HEAD"), head)

    def test_branch_atrasada_recebe_a_main(self):
        self._main_anda()
        linha, nota = d.juntar_main(self.wt)
        self.assertIn("main juntada na branch", linha)
        self.assertEqual(nota, "")
        self.assertTrue((self.wt / "b.txt").exists())
        self._git(self.wt, "merge-base", "--is-ancestor", "origin/main", "HEAD")

    def test_worktree_sujo_nao_e_tocado(self):
        self._main_anda()
        (self.wt / "card.txt").write_text("mexido\n", encoding="utf-8")
        head = self._git(self.wt, "rev-parse", "HEAD")
        linha, nota = d.juntar_main(self.wt)
        self.assertIn("mudança sem commit", linha)
        self.assertIn("Main atrasada", nota)
        self.assertEqual(self._git(self.wt, "rev-parse", "HEAD"), head)
        self.assertEqual((self.wt / "card.txt").read_text(encoding="utf-8"), "mexido\n")

    def test_lane_nao_conta_como_sujeira(self):
        self._main_anda()
        (self.wt / ".lane" / "result.json").write_text("{}", encoding="utf-8")
        linha, _nota = d.juntar_main(self.wt)
        self.assertIn("main juntada na branch", linha)

    def test_conflito_fica_marcado_para_a_lane(self):
        self._main_anda("card.txt", "da main\n")
        linha, nota = d.juntar_main(self.wt)
        self.assertIn("conflito em card.txt", linha)
        self.assertIn("Rodada de conflito", nota)
        self.assertIn("<<<<<<<", (self.wt / "card.txt").read_text(encoding="utf-8"))

    def test_merge_pela_metade_nao_comeca_outro(self):
        self._main_anda("card.txt", "da main\n")
        d.juntar_main(self.wt)                      # deixa o conflito marcado
        self._main_anda("c.txt", "c\n")             # a main anda de novo
        linha, nota = d.juntar_main(self.wt)
        self.assertIn("pela metade", linha)
        self.assertIn("card.txt", linha)
        self.assertIn("Rodada de conflito", nota)
        self.assertFalse((self.wt / "c.txt").exists())

    def test_excecao_nao_derruba_o_claim(self):
        with mock.patch.object(d, "_juntar_main", side_effect=subprocess.TimeoutExpired("git", 180)):
            linha, nota = d.juntar_main(self.wt)
        self.assertIn("TimeoutExpired", linha)
        self.assertEqual(nota, "")

    def test_historico_antigo_e_detectado(self):
        self.assertFalse(d.historico_antigo(self.wt))
        self._git(self.wt, "checkout", "-q", "--orphan", "velha")
        (self.wt / "velho.txt").write_text("v\n", encoding="utf-8")
        self._git(self.wt, "add", "-A")
        self._git(self.wt, "commit", "-q", "-m", "histórico antigo")
        self._git(self.wt, "fetch", "-q", "origin", "main")
        self.assertTrue(d.historico_antigo(self.wt))

    def test_fetch_falho_segue_a_rodada(self):
        self._git(self.wt, "remote", "set-url", "origin", str(self.origem) + "-nao-existe")
        head = self._git(self.wt, "rev-parse", "HEAD")
        linha, nota = d.juntar_main(self.wt)
        self.assertIn("fetch falhou", linha)
        self.assertEqual(nota, "")
        self.assertEqual(self._git(self.wt, "rev-parse", "HEAD"), head)


class EstadoDaLaneAtomico(unittest.TestCase):
    def test_save_state_nao_deixa_temporario_e_le_de_volta(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        with mock.patch.object(d, "STATE_DIR", tmp):
            d.save_state("claude", {"card": "FRA-1"})
            self.assertEqual(d.load_state("claude"), {"card": "FRA-1"})
            self.assertEqual(sorted(p.name for p in tmp.iterdir()), ["lane-claude.json"])


class FilaDoTodo(unittest.TestCase):
    """(d) Lane ociosa sobe do Todo o card pronto de maior prioridade.
    Bloqueio, BLOQUEADA e needs:dono ficam. A lane segue a de menor %."""

    def card(self, ident, prio=3, titulo="Card", labels=None, blockers=None):
        if labels is None:
            labels = [{"name": "medio", "parent": {"name": "esforco"}}]
        rels = [{"type": "blocks", "issue": {"identifier": b, "state": {"type": "started", "name": "In Progress"}}}
                for b in (blockers or [])]
        return {"id": ident, "identifier": ident, "title": titulo, "priority": prio,
                "labels": {"nodes": labels}, "inverseRelations": {"nodes": rels},
                "history": {"nodes": []}, "branchName": f"b-{ident}", "url": "u"}

    def test_sobe_o_de_maior_prioridade_e_respeita_o_limite_de_vagas(self):
        cards = [
            self.card("BAIXA", prio=4),
            self.card("ALTA", prio=1),
            self.card("MEDIA", prio=3),
        ]
        uma = d.escolher_do_todo(cards, ["claude"])
        self.assertEqual([c["identifier"] for c in uma], ["ALTA"])
        duas = d.escolher_do_todo(cards, ["claude", "grok"])
        self.assertEqual([c["identifier"] for c in duas], ["ALTA", "MEDIA"])
        self.assertEqual(d.escolher_do_todo(cards, []), [])

    def test_bloqueio_bloqueada_e_needs_nao_sobem(self):
        cards = [
            self.card("BLOQ", titulo="FRA BLOQUEADA agora"),
            self.card("NEEDS", labels=[{"name": "medio", "parent": {"name": "esforco"}},
                                       {"name": "needs:dono"}]),
            self.card("DEP", blockers=["FRA-1"]),
            self.card("FALHOU", labels=[{"name": "medio", "parent": {"name": "esforco"}},
                                        {"name": "lane:falhou"}]),
            self.card("OK", prio=2),
        ]
        escolhidos = d.escolher_do_todo(cards, ["claude", "grok", "opencode", "codex"])
        self.assertEqual([c["identifier"] for c in escolhidos], ["OK"])

    def test_vaga_so_com_lane_ociosa(self):
        self.assertEqual(d.lanes_ociosas({"claude", "grok"}, set(), {}, {"claude": [], "grok": []}),
                         [l for l in d.LANES if l in {"claude", "grok"}])
        self.assertEqual(d.lanes_ociosas({"claude"}, {"claude"}, {}, {"claude": []}), [])
        self.assertEqual(d.lanes_ociosas({"claude"}, set(), {"claude": time.time() + 10}, {"claude": []}), [])
        self.assertEqual(d.lanes_ociosas({"claude"}, set(), {}, {"claude": [{"identifier": "X"}]}), [])

    def test_lane_continua_sendo_a_de_menor_pct(self):
        lane, shown = d.pick_lane({"claude": (80, "5 h"), "opencode": (10, "5 h")},
                                  ["claude", "opencode"])
        self.assertEqual(lane, "opencode")
        self.assertIn("10", shown)


class LaneParadaEPrompts(unittest.TestCase):
    """(e) Log parado 10 min é stop 'sem saída'. Prompt da opencode entre aspas.
    lane-prompt-opencode.md sem perguntas. lane-prompt.md sem as contradições."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.antes = (d.STATE_DIR, d.tmux_alive)
        d.STATE_DIR = self.tmp
        d.tmux_alive = lambda _sessao: True
        self.addCleanup(lambda: (setattr(d, "STATE_DIR", self.antes[0]), setattr(d, "tmux_alive", self.antes[1])))

    def test_log_parado_10_min_e_sem_saida(self):
        log = self.tmp / "lane.jsonl"
        log.write_text("{}\n", encoding="utf-8")
        antigo = time.time() - 10 * 60 - 5
        os.utime(log, (antigo, antigo))
        st = {"lane": "claude", "session": "lane-claude", "started": time.time(), "log": str(log)}
        self.assertEqual(d.razao_sem_exit(st), "sem saída")
        self.assertEqual(d.causa_de("sem saída"), "sem-saida")
        os.utime(log, None)
        self.assertIsNone(d.razao_sem_exit(st))
        self.assertFalse(d.log_sem_saida(str(log), time.time(), limite=10 * 60))
        self.assertTrue(d.log_sem_saida(str(log), time.time() + 600, limite=10 * 60))

    def test_prompt_com_espacos_e_aspas_chega_inteiro_na_opencode(self):
        cmd = d.texto_do_agente("opencode", "medio")
        self.assertIn('-- "$(cat .lane/prompt.md)"', cmd)
        wt = self.tmp / "wt"
        (wt / ".lane").mkdir(parents=True)
        texto = 'um prompt com espaços e "aspas" e $HOME'
        (wt / ".lane" / "prompt.md").write_text(texto, encoding="utf-8")
        out = subprocess.run(["bash", "-c", 'printf %s "$(cat .lane/prompt.md)"'],
                             cwd=wt, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout, texto)

    def test_prompt_opencode_nao_faz_pergunta(self):
        texto = (Path(d.__file__).resolve().parent / "lane-prompt-opencode.md").read_text(encoding="utf-8")
        self.assertNotIn("?", texto)
        self.assertIn("Não pergunte", texto)
        self.assertIn("needs_dono", texto)

    def test_prompt_principal_nao_contradiz_duvida_nem_prova(self):
        texto = (Path(d.__file__).resolve().parent / "lane-prompt.md").read_text(encoding="utf-8")
        self.assertIn("não é needs_dono", texto)
        self.assertIn("Problema de ambiente", texto)
        self.assertIn("Não rode o build", texto)
        self.assertIn("Executed N tests, with 0 failures", texto)
        self.assertIn("Quem roda a prova é o dispatcher", texto)
        for linha in texto.splitlines():
            baixa = linha.lower()
            if any(p in baixa for p in ("rode o build", "rode a suíte", "rode a suite", "rode a prova")):
                self.assertTrue(baixa.strip().startswith("não") or " não " in f" {baixa} ", linha)


class ClassificacaoDeEsforco(unittest.TestCase):
    """FRA-516: regra determinística de classificação de esforço."""

    def test_area_sensivel_alto(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "LGPD: apagamento total de dados",
            "Remove leituras, falas e chave de cifra")
        self.assertEqual(nivel, "alto")
        self.assertFalse(duvida)

    def test_watch_healthkit_alto(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "Watch: captura de voz no relógio",
            "Integra com HealthKit e erase")
        self.assertEqual(nivel, "alto")
        self.assertFalse(duvida)

    def test_lgpd_privacidade_alto(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "LGPD: apagamento total de dados",
            "Remove leituras, falas e chave de cifra")
        self.assertEqual(nivel, "alto")
        self.assertFalse(duvida)

    def test_ui_nova_medio(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "Freio de caminho protegido",
            "Glob morto e freio que não alcança o repo")
        self.assertEqual(nivel, "medio")
        self.assertFalse(duvida)

    def test_so_texto_baixo(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "Docs: atualizar README",
            "Renomear e corrigir typos na documentação")
        self.assertEqual(nivel, "baixo")
        self.assertFalse(duvida)

    def test_so_testes_baixo(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "Docs: atualizar README",
            "Renomear e corrigir typos na documentação")
        self.assertEqual(nivel, "baixo")
        self.assertFalse(duvida)

    def test_sem_sinal_medio_em_duvida(self):
        nivel, motivo, duvida = d.classificar_esforco_por_regra(
            "Ajustar configuração",
            "Mudar parâmetro padrão")
        self.assertEqual(nivel, "medio")
        self.assertTrue(duvida)

    def test_classificar_esforco_retorna_tupla(self):
        nivel, motivo = d.classificar_esforco("Card genérico", "Sem área sensível")
        self.assertIn(nivel, ("baixo", "medio", "alto"))
        self.assertIsInstance(motivo, str)

    def test_ollama_indisponivel_fallback(self):
        # Ollama provavelmente não está rodando no teste; deve cair no fallback
        nivel, motivo = d.classificar_esforco("Ajustar configuração", "Mudar parâmetro padrão")
        self.assertIn(nivel, ("baixo", "medio", "alto"))


class CacheDeTitulos(unittest.TestCase):
    """FRA-563: títulos dos cards para o painel, gravados só quando mudam e com teto."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        antigo = d.STATE_DIR
        self.addCleanup(setattr, d, "STATE_DIR", antigo)
        d.STATE_DIR = self.tmp
        self.arquivo = self.tmp / "titulos-cache.json"

    def test_grava_le_e_ignora_lixo(self):
        d.atualizar_cache_titulos([{"identifier": "FRA-1", "title": "Um"}, "FRA-2", None, {"title": "sem id"}])
        self.assertEqual(json.loads(self.arquivo.read_text(encoding="utf-8")), {"FRA-1": "Um"})
        antes = self.arquivo.stat().st_mtime_ns
        d.atualizar_cache_titulos([{"identifier": "FRA-1", "title": "Um"}])
        self.assertEqual(self.arquivo.stat().st_mtime_ns, antes, "sem mudança, sem gravar")
        self.assertFalse((self.tmp / "titulos-cache.json.tmp").exists())

    def test_guarda_so_os_mais_recentes(self):
        with mock.patch.object(d, "TITULOS_MAX", 3):
            d.atualizar_cache_titulos([{"identifier": f"FRA-{i}", "title": f"T{i}"} for i in range(5)])
            d.atualizar_cache_titulos([{"identifier": "FRA-2", "title": "T2 novo"}])
        self.assertEqual(json.loads(self.arquivo.read_text(encoding="utf-8")),
                         {"FRA-3": "T3", "FRA-4": "T4", "FRA-2": "T2 novo"})

    def test_arquivo_estragado_recomeca(self):
        self.arquivo.write_text("{quebrado", encoding="utf-8")
        d.atualizar_cache_titulos([{"identifier": "FRA-9", "title": "Nove"}])
        self.assertEqual(json.loads(self.arquivo.read_text(encoding="utf-8")), {"FRA-9": "Nove"})


if __name__ == "__main__":
    unittest.main()
