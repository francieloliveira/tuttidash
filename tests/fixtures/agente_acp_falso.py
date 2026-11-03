#!/usr/bin/env python3
"""Agente ACP falso para os testes da lane ACP.

FAKE_MODO: `perguntar` (padrão) pede permissão para tudo e só age no que foi
liberado; `sem_perguntar` age sem pedir (o caso que a sonda precisa pegar);
`modelo_fixo` ignora o modelo pedido. O modelo inicial vem de
OPENCODE_CONFIG_CONTENT (chave `model`), como no OpenCode.
"""
import json
import os
import sys

modo = os.environ.get("FAKE_MODO", "perguntar")
fora = os.environ.get("FAKE_FORA", "/tmp/acp-falso-fora.txt")
cfg = json.loads(os.environ.get("OPENCODE_CONFIG_CONTENT") or "{}")
modelo = "padrao/x" if modo == "modelo_fixo" else (cfg.get("model") or "padrao/x")
cwd = os.getcwd()
prox = [1000]


def enviar(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()


def ler():
    linha = sys.stdin.readline()
    return json.loads(linha) if linha else None


def update(u):
    enviar({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})


def pedir(tool):
    prox[0] += 1
    mid = prox[0]
    enviar({"jsonrpc": "2.0", "id": mid, "method": "session/request_permission",
            "params": {"sessionId": "s1", "toolCall": tool, "options": [
                {"optionId": "once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "always", "name": "Always", "kind": "allow_always"},
                {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}})
    while True:
        m = ler()
        if m is None:
            sys.exit(0)
        if m.get("id") == mid:
            out = (m.get("result") or {}).get("outcome") or {}
            return out.get("outcome") == "selected" and out.get("optionId") == "once"


def opcoes():
    return [{"id": "model", "category": "model", "type": "select", "currentValue": modelo,
             "options": [{"value": modelo}]}]


def agir(tool, efeito):
    update(dict(tool, sessionUpdate="tool_call", status="pending"))
    ok = True if modo == "sem_perguntar" else pedir(tool)
    if ok:
        efeito()
    update({"sessionUpdate": "tool_call_update", "toolCallId": tool["toolCallId"],
            "status": "completed" if ok else "failed"})


def escrever(caminho):
    def f():
        with open(caminho, "w") as fh:
            fh.write("oi")
    return f


while True:
    msg = ler()
    if msg is None:
        break
    met, mid = msg.get("method"), msg.get("id")
    if met == "initialize":
        enviar({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": int(os.environ.get("FAKE_VERSAO", "1")),
                                                         "agentCapabilities": {}, "authMethods": [],
                                                         "agentInfo": {"name": "falso", "version": "9.9.9"}}})
    elif met == "session/new":
        enviar({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s1", "configOptions": opcoes()}})
    elif met == "session/set_config_option":
        if modo != "modelo_fixo":
            modelo = msg["params"]["value"]
        enviar({"jsonrpc": "2.0", "id": mid, "result": {"configOptions": opcoes()}})
    elif met == "session/prompt" and "Teste automático" in json.dumps(msg["params"]["prompt"], ensure_ascii=False):
        texto = json.dumps(msg["params"]["prompt"], ensure_ascii=False)
        if modo != "nada":
            if "SONDA.md" in texto:
                agir({"toolCallId": "s1", "title": "SONDA.md", "kind": "edit",
                      "locations": [{"path": os.path.join(cwd, "SONDA.md")}]}, escrever(os.path.join(cwd, "SONDA.md")))
            elif "touch fora-da-politica.txt" in texto:
                agir({"toolCallId": "s2", "title": "touch fora-da-politica.txt", "kind": "execute",
                      "rawInput": {"command": "touch fora-da-politica.txt"}},
                     escrever(os.path.join(cwd, "fora-da-politica.txt")))
            elif "example.com" in texto:
                agir({"toolCallId": "s3", "title": "https://example.com", "kind": "fetch",
                      "rawInput": {"url": "https://example.com"}}, lambda: None)
        enviar({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif met == "session/prompt":
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "começando"}})
        agir({"toolCallId": "t1", "title": "ok.txt", "kind": "edit",
              "locations": [{"path": os.path.join(cwd, "ok.txt")}]}, escrever(os.path.join(cwd, "ok.txt")))
        agir({"toolCallId": "t2", "title": "git status; touch encadeado.txt", "kind": "execute",
              "rawInput": {"command": "git status; touch encadeado.txt"}}, escrever(os.path.join(cwd, "encadeado.txt")))
        agir({"toolCallId": "t3", "title": "fora", "kind": "edit", "locations": [{"path": fora}]}, escrever(fora))
        agir({"toolCallId": "t4", "title": "https://example.com", "kind": "fetch",
              "rawInput": {"url": "https://example.com"}}, escrever(os.path.join(cwd, "web.txt")))
        agir({"toolCallId": "t5", "title": "git status", "kind": "execute",
              "rawInput": {"command": "git status"}}, escrever(os.path.join(cwd, "status.txt")))
        update({"sessionUpdate": "usage_update", "used": 100, "size": 1000,
                "cost": {"amount": 0.0123, "currency": "USD"}})
        update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " FIM"}})
        enviar({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn", "usage": {
            "inputTokens": 50, "outputTokens": 7, "cachedReadTokens": 3, "totalTokens": 60}}})
    elif mid is not None:
        enviar({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "não"}})
