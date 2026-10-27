"""FRA-528: logs do opencode e do codex não viram «morta» quando terminaram."""
import json
import tempfile
import unittest
from pathlib import Path

from gasto_lanes import parser as p


def _log(nome, eventos):
    d = Path(tempfile.mkdtemp())
    f = d / nome
    f.write_text("".join(json.dumps(e) + "\n" for e in eventos))
    return f


OC_FIM = [{"type": "step_start", "sessionID": "s"},
          {"type": "step_finish", "sessionID": "s", "part": {"reason": "tool-calls", "cost": 0,
                                                           "tokens": {"input": 10, "output": 5, "cache": {"read": 100}}}},
          {"type": "text", "sessionID": "s", "part": {"text": "Card entregue."}}]


class OutrosFormatos(unittest.TestCase):
    def test_nome_com_hifen(self):
        m = p.parse_name("FRA-514-opencode-go-20261023-194452.jsonl")
        self.assertEqual((m["card"], m["lane"]), ("FRA-514", "opencode-go"))

    def test_opencode_terminou_e_gratis(self):
        r = p.parse_log(_log("FRA-519-opencode-20261023-175926.jsonl", OC_FIM))
        self.assertEqual(r["status"], p.STATUS_OK)
        self.assertEqual(r["custo"], p.CUSTO_GRATIS)
        self.assertEqual(r["tokens"]["total"], 115)

    def test_opencode_sumiu_no_meio_e_morta(self):
        r = p.parse_log(_log("FRA-1-opencode-20261023-100000.jsonl", OC_FIM[:1] + [{"type": "tool_use", "sessionID": "s"}]))
        self.assertEqual(r["status"], p.STATUS_MORTA)

    def test_opencode_rodando(self):
        f = _log("FRA-1-opencode-20261023-100000.jsonl", OC_FIM[:1])
        self.assertEqual(p.parse_log(f, {f.name})["status"], p.STATUS_ANDAMENTO)

    def test_opencode_go_erro_de_regiao_falhou(self):
        r = p.parse_log(_log("FRA-514-opencode-go-20261023-194452.jsonl", [
            {"type": "step_start", "sessionID": "s"},
            {"type": "error", "sessionID": "s", "error": {"type": "provider.invalid-request",
                                                       "message": "This Go model requires Global regions."}}]))
        self.assertEqual(r["status"], p.STATUS_ERRO)
        self.assertEqual(r["custo"], p.CUSTO_PLANO)
        self.assertIn("Global", r["erros"][0])

    def test_opencode_abortado_cancelada(self):
        r = p.parse_log(_log("FRA-1-opencode-20261023-100000.jsonl", [
            {"type": "step_start", "sessionID": "s"},
            {"type": "error", "sessionID": "s", "error": {"name": "MessageAbortedError", "message": "aborted"}}]))
        self.assertEqual(r["status"], p.STATUS_CANCELADA)

    def test_codex_falhou_no_limite(self):
        r = p.parse_log(_log("FRA-517-codex-20261023-154136.jsonl", [
            {"type": "thread.started"}, {"type": "turn.started"},
            {"type": "error", "message": "You've hit your usage limit."},
            {"type": "turn.failed", "error": {"message": "You've hit your usage limit."}}]))
        self.assertEqual(r["status"], p.STATUS_ERRO)

    def test_codex_concluiu(self):
        r = p.parse_log(_log("FRA-2-codex-20261023-100000.jsonl", [
            {"type": "thread.started"}, {"type": "turn.completed", "usage": {"input_tokens": 3, "output_tokens": 4}}]))
        self.assertEqual(r["status"], p.STATUS_OK)
        self.assertEqual(r["custo"], p.CUSTO_PLANO)

    def test_claude_cancelado(self):
        r = p.parse_log(_log("FRA-3-claude-20261023-100000.jsonl", [
            {"type": "result", "subtype": "success", "is_error": False, "stop_reason": "cancelled"}]))
        self.assertEqual(r["status"], p.STATUS_CANCELADA)


if __name__ == "__main__":
    unittest.main()
