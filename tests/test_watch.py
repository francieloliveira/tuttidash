"""Funções puras do vigia (bots/watch.py): sem rede, sem Linear, sem gh."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("watch", Path(__file__).resolve().parents[1] / "bots" / "watch.py")
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)
# Prompts do repositório, não da cópia instalada: o teste não depende de ~/.transcentia.
watch.PROMPTS_DIR = Path(__file__).resolve().parents[1] / "bots" / "prompts"

# Nenhum teste escreve nos logs reais do Mac (painel, vigia, sombra, análises): o painel mostrava
# linha de teste como se fosse do vigia de verdade (FRA-532, 23/10/2026).
_LOGS = Path(tempfile.mkdtemp(prefix="test-watch-"))
for _nome in ("LOG_FILE", "PANEL_LOG", "SHADOW_NEEDS_LOG", "ANALISES_LOG", "REVISOR_VEREDITOS"):
    setattr(watch, _nome, _LOGS / f"{_nome.lower()}.log")
watch.RUN_LOG_DIR = _LOGS / "runs"


def card(comments, labels=()):
    return {"comments": {"nodes": [{"id": str(i), "body": b} for i, b in enumerate(comments)]},
            "labels": {"nodes": [{"name": n, "parent": None} for n in labels]}, "title": "x"}


class WatchTests(unittest.TestCase):
    def test_decisao(self):
        self.assertEqual(watch.decision("[Triagem] x\nDECISAO: voltar_fila"), "voltar_fila")
        self.assertEqual(watch.decision("[Triagem] x\nDECISÃO: remover_needs"), "remover_needs")
        self.assertEqual(watch.decision("[Triagem] sem linha"), "manter")

    def test_prova_verde_so_no_head_atual(self):
        pr = {"headRefOid": "abc1234def", "body": "verification: dispatcher: safe_xcodebuild.sh test X → verde"}
        self.assertTrue(watch.proof_passed(card(["DONE abc1234\n\nok"]), pr))
        self.assertFalse(watch.proof_passed(card(["DONE 9999999"]), pr))
        self.assertFalse(watch.proof_passed(card(["DONE abc1234"]), dict(pr, body="sem prova")))

    def test_motivo_normalizado_ignora_numeros(self):
        a = watch.stop_reason(card(["✋ lane:parada\n**Motivo:** a prova passou de 40 min"]), "lane:parada")[1]
        b = watch.stop_reason(card(["✋ lane:parada\n**Motivo:** a prova passou de 45 min"]), "lane:parada")[1]
        self.assertEqual(a, b)

    def test_teste_no_aparelho(self):
        self.assertTrue(watch.waiting_device_test(card([], ["teste:aparelho"]), {"labels": []}))
        self.assertFalse(watch.waiting_device_test(card([]), {"labels": [{"name": "Bug"}]}))

    def test_formato_invalido_tenta_mais_uma_vez(self):
        st = {}
        self.assertFalse(watch.format_failure(st, "abc"))  # 1a falha: tenta de novo
        self.assertTrue(watch.format_failure(st, "abc"))   # 2a falha: desiste e avisa
        self.assertFalse(watch.format_failure(st, "def"))  # outro head começa do zero

    def test_bloqueios_abertos(self):
        ci = {"inverseRelations": {"nodes": [
            {"type": "blocks", "issue": {"identifier": "FRA-1", "state": {"type": "completed"}}},
            {"type": "blocks", "issue": {"identifier": "FRA-2", "state": {"type": "started"}}},
            {"type": "related", "issue": {"identifier": "FRA-3", "state": {"type": "backlog"}}}]}}
        self.assertEqual(watch.open_blockers(ci), ["FRA-2"])

    def test_promove_do_backlog_so_pronto_e_sem_bloqueio(self):
        def c(ident, state, labels, blockers=(), prio=1, order=0, title="x"):
            return {"identifier": ident, "title": title, "priority": prio, "sortOrder": order,
                    "state": {"type": state, "name": state},
                    "labels": {"nodes": [{"name": n, "parent": {"name": g}} for n, g in labels]},
                    "inverseRelations": {"nodes": [{"type": "blocks", "issue": {"identifier": b,
                                         "state": {"type": "started"}}} for b in blockers]}}
        issues = [
            c("A", "backlog", [("medio", "esforco")], prio=2),
            c("B", "backlog", [("alto", "esforco")], prio=1),
            c("C", "backlog", [("medio", "esforco")], blockers=["FRA-9"]),
            c("D", "backlog", []),
            c("E", "unstarted", [("medio", "esforco")]),
            c("F", "backlog", [("medio", "esforco"), ("lane:parada", "")]),
        ]
        self.assertEqual([i["identifier"] for i in watch.promotable(issues)], ["B", "A"])

    def test_analise_de_parada_tenta_3_vezes(self):
        st = {}
        self.assertFalse(watch.analysis_failed(st, "c1"))
        self.assertFalse(watch.analysis_failed(st, "c1"))
        self.assertTrue(watch.analysis_failed(st, "c1"))

    def test_detecta_limite_da_conta(self):
        self.assertTrue(watch.LIMIT_RE.search("claude -p (1): aviso | You've hit your monthly spend limit"))
        self.assertIsNone(watch.LIMIT_RE.search("claude -p (1): Permission allow rule has a syntax error"))

    def test_peso_esforco_depois_prioridade(self):
        def c(i, eff, prio, started="2026-10-10"):
            return {"identifier": i, "priority": prio, "startedAt": started,
                    "labels": {"nodes": [{"name": eff, "parent": {"name": "esforco"}}]}}
        self.assertGreater(watch.weight(c("A", "alto", 3)), watch.weight(c("B", "medio", 1)))
        self.assertGreater(watch.weight(c("A", "medio", 1)), watch.weight(c("B", "medio", 3)))
        self.assertGreater(watch.weight(c("A", "medio", 1, "2026-10-09")), watch.weight(c("B", "medio", 1, "2026-10-10")))

    def test_conflito_mais_pesado_vai_primeiro(self):
        def c(i, eff, desc):
            return {"identifier": i, "priority": 1, "startedAt": "2026-10-10", "description": desc,
                    "labels": {"nodes": [{"name": eff, "parent": {"name": "esforco"}}]}}
        leve = c("L", "medio", "mexe em `TranscentIA/UI/MeasurementsView.swift`")
        pesado = c("P", "alto", "toca MeasurementsView.swift e TCComponents.swift")
        outro = c("O", "alto", "só `InformacoesView.swift`")
        others = [(pesado, watch.card_files(pesado)), (outro, watch.card_files(outro))]
        hit = watch.heavier_conflict(leve, watch.card_files(leve), others)
        self.assertEqual(hit[0]["identifier"], "P")
        self.assertEqual(hit[1], {"MeasurementsView.swift"})
        self.assertIsNone(watch.heavier_conflict(pesado, watch.card_files(pesado), [(leve, watch.card_files(leve))]))

    def test_card_of(self):
        self.assertEqual(watch.card_of("[FRA-324] x", "b"), "FRA-324")
        self.assertEqual(watch.card_of("x", "dono/fra-12-y"), "FRA-12")


class MelhoriasDe21Out(unittest.TestCase):
    """Causa estável, needs por evento e revisor (21/10/2026)."""

    def test_causa_vence_o_texto_do_motivo(self):
        a = watch.stop_reason(card(["⛔ **lane:claude** terminou: a prova do dispatcher falhou (A, B, código 0).\n\n"
                                    "- causa: `prova-vermelha`\n… remover a label `lane:falhou`."]), "lane:falhou")[1]
        b = watch.stop_reason(card(["⛔ **lane:claude** terminou: a prova do dispatcher falhou (A, código 65).\n\n"
                                    "- causa: `prova-vermelha`\n… `lane:falhou`."]), "lane:falhou")[1]
        self.assertEqual(a, "causa:prova-vermelha")
        self.assertEqual(a, b)

    def test_motivo_antigo_ignora_lista_entre_parenteses(self):
        a = watch.stop_reason(card(["lane:falhou (a prova do dispatcher falhou (A, B, código 0))"]), "lane:falhou")[1]
        b = watch.stop_reason(card(["lane:falhou (a prova do dispatcher falhou (C, código 1))"]), "lane:falhou")[1]
        self.assertEqual(a, b)

    def test_comentario_da_julia_nao_e_a_parada(self):
        ci = card(["⛔ x\n- causa: `sem-commit`\n`lane:falhou`", "[Triagem] sobre a lane:falhou: ..."])
        self.assertEqual(watch.stop_reason(ci, "lane:falhou"), ("0", "causa:sem-commit"))

    def ci_needs(self, comentarios):
        c = card(comentarios, labels=(watch.OWNER_LABEL,))
        c.update(identifier="X-1", description="d", state={"name": "In Progress"})
        return c

    def test_needs_so_reconfere_quando_muda(self):
        st = {"needs_checked": {}}
        ci = self.ci_needs(["✋ precisa do dono"])
        deve, imp = watch.needs_deve_reconferir(ci, st, agora=1000.0)
        self.assertTrue(deve)
        st["needs_checked"]["X-1"] = {"imp": imp, "at": 1000.0}
        self.assertFalse(watch.needs_deve_reconferir(ci, st, agora=1000.0 + 3600)[0])
        com_bot = self.ci_needs(["✋ precisa do dono", "[Triagem] continua"])
        self.assertFalse(watch.needs_deve_reconferir(com_bot, st, agora=1000.0 + 3600)[0],
                         "comentário de bot não é mudança")
        com_pessoa = self.ci_needs(["✋ precisa do dono", "[Triagem] continua", "feito, pode seguir"])
        self.assertTrue(watch.needs_deve_reconferir(com_pessoa, st, agora=1000.0 + 3600)[0])
        self.assertTrue(watch.needs_deve_reconferir(ci, st, agora=1000.0 + watch.NEEDS_MAX_S + 1)[0],
                        "rede de segurança: reconfere depois do teto mesmo sem mudança")

    def test_needs_registro_antigo_respeita_o_intervalo(self):
        ci = self.ci_needs(["x"])
        self.assertFalse(watch.needs_deve_reconferir(ci, {"needs_checked": {"X-1": 1000.0}}, agora=1010.0)[0])

    def conf(self, **kw):
        c = conf_padrao()
        c.update(kw)
        return c

    def test_revisores_vem_do_catalogo(self):
        nomes = watch.revisores_catalogo()
        for a in ("claude", "codex", "grok", "opencode", "opencode-go"):
            self.assertIn(a, nomes)
        self.assertNotIn("cursor", nomes, "sem CLI sem tela não revisa")

    def test_revisor_independente_do_autor(self):
        sim = lambda _c: "/bin/x"
        self.assertEqual(watch.escolher_revisor("claude", self.conf(), {}, sim)[1], "")
        self.assertNotEqual(watch.fornecedor(watch.escolher_revisor("claude", self.conf(), {}, sim)[0]), "claude")
        self.assertEqual(watch.escolher_revisor("grok", self.conf(), {}, sim), ("claude", ""))
        self.assertEqual(watch.escolher_revisor("manual", self.conf(), {}, sim), ("claude", ""))

    def test_auto_so_com_modelo_que_a_privacidade_libera(self):
        antigo = watch.privacidade_ok
        self.addCleanup(setattr, watch, "privacidade_ok", antigo)
        sim = lambda _c: "/bin/x"
        med = {"codex": [90, "30 dias"], "grok": [100, "créditos"]}
        watch.privacidade_ok = lambda a, m: (not a.startswith("opencode"), "")
        self.assertEqual(watch.escolher_revisor("claude", self.conf(), med, sim), ("claude", "mesmo fornecedor"))
        watch.privacidade_ok = lambda a, m: (True, "")
        self.assertIn(watch.escolher_revisor("claude", self.conf(), med, sim)[0], ("opencode", "opencode-go"))

    def test_auto_escolhe_a_conta_com_mais_folga(self):
        sim = lambda _c: "/bin/x"
        self.assertEqual(watch.escolher_revisor("claude", self.conf(), {"codex": [70, "x"], "grok": [20, "x"]}, sim),
                         ("grok", ""))

    def test_independencia_desligada(self):
        self.assertEqual(watch.escolher_revisor("claude", self.conf(independente=False), {}, lambda _c: "/bin/x"),
                         ("claude", ""))

    def test_preferido_qualquer_agente(self):
        sim = lambda _c: "/bin/x"
        self.assertEqual(watch.escolher_revisor("claude", self.conf(lane="grok"), {}, sim), ("grok", ""))
        self.assertEqual(watch.escolher_revisor("codex", self.conf(lane="codex"), {}, sim), ("claude", ""))

    def test_confirmacao_so_com_quem_aprova_sozinho(self):
        sim = lambda _c: "/bin/x"
        c = self.conf(lane="opencode")
        self.assertEqual(watch.papel("opencode", c), "segunda_opiniao")
        rev, _ = watch.escolher_revisor("claude", c, {}, sim, so_sozinho=True)
        self.assertEqual(watch.papel(rev, c), "sozinho")
        self.assertNotEqual(rev, "opencode")

    def test_comando_de_cada_cli(self):
        c = self.conf()
        ctx = {"prompt": "P --check", "saida": "/tmp/s", "settings": "/tmp/st.json", "mcp": "/tmp/m.json"}
        argv, entrada = watch.comando_revisao("opencode", c, ctx)
        self.assertEqual(argv[:2], ["opencode", "run"])
        self.assertEqual(argv[-2:], ["--", "P --check"], "prompt depois de -- (FRA-474)")
        self.assertIn("--agent", argv)
        self.assertIsNone(entrada)
        argv, entrada = watch.comando_revisao("codex", c, ctx)
        self.assertIn("read-only", argv)
        self.assertEqual(argv[-1], "-")
        self.assertIn("model_reasoning_effort=high", argv)
        self.assertNotIn("-m", argv, "modelo padrao = o do CLI")
        self.assertEqual(entrada, "P --check")
        argv, _ = watch.comando_revisao("claude", c, ctx)
        self.assertEqual(argv[argv.index("--model") + 1], "opus")
        self.assertEqual(argv[argv.index("--settings") + 1], "/tmp/st.json")
        argv, entrada = watch.comando_revisao("grok", c, ctx)
        self.assertEqual(argv[-2:], ["-p", "P --check"])
        self.assertIn("read_file,grep,list_dir", argv)

    def test_limpa_saida_do_cli(self):
        self.assertEqual(watch.limpar_saida("\x1b[0m> plan\n[Revisor] REVISOR: APROVADO\nok"), "[Revisor] REVISOR: APROVADO\nok")


if __name__ == "__main__":
    unittest.main()



class StopNoteTest(unittest.TestCase):
    """Instrução da parada vai para o topo da descrição (FRA-326, 11/10)."""

    def test_puts_instruction_on_top(self):
        ci = {"description": "## Norte servido\n..."}
        text = "[Triagem] Diagnóstico\ncausa E1\nINSTRUCAO: um comando por vez, sem &&.\nDECISAO: voltar_fila"
        note = watch.stop_note(ci, text, 2, "sessão cancelada")
        self.assertTrue(note.startswith("> ⛔ **Retomada 2 (sessão cancelada)"))
        self.assertIn("um comando por vez, sem &&.", note)

    def test_skips_missing_or_repeated_instruction(self):
        text = "[Triagem] x\nINSTRUCAO: um comando por vez.\nDECISAO: voltar_fila"
        self.assertIsNone(watch.stop_note({"description": "> ⛔ um comando por vez."}, text, 3, "r"))
        self.assertIsNone(watch.stop_note({"description": ""}, "[Triagem] x\nDECISAO: voltar_fila", 1, "r"))


class RetomadaExpiraTest(unittest.TestCase):
    """PRD 29/10, mudança 2: a instrução da triagem sai quando o dono libera o card."""

    CORPO = "## Objetivo\n\nTexto `com código` e > citação do card.\n"

    def _bloco(self, n: int, instr: str) -> str:
        texto = f"[Triagem] x\nINSTRUCAO: {instr}\nDECISAO: voltar_fila"
        return watch.stop_note({"description": ""}, texto, n, "causa:prova-vermelha")

    def test_sem_bloco_nao_muda_nada(self):
        self.assertEqual(watch.limpar_retomadas(self.CORPO), (self.CORPO, []))

    def test_tira_um_e_dois_blocos_e_preserva_o_resto(self):
        um = self._bloco(2, "faça git rebase main.")
        nova, tirados = watch.limpar_retomadas(um + self.CORPO)
        self.assertEqual(nova, self.CORPO)
        self.assertEqual(len(tirados), 1)
        self.assertIn("git rebase main", tirados[0])
        dois = self._bloco(3, "um comando por vez.") + um + self.CORPO
        nova, tirados = watch.limpar_retomadas(dois)
        self.assertEqual(nova, self.CORPO)
        self.assertEqual(len(tirados), 2)

    def _rodar(self, cards, st):
        self.escritas, self.comentarios = [], []
        velhos = watch.set_description, watch.comment
        watch.set_description = lambda ci, t: self.escritas.append((ci["identifier"], t))
        watch.comment = lambda i, b: self.comentarios.append((i, b))
        try:
            watch.expirar_retomadas(cards, st, [])
        finally:
            watch.set_description, watch.comment = velhos

    def _card(self, labels, desc):
        return {"id": "id-1", "identifier": "FRA-1", "description": desc,
                "labels": {"nodes": [{"name": n, "parent": None} for n in labels]}}

    def _st(self):
        return {"bloqueios": {}, "removidas_pelo_vigia": {},
                "stops": {"FRA-1": {"vistos": ["c1"], "motivos": {"causa:prova-vermelha": 3}}}}

    def test_dono_tira_needs_dono(self):
        st, desc = self._st(), self._bloco(2, "faça git rebase main.") + self.CORPO
        self._rodar([self._card(["needs:dono", "lane:falhou"], desc)], st)
        self.assertEqual(self.escritas, [])                 # 1ª vez: só registra
        self._rodar([self._card([], desc)], st)
        self.assertEqual(self.escritas, [("FRA-1", self.CORPO)])
        self.assertIn("git rebase main", self.comentarios[0][1])
        self.assertEqual(st["stops"]["FRA-1"]["motivos"], {})
        self.assertEqual(st["stops"]["FRA-1"]["vistos"], ["c1"])
        self.assertNotIn("FRA-1", st["bloqueios"])

    def test_vigia_tira_lane_falhou_e_a_instrucao_fica(self):
        st, desc = self._st(), self._bloco(1, "um comando por vez.") + self.CORPO
        self._rodar([self._card(["lane:falhou"], desc)], st)
        st["removidas_pelo_vigia"]["FRA-1|lane:falhou"] = "agora"
        self._rodar([self._card([], desc)], st)
        self.assertEqual(self.escritas, [])
        self.assertEqual(st["stops"]["FRA-1"]["motivos"], {"causa:prova-vermelha": 3})
        self.assertEqual(st["removidas_pelo_vigia"], {})

    def test_dono_tira_lane_falhou(self):
        st, desc = self._st(), self._bloco(1, "um comando por vez.") + self.CORPO
        self._rodar([self._card(["lane:falhou"], desc)], st)
        self._rodar([self._card([], desc)], st)
        self.assertEqual(self.escritas, [("FRA-1", self.CORPO)])
        self.assertEqual(st["stops"]["FRA-1"]["motivos"], {})

    def test_liberado_sem_bloco_so_zera_o_contador(self):
        st = self._st()
        self._rodar([self._card(["needs:dono"], self.CORPO)], st)
        self._rodar([self._card([], self.CORPO)], st)
        self.assertEqual((self.escritas, self.comentarios), ([], []))
        self.assertEqual(st["stops"]["FRA-1"]["motivos"], {})


class CliNoPathDoVigiaTest(unittest.TestCase):
    """Sob o launchd o PATH do processo não tem os CLIs; a busca usa PATH_ENV."""

    def test_procura_no_path_env(self):
        vistos = []
        antes = watch.shutil.which
        self.addCleanup(setattr, watch.shutil, "which", antes)
        watch.shutil.which = lambda c, path=None: vistos.append(path) or "/x/" + c
        self.assertEqual(watch.cli_instalado("claude"), "/x/claude")
        self.assertEqual(vistos, [watch.PATH_ENV])


class MergeExigeAprovadoTest(unittest.TestCase):
    """Revisão de 29/10, R2/R3: sem APROVADO no head não mergeia; erro de revisão é tentado de novo."""

    PR = {"number": 7, "headRefOid": "abc1234def"}

    def setUp(self):
        self.calls = []
        velhos = (watch.add_label, watch.comment, watch.sh)
        self.addCleanup(lambda: setattr(watch, "add_label", velhos[0]) or setattr(watch, "comment", velhos[1])
                        or setattr(watch, "sh", velhos[2]))
        watch.add_label = lambda i, n: self.calls.append(("label", n))
        watch.comment = lambda i, b: self.calls.append(("comment", b))

    def test_veredito_do_estado_e_do_pr(self):
        st = {"reviewed": {"abc1234def": "APROVADO"}}
        self.assertEqual(watch.veredito_do_head({"dir": "."}, self.PR, st), "APROVADO")
        for v in (None, "formato-invalido", "erro 10-29 01:56"):
            st = {"reviewed": {} if v is None else {"abc1234def": v}}
            self.assertIsNone(watch.veredito_do_head({"dir": "."}, self.PR, st))
        watch.sh = lambda *a, **k: ('{"comments":[{"body":"[Revisor] REVISOR: AJUSTES em abc1234"},'
                                    '{"body":"[Revisor] REVISOR: APROVADO head abc1234"}]}')
        st = {"reviewed": {"abc1234def": "ja-tinha"}}
        self.assertEqual(watch.veredito_do_head({"dir": "."}, self.PR, st), "APROVADO")
        self.assertEqual(st["reviewed"]["abc1234def"], "APROVADO")

    def test_erro_de_revisao_tenta_de_novo_depois_do_intervalo(self):
        st = {"reviewed": {"h": "erro 10-29 01:56"}, "erros_revisao": {"h": 1000.0}}
        self.assertFalse(watch.revisao_pode_tentar(st, "h", 1000.0 + watch.REVIEW_RETRY_S - 1))
        self.assertTrue(watch.revisao_pode_tentar(st, "h", 1000.0 + watch.REVIEW_RETRY_S))
        self.assertTrue(watch.revisao_pode_tentar({"reviewed": {}}, "h"))
        self.assertFalse(watch.revisao_pode_tentar({"reviewed": {"h": "AJUSTES"}}, "h"))
        self.assertFalse(watch.revisao_pode_tentar({"reviewed": {"h": "formato-invalido"}}, "h"))

    def test_sem_aprovado_espera_e_depois_chama_o_dono_uma_vez(self):
        st, ci, diary = {"reviewed": {}}, {"id": "i", "identifier": "FRA-7"}, []
        watch.segurar_sem_aprovacao(ci, self.PR, st, diary, agora=0.0)
        watch.segurar_sem_aprovacao(ci, self.PR, st, diary, agora=watch.REVIEW_WAIT_MAX_S - 1)
        self.assertEqual(self.calls, [])
        watch.segurar_sem_aprovacao(ci, self.PR, st, diary, agora=watch.REVIEW_WAIT_MAX_S)
        watch.segurar_sem_aprovacao(ci, self.PR, st, diary, agora=watch.REVIEW_WAIT_MAX_S * 2)
        self.assertEqual([c[0] for c in self.calls], ["label", "comment"])
        self.assertEqual(self.calls[0][1], watch.OWNER_LABEL)
        self.assertIn("Não mergeio sem revisão", self.calls[1][1])


class ComentariosMaisRecentesTest(unittest.TestCase):
    """O Linear devolve do mais novo para o mais antigo; o vigia lê em ordem cronológica."""

    def test_consulta_pede_os_mais_novos(self):
        self.assertIn("comments(first:30, orderBy: createdAt)", watch.ISSUE_FIELDS)
        self.assertNotIn("last:30", watch.ISSUE_FIELDS)

    def test_em_ordem_poe_o_mais_novo_no_fim_e_o_done_novo_vale(self):
        ci = {"comments": {"nodes": [
            {"id": "3", "body": "[Revisor] REVISOR: APROVADO", "createdAt": "2026-10-29T13:28:00Z"},
            {"id": "2", "body": "DONE e445dea\n\nx", "createdAt": "2026-10-29T11:07:00Z"},
            {"id": "1", "body": "DONE 91aa661\n\nx", "createdAt": "2026-10-29T09:55:00Z"}]}}
        watch.em_ordem(ci)
        self.assertEqual([n["id"] for n in ci["comments"]["nodes"]], ["1", "2", "3"])
        pr = {"body": "dispatcher: x → verde", "headRefOid": "e445dea0000"}
        self.assertTrue(watch.proof_passed(ci, pr))
        self.assertIsNone(watch.em_ordem(None))


class CaixaDoDonoTest(unittest.TestCase):
    """PRD de 29/10: a caixa do dono (pendência, decisões e limpeza de cancelados)."""

    ANALISE = ("[Triagem] Conferência da etiqueta needs:dono\nA rodada foi cancelada.\n"
               "PENDENCIA: escolher o esforço antes de rodar de novo\n"
               "OPCOES: A) Liberar em opus high | B) Reclassificar como médio e liberar [esforco=medio] | "
               "C) Manter parado | D) passar ao codex [lane=codex]\n"
               "RECOMENDA: A — o card é grande e high já foi testado\nDECISAO: manter")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.calls = []
        nomes = ["CAIXA_ARQUIVO", "remove_label", "set_description", "comment", "LABEL_IDS", "IDS_LINEAR"]
        antes = {n: getattr(watch, n) for n in nomes}
        self.addCleanup(lambda: [setattr(watch, n, v) for n, v in antes.items()])
        watch.CAIXA_ARQUIVO = self.tmp / "caixa-dono.json"
        watch.remove_label = lambda i, n: self.calls.append(("remove", n))
        watch.set_description = lambda ci, t: self.calls.append(("desc", t))
        watch.comment = lambda i, b: self.calls.append(("comment", b))
        watch.LABEL_IDS = {watch.OWNER_LABEL: "lab-dono", "lane:falhou": "lab-f", "lane:parada": "lab-p"}
        watch.IDS_LINEAR = {"esforco": {"medio": "lab-medio"}, "lanes": {"codex": "lab-codex"}}

    def _card(self, ident="FRA-1", labels=(), comentarios=(), desc="corpo"):
        return {"id": "id-" + ident, "identifier": ident, "title": "Título", "url": "https://linear.app/x/" + ident,
                "description": desc, "labels": {"nodes": [{"name": n, "parent": None} for n in labels]},
                "comments": {"nodes": [{"id": str(i), "body": b, "createdAt": f"2026-10-29T10:0{i}:00Z"}
                                       for i, b in enumerate(comentarios)]}}

    def test_analise_vira_pendencia_e_opcoes(self):
        a = watch.caixa_da_analise(self.ANALISE)
        self.assertEqual(a["pendencia"], "escolher o esforço antes de rodar de novo")
        self.assertEqual([o["letra"] for o in a["opcoes"]], ["A", "B", "D"], "«manter parado» não é opção")
        self.assertEqual(a["opcoes"][1]["acao"], {"tipo": "esforco", "valor": "medio"})
        self.assertEqual(a["opcoes"][2]["acao"], {"tipo": "lane", "valor": "codex"})
        self.assertIsNone(a["opcoes"][0]["acao"])
        self.assertEqual(a["recomenda"], "A")
        self.assertIn("high já foi testado", a["porque"])

    def test_analise_sem_formato_e_acao_fora_da_lista(self):
        self.assertEqual(watch.caixa_da_analise("[Triagem] texto livre\nDECISAO: manter"),
                         {"pendencia": "", "opcoes": [], "recomenda": "", "porque": ""})
        a = watch.caixa_da_analise("OPCOES: A) apagar a branch [apagar] | B) ok [lane=inventada]\nRECOMENDA: A")
        self.assertEqual(a["opcoes"], [])
        self.assertEqual(a["recomenda"], "", "recomendada que não existe nas opções")

    def test_escreve_a_caixa_com_o_motivo_e_a_analise(self):
        st = {"caixa_analise": {"FRA-1": dict(watch.caixa_da_analise(self.ANALISE), imp="abc", quem="ollama/x")}}
        c1 = self._card("FRA-1", ["needs:dono", "alto", "claude"],
                        ["▶️ lane assumiu", "✋ **lane:claude** parou e precisa do dono.\n\n**Motivo:** rebase negado\n\nfim"])
        c2 = self._card("FRA-2", ["alto"])
        dados = watch.escrever_caixa([c1, c2], st, agora=1_000_000.0)
        lido = json.loads(watch.CAIXA_ARQUIVO.read_text(encoding="utf-8"))
        self.assertEqual(lido, dados)
        self.assertEqual([i["card"] for i in dados["itens"]], ["FRA-1"])
        item = dados["itens"][0]
        self.assertEqual((item["origem"], item["motivo"]), ("lane", "rebase negado"))
        self.assertEqual((item["esforco"], item["lane"], item["pergunta_id"]), ("alto", "claude", "FRA-1:abc"))
        self.assertEqual(item["outras_travas"], [])
        self.assertEqual(item["recomenda"], "A")
        self.assertEqual(dados["ids"]["dono"], "lab-dono")
        self.assertEqual(dados["ids"]["esforco"], {"medio": "lab-medio"})
        watch.escrever_caixa([c2], st, agora=1_000_100.0)
        self.assertEqual(json.loads(watch.CAIXA_ARQUIVO.read_text(encoding="utf-8"))["itens"], [])
        self.assertNotIn("FRA-1", st["caixa_desde"], "saiu da caixa, sai o «desde»")

    def test_sem_analise_sai_o_motivo_cru(self):
        c = self._card("FRA-3", ["needs:dono", "lane:falhou"], ["[Triagem] 3ª parada pelo mesmo motivo (x). dono, preciso de você"])
        item = watch.escrever_caixa([c], {}, agora=5.0)["itens"][0]
        self.assertEqual(item["origem"], "triagem")
        self.assertEqual((item["pendencia"], item["opcoes"]), ("", []))
        self.assertEqual(item["outras_travas"], ["lane:falhou"])

    def test_cancelado_com_pendencia_e_limpo_uma_vez(self):
        bloco = watch.stop_note({"description": ""}, "[Triagem] x\nINSTRUCAO: faça rebase.\nDECISAO: voltar_fila", 2, "r")
        st = {"stops": {"FRA-4": {"vistos": [], "motivos": {"r": 3}}}, "caixa_analise": {"FRA-4": {}}}
        c = self._card("FRA-4", ["needs:dono", "lane:falhou", "alto"], desc=bloco + "corpo")
        watch.limpar_cancelados([c], st, [])
        self.assertEqual([x for x in self.calls if x[0] == "remove"], [("remove", "needs:dono"), ("remove", "lane:falhou")])
        self.assertIn(("desc", "corpo"), self.calls)
        self.assertNotIn("FRA-4", st["stops"])
        self.assertIn("FRA-4", st["cancelados_limpos"])
        self.assertIn("Card cancelado", [x for x in self.calls if x[0] == "comment"][0][1])
        self.calls.clear()
        watch.limpar_cancelados([self._card("FRA-4", ["alto"], desc="corpo")], st, [])
        self.assertEqual(self.calls, [], "sem pendência, nada a limpar")


class CardFilesLaneInfraTest(unittest.TestCase):
    """result.json e .lane/ não contam como arquivo do card (conflito falso de 11/10)."""

    def test_ignores_lane_infra(self):
        ci = {"description": "grave o `.lane/result.json`; depois o result.json; mexe em TranscentIA/UI/MirrorView.swift"}
        self.assertEqual(watch.card_files(ci), {"MirrorView.swift"})


class SeguraPelaDescricaoTest(unittest.TestCase):
    """«Não vai para lane» na descrição segura o card fora da promoção (FRA-283, 12/10)."""

    def test_detecta_a_decisao(self):
        self.assertTrue(watch.held_by_description({"description": "Fica no Backlog. Não vai para lane até ser retomado."}))
        self.assertTrue(watch.held_by_description({"description": "O card nao vai para a lane antes do delta."}))

    def test_descricao_comum_passa(self):
        self.assertFalse(watch.held_by_description({"description": "Escopo: tela nova. Prova do dispatcher (E5)."}))
        self.assertFalse(watch.held_by_description({}))


class FreioDePromocaoTest(unittest.TestCase):
    """FRA-471: a promoção Backlog→Todo precisa de regra mecânica, não de leitura.

    E19 promoveu card que não estava pronto: o FRA-407 voltou da lane e o FRA-454
    subiu com decisão de produto aberta. Os dois estavam escritos no card; o que
    faltava era o freio que lê aquilo.
    """

    # No Linear a label é a filha: nome="medio", grupo pai="esforco".
    def card(self, descricao, titulo="Card qualquer", labels=(("medio", "esforco"),)):
        c = card([], [nome for nome, _ in labels])
        c["labels"]["nodes"] = [{"name": nome, "parent": {"name": grupo}}
                                for nome, grupo in labels]
        c["description"] = descricao
        c["title"] = titulo
        return c

    # --- decisão de produto ---

    def test_decisao_aberta_segura_o_card(self):
        c = self.card("# Decisão pendente do dono (antes de puxar)\n\n"
                      "**Grok e relógio:** confirmar com o dono.\n")
        self.assertIsNotNone(watch.decisao_pendente(c))
        self.assertIn("decisão aberta", watch.motivo_do_freio(c))

    def test_decisao_resolvida_nao_segura(self):
        c = self.card("# Decisão do dono — **RESOLVIDA** em 2026-10-18\n\n"
                      "1. **(a) novo valor** no seletor.\n\n"
                      "## Aceite\n\n- [ ] o seletor mostra o novo valor\n")
        self.assertIsNone(watch.decisao_pendente(c))
        self.assertIsNone(watch.motivo_do_freio(c), "resolvida é o estado normal de card pronto")

    def test_secao_de_decisao_vazia_nao_segura(self):
        """O cabeçalho existe no template mesmo quando não há nada pendente."""
        c = self.card("# Decisão pendente do dono\n\n"
                      "\n# Fora de escopo\n\n* outra coisa\n"
                      "\n## Aceite\n\n- [ ] a prova roda\n")
        self.assertIsNone(watch.decisao_pendente(c))
        self.assertIsNone(watch.motivo_do_freio(c))

    def test_secao_resolvida_mais_adiante_ainda_segura(self):
        c = self.card("## Aceite\n\n- [ ] prova\n\n"
                      "# Decisão do dono\n\nPergunta em aberto.\n")
        self.assertIsNotNone(watch.decisao_pendente(c))

    def test_palavra_solta_nao_vira_decisao(self):
        """«decisão pendente» no meio de um texto não é gate — o texto fala dela."""
        c = self.card("O card fala da decisão pendente anterior e da decisão do produto.\n\n"
                      "## Aceite\n\n- [ ] a prova roda\n")
        self.assertIsNone(watch.decisao_pendente(c))

    def test_titulo_bloqueada_segura(self):
        c = self.card("## Aceite\n\n- [ ] prova\n", titulo="[BLOQUEADA] Rever: servidor próprio")
        self.assertIn("BLOQUEADA", watch.motivo_do_freio(c))

    # --- aceite observável ---

    def test_sem_aceite_algum_segura(self):
        c = self.card("Um card que só descreve o problema.\n")
        self.assertIn("sem aceite observável", watch.motivo_do_freio(c))

    def test_aceite_em_checklist_passa(self):
        c = self.card("## Aceite\n\n- [ ] `python3 lanes/test_lanes.py` sai `OK`\n")
        self.assertIsNone(watch.motivo_do_freio(c))

    def test_aceite_escrito_sem_checklist_diz_que_falta_checklist(self):
        c = self.card("## Aceite\n\na prova do dispatcher sai verde.\n")
        self.assertIn("checkbox", watch.motivo_do_freio(c))

    # --- efeito na promoção ---

    def test_promotable_e_travados_pelo_freio(self):
        issues = [
            dict(self.card("## Aceite\n\n- [ ] prova\n"), state={"type": "backlog"},
                 identifier="FRA-1", priority=0, sortOrder=0),
            dict(self.card("# Decisão do dono\n\npergunta aberta\n"),
                 state={"type": "backlog"}, identifier="FRA-2", priority=0, sortOrder=1),
        ]
        ids_promo = [c["identifier"] for c in watch.promotable(issues)]
        self.assertIn("FRA-1", ids_promo)
        self.assertIn("FRA-2", ids_promo, "promotable continua lista; o filtro é quem segura")
        travados = dict((c["identifier"], m) for c, m in watch.travados_pelo_freio(issues))
        self.assertEqual(list(travados), ["FRA-2"])
        self.assertIn("decisão aberta", travados["FRA-2"])

    def test_freio_so_olha_backlog(self):
        """Card já em In Progress não é julgado pelo gate de promoção."""
        issues = [dict(self.card("# Decisão do dono\n\naberta\n"),
                       state={"type": "started"}, identifier="FRA-3", priority=0, sortOrder=0)]
        self.assertEqual(watch.travados_pelo_freio(issues), [])


class ParidadeAgentesTest(unittest.TestCase):
    """watch, dispatcher e gasto_lanes leem o MESMO catálogo (`agents.d/`)."""

    def test_mesmos_agentes_em_todos_os_registries(self):
        from gasto_lanes import agentes as A
        from gasto_lanes import catalogo as C
        self.assertEqual(tuple(watch.AGENTES), A.AGENTES_CONHECIDOS)
        self.assertEqual(tuple(watch.AGENTES), tuple(C.catalogo()))
        for nome in A.AGENTES_CONHECIDOS:
            self.assertEqual(watch.lane_of(card([], [nome])), nome)
        self.assertEqual(watch.lane_of(card([], [])), "manual")

    def test_cli_dos_agentes_vem_do_manifesto(self):
        from gasto_lanes import catalogo as C
        for nome, d in C.catalogo().items():
            with self.subTest(agente=nome):
                self.assertEqual(watch.AGENTES[nome]["cli"], d["cli"])

    def test_o_vigia_nao_tem_lista_hardcoded(self):
        """Nenhum dicionário de agentes escrito à mão no script do vigia."""
        texto = Path(watch.__file__).read_text()
        self.assertNotIn('"estado_prefixo"', texto)
        self.assertNotIn('"logs_glob"', texto)


class LanesAtivasTest(unittest.TestCase):
    """lanes_ativas(): ligadas no `enabled` E executáveis (IMPLEMENTED_LANES)."""

    def setUp(self):
        self.tmpdir = Path(tempfile.mkdtemp())
        self.enabled = self.tmpdir / "enabled"
        self._lanes_dir_antigo = watch.LANES_DIR
        watch.LANES_DIR = self.tmpdir

    def tearDown(self):
        import shutil
        watch.LANES_DIR = self._lanes_dir_antigo
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _escreve_enabled(self, lanes: str):
        self.enabled.write_text(lanes)

    def test_lanes_ativas_sem_arquivo_enabled(self):
        self.assertEqual(watch.lanes_ativas(), set())

    def test_lanes_ativas_somente_executaveis(self):
        # cursor é conta de uso, não lane: fica de fora mesmo habilitado
        self._escreve_enabled("claude\nopencode\ncodex\ngrok\ncursor\n")
        ativas = watch.lanes_ativas()
        self.assertEqual(ativas, {"claude", "grok", "codex", "opencode"})

    def test_lanes_ativas_separadas_por_espaco(self):
        # Formato que o notch e o dispatcher gravam (20/10: «claude opencode opencode-go»).
        self._escreve_enabled("claude grok\n")
        self.assertEqual(watch.lanes_ativas(), {"claude", "grok"})

    def test_lanes_ativas_opencode_sem_arquivo_de_habilitacao(self):
        # Não há mais lane experimental: opencode e opencode-go valem só pelo `enabled`.
        self._escreve_enabled("claude opencode opencode-go\n")
        self.assertEqual(watch.lanes_ativas(), {"claude", "opencode", "opencode-go"})

    def test_slots_zero_sem_ativas(self):
        ativas = set()
        slots = watch.MAX_PER_LANE * len(ativas)
        self.assertEqual(slots, 0)

    def test_analise_de_parada_de_opencode_usa_claude(self):
        """A análise é do vigia (Claude headless). opencode não aceita as flags do claude -p (FRA-449, 19/10)."""
        capturado = {}

        def falso_sh(args, cwd=None, timeout=120, inp=None, check=True):
            capturado["args"] = args
            return "[Triagem] ok"

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            antes = (watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE)
            watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE = falso_sh, d / "logs", d, d / "w.log"
            try:
                watch.run_agent("x", d, "teste", agente="opencode")
            finally:
                watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE = antes
        self.assertEqual(capturado["args"][0], "claude")
        self.assertIn("-p", capturado["args"])


    def test_analise_progressiva(self):
        self.assertEqual(watch.modelo_da_analise({}, "c", 1), "haiku")
        self.assertEqual(watch.modelo_da_analise({"analise_falhas": {"c": 1}}, "c", 1), "sonnet")
        self.assertEqual(watch.modelo_da_analise({"analise_falhas": {"c": 2}}, "c", 1), "opus")
        self.assertEqual(watch.modelo_da_analise({}, "c", 2), "sonnet")
        self.assertEqual(watch.modelo_da_analise({"analise_falhas": {"c": 5}}, "c", 1), "opus")

    def test_run_agent_modelo_e_esforco(self):
        capturado = {}

        def falso_sh(args, cwd=None, timeout=120, inp=None, check=True):
            capturado["args"] = args
            return "[Triagem] ok"

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            antes = (watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE)
            watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE = falso_sh, d / "logs", d, d / "w.log"
            try:
                watch.run_agent("x", d, "teste", modelo="sonnet", esforco="medium")
            finally:
                watch.sh, watch.RUN_LOG_DIR, watch.STATE_DIR, watch.LOG_FILE = antes
        a = capturado["args"]
        self.assertEqual(a[a.index("--model") + 1], "sonnet")
        self.assertEqual(a[a.index("--effort") + 1], "medium")

    def test_reconferencia_needs_a_cada_30_min(self):
        self.assertEqual(watch.NEEDS_RECHECK_S, 30 * 60)

    def test_needs_cai_no_opencode_quando_o_ollama_nao_responde(self):
        """FRA-532: o Ollama é o principal; sem resposta válida dele, o opencode free."""
        ci = {"identifier": "FRA-3", "id": "z", "title": "t", "state": {"name": "In Progress"},
              "description": "", "labels": {"nodes": []}, "comments": {"nodes": []}}
        antes = (watch.opencode_call, watch.run_agent, watch.lane_log_tail, watch.lane_of, watch.comment,
                 watch.local_call, watch.SHADOW_NEEDS_LOG, watch.PANEL_LOG, watch.LOG_FILE)

        def nao(*a, **k):
            raise AssertionError("o haiku não deveria rodar")

        watch.opencode_call = lambda p: "[Triagem] ok" + chr(10) + "DECISAO: manter"
        watch.run_agent = nao
        watch.lane_log_tail = lambda ident: ("log", "")
        watch.lane_of = lambda c: "opencode"
        watch.comment = lambda *a, **k: None
        watch.local_call = lambda p: None
        watch.SHADOW_NEEDS_LOG = Path("/dev/null")
        watch.PANEL_LOG = Path("/dev/null")
        watch.LOG_FILE = Path("/dev/null")
        try:
            watch.recheck_needs(ci, {"needs_checked": {}, "alerts": {}}, [])
        finally:
            (watch.opencode_call, watch.run_agent, watch.lane_log_tail, watch.lane_of, watch.comment,
             watch.local_call, watch.SHADOW_NEEDS_LOG, watch.PANEL_LOG, watch.LOG_FILE) = antes


def conf_padrao() -> dict:
    """`conf_revisor()` só com os padrões do código e dos manifestos: os Ajustes reais do Mac
    (`revisores.pr` em ~/.transcentia/tools/cfg) não entram no teste."""
    antigo = watch._cfg
    watch._cfg = lambda chave, padrao: padrao
    try:
        return watch.conf_revisor()
    finally:
        watch._cfg = antigo


class PrivacidadeDoRevisor(unittest.TestCase):
    def test_revisor_aceita_modelo_que_treina_desde_23_10(self):
        """A revisão usa a mesma regra das lanes (privacidade.pode_receber_codigo)."""
        if watch.privacidade is None:
            self.skipTest("módulo de privacidade ausente")
        antigo = watch.privacidade._cfg
        self.addCleanup(setattr, watch.privacidade, "_cfg", antigo)
        watch.privacidade._cfg = lambda k, p: p
        ok, motivo = watch.privacidade_ok("opencode", "opencode/nemotron-3.5-super-vl-free")
        self.assertTrue(ok, motivo)

    def test_revisor_do_opencode_some_se_o_modelo_nao_e_seguro(self):
        antigo = watch.privacidade_ok
        self.addCleanup(setattr, watch, "privacidade_ok", antigo)
        sim = lambda _c: "/bin/x"
        c = conf_padrao()
        c.update(reserva="opencode")
        watch.privacidade_ok = lambda a, m: (a != "opencode", "teste")
        self.assertEqual(watch.escolher_revisor("claude", c, {}, sim), ("claude", "mesmo fornecedor"))
        watch.privacidade_ok = lambda a, m: (True, "")
        self.assertEqual(watch.escolher_revisor("claude", c, {}, sim), ("opencode", ""))

    def test_needs_nao_manda_card_para_modelo_inseguro(self):
        antigo = watch.privacidade_ok
        self.addCleanup(setattr, watch, "privacidade_ok", antigo)
        watch.privacidade_ok = lambda a, m: (False, "treina")
        with self.assertRaises(RuntimeError):
            watch.opencode_call("x")


class VigiaLocalPrimeiro(unittest.TestCase):
    """FRA-532 (decisão de 23/10/2026 20h33): Ollama e triagem local primeiro, opencode free depois,
    Claude só por último. Nada aqui chama modelo de verdade nem lê os Ajustes reais."""

    CI = {"identifier": "FRA-9", "id": "id9", "title": "t", "state": {"name": "In Progress"},
          "description": "", "labels": {"nodes": []}, "comments": {"nodes": []}}

    def setUp(self):
        import json
        self.json = json
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = {}
        self.chamadas = []
        self.comentarios = []
        nomes = ["_cfg", "agent_paused", "local_call", "opencode_call", "run_agent", "lane_log_tail",
                 "comment", "remove_label", "add_label", "prepend_description", "prompt", "known_errors",
                 "PANEL_LOG", "ANALISES_LOG", "SHADOW_NEEDS_LOG", "run_revisor", "privacidade_ok", "LOG_FILE"]
        antes = {n: getattr(watch, n) for n in nomes}
        self.addCleanup(lambda: [setattr(watch, n, v) for n, v in antes.items()])
        watch._cfg = lambda k, p: self.cfg.get(k, p)
        watch.agent_paused = lambda: False
        watch.lane_log_tail = lambda ident: ("log", "linha boa\nCoreSimulator timed out\n")
        watch.comment = lambda _id, body: self.comentarios.append(body)
        watch.remove_label = lambda *a: self.chamadas.append(("remove", a[1]))
        watch.add_label = lambda *a: self.chamadas.append(("add", a[1]))
        watch.prepend_description = lambda *a: None
        watch.prompt = lambda nome: "{card} {title} {log_tail}"
        watch.known_errors = lambda: ""
        watch.privacidade_ok = lambda a, m: (True, "")
        watch.PANEL_LOG = self.tmp / "painel.log"
        watch.ANALISES_LOG = self.tmp / "analises.jsonl"
        watch.SHADOW_NEEDS_LOG = self.tmp / "sombra.jsonl"
        watch.LOG_FILE = self.tmp / "bots-watch.log"   # nada de linha de teste no log real do vigia

        def nao(nome):
            def f(*a, **k):
                self.chamadas.append(nome)
                raise RuntimeError(f"{nome} indisponível no teste")
            return f
        watch.local_call = nao("ollama")
        watch.opencode_call = nao("opencode")
        watch.run_agent = nao("claude")

    def painel(self) -> str:
        return (self.tmp / "painel.log").read_text() if (self.tmp / "painel.log").exists() else ""

    # ---- ordem
    def test_ordem_padrao_e_configuravel(self):
        self.assertEqual(watch.ordem("needs"), ["ollama", "opencode", "claude"])
        self.assertEqual(watch.ordem("paradas"), ["opencode", "claude"])
        self.cfg["watch.ordem_paradas"] = "local, opencode, claude"
        self.assertEqual(watch.ordem("paradas"), ["opencode", "claude"], "a triagem local saiu: «local» é ignorado")
        self.cfg["watch.ordem_needs"] = "opencode, OLLAMA, inventado, opencode"
        self.assertEqual(watch.ordem("needs"), ["opencode", "ollama"])
        self.cfg["watch.ordem_paradas"] = ["opencode"]
        self.assertEqual(watch.ordem("paradas"), ["opencode"])
        self.cfg["watch.ordem_paradas"] = ""
        self.assertEqual(watch.ordem("paradas"), ["opencode", "claude"], "vazio volta ao padrão")

    # ---- etiqueta do dono
    def test_needs_ollama_e_o_principal_e_o_opencode_fica_na_sombra(self):
        watch.local_call = lambda p, modelo=None: "texto antes\n[Triagem] Conferência\nDECISAO: remover_needs"
        watch.opencode_call = lambda p, modelo=None, cwd=None: "[Triagem] Conferência\nDECISAO: manter"
        st = {"needs_checked": {}, "alerts": {}}
        self.assertTrue(watch.recheck_needs(dict(self.CI), st, []))
        self.assertIn(("remove", watch.OWNER_LABEL), self.chamadas)
        self.assertIn("_Análise: ollama/qwen2.5-coder:7b._", self.comentarios[0])
        sombra = self.json.loads((self.tmp / "sombra.jsonl").read_text().splitlines()[-1])
        self.assertEqual((sombra["principal_por"], sombra["principal"]), ("ollama/qwen2.5-coder:7b", "remover_needs"))
        self.assertEqual((sombra["sombra_etapa"], sombra["sombra"], sombra["igual"]), ("opencode", "manter", False))
        self.assertIn("análise feita por ollama", self.painel())

    def test_needs_ollama_fora_do_formato_cai_no_opencode(self):
        watch.local_call = lambda p, modelo=None: "acho que manter"
        watch.opencode_call = lambda p, modelo=None, cwd=None: "[Triagem] Conferência\nDECISAO: manter"
        watch.recheck_needs(dict(self.CI), {"needs_checked": {}, "alerts": {}}, [])
        self.assertIn("_Análise: opencode/deepseek-v4.1-flash-free._", self.comentarios[0])
        self.assertNotIn("claude", self.chamadas)
        self.assertFalse((self.tmp / "sombra.jsonl").exists(), "depois do opencode só sobra o Claude: sem sombra")

    def test_needs_claude_so_por_ultimo_e_no_limite_nao_trava(self):
        watch.agent_paused = lambda: True
        self.assertTrue(watch.recheck_needs(dict(self.CI), {"needs_checked": {}, "alerts": {}}, []))
        self.assertEqual(self.chamadas, ["ollama", "opencode"], "Claude no limite é pulado, não chamado")
        self.assertEqual(self.comentarios, [])
        self.assertIn("reconferência sem resposta", self.painel())

    def test_needs_claude_livre_usa_haiku(self):
        visto = {}

        def claude(text, cwd, tag, agente=None, modelo="opus", **k):
            visto["modelo"] = modelo
            return "[Triagem] ok\nDECISAO: manter"
        watch.run_agent = claude
        watch.recheck_needs(dict(self.CI), {"needs_checked": {}, "alerts": {}}, [])
        self.assertEqual(visto["modelo"], "haiku")
        self.assertIn("_Análise: claude/haiku._", self.comentarios[0])

    # ---- paradas
    def st(self):
        return {"stops": {}, "analise_falhas": {}}

    def test_parada_vai_ao_opencode_do_peso(self):
        self.cfg["lanes.modelo.opencode"] = {"modo": "auto", "porPeso": {"alto": {"modelo": "opencode/nemotron-3-ultra-free"}}}
        visto = {}

        def oc(p, modelo=None, cwd=None):
            visto.update(p=p, modelo=modelo)
            return "[Triagem] Diagnóstico\nINSTRUCAO: x\nDECISAO: voltar_fila"
        watch.opencode_call = oc
        ci = dict(self.CI, labels={"nodes": [{"name": "alto"}]})
        watch.handle_stops(ci, "lane:falhou", self.st(), [])
        self.assertEqual(visto["modelo"], "opencode/nemotron-3-ultra-free")
        self.assertIn("_Análise: opencode/nemotron-3-ultra-free._", self.comentarios[0])

    def test_parada_vai_primeiro_ao_opencode(self):
        watch.opencode_call = lambda p, modelo=None, cwd=None: "[Triagem] D\nDECISAO: chamar_dono"
        watch.handle_stops(dict(self.CI), "lane:parada", self.st(), [])
        self.assertIn(("add", watch.OWNER_LABEL), self.chamadas)
        self.assertFalse(hasattr(watch, "triagem_local_call"))

    def test_parada_claude_no_limite_nao_bloqueia_e_conta_falha(self):
        watch.agent_paused = lambda: True
        st = self.st()
        self.assertTrue(watch.handle_stops(dict(self.CI), "lane:parada", st, []))
        self.assertEqual(self.chamadas, ["opencode"])
        self.assertEqual(sum(st["analise_falhas"].values()), 1)
        self.assertIn("análise da parada falhou", self.painel())

    def test_parada_claude_por_ultimo_quando_livre(self):
        watch.run_agent = lambda *a, **k: "[Triagem] D\nDECISAO: voltar_fila"
        watch.handle_stops(dict(self.CI), "lane:parada", self.st(), [])
        self.assertIn("_Análise: claude/haiku._", self.comentarios[0])

    # ---- revisão
    def test_ordem_da_revisao_fallback_padrao_e_o_opencode(self):
        conf = watch.conf_revisor()
        ordem = watch.ordem_revisao("opencode-go", conf, instalado=lambda c: True)
        self.assertEqual(ordem[:2], ["opencode-go", "opencode"])
        self.assertEqual(ordem[-1], "claude")
        self.cfg["watch.adaptador_fallback"] = "codex"
        self.assertEqual(watch.ordem_revisao("opencode-go", conf, instalado=lambda c: True)[:2], ["opencode-go", "codex"])
        self.assertEqual(watch.ordem_revisao("opencode", conf, so_sozinho=True, instalado=lambda c: True)[-1], "claude")

    def test_revisao_cai_no_reserva_e_pula_claude_no_limite(self):
        tentou = []

        def rev(a, texto, cwd, tag, conf, esforco=None):
            tentou.append(a)
            if a == "opencode":
                return "[Revisor] ok"
            raise RuntimeError("caiu")
        watch.run_revisor = rev
        conf = watch.conf_revisor()
        antes = watch.shutil.which
        self.addCleanup(setattr, watch.shutil, "which", antes)
        watch.shutil.which = lambda c, path=None: "/bin/" + c
        self.assertEqual(watch.revisar("x", self.tmp, "t", "opencode-go", conf), ("[Revisor] ok", "opencode"))
        self.assertEqual(tentou, ["opencode-go", "opencode"])
        tentou.clear()
        watch.run_revisor = lambda a, *r: tentou.append(a) or (_ for _ in ()).throw(RuntimeError("caiu"))
        watch.agent_paused = lambda: True
        with self.assertRaises(RuntimeError):
            watch.revisar("x", self.tmp, "t", "opencode-go", conf)
        self.assertNotIn("claude", tentou)



class WorktreesForaDaPastaTest(unittest.TestCase):
    """Regra do dono (29/10): `<repo>` é a main; todo outro checkout fica na pasta de branches."""
    PORCELAIN = """worktree /Users/x/Developer/tuttidash
HEAD a746ee7aaaa
branch refs/heads/main

worktree /private/tmp/pr19
HEAD d7996cfbbbb
detached

worktree /Users/x/Developer/tuttidash-branches/fra-407
HEAD e0914ddcccc
branch refs/heads/dono/fra-407

worktree /Users/x/Developer/outra-pasta/fra-9
HEAD 1111111dddd
branch refs/heads/fra-9
"""

    def test_ler_porcelain(self):
        lista = watch.ler_worktrees(self.PORCELAIN)
        self.assertEqual([w["path"] for w in lista][1], "/private/tmp/pr19")
        self.assertEqual(lista[0]["branch"], "main")
        self.assertEqual(lista[1]["branch"], "")

    def test_so_main_e_branches_ficam_de_fora(self):
        lista = watch.ler_worktrees(self.PORCELAIN)
        fora = watch.worktrees_fora(lista, Path("/Users/x/Developer/tuttidash"),
                                    Path("/Users/x/Developer/tuttidash-branches"))
        self.assertEqual([w["path"] for w in fora], ["/private/tmp/pr19", "/Users/x/Developer/outra-pasta/fra-9"])

    def test_avisa_uma_vez_por_dia_e_esquece_o_que_sumiu(self):
        class P:
            repo = Path(tempfile.mkdtemp())
            worktrees = Path("/Users/x/Developer/tuttidash-branches")
        porcelain = self.PORCELAIN.replace("/Users/x/Developer/tuttidash\n", f"{P.repo}\n", 1)
        orig_projeto, orig_sh, orig_panel = watch.projeto, watch.sh, watch.panel
        linhas = []
        watch.projeto = lambda: P
        watch.sh = lambda *a, **k: porcelain
        watch.panel = linhas.append
        try:
            st = {}
            watch.avisar_worktrees_fora(st, [], agora=1000.0)
            self.assertEqual(len(linhas), 2)
            self.assertIn("worktree fora da pasta de branches: /private/tmp/pr19 (detached d7996cf)", linhas[0])
            watch.avisar_worktrees_fora(st, [], agora=2000.0)
            self.assertEqual(len(linhas), 2, "não repete no mesmo dia")
            porcelain = porcelain.split("\nworktree /private/tmp/pr19")[0] + "\n"
            watch.sh = lambda *a, **k: porcelain
            watch.avisar_worktrees_fora(st, [], agora=3000.0)
            self.assertEqual(list(st["worktrees_avisados"]), [], "o que sumiu sai do estado")
        finally:
            watch.projeto, watch.sh, watch.panel = orig_projeto, orig_sh, orig_panel

    def test_revisor_nao_cria_worktree(self):
        deny = watch.READ_ONLY_SETTINGS["permissions"]["deny"]
        self.assertIn("Bash(git worktree:*)", deny)
        self.assertIn("Bash(git clone:*)", deny)
        self.assertIn("Não crie worktree", watch.prompt("revisor"))


class SegundaOpiniaoGuardadaTest(unittest.TestCase):
    """PRD 29/10: a segunda opinião APROVADO vale para o head até ele mudar; sem quem confirme,
    o vigia nem chama a segunda opinião. A regra de merge (APROVADO publicado) não muda."""

    PR = {"number": 23, "headRefOid": "711e004aaaa", "title": "Menu da barra", "headRefName": "x/menu",
          "mergeStateStatus": "CLEAN"}

    def setUp(self):
        nomes = ("sh", "card_of", "issue", "conf_revisor", "escolher_revisor", "revisar", "papel",
                 "quem_confirma", "save_state", "registrar_veredito", "panel", "prompt", "comment",
                 "agent_paused", "LIMIT_FILE")
        velhos = {n: getattr(watch, n) for n in nomes}
        self.addCleanup(lambda: [setattr(watch, n, f) for n, f in velhos.items()])
        self.chamadas, self.linhas = [], []
        watch.sh = lambda *a, **k: ""
        watch.card_of = lambda t, b: None
        watch.issue = lambda c: None
        watch.conf_revisor = lambda: {"opencode": {"papel": "segunda_opiniao"}}
        watch.escolher_revisor = lambda lane, conf, so_sozinho=False, **k: ("claude" if so_sozinho else "opencode", "")
        watch.papel = lambda a, conf: "segunda_opiniao" if a == "opencode" else "sozinho"
        watch.save_state = lambda st: None
        watch.registrar_veredito = lambda reg: None
        watch.panel = self.linhas.append
        watch.prompt = lambda nome: "{number}{repo_slug}{title}{branch}{sha}{sha7}{merge_state}{card}{card_desc}" \
                                    "{card_comments}{stat}{protected}{lane}{known_errors}{same_model}"
        watch.comment = lambda *a: None
        watch.LIMIT_FILE = Path(tempfile.mkdtemp()) / "limite-agente"  # nunca o arquivo real do Mac
        self.st = {"reviewed": {}}

    def revisar_falso(self, respostas):
        def revisar(texto, cwd, tag, revisor, conf, so_sozinho=False, esforco=None):
            self.chamadas.append((revisor, so_sozinho))
            r = respostas.pop(0)
            if isinstance(r, Exception):
                raise r
            return r, revisor
        watch.revisar = revisar

    def rodar(self):
        return watch.review_pr("app", {"dir": ".", "slug": "dono/repo"}, self.PR, self.st, [])

    def test_aprovado_fica_guardado_mesmo_se_a_confirmacao_falha(self):
        watch.quem_confirma = lambda lane, conf: ["claude"]
        self.revisar_falso(["[Revisor] REVISOR: APROVADO · head `711e004`", RuntimeError("limite")])
        with self.assertRaises(RuntimeError):
            self.rodar()
        self.assertIn("711e004aaaa", self.st["segundas_opinioes"])
        # Próximo ciclo: só a confirmação roda; o opencode não revisa de novo.
        self.chamadas.clear()
        self.revisar_falso(["[Revisor] REVISOR: APROVADO · head `711e004`\n\nok"])
        watch.sh = lambda *a, **k: ""
        self.rodar()
        self.assertEqual(self.chamadas, [("claude", True)])
        self.assertEqual(self.st["reviewed"]["711e004aaaa"], "APROVADO")

    def test_sem_quem_confirme_nem_chama_a_segunda_opiniao(self):
        watch.quem_confirma = lambda lane, conf: []
        self.revisar_falso([])
        self.assertIs(self.rodar(), False)
        self.assertIs(self.rodar(), False)
        self.assertEqual(self.chamadas, [])
        self.assertEqual(len(self.linhas), 1, "avisa uma vez por head")
        self.assertIn("PR #23: revisão espera o Claude", self.linhas[0])
        self.assertNotIn("711e004aaaa", self.st["reviewed"], "não marca o head: revisa quando o Claude voltar")

    def test_guardada_e_sem_quem_confirme_avisa_que_esta_guardada(self):
        watch.quem_confirma = lambda lane, conf: []
        self.st["segundas_opinioes"] = {"711e004aaaa": {"revisor": "opencode", "quando": 1.0, "pr": 23}}
        self.revisar_falso([])
        self.assertIs(self.rodar(), False)
        self.assertIn("segunda opinião APROVADO guardada", self.linhas[0])

    def test_ajustes_da_segunda_opiniao_nao_fica_guardado(self):
        watch.quem_confirma = lambda lane, conf: ["claude"]
        self.revisar_falso(["[Revisor] REVISOR: AJUSTES · head `711e004`\n\nbug"])
        self.rodar()
        self.assertNotIn("711e004aaaa", self.st.get("segundas_opinioes", {}))
        self.assertEqual(self.st["reviewed"]["711e004aaaa"], "AJUSTES")
        self.assertEqual(self.chamadas, [("opencode", False)])

    def test_head_novo_pede_segunda_opiniao_de_novo_e_limpeza(self):
        watch.quem_confirma = lambda lane, conf: ["claude"]
        self.st["segundas_opinioes"] = {"velho": {"revisor": "opencode", "quando": 1.0, "pr": 23}}
        self.revisar_falso(["[Revisor] REVISOR: AJUSTES · head `711e004`"])
        self.rodar()
        self.assertEqual(self.chamadas, [("opencode", False)])
        self.st["sem_revisao"] = {"velho": 1.0, "velho|avisado": 2.0, "711e004aaaa": 3.0}
        watch.limpar_revisoes_fechadas(self.st, {"711e004aaaa"})
        self.assertEqual(self.st["segundas_opinioes"], {})
        self.assertEqual(self.st["sem_revisao"], {"711e004aaaa": 3.0})


class LimiteMensalTest(unittest.TestCase):
    def setUp(self):
        velhos = (watch.LIMIT_FILE, watch.panel, watch.log)
        self.addCleanup(lambda: setattr(watch, "LIMIT_FILE", velhos[0]) or setattr(watch, "panel", velhos[1])
                        or setattr(watch, "log", velhos[2]))
        watch.LIMIT_FILE = Path(tempfile.mkdtemp()) / "limite-agente"
        self.linhas = []
        watch.panel = self.linhas.append
        watch.log = lambda m: None

    def test_mensal_pausa_6h_e_avisa_diferente(self):
        exc = RuntimeError("claude -p (1): | You've hit your monthly spend limit · raise it at https://claude.ai/settings/usage")
        watch.note_agent_failure(exc)
        ate, mensal = watch.ler_pausa()
        self.assertTrue(mensal)
        self.assertGreater(ate - watch.time.time(), watch.AGENT_MONTHLY_PAUSE_S - 60)
        self.assertTrue(watch.agent_paused())
        self.assertIn("sem cota mensal de gasto", self.linhas[0])
        watch.note_agent_failure(exc)
        self.assertEqual(len(self.linhas), 1, "um aviso por pausa")

    def test_limite_comum_continua_30_min(self):
        watch.note_agent_failure(RuntimeError("You've hit your usage limit"))
        ate, mensal = watch.ler_pausa()
        self.assertFalse(mensal)
        self.assertLess(ate - watch.time.time(), watch.AGENT_LIMIT_PAUSE_S + 5)
        self.assertIn("pausa a IA até", self.linhas[0])

    def test_pausa_antiga_sem_marcador_ainda_le(self):
        watch.LIMIT_FILE.write_text(str(watch.time.time() + 100))
        self.assertEqual(watch.ler_pausa()[1], False)
        self.assertTrue(watch.agent_paused())


class PrSemCardTest(unittest.TestCase):
    def setUp(self):
        velho = watch.panel
        self.addCleanup(lambda: setattr(watch, "panel", velho))
        self.linhas = []
        watch.panel = self.linhas.append

    def test_avisa_depois_de_6h_uma_vez(self):
        pr = {"number": 22, "headRefOid": "3a8ed4c", "title": "Revisor não cria worktree", "headRefName": "x/wt"}
        st = {"reviewed": {"3a8ed4c": "APROVADO"}}
        watch.avisar_pr_sem_card(pr, st, agora=0.0)
        watch.avisar_pr_sem_card(pr, st, agora=watch.REVIEW_WAIT_MAX_S - 1)
        self.assertEqual(self.linhas, [])
        watch.avisar_pr_sem_card(pr, st, agora=watch.REVIEW_WAIT_MAX_S)
        watch.avisar_pr_sem_card(pr, st, agora=watch.REVIEW_WAIT_MAX_S * 2)
        self.assertEqual(len(self.linhas), 1)
        self.assertIn("PR #22 sem card está APROVADO há 6 h", self.linhas[0])

    def test_pr_com_card_fica_com_o_merge_ready(self):
        pr = {"number": 9, "headRefOid": "h", "title": "FRA-9 algo", "headRefName": "x/fra-9"}
        st = {"reviewed": {}}
        watch.avisar_pr_sem_card(pr, st, agora=10 ** 9)
        self.assertEqual(self.linhas, [])
        self.assertNotIn("sem_revisao", st)


class ContextoDeFilaTest(unittest.TestCase):
    """Encaixe card ↔ lane: o vigia não deve promover card que nenhuma lane consegue rodar."""

    def ci(self, ident="FRA-1", lane="grok", effort="alto", descricao="", comentarios=()):
        labels = []
        if lane:
            labels.append({"name": lane, "parent": {"name": "lane"}})
        if effort:
            labels.append({"name": effort, "parent": {"name": "esforco"}})
        return {"identifier": ident, "title": "x", "description": descricao,
                "labels": {"nodes": labels},
                "comments": {"nodes": [{"id": str(i), "body": b} for i, b in enumerate(comentarios)]}}

    def test_contexto_rejeita_duas_lanes(self):
        labels = [{"name": "grok", "parent": {"name": "lane"}},
                  {"name": "codex", "parent": {"name": "lane"}},
                  {"name": "alto", "parent": {"name": "esforco"}}]
        ctx = watch.contexto_card({"labels": {"nodes": labels}, "description": ""})
        self.assertTrue(ctx["lane_invalida"])
        self.assertIsNone(ctx["lane"])

    def test_lane_pedida_precisa_ser_a_lane_com_folga(self):
        card = self.ci(lane="codex")
        self.assertIsNone(watch.lane_para_card(
            card, {"grok"}, {"grok": (11, "créditos")}, {"grok": 0}, set(), [card]))

    def test_escolhe_lane_com_cota_e_vaga(self):
        card = self.ci(lane="grok")
        medidas = {"grok": (11, "créditos")}
        self.assertEqual(watch.lane_para_card(
            card, {"grok"}, medidas, {"grok": 0}, set(), [card]), "grok")
        self.assertIsNone(watch.lane_para_card(
            card, {"grok"}, medidas, {"grok": watch.MAX_PER_LANE}, set(), [card]))

    def test_cota_por_esforco(self):
        self.assertTrue(watch.cota_ok("grok", "alto", {"grok": (11, "créditos")}))
        self.assertFalse(watch.cota_ok("grok", "alto", {"grok": (61, "créditos")}))
        # Janela longa afrouxa o teto do alto para 85.
        self.assertTrue(watch.cota_ok("grok", "alto", {"grok": (80, "30 dias")}))
        self.assertFalse(watch.cota_ok("grok", "alto", {"grok": (86, "30 dias")}))

    def test_comentario_recente_segura(self):
        card = self.ci(comentarios=("x", "não vai para a lane por enquanto"))
        self.assertTrue(watch.held_by_comments(card))
        self.assertIsNone(watch.lane_para_card(
            card, {"grok"}, {"grok": (11, "créditos")}, {"grok": 0}, set(), [card]))

    def test_conflito_com_card_rodando_segura(self):
        card = self.ci(ident="FRA-2", descricao="app/MeasurementsView.swift")
        rodando = self.ci(ident="FRA-1", descricao="app/MeasurementsView.swift")
        self.assertIsNone(watch.lane_para_card(
            card, {"grok"}, {"grok": (11, "créditos")}, {"grok": 0}, {"FRA-1"}, [card, rodando]))

    def test_keep_nao_promove_card_de_lane_sem_folga(self):
        from unittest.mock import patch
        codex = self.ci(ident="FRA-2", lane="codex", descricao="- [ ] feito")
        codex.update({"id": "id-FRA-2", "state": {"id": "todo", "name": "Backlog", "type": "backlog"},
                      "priority": 1, "sortOrder": 0,
                      "inverseRelations": {"nodes": []}})
        grok = self.ci(ident="FRA-3", lane="grok", descricao="- [ ] feito")
        grok.update({"id": "id-FRA-3", "state": {"id": "todo", "name": "Backlog", "type": "backlog"},
                     "priority": 2, "sortOrder": 0,
                     "inverseRelations": {"nodes": []}})
        mudou, comentou = [], []
        with patch.object(watch, "lanes_ativas", return_value={"grok"}), \
             patch.object(watch, "lanes_com_folga", return_value={"grok"}), \
             patch.object(watch, "SAUDE_LANES", Path(tempfile.mkdtemp()) / "saude.json"), \
             patch.object(watch, "medidas_contas", return_value={"grok": (11, "créditos")}), \
             patch.object(watch, "busy_lanes", return_value=set()), \
             patch.object(watch, "set_state", side_effect=lambda i, s: mudou.append((i, s))), \
             patch.object(watch, "comment", side_effect=lambda i, b: comentou.append((i, b))), \
             patch.object(watch, "panel", return_value=None):
            watch.keep_lanes_busy([codex, grok], {}, [])
        self.assertNotIn("id-FRA-2", {i for i, _ in mudou})
        self.assertIn(("id-FRA-3", watch.STATE_TODO_ID), mudou)
        # v2: o vigia só promove para o Todo; quem puxa para In Progress é o dispatcher.
        self.assertNotIn(("id-FRA-3", watch.STATE_IN_PROGRESS_ID), mudou)

    def test_risco_alto_prefere_lane_forte_sem_lane_explicita(self):
        labels = [{"name": "alto", "parent": {"name": "esforco"}},
                  {"name": "risco:alto", "parent": None}]
        card = {"identifier": "FRA-8", "title": "x", "description": "- [ ] ok",
                "labels": {"nodes": labels}, "comments": {"nodes": []}}
        medidas = {"opencode": (1, "créditos"), "grok": (50, "créditos")}
        lane = watch.lane_para_card(card, {"opencode", "grok"}, medidas,
                                    {"opencode": 0, "grok": 1}, set(), [card])
        self.assertEqual(lane, "grok", "risco alto tenta Grok/Claude antes da free")

    def test_card_e_lane_entram_em_cooldown(self):
        import time as _time
        agora = _time.time()
        self.assertTrue(watch.card_em_cooldown(
            {"identifier": "FRA-1"}, {"stops": {"FRA-1": {"ultimo": agora}}}))
        self.assertFalse(watch.card_em_cooldown(
            {"identifier": "FRA-1"}, {"stops": {"FRA-1": {"ultimo": agora - watch.FAIL_COOLDOWN_S - 1}}}))
        self.assertTrue(watch.lane_em_cooldown({"lane_falhas": {"opencode": agora}}, "opencode"))
        self.assertFalse(watch.lane_em_cooldown(
            {"lane_falhas": {"opencode": agora - watch.LANE_FAIL_COOLDOWN_S - 1}}, "opencode"))

    def test_card_atribuido_a_outro_nao_entra(self):
        self.assertTrue(watch.atribuido_a_outro({"assignee": {"id": "u1"}}, "u2"))
        self.assertFalse(watch.atribuido_a_outro({"assignee": {"id": "u1"}}, "u1"))
        self.assertFalse(watch.atribuido_a_outro({"assignee": None}, "u2"))

    def test_project_issues_pagina_ate_o_fim(self):
        from unittest.mock import patch
        paginas = [
            {"issues": {"pageInfo": {"hasNextPage": True, "endCursor": "c1"},
                        "nodes": [{"identifier": "FRA-1", "state": {"name": "Backlog"}}]}},
            {"issues": {"pageInfo": {"hasNextPage": False, "endCursor": "c2"},
                        "nodes": [{"identifier": "FRA-2", "state": {"name": "Backlog"}}]}},
        ]
        with patch.object(watch, "projeto_linear", return_value="p"), \
             patch.object(watch, "linear", side_effect=paginas):
            issues = watch.project_issues(["Backlog"])
        self.assertEqual([i["identifier"] for i in issues], ["FRA-1", "FRA-2"])
